using AssistArm.Control;

namespace AssistArm.Futaba;

/// <summary>
/// Futaba RS-series (RS30x/RS40x) command servo protocol: short packets, return packets, and
/// the memory-map addresses the controller uses. Bytes follow the legacy ControlServo.cpp.
/// </summary>
public static class FutabaProtocol
{
    /// <summary>Header of packets the host sends.</summary>
    public static readonly byte[] Header = [0xFA, 0xAF];
    /// <summary>Header of return packets the servo sends.</summary>
    public static readonly byte[] ReturnHeader = [0xFD, 0xDF];
    public const int BaudRate = 115200;

    /// <summary>Memory map (RAM) addresses.</summary>
    public static class Address
    {
        public const byte CwComplianceSlope = 0x1A;
        public const byte GoalPosition = 0x1E;
        public const byte MaxTorque = 0x23;
        public const byte TorqueEnable = 0x24;
        public const byte PresentPosition = 0x2A; // 42
    }

    /// <summary>Flag byte of a command packet.</summary>
    public static class Flag
    {
        /// <summary>Write to RAM, no return packet.</summary>
        public const byte Write = 0x00;
        /// <summary>Return packet with memory map 42–59.</summary>
        public const byte ReturnStatus = 0x09;
    }

    public const int StatusReturnLength = 7 + 18 + 1;

    public static byte Checksum(IEnumerable<byte> bytes)
    {
        byte sum = 0;
        foreach (byte b in bytes) sum ^= b;
        return sum;
    }

    /// <summary>Short packet: FA AF ID Flag Addr Len Cnt Data… Sum (Sum = XOR from ID to last data byte).</summary>
    public static byte[] ShortPacket(byte id, byte flag, byte address, ReadOnlySpan<byte> data)
    {
        var packet = new byte[7 + data.Length + 1];
        packet[0] = Header[0];
        packet[1] = Header[1];
        packet[2] = id;
        packet[3] = flag;
        packet[4] = address;
        packet[5] = (byte)data.Length;
        packet[6] = 1;
        data.CopyTo(packet.AsSpan(7));
        byte sum = 0;
        for (int i = 2; i < packet.Length - 1; i++) sum ^= packet[i];
        packet[^1] = sum;
        return packet;
    }

    public static byte[] WriteRam(byte id, byte address, ReadOnlySpan<byte> data) => ShortPacket(id, Flag.Write, address, data);

    public static byte[] Torque(byte id, bool on) => WriteRam(id, Address.TorqueEnable, [(byte)(on ? 1 : 0)]);

    public static byte[] MaxTorque(byte id, byte percent) => WriteRam(id, Address.MaxTorque, [Math.Min((byte)100, percent)]);

    /// <summary>Compliance slope for CW and CCW (addresses 0x1A, 0x1B) in one write.</summary>
    public static byte[] ComplianceSlope(byte id, byte slope) => WriteRam(id, Address.CwComplianceSlope, [slope, slope]);

    /// <summary>Goal position (0.1°) and goal time (10 ms) in one write (addresses 0x1E–0x21).</summary>
    public static byte[] Move(byte id, short position, ushort time)
    {
        ushort p = unchecked((ushort)position);
        return WriteRam(id, Address.GoalPosition, [(byte)(p & 0xFF), (byte)(p >> 8), (byte)(time & 0xFF), (byte)(time >> 8)]);
    }

    /// <summary>Ask for memory map 42–59. The answer is a 26-byte return packet.</summary>
    public static byte[] StatusRequest(byte id) => ShortPacket(id, Flag.ReturnStatus, 0, []);

    /// <summary>A parsed packet (command echo or servo return).</summary>
    public sealed record Packet(byte Id, byte Flag, byte Address, byte Length, byte Count, byte[] Data)
    {
        /// <summary>Above any real servo temperature (°C) and below any real supply voltage (10 mV units).</summary>
        internal const short MaxPlausibleTemperature = 200;

        /// <summary>
        /// Decode the status block (memory map 42–59).
        ///
        /// Models differ after the current field. Some report temperature at 50–51 and voltage at
        /// 52–53. Others (the bench servos answer "… B4 03 00 00 …", 9.48 V) have no temperature
        /// and report voltage at 50–51 with 52–53 left zero. A powered servo never reads 0 V, and
        /// no servo runs at hundreds of °C, so the two are told apart by value.
        /// </summary>
        public ServoStatus Status()
        {
            if (Address != FutabaProtocol.Address.PresentPosition || Data.Length < 12)
                throw ServoException.BadPacket($"expected 18 bytes from address 42, got {Data.Length} from {Address}");
            short I16(int offset) => unchecked((short)(Data[offset] | Data[offset + 1] << 8));
            short word50 = I16(8), word52 = I16(10);
            bool voltageOnly = word52 == 0 && word50 > MaxPlausibleTemperature;
            return new ServoStatus
            {
                Position = I16(0), ElapsedTime = I16(2), Speed = I16(4), Current = I16(6),
                Temperature = voltageOnly ? null : word50,
                Voltage = voltageOnly ? word50 : word52,
                Raw = Data,
            };
        }
    }

    /// <summary>
    /// Scan <paramref name="bytes"/> for the first complete, checksum-valid packet. Returns the
    /// packet and the number of bytes consumed up to and including it, or null if more bytes are
    /// needed. Bytes before a valid header are discarded (RS-485 adapters often echo what we
    /// sent, and the echo is itself a valid packet, so callers filter on flag/length).
    /// </summary>
    public static (Packet Packet, int Consumed)? Parse(IReadOnlyList<byte> bytes)
    {
        int start = 0;
        while (start + 7 <= bytes.Count)
        {
            bool isCommand = bytes[start] == 0xFA && bytes[start + 1] == 0xAF;
            bool isReturn = bytes[start] == 0xFD && bytes[start + 1] == 0xDF;
            if (!isCommand && !isReturn) { start++; continue; }
            int total = 7 + bytes[start + 5] * bytes[start + 6] + 1;
            if (start + total > bytes.Count) return null;
            byte sum = 0;
            for (int i = start + 2; i < start + total - 1; i++) sum ^= bytes[i];
            if (sum == bytes[start + total - 1])
            {
                var data = new byte[total - 8];
                for (int i = 0; i < data.Length; i++) data[i] = bytes[start + 7 + i];
                var packet = new Packet(bytes[start + 2], bytes[start + 3], bytes[start + 4], bytes[start + 5], bytes[start + 6], data);
                return (packet, start + total);
            }
            start++;
        }
        return null;
    }
}
