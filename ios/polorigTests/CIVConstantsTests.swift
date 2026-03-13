import XCTest
@testable import PoloRig

final class CIVConstantsTests: XCTestCase {

    // MARK: - Frequency Parsing

    func testParseHz_14060MHz() {
        let bytes: [UInt8] = [0x00, 0x00, 0x06, 0x14, 0x00]
        XCTAssertEqual(CIV.Frequency.parseHz(from: bytes), 14_060_000)
    }

    func testParseHz_7030MHz() {
        let bytes: [UInt8] = [0x00, 0x00, 0x03, 0x07, 0x00]
        XCTAssertEqual(CIV.Frequency.parseHz(from: bytes), 7_030_000)
    }

    func testParseHz_433MHz() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x33, 0x04]
        XCTAssertEqual(CIV.Frequency.parseHz(from: bytes), 433_000_000)
    }

    func testParseHz_allZeros() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(CIV.Frequency.parseHz(from: bytes), 0)
    }

    func testParseHz_tooFewBytes() {
        let bytes: [UInt8] = [0x00, 0x06, 0x14]
        XCTAssertNil(CIV.Frequency.parseHz(from: bytes))
    }

    func testParseHz_invalidBCD() {
        let bytes: [UInt8] = [0xAB, 0x00, 0x06, 0x14, 0x00]
        XCTAssertNil(CIV.Frequency.parseHz(from: bytes))
    }

    // MARK: - Frequency Formatting

    func testFormatMHz() {
        XCTAssertEqual(CIV.Frequency.formatMHz(14_060_000), "14.060 MHz")
    }

    func testFormatKHz() {
        XCTAssertEqual(CIV.Frequency.formatKHz(14_060_000), "14060")
    }

    func testFormatMHz_subMHz() {
        XCTAssertEqual(CIV.Frequency.formatMHz(500_000), "500.000 kHz")
    }

    // MARK: - Frequency Round-Trip

    func testToBytes_roundTrip() {
        let frequencies = [14_060_000, 7_030_000, 433_000_000, 0, 146_520_000, 3_573_000]
        for hz in frequencies {
            let bytes = CIV.Frequency.toBytes(hz)
            let parsed = CIV.Frequency.parseHz(from: bytes)
            XCTAssertEqual(parsed, hz, "Round-trip failed for \(hz) Hz")
        }
    }

    // MARK: - Mode Enum

    func testModeRawValues() {
        XCTAssertEqual(CIV.Mode.cw.rawValue, 0x03)
        XCTAssertEqual(CIV.Mode.usb.rawValue, 0x01)
        XCTAssertEqual(CIV.Mode.lsb.rawValue, 0x00)
        XCTAssertEqual(CIV.Mode.am.rawValue, 0x02)
        XCTAssertEqual(CIV.Mode.fm.rawValue, 0x05)
        XCTAssertEqual(CIV.Mode.cwR.rawValue, 0x07)
        XCTAssertEqual(CIV.Mode.rtty.rawValue, 0x04)
        XCTAssertEqual(CIV.Mode.rttyR.rawValue, 0x08)
    }

    func testModeLabels() {
        XCTAssertEqual(CIV.Mode.cw.label, "CW")
        XCTAssertEqual(CIV.Mode.cwR.label, "CW-R")
        XCTAssertEqual(CIV.Mode.usb.label, "USB")
        XCTAssertEqual(CIV.Mode.lsb.label, "LSB")
        XCTAssertEqual(CIV.Mode.am.label, "AM")
        XCTAssertEqual(CIV.Mode.fm.label, "FM")
        XCTAssertEqual(CIV.Mode.rtty.label, "RTTY")
        XCTAssertEqual(CIV.Mode.rttyR.label, "RTTY-R")
    }

    func testDefaultRST() {
        XCTAssertEqual(CIV.Mode.cw.defaultRST, "599")
        XCTAssertEqual(CIV.Mode.cwR.defaultRST, "599")
        XCTAssertEqual(CIV.Mode.usb.defaultRST, "59")
        XCTAssertEqual(CIV.Mode.lsb.defaultRST, "59")
        XCTAssertEqual(CIV.Mode.am.defaultRST, "59")
        XCTAssertEqual(CIV.Mode.fm.defaultRST, "59")
        XCTAssertEqual(CIV.Mode.rtty.defaultRST, "599")
        XCTAssertEqual(CIV.Mode.rttyR.defaultRST, "599")
    }

    func testModeFromRawValue() {
        XCTAssertEqual(CIV.Mode(rawValue: 0x03), .cw)
        XCTAssertEqual(CIV.Mode(rawValue: 0x01), .usb)
        XCTAssertNil(CIV.Mode(rawValue: 0x06))
        XCTAssertNil(CIV.Mode(rawValue: 0x09))
        XCTAssertNil(CIV.Mode(rawValue: 0xFF))
    }

    // MARK: - CW Speed

    func testWpmToValue_min() {
        let (high, low) = CIV.CWSpeed.wpmToValue(6)
        XCTAssertEqual(high, 0x00)
        XCTAssertEqual(low, 0x00)
    }

    func testWpmToValue_max() {
        let (high, low) = CIV.CWSpeed.wpmToValue(48)
        XCTAssertEqual(high, 0x02)
        XCTAssertEqual(low, 0x55)
    }

    func testWpmToValue_clamping() {
        let (lowH, lowL) = CIV.CWSpeed.wpmToValue(0)
        XCTAssertEqual(lowH, 0x00)
        XCTAssertEqual(lowL, 0x00)

        let (highH, highL) = CIV.CWSpeed.wpmToValue(100)
        XCTAssertEqual(highH, 0x02)
        XCTAssertEqual(highL, 0x55)
    }

    // MARK: - Build Frame

    func testBuildFrame_commandOnly() {
        let frame = CIV.buildFrame(command: CIV.Command.readFrequency)
        let expected: [UInt8] = [0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD]
        XCTAssertEqual(Array(frame), expected)
    }

    func testBuildFrame_withSubCommand() {
        let frame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
        let expected: [UInt8] = [0xFE, 0xFE, 0xA4, 0xE0, 0x14, 0x0C, 0xFD]
        XCTAssertEqual(Array(frame), expected)
    }

    func testBuildFrame_withData() {
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: [0x48, 0x45])
        let expected: [UInt8] = [0xFE, 0xFE, 0xA4, 0xE0, 0x17, 0x48, 0x45, 0xFD]
        XCTAssertEqual(Array(frame), expected)
    }
}
