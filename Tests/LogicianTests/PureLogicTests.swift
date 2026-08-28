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

    // MARK: - Smart Tempo mode normalisation (a write-protection control)

    func testProjectTempoModeReadsTheSingleWordLabels() {
        XCTAssertEqual(normalizedProjectTempoMode("Keep"), .keep)
        XCTAssertEqual(normalizedProjectTempoMode("ADAPT"), .adapt)
        XCTAssertEqual(normalizedProjectTempoMode(" auto "), .auto)
    }

    func testProjectTempoModeReadsLongerWordings() {
        XCTAssertEqual(normalizedProjectTempoMode("Adapt Project Tempo"), .adapt)
        XCTAssertEqual(normalizedProjectTempoMode("Keep Project Tempo"), .keep)
        XCTAssertEqual(normalizedProjectTempoMode("Automatic"), .auto)
    }

    func testProjectTempoModeErrsTowardTheRefusalWhenAStringNamesTwoModes() {
        // A sentence mentioning both must resolve to the destructive one:
        // a false refusal costs a retry, a false 'keep' costs the tempo track.
        XCTAssertEqual(
            normalizedProjectTempoMode("Keep project tempo, do not adapt to recordings"),
            .adapt
        )
    }

    func testProjectTempoModeRejectsTextThatNamesNoMode() {
        XCTAssertNil(normalizedProjectTempoMode(""))
        XCTAssertNil(normalizedProjectTempoMode("   "))
        XCTAssertNil(normalizedProjectTempoMode("120"))
        // The pop-up button's help text is what the AX walk actually finds on
        // it; the mode itself is not in there, so it must not be guessed from
        // Apple's tooltip prose.
        XCTAssertNil(normalizedProjectTempoMode("Project Tempo menu, Project Tempo pop-up menu."))
    }

    func testUnknownProjectTempoModesCarryNoNameButDoCarryAnExplanation() {
        for mode in [ProjectTempoMode.unreadable, .absent] {
            XCTAssertNil(mode.name, "an unknown mode must never serialise as a value")
            XCTAssertNotNil(mode.explanation)
            XCTAssertTrue(
                mode.explanation?.contains("Smart Tempo") == true,
                "the explanation has to name the fix's location"
            )
        }
        for mode in [ProjectTempoMode.keep, .adapt, .auto] {
            XCTAssertNotNil(mode.name)
            XCTAssertNil(mode.explanation, "a known mode needs no excuse")
        }
    }

    func testProjectTempoModeRefusalIsAPreconditionFailure() {
        // Nothing is written when this throws, so it belongs to the same
        // vocabulary agents already branch on for "your project isn't ready".
        let error = LogicianError.projectTempoModeUnsafe(mode: "ADAPT", detail: "detail here")
        XCTAssertEqual(error.code, "precondition_failed")
        XCTAssertEqual(
            error.errorDescription,
            "Refusing to record: the project tempo mode is ADAPT. detail here"
        )
    }

    // MARK: - Two-point tempo sampling (tempo-map honesty guards)

    private func span(
        _ startTempo: Double, _ endTempo: Double, bars: (Int, Int) = (5, 33)
    ) -> TempoSpan {
        TempoSpan(
            startBar: bars.0, endBar: bars.1, startTempo: startTempo, endTempo: endTempo
        )
    }

    func testTempoSpanTreatsReadNoiseAsOneTempoAndRealChangesAsTwo() {
        // The epsilon exists to separate display/read noise from a tempo the
        // user actually changed: identical, and a hair apart, are the same
        // tempo; a tenth of a BPM is not.
        XCTAssertTrue(span(120, 120).isConstant)
        XCTAssertTrue(span(120, 120 + tempoSampleEpsilonBPM).isConstant, "exactly at the epsilon is still constant")
        XCTAssertTrue(span(120.5, 120.53).isConstant)
        XCTAssertFalse(span(120, 120.1).isConstant, "0.1 BPM is a deliberate change, not noise")
        XCTAssertFalse(span(120, 140).isConstant)
        XCTAssertFalse(span(140, 120).isConstant, "the direction of the change is irrelevant")
    }

    func testTempoSpanEpsilonStaysBelowTheSliderResolution() {
        // setTempo writes whole BPM and accepts +-0.5; the detector has to be
        // strictly finer than that or a 1 BPM tempo map would read as constant.
        XCTAssertLessThan(tempoSampleEpsilonBPM, 0.5)
        XCTAssertFalse(span(120, 121).isConstant)
    }

    func testTempoSpanNamesBothReadingsAndBothBars() {
        let clause = span(120, 140, bars: (5, 33)).mismatchClause
        XCTAssertEqual(
            clause,
            "the tempo changes across bars 5-33 (120 BPM at bar 5, 140 BPM at bar 33)"
        )
        // A fractional tempo must not be rounded away in the message an agent
        // reads to decide whether the change is real.
        XCTAssertTrue(span(120.5, 90.25).mismatchClause.contains("120.5 BPM"))
        XCTAssertTrue(span(120.5, 90.25).mismatchClause.contains("90.25 BPM"))
    }

    func testTempoWarningIsSilentOnAConstantTempo() {
        XCTAssertNil(tempoSpanWarning(.constant(span(120, 120)), sliced: "this slice"))
        XCTAssertNil(TempoSample.verdict(.constant(span(120, 120))).warning(sliced: "this slice"))
    }

    func testTempoWarningOnAMismatchNamesTheReadingsAndTheSafeAlternative() {
        guard let warning = tempoSpanWarning(.varying(span(120, 140)), sliced: "this slice") else {
            return XCTFail("a varying tempo must produce a warning")
        }
        XCTAssertTrue(warning.contains("120 BPM at bar 5"))
        XCTAssertTrue(warning.contains("140 BPM at bar 33"))
        XCTAssertTrue(warning.contains("this slice"))
        // The alternative has to be named, or the warning tells an agent it is
        // stuck instead of telling it what works.
        XCTAssertTrue(warning.contains("logic_bounce_range"))
        XCTAssertTrue(warning.contains("solo_bounce"))
    }

    func testTempoWarningDistinguishesUnverifiedFromVarying() {
        guard let warning = tempoSpanWarning(
            .unverified(reason: "the control bar reports no playhead position"),
            sliced: "this slice"
        ) else {
            return XCTFail("an unverified check must say so")
        }
        XCTAssertTrue(warning.contains("NOT VERIFIED"))
        XCTAssertTrue(warning.contains("the control bar reports no playhead position"))
        XCTAssertTrue(warning.contains("logic_bounce_range"))
        // "could not check" must never read as "checked and fine".
        XCTAssertFalse(warning.contains("TEMPO MAP DETECTED"))
    }

    func testAPlayheadLeftBehindIsReportedEvenWhenTheTempoIsConstant() {
        // The sample moves the playhead twice. A restore that did not happen is
        // a state leak, and this codebase does not report restorations it did
        // not make - so it rides along with an otherwise silent verdict.
        let leak = "THE PLAYHEAD WAS NOT PUT BACK: ..."
        let sample = TempoSample(sample: .constant(span(120, 120)), playheadLeak: leak)
        XCTAssertEqual(sample.warning(sliced: "this slice"), leak)
        let varying = TempoSample(sample: .varying(span(120, 140)), playheadLeak: leak)
        let warning = varying.warning(sliced: "this slice") ?? ""
        XCTAssertTrue(warning.contains("TEMPO MAP DETECTED"), "the verdict survives the leak")
        XCTAssertTrue(warning.contains(leak), "and the leak survives the verdict")
    }

    func testRefusalDetailCarriesTheReadingsWithoutTheSliceAdvice() {
        let detail = TempoSample.verdict(.varying(span(120, 140))).refusalDetail ?? ""
        XCTAssertTrue(detail.contains("120 BPM at bar 5"))
        // A refusal names its own alternative in its own words; the slice
        // advice would be wrong for the tools that refuse.
        XCTAssertFalse(detail.contains("logic_bounce_range"))
        XCTAssertNil(TempoSample.verdict(.constant(span(120, 120))).refusalDetail)
        XCTAssertNil(
            TempoSample.verdict(.unverified(reason: "no playhead")).refusalDetail,
            "an unverified sample refuses nothing, so it details nothing"
        )
    }

    func testTempoWriteWarningTalksAboutTheWriteNotAboutSlices() {
        // logic_set_tempo slices nothing: an unverified check there means the
        // WRITE may have landed on one tempo node.
        let sample = TempoSample.verdict(.unverified(reason: "no playhead position"))
        guard let warning = sample.writeWarning else {
            return XCTFail("an unverified tempo-map check must be reported")
        }
        XCTAssertTrue(warning.contains("TEMPO MAP NOT VERIFIED"))
        XCTAssertTrue(warning.contains("tempo node at the playhead"))
        XCTAssertTrue(warning.contains("Undo"))
        XCTAssertFalse(warning.contains("logic_bounce_range"), "there is no slice to bounce instead")
        XCTAssertNil(TempoSample.verdict(.constant(span(120, 120))).writeWarning)
        XCTAssertNil(
            TempoSample.verdict(.varying(span(120, 140))).writeWarning,
            "a detected map is refused, not warned about"
        )
    }

    func testTempoMapRefusalIsAPreconditionFailureThatNamesTheOperation() {
        // Nothing is written when this throws, so it joins the vocabulary
        // agents already branch on - the same code the Smart Tempo guard uses.
        let error = LogicianError.tempoMapUnsafe(
            operation: "logic_set_tempo", detail: "detail here"
        )
        XCTAssertEqual(error.code, "precondition_failed")
        XCTAssertEqual(
            error.errorDescription,
            "Refusing logic_set_tempo: the project tempo is not constant. detail here"
        )
    }

    func testWarningsAccumulateInsteadOfOverwritingEachOther() {
        var result: [String: Any] = [:]
        appendWarning(nil, to: &result)
        appendWarning("", to: &result)
        XCTAssertNil(result["warning"], "nothing to say means no warning key at all")
        appendWarning("the render is silent", to: &result)
        XCTAssertEqual(result["warning"] as? String, "the render is silent")
        appendWarning("the tempo changes", to: &result)
        // Both complaints can be true at once, and the first one written must
        // not be lost - an agent reading only `warning` has to see both.
        XCTAssertEqual(
            result["warning"] as? String,
            "the render is silent ALSO: the tempo changes"
        )
        appendWarning("the tempo changes", to: &result)
        XCTAssertEqual(
            result["warning"] as? String,
            "the render is silent ALSO: the tempo changes",
            "the same warning twice is one warning"
        )
    }

    // MARK: - Bar math and end-of-take length (the meter is not always 4)

    func testBarRangeSecondsIsTheConstantTempoFormula() throws {
        let range = try MCPServer.barRangeSeconds(
            startBar: 1, endBar: 5, tempo: 120, beatsPerBar: 4
        )
        XCTAssertEqual(range.start, 0, accuracy: 1e-9, "bar 1 is the project start")
        XCTAssertEqual(range.end, 8, accuracy: 1e-9, "four bars of 2 s at 120 BPM in 4/4")
        // The meter is what makes a bar long, not the number 4.
        let waltz = try MCPServer.barRangeSeconds(
            startBar: 3, endBar: 5, tempo: 120, beatsPerBar: 3
        )
        XCTAssertEqual(waltz.start, 3, accuracy: 1e-9)
        XCTAssertEqual(waltz.end, 6, accuracy: 1e-9)
    }

    func testBarRangeSecondsRefusesRangesAndTemposItCannotConvert() {
        for bad in [(0, 4), (1, 1), (5, 2)] {
            XCTAssertThrowsError(
                try MCPServer.barRangeSeconds(
                    startBar: bad.0, endBar: bad.1, tempo: 120, beatsPerBar: 4
                ),
                "start \(bad.0), end \(bad.1) is not a range"
            )
        }
        XCTAssertThrowsError(
            try MCPServer.barRangeSeconds(startBar: 1, endBar: 5, tempo: 0, beatsPerBar: 4),
            "a zero tempo would divide by zero and return infinity as a boundary"
        )
        XCTAssertThrowsError(
            try MCPServer.barRangeSeconds(startBar: 1, endBar: 5, tempo: 120, beatsPerBar: 0)
        )
    }

    func testTakeEndMeasuresTheTakeInTheProjectsOwnMeter() {
        // Four 4/4 bars of whole notes starting at bar 9: the take ends where
        // bar 13 begins.
        let notes = (0..<4).map { (bar: 9 + $0, beat: 1.0, durationBeats: 4.0) }
        let common = MCPServer.takeEnd(
            startBar: 9, beatsPerBar: 4, notes: notes, extraEventBars: []
        )
        XCTAssertEqual(common.lastBeat, 16, accuracy: 1e-9)
        XCTAssertEqual(common.endBar, 13)
        // The same four bars in 3/4 are twelve beats, not sixteen - the bug
        // this replaced measured them with a hardcoded 4 and claimed bar 13
        // while the verification render, which already used the real meter,
        // claimed something else.
        let waltz = MCPServer.takeEnd(
            startBar: 9, beatsPerBar: 3,
            notes: (0..<4).map { (bar: 9 + $0, beat: 1.0, durationBeats: 3.0) },
            extraEventBars: []
        )
        XCTAssertEqual(waltz.lastBeat, 12, accuracy: 1e-9)
        XCTAssertEqual(waltz.endBar, 13)
    }

    func testTakeEndCountsOffbeatsPartialBarsAndCCEvents() {
        // A note starting on beat 2.5 of the second bar, lasting half a beat,
        // ends 1.5 beats into that bar - the take still occupies two bars.
        let offbeat = MCPServer.takeEnd(
            startBar: 1, beatsPerBar: 4,
            notes: [(bar: 2, beat: 2.5, durationBeats: 0.5)], extraEventBars: []
        )
        XCTAssertEqual(offbeat.lastBeat, 6, accuracy: 1e-9)
        XCTAssertEqual(offbeat.endBar, 3)
        // A CC event carries no duration, so it claims the bar it sits in -
        // measured in the project's meter as well.
        let withCC = MCPServer.takeEnd(
            startBar: 1, beatsPerBar: 3,
            notes: [(bar: 1, beat: 1, durationBeats: 1)], extraEventBars: [4]
        )
        XCTAssertEqual(withCC.lastBeat, 12, accuracy: 1e-9)
        XCTAssertEqual(withCC.endBar, 5)
    }

    func testTakeEndNeverReturnsAnEmptyRange() {
        // A single short note still occupies a bar, and the bar math downstream
        // refuses end <= start.
        let tiny = MCPServer.takeEnd(
            startBar: 4, beatsPerBar: 4,
            notes: [(bar: 4, beat: 1, durationBeats: 0.25)], extraEventBars: []
        )
        XCTAssertEqual(tiny.endBar, 5)
        XCTAssertGreaterThan(tiny.endBar, 4)
        // An absent meter falls back to 4 rather than dividing by zero.
        let noMeter = MCPServer.takeEnd(
            startBar: 1, beatsPerBar: 0,
            notes: [(bar: 1, beat: 1, durationBeats: 4)], extraEventBars: []
        )
        XCTAssertEqual(noMeter.endBar, 2)
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

    // MARK: - MCU timecode mode plausibility (beats vs SMPTE)

    /// The bridge decodes the ten 7-segment digits into exactly ten
    /// characters with no separators (a 10-byte buffer written right to
    /// left), so the position fields are fixed slices: bar 3, beat 2,
    /// division 2, ticks 3.
    private func assertBeats(
        _ raw: String?, bar: Int, beat: Int, division: Int, ticks: Int,
        expectedBar: Int? = nil, _ message: String = "", line: UInt = #line
    ) {
        let reading = MCUController.classifyTimecode(raw, expectedBar: expectedBar)
        guard case .beats(let b, let bt, let d, let t) = reading else {
            return XCTFail("expected a beats reading, got \(reading). \(message)", line: line)
        }
        XCTAssertEqual([b, bt, d, t], [bar, beat, division, ticks], message, line: line)
    }

    private func assertImplausible(_ raw: String?, expectedBar: Int? = nil,
                                   _ message: String = "", line: UInt = #line) {
        let reading = MCUController.classifyTimecode(raw, expectedBar: expectedBar)
        guard case .implausible = reading else {
            return XCTFail("expected implausible, got \(reading). \(message)", line: line)
        }
    }

    func testClassifyTimecodeAcceptsARealBeatsDisplay() {
        assertBeats("0010101000", bar: 1, beat: 1, division: 1, ticks: 0)
        // Leading-zero suppression blanks the unused digits of the bar field.
        assertBeats(" 210101000", bar: 21, beat: 1, division: 1, ticks: 0)
        assertBeats("  10403120", bar: 1, beat: 4, division: 3, ticks: 120)
        // The three-digit bar field's ceiling.
        assertBeats("9990403120", bar: 999, beat: 4, division: 3, ticks: 120)
    }

    func testClassifyTimecodeAcceptsTheSpaceSeparatedRendering() {
        // The shape the snapshot fixture in ProtocolTests spells out. The
        // live bridge emits no separators, but a formatter change must not
        // turn every position into "implausible".
        assertBeats("001 01 01 000", bar: 1, beat: 1, division: 1, ticks: 0)
        assertBeats("128 03 02 240", bar: 128, beat: 3, division: 2, ticks: 240)
    }

    func testClassifyTimecodeToleratesBlankDivisionAndTickFields() {
        // The 7-segment decode is only verified for digits and spaces
        // (FINDINGS 2026-08-25), so blanks in the two fields nothing reads
        // must not refuse a legitimate recording.
        assertBeats("00101     ", bar: 1, beat: 1, division: 0, ticks: 0)
        assertBeats("00101 1   ", bar: 1, beat: 1, division: 1, ticks: 0)
    }

    func testClassifyTimecodeRejectsSMPTEShapedDigits() {
        // 00:00:00:00 — the zero-based hours field cannot be a bar number.
        assertImplausible("  00000000", "SMPTE at zero")
        // 01:12:34:12 right-aligned: still a zero/blank bar field.
        assertImplausible("  01123412", "one hour in")
        // A bar field that happens to look plausible, caught by the
        // zero-based minutes landing in the beat field.
        assertImplausible("0010001234", "00 minutes is not beat 0")
        // …and by zero-based seconds landing in the division field.
        assertImplausible("0102000345", "00 seconds is not division 0")
    }

    func testClassifyTimecodeCatchesPlausibleLookingSMPTEViaTheParkedBar() {
        // Honest about the limit of shape alone: these digits pass every
        // format rule, so only the cross-check against the bar the playhead
        // was just parked at can reject them. Every guarded call site that
        // has parked the playhead passes expectedBar for exactly this.
        assertBeats("0102030405", bar: 10, beat: 20, division: 30, ticks: 405,
                    "shape alone cannot rule this out")
        assertImplausible("0102030405", expectedBar: 8, "cross-check must reject it")
    }

    func testClassifyTimecodeAppliesTheParkedBarWithinOneBarOfSlack() {
        assertBeats("0070101000", bar: 7, beat: 1, division: 1, ticks: 0, expectedBar: 7)
        // One bar of slack: the display can be mid-update after a park.
        assertBeats("0070101000", bar: 7, beat: 1, division: 1, ticks: 0, expectedBar: 8)
        assertBeats("0070101000", bar: 7, beat: 1, division: 1, ticks: 0, expectedBar: 6)
        assertImplausible("0070101000", expectedBar: 9)
        assertImplausible("0070101000", expectedBar: 121, "hours-as-bars is the bug this catches")
    }

    func testClassifyTimecodeReportsTheAlertSentinelSeparately() {
        // A modal dialog freezes the whole mirror and Logic paints ALERT;
        // that is a dismiss-the-dialog problem, not a display-mode problem.
        XCTAssertEqual(MCUController.classifyTimecode("ALERT     "), .alert)
        XCTAssertEqual(MCUController.classifyTimecode("  ALERT   "), .alert)
    }

    func testClassifyTimecodeReportsTheNeverPaintedDisplayAsNotReported() {
        // The bridge's buffer starts as ten spaces, and a missing status
        // yields nil — neither is evidence about the mode.
        XCTAssertEqual(MCUController.classifyTimecode(nil), .notReported)
        XCTAssertEqual(MCUController.classifyTimecode(""), .notReported)
        XCTAssertEqual(MCUController.classifyTimecode("          "), .notReported)
    }

    func testClassifyTimecodeRejectsShortAndNonNumericDisplays() {
        assertImplausible("001", "too short to carry a position")
        assertImplausible("ABCDEFGHIJ", "letters are not a position")
        assertImplausible("--- -- -- ---", "the dashes transient is not a position")
    }

    func testBeatsDisplayGuardNamesTheSMPTEFixAndRefusesWithoutWriting() {
        let error = MCUController.beatsDisplayError(
            for: MCUController.classifyTimecode("  00000000"),
            operation: "MIDI recording at bar 5"
        )
        XCTAssertEqual(error?.code, "precondition_failed",
                       "nothing is written by the check, so this is a precondition")
        let message = error?.errorDescription ?? ""
        XCTAssertTrue(message.contains("SMPTE mode"), message)
        XCTAssertTrue(message.contains("press the SMPTE/Beats button"), message)
        XCTAssertTrue(message.contains("MIDI recording at bar 5"), message)
    }

    func testBeatsDisplayGuardDistinguishesAlertBlankAndUsableReadings() {
        XCTAssertNil(MCUController.beatsDisplayError(
            for: .beats(bar: 4, beat: 1, division: 1, ticks: 0), operation: "x"
        ))
        let alert = MCUController.beatsDisplayError(for: .alert, operation: "x")
        XCTAssertEqual(alert?.code, "verification_failed")
        XCTAssertTrue((alert?.errorDescription ?? "").contains("ALERT"))
        let blank = MCUController.beatsDisplayError(for: .notReported, operation: "x")
        XCTAssertEqual(blank?.code, "not_exposed")
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

    // MARK: - Audio frame indexing (the slicer's clamp)

    func testAudioFrameIndexClampsToBothEndsOfTheFile() {
        // 100 frames at 100 Hz = one second of file.
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(0, rate: 100, cap: 100), 0)
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(0.5, rate: 100, cap: 100), 50)
        // Past the end clamps to the end, not past it.
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(9, rate: 100, cap: 100), 100)
        // BEFORE the start clamps to zero. This is the one that mattered: a
        // negative index fed an unsafe pointer walk and read outside the
        // buffer entirely (SIGBUS), taking the whole server down.
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(-0.5, rate: 100, cap: 100), 0)
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(-1e9, rate: 100, cap: 100), 0)
    }

    func testAudioFrameIndexRefusesWhatItCannotMeasureAgainst() {
        XCTAssertNil(LogicAccessibility.audioFrameIndex(1, rate: 0, cap: 100))
        XCTAssertNil(LogicAccessibility.audioFrameIndex(.nan, rate: 100, cap: 100))
        XCTAssertNil(LogicAccessibility.audioFrameIndex(.infinity, rate: 100, cap: 100))
        XCTAssertNil(LogicAccessibility.audioFrameIndex(1, rate: .infinity, cap: 100))
    }

    func testAudioFrameIndexSurvivesSecondsNoIntCanHold() {
        // `Int(1e300 * 44100)` is a Swift runtime trap; clamping to the cap is
        // the only answer that is neither a trap nor a wrong number.
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(1e300, rate: 44100, cap: 512), 512)
        XCTAssertEqual(LogicAccessibility.audioFrameIndex(-1e300, rate: 44100, cap: 512), 0)
    }

    // MARK: - What the notes-crossing modal is reported to have done

    func testNotesCrossingNoteSaysNothingWasAskedWhenNoDialogAppeared() {
        let note = LogicAccessibility.notesCrossingNote(nil, requested: "split")
        XCTAssertTrue(note.contains("No 'Notes Crossing Split Point' dialog appeared"))
    }

    func testNotesCrossingNoteReportsTheChoiceItActuallyPressed() {
        let note = LogicAccessibility.notesCrossingNote("split", requested: "split")
        XCTAssertTrue(note.contains("this answered 'split'"))
    }

    func testNotesCrossingNoteRefusesToClaimAChoiceLogicMade() {
        // The bug: the answer was reported as the REQUESTED choice even when
        // no radio button carrying it existed, so Logic's own default decided
        // how the crossing notes were cut and the result said otherwise.
        let note = LogicAccessibility.notesCrossingNote(
            LogicAccessibility.notesCrossingLogicDefault, requested: "split"
        )
        XCTAssertFalse(note.contains("this answered 'split'"))
        XCTAssertTrue(note.contains("published no 'split' option"))
        XCTAssertTrue(note.contains("unknown"))
    }

    func testNotesCrossingNoteSaysTheSplitWasAbandonedWhenItCouldNotConfirm() {
        let note = LogicAccessibility.notesCrossingNote(
            LogicAccessibility.notesCrossingUnanswered, requested: "split"
        )
        XCTAssertTrue(note.contains("cancelled"))
        XCTAssertTrue(note.contains("abandoned"))
        // It must NOT promise the two halves exist.
        XCTAssertFalse(note.contains("The two halves are new regions"))
    }
}
