import AssistArmCore
import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.serial
#endif

/// A serial device the system knows about.
public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    /// Callout device, e.g. `/dev/cu.usbserial-AB0JQ9I2`.
    public var path: String
    /// USB product name when available, else the tty base name.
    public var name: String
    public var id: String { path }

    /// Serial ports present right now, USB adapters first. Direct-USB FTDI adapters that macOS
    /// has no driver for (the Futaba RSC-U485) are listed too, with a `usb://` path.
    public static func available() -> [SerialPortInfo] {
        let direct = FTDIDeviceInfo.available().map { SerialPortInfo(path: $0.spec, name: $0.displayName) }
        return direct + serialDevices()
    }

    /// Serial devices with a `/dev/cu.*` node.
    static func serialDevices() -> [SerialPortInfo] {
        var ports: [SerialPortInfo] = []
        #if canImport(IOKit)
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return fallback() }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return fallback() }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            let tty = IORegistryEntryCreateCFProperty(service, kIOTTYDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            let product = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault,
                                                          IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
            ports.append(SerialPortInfo(path: path, name: product ?? tty ?? path))
        }
        #else
        ports = fallback()
        #endif
        return ports.sorted { a, b in
            let ua = a.path.contains("usb"), ub = b.path.contains("usb")
            return ua != ub ? ua : a.path < b.path
        }
    }

    private static func fallback() -> [SerialPortInfo] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") }
            .map { SerialPortInfo(path: "/dev/\($0)", name: $0) }
    }
}

/// POSIX serial port, 8N1, raw mode. Blocking I/O runs on a private queue so callers can await it.
public final class SerialPort: ServoTransport, @unchecked Sendable {
    public let path: String
    public let baudRate: Int
    public var name: String { path }

    private let queue = DispatchQueue(label: "assistarm.serial")
    private var fd: Int32 = -1

    public init(path: String, baudRate: Int = Futaba.baudRate) {
        self.path = path
        self.baudRate = baudRate
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    public func open() async throws {
        try await run { [self] in
            guard fd < 0 else { return }
            let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard handle >= 0 else { throw ServoError.io("open \(path): \(String(cString: strerror(errno)))") }
            // Exclusive access, then back to blocking reads (we use poll for timeouts).
            _ = ioctl(handle, TIOCEXCL)
            _ = fcntl(handle, F_SETFL, 0)

            var options = termios()
            guard tcgetattr(handle, &options) == 0 else {
                Darwin.close(handle)
                throw ServoError.io("tcgetattr: \(String(cString: strerror(errno)))")
            }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE | CRTSCTS)
            options.c_cflag |= tcflag_t(CS8)
            withUnsafeMutablePointer(to: &options.c_cc) { ptr in
                ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                    cc[Int(VMIN)] = 0
                    cc[Int(VTIME)] = 0
                }
            }
            guard cfsetspeed(&options, speed_t(baudRate)) == 0, tcsetattr(handle, TCSANOW, &options) == 0 else {
                Darwin.close(handle)
                throw ServoError.io("cannot configure \(path) at \(baudRate) bps")
            }
            tcflush(handle, TCIOFLUSH)
            fd = handle
        }
    }

    public func close() async {
        try? await run { [self] in
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await run { [self] in
            guard fd >= 0 else { throw ServoError.notOpen }
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw ServoError.io("write: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
            tcdrain(fd)
        }
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        try await run { [self] in
            guard fd >= 0 else { throw ServoError.notOpen }
            var out: [UInt8] = []
            out.reserveCapacity(count)
            let deadline = ContinuousClock.now + timeout
            var chunk = [UInt8](repeating: 0, count: count)
            while out.count < count {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = Int32(min(Int64(remaining / .milliseconds(1)), 1000))
                let ready = poll(&pfd, 1, max(1, ms))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ServoError.io("poll: \(String(cString: strerror(errno)))")
                }
                if ready == 0 { break }
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, count - out.count) }
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw ServoError.io("read: \(String(cString: strerror(errno)))")
                }
                if n == 0 { break }
                out += chunk[0..<n]
            }
            return out
        }
    }

    public func discardInput() async throws {
        try await run { [self] in
            guard fd >= 0 else { throw ServoError.notOpen }
            tcflush(fd, TCIFLUSH)
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
