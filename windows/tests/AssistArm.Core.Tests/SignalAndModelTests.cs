using AssistArm.Model;
using AssistArm.Signal;

namespace AssistArm.Tests;

public class SignalTests
{
    [Fact]
    public void KoikeCoefficientsMatchLegacy()
    {
        var f = new KoikeFilter();
        Assert.Equal(100, f.TapCount);
        Assert.Equal(1, f.Coefficients.Sum(), 12);
        // Legacy: coef[i] = 6.44*(exp(-10.8 t) - exp(-16.52 t)), t = 0.005 i, then normalised.
        var raw = Enumerable.Range(0, 100).Select(i => 6.44 * (Math.Exp(-10.8 * 0.005 * i) - Math.Exp(-16.52 * 0.005 * i))).ToArray();
        double sum = raw.Sum();
        for (int i = 0; i < 100; i++) Assert.Equal(raw[i] / sum, f.Coefficients[i], 15);
        Assert.Equal(0, f.Coefficients[0], 15); // h(0) = 0
        Assert.True(f.Coefficients[20] > f.Coefficients[90]);
    }

    [Fact]
    public void KoikeStepResponseReachesUnity()
    {
        var f = new KoikeFilter();
        double y = 0;
        for (int i = 0; i < 100; i++) y = f.Push(1);
        Assert.Equal(1, y, 9);
        for (int i = 0; i < 100; i++) y = f.Push(0);
        Assert.Equal(0, y, 9);
    }

    [Fact]
    public void QuasiTensionDecimatesAndRectifies()
    {
        var p = new QuasiTensionProcessor(2000, 2);
        Assert.Equal(10, p.Decimation);
        Assert.Equal(200, p.OutputRate);
        // Constant ±1 square wave on ch0, zeros on ch1: mean |x| = 1 on ch0.
        var samples = new float[4000];
        for (int row = 0; row < 2000; row++) samples[row * 2] = row % 2 == 0 ? 1 : -1;
        var output = p.Process(new EmgBlock(2000, 2, samples, 0));
        Assert.Equal(200, output.Count);
        Assert.Equal(199, output[^1].Index);
        Assert.Equal(1, output[^1].Values[0], 9); // 1 s in, filter has settled
        Assert.Equal(0, output[^1].Values[1], 12);
        Assert.True(output[5].Values[0] < 0.5); // still rising early on

        // Partial blocks carry over.
        var q = new QuasiTensionProcessor(2000, 1);
        var a = q.Process(new EmgBlock(2000, 1, Enumerable.Repeat(1f, 7).ToArray(), 0));
        var b = q.Process(new EmgBlock(2000, 1, Enumerable.Repeat(1f, 3).ToArray(), 7));
        Assert.Empty(a);
        Assert.Single(b);
    }

    [Fact]
    public void MinMaxCalibrationSkipsFirstSecond()
    {
        var c = new MinMaxCalibration(2, 200, 1);
        for (int i = 0; i < 400; i++)
        {
            // Huge transient in the first second must be ignored.
            double v = i < 200 ? 100.0 : i % 10 / 10.0;
            c.Add(new QuasiTensionSample([v, v * 2], i));
        }
        var r = c.Finish();
        Assert.Equal([0.0, 0.0], r.Minimum);
        Assert.Equal([0.9, 1.8], r.Maximum);
        Assert.Equal(2, c.ElapsedSeconds, 9);
        Assert.Equal(0.5, r.Normalize(0.45, 0), 12);
        Assert.Equal(0, r.Normalize(-1, 0));
        Assert.Equal(1, r.Normalize(5, 1));

        Assert.Equal(ActivationRange.Identity(2), new MinMaxCalibration(2).Finish());
    }
}

public class ModelTests
{
    // param_eq.txt and param_trq.txt from the legacy demo.
    private static readonly double[] EqParams = [4.76194, 21224.7, -5982.69, 192.182, -1244.74, -14.4463, -13990, -6807.12, 0.0];
    private static readonly double[] TrqParams = [22.5173, 27360.5, -11043, 0.00236232, -3.45335e-005, -52.8076, -6824.3, -20.7912, 0.430399];

    [Fact]
    public void BundledParametersLoad()
    {
        var eq = SingleJointModel.Bundled("param_eq");
        var trq = SingleJointModel.Bundled("param_trq");
        Assert.Equal(EqParams[..^1], eq.Coefficients);
        Assert.Equal(0, eq.CenterAngle);
        Assert.Equal(TrqParams[..^1], trq.Coefficients);
        Assert.Equal(0.430399, trq.CenterAngle);
    }

    [Fact]
    public void FileFormatParsing()
    {
        var m = SingleJointModel.FromText(2, "9\n1\n2\n3\n4\n5\n6\n7\n8\n0.5\n");
        Assert.Equal([1.0, 2, 3, 4, 5, 6, 7, 8], m.Coefficients);
        Assert.Equal(0.5, m.CenterAngle);
        Assert.Throws<ModelException>(() => SingleJointModel.FromText(2, "3\n1\n2\n3\n"));
        Assert.Throws<ModelException>(() => new SingleJointModel(2, [1, 2, 3]));
    }

    [Fact]
    public void EquilibriumMatchesLegacyFormula()
    {
        var m = new SingleJointModel(2, EqParams);
        double[] u = [0.3, 0.1];
        double num = 4.76194 + 21224.7 * 0.3 + -5982.69 * 0.1 + 192.182 * 0.09 + -1244.74 * 0.01;
        double den = -14.4463 + -13990 * 0.3 + -6807.12 * 0.1;
        Assert.Equal(-num / den, m.Equilibrium(u), 12);
        Assert.Equal(-den, m.Stiffness(u), 12);
        // Relaxed arm: 4.76194 / 14.4463 rad ≈ 18.9°.
        Assert.InRange(m.Equilibrium([0, 0]) * 180 / Math.PI, 18.876, 18.896);
    }

    [Fact]
    public void EstimatorNormalisesStiffnessOverUnitCube()
    {
        var est = JointEstimator.LegacyDefault();
        // stiffness = 52.8076 + 6824.3 u1 + 20.7912 u2 → min at (0,0), max at (1,1).
        Assert.Equal(52.8076, est.StiffnessLow, 9);
        Assert.Equal(52.8076 + 6824.3 + 20.7912, est.StiffnessHigh, 9);
        Assert.Equal(0, est.Estimate([0, 0]).NormalizedStiffness, 9);
        Assert.Equal(100, est.Estimate([1, 1]).NormalizedStiffness, 9);
        Assert.Equal(6824.3 * 0.5 / (6824.3 + 20.7912) * 100, est.Estimate([0.5, 0]).NormalizedStiffness, 9);
        Assert.Equal(100, est.Estimate([2, 2]).NormalizedStiffness); // clamped
    }

    [Fact]
    public void StiffnessPolicyModes()
    {
        var p = new StiffnessPolicy { Mode = StiffnessMode.HighOrLow, Threshold = 40 };
        Assert.Equal(0xFF, p.Compliance(39.9));
        Assert.Equal(0x32, p.Compliance(40));
        Assert.Equal(0xFF, p.InitialCompliance);
        p.Mode = StiffnessMode.Low;
        Assert.Equal(0xFF, p.Compliance(100));
        p.Mode = StiffnessMode.High;
        Assert.Equal(0x32, p.Compliance(0));
        Assert.Equal(0x32, p.InitialCompliance);
        p.Mode = StiffnessMode.Linear;
        Assert.Equal(0xFF, p.Compliance(0));
        Assert.Equal(0xFF, p.Compliance(40));
        Assert.Equal(0x32, p.Compliance(100));
        Assert.Equal((byte)Math.Round(255.0 + (50.0 - 255.0) * 0.5, MidpointRounding.AwayFromZero), p.Compliance(70));
    }

    [Fact]
    public void LegacyStiffnessScalingIsStiffForEitherMuscle()
    {
        var est = JointEstimator.LegacyDefault();
        // Trigno-scale quasi-tension in volts.
        var raw = new ActivationRange([2.5e-5, 2.9e-6], [6.6e-5, 3.4e-6]);
        var legacy = est.WithLegacyStiffnessRange(raw);
        Assert.Equal(0, legacy.Estimate([0, 0]).NormalizedStiffness, 6);
        Assert.Equal(100, legacy.Estimate([0, 0.2]).NormalizedStiffness, 6); // extensor alone → stiff
        Assert.Equal(100, legacy.Estimate([0.2, 0]).NormalizedStiffness, 6);
        // Cube scaling: extensor alone stays nearly 0 with these parameters.
        Assert.True(est.Estimate([0, 1]).NormalizedStiffness < 1);
        Assert.True(est.Estimate([1, 0]).NormalizedStiffness > 99);
    }
}
