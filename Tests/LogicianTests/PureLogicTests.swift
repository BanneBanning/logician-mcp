import XCTest
@testable import Logician

/// Pure parsing/sanitising logic from the server side. None of this needs
/// Logic Pro, and all of it is expensive to get wrong: LCD field slicing
/// feeds every bank scan, the dB parser decides every volume convergence,
/// and the filename sanitiser is a security control.
final class PureLogicTests: XCTestCase {

    // MARK: - LCD field slicing (8 x 7-character cells)

    func testLCDFieldsAlwaysYieldsEightTrimmedCells() {
        let row = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "
        let fields = MCUController.lcdFields(row)
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(fields, ["LofPad", "Bas", "808", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])
    }

    func testLCDFieldsPadsAShortRowInsteadOfCrashing() {
        let fields = MCUController.lcdFields("Vol")
        XCTAssertEqual(fields.count, 8, "callers index [0...7] unconditionally")
        XCTAssertEqual(fields[0], "Vol")
        XCTAssertEqual(fields[7], "")
    }

    func testLCDFieldsHandlesEmptyAndOverlongRows() {
        XCTAssertEqual(MCUController.lcdFields("").count, 8)
        XCTAssertEqual(MCUController.lcdFields(String(repeating: "x", count: 200)).count, 8)
    }

    func testLCDFieldsRecognisesTheAllDashesTransientDisplay() {
        // The single-channel pan view; treating it as track names poisoned
        // bank scans until the transient check was added.
        let fields = MCUController.lcdFields("Pan    -      -      -      -      -      -      -      ")
        XCTAssertEqual(fields.filter { $0 == "-" }.count, 7)
    }

    // MARK: - dB parsing off the LCD

    func testParseDbHandlesSwedishDecimalCommas() {
        XCTAssertEqual(MCUController.parseDb("-10,7"), -10.7)
        XCTAssertEqual(MCUController.parseDb("+2,8dB"), 2.8)
    }

    func testParseDbHandlesValuesTruncatedByTheSevenCharacterCell() {
        XCTAssertEqual(MCUController.parseDb("-10,0 d"), -10.0)
        XCTAssertEqual(MCUController.parseDb("-4,9dB"), -4.9)
    }

    func testParseDbMapsMinusInfinityToTheFloor() {
        XCTAssertEqual(MCUController.parseDb("-oo"), -70.0)
        XCTAssertEqual(MCUController.parseDb("-oo   "), -70.0)
    }

    func testParseDbRejectsNonNumericCells() {
        XCTAssertNil(MCUController.parseDb(""))
        XCTAssertNil(MCUController.parseDb("-"))
        XCTAssertNil(MCUController.parseDb("Volume"))
    }

    func testParseDbAcceptsPlainIntegersAndZero() {
        XCTAssertEqual(MCUController.parseDb("0,0dB"), 0.0)
        XCTAssertEqual(MCUController.parseDb("+0,0"), 0.0)
        XCTAssertEqual(MCUController.parseDb("-70"), -70.0)
    }

    // MARK: - Abbreviated track-name matching

    func testLCDNameMatchesRecoversLogicsAbbreviations() {
        XCTAssertTrue(MCUController.lcdNameMatches(track: "Lofi Pad", lcd: "LofPad"))
        XCTAssertTrue(MCUController.lcdNameMatches(track: "Ivan Slagverk", lcd: "IvnSlg"))
        XCTAssertTrue(MCUController.lcdNameMatches(track: "Bas", lcd: "Bas"))
    }

    func testLCDNameMatchesRejectsDifferentTracks() {
        XCTAssertFalse(MCUController.lcdNameMatches(track: "Bas", lcd: "808"))
        XCTAssertFalse(MCUController.lcdNameMatches(track: "Vocals", lcd: "Drums"))
    }

    func testLCDNameMatchesIgnoresEmptyCells() {
        XCTAssertFalse(MCUController.lcdNameMatches(track: "Bas", lcd: ""))
        XCTAssertFalse(MCUController.lcdNameMatches(track: "Bas", lcd: "-"))
    }

    // MARK: - Filename sanitisation (a security control)

    func testSanitiserStripsPathTraversal() {
        let sanitised = sanitizedFilenameComponent("../../../../tmp/pwned")
        XCTAssertFalse(sanitised.contains("/"))
        let path = URL(fileURLWithPath: "/base/captures")
            .appendingPathComponent("render-\(sanitised)-1.wav").path
        XCTAssertTrue(path.hasPrefix("/base/captures/"))
    }

    func testSanitiserNeverReturnsADotOnlyComponent() {
        // "." and ".." resolve as traversal even without a slash.
        XCTAssertEqual(sanitizedFilenameComponent("..", fallback: "render"), "render")
        XCTAssertEqual(sanitizedFilenameComponent(".", fallback: "render"), "render")
        XCTAssertEqual(sanitizedFilenameComponent("....//", fallback: "render"), "render")
    }

    func testSanitiserKeepsOrdinaryLabelsIntact() {
        XCTAssertEqual(sanitizedFilenameComponent("hook_final"), "hook_final")
        XCTAssertEqual(sanitizedFilenameComponent("verse-2.take3"), "verse-2.take3")
    }

    func testSanitiserCollapsesSeparatorsAndSpaces() {
        XCTAssertEqual(sanitizedFilenameComponent("a/b/c"), "a-b-c")
        XCTAssertEqual(sanitizedFilenameComponent("Ivan Vocals"), "Ivan-Vocals")
    }

    func testSanitiserHandlesNonASCIIAndEmptyInput() {
        XCTAssertEqual(sanitizedFilenameComponent("", fallback: "clip"), "clip")
        // Swedish track names must not vanish into an empty component.
        XCTAssertFalse(sanitizedFilenameComponent("Testlåt").isEmpty)
        XCTAssertFalse(sanitizedFilenameComponent("日本語").isEmpty)
    }

    func testSanitiserCapsLength() {
        XCTAssertLessThanOrEqual(sanitizedFilenameComponent(String(repeating: "a", count: 500)).count, 64)
    }

    // MARK: - Formatted-value comparison (compare-and-set)

    func testEquivalentValuesAcceptFormattingDifferences() {
        let logic = LogicAccessibility()
        XCTAssertTrue(logic.equivalentFormattedValues("-6.0 dB", "-6,0 dB"))
        XCTAssertTrue(logic.equivalentFormattedValues("4.0:1", "4.0"))
        XCTAssertTrue(logic.equivalentFormattedValues(" 2.5 ", "2.5"))
    }

    func testEquivalentValuesRejectDifferentNumbers() {
        let logic = LogicAccessibility()
        XCTAssertFalse(logic.equivalentFormattedValues("-6.0 dB", "-7.0 dB"))
        XCTAssertFalse(logic.equivalentFormattedValues("On", "Off"))
    }

    func testNormalisedValueExtractsTheLeadingNumber() {
        let logic = LogicAccessibility()
        XCTAssertEqual(logic.normalizedFormattedValue("-6,0 dB").number, -6.0)
        XCTAssertEqual(logic.normalizedFormattedValue("+2.8dB").number, 2.8)
        XCTAssertNil(logic.normalizedFormattedValue("Bypass").number)
    }
}
