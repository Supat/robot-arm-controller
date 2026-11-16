using System.Diagnostics;
using System.Runtime.InteropServices;
using AssistArm.Signal;

namespace AssistArm.Control;

/// <summary>Anything that delivers raw EMG blocks: the Delsys API, a file, a synthesiser.</summary>
public interface IEmgSource
{
    string Name { get; }
    int ChannelCount { get; }
    double SampleRate { get; }
    /// <summary>Begin delivering blocks to <paramref name="sink"/> (called from an arbitrary thread).</summary>
    Task StartAsync(Action<EmgBlock> sink);
    Task StopAsync();
}

/// <summary>Waits that are accurate to well under a millisecond, which Task.Delay is not on Windows.</summary>
public static class PrecisionClock
{
    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint milliseconds);

    // Windows timers tick every 15.6 ms unless the process asks for better, which quantizes
    // Thread.Sleep(1) — and with it every loop here — to ~64 Hz. Request 1 ms once, for the
    // life of the process, so a CLI or test host is as accurate as the app.
    private static readonly bool FineTimer = RequestFineTimer();

    private static bool RequestFineTimer()
    {
        if (!OperatingSystem.IsWindows()) return true; // 1 ms sleeps already
        try { return timeBeginPeriod(1) == 0; }
        catch (Exception) { return false; }
    }

    /// <summary>Block until <paramref name="stopwatch"/> reaches <paramref name="dueSeconds"/>.</summary>
    public static void SleepUntil(Stopwatch stopwatch, double dueSeconds, CancellationToken cancel = default)
    {
        // Sleep(1) can overshoot by a timer tick, so only sleep while there is room for that.
        double sleepMargin = FineTimer ? 0.003 : 0.017;
        while (!cancel.IsCancellationRequested)
        {
            double remaining = dueSeconds - stopwatch.Elapsed.TotalSeconds;
            if (remaining <= 0) return;
            if (remaining > sleepMargin) Thread.Sleep(1);
            else Thread.SpinWait(50);
        }
    }
}

/// <summary>
/// Two synthetic muscles for development without sensors: band-limited noise under a slowly
/// alternating envelope, with a co-contraction burst every cycle. Amplitudes are in volts,
/// about what a Trigno sensor reports.
/// </summary>
public sealed class SyntheticEmgSource : IEmgSource
{
    public string Name => "Synthetic EMG";
    public int ChannelCount { get; }
    public double SampleRate { get; }
    public float Amplitude { get; set; } = 2e-4f;
    public double PeriodSeconds { get; set; } = 8;

    private const double BlockSeconds = 0.01;
    private CancellationTokenSource? _cancel;
    private Thread? _thread;
    private readonly object _gate = new();

    public SyntheticEmgSource(int channelCount = 2, double sampleRate = 2000)
    {
        ChannelCount = channelCount;
        SampleRate = sampleRate;
    }

    public async Task StartAsync(Action<EmgBlock> sink)
    {
        await StopAsync();
        int rows = Math.Max(1, (int)(SampleRate * BlockSeconds));
        double rate = SampleRate, period = PeriodSeconds;
        int channels = ChannelCount;
        float amp = Amplitude;
        var cancel = new CancellationTokenSource();
        var thread = new Thread(() =>
        {
            long index = 0;
            var rng = new Random();
            var lowpass = new float[channels];
            var envelope = new double[channels];
            var clock = Stopwatch.StartNew();
            while (!cancel.IsCancellationRequested)
            {
                var samples = new float[rows * channels];
                for (int r = 0; r < rows; r++)
                {
                    double time = (index + r) / rate;
                    double phase = time / period % 1;
                    // 0…0.4: muscle 0, 0.5…0.9: muscle 1, 0.92…1: both.
                    Array.Fill(envelope, 0.05);
                    if (phase < 0.4) envelope[0] += Math.Sin(Math.PI * phase / 0.4);
                    if (phase >= 0.5 && phase < 0.9 && channels > 1) envelope[1] += Math.Sin(Math.PI * (phase - 0.5) / 0.4);
                    if (phase >= 0.92) for (int c = 0; c < channels; c++) envelope[c] += 0.8;
                    for (int c = 0; c < channels; c++)
                    {
                        // White noise lightly smoothed so it looks like 20–450 Hz EMG.
                        float white = (float)(rng.NextDouble() * 2 - 1);
                        lowpass[c] += 0.6f * (white - lowpass[c]);
                        samples[r * channels + c] = lowpass[c] * amp * (float)envelope[c];
                    }
                }
                sink(new EmgBlock(rate, channels, samples, index));
                index += rows;
                PrecisionClock.SleepUntil(clock, index / rate, cancel.Token);
            }
        })
        { IsBackground = true, Name = "Synthetic EMG" };
        lock (_gate) { _cancel = cancel; _thread = thread; }
        thread.Start();
    }

    public Task StopAsync()
    {
        CancellationTokenSource? cancel;
        Thread? thread;
        lock (_gate) { cancel = _cancel; thread = _thread; _cancel = null; _thread = null; }
        cancel?.Cancel();
        if (thread is not null && thread != Thread.CurrentThread) thread.Join(500);
        return Task.CompletedTask;
    }
}
