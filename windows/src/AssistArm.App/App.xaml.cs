using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace AssistArm.App;

public partial class App : Application
{
    // Windows timers tick every 15.6 ms by default, too coarse for a 50 Hz loop. Asking for 1 ms
    // lets the control thread sleep accurately between ticks.
    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint milliseconds);

    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint milliseconds);

    protected override void OnStartup(StartupEventArgs e)
    {
        // Numbers in the UI and the CSV use a decimal point regardless of the Windows locale.
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        try { timeBeginPeriod(1); } catch (Exception) { /* not fatal: timing is just coarser */ }
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { timeEndPeriod(1); } catch (Exception) { /* see OnStartup */ }
        base.OnExit(e);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "Assist Arm", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
