using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using AssistArm.Model;
using Microsoft.Win32;

namespace AssistArm.App;

/// <summary>Readable names for the enums shown in combo boxes.</summary>
public sealed class TitleConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        EmgSourceKind.Delsys => "Delsys API (Trigno base on USB)",
        EmgSourceKind.Synthetic => "Synthetic",
        ServoKind.Serial => "Serial (COM port)",
        ServoKind.Tcp => "TCP bridge",
        ServoKind.Mock => "Simulated",
        StiffnessMode.Linear => "Linear",
        StiffnessMode.Low => "Low",
        StiffnessMode.High => "High",
        StiffnessMode.HighOrLow => "High or low",
        _ => value?.ToString() ?? "",
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => Binding.DoNothing;
}

public partial class MainWindow : Window
{
    private static readonly Brush Off = new SolidColorBrush(Color.FromRgb(0xBB, 0xBB, 0xBB));
    private static readonly Brush On = new SolidColorBrush(Color.FromRgb(0x3A, 0xA6, 0x55));
    private static readonly Brush Busy = new SolidColorBrush(Color.FromRgb(0xF2, 0x8E, 0x2B));
    private static readonly Brush Running = new SolidColorBrush(Color.FromRgb(0xD3, 0x2F, 0x2F));

    private readonly AppModel _model = new();
    private readonly DispatcherTimer _refresh;
    private readonly PlotStrip[] _plots;
    private bool _closing;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _model;
        _plots = [PlotFlexor, PlotExtensor, PlotActivation, PlotAngle, PlotStiffness, PlotCompliance];
        _model.Alert += text => MessageBox.Show(this, text, "Assist Arm", MessageBoxButton.OK, MessageBoxImage.Warning);
        _model.BuffersChanged += ConfigurePlots;
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppModel.StiffnessMode) or nameof(AppModel.Threshold)) ConfigurePlots();
        };
        ConfigurePlots();
        // Redraw the plots and read-outs at display-ish rate while data is flowing.
        _refresh = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Render, (_, _) => RefreshLive(), Dispatcher);
    }

    private void ConfigurePlots()
    {
        var buffers = _model.Buffers;
        LivePanel.Visibility = buffers is null ? Visibility.Collapsed : Visibility.Visible;
        EmptyHint.Visibility = buffers is null ? Visibility.Visible : Visibility.Collapsed;
        if (buffers is null)
        {
            foreach (var plot in _plots) plot.Ring = null;
            return;
        }
        bool calibrated = _model.Range is not null;
        float limit = (float)_model.Configuration.AngleLimitDegrees;

        PlotFlexor.Ring = buffers.Emg;
        PlotFlexor.Channels = [0];
        PlotFlexor.Scale = PlotScaleKind.Symmetric;
        PlotFlexor.SeriesColor = PlotStrip.Palette[0];

        PlotExtensor.Ring = buffers.Emg;
        PlotExtensor.Channels = [1];
        PlotExtensor.Scale = PlotScaleKind.Symmetric;
        PlotExtensor.SeriesColor = PlotStrip.Palette[1];

        PlotActivation.Ring = buffers.Activation;
        PlotActivation.Title = calibrated ? "Activation" : "Quasi-tension (uncalibrated)";
        PlotActivation.Units = calibrated ? "0…1" : "V";
        PlotActivation.Channels = [0, 1];
        PlotActivation.Labels = ["flexor", "extensor"];
        PlotActivation.Scale = calibrated ? PlotScaleKind.Fixed : PlotScaleKind.Auto;
        PlotActivation.FixedLow = 0;
        PlotActivation.FixedHigh = 1;

        PlotAngle.Ring = buffers.Angle;
        PlotAngle.Channels = [0, 1, 2];
        PlotAngle.Labels = ["target", "left", "right"];
        PlotAngle.Scale = PlotScaleKind.Fixed;
        PlotAngle.FixedLow = -limit;
        PlotAngle.FixedHigh = limit;
        PlotAngle.Markers = [0];

        PlotStiffness.Ring = buffers.Stiffness;
        PlotStiffness.Channels = [0];
        PlotStiffness.Labels = ["normalised"];
        PlotStiffness.Scale = PlotScaleKind.Fixed;
        PlotStiffness.FixedLow = 0;
        PlotStiffness.FixedHigh = 100;
        PlotStiffness.Markers = [(float)_model.Configuration.Stiffness.Threshold];

        PlotCompliance.Ring = buffers.Stiffness;
        PlotCompliance.Channels = [1];
        PlotCompliance.Labels = ["0x32 stiff … 0xFF soft"];
        PlotCompliance.Scale = PlotScaleKind.Fixed;
        PlotCompliance.FixedLow = 0;
        PlotCompliance.FixedHigh = 255;

        foreach (var plot in _plots)
        {
            plot.WindowSeconds = buffers.Window;
            plot.InvalidateVisual();
        }
    }

    private void RefreshLive()
    {
        EmgDot.Fill = _model.EmgPhase switch { Phase.Connected => On, Phase.Connecting => Busy, _ => Off };
        ServoDot.Fill = _model.ServoPhase switch { Phase.Connected => On, Phase.Connecting => Busy, _ => Off };
        (StateDot.Fill, StateLabel.Text) =
            _model.IsControlling ? (Running, "Controlling")
            : _model.IsCalibrating ? (Busy, "Calibrating")
            : _model.Range is not null ? (On, "Calibrated") : (Off, "Not calibrated");
        ControlButton.Content = _model.IsControlling ? "Stop" : "Start control";
        ControlButton.IsEnabled = _model.IsControlling || _model.CanControl;

        if (!_model.IsStreaming) return;
        foreach (var plot in _plots) plot.InvalidateVisual();

        var s = _model.Latest;
        var stiffness = _model.Configuration.Stiffness;
        ReadEquilibrium.Text = s is null ? "—" : $"{s.Estimate.EquilibriumDegrees:F1}°";
        ReadStiffness.Text = s is null ? "—" : $"{s.Estimate.NormalizedStiffness:F0}";
        ReadCompliance.Text = s is null ? "—" : $"0x{s.Compliance:X2}";
        ReadComplianceDetail.Text = s is null ? " " : s.Compliance == stiffness.StiffCompliance ? "stiff" : s.Compliance == stiffness.SoftCompliance ? "soft" : " ";
        ReadLeft.Text = s?.StatusLeft is { } left ? $"{left.PositionDegrees:F1}°" : "—";
        ReadLeftDetail.Text = s?.StatusLeft is { } l ? $"{l.Current} mA" : " ";
        ReadRight.Text = s?.StatusRight is { } right ? $"{right.PositionDegrees:F1}°" : "—";
        ReadRightDetail.Text = s?.StatusRight is { } r ? $"{r.Current} mA · {r.Volts:F1} V" : " ";
    }

    private async void Emg_Click(object sender, RoutedEventArgs e)
    {
        if (_model.EmgConnected)
        {
            if (_model.CanDisconnectEmg) await _model.DisconnectEmgAsync();
        }
        else
        {
            await _model.ConnectEmgAsync();
        }
    }

    private async void Servo_Click(object sender, RoutedEventArgs e)
    {
        if (_model.ServoConnected)
        {
            if (_model.CanDisconnectServo) await _model.DisconnectServoAsync();
        }
        else if (_model.CanConnectServo)
        {
            await _model.ConnectServoAsync();
        }
    }

    private async void Calibrate_Click(object sender, RoutedEventArgs e)
    {
        if (_model.IsCalibrating) await _model.StopCalibrationAsync();
        else await _model.StartCalibrationAsync();
    }

    private async void Control_Click(object sender, RoutedEventArgs e)
    {
        if (_model.IsControlling) await _model.StopControlAsync();
        else await _model.StartControlAsync();
    }

    private async void Base_Click(object sender, RoutedEventArgs e)
    {
        if (_model.BaseOpen) await _model.CloseBaseAsync();
        else await _model.OpenBaseAsync();
    }

    private async void Rescan_Click(object sender, RoutedEventArgs e) => await _model.RescanAsync();
    private async void Pair_Click(object sender, RoutedEventArgs e) => await _model.PairAsync();
    private void CancelPair_Click(object sender, RoutedEventArgs e) => _model.CancelPairing();
    private async void Identify_Click(object sender, RoutedEventArgs e) => await _model.IdentifySelectedSensorAsync();

    private async void RemoveSensor_Click(object sender, RoutedEventArgs e)
    {
        if (_model.SelectedSensor is not { } sensor) return;
        var answer = MessageBox.Show(this, $"Make the base forget sensor {sensor.PairNumber} ({sensor.Name})? It will have to be paired again before it can be used.",
                                     "Assist Arm", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer == MessageBoxResult.OK) await _model.RemoveSelectedSensorAsync();
    }

    private void ClearRange_Click(object sender, RoutedEventArgs e) => _model.ClearCalibration();
    private void RefreshPorts_Click(object sender, RoutedEventArgs e) => _model.RefreshSerialPorts();
    private void Recordings_Click(object sender, RoutedEventArgs e) => _model.RevealRecordings();
    private void SaveLicense_Click(object sender, RoutedEventArgs e) => _model.SaveLicense();
    private void BuiltInParameters_Click(object sender, RoutedEventArgs e) => _model.UseBundledParameters();

    private void ChooseParameters_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose the folder containing param_eq.txt and param_trq.txt" };
        if (dialog.ShowDialog(this) == true) _model.LoadParameters(dialog.FolderName);
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (_closing) return;
        // Stop control and switch servo torque off before the window goes away.
        e.Cancel = true;
        _closing = true;
        _refresh.Stop();
        await _model.ShutdownAsync();
        Close();
    }
}
