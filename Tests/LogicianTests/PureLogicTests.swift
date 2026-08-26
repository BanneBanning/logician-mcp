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

    // MARK: - On-disk cache scoping (build + project)

    func testCacheScopeTokenCarriesBothTheBuildAndTheProject() {
        let token = cacheScopeToken(projectPath: "/Music/Song.logicx")
        XCTAssertTrue(token.contains(cacheSchemaVersion))
        XCTAssertTrue(token.contains("/Music/Song.logicx"))
    }

    func testCacheScopeTokenSeparatesProjectsAndBuilds() {
        XCTAssertNotEqual(
            cacheScopeToken(projectPath: "/Music/A.logicx"),
            cacheScopeToken(projectPath: "/Music/B.logicx")
        )
        // The schema version rides on serverVersion so a new build retires
        // every measurement the previous one wrote.
        XCTAssertEqual(cacheSchemaVersion, serverVersion)
    }

    func testScopedCacheRoundTripsWithinTheSameProject() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(["bank0", "bank1"], to: url, projectPath: "/Music/A.logicx")
        XCTAssertEqual(
            loadScopedCache(url, projectPath: "/Music/A.logicx", as: [String].self),
            ["bank0", "bank1"]
        )
    }

    func testScopedCacheIsInvisibleToAnotherProject() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(["bank0"], to: url, projectPath: "/Music/A.logicx")
        // The whole point: a bank map from another song is not stale, it is
        // wrong, and must read as absent rather than be trusted.
        XCTAssertNil(loadScopedCache(url, projectPath: "/Music/B.logicx", as: [String].self))
    }

    func testScopedCacheIsUnreadableAndUnwritableWithoutAProject() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(["bank0"], to: url, projectPath: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an unstamped file could never be validated on the way back in")
        saveScopedCache(["bank0"], to: url, projectPath: "/Music/A.logicx")
        XCTAssertNil(loadScopedCache(url, projectPath: nil, as: [String].self))
    }

    func testScopedCacheRejectsPreScopeFilesFromOlderBuilds() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // The 0.50.0 bank cache was a bare JSON array with no stamp at all.
        try? Data(#"["bank0","bank1"]"#.utf8).write(to: url)
        XCTAssertNil(loadScopedCache(url, projectPath: "/Music/A.logicx", as: [String].self))
    }

    func testScopedCacheSurvivesADictionaryPayload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoped-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let names: [String: [[String]]] = ["Channe": [["Gain", "Freq", "Q", "", "", "", "", ""]]]
        saveScopedCache(names, to: url, projectPath: "/Music/A.logicx")
        XCTAssertEqual(
            loadScopedCache(url, projectPath: "/Music/A.logicx", as: [String: [[String]]].self),
            names
        )
    }

    // MARK: - Cached parameter-name verification (anti-hallucination)

    private static let eightNames =
        ["Gain", "Freq", "Q", "Slope", "Mode", "Out", "Mix", "Bypass"]

    func testCachedNameRowAcceptsAnIdenticalSettledRow() {
        XCTAssertTrue(MCUController.cachedNameRowMatches(
            cached: Self.eightNames, live: Self.eightNames
        ))
    }

    func testCachedNameRowRejectsAnInsertedParameter() {
        // A plugin update that inserts one parameter shifts every field after
        // it; pairing these names with live values would mislabel six of them.
        var shifted = Self.eightNames
        shifted.insert("Drive", at: 2)
        XCTAssertFalse(MCUController.cachedNameRowMatches(
            cached: Self.eightNames, live: Array(shifted.prefix(8))
        ))
    }

    func testCachedNameRowRejectsAChangeInTheHiddenTailFields() {
        // Fields 6-7 are exactly the ones the cheap per-page check cannot see,
        // which is why this comparison exists at all.
        var tailChanged = Self.eightNames
        tailChanged[7] = "Trim"
        XCTAssertFalse(MCUController.cachedNameRowMatches(
            cached: Self.eightNames, live: tailChanged
        ))
    }

    func testCachedNameRowRefusesARowStillShowingThePageIndicator() {
        var unsettled = Self.eightNames
        unsettled[6] = "Page 1"
        unsettled[7] = "1/4"
        XCTAssertFalse(
            MCUController.cachedNameRowMatches(cached: Self.eightNames, live: unsettled),
            "a half-repainted row proves nothing and must not count as agreement"
        )
    }

    func testCachedNameRowRefusesRowsThatAreNotEightFields() {
        XCTAssertFalse(MCUController.cachedNameRowMatches(cached: [], live: Self.eightNames))
        XCTAssertFalse(MCUController.cachedNameRowMatches(
            cached: Array(Self.eightNames.prefix(7)), live: Self.eightNames
        ))
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
