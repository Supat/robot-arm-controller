using System.Globalization;
using System.Text;

namespace AssistArm.Control;

/// <summary>CSV log of every control tick, replacing the legacy ./LinearData/*.txt dumps.</summary>
public sealed class TelemetryLog : IDisposable
{
    public string Path { get; }
    private readonly StreamWriter _writer;
    private readonly object _gate = new();

    public TelemetryLog(string path, int channelCount)
    {
        Path = path;
        var folder = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);
        _writer = new StreamWriter(path, false, new UTF8Encoding(false), 16 * 1024) { NewLine = "\n" };
        var header = new List<string> { "time_s" };
        for (int i = 0; i < channelCount; i++) header.Add($"qt{i + 1}");
        for (int i = 0; i < channelCount; i++) header.Add($"activation{i + 1}");
        header.AddRange(["eq_deg", "stiffness", "nstiffness", "compliance", "target_deg", "goal_left", "goal_right",
                         "pos_left_deg", "pos_right_deg", "current_left_mA", "current_right_mA"]);
        _writer.WriteLine(string.Join(",", header));
    }

    private static string F(double v, int digits = 4) => v.ToString("F" + digits, CultureInfo.InvariantCulture);

    public void Write(ControlSample s)
    {
        var fields = new List<string> { F(s.Time) };
        fields.AddRange(s.QuasiTension.Select(v => F(v, 8)));
        fields.AddRange(s.Activation.Select(v => F(v)));
        fields.AddRange([
            F(s.Estimate.EquilibriumDegrees), F(s.Estimate.Stiffness), F(s.Estimate.NormalizedStiffness),
            s.Compliance.ToString(CultureInfo.InvariantCulture), F(s.TargetDegrees),
            s.TargetLeft.ToString(CultureInfo.InvariantCulture), s.TargetRight.ToString(CultureInfo.InvariantCulture),
            s.StatusLeft is null ? "" : F(s.StatusLeft.PositionDegrees), s.StatusRight is null ? "" : F(s.StatusRight.PositionDegrees),
            s.StatusLeft?.Current.ToString(CultureInfo.InvariantCulture) ?? "", s.StatusRight?.Current.ToString(CultureInfo.InvariantCulture) ?? "",
        ]);
        lock (_gate) _writer.WriteLine(string.Join(",", fields));
    }

    public void Finish()
    {
        lock (_gate) _writer.Dispose();
    }

    public void Dispose() => Finish();
}
