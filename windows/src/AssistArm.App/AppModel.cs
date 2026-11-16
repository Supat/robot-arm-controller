using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Threading;
using AssistArm.Control;
using AssistArm.Delsys;
using AssistArm.Futaba;
using AssistArm.Model;
using AssistArm.Signal;

namespace AssistArm.App;

public sealed record LogEntry(DateTime Time, string Text, bool IsError)
{
    public string TimeText => Time.ToString("HH:mm:ss");
}

[JsonConverter(typeof(JsonStringEnumConverter<EmgSourceKind>))]
public enum EmgSourceKind { Delsys, Synthetic }

[JsonConverter(typeof(JsonStringEnumConverter<ServoKind>))]
public enum ServoKind { Serial, Tcp, Mock }

public enum Phase { Disconnected, Connecting, Connected }

/// <summary>What is saved between launches (%APPDATA%\AssistArm\settings.json).</summary>
public sealed class AppSettings
{
    public EmgSourceKind EmgKind { get; set; } = EmgSourceKind.Delsys;
    public int FlexorSensor { get; set; } = 1;
    public int ExtensorSensor { get; set; } = 2;
    /// <summary>Sample mode names; empty keeps the sensor's current mode.</summary>
    public string FlexorMode { get; set; } = "";
    public string ExtensorMode { get; set; } = "";
    public ServoKind ServoKind { get; set; } = ServoKind.Serial;
    public string SerialPort { get; set; } = "";
    public string BridgeHost { get; set; } = "192.168.1.60";
    public int BridgePort { get; set; } = 5000;
    public ControlConfiguration Configuration { get; set; } = new();
    public ActivationRange? Range { get; set; }
    public bool RecordTelemetry { get; set; } = true;
    public double PlotWindow { get; set; } = 5;
    /// <summary>Paths of the subject's parameter files; empty means the built-in legacy set.</summary>
    public string ParamEqPath { get; set; } = "";
    public string ParamTrqPath { get; set; } = "";

    public static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AssistArm", "settings.json");

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new AppSettings();
        }
        catch (Exception)
        {
            // A damaged settings file should not stop the app from starting.
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception)
        {
            // Settings are a convenience; failing to save them is not worth an alert.
        }
    }
}

/// <summary>Everything the window binds to. Hardware and the control loop are owned here.</summary>
public sealed class AppModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>An error the window should show in a dialog.</summary>
    public event Action<string>? Alert;
    /// <summary>The plot buffers were created, resized or dropped.</summary>
    public event Action? BuffersChanged;

    private readonly Dispatcher _dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
    private readonly AppSettings _settings = AppSettings.Load();

    private void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void RaiseState()
    {
        foreach (var name in new[]
                 {
                     nameof(EmgConnected), nameof(ServoConnected), nameof(EmgDisconnected), nameof(ServoDisconnected), nameof(IsBusy),
                     nameof(CanCalibrate), nameof(CanControl), nameof(CanConnectEmg), nameof(CanConnectServo), nameof(CanDisconnectEmg),
                     nameof(CanDisconnectServo), nameof(NotControlling), nameof(EmgButtonText), nameof(ServoButtonText), nameof(IsCalibrating),
                     nameof(IsControlling), nameof(NotCalibrating), nameof(CalibrateText), nameof(HasRange), nameof(RangeText), nameof(ControlHint),
                     nameof(EmgDetail), nameof(ServoDetail), nameof(WindowTitle), nameof(IsDelsys), nameof(IsSerial), nameof(IsTcp),
                     nameof(ShowThreshold), nameof(ModeFooter), nameof(ModelName), nameof(ModelFooter), nameof(UsesCustomParameters),
                     nameof(BaseOpen), nameof(BaseButtonText), nameof(BaseDetail), nameof(CanToggleBase), nameof(CanManageSensors),
                     nameof(CanEditLicense), nameof(IsPairing), nameof(NotPairing), nameof(PairStatus), nameof(CanChooseSensors),
                 })
            Raise(name);
    }

    private void SaveSettings() => _settings.Save();

    // MARK: Persisted settings

    public EmgSourceKind[] EmgKinds { get; } = [EmgSourceKind.Delsys, EmgSourceKind.Synthetic];
    public ServoKind[] ServoKinds { get; } = [ServoKind.Serial, ServoKind.Tcp, ServoKind.Mock];
    public int[] SensorNumbers { get; } = Enumerable.Range(1, 16).ToArray();
    public StiffnessMode[] StiffnessModes { get; } = [StiffnessMode.Linear, StiffnessMode.Low, StiffnessMode.High, StiffnessMode.HighOrLow];
    public double[] PlotWindows { get; } = [2, 5, 10, 20];

    public EmgSourceKind EmgKind { get => _settings.EmgKind; set { _settings.EmgKind = value; SaveSettings(); Raise(); RaiseState(); } }
    public int FlexorSensor { get => _settings.FlexorSensor; set { _settings.FlexorSensor = value; SaveSettings(); Raise(); RefreshModeLists(); } }
    public int ExtensorSensor { get => _settings.ExtensorSensor; set { _settings.ExtensorSensor = value; SaveSettings(); Raise(); RefreshModeLists(); } }
    public string FlexorMode { get => _settings.FlexorMode; set { _settings.FlexorMode = value ?? ""; SaveSettings(); Raise(); } }
    public string ExtensorMode { get => _settings.ExtensorMode; set { _settings.ExtensorMode = value ?? ""; SaveSettings(); Raise(); } }
    public ServoKind ServoKind { get => _settings.ServoKind; set { _settings.ServoKind = value; SaveSettings(); Raise(); RaiseState(); } }
    public string SerialPort { get => _settings.SerialPort; set { _settings.SerialPort = value ?? ""; SaveSettings(); Raise(); RaiseState(); } }
    public string BridgeHost { get => _settings.BridgeHost; set { _settings.BridgeHost = value; SaveSettings(); Raise(); } }
    public int BridgePort { get => _settings.BridgePort; set { _settings.BridgePort = value; SaveSettings(); Raise(); } }
    public bool RecordTelemetry { get => _settings.RecordTelemetry; set { _settings.RecordTelemetry = value; SaveSettings(); Raise(); } }

    public double PlotWindow
    {
        get => _settings.PlotWindow;
        set { _settings.PlotWindow = value; SaveSettings(); Raise(); ResizeBuffers(); }
    }

    public ControlConfiguration Configuration => _settings.Configuration;

    /// <summary>Call after changing anything inside <see cref="Configuration"/>.</summary>
    private void ConfigurationChanged([CallerMemberName] string? name = null)
    {
        SaveSettings();
        _controller?.Update(Configuration);
        Raise(name);
        RaiseState();
    }

    public byte LeftServoId { get => Configuration.LeftServoId; set { Configuration.LeftServoId = value; ConfigurationChanged(); } }
    public byte RightServoId { get => Configuration.RightServoId; set { Configuration.RightServoId = value; ConfigurationChanged(); } }
    public StiffnessMode StiffnessMode { get => Configuration.Stiffness.Mode; set { Configuration.Stiffness.Mode = value; ConfigurationChanged(); } }
    public double Threshold { get => Configuration.Stiffness.Threshold; set { Configuration.Stiffness.Threshold = Math.Round(value); ConfigurationChanged(); Raise(nameof(ThresholdText)); } }
    public string ThresholdText => $"Threshold {(int)Configuration.Stiffness.Threshold}";
    public double AngleLimitDegrees { get => Configuration.AngleLimitDegrees; set { Configuration.AngleLimitDegrees = value; ConfigurationChanged(); BuffersChanged?.Invoke(); } }
    public double UnitsPerDegree { get => Configuration.UnitsPerDegree; set { Configuration.UnitsPerDegree = value; ConfigurationChanged(); } }
    public double UpdateRate { get => Configuration.UpdateRate; set { Configuration.UpdateRate = value; ConfigurationChanged(); } }
    public double GoalUpdateRate { get => Configuration.GoalUpdateRate; set { Configuration.GoalUpdateRate = value; ConfigurationChanged(); } }
    public byte MaxTorquePercent { get => Configuration.MaxTorquePercent; set { Configuration.MaxTorquePercent = value; ConfigurationChanged(); } }
    public bool MirrorRight { get => Configuration.MirrorRight; set { Configuration.MirrorRight = value; ConfigurationChanged(); } }
    public bool LegacyScaling { get => Configuration.Stiffness.LegacyScaling; set { Configuration.Stiffness.LegacyScaling = value; ConfigurationChanged(); } }

    public ActivationRange? Range
    {
        get => _settings.Range;
        private set
        {
            _settings.Range = value;
            SaveSettings();
            if (value is not null) _controller?.Update(value);
            Raise();
            RaiseState();
            BuffersChanged?.Invoke();
        }
    }

    // MARK: Delsys licence (kept in its own file, outside the settings and the repository)

    private string _delsysKey = "";
    private string _delsysLicense = "";
    public string DelsysKey { get => _delsysKey; set { _delsysKey = value ?? ""; Raise(); } }
    public string DelsysLicense { get => _delsysLicense; set { _delsysLicense = value ?? ""; Raise(); } }
    public string LicensePath => DelsysCredentials.DefaultPath;

    public void SaveLicense()
    {
        try
        {
            new DelsysCredentials(DelsysKey.Trim(), DelsysLicense.Trim()).Save();
            Info($"Delsys licence saved to {LicensePath}");
        }
        catch (Exception e) { Fail(e); }
    }

    // MARK: Live state

    private Phase _emgPhase = Phase.Disconnected, _servoPhase = Phase.Disconnected;
    private bool _isCalibrating, _isControlling, _isSwitching;
    private double _calibrationElapsed;
    private ActivationRange? _liveRange;
    private ServoSetup.ZeroResult? _zero;
    private string _sourceName = "", _sourceDetail = "", _servoName = "";
    private string? _currentRecording;
    private volatile ControlSample? _latest;

    public ObservableCollection<LogEntry> Log { get; } = [];
    public ObservableCollection<string> SerialPorts { get; } = [];
    /// <summary>Sensors paired with the base, as of the last scan.</summary>
    public ObservableCollection<DelsysSensor> Sensors { get; } = [];
    public ObservableCollection<string> FlexorModes { get; } = [];
    public ObservableCollection<string> ExtensorModes { get; } = [];

    private bool _baseOpen, _baseBusy, _isPairing;
    private string _pairStatus = "";
    private string _pairNumberText = "";
    private DelsysSensor? _selectedSensor;
    private CancellationTokenSource? _pairCancel;
    private int? _identifying;

    public DelsysSensor? SelectedSensor { get => _selectedSensor; set { _selectedSensor = value; Raise(); } }
    public string PairNumberText { get => _pairNumberText; set { _pairNumberText = value ?? ""; Raise(); } }
    public bool BaseOpen => _baseOpen;
    public bool IsPairing => _isPairing;
    public bool NotPairing => !_isPairing;
    public string PairStatus => _pairStatus;
    public bool CanToggleBase => !_baseBusy && _emgPhase != Phase.Connecting && !IsBusy;
    /// <summary>Sensors can be scanned, paired, removed and identified while the base is open and not streaming.</summary>
    public bool CanManageSensors => _baseOpen && !_baseBusy && _emgPhase == Phase.Disconnected;
    public bool CanChooseSensors => _emgPhase == Phase.Disconnected;
    public bool CanEditLicense => !_baseOpen && !_baseBusy;
    public string BaseButtonText => _baseBusy && !_baseOpen ? "Opening…" : _baseOpen ? "Close base" : "Open base";

    public string BaseDetail
    {
        get
        {
            if (!_baseOpen || _session is not { } session) return "The Trigno base connects to this PC by USB. No Delsys program needs to be running; close the Trigno Control Utility and Trigno Discover, because only one program can use the base.";
            string firmware = session.BaseInfo.FirstOrDefault(kv => kv.Key.Contains("firmware", StringComparison.OrdinalIgnoreCase)).Value ?? "";
            return $"{session.DeviceName}" + (firmware.Length > 0 ? $" · firmware {firmware}" : "") +
                   $" · {Sensors.Count} of {session.SupportedSlots} sensor slots paired";
        }
    }

    private DelsysSession? _session;
    private IEmgSource? _source;
    private QuasiTensionPipeline? _pipeline;
    private ActivationCalibrator? _calibrator;
    private IServoDriver? _servo;
    private AssistController? _controller;
    private TelemetryLog? _telemetry;
    private DispatcherTimer? _calibrationTimer;
    private JointEstimator _estimator;

    public PlotBuffers? Buffers { get; private set; }
    public ControlSample? Latest => _latest;
    public JointEstimator Estimator => _estimator;

    public Phase EmgPhase => _emgPhase;
    public Phase ServoPhase => _servoPhase;
    public bool EmgConnected => _emgPhase == Phase.Connected;
    public bool ServoConnected => _servoPhase == Phase.Connected;
    public bool EmgDisconnected => _emgPhase == Phase.Disconnected;
    public bool ServoDisconnected => _servoPhase == Phase.Disconnected;
    public bool IsCalibrating => _isCalibrating;
    public bool IsControlling => _isControlling;
    public bool NotCalibrating => !_isCalibrating;
    public bool NotControlling => !_isControlling;
    public bool IsBusy => _isCalibrating || _isControlling;
    /// <summary>Data is flowing into the plot buffers, so the plots should redraw.</summary>
    public bool IsStreaming => EmgConnected;
    public bool CanCalibrate => EmgConnected && !_isControlling && !_isSwitching;
    public bool CanControl => EmgConnected && ServoConnected && Range is not null && !_isCalibrating && !_isSwitching;
    public bool CanConnectEmg => _emgPhase == Phase.Disconnected;
    public bool CanDisconnectEmg => EmgConnected && !IsBusy;
    public bool CanConnectServo => _servoPhase == Phase.Disconnected && (ServoKind != ServoKind.Serial || SerialPort.Length > 0);
    public bool CanDisconnectServo => ServoConnected && !_isControlling;
    public bool IsDelsys => EmgKind == EmgSourceKind.Delsys;
    public bool IsSerial => ServoKind == ServoKind.Serial;
    public bool IsTcp => ServoKind == ServoKind.Tcp;
    public bool HasRange => Range is not null || _liveRange is not null;
    public bool ShowThreshold => StiffnessMode is StiffnessMode.HighOrLow or StiffnessMode.Linear;
    public bool UsesCustomParameters => _settings.ParamEqPath.Length > 0 || _settings.ParamTrqPath.Length > 0;

    public string EmgButtonText => (_emgPhase, IsDelsys) switch
    {
        (Phase.Connecting, _) => "Connecting…",
        (Phase.Connected, true) => "Stop streaming",
        (Phase.Connected, false) => "Disconnect",
        (_, true) => "Start streaming",
        _ => "Connect",
    };
    public string ServoButtonText => _servoPhase switch { Phase.Connecting => "Zeroing…", Phase.Connected => "Disconnect", _ => "Connect & zero" };
    public string CalibrateText => _isCalibrating ? $"Stop ({_calibrationElapsed:F0} s)" : "Calibrate";
    public string WindowTitle => EmgConnected ? $"Assist Arm — {_sourceName}" : "Assist Arm — not connected";
    public string EmgDetail => EmgConnected ? _sourceDetail : "";

    public string ServoDetail
    {
        get
        {
            if (_zero is null) return "Futaba RS servos at 115200 bps. Connect drives both to 0° and records the resting angles.";
            string temperature = _zero.Left.Temperature is short t ? $" · {t} °C" : "";
            return $"Zero: L {_zero.Left.PositionDegrees:F1}°, R {_zero.Right.PositionDegrees:F1}° · {_zero.Left.Volts:F1} V{temperature}";
        }
    }

    public string RangeText
    {
        get
        {
            var r = _isCalibrating ? _liveRange : Range;
            if (r is null) return "";
            string[] names = ["Flexor", "Extensor"];
            return string.Join("\n", Enumerable.Range(0, r.ChannelCount).Select(ch =>
                $"{(ch < names.Length ? names[ch] : $"Channel {ch + 1}")}:  {r.Minimum[ch]:G3} … {r.Maximum[ch]:G3}"));
        }
    }

    public string ControlHint =>
        !CanControl && !_isControlling ? "Needs an EMG source, a servo link and a calibrated range."
        : _currentRecording is not null ? $"Recording {Path.GetFileName(_currentRecording)}" : "";

    public string ModeFooter => StiffnessMode switch
    {
        StiffnessMode.Linear => "Servo compliance follows joint stiffness from the threshold up to 100.",
        StiffnessMode.Low => "Servos stay soft (compliance 0xFF).",
        StiffnessMode.High => "Servos stay stiff (compliance 0x32).",
        _ => "Soft below the threshold, stiff at or above it, like the legacy demo.",
    };

    public string ModelName => UsesCustomParameters
        ? Path.GetFileName(Path.GetDirectoryName(_settings.ParamEqPath) ?? "") : "Built-in (legacy demo)";

    public string ModelFooter
    {
        get
        {
            var s = _estimator.Summary;
            return $"Subject's param_eq.txt and param_trq.txt. Equilibrium at rest {s.AtRest:F1}°, flexor only {s.PerMuscle[0]:F1}°, extensor only {s.PerMuscle[1]:F1}°.";
        }
    }

    public static string RecordingsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "AssistArm", "Recordings");

    public AppModel()
    {
        _estimator = JointEstimator.LegacyDefault();
        if (UsesCustomParameters)
        {
            try { _estimator = JointEstimator.FromFiles(_settings.ParamEqPath, _settings.ParamTrqPath); }
            catch (Exception e)
            {
                _settings.ParamEqPath = _settings.ParamTrqPath = "";
                Info($"Saved model parameters could not be loaded ({e.Message}); using the built-in set.", isError: true);
            }
        }
        // Zero offsets are per power-up, not per launch.
        Configuration.ZeroLeft = 0;
        Configuration.ZeroRight = 0;
        try
        {
            if (DelsysCredentials.Load() is { } saved) { _delsysKey = saved.Key; _delsysLicense = saved.License; }
        }
        catch (Exception e) { Info(e.Message, isError: true); }
        RefreshSerialPorts();
    }

    // MARK: EMG source

    public async Task ConnectEmgAsync()
    {
        if (_emgPhase != Phase.Disconnected) return;
        _emgPhase = Phase.Connecting;
        RaiseState();
        try
        {
            IEmgSource source;
            if (EmgKind == EmgSourceKind.Synthetic)
            {
                source = new SyntheticEmgSource();
                _sourceDetail = "Two simulated muscles that take turns contracting.";
            }
            else
            {
                if (!_baseOpen)
                {
                    _emgPhase = Phase.Disconnected;
                    await OpenBaseAsync();
                    if (!_baseOpen) { RaiseState(); return; }
                    _emgPhase = Phase.Connecting;
                    RaiseState();
                }
                var session = _session!;
                int flexor = FlexorSensor, extensor = ExtensorSensor;
                string flexorMode = FlexorMode.Trim(), extensorMode = ExtensorMode.Trim();
                // The API blocks while it talks to the base, so keep it off the UI thread.
                source = await Task.Run(() => session.CreateSourceAsync(flexor, extensor, flexorMode, extensorMode));
                ShowSensors(session.Sensors);
                _sourceDetail = $"Streaming sensors {flexor} (flexor) and {extensor} (extensor) · EMG {source.SampleRate:F0} Hz";
                Info($"{session.DeviceName}: sensors {flexor} (flexor) and {extensor} (extensor), {source.SampleRate:F0} Hz");
            }
            _source = source;
            _sourceName = source.Name;
            var pipeline = new QuasiTensionPipeline(source);
            _pipeline = pipeline;
            var buffers = new PlotBuffers(source.ChannelCount, source.SampleRate, pipeline.OutputRate, Configuration.UpdateRate, PlotWindow);
            Buffers = buffers;
            pipeline.AddRawSink(buffers.Emg.Push);
            pipeline.AddQuasiTensionSink(sample =>
            {
                // Plot normalised activation once a range exists, raw quasi-tension before.
                var range = _settings.Range;
                var values = range is not null && range.ChannelCount == sample.Values.Length ? range.Normalize(sample.Values) : sample.Values;
                Span<float> row = stackalloc float[values.Length];
                for (int i = 0; i < values.Length; i++) row[i] = (float)values[i];
                buffers.Activation.Push(row);
            });
            _calibrator = new ActivationCalibrator(pipeline);
            _controller = null;
            // Stream for as long as the source is connected. Calibration and control then only
            // join the running stream instead of stopping and restarting the base between them.
            await pipeline.StartAsync();
            _emgPhase = Phase.Connected;
            Info($"EMG source ready: {source.Name}");
            BuffersChanged?.Invoke();
        }
        catch (Exception e)
        {
            await DropEmgAsync();
            _emgPhase = Phase.Disconnected;
            Fail(e);
        }
        RaiseState();
    }

    /// <summary>Forget the stream. The base stays open so sensors can be managed again.</summary>
    private async Task DropEmgAsync()
    {
        _pipeline = null;
        _calibrator = null;
        _controller = null;
        _source = null;
        Buffers = null;
        if (_session is { IsOpen: true } session)
        {
            try
            {
                await Task.Run(session.ReleaseAsync);
                ShowSensors(session.Sensors);
            }
            catch (Exception e) { Info($"Releasing the Trigno stream: {e.Message}", isError: true); }
        }
        BuffersChanged?.Invoke();
    }

    // MARK: Trigno base and sensors (Delsys API)

    private void ShowSensors(IReadOnlyList<DelsysSensor> sensors)
    {
        int? selected = _selectedSensor?.PairNumber;
        Sensors.Clear();
        foreach (var sensor in sensors) Sensors.Add(sensor);
        SelectedSensor = Sensors.FirstOrDefault(s => s.PairNumber == selected);
        RefreshModeLists();
        Raise(nameof(BaseDetail));
    }

    private void RefreshModeLists()
    {
        void Fill(ObservableCollection<string> list, int pairNumber)
        {
            list.Clear();
            list.Add(""); // keep the sensor's current mode
            foreach (var mode in Sensors.FirstOrDefault(s => s.PairNumber == pairNumber)?.SampleModes ?? []) list.Add(mode);
        }
        Fill(FlexorModes, FlexorSensor);
        Fill(ExtensorModes, ExtensorSensor);
        Raise(nameof(FlexorMode));
        Raise(nameof(ExtensorMode));
    }

    /// <summary>Run one blocking Delsys operation off the UI thread, with the sensor buttons disabled meanwhile.</summary>
    private async Task<bool> WithBaseAsync(Func<DelsysSession, Task> work)
    {
        if (_session is not { } session || _baseBusy) return false;
        _baseBusy = true;
        RaiseState();
        try
        {
            await Task.Run(() => work(session));
            return true;
        }
        catch (Exception e)
        {
            Fail(e);
            return false;
        }
        finally
        {
            _baseBusy = false;
            RaiseState();
        }
    }

    public async Task OpenBaseAsync()
    {
        if (_baseOpen || _baseBusy) return;
        _baseBusy = true;
        RaiseState();
        DelsysSession? session = null;
        try
        {
            session = new DelsysSession(new DelsysCredentials(DelsysKey.Trim(), DelsysLicense.Trim()));
            session.Debug += text => Debug.WriteLine("[delsys] " + text);
            var opened = session;
            var sensors = await Task.Run(async () =>
            {
                opened.Open();
                return await opened.ScanAsync();
            });
            _session = session;
            _baseOpen = true;
            ShowSensors(sensors);
            Info($"{session.DeviceName}: {sensors.Count} paired sensor{(sensors.Count == 1 ? "" : "s")} found");
        }
        catch (Exception e)
        {
            if (session is not null) await Task.Run(session.Dispose);
            Fail(e);
        }
        _baseBusy = false;
        RaiseState();
    }

    public async Task CloseBaseAsync()
    {
        if (!_baseOpen) return;
        if (EmgConnected) await DisconnectEmgAsync();
        CancelPairing();
        var session = _session;
        _session = null;
        _baseOpen = false;
        Sensors.Clear();
        RefreshModeLists();
        if (session is not null) await Task.Run(session.Dispose);
        Info("Trigno base closed");
        RaiseState();
    }

    public async Task RescanAsync()
    {
        IReadOnlyList<DelsysSensor> sensors = [];
        if (await WithBaseAsync(async session => sensors = await session.ScanAsync()))
        {
            ShowSensors(sensors);
            Info($"Scan found {sensors.Count} paired sensor{(sensors.Count == 1 ? "" : "s")}");
        }
    }

    /// <summary>Pair a new sensor under the number typed into the pairing box, then rescan.</summary>
    public async Task PairAsync()
    {
        if (!int.TryParse(PairNumberText.Trim(), out int number) || number < 1)
        {
            Fail(new DelsysException("Enter the number to pair the sensor as (1 or higher)."));
            return;
        }
        var cancel = _pairCancel = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        _isPairing = true;
        _pairStatus = $"Waiting for sensor {number}: hold the sensor's button until its light signals pairing (60 s)…";
        RaiseState();
        bool paired = false;
        IReadOnlyList<DelsysSensor> sensors = [];
        bool ran = await WithBaseAsync(async session =>
        {
            paired = await session.PairAsync(number, cancel.Token);
            if (paired) sensors = await session.ScanAsync();
        });
        _isPairing = false;
        _pairCancel = null;
        _pairStatus = "";
        if (ran && paired)
        {
            ShowSensors(sensors);
            PairNumberText = "";
            Info($"Sensor {number} paired");
        }
        else if (ran)
        {
            Info($"No sensor asked to pair as number {number}", isError: true);
        }
        RaiseState();
    }

    public void CancelPairing() => _pairCancel?.Cancel();

    public async Task RemoveSelectedSensorAsync()
    {
        if (SelectedSensor is not { } sensor) return;
        IReadOnlyList<DelsysSensor> sensors = [];
        if (await WithBaseAsync(session => { session.Remove(sensor.PairNumber); sensors = session.Sensors; return Task.CompletedTask; }))
        {
            ShowSensors(sensors);
            Info($"Sensor {sensor.PairNumber} removed");
        }
    }

    /// <summary>Flash the selected sensor's light for a few seconds.</summary>
    public async Task IdentifySelectedSensorAsync()
    {
        if (SelectedSensor is not { } sensor || _identifying is not null) return;
        _identifying = sensor.PairNumber;
        if (await WithBaseAsync(session => { session.Identify(sensor.PairNumber, true); return Task.CompletedTask; }))
        {
            Info($"Sensor {sensor.PairNumber} is flashing");
            await Task.Delay(TimeSpan.FromSeconds(5));
            await WithBaseAsync(session => { session.Identify(sensor.PairNumber, false); return Task.CompletedTask; });
        }
        _identifying = null;
    }

    public async Task DisconnectEmgAsync()
    {
        if (_isControlling) await StopControlAsync();
        if (_isCalibrating) await StopCalibrationAsync();
        if (_pipeline is { } pipeline) await pipeline.StopAsync();
        await DropEmgAsync();
        _emgPhase = Phase.Disconnected;
        _latest = null;
        Info("EMG source disconnected");
        RaiseState();
    }

    // MARK: Servo

    public void RefreshSerialPorts()
    {
        var ports = SerialServoTransport.AvailablePorts();
        SerialPorts.Clear();
        foreach (var p in ports) SerialPorts.Add(p);
        if (SerialPort.Length == 0 || !ports.Contains(SerialPort)) SerialPort = ports.FirstOrDefault() ?? SerialPort;
    }

    public async Task ConnectServoAsync()
    {
        if (_servoPhase != Phase.Disconnected) return;
        _servoPhase = Phase.Connecting;
        RaiseState();
        IServoDriver? driver = null;
        try
        {
            driver = ServoKind switch
            {
                ServoKind.Mock => new MockServoDriver(),
                ServoKind.Tcp => new FutabaRsServoDriver(new TcpServoTransport(BridgeHost.Trim(), BridgePort)),
                _ => new FutabaRsServoDriver(new SerialServoTransport(SerialPort)),
            };
            var opened = driver;
            var configuration = Configuration.Clone();
            Info($"Opening servo link: {driver.Name}. Zeroing…");
            var result = await Task.Run(() =>
            {
                opened.Open();
                return ServoSetup.Zero(opened, configuration);
            });
            _zero = result;
            Configuration.ZeroLeft = result.Left.Position;
            Configuration.ZeroRight = result.Right.Position;
            SaveSettings();
            _servo = driver;
            _servoName = driver.Name;
            _controller = null;
            _servoPhase = Phase.Connected;
            Info($"Servos zeroed: left {result.Left.PositionDegrees:F1}°, right {result.Right.PositionDegrees:F1}° ({result.Left.Volts:F1} V)");
        }
        catch (Exception e)
        {
            if (driver is not null) await Task.Run(driver.Close);
            _servoPhase = Phase.Disconnected;
            Fail(e);
        }
        RaiseState();
    }

    public async Task DisconnectServoAsync()
    {
        if (_isControlling) await StopControlAsync();
        if (_servo is { } servo) await Task.Run(servo.Close);
        _servo = null;
        _controller = null;
        _zero = null;
        _servoPhase = Phase.Disconnected;
        Info("Servo link closed");
        RaiseState();
    }

    // MARK: Calibration

    public async Task StartCalibrationAsync()
    {
        if (_calibrator is not { } calibrator || !CanCalibrate || _isCalibrating) return;
        _isSwitching = true;
        RaiseState();
        try
        {
            await calibrator.StartAsync();
            _isCalibrating = true;
            _calibrationElapsed = 0;
            _liveRange = null;
            Info("Calibrating: relax, then contract each muscle fully");
            _calibrationTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(200), DispatcherPriority.Normal, (_, _) =>
            {
                if (_calibrator is not { } c) return;
                var progress = c.Progress;
                _calibrationElapsed = progress.Elapsed;
                _liveRange = progress.Range;
                Raise(nameof(CalibrateText));
                Raise(nameof(RangeText));
                Raise(nameof(HasRange));
            }, _dispatcher);
        }
        catch (Exception e) { Fail(e); }
        _isSwitching = false;
        RaiseState();
    }

    public async Task<ActivationRange?> StopCalibrationAsync()
    {
        if (_calibrator is not { } calibrator || !_isCalibrating) return null;
        _calibrationTimer?.Stop();
        _calibrationTimer = null;
        _isCalibrating = false;
        _isSwitching = true;
        RaiseState();
        var result = await calibrator.StopAsync();
        _liveRange = null;
        _isSwitching = false;
        Range = result;
        Info("Calibrated: " + string.Join(", ", Enumerable.Range(0, result.ChannelCount).Select(ch => $"ch{ch + 1} {result.Minimum[ch]:G3}…{result.Maximum[ch]:G3}")));
        return result;
    }

    public void ClearCalibration()
    {
        if (_isControlling) return;
        Range = null;
    }

    // MARK: Control

    public async Task StartControlAsync()
    {
        if (_pipeline is not { } pipeline || _servo is not { } servo || Range is not { } range || !CanControl || _isControlling) return;
        _isSwitching = true;
        RaiseState();
        try
        {
            if (_controller is null)
            {
                var created = new AssistController(pipeline, servo, _estimator, range, Configuration);
                created.Sample += Receive;
                created.Error += error => _dispatcher.BeginInvoke(async () =>
                {
                    Fail(error);
                    await StopControlAsync();
                });
                _controller = created;
            }
            var controller = _controller;
            controller.Update(range);
            controller.Update(Configuration);
            Buffers?.ClearControl();
            if (RecordTelemetry)
            {
                string path = Path.Combine(RecordingsDirectory, $"assist-{DateTime.Now:yyyyMMdd-HHmmss}.csv");
                _telemetry = new TelemetryLog(path, pipeline.ChannelCount);
                _currentRecording = path;
            }
            await controller.StartAsync();
            _isControlling = true;
            Info($"Controlling ({StiffnessMode}, threshold {(int)Configuration.Stiffness.Threshold})");
        }
        catch (Exception e)
        {
            _telemetry?.Finish();
            _telemetry = null;
            _currentRecording = null;
            Fail(e);
        }
        _isSwitching = false;
        RaiseState();
    }

    public async Task StopControlAsync()
    {
        if (_controller is not { } controller || !_isControlling) return;
        _isControlling = false;
        _isSwitching = true;
        RaiseState();
        await controller.StopAsync();
        if (_telemetry is { } telemetry)
        {
            try { telemetry.Finish(); Info($"Saved {Path.GetFileName(telemetry.Path)}"); }
            catch (Exception e) { Fail(e); }
        }
        _telemetry = null;
        _currentRecording = null;
        _isSwitching = false;
        Info("Stopped");
        RaiseState();
    }

    /// <summary>Runs on the control thread.</summary>
    private void Receive(ControlSample sample)
    {
        _latest = sample;
        Buffers?.Push(sample, Configuration);
        try { _telemetry?.Write(sample); }
        catch (ObjectDisposedException) { /* a tick that raced the end of the recording */ }
    }

    private void ResizeBuffers()
    {
        if (_source is not { } source || _pipeline is not { } pipeline || Buffers is not { } buffers) return;
        buffers.Resize(PlotWindow, source.SampleRate, pipeline.OutputRate, Configuration.UpdateRate);
        BuffersChanged?.Invoke();
    }

    public void RevealRecordings()
    {
        try
        {
            Directory.CreateDirectory(RecordingsDirectory);
            Process.Start(new ProcessStartInfo { FileName = RecordingsDirectory, UseShellExecute = true });
        }
        catch (Exception e) { Fail(e); }
    }

    // MARK: Model parameters

    /// <summary>Load param_eq.txt and param_trq.txt from the legacy parameter folder.</summary>
    public void LoadParameters(string folder)
    {
        try
        {
            string eq = Path.Combine(folder, JointEstimator.EquilibriumFileName);
            string trq = Path.Combine(folder, JointEstimator.TorqueFileName);
            _estimator = JointEstimator.FromFiles(eq, trq);
            _settings.ParamEqPath = eq;
            _settings.ParamTrqPath = trq;
            SaveSettings();
            _controller = null; // the next start uses the new model
            var s = _estimator.Summary;
            Info($"Model parameters loaded from {folder}: rest {s.AtRest:F1}°, flexor {s.PerMuscle[0]:F1}°, extensor {s.PerMuscle[1]:F1}°");
        }
        catch (Exception e) { Fail(e); }
        RaiseState();
    }

    public void UseBundledParameters()
    {
        _estimator = JointEstimator.LegacyDefault();
        _settings.ParamEqPath = _settings.ParamTrqPath = "";
        SaveSettings();
        _controller = null;
        Info("Using the built-in legacy model parameters");
        RaiseState();
    }

    // MARK: Log

    public void Info(string text, bool isError = false)
    {
        Log.Insert(0, new LogEntry(DateTime.Now, text, isError));
        while (Log.Count > 300) Log.RemoveAt(Log.Count - 1);
    }

    public void Fail(Exception error)
    {
        string text = error is AggregateException { InnerException: { } inner } ? inner.Message : error.Message;
        Info(text, isError: true);
        Alert?.Invoke(text);
    }

    /// <summary>Stop everything before the window closes, so the servos are not left powered.</summary>
    public async Task ShutdownAsync()
    {
        try
        {
            if (EmgConnected) await DisconnectEmgAsync();
            if (BaseOpen) await CloseBaseAsync();
            if (ServoConnected) await DisconnectServoAsync();
        }
        catch (Exception)
        {
            // Closing anyway.
        }
    }
}
