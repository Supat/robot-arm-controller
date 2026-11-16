using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace AssistArm.App;

public enum PlotScaleKind { Auto, Symmetric, Fixed }

/// <summary>One scrolling plot, drawn from a <see cref="SeriesRing"/> as a min/max envelope per pixel column.</summary>
public sealed class PlotStrip : FrameworkElement
{
    public static readonly Color[] Palette =
    [
        Color.FromRgb(0x1F, 0x77, 0xD4), Color.FromRgb(0xF2, 0x8E, 0x2B), Color.FromRgb(0x3A, 0xA6, 0x55),
        Color.FromRgb(0x8E, 0x5B, 0xC9), Color.FromRgb(0xE1, 0x57, 0x8A), Color.FromRgb(0x2A, 0xA1, 0xA1),
    ];

    public string Title { get; set; } = "";
    public string Units { get; set; } = "";
    public SeriesRing? Ring { get; set; }
    public int[] Channels { get; set; } = [];
    public string[] Labels { get; set; } = [];
    public PlotScaleKind Scale { get; set; } = PlotScaleKind.Auto;
    public float FixedLow { get; set; }
    public float FixedHigh { get; set; } = 1;
    public double WindowSeconds { get; set; } = 5;
    public float[] Markers { get; set; } = [];
    /// <summary>Overrides the palette for a single-series plot.</summary>
    public Color? SeriesColor { get; set; }

    private static readonly Typeface LabelFace = new("Segoe UI");
    private static readonly Brush Background = Frozen(new SolidColorBrush(Color.FromArgb(0x10, 0x80, 0x80, 0x80)));
    private static readonly Brush Secondary = Frozen(new SolidColorBrush(Color.FromRgb(0x70, 0x70, 0x70)));
    private static readonly Pen MarkerPen = FrozenPen(new Pen(new SolidColorBrush(Color.FromArgb(0x60, 0x70, 0x70, 0x70)), 0.5) { DashStyle = new DashStyle([8, 6], 0) });
    private static readonly Pen ZeroPen = FrozenPen(new Pen(new SolidColorBrush(Color.FromArgb(0x60, 0x70, 0x70, 0x70)), 0.5));

    private static Brush Frozen(Brush brush) { brush.Freeze(); return brush; }
    private static Pen FrozenPen(Pen pen) { pen.Freeze(); return pen; }

    private Color ColorOf(int i) => SeriesColor ?? Palette[i % Palette.Length];

    private FormattedText Text(string text, Brush brush, bool medium = false) =>
        new(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            medium ? new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Medium, FontStretches.Normal) : LabelFace,
            11, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    protected override void OnRender(DrawingContext dc)
    {
        double width = ActualWidth, height = ActualHeight;
        if (width < 4 || height < 4) return;
        dc.DrawRoundedRectangle(Background, null, new Rect(0, 0, width, height), 6, 6);

        // Title, series labels and units along the top left.
        double x = 6;
        var title = Text(Title, Brushes.Black, medium: true);
        dc.DrawText(title, new Point(x, 3));
        x += title.Width + 8;
        if (Channels.Length > 1 || Labels.Length > 0)
        {
            for (int i = 0; i < Channels.Length && i < Labels.Length; i++)
            {
                var brush = new SolidColorBrush(ColorOf(i));
                var label = Text(Labels[i], brush);
                dc.DrawText(label, new Point(x, 3));
                x += label.Width + 8;
            }
        }
        dc.DrawText(Text(Units, Secondary), new Point(x, 3));

        var ring = Ring;
        if (ring is null || Channels.Length == 0) return;
        int bins = Math.Max(1, (int)width);
        var envelopes = Channels.Select(c => ring.GetEnvelope(c, bins)).ToArray();

        float lo, hi;
        if (Scale == PlotScaleKind.Fixed)
        {
            lo = FixedLow;
            hi = FixedHigh;
        }
        else
        {
            lo = float.PositiveInfinity;
            hi = float.NegativeInfinity;
            foreach (var env in envelopes)
            {
                foreach (float v in env.Mins) if (!float.IsNaN(v) && v < lo) lo = v;
                foreach (float v in env.Maxs) if (!float.IsNaN(v) && v > hi) hi = v;
            }
            if (float.IsInfinity(lo) || float.IsInfinity(hi)) return;
            if (Scale == PlotScaleKind.Symmetric)
            {
                float peak = Math.Max(Math.Max(Math.Abs(lo), Math.Abs(hi)), 1e-9f);
                lo = -peak;
                hi = peak;
            }
            if (hi - lo < 1e-9f) { lo -= 0.5f; hi += 0.5f; }
            float pad = (hi - lo) * 0.08f;
            lo -= pad;
            hi += pad;
        }

        const double topInset = 18;
        double plotHeight = height - topInset;
        double Y(float v) => topInset + (hi - v) / (hi - lo) * plotHeight;

        foreach (float m in Markers) dc.DrawLine(m == 0 ? ZeroPen : MarkerPen, new Point(0, Y(m)), new Point(width, Y(m)));
        if (lo < 0 && hi > 0 && !Markers.Contains(0f)) dc.DrawLine(ZeroPen, new Point(0, Y(0)), new Point(width, Y(0)));

        for (int i = 0; i < envelopes.Length; i++)
        {
            var env = envelopes[i];
            if (env.IsEmpty) continue;
            int count = env.Mins.Length;
            double dx = width / count;
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                bool started = false;
                for (int b = 0; b < count; b++)
                {
                    if (float.IsNaN(env.Mins[b])) continue;
                    double px = (b + 0.5) * dx;
                    var p1 = new Point(px, Y(env.Mins[b]));
                    if (started) g.LineTo(p1, true, false);
                    else { g.BeginFigure(p1, false, false); started = true; }
                    if (env.Maxs[b] != env.Mins[b]) g.LineTo(new Point(px, Y(env.Maxs[b])), true, false);
                }
            }
            geometry.Freeze();
            var pen = new Pen(new SolidColorBrush(ColorOf(i)), 1);
            pen.Freeze();
            dc.DrawGeometry(null, pen, geometry);
        }

        var range = Text($"{Format(hi)}  /  {Format(lo)}  ·  {(int)WindowSeconds} s", Secondary);
        dc.DrawText(range, new Point(width - range.Width - 6, 3));
    }

    private static string Format(float v)
    {
        float a = Math.Abs(v);
        if (a != 0 && (a < 0.01f || a >= 10000f)) return v.ToString("0.00e+0", CultureInfo.InvariantCulture);
        return v.ToString("G3", CultureInfo.InvariantCulture);
    }
}
