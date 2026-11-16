using System.IO.Ports;
using System.Net.Sockets;
using AssistArm.Control;

namespace AssistArm.Futaba;

/// <summary>A byte pipe to the servo bus: a serial (COM) port, or a TCP bridge that forwards raw bytes.</summary>
public interface IServoTransport
{
    string Name { get; }
    void Open();
    void Close();
    void Write(byte[] bytes);
    /// <summary>Wait up to <paramref name="timeout"/> for bytes; returns whatever arrived (possibly fewer than <paramref name="count"/>).</summary>
    byte[] Read(int count, TimeSpan timeout);
    void DiscardInput();
}

/// <summary>
/// Serial port transport. On Windows the Futaba RSC-U485 appears as a COM port once Futaba's
/// driver is installed; set its latency timer to 1 ms in Device Manager for prompt replies.
/// </summary>
public sealed class SerialServoTransport : IServoTransport
{
    public string PortName { get; }
    public int BaudRate { get; }
    public string Name => PortName;
    private SerialPort? _port;

    public SerialServoTransport(string portName, int baudRate = FutabaProtocol.BaudRate)
    {
        PortName = portName;
        BaudRate = baudRate;
    }

    public static string[] AvailablePorts()
    {
        try { return SerialPort.GetPortNames().Distinct().OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToArray(); }
        catch (Exception) { return []; }
    }

    public void Open()
    {
        try
        {
            var port = new SerialPort(PortName, BaudRate, Parity.None, 8, StopBits.One)
            {
                Handshake = Handshake.None,
                ReadTimeout = 50,
                WriteTimeout = 500,
            };
            port.Open();
            port.DiscardInBuffer();
            _port = port;
        }
        catch (Exception e) when (e is not ServoException)
        {
            throw ServoException.IO($"cannot open {PortName}: {e.Message}");
        }
    }

    public void Close()
    {
        try { _port?.Close(); } catch (Exception) { /* closing a vanished port */ }
        _port = null;
    }

    public void Write(byte[] bytes)
    {
        var port = _port ?? throw ServoException.NotOpen();
        try { port.Write(bytes, 0, bytes.Length); }
        catch (Exception e) { throw ServoException.IO(e.Message); }
    }

    public byte[] Read(int count, TimeSpan timeout)
    {
        var port = _port ?? throw ServoException.NotOpen();
        var buffer = new byte[count];
        try
        {
            port.ReadTimeout = Math.Max(1, (int)Math.Ceiling(timeout.TotalMilliseconds));
            int n = port.Read(buffer, 0, count);
            return n == count ? buffer : buffer[..n];
        }
        catch (TimeoutException) { return []; }
        catch (Exception e) { throw ServoException.IO(e.Message); }
    }

    public void DiscardInput()
    {
        var port = _port ?? throw ServoException.NotOpen();
        try { port.DiscardInBuffer(); }
        catch (Exception e) { throw ServoException.IO(e.Message); }
    }
}

/// <summary>TCP transport for a serial bridge that forwards raw bytes to an RS-485 adapter.</summary>
public sealed class TcpServoTransport : IServoTransport
{
    public string Host { get; }
    public int Port { get; }
    public string Name => $"tcp://{Host}:{Port}";
    private TcpClient? _client;
    private NetworkStream? _stream;

    public TcpServoTransport(string host, int port)
    {
        Host = host;
        Port = port;
    }

    public void Open()
    {
        try
        {
            var client = new TcpClient { NoDelay = true };
            if (!client.ConnectAsync(Host, Port).Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("connection timed out");
            _client = client;
            _stream = client.GetStream();
        }
        catch (Exception e)
        {
            throw ServoException.IO($"cannot connect to {Name}: {(e.InnerException ?? e).Message}");
        }
    }

    public void Close()
    {
        _stream?.Dispose();
        _client?.Dispose();
        _stream = null;
        _client = null;
    }

    public void Write(byte[] bytes)
    {
        var stream = _stream ?? throw ServoException.NotOpen();
        try { stream.Write(bytes, 0, bytes.Length); }
        catch (Exception e) { throw ServoException.IO(e.Message); }
    }

    public byte[] Read(int count, TimeSpan timeout)
    {
        var stream = _stream ?? throw ServoException.NotOpen();
        var client = _client!;
        try
        {
            if (!client.Client.Poll(timeout, SelectMode.SelectRead)) return [];
            var buffer = new byte[count];
            int n = stream.Read(buffer, 0, count);
            if (n == 0) throw new IOException("the bridge closed the connection");
            return n == count ? buffer : buffer[..n];
        }
        catch (Exception e) when (e is not ServoException) { throw ServoException.IO(e.Message); }
    }

    public void DiscardInput()
    {
        var stream = _stream ?? throw ServoException.NotOpen();
        var scratch = new byte[256];
        try { while (stream.DataAvailable) stream.Read(scratch, 0, scratch.Length); }
        catch (Exception e) { throw ServoException.IO(e.Message); }
    }
}

public static class ServoTransports
{
    /// <summary>"COM3" (or any serial device path) or "tcp://host:port".</summary>
    public static IServoTransport Make(string spec)
    {
        if (spec.StartsWith("tcp://", StringComparison.OrdinalIgnoreCase))
        {
            var rest = spec[6..];
            int colon = rest.LastIndexOf(':');
            if (colon <= 0 || !int.TryParse(rest[(colon + 1)..], out int port))
                throw ServoException.IO($"bad TCP address \"{spec}\" (expected tcp://host:port)");
            return new TcpServoTransport(rest[..colon], port);
        }
        return new SerialServoTransport(spec);
    }
}
