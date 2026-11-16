// Headless controller for bench work and development.
//
//   assist-arm ports                         list serial ports
//   assist-arm status --port COM3            read status of servos 1 and 2 (no motion)
//   assist-arm sensors [--modes]             scan for paired Trigno sensors through the Delsys API
//   assist-arm base                          show what the base station reports about itself
//   assist-arm pair --number 3 [--wait 60]   pair a new sensor as number 3 (then press the sensor's button)
//   assist-arm remove --sensor 3             forget a paired sensor
//   assist-arm identify --sensor 1 [--seconds 5]   flash one sensor's light
//     (all Delsys commands take --license FILE and --verbose)
//   assist-arm run [options]                 calibrate, then control
//     --source synthetic|delsys       (default synthetic)
//     --sensors 1,2                   Trigno pair numbers for flexor and extensor (default 1,2)
//     --sensor-mode "…"               sample mode name for both sensors (default: keep current)
//     --license FILE                  Delsys key/licence JSON (default %APPDATA%\AssistArm\delsys-license.json)
//     --servo mock|COM3|tcp://host:port   (default mock)
//     --mode linear|low|high|highOrLow --threshold 40
//     --stiffness-scaling legacy|cube (default legacy)
//     --goal-rate 6                   goal writes per second
//     --calibrate 8                   seconds of calibration (default 8)
//     --duration 20                   seconds of control (default 20)
//     --log out.csv                   telemetry CSV
//     --params DIR                    folder with the subject's param_eq.txt and param_trq.txt

using System.Globalization;
using AssistArm.Control;
using AssistArm.Delsys;
using AssistArm.Futaba;
using AssistArm.Model;

CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

string command = args.Length > 0 && !args[0].StartsWith("--") ? args[0] : "run";
var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
for (int i = command == "run" && (args.Length == 0 || args[0].StartsWith("--")) ? 0 : 1; i < args.Length; i++)
{
    if (!args[i].StartsWith("--")) continue;
    options[args[i][2..]] = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[++i] : "";
}
string Opt(string key, string fallback = "") => options.TryGetValue(key, out var v) ? v : fallback;
double Num(string key, double fallback) => double.TryParse(Opt(key), NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : fallback;

void Log(string text) => Console.WriteLine(text);

IServoDriver MakeServo(string spec) =>
    spec.Equals("mock", StringComparison.OrdinalIgnoreCase) ? new MockServoDriver() : new FutabaRsServoDriver(ServoTransports.Make(spec));

void PrintSensor(DelsysSensor s)
{
    string battery = s.BatteryPercent is double b ? $", battery {b:F0} %" : "";
    string range = s.OutOfRange ? ", OUT OF RANGE OR OFF" : "";
    Log($"sensor {s.PairNumber}: {s.Name} [{s.Kind}] SID {s.Sid}, firmware {s.Firmware}, mode \"{s.CurrentMode}\", EMG {s.EmgSampleRate:F0} Hz{battery}{range}");
    if (options.ContainsKey("modes")) foreach (var m in s.SampleModes) Log($"    {m}");
}

void PrintStatus(IServoDriver servo, ControlConfiguration config)
{
    foreach (byte id in new[] { config.LeftServoId, config.RightServoId })
    {
        var s = servo.ReadStatus(id);
        string temperature = s.Temperature is short t ? $"  {t} °C" : "";
        Log($"servo {id}: {s.PositionDegrees:F1}°  {s.Current} mA  {s.Volts:F1} V{temperature}");
        if (s.Raw.Length > 0) Log("  raw 42–59: " + string.Join(" ", s.Raw.Select(b => b.ToString("X2"))));
    }
}

DelsysSession OpenDelsys()
{
    string licensePath = Opt("license", DelsysCredentials.DefaultPath);
    var credentials = DelsysCredentials.Load(licensePath)
        ?? throw new DelsysException($"No Delsys licence file at {licensePath}. Create it as {{\"key\": \"…\", \"license\": \"…\"}}.");
    var session = new DelsysSession(credentials);
    if (options.ContainsKey("verbose")) session.Debug += text => Log("  [delsys] " + text);
    session.Open();
    Log($"Base: {session.DeviceName}");
    return session;
}

try
{
    switch (command)
    {
        case "ports":
        {
            var ports = SerialServoTransport.AvailablePorts();
            if (ports.Length == 0) Log("No serial ports.");
            foreach (var p in ports) Log(p);
            return 0;
        }
        case "status":
        {
            var servo = MakeServo(Opt("port", Opt("servo", "mock")));
            servo.Open();
            Log($"Link open: {servo.Name}");
            try { PrintStatus(servo, new ControlConfiguration()); }
            finally { servo.Close(); }
            return 0;
        }
        case "sensors":
        {
            using var session = OpenDelsys();
            Log("Scanning for paired sensors…");
            var sensors = await session.ScanAsync();
            if (sensors.Count == 0) Log("No paired sensors found. Take them out of the dock and wake them.");
            foreach (var s in sensors) PrintSensor(s);
            return 0;
        }
        case "base":
        {
            using var session = OpenDelsys();
            Log($"Sensor slots: {session.SupportedSlots}");
            foreach (var (key, value) in session.BaseInfo) Log($"  {key}: {value}");
            return 0;
        }
        case "pair":
        {
            using var session = OpenDelsys();
            await session.ScanAsync();
            int number = (int)Num("number", 0);
            if (number <= 0) { Log("Give the pair number with --number N."); return 2; }
            double wait = Num("wait", 60);
            Log($"Waiting up to {wait:F0} s for a pair request. Hold the sensor's button until its light signals pairing…");
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(wait));
            if (!await session.PairAsync(number, cancel.Token)) { Log("No sensor asked to pair."); return 1; }
            Log("Paired. Scanning…");
            foreach (var s in await session.ScanAsync()) PrintSensor(s);
            return 0;
        }
        case "remove":
        {
            using var session = OpenDelsys();
            await session.ScanAsync();
            int number = (int)Num("sensor", 0);
            session.Remove(number);
            Log($"Sensor {number} removed.");
            return 0;
        }
        case "identify":
        {
            using var session = OpenDelsys();
            await session.ScanAsync();
            int number = (int)Num("sensor", 0);
            session.Identify(number, true);
            Log($"Sensor {number} should be flashing.");
            await Task.Delay(TimeSpan.FromSeconds(Num("seconds", 5)));
            session.Identify(number, false);
            return 0;
        }
        case "run":
            return await Run();
        default:
            Log($"Unknown command \"{command}\". See the comment at the top of Program.cs for usage.");
            return 2;
    }
}
catch (Exception e)
{
    Console.Error.WriteLine("Error: " + e.Message);
    return 1;
}

async Task<int> Run()
{
    var config = new ControlConfiguration();
    config.Stiffness.Mode = Opt("mode", "highOrLow").ToLowerInvariant() switch
    {
        "linear" => StiffnessMode.Linear, "low" => StiffnessMode.Low, "high" => StiffnessMode.High, _ => StiffnessMode.HighOrLow,
    };
    config.Stiffness.Threshold = Num("threshold", 40);
    config.Stiffness.LegacyScaling = Opt("stiffness-scaling", "legacy") != "cube";
    config.GoalUpdateRate = Num("goal-rate", config.GoalUpdateRate);

    var estimator = options.ContainsKey("params") ? JointEstimator.FromFolder(Opt("params")) : JointEstimator.LegacyDefault();
    var summary = estimator.Summary;
    Log($"Model: rest {summary.AtRest:F1}°, flexor only {summary.PerMuscle[0]:F1}°, extensor only {summary.PerMuscle[1]:F1}°");

    DelsysSession? session = null;
    IEmgSource source;
    if (Opt("source", "synthetic") == "delsys")
    {
        session = OpenDelsys();
        var pairs = Opt("sensors", "1,2").Split(',').Select(s => int.Parse(s.Trim())).ToArray();
        Log("Scanning for paired sensors…");
        await session.ScanAsync();
        string? mode = options.ContainsKey("sensor-mode") ? Opt("sensor-mode") : null;
        source = await session.CreateSourceAsync(pairs[0], pairs[1], mode, mode);
        Log($"Sensors {pairs[0]} (flexor) and {pairs[1]} (extensor), EMG {source.SampleRate:F0} Hz");
    }
    else
    {
        source = new SyntheticEmgSource();
    }

    var servo = MakeServo(Opt("servo", "mock"));
    TelemetryLog? telemetry = null;
    try
    {
        servo.Open();
        Log($"Zeroing servos ({servo.Name})…");
        var zero = ServoSetup.Zero(servo, config);
        config.ZeroLeft = zero.Left.Position;
        config.ZeroRight = zero.Right.Position;
        Log($"Zero: left {zero.Left.PositionDegrees:F1}°, right {zero.Right.PositionDegrees:F1}° ({zero.Left.Volts:F1} V)");

        var pipeline = new QuasiTensionPipeline(source);
        await pipeline.StartAsync(); // hold the stream across calibration and control
        try
        {
            var calibrator = new ActivationCalibrator(pipeline);
            double calibrateSeconds = Num("calibrate", 8);
            Log($"Calibrating for {calibrateSeconds:F1} s: relax, then contract each muscle fully ({source.Name})…");
            await calibrator.StartAsync();
            await Task.Delay(TimeSpan.FromSeconds(calibrateSeconds));
            var range = await calibrator.StopAsync();
            for (int ch = 0; ch < range.ChannelCount; ch++) Log($"  ch{ch + 1}: {range.Minimum[ch]:G3} … {range.Maximum[ch]:G3}");

            var controller = new AssistController(pipeline, servo, estimator, range, config);
            if (options.ContainsKey("log")) telemetry = new TelemetryLog(Opt("log"), pipeline.ChannelCount);
            double nextPrint = 0;
            Exception? failure = null;
            controller.Sample += s =>
            {
                telemetry?.Write(s);
                if (s.Time < nextPrint) return;
                nextPrint = s.Time + 0.5;
                string position = s.StatusLeft is null ? "" : $"  posL={s.StatusLeft.PositionDegrees:F1}°";
                Log($"t={s.Time,6:F2}  u=[{string.Join(" ", s.Activation.Select(a => a.ToString("F2")))}]  eq={s.Estimate.EquilibriumDegrees,6:F1}°  " +
                    $"nstiff={s.Estimate.NormalizedStiffness,5:F1}  comp=0x{s.Compliance:X2}  goalL={s.TargetLeft,5}{position}");
            };
            controller.Error += e => failure = e;
            double duration = Num("duration", 20);
            Log($"Controlling for {duration:F0} s ({config.Stiffness.Mode}, threshold {config.Stiffness.Threshold:F0})…");
            await controller.StartAsync();
            var end = DateTime.UtcNow.AddSeconds(duration);
            while (DateTime.UtcNow < end && failure is null) await Task.Delay(50);
            await controller.StopAsync();
            if (failure is not null) throw failure;
        }
        finally
        {
            await pipeline.StopAsync();
        }
        Log("Done.");
        return 0;
    }
    finally
    {
        telemetry?.Finish();
        servo.Close();
        session?.Dispose();
    }
}
