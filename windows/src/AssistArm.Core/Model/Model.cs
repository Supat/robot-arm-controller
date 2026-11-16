using System.Globalization;
using System.Reflection;
using System.Text.Json.Serialization;
using AssistArm.Signal;

namespace AssistArm.Model;

public sealed class ModelException(string message) : Exception(message);

/// <summary>
/// Single-joint musculoskeletal model from the legacy MSJointStateShin.
///
/// For n muscles the parameter vector p has 2 + 3n entries (plus a trailing centre angle in
/// the file). With activations u:
///
///     numerator   = p[0] + Σ p[1+i]·u[i] + Σ p[1+n+i]·u[i]²
///     denominator = p[1+2n] + Σ p[2+2n+i]·u[i]
///     equilibrium = -numerator / denominator            (radians)
///     stiffness   = -denominator
///
/// The legacy program loaded two parameter sets: param_eq.txt for the equilibrium angle and
/// param_trq.txt for stiffness. Each is a SingleJointModel.
/// </summary>
public sealed class SingleJointModel
{
    public int ChannelCount { get; }
    /// <summary>2 + 3n model coefficients.</summary>
    public double[] Coefficients { get; }
    /// <summary>Joint angle when "straight" (radians); last value of the parameter file.</summary>
    public double CenterAngle { get; }

    public static int ParameterCount(int channelCount) => 2 + 3 * channelCount + 1;

    public SingleJointModel(int channelCount, IReadOnlyList<double> parameters)
    {
        int expected = ParameterCount(channelCount);
        if (parameters.Count != expected)
            throw new ModelException($"Model expects {expected} parameters, file has {parameters.Count}");
        ChannelCount = channelCount;
        Coefficients = parameters.Take(expected - 1).ToArray();
        CenterAngle = parameters[expected - 1];
    }

    /// <summary>Legacy file format: first line is the count, then one number per line.</summary>
    public static SingleJointModel FromText(int channelCount, string text)
    {
        var numbers = new List<double>();
        foreach (var token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out double v)) numbers.Add(v);
        if (numbers.Count == 0 || numbers.Count < (int)numbers[0] + 1)
            throw new ModelException("Cannot read model parameters: expected a count followed by that many numbers");
        int count = (int)numbers[0];
        return new SingleJointModel(channelCount, numbers.GetRange(1, count));
    }

    public static SingleJointModel FromFile(int channelCount, string path)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception e) { throw new ModelException($"Cannot read model parameters: {e.Message}"); }
        return FromText(channelCount, text);
    }

    private void Check(IReadOnlyList<double> u)
    {
        if (u.Count != ChannelCount) throw new ArgumentException("activation count mismatch");
    }

    public double Numerator(IReadOnlyList<double> u)
    {
        Check(u);
        double value = Coefficients[0];
        for (int i = 0; i < ChannelCount; i++) value += Coefficients[1 + i] * u[i];
        for (int i = 0; i < ChannelCount; i++) value += Coefficients[1 + ChannelCount + i] * u[i] * u[i];
        return value;
    }

    public double Denominator(IReadOnlyList<double> u)
    {
        Check(u);
        double value = Coefficients[1 + 2 * ChannelCount];
        for (int i = 0; i < ChannelCount; i++) value += Coefficients[2 + 2 * ChannelCount + i] * u[i];
        return value;
    }

    /// <summary>Equilibrium joint angle in radians.</summary>
    public double Equilibrium(IReadOnlyList<double> u) => -Numerator(u) / Denominator(u);

    /// <summary>Joint stiffness (model units).</summary>
    public double Stiffness(IReadOnlyList<double> u) => -Denominator(u);

    /// <summary>The parameter files shipped with the legacy demo.</summary>
    public static SingleJointModel Bundled(string name, int channelCount = 2)
    {
        var assembly = typeof(SingleJointModel).GetTypeInfo().Assembly;
        using var stream = assembly.GetManifestResourceStream($"AssistArm.Parameters.{name}.txt")
            ?? throw new ModelException($"Cannot read model parameters: bundled {name}.txt missing");
        using var reader = new StreamReader(stream);
        return FromText(channelCount, reader.ReadToEnd());
    }
}

/// <summary>Output of <see cref="JointEstimator"/> for one activation vector.</summary>
/// <param name="Equilibrium">Equilibrium angle, radians.</param>
/// <param name="Stiffness">Stiffness in model units.</param>
/// <param name="NormalizedStiffness">Stiffness scaled to 0…100 within the estimator's stiffness range (clamped).</param>
public readonly record struct JointEstimate(double Equilibrium, double Stiffness, double NormalizedStiffness)
{
    public double EquilibriumDegrees => Equilibrium * 180 / Math.PI;
}

/// <summary>
/// Combines the equilibrium model and the stiffness model, as the legacy program did with
/// msjoint (param_eq) and msjoint_stiff (param_trq).
/// </summary>
public sealed class JointEstimator
{
    public const string EquilibriumFileName = "param_eq.txt";
    public const string TorqueFileName = "param_trq.txt";

    public SingleJointModel EquilibriumModel { get; }
    public SingleJointModel StiffnessModel { get; }
    /// <summary>Stiffness mapped to 0 and 100 respectively.</summary>
    public double StiffnessLow { get; }
    public double StiffnessHigh { get; }

    public JointEstimator(SingleJointModel equilibriumModel, SingleJointModel stiffnessModel, (double Low, double High)? stiffnessRange = null)
    {
        if (equilibriumModel.ChannelCount != stiffnessModel.ChannelCount) throw new ArgumentException("model channel counts differ");
        EquilibriumModel = equilibriumModel;
        StiffnessModel = stiffnessModel;
        var range = stiffnessRange ?? StiffnessExtremes(stiffnessModel);
        StiffnessLow = range.Low;
        StiffnessHigh = range.High;
    }

    /// <summary>The legacy demo's two bundled parameter sets for a two-muscle joint.</summary>
    public static JointEstimator LegacyDefault() =>
        new(SingleJointModel.Bundled("param_eq"), SingleJointModel.Bundled("param_trq"));

    /// <summary>Loads a subject's parameter pair from two legacy-format files.</summary>
    public static JointEstimator FromFiles(string equilibriumPath, string torquePath, int channelCount = 2) =>
        new(SingleJointModel.FromFile(channelCount, equilibriumPath), SingleJointModel.FromFile(channelCount, torquePath));

    /// <summary>Loads param_eq.txt and param_trq.txt from a folder (the legacy parameter/ directory).</summary>
    public static JointEstimator FromFolder(string folder, int channelCount = 2) =>
        FromFiles(Path.Combine(folder, EquilibriumFileName), Path.Combine(folder, TorqueFileName), channelCount);

    public int ChannelCount => EquilibriumModel.ChannelCount;

    /// <summary>
    /// Equilibrium angles (degrees) at rest and with each muscle alone at full activation, for
    /// showing what a parameter set does.
    /// </summary>
    public (double AtRest, double[] PerMuscle) Summary
    {
        get
        {
            int n = ChannelCount;
            double rest = EquilibriumModel.Equilibrium(new double[n]) * 180 / Math.PI;
            var per = new double[n];
            for (int i = 0; i < n; i++)
            {
                var u = new double[n];
                u[i] = 1;
                per[i] = EquilibriumModel.Equilibrium(u) * 180 / Math.PI;
            }
            return (rest, per);
        }
    }

    /// <summary>
    /// Stiffness is linear in the activations, so its extremes over normalised activations in
    /// [0, 1]^n lie at the corners of the cube.
    /// </summary>
    public static (double Low, double High) StiffnessExtremes(SingleJointModel model)
    {
        int n = model.ChannelCount;
        double lo = double.PositiveInfinity, hi = double.NegativeInfinity;
        for (int corner = 0; corner < 1 << n; corner++)
        {
            var u = new double[n];
            for (int i = 0; i < n; i++) u[i] = ((corner >> i) & 1) == 1 ? 1.0 : 0.0;
            double s = model.Stiffness(u);
            lo = Math.Min(lo, s);
            hi = Math.Max(hi, s);
        }
        if (hi <= lo) hi = lo + 1;
        return (lo, hi);
    }

    /// <summary>
    /// The legacy stiffness range: the model evaluated at the raw calibration minimum and maximum
    /// (MSJointStateShin::calcMinStiffness/calcMaxStiffness(daq->dQtMin/dQtMax)).
    /// </summary>
    public static (double Low, double High) LegacyStiffnessRange(SingleJointModel model, ActivationRange rawRange)
    {
        double lo = model.Stiffness(rawRange.Minimum);
        double hi = model.Stiffness(rawRange.Maximum);
        if (hi <= lo) hi = lo + 1e-9;
        return (lo, hi);
    }

    /// <summary>A copy whose 0…100 stiffness scale follows the legacy raw-range convention for <paramref name="rawRange"/>.</summary>
    public JointEstimator WithLegacyStiffnessRange(ActivationRange rawRange) =>
        new(EquilibriumModel, StiffnessModel, LegacyStiffnessRange(StiffnessModel, rawRange));

    public JointEstimate Estimate(IReadOnlyList<double> activation)
    {
        double eq = EquilibriumModel.Equilibrium(activation);
        double stiff = StiffnessModel.Stiffness(activation);
        double span = StiffnessHigh - StiffnessLow;
        double normalized = Math.Min(100, Math.Max(0, (stiff - StiffnessLow) / span * 100));
        return new JointEstimate(eq, stiff, normalized);
    }
}

/// <summary>
/// How estimated joint stiffness is turned into servo compliance, mirroring the legacy radio
/// buttons "linear / low / high / high or low".
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<StiffnessMode>))]
public enum StiffnessMode
{
    /// <summary>Servo stiffness follows normalised joint stiffness between the threshold and 100.</summary>
    Linear,
    /// <summary>Always soft.</summary>
    Low,
    /// <summary>Always stiff.</summary>
    High,
    /// <summary>Soft below the threshold, stiff at or above it.</summary>
    HighOrLow,
}

/// <summary>
/// Maps normalised stiffness (0…100) to a Futaba compliance-slope byte.
///
/// Larger slope = softer servo. The legacy values were 0xFF (soft, "LOW") and 0x32 (stiff,
/// "HIGH"). Linear interpolates from soft at the threshold to stiff at 100.
/// </summary>
public sealed class StiffnessPolicy
{
    public StiffnessMode Mode { get; set; } = StiffnessMode.HighOrLow;

    private double _threshold = 40;
    /// <summary>0…100, the legacy GUI defaulted to 40.</summary>
    public double Threshold { get => _threshold; set => _threshold = Math.Min(100, Math.Max(0, value)); }

    public byte SoftCompliance { get; set; } = 0xFF;
    public byte StiffCompliance { get; set; } = 0x32;

    /// <summary>
    /// How normalised stiffness 0…100 is scaled. True: between the stiffness model's values at
    /// the raw calibration minimum and maximum, as the legacy demo did. False: over the 0…1
    /// activation cube.
    /// </summary>
    public bool LegacyScaling { get; set; } = true;

    /// <summary>Compliance the servo should have before any estimate exists.</summary>
    [JsonIgnore]
    public byte InitialCompliance => Mode == StiffnessMode.High ? StiffCompliance : SoftCompliance;

    public byte Compliance(double normalizedStiffness)
    {
        switch (Mode)
        {
            case StiffnessMode.Low: return SoftCompliance;
            case StiffnessMode.High: return StiffCompliance;
            case StiffnessMode.HighOrLow: return normalizedStiffness < Threshold ? SoftCompliance : StiffCompliance;
            default:
                double span = Math.Max(1e-9, 100 - Threshold);
                double t = Math.Min(1, Math.Max(0, (normalizedStiffness - Threshold) / span));
                double value = SoftCompliance + ((double)StiffCompliance - SoftCompliance) * t;
                return (byte)Math.Clamp((int)Math.Round(value, MidpointRounding.AwayFromZero), 0, 255);
        }
    }

    public StiffnessPolicy Clone() => (StiffnessPolicy)MemberwiseClone();
}
