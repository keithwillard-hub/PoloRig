import XCTest
@testable import PoloRig

extension SendBufferEntry: @retroactive Equatable {
    public static func == (lhs: SendBufferEntry, rhs: SendBufferEntry) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): return a == b
        case (.speedChange(let a), .speedChange(let b)): return a == b
        case (.delay(let a), .delay(let b)): return a == b
        case (.serialNumber, .serialNumber): return true
        default: return false
        }
    }
}

final class CWKeyerTests: XCTestCase {

    private var keyer: CWKeyer!
    private var defaultContext: KeyerContext!

    override func setUp() {
        super.setUp()
        keyer = CWKeyer()
        defaultContext = KeyerContext()
    }

    override func tearDown() {
        keyer = nil
        defaultContext = nil
        super.tearDown()
    }

    // MARK: - Macro Expansion

    func testExpandMacros_plainText() {
        let entries = keyer.expandMacros(template: "CQ CQ CQ", context: defaultContext)
        XCTAssertEqual(entries, [.text("CQ CQ CQ")])
    }

    func testExpandMacros_call() {
        var ctx = defaultContext!
        ctx.callsign = "AC0VW"
        let entries = keyer.expandMacros(template: "{CALL}", context: ctx)
        XCTAssertEqual(entries, [.text("AC0VW")])
    }

    func testExpandMacros_myCall() {
        var ctx = defaultContext!
        ctx.myCallsign = "AC0VW"
        let entries = keyer.expandMacros(template: "{MYCALL}", context: ctx)
        XCTAssertEqual(entries, [.text("AC0VW")])
    }

    func testExpandMacros_rst_cwMode() {
        var ctx = defaultContext!
        ctx.operatingMode = .cw
        let entries = keyer.expandMacros(template: "{RST}", context: ctx)
        XCTAssertEqual(entries, [.text("599")])
    }

    func testExpandMacros_rst_usbMode() {
        var ctx = defaultContext!
        ctx.operatingMode = .usb
        let entries = keyer.expandMacros(template: "{RST}", context: ctx)
        XCTAssertEqual(entries, [.text("59")])
    }

    func testExpandMacros_freq() {
        var ctx = defaultContext!
        ctx.frequencyHz = 14_060_000
        let entries = keyer.expandMacros(template: "{FREQ}", context: ctx)
        XCTAssertEqual(entries, [.text("14060")])
    }

    func testExpandMacros_serial() {
        let entries = keyer.expandMacros(template: "{SERIAL}", context: defaultContext)
        XCTAssertEqual(entries, [.serialNumber])
    }

    func testExpandMacros_cut() {
        keyer.serialNumber = 100
        let entries = keyer.expandMacros(template: "{CUT}", context: defaultContext)
        XCTAssertEqual(entries, [.text("1TT")])
    }

    func testExpandMacros_speedChange() {
        let entries = keyer.expandMacros(template: "{SPEED:25}", context: defaultContext)
        XCTAssertEqual(entries, [.speedChange(25)])
    }

    func testExpandMacros_delay() {
        let entries = keyer.expandMacros(template: "{DELAY:2}", context: defaultContext)
        XCTAssertEqual(entries, [.delay(2.0)])
    }

    func testExpandMacros_mixed() {
        var ctx = defaultContext!
        ctx.myCallsign = "AC0VW"
        let entries = keyer.expandMacros(template: "CQ DE {MYCALL} K", context: ctx)
        XCTAssertEqual(entries, [.text("CQ DE "), .text("AC0VW"), .text(" K")])
    }

    func testExpandMacros_unknownMacro() {
        let entries = keyer.expandMacros(template: "{UNKNOWN}", context: defaultContext)
        XCTAssertEqual(entries, [.text("{UNKNOWN}")])
    }

    func testExpandMacros_unclosedBrace() {
        let entries = keyer.expandMacros(template: "{CALL", context: defaultContext)
        XCTAssertEqual(entries, [.text("{CALL")])
    }

    func testExpandMacros_emptyTemplate() {
        let entries = keyer.expandMacros(template: "", context: defaultContext)
        XCTAssertEqual(entries, [])
    }

    func testExpandMacros_cqMemory() {
        var ctx = defaultContext!
        ctx.myCallsign = "AC0VW"
        let template = "CQ CQ CQ DE {MYCALL} {MYCALL} K"
        let entries = keyer.expandMacros(template: template, context: ctx)
        let expected: [SendBufferEntry] = [
            .text("CQ CQ CQ DE "),
            .text("AC0VW"),
            .text(" "),
            .text("AC0VW"),
            .text(" K"),
        ]
        XCTAssertEqual(entries, expected)
    }

    // MARK: - Serial Number Formatting

    func testFormatSerial_zeroPadded() {
        XCTAssertEqual(keyer.formatSerialNumber(1), "001")
        XCTAssertEqual(keyer.formatSerialNumber(42), "042")
    }

    func testFormatSerial_threeDigits() {
        XCTAssertEqual(keyer.formatSerialNumber(100), "100")
        XCTAssertEqual(keyer.formatSerialNumber(999), "999")
    }

    func testFormatSerial_cutNumbers() {
        XCTAssertEqual(keyer.formatSerialNumber(100, useCutNumbers: true), "1TT")
        XCTAssertEqual(keyer.formatSerialNumber(109, useCutNumbers: true), "1TN")
        XCTAssertEqual(keyer.formatSerialNumber(901, useCutNumbers: true), "NT1")
    }

    // MARK: - Morse Timing

    func testEstimateDuration_singleE() {
        let duration = MorseTiming.estimateDuration("E", wpm: 20)
        XCTAssertEqual(duration, 0.060, accuracy: 0.001)
    }

    func testEstimateDuration_singleT() {
        let duration = MorseTiming.estimateDuration("T", wpm: 20)
        XCTAssertEqual(duration, 0.180, accuracy: 0.001)
    }

    func testEstimateDuration_word() {
        let duration = MorseTiming.estimateDuration("CQ", wpm: 20)
        XCTAssertEqual(duration, 27.0 * 0.060, accuracy: 0.001)
    }

    func testEstimateDuration_wordSpace() {
        let duration = MorseTiming.estimateDuration("CQ CQ", wpm: 20)
        XCTAssertEqual(duration, 58.0 * 0.060, accuracy: 0.001)
    }

    func testEstimateDuration_emptyString() {
        XCTAssertEqual(MorseTiming.estimateDuration("", wpm: 20), 0)
    }

    func testEstimateDuration_zeroWpm() {
        XCTAssertEqual(MorseTiming.estimateDuration("CQ", wpm: 0), 0)
    }

    func testEstimateDuration_unknownChar() {
        let duration = MorseTiming.estimateDuration("E#", wpm: 20)
        XCTAssertEqual(duration, 0.060, accuracy: 0.001)
    }

    // MARK: - Interpolated Template

    func testSendInterpolatedTemplate_combinesDollarAndMacro() {
        var ctx = defaultContext!
        ctx.myCallsign = "AC0VW"
        ctx.operatingMode = .cw

        let template = "$callsign DE $mycall NR {SERIAL} K"
        let variables = ["callsign": "W5XYZ", "mycall": "AC0VW"]

        let interpolated = CWTemplateEngine.interpolate(template, variables: variables)
        XCTAssertEqual(interpolated, "W5XYZ DE AC0VW NR {SERIAL} K")

        let entries = keyer.expandMacros(template: interpolated, context: ctx)
        let expected: [SendBufferEntry] = [
            .text("W5XYZ DE AC0VW NR "),
            .serialNumber,
            .text(" K"),
        ]
        XCTAssertEqual(entries, expected)
    }
}
