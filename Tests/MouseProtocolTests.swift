import XCTest
@testable import XuanpaiMouse

/// 用例中的应答均来自真机抓取
final class MouseProtocolTests: XCTestCase {
    func pad(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: 64 - bytes.count) }

    func testFramePadsTo64() {
        let f = MouseProtocol.frame([0x45, 0xFF])
        XCTAssertEqual(f.count, 64)
        XCTAssertEqual(Array(f.prefix(4)), [0xA0, 0x45, 0xFF, 0x00])
    }

    func testReadRequests() {
        XCTAssertEqual(MouseProtocol.readRequest(.deviceInfo), [0x02])
        XCTAssertEqual(MouseProtocol.readRequest(.readRate), [0x41, 0xFF])
    }

    func testContainerMatchesVerifiedWrites() {
        XCTAssertEqual(MouseProtocol.container([MouseProtocol.debounceEntry(4)]), [0xDF, 0x01, 0x03, 0x4E, 0x03, 0x04])
        XCTAssertEqual(MouseProtocol.container([MouseProtocol.lodEntry(2)]), [0xDF, 0x01, 0x03, 0x4C, 0x03, 0x02])
    }

    func testRateCodes() {
        XCTAssertEqual(PollingRate.hz1000.code, 3)
        XCTAssertEqual(PollingRate(code: 5), .hz4000)
        XCTAssertNil(PollingRate(code: 1))
    }

    func testParseDeviceInfo() {
        let r = pad([0xA1, 0x02, 0x04, 0x00, 0x01, 0x1B, 0x02, 0x11, 0xC4, 0x00, 0x9B, 0x36,
                     0x02, 0x13, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x02, 0x25, 0x5B, 0x02, 0x26, 0x01])
        let info = MouseProtocol.parseDeviceInfo(r)
        XCTAssertEqual(info?.productID, 0x00C4)
        XCTAssertEqual(info?.vendorID, 0x369B)
        XCTAssertEqual(info?.serial, "123456")
        XCTAssertEqual(info?.battery, 91)
        XCTAssertEqual(info?.workMode, 1)
    }

    func testParseRateLODDebounce() {
        XCTAssertEqual(MouseProtocol.parseRate(pad([0xA1, 0x41, 0x03, 0x00, 0x02, 0x03, 0x04, 0x05, 0x06])), .hz1000)
        XCTAssertEqual(MouseProtocol.parseLOD(pad([0xA1, 0x4D, 0x01])), 1)
        XCTAssertEqual(MouseProtocol.parseDebounce(pad([0xA1, 0x4F, 0x04])), 4)
        XCTAssertNil(MouseProtocol.parseLOD(pad([0xA1, 0x50, 0x00])))
    }

    func testParseDPI() {
        let r = pad([0xA1, 0x45, 0x05, 0x07, 0x02, 0x00, 0x04, 0x01, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00,
                     0x20, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x00])
        let dpi = MouseProtocol.parseDPI(r)
        XCTAssertEqual(dpi?.current, 5)
        XCTAssertEqual(dpi?.minDPI, 200)
        XCTAssertEqual(dpi?.maxDPI, 26000)
        XCTAssertEqual(dpi?.levels, [800, 1600, 2400, 3200, 6400])
    }

    func testDPIEntryLayoutMatchesOfficialDriver() {
        let e = MouseProtocol.dpiEntry(current: 2, levels: [800, 1600, 2400, 3200, 6400, 13000, 26000])
        XCTAssertEqual(e[0], 0x44)
        XCTAssertEqual(Int(e[1]), e.count - 2)
        XCTAssertEqual(e.count, 46)          // 驱动：44 2C + 44 字节
        XCTAssertEqual(Array(e[2...4]), [0x02, 0x08, 0x00])
        XCTAssertEqual(Array(e[13...14]), [0x82, 0x00]) // 13000 → 130 = 0x82
        XCTAssertEqual(Array(e[15...16]), [0x04, 0x01]) // 26000 → 260 = 0x0104
    }

    func testDPIEntryPadsUnusedSlots() {
        let e = MouseProtocol.dpiEntry(current: 1, levels: [800, 1600])
        XCTAssertEqual(e.count, 46)
        XCTAssertEqual(Array(e[7...16]), [UInt8](repeating: 0, count: 10)) // 第3~7档为 0000
    }

    func testClampDPI() {
        XCTAssertEqual(MouseProtocol.clampDPI(50), 200)
        XCTAssertEqual(MouseProtocol.clampDPI(1650), 1600)
        XCTAssertEqual(MouseProtocol.clampDPI(99999), 26000)
    }

    func testWriteAck() {
        XCTAssertTrue(MouseProtocol.writeSucceeded(pad([0xA1, 0xDF, 0x00])))
        XCTAssertFalse(MouseProtocol.writeSucceeded(pad([0xA1, 0xDF, 0x01])))
    }
}

extension MouseProtocolTests {
    /// 真机抓取的状态通知
    func testParseNotification() {
        let r = pad([0xA1, 0x50, 0x01, 0x03, 0x0D, 0x02, 0x04, 0x25, 0x5A, 0x44, 0x03, 0x05,
                     0x02, 0x06, 0x04, 0x00, 0x01, 0x1B])
        let n = MouseProtocol.parseNotification(r)
        XCTAssertEqual(n?.battery, 90)
        XCTAssertEqual(n?.dpiLevel, 5)
    }

    func testParseEmptyNotification() {
        XCTAssertEqual(MouseProtocol.parseNotification(pad([0xA1, 0x50, 0x00])), MouseProtocol.Notification())
        XCTAssertNil(MouseProtocol.parseNotification(pad([0xA1, 0x45, 0x05])))
    }
}
