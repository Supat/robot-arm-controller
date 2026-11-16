namespace AssistArm.Signal;

/// <summary>
/// EMG-to-quasi-tension FIR filter (Koike &amp; Kawato).
///
/// Impulse response h(t) = 6.44 (e^(-10.8 t) - e^(-16.52 t)), sampled every 1/sampleRate
/// seconds over 0.5 s and normalised to unit gain, exactly as the legacy CKoikeFilter
/// (100 taps at 200 Hz).
/// </summary>
public sealed class KoikeFilter
{
    private readonly double[] _coefficients;
    private readonly double[] _history;
    private int _head;

    public KoikeFilter(double sampleRate = 200, double duration = 0.5)
    {
        int taps = Math.Max(1, (int)Math.Round(sampleRate * duration, MidpointRounding.AwayFromZero));
        var c = new double[taps];
        double sum = 0;
        for (int i = 0; i < taps; i++)
        {
            double t = i / sampleRate;
            c[i] = 6.44 * (Math.Exp(-10.8 * t) - Math.Exp(-16.52 * t));
            sum += c[i];
        }
        for (int i = 0; i < taps; i++) c[i] /= sum;
        _coefficients = c;
        _history = new double[taps];
    }

    public IReadOnlyList<double> Coefficients => _coefficients;
    public int TapCount => _coefficients.Length;

    public void Reset()
    {
        Array.Clear(_history);
        _head = 0;
    }

    /// <summary>Push one input sample and return the filtered output.</summary>
    public double Push(double x)
    {
        int n = _coefficients.Length;
        _history[_head] = x;
        double acc = 0;
        int idx = _head;
        for (int k = 0; k < n; k++)
        {
            acc += _coefficients[k] * _history[idx];
            idx = idx == 0 ? n - 1 : idx - 1;
        }
        _head = (_head + 1) % n;
        return acc;
    }
}

/// <summary>A block of raw EMG samples from any source, row-major: Samples[row * ChannelCount + channel].</summary>
public sealed class EmgBlock
{
    public double SampleRate { get; }
    public int ChannelCount { get; }
    public float[] Samples { get; }
    /// <summary>Index of the first row since the source started.</summary>
    public long StartIndex { get; }
    public DateTime HostTime { get; }

    public EmgBlock(double sampleRate, int channelCount, float[] samples, long startIndex, DateTime? hostTime = null)
    {
        SampleRate = sampleRate;
        ChannelCount = channelCount;
        Samples = samples;
        StartIndex = startIndex;
        HostTime = hostTime ?? DateTime.UtcNow;
    }

    public int RowCount => ChannelCount == 0 ? 0 : Samples.Length / ChannelCount;
    public float Value(int row, int channel) => Samples[row * ChannelCount + channel];
}

/// <summary>One quasi-tension sample for all channels, at <see cref="QuasiTensionProcessor.OutputRate"/>.</summary>
/// <param name="Values">Rectified, averaged, Koike-filtered EMG per channel (same units as the input).</param>
/// <param name="Index">Index of this sample since the processor was reset.</param>
public sealed record QuasiTensionSample(double[] Values, int Index);

/// <summary>
/// Turns raw EMG into quasi-tension the way the legacy SimpleNiControl::GetData did:
/// rectify, average every <see cref="Decimation"/> samples (2 kHz → 200 Hz), then the Koike FIR.
/// </summary>
public sealed class QuasiTensionProcessor
{
    public double InputRate { get; }
    public double OutputRate { get; }
    public int ChannelCount { get; }
    public int Decimation { get; }

    private readonly KoikeFilter[] _filters;
    private readonly double[] _accumulators;
    private int _accumulated;
    private int _outputIndex;

    public QuasiTensionProcessor(double inputRate, int channelCount, double outputRate = 200)
    {
        if (channelCount <= 0) throw new ArgumentOutOfRangeException(nameof(channelCount));
        InputRate = inputRate;
        ChannelCount = channelCount;
        Decimation = Math.Max(1, (int)Math.Round(inputRate / outputRate, MidpointRounding.AwayFromZero));
        OutputRate = inputRate / Decimation;
        _filters = new KoikeFilter[channelCount];
        for (int i = 0; i < channelCount; i++) _filters[i] = new KoikeFilter(OutputRate);
        _accumulators = new double[channelCount];
    }

    public void Reset()
    {
        foreach (var f in _filters) f.Reset();
        Array.Clear(_accumulators);
        _accumulated = 0;
        _outputIndex = 0;
    }

    /// <summary>Process a block and return the quasi-tension samples it completed (0 or more).</summary>
    public List<QuasiTensionSample> Process(EmgBlock block)
    {
        if (block.ChannelCount != ChannelCount) throw new ArgumentException("channel count mismatch", nameof(block));
        var output = new List<QuasiTensionSample>(block.RowCount / Decimation + 1);
        for (int row = 0; row < block.RowCount; row++)
        {
            for (int ch = 0; ch < ChannelCount; ch++) _accumulators[ch] += Math.Abs((double)block.Value(row, ch));
            _accumulated++;
            if (_accumulated == Decimation)
            {
                var values = new double[ChannelCount];
                for (int ch = 0; ch < ChannelCount; ch++)
                {
                    values[ch] = _filters[ch].Push(_accumulators[ch] / Decimation);
                    _accumulators[ch] = 0;
                }
                _accumulated = 0;
                output.Add(new QuasiTensionSample(values, _outputIndex));
                _outputIndex++;
            }
        }
        return output;
    }
}

/// <summary>Per-channel quasi-tension range used to normalise activation to 0…1.</summary>
public sealed class ActivationRange : IEquatable<ActivationRange>
{
    public double[] Minimum { get; set; }
    public double[] Maximum { get; set; }

    public ActivationRange() : this([], []) { }

    public ActivationRange(double[] minimum, double[] maximum)
    {
        if (minimum.Length != maximum.Length) throw new ArgumentException("minimum and maximum differ in length");
        Minimum = minimum;
        Maximum = maximum;
    }

    /// <summary>
    /// Range that passes values through unchanged (0 → 0, 1 → 1), as the legacy code used when
    /// too few samples were collected.
    /// </summary>
    public static ActivationRange Identity(int channelCount) =>
        new(new double[channelCount], Enumerable.Repeat(1.0, channelCount).ToArray());

    [System.Text.Json.Serialization.JsonIgnore]
    public int ChannelCount => Minimum.Length;

    /// <summary>Legacy CDaqControl::GetNormalizedQt: clamp to the calibrated range and scale to 0…1.</summary>
    public double Normalize(double value, int channel)
    {
        double lo = Minimum[channel], hi = Maximum[channel];
        if (!(hi > lo)) return 0;
        if (value >= hi) return 1;
        if (value <= lo) return 0;
        return (value - lo) / (hi - lo);
    }

    public double[] Normalize(IReadOnlyList<double> values)
    {
        var result = new double[values.Count];
        for (int i = 0; i < result.Length; i++) result[i] = Normalize(values[i], i);
        return result;
    }

    public bool Equals(ActivationRange? other) =>
        other is not null && Minimum.SequenceEqual(other.Minimum) && Maximum.SequenceEqual(other.Maximum);
    public override bool Equals(object? obj) => Equals(obj as ActivationRange);
    public override int GetHashCode() => Minimum.Length;
}

/// <summary>
/// Collects quasi-tension while the user relaxes and contracts maximally, then yields the
/// min/max range. The first <c>discardSeconds</c> are skipped (legacy skipped 200 samples = 1 s)
/// so the filter's start-up transient is not counted.
/// </summary>
public sealed class MinMaxCalibration
{
    public int ChannelCount { get; }
    public double DiscardSeconds { get; }
    private readonly double _sampleRate;
    private readonly double[] _minimum;
    private readonly double[] _maximum;
    public int SampleCount { get; private set; }
    public int UsedCount { get; private set; }

    public MinMaxCalibration(int channelCount, double sampleRate = 200, double discardSeconds = 1.0)
    {
        ChannelCount = channelCount;
        _sampleRate = sampleRate;
        DiscardSeconds = discardSeconds;
        _minimum = Enumerable.Repeat(double.PositiveInfinity, channelCount).ToArray();
        _maximum = Enumerable.Repeat(double.NegativeInfinity, channelCount).ToArray();
    }

    public void Add(QuasiTensionSample sample)
    {
        SampleCount++;
        if (!(SampleCount > DiscardSeconds * _sampleRate)) return;
        UsedCount++;
        for (int ch = 0; ch < ChannelCount; ch++)
        {
            _minimum[ch] = Math.Min(_minimum[ch], sample.Values[ch]);
            _maximum[ch] = Math.Max(_maximum[ch], sample.Values[ch]);
        }
    }

    public double ElapsedSeconds => SampleCount / _sampleRate;

    /// <summary>Current running range, or null until at least one sample has been used.</summary>
    public ActivationRange? Range =>
        UsedCount > 0 ? new ActivationRange((double[])_minimum.Clone(), (double[])_maximum.Clone()) : null;

    /// <summary>
    /// Final range; falls back to the identity range when nothing usable was collected, as the
    /// legacy program did.
    /// </summary>
    public ActivationRange Finish() => Range ?? ActivationRange.Identity(ChannelCount);
}
