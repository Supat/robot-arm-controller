using System.Globalization;
using System.Windows;
using System.Windows.Threading;

namespace AssistArm.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Numbers in the UI and the CSV use a decimal point regardless of the Windows locale.
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        // PrecisionClock raises the system timer resolution for the control loop's sake.
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "Assist Arm", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
