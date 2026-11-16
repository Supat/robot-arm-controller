using AssistArm.Control;
using AssistArm.Signal;

namespace AssistArm.App;

/// <summary>Fixed-length ring of multi-channel samples, written from any thread, read by the plots.</summary>
public sealed class SeriesRing
{
    public readonly record struct Envelope(float[] Mins, float[] Maxs)
    {
        public bool IsEmpty => Mins.Length == 0;
    }

    public int Channels { get; }
    public int Capacity { get; private set; }
    private float[] _data;
    private int _writeRow;
    private int _filled;
    private readonly object _gate = new();

    public SeriesRing(int channels, int capacity)
    {
        Channels = channels;
        Capacity = Math.Max(1, capacity);
        _data = new float[channels * Capacity];
    }

    public void Reset(int? capacity = null)
    {
        lock (_gate)
        {
            if (capacity is int c) Capacity = Math.Max(1, c);
            _data = new float[Channels * Capacity];
            _writeRow = 0;
            _filled = 0;
        }
    }

    public void Push(ReadOnlySpan<float> values)
    {
        lock (_gate)
        {
            int start = _writeRow * Channels;
            for (int c = 0; c < Channels; c++) _data[start + c] = c < values.Length ? values[c] : float.NaN;
            _writeRow = (_writeRow + 1) % Capacity;
            _filled = Math.Min(_filled + 1, Capacity);
        }
    }

    public void Push(EmgBlock block)
    {
        lock (_gate)
        {
            for (int row = 0; row < block.RowCount; row++)
            {
                int start = _writeRow * Channels;
                for (int c = 0; c < Channels; c++) _data[start + c] = c < block.ChannelCount ? block.Value(row, c) : float.NaN;
                _writeRow = (_writeRow + 1) % Capacity;
                _filled = Math.Min(_filled + 1, Capacity);
            }
        }
    }

    /// <summary>Min/max per bin over the whole window (oldest first) for one channel. Empty bins are NaN.</summary>
    public Envelope GetEnvelope(int channel, int bins)
    {
        lock (_gate)
        {
            if (_filled == 0 || bins <= 0) return new Envelope([], []);
            int binCount = Math.Min(bins, Capacity);
            var mins = new float[binCount];
            var maxs = new float[binCount];
            Array.Fill(mins, float.NaN);
            Array.Fill(maxs, float.NaN);
            int oldest = (_writeRow - _filled + Capacity) % Capacity;
            int offset = Capacity - _filled;
            for (int k = 0; k < _filled; k++)
            {
                float v = _data[(oldest + k) % Capacity * Channels + channel];
                if (float.IsNaN(v)) continue;
                int bin = (int)((long)(offset + k) * binCount / Capacity);
                if (float.IsNaN(mins[bin]) || v < mins[bin]) mins[bin] = v;
                if (float.IsNaN(maxs[bin]) || v > maxs[bin]) maxs[bin] = v;
            }
            return new Envelope(mins, maxs);
        }
    }
}

/// <summary>
/// All plotted series for one EMG source: raw EMG at the source rate, activation at the
/// quasi-tension rate, joint angle and stiffness at the control rate.
/// </summary>
public sealed class PlotBuffers
{
    public double Window { get; private set; }
    public int ChannelCount { get; }
    public SeriesRing Emg { get; }
    /// <summary>Normalised activation 0…1 (or raw quasi-tension before calibration).</summary>
    public SeriesRing Activation { get; }
    /// <summary>[target°, measured left°, measured right° (mirrored back)]</summary>
    public SeriesRing Angle { get; }
    /// <summary>[normalised stiffness 0…100, compliance byte]</summary>
    public SeriesRing Stiffness { get; }

    public PlotBuffers(int channelCount, double emgRate, double qtRate, double controlRate, double window)
    {
        ChannelCount = channelCount;
        Window = window;
        Emg = new SeriesRing(channelCount, (int)(emgRate * window));
        Activation = new SeriesRing(channelCount, (int)(qtRate * window));
        Angle = new SeriesRing(3, (int)(controlRate * window));
        Stiffness = new SeriesRing(2, (int)(controlRate * window));
    }

    public void Resize(double window, double emgRate, double qtRate, double controlRate)
    {
        Window = window;
        Emg.Reset((int)(emgRate * window));
        Activation.Reset((int)(qtRate * window));
        Angle.Reset((int)(controlRate * window));
        Stiffness.Reset((int)(controlRate * window));
    }

    public void ClearControl()
    {
        Angle.Reset();
        Stiffness.Reset();
    }

    public void Push(ControlSample sample, ControlConfiguration c)
    {
        float left = sample.StatusLeft is { } l ? (float)((l.Position - c.ZeroLeft) / c.UnitsPerDegree) : float.NaN;
        float right = float.NaN;
        if (sample.StatusRight is { } r)
        {
            double raw = (r.Position - c.ZeroRight) / c.UnitsPerDegree;
            right = (float)(c.MirrorRight ? -raw : raw);
        }
        Angle.Push([(float)sample.TargetDegrees, left, right]);
        Stiffness.Push([(float)sample.Estimate.NormalizedStiffness, sample.Compliance]);
    }
}
