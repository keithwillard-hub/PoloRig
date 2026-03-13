import XCTest
@testable import PoloRig

final class CWTemplateEngineTests: XCTestCase {

    // MARK: - Interpolation

    func testInterpolate_plainText() {
        let result = CWTemplateEngine.interpolate("CQ CQ CQ", variables: [:])
        XCTAssertEqual(result, "CQ CQ CQ")
    }

    func testInterpolate_singleVariable() {
        let result = CWTemplateEngine.interpolate("$callsign ?", variables: ["callsign": "AC0VW"])
        XCTAssertEqual(result, "AC0VW ?")
    }

    func testInterpolate_multipleVariables() {
        let result = CWTemplateEngine.interpolate(
            "CQ DE $mycall $mycall K",
            variables: ["mycall": "AC0VW"]
        )
        XCTAssertEqual(result, "CQ DE AC0VW AC0VW K")
    }

    func testInterpolate_unknownVariable() {
        let result = CWTemplateEngine.interpolate("$unknown", variables: [:])
        XCTAssertEqual(result, "")
    }

    func testInterpolate_adjacentVariables() {
        let result = CWTemplateEngine.interpolate(
            "$a$b",
            variables: ["a": "X", "b": "Y"]
        )
        XCTAssertEqual(result, "XY")
    }

    func testInterpolate_underscoreInName() {
        let result = CWTemplateEngine.interpolate(
            "$partial_callsign",
            variables: ["partial_callsign": "W1A"]
        )
        XCTAssertEqual(result, "W1A")
    }

    func testInterpolate_dollarAtEnd() {
        let result = CWTemplateEngine.interpolate("text$", variables: [:])
        XCTAssertEqual(result, "text$")
    }

    func testInterpolate_dollarFollowedBySpace() {
        let result = CWTemplateEngine.interpolate("$ text", variables: [:])
        XCTAssertEqual(result, "$ text")
    }

    func testInterpolate_dollarFollowedByDigit() {
        let result = CWTemplateEngine.interpolate("$3abc", variables: ["3abc": "NOPE"])
        XCTAssertEqual(result, "$3abc")
    }

    func testInterpolate_emptyTemplate() {
        let result = CWTemplateEngine.interpolate("", variables: ["callsign": "AC0VW"])
        XCTAssertEqual(result, "")
    }

    func testInterpolate_emptyDictionary() {
        let result = CWTemplateEngine.interpolate(
            "$callsign DE $mycall",
            variables: [:]
        )
        XCTAssertEqual(result, " DE ")
    }

    func testInterpolate_casePreservation() {
        let result = CWTemplateEngine.interpolate(
            "$Callsign $callsign",
            variables: ["callsign": "AC0VW"]
        )
        XCTAssertEqual(result, " AC0VW")
    }

    func testInterpolate_uppercaseOutput() {
        let result = CWTemplateEngine.interpolate(
            "$name",
            variables: ["name": "john"]
        )
        XCTAssertEqual(result, "JOHN")
    }

    func testInterpolate_mixedDollarAndMacro() {
        let result = CWTemplateEngine.interpolate(
            "$callsign DE $mycall NR {SERIAL} K",
            variables: ["callsign": "W5XYZ", "mycall": "AC0VW"]
        )
        XCTAssertEqual(result, "W5XYZ DE AC0VW NR {SERIAL} K")
    }

    func testInterpolate_variableStartingWithUnderscore() {
        let result = CWTemplateEngine.interpolate(
            "$_custom",
            variables: ["_custom": "test"]
        )
        XCTAssertEqual(result, "TEST")
    }

    // MARK: - Standard Variables

    func testStandardVariables_allPresent() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "W5XYZ",
            myCallsign: "AC0VW",
            frequencyHz: 14_060_000,
            operatingMode: .cw,
            name: "John"
        )
        XCTAssertEqual(vars["callsign"], "W5XYZ")
        XCTAssertEqual(vars["mycall"], "AC0VW")
        XCTAssertEqual(vars["rst"], "599")
        XCTAssertEqual(vars["freq"], "14060")
        XCTAssertEqual(vars["name"], "John")
    }

    func testStandardVariables_cwRST() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 0, operatingMode: .cw, name: nil
        )
        XCTAssertEqual(vars["rst"], "599")
    }

    func testStandardVariables_usbRST() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 0, operatingMode: .usb, name: nil
        )
        XCTAssertEqual(vars["rst"], "59")
    }

    func testStandardVariables_noMode() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 0, operatingMode: nil, name: nil
        )
        XCTAssertEqual(vars["rst"], "599")
    }

    func testStandardVariables_frequency() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 14_060_000, operatingMode: nil, name: nil
        )
        XCTAssertEqual(vars["freq"], "14060")
    }

    func testStandardVariables_noName() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 0, operatingMode: nil, name: nil
        )
        XCTAssertNil(vars["name"])
    }

    func testStandardVariables_emptyName() {
        let vars = CWTemplateEngine.standardVariables(
            callsign: "", myCallsign: "", frequencyHz: 0, operatingMode: nil, name: ""
        )
        XCTAssertNil(vars["name"])
    }
}
