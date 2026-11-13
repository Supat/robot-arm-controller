import XCTest
@testable import FutabaRS

final class FTDIProtocolTests: XCTestCase {
    func testBaudDivisorsMatchFTDIReference() {
        // Values from FTDI AN232B-05 for FT232R/BM-class chips.
        XCTAssertEqual(FTDIProtocol.baudDivisor(115_200).value, 0x001A)
        XCTAssertEqual(FTDIProtocol.baudDivisor(115_200).index, 0)
        XCTAssertEqual(FTDIProtocol.baudDivisor(9_600).value, 0x4138)
        XCTAssertEqual(FTDIProtocol.baudDivisor(230_400).value, 0x000D)
        XCTAssertEqual(FTDIProtocol.baudDivisor(921_600).value, 0x8003)
        XCTAssertEqual(FTDIProtocol.baudDivisor(3_000_000).value, 0)
        XCTAssertEqual(FTDIProtocol.baudDivisor(2_000_000).value, 1)
    }

    func testPayloadStripsStatusBytesPerPacket() {
        XCTAssertEqual(FTDIProtocol.payload(of: [0xF1, 0x60], maxPacket: 64), [])
        XCTAssertEqual(FTDIProtocol.payload(of: [0xF1, 0x60, 0xFD, 0xDF, 0x01], maxPacket: 64), [0xFD, 0xDF, 0x01])
        let two = [UInt8](repeating: 0xAA, count: 4) + [0xBB, 0xBB, 0x01, 0x02]
        XCTAssertEqual(FTDIProtocol.payload(of: two, maxPacket: 4), [0xAA, 0xAA, 0x01, 0x02])
        XCTAssertEqual(FTDIProtocol.payload(of: [], maxPacket: 64), [])
    }

    func testSpecRoundTrip() {
        let info = FTDIDeviceInfo(vendorID: 0x1115, productID: 0x0008, locationID: 0x1034_4000, productName: "USB <-> Serial Cable", serialNumber: nil)
        XCTAssertEqual(info.spec, "usb://1115:0008@10344000")
        let parsed = FTDIDeviceInfo.parse(spec: info.spec)
        XCTAssertEqual(parsed?.vendorID, 0x1115)
        XCTAssertEqual(parsed?.productID, 0x0008)
        XCTAssertEqual(parsed?.locationID, 0x1034_4000)
        XCTAssertEqual(FTDIDeviceInfo.parse(spec: "usb://1115:0008")?.locationID, nil)
        XCTAssertNil(FTDIDeviceInfo.parse(spec: "/dev/cu.usbserial"))
    }
}
