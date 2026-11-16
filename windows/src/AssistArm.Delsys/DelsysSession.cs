using System.Text.Json;
using Aero.PipeLine;
using AssistArm.Control;
using AssistArm.Signal;
using DelsysAPI.Channels.Trigno;
using DelsysAPI.Components.TrignoRf;
using DelsysAPI.DelsysDevices;
using DelsysAPI.Events;
using DelsysAPI.Exceptions;
using DelsysAPI.Pipelines;
using DelsysAPI.Utils;

namespace AssistArm.Delsys;

public sealed class DelsysException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// The key and licence strings Delsys issues for the API. They are read from a JSON file kept
/// outside the repository: {"key": "...", "license": "..."}.
/// </summary>
public sealed record DelsysCredentials(string Key, string License)
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AssistArm", "delsys-license.json");

    public bool IsComplete => !string.IsNullOrWhiteSpace(Key) && !string.IsNullOrWhiteSpace(License);

    public static DelsysCredentials? Load(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            string key = doc.RootElement.TryGetProperty("key", out var k) ? k.GetString() ?? "" : "";
            string license = doc.RootElement.TryGetProperty("license", out var l) ? l.GetString() ?? "" : "";
            return new DelsysCredentials(key, license);
        }
        catch (Exception e)
        {
            throw new DelsysException($"Cannot read the Delsys licence file {path}: {e.Message}", e);
        }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(new { key = Key, license = License }, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// <summary>A paired sensor found by a scan.</summary>
/// <param name="PairNumber">The number the sensor was paired as (the "sensor 1, sensor 2" of the Trigno utility).</param>
/// <param name="Sid">The sensor's serial ID.</param>
/// <param name="Kind">The API's class for this sensor model, e.g. "Avanti" or "StandardLegacy".</param>
/// <param name="EmgSampleRate">EMG rate in the current mode, or 0 if the current mode has no EMG channel.</param>
/// <param name="BatteryPercent">Charge level as the sensor last reported it, or null if it has not.</param>
public sealed record DelsysSensor(int PairNumber, int Sid, string Name, string Kind, string Firmware, string CurrentMode,
                                  IReadOnlyList<string> SampleModes, double EmgSampleRate, double? BatteryPercent, bool OutOfRange)
{
    public string Summary =>
        $"{PairNumber}: {Name}" + (EmgSampleRate > 0 ? $" · EMG {EmgSampleRate:F0} Hz" : " · no EMG in this mode") +
        (BatteryPercent is double b ? $" · {b:F0} %" : "") + (OutOfRange ? " · out of range or off" : "");
}

/// <summary>
/// One connection to a Trigno base through the Delsys API: load the base, scan for paired
/// sensors, and build an <see cref="IEmgSource"/> for two of them. The API talks to the base
/// over USB itself; the Trigno Control Utility must not be running at the same time.
/// </summary>
public sealed class DelsysSession : IDisposable
{
    private readonly DelsysCredentials _credentials;
    private Pipeline? _pipeline;
    private int _pipelineIndex = -1;

    /// <summary>Diagnostic text from the API (it is chatty; show it in a log, not an alert).</summary>
    public event Action<string>? Debug;

    public string DeviceName { get; private set; } = "";
    /// <summary>What the base reports about itself (hardware name, serial, firmware…), for display.</summary>
    public IReadOnlyDictionary<string, string> BaseInfo { get; private set; } = new Dictionary<string, string>();
    /// <summary>How many sensors the base can pair, or 0 before it is open.</summary>
    public int SupportedSlots { get; private set; }
    public bool IsOpen => _pipeline is not null;
    internal Pipeline Pipeline => _pipeline ?? throw new DelsysException("The Trigno base is not connected.");

    public DelsysSession(DelsysCredentials credentials)
    {
        if (!credentials.IsComplete)
            throw new DelsysException("The Delsys API key and licence are missing. Enter the strings Delsys issued to your lab.");
        _credentials = credentials;
    }

    /// <summary>Find the base on USB and create the API pipeline.</summary>
    public void Open()
    {
        if (_pipeline is not null) return;
        try
        {
            var creator = new DeviceSourcePortable(_credentials.Key, _credentials.License);
            creator.SetDebugOutputStream((format, args) =>
            {
                string text;
                try { text = args is { Length: > 0 } ? string.Format(format, args) : format; }
                catch (FormatException) { text = format; }
                Debug?.Invoke(text);
            });
            var device = creator.GetDataSource([SourceType.TRIGNO_RF]);
            device.Key = _credentials.Key;
            device.License = _credentials.License;
            var controller = PipelineController.Instance;
            controller.AddPipeline(device);
            _pipelineIndex = controller.PipelineIds.Count - 1;
            _pipeline = controller.PipelineIds[_pipelineIndex];
        }
        catch (BaseDetectionFailedException e)
        {
            throw new DelsysException("No Trigno base found. Check its USB and power connections, and close the Trigno Control Utility.", e);
        }
        catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or PlatformNotSupportedException or TypeInitializationException)
        {
            throw new DelsysException($"The Delsys API could not load its USB driver on this computer: {(e.InnerException ?? e).Message}", e);
        }
        _pipeline.SetActiveDataSources(SourceType.TRIGNO_RF);
        DeviceName = DescribeDevice(_pipeline);
        try { BaseInfo = new Dictionary<string, string>(_pipeline.DataSourceInfo[SourceType.TRIGNO_RF][0]); }
        catch (Exception) { /* purely informational */ }
        try { SupportedSlots = _pipeline.TrignoRfManager.SupportedNumberOfSlots(); }
        catch (Exception) { /* purely informational */ }
    }

    private static string DescribeDevice(Pipeline pipeline)
    {
        try
        {
            var info = pipeline.DataSourceInfo[SourceType.TRIGNO_RF][0];
            string name = info.TryGetValue("Hardware Name", out var n) ? n : "Trigno";
            if (info.TryGetValue("Centro ID", out var centro)) return $"{name} {centro}";
            if (info.TryGetValue("Dongle ID", out var dongle)) return $"{name} {dongle}";
            int underscore = name.IndexOf('_');
            return name.Contains("base", StringComparison.OrdinalIgnoreCase) && underscore >= 0
                ? $"Trigno Base Station {name[(underscore + 1)..]}" : name;
        }
        catch (Exception) { return "Trigno"; }
    }

    internal bool IsCentro
    {
        get
        {
            try { return Pipeline.DataSourceInfo[SourceType.TRIGNO_RF][0].ContainsKey("Centro ID"); }
            catch (Exception) { return false; }
        }
    }

    /// <summary>Scan for sensors already paired with the base. Sensors must be out of the dock and awake.</summary>
    public async Task<IReadOnlyList<DelsysSensor>> ScanAsync(TimeSpan? timeout = null)
    {
        var pipeline = Pipeline;
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnScanComplete(object? sender, ComponentScanCompletedEventArgs e)
        {
            // The API reports intermediate steps of a recovery or re-pairing sequence first.
            if (e.IsRecovering || e.RepairSensors) return;
            done.TrySetResult(true);
        }
        pipeline.TrignoRfManager.ComponentScanComplete += OnScanComplete;
        try
        {
            await pipeline.Scan().ConfigureAwait(false);
            var finished = await Task.WhenAny(done.Task, Task.Delay(timeout ?? TimeSpan.FromSeconds(30))).ConfigureAwait(false);
            if (finished != done.Task) throw new DelsysException("Timed out scanning for Trigno sensors.");
        }
        finally
        {
            pipeline.TrignoRfManager.ComponentScanComplete -= OnScanComplete;
        }
        return Sensors;
    }

    public IReadOnlyList<DelsysSensor> Sensors =>
        Pipeline.TrignoRfManager.Components.Select(Describe).OrderBy(s => s.PairNumber).ToList();

    private static DelsysSensor Describe(SensorTrignoRf sensor)
    {
        var modes = sensor.Configuration?.SampleModes ?? [];
        string mode = sensor.Configuration?.ModeString ?? "";
        string name = string.IsNullOrWhiteSpace(sensor.FriendlyName) ? sensor.InternalName ?? "Sensor" : sensor.FriendlyName;
        string kind = sensor.GetType().Name;
        if (kind.StartsWith("Sensor", StringComparison.Ordinal)) kind = kind[6..];
        var properties = sensor.Properties;
        double? battery = properties is not null && properties.BatteryPercent > 0 ? properties.BatteryPercent : null;
        return new DelsysSensor(sensor.PairNumber, properties?.Sid ?? 0, name, kind, properties?.Fw ?? "", mode, modes,
                                EmgChannel(sensor)?.SampleRate ?? 0, battery, properties?.OutOfRangeOrOff ?? false);
    }

    /// <summary>
    /// The pipeline can only be scanned or re-paired while it is not armed. Stop and disarm it
    /// (after streaming) so sensors can be managed again.
    /// </summary>
    public async Task ReleaseAsync()
    {
        var pipeline = Pipeline;
        if (pipeline.CurrentState == Pipeline.ProcessState.Running) await pipeline.Stop().ConfigureAwait(false);
        if (pipeline.CurrentState is Pipeline.ProcessState.Armed or Pipeline.ProcessState.Finished
            or Pipeline.ProcessState.InputsConfigured or Pipeline.ProcessState.OutputsConfigured)
            await pipeline.DisarmPipeline().ConfigureAwait(false);
    }

    /// <summary>
    /// Pair a new sensor with the base as <paramref name="pairNumber"/>. The API waits for a
    /// pair request from the sensor: hold the sensor's button (or tap it on the base's pairing
    /// mark, depending on the model) until its light signals pairing. Returns false if no
    /// sensor asked to pair before <paramref name="cancel"/> fired. Scan afterwards.
    /// </summary>
    public async Task<bool> PairAsync(int pairNumber, CancellationToken cancel)
    {
        var manager = Pipeline.TrignoRfManager;
        if (SupportedSlots > 0 && manager.Components.Count >= SupportedSlots)
            throw new DelsysException($"The base already has {manager.Components.Count} sensors paired, which is all it supports.");
        if (manager.Components.Any(c => c.PairNumber == pairNumber))
            throw new DelsysException($"A sensor is already paired as number {pairNumber}. Remove it first or choose another number.");
        try
        {
            return await manager.AddTrignoComponent(cancel, pairNumber, true).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { manager.CancelledPairingCleanup(); } catch (Exception) { /* nothing was half-paired */ }
            return false;
        }
    }

    /// <summary>Forget a paired sensor.</summary>
    public void Remove(int pairNumber)
    {
        if (!Pipeline.TrignoRfManager.RemoveTrignoComponent(Find(pairNumber)))
            throw new DelsysException($"The base did not remove sensor {pairNumber}.");
    }

    /// <summary>Make a sensor flash its light so it can be told apart from the others, or stop the flashing.</summary>
    public void Identify(int pairNumber, bool on)
    {
        var manager = Pipeline.TrignoRfManager;
        if (!on) { manager.StopSensorIdentification(); return; }
        int sid = Find(pairNumber).Properties?.Sid ?? 0;
        if (!manager.SensorIdentification(sid))
            throw new DelsysException($"Sensor {pairNumber} did not acknowledge the identify request.");
    }

    internal static ChannelTrigno? EmgChannel(SensorTrignoRf sensor) =>
        sensor.TrignoChannels?.FirstOrDefault(c => c.Type == ChannelTypes.EMG);

    internal SensorTrignoRf Find(int pairNumber) =>
        Pipeline.TrignoRfManager.Components.FirstOrDefault(c => c.PairNumber == pairNumber)
        ?? throw new DelsysException($"Sensor {pairNumber} was not found. Paired sensors: " +
                                     (Sensors.Count == 0 ? "none" : string.Join(", ", Sensors.Select(s => s.PairNumber))) + ".");

    /// <summary>
    /// Select the two sensors used as the joint's muscles (and only those) and return a source
    /// for their EMG channels. A mode picks that sensor's sample mode by name; null keeps the
    /// sensor's current mode.
    /// </summary>
    public async Task<DelsysEmgSource> CreateSourceAsync(int flexorPair, int extensorPair, string? flexorMode = null, string? extensorMode = null)
    {
        if (flexorPair == extensorPair) throw new DelsysException("Flexor and extensor must be two different sensors.");
        await ReleaseAsync().ConfigureAwait(false);
        var pipeline = Pipeline;
        var modes = new[] { flexorMode, extensorMode };        var chosen = new[] { Find(flexorPair), Find(extensorPair) };
        foreach (var sensor in pipeline.TrignoRfManager.Components)
        {
            bool wanted = chosen.Contains(sensor);
            if (wanted && sensor.State != SelectionState.Allocated)
                await pipeline.TrignoRfManager.SelectComponentAsync(sensor).ConfigureAwait(false);
            else if (!wanted && sensor.State == SelectionState.Allocated)
                await pipeline.TrignoRfManager.DeselectComponentAsync(sensor).ConfigureAwait(false);
        }
        var channels = new ChannelTrigno[2];
        for (int i = 0; i < 2; i++)
        {
            var sensor = chosen[i];
            string? mode = string.IsNullOrWhiteSpace(modes[i]) ? null : modes[i];
            if (mode is not null)
            {
                if (!(sensor.Configuration?.SampleModes ?? []).Contains(mode))
                    throw new DelsysException($"Sensor {sensor.PairNumber} has no sample mode \"{mode}\".");
                sensor.SelectSampleMode(mode);
            }
            channels[i] = EmgChannel(sensor)
                ?? throw new DelsysException($"Sensor {sensor.PairNumber} has no EMG channel in mode \"{sensor.Configuration?.ModeString}\". Choose a mode with EMG.");
        }
        if (Math.Abs(channels[0].SampleRate - channels[1].SampleRate) > 0.5)
            throw new DelsysException($"The two sensors sample EMG at different rates ({channels[0].SampleRate:F0} and {channels[1].SampleRate:F0} Hz). Use the same mode for both.");
        return new DelsysEmgSource(this, channels);
    }

    public void Dispose()
    {
        var pipeline = _pipeline;
        _pipeline = null;
        if (pipeline is null) return;
        try
        {
            _pipeline = pipeline;
            try { ReleaseAsync().GetAwaiter().GetResult(); }
            finally { _pipeline = null; }
            int index = PipelineController.Instance.PipelineIds.IndexOf(pipeline);
            if (index >= 0) PipelineController.Instance.RemovePipeline(index);
        }
        catch (Exception e)
        {
            Debug?.Invoke($"Closing the Delsys pipeline: {e.Message}");
        }
    }
}

/// <summary>EMG of two Trigno sensors, streamed through the Delsys API, in volts.</summary>
public sealed class DelsysEmgSource : IEmgSource
{
    private readonly DelsysSession _session;
    private readonly Guid[] _channelIds;
    private readonly double[] _toVolts;
    private readonly List<double>[] _pending = [[], []];
    private readonly object _gate = new();
    private Action<EmgBlock>? _sink;
    private long _index;
    private bool _configured;
    private bool _subscribed;

    public string Name { get; }
    public int ChannelCount => 2;
    public double SampleRate { get; }
    /// <summary>Frames the API hands over per callback. 1 gives the lowest latency.</summary>
    public int FrameThroughput { get; set; } = 1;
    /// <summary>Sensor packets the base reported as dropped since the last start.</summary>
    public long DroppedPackets { get; private set; }

    internal DelsysEmgSource(DelsysSession session, ChannelTrigno[] channels)
    {
        _session = session;
        _channelIds = channels.Select(c => c.Id).ToArray();
        // The pipeline expects volts, as the Trigno SDK delivers them.
        _toVolts = channels.Select(c => c.Unit == Units.MILLIVOLTS ? 1e-3 : 1.0).ToArray();
        SampleRate = channels[0].SampleRate;
        Name = session.DeviceName;
    }

    public async Task StartAsync(Action<EmgBlock> sink)
    {
        var pipeline = _session.Pipeline;
        lock (_gate)
        {
            _sink = sink;
            _index = 0;
            DroppedPackets = 0;
            foreach (var list in _pending) list.Clear();
        }
        if (!_subscribed)
        {
            pipeline.CollectionDataReady += OnData;
            _subscribed = true;
        }
        try
        {
            if (!_configured)
            {
                new DataLine(pipeline).ConfigurePipeline([], false, false, FrameThroughput, _session.IsCentro);
                _configured = true;
            }
            if (!await pipeline.Start().ConfigureAwait(false))
                throw new DelsysException($"The Trigno base refused to start streaming (pipeline state: {pipeline.CurrentState}).");
        }
        catch (Exception e) when (e is not DelsysException)
        {
            throw new DelsysException($"Could not start the Trigno stream: {e.Message}", e);
        }
    }

    public async Task StopAsync()
    {
        lock (_gate) _sink = null;
        var pipeline = _session.IsOpen ? _session.Pipeline : null;
        if (pipeline is null) return;
        try
        {
            if (pipeline.CurrentState == Pipeline.ProcessState.Running) await pipeline.Stop().ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The base may have been unplugged; there is nothing left to stop.
        }
    }

    private void OnData(object? sender, ComponentDataReadyEventArgs e)
    {
        EmgBlock? block = null;
        Action<EmgBlock>? sink;
        lock (_gate)
        {
            sink = _sink;
            if (sink is null || e.Data is null) return;
            foreach (var frame in e.Data)
            {
                if (frame?.SensorData is null) continue;
                foreach (var sensor in frame.SensorData)
                {
                    if (sensor?.ChannelData is null) continue;
                    bool ours = false;
                    foreach (var channel in sensor.ChannelData)
                    {
                        int column = Array.IndexOf(_channelIds, channel.Id);
                        if (column < 0 || channel.Data is null) continue;
                        ours = true;
                        _pending[column].AddRange(channel.Data);
                    }
                    if (ours && sensor.IsDroppedPacket) DroppedPackets++;
                }
            }
            // Emit only complete rows, so the two muscles stay sample-aligned.
            int rows = Math.Min(_pending[0].Count, _pending[1].Count);
            if (rows == 0) return;
            var samples = new float[rows * 2];
            for (int r = 0; r < rows; r++)
            {
                samples[r * 2] = (float)(_pending[0][r] * _toVolts[0]);
                samples[r * 2 + 1] = (float)(_pending[1][r] * _toVolts[1]);
            }
            _pending[0].RemoveRange(0, rows);
            _pending[1].RemoveRange(0, rows);
            block = new EmgBlock(SampleRate, 2, samples, _index);
            _index += rows;
        }
        sink(block);
    }
}
