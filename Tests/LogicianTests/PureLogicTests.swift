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

    // MARK: - Vpot tick chunking (one message carries at most 63 ticks)

    func testVpotChunksLeaveSmallMovesIntact() {
        XCTAssertEqual(MCUController.vpotTickChunks(0), [])
        XCTAssertEqual(MCUController.vpotTickChunks(1), [1])
        XCTAssertEqual(MCUController.vpotTickChunks(-8), [-8])
        XCTAssertEqual(MCUController.vpotTickChunks(63), [63])
        XCTAssertEqual(MCUController.vpotTickChunks(-63), [-63])
    }

    func testVpotChunksSplitMovesBeyondOneMessage() {
        XCTAssertEqual(MCUController.vpotTickChunks(64), [63, 1])
        XCTAssertEqual(MCUController.vpotTickChunks(-90), [-63, -27])
        XCTAssertEqual(MCUController.vpotTickChunks(200), [63, 63, 63, 11])
    }

    func testVpotChunksAlwaysSumBackToTheRequestedMove() {
        // Exactness is the whole point: the undo paths send these chunks to
        // put a parameter back where it was. The bridge clamps anything
        // larger with min(abs(delta), 63) and drops the remainder silently.
        for delta in [-4096, -191, -126, -64, -1, 0, 1, 62, 126, 127, 4096] {
            let chunks = MCUController.vpotTickChunks(delta)
            XCTAssertEqual(chunks.reduce(0, +), delta, "chunks must sum to \(delta)")
            XCTAssertTrue(chunks.allSatisfy { abs($0) <= 63 && $0 != 0 },
                          "every chunk must fit one message: \(chunks)")
        }
    }

    // MARK: - stepToText enum search and its undo

    /// A stand-in for an enum parameter on the LCD. Its display only changes
    /// every `cellWidth` vpot ticks, which is what makes stepToText escalate
    /// its step size - and is how |net| grows past a single message's 63-tick
    /// capacity. `clampsLikeTheBridge` reproduces the bridge's own
    /// min(abs(delta), 63) so an unchunked undo silently falls short here too.
    private final class VpotEnumParameter {
        let cellWidth: Int
        let range: ClosedRange<Int>
        private(set) var position = 0
        private(set) var deltas: [Int] = []
        var clampsLikeTheBridge = true

        init(cellWidth: Int = 15, range: ClosedRange<Int> = -100_000...100_000) {
            self.cellWidth = cellWidth
            self.range = range
        }

        var text: String {
            let cell = Int((Double(position) / Double(cellWidth)).rounded(.down))
            return "val\(cell)"
        }

        func turn(_ ticks: Int) {
            deltas.append(ticks)
            let applied = ticks < 0 ? -min(-ticks, 63) : min(ticks, 63)
            position = min(range.upperBound,
                           max(range.lowerBound,
                               position + (clampsLikeTheBridge ? applied : ticks)))
        }
    }

    private func runStepToText(
        _ parameter: VpotEnumParameter, target: String
    ) -> LogicianError? {
        let original = parameter.text
        do {
            _ = try MCUController.stepToText(
                target: target,
                original: original,
                read: { parameter.text },
                turn: { parameter.turn($0) }
            )
            return nil
        } catch let error as LogicianError {
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    func testStepToTextUndoNeverExceedsOneMessagesTickCapacity() {
        // The regression: the search accumulates well past 63 ticks (24 upward
        // plus 48 downward turns at a step that escalates to 8), and a single
        // oversized undo message was clamped by the bridge instead of split.
        let parameter = VpotEnumParameter()
        _ = runStepToText(parameter, target: "no-such-value")
        XCTAssertTrue(parameter.deltas.contains { abs($0) > 8 },
                      "this fixture must actually drive the undo past one message")
        XCTAssertTrue(parameter.deltas.allSatisfy { abs($0) <= 63 },
                      "every vpot message must fit the wire format: \(parameter.deltas)")
    }

    func testStepToTextPutsTheParameterBackAndSaysSoTruthfully() {
        let parameter = VpotEnumParameter()
        let start = parameter.position
        let error = runStepToText(parameter, target: "no-such-value")
        XCTAssertEqual(parameter.position, start, "the parameter must end where it started")
        guard case .verificationFailed(_, _, let restored)? = error else {
            return XCTFail("expected verificationFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(restored)
    }

    func testStepToTextReportsRestoredFalseWhenAnEndStopSwallowedTheMove() {
        // A parameter that runs into its end stop mid-search cannot be walked
        // back to where it started - the swallowed ticks are gone. Claiming
        // restored: true there is the exact lie this flag exists to prevent.
        let parameter = VpotEnumParameter(cellWidth: 15, range: -100_000...60)
        let error = runStepToText(parameter, target: "no-such-value")
        guard case .verificationFailed(_, let actual, let restored)? = error else {
            return XCTFail("expected verificationFailed, got \(String(describing: error))")
        }
        XCTAssertNotEqual(actual, "val0", "the fixture must actually end up elsewhere")
        XCTAssertFalse(restored, "the LCD reads \(actual), not the original value")
    }

    func testStepToTextReportsRestoredFalseWhenTheUndoCannotBeSent() {
        let parameter = VpotEnumParameter()
        var caught: LogicianError?
        do {
            _ = try MCUController.stepToText(
                target: "no-such-value",
                original: parameter.text,
                read: { parameter.text },
                turn: { ticks in
                    // The search itself never turns more than 8 ticks at once,
                    // so a bigger move can only be an undo chunk: break the
                    // bridge exactly there.
                    if ticks > 8 { throw LogicianError.writeFailed("bridge went away") }
                    parameter.turn(ticks)
                }
            )
            XCTFail("expected the search to fail")
        } catch let error as LogicianError {
            caught = error
        } catch {
            XCTFail("unexpected error \(error)")
        }
        guard case .verificationFailed(_, _, let restored)? = caught else {
            return XCTFail("expected verificationFailed, got \(String(describing: caught))")
        }
        XCTAssertFalse(restored, "an undo that never reached the bridge is not a restoration")
    }

    func testStepToTextStillReturnsTheMatchWhenItFindsOne() {
        let parameter = VpotEnumParameter()
        let found = try? MCUController.stepToText(
            target: "val3",
            original: parameter.text,
            read: { parameter.text },
            turn: { parameter.turn($0) }
        )
        XCTAssertEqual(found, "val3")
    }
}
