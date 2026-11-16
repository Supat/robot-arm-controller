using System.Diagnostics;
using AssistArm.Model;
using AssistArm.Signal;

namespace AssistArm.Control;

/// <summary>Servo-side settings of the control loop. Angles the servo understands are 0.1° units.</summary>
public sealed class ControlConfiguration
{
    public byte LeftServoId { get; set; } = 1;
    public byte RightServoId { get; set; } = 2;
    /// <summary>The right servo turns the opposite way (legacy: -target + zero_R).</summary>
    public bool MirrorRight { get; set; } = true;
    /// <summary>Positions read while the arm hung at rest after zeroing, 0.1° units.</summary>
    public short ZeroLeft { get; set; }
    public short ZeroRight { get; set; }
    /// <summary>Servo units per degree of joint angle. Futaba uses 10; the legacy code used 8.</summary>
    public double UnitsPerDegree { get; set; } = 10;
    /// <summary>Joint angle clamp either side of zero, degrees (legacy ±90).</summary>
    public double AngleLimitDegrees { get; set; } = 90;
    /// <summary>Control loop rate: EMG processing, model evaluation and compliance updates.</summary>
    public double UpdateRate { get; set; } = 50;
    /// <summary>
    /// How often a goal position is written to the servos. Futaba RS servos restart their motion
    /// on every goal command, so writing at the loop rate makes them crawl. The default is the
    /// legacy loop's real cadence (about 6 Hz).
    /// </summary>
    public double GoalUpdateRate { get; set; } = 6;
    /// <summary>How often servo status (angle, current) is read back for display and logging.</summary>
    public double StatusPollRate { get; set; } = 5;
    /// <summary>Legacy set 75 % at zeroing.</summary>
    public byte MaxTorquePercent { get; set; } = 75;
    /// <summary>Travel time per goal, 10 ms units (0 = fastest).</summary>
    public ushort MoveTime { get; set; }
    public StiffnessPolicy Stiffness { get; set; } = new();

    public ControlConfiguration Clone()
    {
        var copy = (ControlConfiguration)MemberwiseClone();
        copy.Stiffness = Stiffness.Clone();
        return copy;
    }
}

/// <summary>One tick of the control loop, for plots and the CSV log.</summary>
public sealed record ControlSample
{
    /// <summary>Seconds since the controller started.</summary>
    public double Time { get; init; }
    public double[] QuasiTension { get; init; } = [];
    public double[] Activation { get; init; } = [];
    public JointEstimate Estimate { get; init; }
    public byte Compliance { get; init; }
    /// <summary>Commanded goals, 0.1° servo units, zero offsets included.</summary>
    public short TargetLeft { get; init; }
    public short TargetRight { get; init; }
    /// <summary>Last status read-back, if any (updated at the status poll rate).</summary>
    public ServoStatus? StatusLeft { get; init; }
    public ServoStatus? StatusRight { get; init; }
    /// <summary>Commanded joint angle, degrees, zero offset removed.</summary>
    public double TargetDegrees { get; init; }
}

public sealed class ControllerException(string message) : Exception(message)
{
    public static ControllerException ChannelMismatch(int source, int model) =>
        new($"EMG source has {source} channels but the model expects {model}.");
}

/// <summary>
/// The legacy EstMykin loop: quasi-tension → normalised activation → equilibrium angle and
/// stiffness → servo goals and compliance, at a fixed rate with periodic status read-back.
/// The loop runs on its own thread so its timing does not depend on the UI or the thread pool.
/// </summary>
public sealed class AssistController
{
    /// <summary>Hard limit on commanded servo position, 0.1° units (legacy ±900).</summary>
    public const short ServoPositionLimit = 900;

    public QuasiTensionPipeline Pipeline { get; }
    public IServoDriver Servo { get; }

    private volatile JointEstimator _estimator;
    private volatile ActivationRange _range;
    private volatile ControlConfiguration _configuration;
    private volatile QuasiTensionSample? _latest;
    private volatile bool _isRunning;
    private readonly SemaphoreSlim _transition = new(1, 1);
    private Thread? _loop;
    private byte? _compliance;
    private ServoStatus? _statusLeft, _statusRight;

    /// <summary>Raised on the control thread for every tick.</summary>
    public event Action<ControlSample>? Sample;
    /// <summary>Raised on the control thread when a servo call fails; the controller then stops.</summary>
    public event Action<Exception>? Error;

    public bool IsRunning => _isRunning;

    public AssistController(QuasiTensionPipeline pipeline, IServoDriver servo, JointEstimator estimator,
                            ActivationRange range, ControlConfiguration? configuration = null)
    {
        if (pipeline.ChannelCount != estimator.ChannelCount)
            throw ControllerException.ChannelMismatch(pipeline.ChannelCount, estimator.ChannelCount);
        Pipeline = pipeline;
        Servo = servo;
        _estimator = estimator;
        _range = range;
        _configuration = (configuration ?? new ControlConfiguration()).Clone();
        pipeline.AddQuasiTensionSink(sample => _latest = sample);
    }

    public void Update(ControlConfiguration configuration) => _configuration = configuration.Clone();
    public void Update(ActivationRange range) => _range = range;
    public void Update(JointEstimator estimator) => _estimator = estimator;

    public async Task StartAsync()
    {
        await _transition.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_isRunning) return;
            _latest = null;
            _compliance = null;
            _statusLeft = _statusRight = null;
            var c = _configuration;
            await Task.Run(() =>
            {
                foreach (byte id in new[] { c.LeftServoId, c.RightServoId })
                {
                    Servo.SetTorque(id, true);
                    Servo.SetCompliance(id, c.Stiffness.InitialCompliance);
                }
            }).ConfigureAwait(false);
            _compliance = c.Stiffness.InitialCompliance;
            await Pipeline.StartAsync().ConfigureAwait(false);
            _isRunning = true;
            _loop = new Thread(Run) { IsBackground = true, Name = "Assist control loop", Priority = ThreadPriority.AboveNormal };
            _loop.Start();
        }
        finally
        {
            _transition.Release();
        }
    }

    public async Task StopAsync()
    {
        await _transition.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!_isRunning) return;
            _isRunning = false;
            var loop = _loop;
            _loop = null;
            if (loop is not null && loop != Thread.CurrentThread) await Task.Run(() => loop.Join(2000)).ConfigureAwait(false);
            await Pipeline.StopAsync().ConfigureAwait(false);
            var c = _configuration;
            await Task.Run(() =>
            {
                foreach (byte id in new[] { c.LeftServoId, c.RightServoId })
                {
                    try { Servo.SetTorque(id, false); } catch (Exception) { /* the link may already be gone */ }
                }
            }).ConfigureAwait(false);
        }
        finally
        {
            _transition.Release();
        }
    }

    private void Run()
    {
        var clock = Stopwatch.StartNew();
        long tick = 0;
        double lastStatusPoll = double.NegativeInfinity;
        double lastGoalWrite = double.NegativeInfinity;
        while (_isRunning)
        {
            var c = _configuration;
            double period = 1 / Math.Max(1, c.UpdateRate);
            double now = clock.Elapsed.TotalSeconds;
            var sample = _latest;
            if (sample is not null)
            {
                try
                {
                    bool pollStatus = now - lastStatusPoll >= 1 / Math.Max(0.1, c.StatusPollRate);
                    if (pollStatus) lastStatusPoll = now;
                    bool writeGoal = now - lastGoalWrite >= 1 / Math.Max(0.1, c.GoalUpdateRate) - period / 2;
                    if (writeGoal) lastGoalWrite = now;
                    var output = Step(c, sample, now, writeGoal, pollStatus);
                    Sample?.Invoke(output);
                }
                catch (Exception error)
                {
                    Error?.Invoke(error);
                    // Stop without joining this thread.
                    _ = Task.Run(StopAsync);
                    return;
                }
            }
            tick++;
            PrecisionClock.SleepUntil(clock, tick * period);
        }
    }

    private ControlSample Step(ControlConfiguration c, QuasiTensionSample sample, double time, bool writeGoal, bool pollStatus)
    {
        var range = _range;
        var activation = range.Normalize(sample.Values);
        var estimator = c.Stiffness.LegacyScaling ? _estimator.WithLegacyStiffnessRange(range) : _estimator;
        var estimate = estimator.Estimate(activation);

        byte wanted = c.Stiffness.Compliance(estimate.NormalizedStiffness);
        if (wanted != _compliance)
        {
            Servo.SetCompliance(c.LeftServoId, wanted);
            Servo.SetCompliance(c.RightServoId, wanted);
            _compliance = wanted;
        }

        double limit = c.AngleLimitDegrees;
        double degrees = Math.Min(limit, Math.Max(-limit, estimate.EquilibriumDegrees));
        int units = (int)Math.Round(degrees * c.UnitsPerDegree, MidpointRounding.AwayFromZero);
        // Legacy clamped the absolute servo position to ±900 (the servos' ±90° range) after
        // adding the zero offset, so a non-zero offset cannot push a goal past the end stop.
        short left = (short)Math.Clamp(units + c.ZeroLeft, -ServoPositionLimit, ServoPositionLimit);
        short right = (short)Math.Clamp((c.MirrorRight ? -units : units) + c.ZeroRight, -ServoPositionLimit, ServoPositionLimit);
        if (writeGoal)
        {
            Servo.Move(c.LeftServoId, left, c.MoveTime);
            Servo.Move(c.RightServoId, right, c.MoveTime);
        }

        if (pollStatus)
        {
            _statusLeft = Servo.ReadStatus(c.LeftServoId);
            _statusRight = Servo.ReadStatus(c.RightServoId);
        }

        return new ControlSample
        {
            Time = time, QuasiTension = sample.Values, Activation = activation, Estimate = estimate, Compliance = wanted,
            TargetLeft = left, TargetRight = right, StatusLeft = _statusLeft, StatusRight = _statusRight, TargetDegrees = degrees,
        };
    }
}

/// <summary>
/// Servo bring-up as in the legacy "Init Servo" button: torque on, soft compliance, drive both
/// to 0, wait, read the resting positions, limit torque, torque off.
/// </summary>
public static class ServoSetup
{
    public sealed record ZeroResult(ServoStatus Left, ServoStatus Right);

    public static ZeroResult Zero(IServoDriver servo, ControlConfiguration c, TimeSpan? settle = null)
    {
        foreach (byte id in new[] { c.LeftServoId, c.RightServoId })
        {
            servo.SetTorque(id, true);
            servo.SetCompliance(id, 0xFF);
            servo.Move(id, 0, 0);
        }
        Thread.Sleep(settle ?? TimeSpan.FromSeconds(1));
        var left = servo.ReadStatus(c.LeftServoId);
        var right = servo.ReadStatus(c.RightServoId);
        foreach (byte id in new[] { c.LeftServoId, c.RightServoId })
        {
            servo.SetMaxTorque(id, c.MaxTorquePercent);
            servo.SetTorque(id, false);
        }
        return new ZeroResult(left, right);
    }
}
