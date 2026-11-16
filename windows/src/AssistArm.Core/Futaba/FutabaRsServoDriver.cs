using System.Diagnostics;
using AssistArm.Control;

namespace AssistArm.Futaba;

/// <summary>
/// <see cref="IServoDriver"/> for Futaba RS-series servos on an <see cref="IServoTransport"/>.
///
/// Writes use short packets with no return packet. Status reads send a flag-0x09 request and
/// wait for the 26-byte return packet, skipping any echo of the request produced by half-duplex
/// RS-485 adapters.
/// </summary>
public sealed class FutabaRsServoDriver : IServoDriver
{
    public IServoTransport Transport { get; }
    public string Name => $"Futaba RS @ {Transport.Name}";
    /// <summary>How long to wait for a return packet. The legacy code slept 50 ms; servos answer in a few ms.</summary>
    public TimeSpan ReplyTimeout { get; set; } = TimeSpan.FromMilliseconds(60);
    /// <summary>
    /// Minimum idle time on the wire between consecutive packets, measured from the estimated end
    /// of transmission. Servos drop a packet that arrives on the heels of the previous one.
    /// </summary>
    public TimeSpan InterPacketGap { get; set; } = TimeSpan.FromMilliseconds(1);
    /// <summary>Bit rate used to estimate when a written packet has finished leaving the UART.</summary>
    public int BaudRate { get; set; } = FutabaProtocol.BaudRate;
    /// <summary>Purge the adapter's receive buffer before each status request (drops stale bytes).</summary>
    public bool PurgeBeforeRead { get; set; } = true;

    private readonly object _gate = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private bool _isOpen;
    /// <summary>When the bus is expected to be idle again after our last transmission or the last reply.</summary>
    private double _busIdleAt;

    public FutabaRsServoDriver(IServoTransport transport) => Transport = transport;

    public void Open()
    {
        lock (_gate)
        {
            if (_isOpen) return;
            Transport.Open();
            _isOpen = true;
        }
    }

    public void Close()
    {
        lock (_gate)
        {
            if (!_isOpen) return;
            Transport.Close();
            _isOpen = false;
        }
    }

    private void Send(byte[] packet)
    {
        if (!_isOpen) throw ServoException.NotOpen();
        PrecisionClock.SleepUntil(_clock, _busIdleAt + InterPacketGap.TotalSeconds);
        Transport.Write(packet);
        _busIdleAt = _clock.Elapsed.TotalSeconds + packet.Length * 10.0 / Math.Max(1, BaudRate);
    }

    public void SetTorque(byte id, bool enabled) { lock (_gate) Send(FutabaProtocol.Torque(id, enabled)); }
    public void SetMaxTorque(byte id, byte percent) { lock (_gate) Send(FutabaProtocol.MaxTorque(id, percent)); }
    public void SetCompliance(byte id, byte slope) { lock (_gate) Send(FutabaProtocol.ComplianceSlope(id, slope)); }
    public void Move(byte id, short position, ushort time) { lock (_gate) Send(FutabaProtocol.Move(id, position, time)); }

    public ServoStatus ReadStatus(byte id) => ReadReturn(id, FutabaProtocol.Flag.ReturnStatus).Status();

    /// <summary>Send a flag-only request and wait for the servo's return packet.</summary>
    public FutabaProtocol.Packet ReadReturn(byte id, byte flag)
    {
        lock (_gate)
        {
            if (!_isOpen) throw ServoException.NotOpen();
            if (PurgeBeforeRead) Transport.DiscardInput();
            Send(FutabaProtocol.ShortPacket(id, flag, 0, []));
            var buffer = new List<byte>();
            double deadline = _clock.Elapsed.TotalSeconds + ReplyTimeout.TotalSeconds;
            while (true)
            {
                double remaining = deadline - _clock.Elapsed.TotalSeconds;
                if (remaining <= 0) throw ServoException.Timeout(id);
                int want = Math.Max(1, FutabaProtocol.StatusReturnLength - buffer.Count);
                var chunk = Transport.Read(want, TimeSpan.FromSeconds(remaining));
                if (chunk.Length == 0) continue;
                buffer.AddRange(chunk);
                while (FutabaProtocol.Parse(buffer) is var (packet, consumed))
                {
                    buffer.RemoveRange(0, consumed);
                    // Skip the echo of our own request (length 0) or packets from other servos.
                    if (packet.Id != id || packet.Length == 0) continue;
                    _busIdleAt = _clock.Elapsed.TotalSeconds;
                    return packet;
                }
                if (buffer.Count > 256) buffer.RemoveRange(0, buffer.Count - 64);
            }
        }
    }
}
