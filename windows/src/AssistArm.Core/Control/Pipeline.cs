using System.Threading.Channels;
using AssistArm.Signal;

namespace AssistArm.Control;

/// <summary>
/// Runs an <see cref="IEmgSource"/> through a <see cref="QuasiTensionProcessor"/> and fans out
/// both the raw blocks and the 200 Hz quasi-tension samples. Shared by calibration and control.
/// </summary>
public sealed class QuasiTensionPipeline
{
    public IEmgSource Source { get; }
    public double OutputRate { get; }
    public int ChannelCount => Source.ChannelCount;

    private readonly QuasiTensionProcessor _processor;
    private readonly SemaphoreSlim _transition = new(1, 1);
    private readonly object _sinkGate = new();
    private Action<EmgBlock>[] _rawSinks = [];
    private Action<QuasiTensionSample>[] _qtSinks = [];
    /// <summary>
    /// Outstanding StartAsync calls. The source runs while at least one is held, so calibration
    /// and control can hand over without stopping and restarting the stream in between.
    /// </summary>
    private int _holders;
    /// <summary>
    /// Blocks are queued here by the source's thread and drained by one task, so they reach the
    /// processor in arrival order (the rectify → average → FIR chain is order-dependent).
    /// </summary>
    private Channel<EmgBlock>? _inbox;
    private Task? _drain;
    private volatile bool _isRunning;
    private volatile QuasiTensionSample? _latest;

    public bool IsRunning => _isRunning;
    public QuasiTensionSample? Latest => _latest;

    public QuasiTensionPipeline(IEmgSource source, double outputRate = 200)
    {
        Source = source;
        _processor = new QuasiTensionProcessor(source.SampleRate, source.ChannelCount, outputRate);
        OutputRate = _processor.OutputRate;
    }

    public void AddRawSink(Action<EmgBlock> sink) { lock (_sinkGate) _rawSinks = [.. _rawSinks, sink]; }
    public void AddQuasiTensionSink(Action<QuasiTensionSample> sink) { lock (_sinkGate) _qtSinks = [.. _qtSinks, sink]; }
    public void RemoveQuasiTensionSink(Action<QuasiTensionSample> sink)
    {
        lock (_sinkGate) _qtSinks = _qtSinks.Where(s => s != sink).ToArray();
    }

    /// <summary>Start the source, or join it if it is already running. Balance every call with StopAsync.</summary>
    public async Task StartAsync()
    {
        await _transition.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_isRunning) { _holders++; return; }
            _processor.Reset();
            _latest = null;
            var inbox = Channel.CreateUnbounded<EmgBlock>(new UnboundedChannelOptions { SingleReader = true });
            _inbox = inbox;
            _isRunning = true;
            _drain = Task.Run(async () =>
            {
                await foreach (var block in inbox.Reader.ReadAllAsync().ConfigureAwait(false)) Ingest(block);
            });
            try
            {
                await Source.StartAsync(block => inbox.Writer.TryWrite(block)).ConfigureAwait(false);
            }
            catch
            {
                _isRunning = false;
                CloseInbox();
                throw;
            }
            _holders = 1;
        }
        finally
        {
            _transition.Release();
        }
    }

    private void CloseInbox()
    {
        _inbox?.Writer.TryComplete();
        _inbox = null;
        _drain = null;
    }

    /// <summary>Release one StartAsync. The source stops when the last holder releases it.</summary>
    public async Task StopAsync()
    {
        await _transition.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_holders <= 0) return;
            _holders--;
            if (_holders > 0 || !_isRunning) return;
            _isRunning = false;
            await Source.StopAsync().ConfigureAwait(false);
            CloseInbox();
        }
        finally
        {
            _transition.Release();
        }
    }

    private void Ingest(EmgBlock block)
    {
        if (!_isRunning) return;
        foreach (var sink in _rawSinks) sink(block);
        foreach (var sample in _processor.Process(block))
        {
            _latest = sample;
            foreach (var sink in _qtSinks) sink(sample);
        }
    }
}

/// <summary>Min/max calibration driven by a pipeline: start, have the user relax and contract, stop.</summary>
public sealed class ActivationCalibrator
{
    public QuasiTensionPipeline Pipeline { get; }
    private readonly object _gate = new();
    private MinMaxCalibration _calibration;
    private bool _isRunning;

    public bool IsRunning { get { lock (_gate) return _isRunning; } }

    public ActivationCalibrator(QuasiTensionPipeline pipeline)
    {
        Pipeline = pipeline;
        _calibration = new MinMaxCalibration(pipeline.ChannelCount, pipeline.OutputRate);
        pipeline.AddQuasiTensionSink(Add);
    }

    private void Add(QuasiTensionSample sample)
    {
        lock (_gate)
        {
            if (_isRunning) _calibration.Add(sample);
        }
    }

    public async Task StartAsync()
    {
        lock (_gate)
        {
            _calibration = new MinMaxCalibration(Pipeline.ChannelCount, Pipeline.OutputRate);
            _isRunning = true;
        }
        try
        {
            await Pipeline.StartAsync().ConfigureAwait(false);
        }
        catch
        {
            lock (_gate) _isRunning = false;
            throw;
        }
    }

    /// <summary>Releases the pipeline and returns the calibrated range.</summary>
    public async Task<ActivationRange> StopAsync()
    {
        bool wasRunning;
        lock (_gate) { wasRunning = _isRunning; _isRunning = false; }
        if (wasRunning) await Pipeline.StopAsync().ConfigureAwait(false);
        lock (_gate) return _calibration.Finish();
    }

    public (double Elapsed, ActivationRange? Range) Progress
    {
        get { lock (_gate) return (_calibration.ElapsedSeconds, _calibration.Range); }
    }
}
