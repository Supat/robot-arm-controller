using AssistArm.Control;
using AssistArm.Futaba;
using AssistArm.Model;
using AssistArm.Signal;

namespace AssistArm.Tests;

/// <summary>Scripted EMG: constant amplitude per channel, delivered quickly.</summary>
internal sealed class ScriptedEmgSource(float[] amplitudes) : IEmgSource
{
    public string Name => "scripted";
    public int ChannelCount => 2;
    public double SampleRate => 2000;
    private CancellationTokenSource? _cancel;

    public Task StartAsync(Action<EmgBlock> sink)
    {
        var cancel = _cancel = new CancellationTokenSource();
        new Thread(() =>
        {
            long index = 0;
            while (!cancel.IsCancellationRequested)
            {
                var s = new float[40];
                for (int r = 0; r < 20; r++) for (int c = 0; c < 2; c++) s[r * 2 + c] = (r % 2 == 0 ? 1 : -1) * amplitudes[c];
                sink(new EmgBlock(2000, 2, s, index));
                index += 20;
                Thread.Sleep(2);
            }
        }) { IsBackground = true }.Start();
        return Task.CompletedTask;
    }

    public Task StopAsync() { _cancel?.Cancel(); return Task.CompletedTask; }
}

/// <summary>Emits a ramp in many small blocks as one synchronous burst, the way a stalled source catches up.</summary>
internal sealed class BurstEmgSource : IEmgSource
{
    public string Name => "burst";
    public int ChannelCount => 1;
    public double SampleRate => 2000;
    public List<EmgBlock> Blocks { get; } = [];

    public BurstEmgSource(int blockCount, int rowsPerBlock)
    {
        long index = 0;
        for (int b = 0; b < blockCount; b++)
        {
            var rows = Enumerable.Range(0, rowsPerBlock).Select(i => (index + i) * (i % 2 == 0 ? 1f : -1f)).ToArray();
            Blocks.Add(new EmgBlock(2000, 1, rows, index));
            index += rowsPerBlock;
        }
    }

    public Task StartAsync(Action<EmgBlock> sink)
    {
        new Thread(() => { foreach (var b in Blocks) sink(b); }) { IsBackground = true }.Start();
        return Task.CompletedTask;
    }

    public Task StopAsync() => Task.CompletedTask;
}

public class ControllerTests
{
    [Fact]
    public async Task BurstOfBlocksIsProcessedInArrivalOrder()
    {
        var source = new BurstEmgSource(400, 5);
        var reference = new QuasiTensionProcessor(2000, 1);
        var expected = source.Blocks.SelectMany(reference.Process).Select(s => s.Values[0]).ToList();

        var pipeline = new QuasiTensionPipeline(source);
        var got = new List<QuasiTensionSample>();
        pipeline.AddQuasiTensionSink(s => { lock (got) got.Add(s); });
        await pipeline.StartAsync();
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (DateTime.UtcNow < deadline)
        {
            lock (got) if (got.Count >= expected.Count) break;
            await Task.Delay(10);
        }
        await pipeline.StopAsync();

        Assert.Equal(expected.Count, got.Count);
        Assert.Equal(Enumerable.Range(0, expected.Count), got.Select(s => s.Index));
        for (int i = 0; i < expected.Count; i++) Assert.Equal(expected[i], got[i].Values[0], 12);
    }

    [Fact]
    public async Task CalibrationThenControlDrivesMockServos()
    {
        var source = new ScriptedEmgSource([1e-4f, 0f]);
        var pipeline = new QuasiTensionPipeline(source);
        var calibrator = new ActivationCalibrator(pipeline);
        await calibrator.StartAsync();
        await Task.Delay(300);
        var range = await calibrator.StopAsync();
        Assert.Equal(2, range.ChannelCount);

        var servo = new MockServoDriver();
        servo.Open();
        var estimator = JointEstimator.LegacyDefault();
        var fixedRange = new ActivationRange([0, 0], [5e-5, 5e-5]);
        var config = new ControlConfiguration { StatusPollRate = 20, GoalUpdateRate = 20 };
        config.Stiffness.LegacyScaling = false;
        var controller = new AssistController(pipeline, servo, estimator, fixedRange, config);

        var samples = new List<ControlSample>();
        controller.Sample += s => { lock (samples) samples.Add(s); };
        await controller.StartAsync();
        await Task.Delay(1500);
        await controller.StopAsync();

        Assert.True(samples.Count > 20);
        var last = samples[^1];
        Assert.Equal(1, last.Activation[0], 6);
        Assert.Equal(0, last.Activation[1], 6);
        var expected = estimator.Estimate([1, 0]);
        Assert.Equal(expected, last.Estimate);
        Assert.Equal(Math.Min(90, Math.Max(-90, expected.EquilibriumDegrees)), last.TargetDegrees, 9);
        Assert.Equal((int)Math.Round(last.TargetDegrees * 10, MidpointRounding.AwayFromZero), last.TargetLeft);
        Assert.Equal(-(int)Math.Round(last.TargetDegrees * 10, MidpointRounding.AwayFromZero), last.TargetRight);
        Assert.Equal(expected.NormalizedStiffness >= 40 ? 0x32 : 0xFF, last.Compliance);
        // The mock servo moved towards the goal and status was read back.
        Assert.NotNull(last.StatusLeft);
        Assert.True(Math.Abs(last.StatusLeft!.Position) > Math.Abs(last.TargetLeft) / 4);
        Assert.Equal(0, servo.ReadStatus(1).Current); // torque is off after stop
    }

    [Fact]
    public async Task ControlLoopKeepsItsRate()
    {
        var pipeline = new QuasiTensionPipeline(new ScriptedEmgSource([1e-4f, 1e-4f]));
        var servo = new MockServoDriver();
        servo.Open();
        var controller = new AssistController(pipeline, servo, JointEstimator.LegacyDefault(), new ActivationRange([0, 0], [5e-5, 5e-5]));
        var times = new List<double>();
        controller.Sample += s => { lock (times) times.Add(s.Time); };
        await controller.StartAsync();
        await Task.Delay(1200);
        await controller.StopAsync();
        var steps = times.Zip(times.Skip(1), (a, b) => b - a).OrderBy(d => d).ToList();
        Assert.True(steps.Count > 30);
        Assert.InRange(steps[steps.Count / 2], 0.019, 0.021); // 50 Hz
    }

    [Fact]
    public async Task PipelineKeepsRunningUntilLastHolderStops()
    {
        var pipeline = new QuasiTensionPipeline(new SyntheticEmgSource());
        await pipeline.StartAsync(); // the app holds the stream while connected
        var calibrator = new ActivationCalibrator(pipeline);
        await calibrator.StartAsync();
        await calibrator.StopAsync();
        Assert.True(pipeline.IsRunning, "calibration ending must not stop a stream someone else holds");
        await pipeline.StopAsync();
        Assert.False(pipeline.IsRunning);
        await pipeline.StopAsync(); // an unbalanced stop is harmless
        await pipeline.StartAsync();
        Assert.True(pipeline.IsRunning);
        await pipeline.StopAsync();
    }

    [Fact]
    public void ChannelMismatchIsRejected()
    {
        var pipeline = new QuasiTensionPipeline(new SyntheticEmgSource(3));
        Assert.Throws<ControllerException>(() =>
            new AssistController(pipeline, new MockServoDriver(), JointEstimator.LegacyDefault(), ActivationRange.Identity(3)));
    }

    [Fact]
    public void TelemetryLogWritesCsv()
    {
        string path = Path.Combine(Path.GetTempPath(), $"assistarm-{Guid.NewGuid()}.csv");
        var log = new TelemetryLog(path, 2);
        log.Write(new ControlSample
        {
            Time = 1.25, QuasiTension = [1e-4, 2e-4], Activation = [0.5, 1], Estimate = new JointEstimate(0.5, 100, 42),
            Compliance = 0x32, TargetLeft = 286, TargetRight = -286,
            StatusLeft = new ServoStatus { Position = 280, Current = 12 }, TargetDegrees = 28.6,
        });
        log.Finish();
        var lines = File.ReadAllText(path).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        File.Delete(path);
        Assert.Equal(2, lines.Length);
        Assert.StartsWith("time_s,qt1,qt2,activation1,activation2,eq_deg,", lines[0]);
        // Same row the macOS app writes for this sample.
        Assert.Equal("1.2500,0.00010000,0.00020000,0.5000,1.0000,28.6479,100.0000,42.0000,50,28.6000,286,-286,28.0000,,12,", lines[1]);
    }
}

/// <summary>Echoes every write (like a half-duplex RS-485 adapter) and answers status requests with the last commanded position.</summary>
internal sealed class ScriptedTransport : IServoTransport
{
    public string Name => "scripted";
    private readonly List<byte> _inbox = [];
    public List<byte[]> Written { get; } = [];
    private short _goal;

    public void Open() { }
    public void Close() { }
    public void DiscardInput() => _inbox.Clear();

    public void Write(byte[] bytes)
    {
        Written.Add(bytes);
        _inbox.AddRange(bytes); // echo
        if (FutabaProtocol.Parse(bytes) is not var (p, _)) return;
        if (p.Address == FutabaProtocol.Address.GoalPosition && p.Data.Length >= 2) _goal = unchecked((short)(p.Data[0] | p.Data[1] << 8));
        if (p.Flag == FutabaProtocol.Flag.ReturnStatus)
        {
            ushort u = unchecked((ushort)_goal);
            byte[] body = [p.Id, 0x00, 0x2A, 0x12, 0x01, (byte)(u & 0xFF), (byte)(u >> 8), .. new byte[16]];
            _inbox.AddRange([.. FutabaProtocol.ReturnHeader, .. body, FutabaProtocol.Checksum(body)]);
        }
    }

    public byte[] Read(int count, TimeSpan timeout)
    {
        int n = Math.Min(count, _inbox.Count);
        var result = _inbox.GetRange(0, n).ToArray();
        _inbox.RemoveRange(0, n);
        return result;
    }
}

public class FutabaTests
{
    [Fact]
    public void PacketsMatchLegacyBytes()
    {
        // Legacy RSIDTorqueOnOff(ID=1, 1): FA AF 01 00 24 01 01 01 sum
        Assert.Equal([0xFA, 0xAF, 0x01, 0x00, 0x24, 0x01, 0x01, 0x01, 0x01 ^ 0x00 ^ 0x24 ^ 0x01 ^ 0x01 ^ 0x01], FutabaProtocol.Torque(1, true));
        // Legacy RSIDMove(ID=2, pos=-900 (0xFC7C), time=0): FA AF 02 00 1E 04 01 7C FC 00 00 sum
        byte[] body = [0x02, 0x00, 0x1E, 0x04, 0x01, 0x7C, 0xFC, 0x00, 0x00];
        Assert.Equal([0xFA, 0xAF, .. body, FutabaProtocol.Checksum(body)], FutabaProtocol.Move(2, -900, 0));
        Assert.Equal([0x01, 0x00, 0x23, 0x01, 0x01, 75], FutabaProtocol.MaxTorque(1, 75)[2..8]);
        // Compliance slope for CW (0x1A) and CCW (0x1B) in one 2-byte write.
        Assert.Equal([0x01, 0x00, 0x1A, 0x02, 0x01, 0x32, 0x32], FutabaProtocol.ComplianceSlope(1, 0x32)[2..9]);
        // Manual: FA AF 01 09 00 00 01 09
        Assert.Equal([0xFA, 0xAF, 0x01, 0x09, 0x00, 0x00, 0x01, 0x09], FutabaProtocol.StatusRequest(1));
    }

    [Fact]
    public void ParseReturnPacketAndSkipEcho()
    {
        // 18 data bytes from address 42: pos=900, time=5, speed=-10, current=120, temp=33, volt=740.
        var data = new List<byte>();
        foreach (short v in new short[] { 900, 5, -10, 120, 33, 740 }) { ushort u = unchecked((ushort)v); data.AddRange([(byte)(u & 0xFF), (byte)(u >> 8)]); }
        data.AddRange(new byte[6]);
        byte[] body = [0x01, 0x00, 0x2A, 0x12, 0x01, .. data];
        byte[] ret = [.. FutabaProtocol.ReturnHeader, .. body, FutabaProtocol.Checksum(body)];
        Assert.Equal(FutabaProtocol.StatusReturnLength, ret.Length);

        // Garbage, then the echoed request, then the return packet.
        var buffer = new List<byte>([0x00, 0x13, .. FutabaProtocol.StatusRequest(1), .. ret]);
        var packets = new List<FutabaProtocol.Packet>();
        while (FutabaProtocol.Parse(buffer) is var (p, used)) { packets.Add(p); buffer.RemoveRange(0, used); }
        Assert.Equal(2, packets.Count);
        Assert.Equal(0, packets[0].Length); // echo
        Assert.Equal(42, packets[1].Address);
        var s = packets[1].Status();
        Assert.Equal((900, 5, -10, 120, 33, 740), (s.Position, s.ElapsedTime, s.Speed, s.Current, s.Temperature!.Value, s.Voltage));
        Assert.Equal(90, s.PositionDegrees, 12);
        Assert.Equal(7.4, s.Volts, 12);

        // Models without a temperature sensor report voltage at 50–51 and leave 52–53 zero
        // (bytes as read from the bench servos: 63.3°, 13 mA, 9.48 V).
        byte[] bench = [0x79, 0x02, 0, 0, 0, 0, 0x0D, 0, 0xB4, 0x03, 0, 0, 0, 0, 0, 0, 0, 0];
        var b = new FutabaProtocol.Packet(1, 0, 42, 18, 1, bench).Status();
        Assert.Equal(633, b.Position);
        Assert.Equal(13, b.Current);
        Assert.Null(b.Temperature);
        Assert.Equal(9.48, b.Volts, 12);

        // Incomplete packet: nothing yet. Corrupt checksum is skipped.
        Assert.Null(FutabaProtocol.Parse(ret[..^3]));
        var bad = (byte[])ret.Clone();
        bad[^1] ^= 0xFF;
        Assert.Null(FutabaProtocol.Parse(bad));
    }

    [Fact]
    public void DriverReadsStatusThroughLoopbackTransport()
    {
        var transport = new ScriptedTransport();
        var driver = new FutabaRsServoDriver(transport);
        driver.Open();
        driver.SetTorque(1, true);
        driver.Move(1, 450, 20);
        var status = driver.ReadStatus(1);
        Assert.Equal(450, status.Position);
        Assert.Equal(FutabaProtocol.Torque(1, true), transport.Written[0]);
        Assert.Equal(FutabaProtocol.Move(1, 450, 20), transport.Written[1]);
        Assert.Equal(FutabaProtocol.StatusRequest(1), transport.Written[2]);
        driver.Close();
    }
}
