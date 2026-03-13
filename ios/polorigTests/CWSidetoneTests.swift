import XCTest
@testable import PoloRig

final class CWSidetoneTests: XCTestCase {

    func testMorseTable_allLettersPresent() {
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            let char = Character(UnicodeScalar(scalar)!)
            XCTAssertNotNil(CWSidetone.morseTable[char], "Missing Morse pattern for '\(char)'")
        }
    }

    func testMorseTable_allDigitsPresent() {
        for scalar in UnicodeScalar("0").value...UnicodeScalar("9").value {
            let char = Character(UnicodeScalar(scalar)!)
            XCTAssertNotNil(CWSidetone.morseTable[char], "Missing Morse pattern for '\(char)'")
        }
    }

    func testMorseTable_patternsOnlyDotsAndDashes() {
        for (char, pattern) in CWSidetone.morseTable {
            let invalid = pattern.filter { $0 != "." && $0 != "-" }
            XCTAssertTrue(invalid.isEmpty,
                "Pattern for '\(char)' contains invalid characters: \(invalid)")
        }
    }

    func testMorseTable_knownPatterns() {
        XCTAssertEqual(CWSidetone.morseTable["E"], ".")
        XCTAssertEqual(CWSidetone.morseTable["T"], "-")
        XCTAssertEqual(CWSidetone.morseTable["S"], "...")
        XCTAssertEqual(CWSidetone.morseTable["O"], "---")
        XCTAssertEqual(CWSidetone.morseTable["1"], ".----")
        XCTAssertEqual(CWSidetone.morseTable["0"], "-----")
    }

    func testMorseTable_noDuplicatePatterns() {
        var seen: [String: Character] = [:]
        for (char, pattern) in CWSidetone.morseTable {
            if let existing = seen[pattern] {
                XCTFail("Duplicate pattern '\(pattern)' for '\(char)' and '\(existing)'")
            }
            seen[pattern] = char
        }
    }
}
