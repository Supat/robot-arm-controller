using System.Diagnostics;

namespace AssistArm.Control;

/// <summary>Status block of a servo (Futaba memory map 42–59).</summary>
public sealed record ServoStatus
{
    /// <summary>Present position, 0.1° units.</summary>
    public short Position { get; init; }
    /// <summary>Elapsed time of the current move, 10 ms units.</summary>
    public short ElapsedTime { get; init; }
    /// <summary>Present speed, °/s.</summary>
    public short Speed { get; init; }
    /// <summary>Present load (current), mA.</summary>
    public short Current { get; init; }
    /// <summary>°C, or null when the servo model does not report a temperature.</summary>
    public short? Temperature { get; init; }
    /// <summary>10 mV units.</summary>
    public short Voltage { get; init; }
    /// <summary>The 18 raw bytes of memory map 42–59 as received, for bench diagnostics (empty for mocks).</summary>
    public byte[] Raw { get; init; } = [];

    public double PositionDegrees => Position / 10.0;
    public double Volts => Voltage / 100.0;
}

public enum ServoErrorKind { NotOpen, IO, Timeout, BadPacket, Unsupported }

public sealed class ServoException : Exception
{
    public ServoErrorKind Kind { get; }
    public ServoException(ServoErrorKind kind, string message) : base(message) => Kind = kind;

    public static ServoException NotOpen() => new(ServoErrorKind.NotOpen, "Servo link is not open.");
    public static ServoException IO(string detail) => new(ServoErrorKind.IO, $"Servo link I/O error: {detail}");
    public static ServoException Timeout(byte id) => new(ServoErrorKind.Timeout, $"Servo {id} did not answer.");
    public static ServoException BadPacket(string detail) => new(ServoErrorKind.BadPacket, $"Malformed servo packet: {detail}");
}

/// <summary>
/// The operations the controller needs from a position-controlled servo bus. Positions are in
/// 0.1° (Futaba convention); compliance follows the Futaba slope byte. Calls block until the
/// bytes are written (or the reply has arrived), so use them from a worker thread.
/// </summary>
public interface IServoDriver
{
    string Name { get; }
    void Open();
    void Close();
    void SetTorque(byte id, bool enabled);
    /// <summary>0…100 % of rated torque.</summary>
    void SetMaxTorque(byte id, byte percent);
    /// <summary>Compliance slope for both directions. Larger = softer.</summary>
    void SetCompliance(byte id, byte slope);
    /// <summary>Goal position in 0.1°, travel time in 10 ms units (0 = as fast as possible).</summary>
    void Move(byte id, short position, ushort time);
    ServoStatus ReadStatus(byte id);
}

/// <summary>
/// A servo bus that only exists in memory: each servo approaches its goal with a first-order
/// lag whose time constant grows with the compliance slope. Good enough to drive the UI.
/// </summary>
public sealed class MockServoDriver : IServoDriver
{
    public string Name => "Simulated servos";

    private sealed class Servo
    {
        public bool Torque;
        public short Goal;
        public double Position;
        public byte Compliance = 0xFF;
        public byte MaxTorque = 100;
        public double LastUpdate;
    }

    private readonly Dictionary<byte, Servo> _servos = [];
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly object _gate = new();
    private bool _isOpen;
    /// <summary>Offset reported as "mechanical zero", to exercise zeroing code.</summary>
    public short RestingPosition { get; set; }

    private Servo Get(byte id)
    {
        double now = _clock.Elapsed.TotalSeconds;
        if (!_servos.TryGetValue(id, out var s))
        {
            s = new Servo { Position = RestingPosition, LastUpdate = now };
            _servos[id] = s;
        }
        double dt = Math.Max(0, now - s.LastUpdate);
        if (s.Torque)
        {
            // 0x32 ≈ 60 ms, 0xFF ≈ 250 ms time constant.
            double tau = 0.04 + 0.21 * s.Compliance / 255;
            double alpha = 1 - Math.Exp(-dt / tau);
            s.Position += (s.Goal - s.Position) * alpha;
        }
        s.LastUpdate = now;
        return s;
    }

    private Servo Checked(byte id)
    {
        if (!_isOpen) throw ServoException.NotOpen();
        return Get(id);
    }

    public void Open() { lock (_gate) _isOpen = true; }
    public void Close() { lock (_gate) _isOpen = false; }
    public void SetTorque(byte id, bool enabled) { lock (_gate) Checked(id).Torque = enabled; }
    public void SetMaxTorque(byte id, byte percent) { lock (_gate) Checked(id).MaxTorque = percent; }
    public void SetCompliance(byte id, byte slope) { lock (_gate) Checked(id).Compliance = slope; }
    public void Move(byte id, short position, ushort time) { lock (_gate) Checked(id).Goal = position; }

    public ServoStatus ReadStatus(byte id)
    {
        lock (_gate)
        {
            var s = Checked(id);
            short load = s.Torque ? (short)Math.Min(2000, Math.Abs(s.Goal - s.Position) * 2) : (short)0;
            return new ServoStatus
            {
                Position = (short)Math.Round(s.Position, MidpointRounding.AwayFromZero),
                Current = load, Temperature = 32, Voltage = 740,
            };
        }
    }
}
