import AssistArmCore
import Foundation
#if canImport(IOUSBHost)
import IOKit
import IOUSBHost
#endif

/// FTDI-style USB-to-serial adapters that macOS has no serial driver for.
///
/// The Futaba RSC-U485 is an FTDI FT232R programmed with Futaba's own USB vendor ID (0x1115),
/// so Apple's FTDI driver never attaches and no `/dev/cu.*` node appears. `FTDIUSBTransport`
/// speaks the FTDI vendor protocol directly over `IOUSBHost` instead, which needs no driver
/// and no kernel extension.
public struct FTDIDeviceInfo: Identifiable, Hashable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// USB location ID; stable for a given physical port.
    public var locationID: UInt32
    public var productName: String
    public var serialNumber: String?

    /// Spec string understood by `ServoTransports.make(_:)`, e.g. `usb://1115:0008@10344000`.
    public var spec: String { String(format: "usb://%04x:%04x@%08x", vendorID, productID, locationID) }
    public var id: String { spec }
    public var displayName: String { "\(productName) (direct USB)" }

    /// Vendor/product pairs known to be FTDI silicon.
    public static let knownIDs: [(vendor: UInt16, product: UInt16?)] = [
        (0x1115, 0x0008),   // Futaba RSC-U485
        (0x0403, nil),      // FTDI's own IDs (only listed when no kernel driver claimed them)
    ]

    public static func parse(spec: String) -> (vendorID: UInt16, productID: UInt16, locationID: UInt32?)? {
        guard spec.hasPrefix("usb://") else { return nil }
        let body = spec.dropFirst(6)
        let parts = body.split(separator: "@", maxSplits: 1)
        let ids = parts[0].split(separator: ":")
        guard ids.count == 2, let v = UInt16(ids[0], radix: 16), let p = UInt16(ids[1], radix: 16) else { return nil }
        let loc = parts.count > 1 ? UInt32(parts[1], radix: 16) : nil
        return (v, p, loc)
    }

    /// Unclaimed FTDI-style interfaces present right now.
    public static func available() -> [FTDIDeviceInfo] {
        #if canImport(IOUSBHost)
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [FTDIDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func prop<T>(_ key: String) -> T? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
            }
            guard let vendor: Int = prop("idVendor"), let product: Int = prop("idProduct"),
                  let cls: Int = prop("bInterfaceClass"), cls == 0xFF,
                  let number: Int = prop("bInterfaceNumber"), number == 0,
                  knownIDs.contains(where: { $0.vendor == UInt16(vendor) && ($0.product == nil || $0.product == UInt16(product)) })
            else { continue }
            // Skip interfaces a kernel driver already owns (those appear as /dev/cu.* instead).
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                let child = IOIteratorNext(children)
                IOObjectRelease(children)
                if child != 0 { IOObjectRelease(child); continue }
            }
            let location: Int = prop("locationID") ?? 0
            let name: String = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault,
                                                               IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
                ?? "FTDI USB serial"
            let serial = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Serial Number" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
            found.append(FTDIDeviceInfo(vendorID: UInt16(vendor), productID: UInt16(product), locationID: UInt32(truncatingIfNeeded: location),
                                        productName: name, serialNumber: serial))
        }
        return found.sorted { $0.locationID < $1.locationID }
        #else
        return []
        #endif
    }
}

/// FTDI vendor-protocol helpers that do not touch hardware (unit-testable).
public enum FTDIProtocol {
    public static let reset: UInt8 = 0x00
    public static let setModemControl: UInt8 = 0x01
    public static let setFlowControl: UInt8 = 0x02
    public static let setBaudRate: UInt8 = 0x03
    public static let setData: UInt8 = 0x04
    public static let setLatencyTimer: UInt8 = 0x09
    public static let purgeRX: UInt16 = 1
    public static let purgeTX: UInt16 = 2
    /// Bytes of modem/line status that prefix every IN packet.
    public static let statusHeaderLength = 2

    /// Baud divisor for FT232R/FT232BM-class chips (48 MHz clock, 1/8 sub-integer steps).
    /// Returns the `wValue` and `wIndex` for a SET_BAUDRATE request.
    public static func baudDivisor(_ baud: Int) -> (value: UInt16, index: UInt16) {
        let fractionCode: [UInt32] = [0, 3, 2, 4, 1, 5, 6, 7]
        let divisor3 = UInt32((48_000_000 + baud) / (2 * baud))   // round(48e6 / (2·baud))
        var divisor = divisor3 >> 3
        divisor |= fractionCode[Int(divisor3 & 7)] << 14
        if divisor == 1 { divisor = 0 }             // 3 MBaud
        else if divisor == 0x4001 { divisor = 1 }   // 2 MBaud
        return (UInt16(divisor & 0xFFFF), UInt16((divisor >> 16) & 0xFFFF))
    }

    /// Strips the two status bytes from each `maxPacket`-sized packet of a bulk IN transfer.
    public static func payload(of packet: [UInt8], maxPacket: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(packet.count)
        var offset = 0
        while offset < packet.count {
            let end = min(offset + maxPacket, packet.count)
            let start = min(offset + statusHeaderLength, end)
            out += packet[start..<end]
            offset = end
        }
        return out
    }
}

#if canImport(IOUSBHost)
/// `ServoTransport` over a raw FTDI USB interface. Blocking USB calls run on a private queue.
public final class FTDIUSBTransport: ServoTransport, @unchecked Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let locationID: UInt32?
    public let baudRate: Int
    public var name: String { String(format: "usb://%04x:%04x", vendorID, productID) + (locationID.map { String(format: "@%08x", $0) } ?? "") }

    private let queue = DispatchQueue(label: "assistarm.ftdi")
    private var interface: IOUSBHostInterface?
    private var inPipe: IOUSBHostPipe?
    private var outPipe: IOUSBHostPipe?
    private var inMaxPacket = 64
    private var pending: [UInt8] = []

    public init(vendorID: UInt16, productID: UInt16, locationID: UInt32? = nil, baudRate: Int = Futaba.baudRate) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.baudRate = baudRate
    }

    public convenience init?(spec: String, baudRate: Int = Futaba.baudRate) {
        guard let p = FTDIDeviceInfo.parse(spec: spec) else { return nil }
        self.init(vendorID: p.vendorID, productID: p.productID, locationID: p.locationID, baudRate: baudRate)
    }

    deinit { interface?.destroy() }

    public func open() async throws {
        try await run { [self] in
            guard interface == nil else { return }
            let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
            matching["idVendor"] = Int(vendorID)
            matching["idProduct"] = Int(productID)
            matching["bConfigurationValue"] = 1
            matching["bInterfaceNumber"] = 0
            if let locationID { matching["locationID"] = Int(locationID) }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { throw ServoError.io("USB device \(name) not found") }
            defer { IOObjectRelease(service) }
            let iface: IOUSBHostInterface
            do {
                iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch {
                throw ServoError.io("cannot open \(name): \(error.localizedDescription)")
            }
            do {
                var inAddress: UInt8 = 0x81, outAddress: UInt8 = 0x02
                var ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor, nil)
                while let e = ep {
                    let d = e.pointee
                    if d.bmAttributes & 0x03 == 0x02 {   // bulk
                        if d.bEndpointAddress & 0x80 != 0 { inAddress = d.bEndpointAddress; inMaxPacket = Int(d.wMaxPacketSize) }
                        else { outAddress = d.bEndpointAddress }
                    }
                    ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor,
                                                        UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(e)))
                }
                let divisor = FTDIProtocol.baudDivisor(baudRate)
                try control(iface, FTDIProtocol.reset, 0, 0)
                try control(iface, FTDIProtocol.setBaudRate, divisor.value, divisor.index)
                try control(iface, FTDIProtocol.setData, 0x0008, 0)        // 8 data bits, no parity, 1 stop
                try control(iface, FTDIProtocol.setFlowControl, 0, 0)
                try control(iface, FTDIProtocol.setLatencyTimer, 1, 0)     // flush received bytes every 1 ms
                try control(iface, FTDIProtocol.reset, FTDIProtocol.purgeRX, 0)
                try control(iface, FTDIProtocol.reset, FTDIProtocol.purgeTX, 0)
                inPipe = try iface.copyPipe(withAddress: Int(inAddress))
                outPipe = try iface.copyPipe(withAddress: Int(outAddress))
            } catch {
                iface.destroy()
                inPipe = nil; outPipe = nil
                throw error
            }
            interface = iface
            pending.removeAll()
        }
    }

    private func control(_ iface: IOUSBHostInterface, _ request: UInt8, _ value: UInt16, _ index: UInt16) throws {
        let req = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: request, wValue: value, wIndex: index, wLength: 0)
        do {
            try iface.__send(req, data: nil, bytesTransferred: nil, completionTimeout: 1.0)
        } catch {
            throw ServoError.io(String(format: "FTDI request 0x%02X failed: %@", request, error.localizedDescription))
        }
    }

    public func close() async {
        try? await run { [self] in
            inPipe = nil
            outPipe = nil
            interface?.destroy()
            interface = nil
            pending.removeAll()
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await run { [self] in
            guard let outPipe else { throw ServoError.notOpen }
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            var n = 0
            do {
                try outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 1.0)
            } catch {
                throw ServoError.io("USB write: \(error.localizedDescription)")
            }
            guard n == bytes.count else { throw ServoError.io("USB write: short transfer (\(n)/\(bytes.count))") }
        }
    }

    public func read(count: Int, timeout: Duration) async throws -> [UInt8] {
        try await run { [self] in
            guard let inPipe else { throw ServoError.notOpen }
            let deadline = ContinuousClock.now + timeout
            while pending.count < count {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                let buffer = NSMutableData(length: inMaxPacket)!
                var n = 0
                do {
                    // The chip answers every latency period even when idle, so this returns quickly;
                    // the timeout only matters if the adapter is unplugged.
                    try inPipe.__sendIORequest(with: buffer, bytesTransferred: &n, completionTimeout: max(0.05, remaining.seconds + 0.05))
                } catch {
                    throw ServoError.io("USB read: \(error.localizedDescription)")
                }
                let packet = [UInt8](UnsafeBufferPointer(start: buffer.bytes.assumingMemoryBound(to: UInt8.self), count: n))
                pending += FTDIProtocol.payload(of: packet, maxPacket: inMaxPacket)
            }
            let take = min(count, pending.count)
            let out = Array(pending.prefix(take))
            pending.removeFirst(take)
            return out
        }
    }

    /// Drops buffered input. This deliberately does not use the FTDI "purge RX" request: on the
    /// FT232R a purge issued while the previous packet is still leaving the UART makes the next
    /// reply vanish (measured: 10/10 status reads lost with purge, 0/10 without). One bulk read,
    /// which the latency timer completes within 1 ms, drains what the chip holds instead.
    public func discardInput() async throws {
        try await run { [self] in
            guard let inPipe else { throw ServoError.notOpen }
            pending.removeAll()
            let buffer = NSMutableData(length: inMaxPacket)!
            var n = 0
            try? inPipe.__sendIORequest(with: buffer, bytesTransferred: &n, completionTimeout: 0.05)
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
#endif

/// Builds a transport from a spec string: `/dev/cu.…`, `usb://vid:pid[@location]`, or `tcp://host[:port]`.
public enum ServoTransports {
    public static func make(_ spec: String) throws -> ServoTransport {
        if spec.hasPrefix("tcp://") {
            let hp = spec.dropFirst(6).split(separator: ":")
            guard let host = hp.first, !host.isEmpty else { throw ServoError.io("bad TCP spec \(spec)") }
            return TCPServoTransport(host: String(host), port: UInt16(hp.count > 1 ? hp[1] : "5000") ?? 5000)
        }
        if spec.hasPrefix("usb://") {
            #if canImport(IOUSBHost)
            guard let t = FTDIUSBTransport(spec: spec) else { throw ServoError.io("bad USB spec \(spec)") }
            return t
            #else
            throw ServoError.io("direct USB adapters are not supported on this platform")
            #endif
        }
        return SerialPort(path: spec)
    }
}
