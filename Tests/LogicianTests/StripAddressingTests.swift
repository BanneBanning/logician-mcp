import XCTest
@testable import Logician

/// Resolving a strip NAME to a control-surface strip, and choosing which plane
/// can address it. Pure: no Logic, no bridge. Every rule here decides which
/// channel a write lands on, which is the one mistake this server exists to
/// prevent — plugins once landed on Stereo Out by accident (FINDINGS
/// 2026-08-25, v0.31.0), and the master chain was unaddressable for the
/// mirror-image reason.
final class StripAddressingTests: XCTestCase {

    /// The real bank map of the reference project, read off the surface
    /// 2026-08-27 (25 strips, so the rightmost bank CLAMPS and re-shows the
    /// previous bank's tail shifted by one).
    private let bankTops = [
        "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg ",
        "DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  ",
        "Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out ",
        "Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out Master "
    ]

    // MARK: - The abbreviation-plausibility tightening

    func testEveryObservedAbbreviationIsPlausibleForItsOwnName() {
        // Track names from Accessibility paired with the cells Logic painted
        // for them (same session, same project). If Logic ever abbreviates a
        // long name into fewer than six characters, this is the test that
        // catches it before a user does.
        let observed = [
            ("Lofi Pad", "LofPad"), ("Bas", "Bas"), ("808", "808"),
            ("Inst 2", "Inst 2"), ("Drums", "Drums"), ("Fill", "Fill"),
            ("Acke Slagverk", "AckSlg"), ("Ivan Slagverk", "IvnSlg"),
            ("Drum Synth Kit", "DrSyKi"), ("Vocals", "Vocals"),
            ("Ivan Vocals", "IvnVoc"),
            ("Acke Vocals", "AckVoc"), ("Sweeps", "Sweeps"), ("Crash", "Crash"),
            ("Vinyl", "Vinyl"), ("Audio 8", "Audio8"), ("Audio 9", "Audio9"),
            ("Aux 1", "Aux 1"), ("Stereo Out", "St Out"), ("Master", "Master")
        ]
        for (name, cell) in observed {
            XCTAssertTrue(
                MCUController.lcdAbbreviationPlausible(track: name, lcd: cell),
                "'\(cell)' must stay a plausible abbreviation of '\(name)'"
            )
        }
    }

    func testLogicSometimesSUBSTITUTESWordsWhichSubsequenceMatchingCannotRecover() {
        // A known, pre-existing gap, documented rather than papered over:
        // Logic abbreviated the track "Ivan Effect" to "IvanFx" — "Effect"
        // became "Fx", which is not a subsequence of the name at all, so
        // NEITHER the matcher nor the plausibility filter can recover it and
        // that track has never been addressable by name on the surface. It
        // fails as "not found" (nothing written), never as a wrong strip.
        XCTAssertFalse(MCUController.lcdNameMatches(track: "Ivan Effect", lcd: "IvanFx"))
        XCTAssertFalse(MCUController.lcdAbbreviationPlausible(track: "Ivan Effect", lcd: "IvanFx"))
        XCTAssertTrue(MCUController.channelMatches(name: "Ivan Effect", bankTops: bankTops).isEmpty)
    }

    func testAShortCellIsNotAnAbbreviationOfALongName() {
        // The hazard the tightening exists for: "Set" is an ordered
        // subsequence of "Stereo Out" (s-e-t), so the old matcher accepted it —
        // and on a project without a Stereo Out it would have been the only
        // match, sending the write to a track called Set.
        XCTAssertTrue(MCUController.lcdNameMatches(track: "Stereo Out", lcd: "Set"))
        XCTAssertFalse(MCUController.lcdAbbreviationPlausible(track: "Stereo Out", lcd: "Set"))
        XCTAssertFalse(MCUController.lcdAbbreviationPlausible(track: "Stereo Out", lcd: "So"))
        XCTAssertFalse(MCUController.lcdAbbreviationPlausible(track: "Acke Slagverk", lcd: "Ace"))
    }

    func testTwoNamesThatAbbreviateAlikeStayAmbiguousRatherThanWrong() {
        // "Stereo Outro" would fill the cell exactly like "Stereo Out", so
        // BOTH are plausible for the cell "St Out" — which is what makes the
        // pair resolve to `ambiguous` (refusal) instead of to a coin flip.
        XCTAssertTrue(MCUController.lcdAbbreviationPlausible(track: "Stereo Out", lcd: "St Out"))
        XCTAssertTrue(MCUController.lcdAbbreviationPlausible(track: "Stereo Outro", lcd: "St Out"))
        let matches = MCUController.channelMatches(
            name: "Stereo Out",
            bankTops: ["St Out StOutr                                           "]
        )
        XCTAssertEqual(matches.count, 1, "'StOutr' is not an abbreviation of 'Stereo Out'")
        XCTAssertEqual(matches.first, MCUController.BankMatch(bank: 0, channel: 0))
    }

    func testAnUnabbreviatedCellPassesOnTheSubsequenceMatchAlone() {
        XCTAssertTrue(MCUController.lcdAbbreviationPlausible(track: "Bas", lcd: "Bas"))
        XCTAssertTrue(MCUController.lcdAbbreviationPlausible(track: "Fill", lcd: "Fill"))
        XCTAssertFalse(MCUController.lcdAbbreviationPlausible(track: "Bas", lcd: ""))
    }

    // MARK: - The clamped rightmost bank

    func testClampOverlapFindsTheShiftOfTheRightmostBank() {
        let shift = MCUController.clampOverlap(
            previous: MCUController.lcdFields(bankTops[2]),
            last: MCUController.lcdFields(bankTops[3])
        )
        XCTAssertEqual(shift, 1, "25 strips means the last bank re-shows 7 of the previous 8")
    }

    func testClampOverlapIsNilWhenTheBanksAreDisjoint() {
        XCTAssertNil(MCUController.clampOverlap(
            previous: MCUController.lcdFields(bankTops[0]),
            last: MCUController.lcdFields(bankTops[1])
        ))
    }

    func testClampOverlapRefusesRowsThatAreNotEightCells() {
        XCTAssertNil(MCUController.clampOverlap(previous: ["a", "b"], last: ["b", "c"]))
    }

    func testTheClampedBankNoLongerMakesAUniqueNameAmbiguous() {
        // This is the bug that kept the whole master chain unaddressable:
        // Stereo Out shows up in banks 2 AND 3, findChannel counted two
        // matches, read that as "ambiguous" and returned nil — for a strip
        // that is perfectly unique.
        let matches = MCUController.channelMatches(name: "Stereo Out", bankTops: bankTops)
        XCTAssertEqual(matches, [MCUController.BankMatch(bank: 2, channel: 7)],
                       "the earliest (non-clamped) position addresses the same strip")
    }

    func testEveryStripInTheClampedOverlapResolvesUniquely() {
        for (name, expected) in [
            ("Aux 1", MCUController.BankMatch(bank: 2, channel: 3)),
            ("Aux 2", MCUController.BankMatch(bank: 2, channel: 4)),
            ("Aux 3", MCUController.BankMatch(bank: 2, channel: 5)),
            ("Audio 8", MCUController.BankMatch(bank: 2, channel: 1)),
            ("Audio 9", MCUController.BankMatch(bank: 2, channel: 2))
        ] {
            XCTAssertEqual(MCUController.channelMatches(name: name, bankTops: bankTops), [expected], name)
        }
    }

    func testAStripThatOnlyTheClampedBankShowsStillResolves() {
        // The Master fader strip is the 25th of 25: it exists ONLY in the
        // shifted last bank, so it must survive de-duplication.
        XCTAssertEqual(
            MCUController.channelMatches(name: "Master", bankTops: bankTops),
            [MCUController.BankMatch(bank: 3, channel: 7)]
        )
    }

    func testDeduplicationNeverCollapsesGenuinelyDifferentStrips() {
        // Two tracks really named "Ivan Vocals" sit side by side in bank 1.
        let matches = MCUController.channelMatches(name: "Ivan Vocals", bankTops: bankTops)
        XCTAssertEqual(matches, [
            MCUController.BankMatch(bank: 1, channel: 2),
            MCUController.BankMatch(bank: 1, channel: 3)
        ], "a duplicate NAME must stay ambiguous; only the clamp overlap is collapsed")
    }

    func testDeduplicationLeavesADisjointLastBankAlone() {
        // A strip count divisible by 8 means no clamp and nothing to collapse.
        let disjoint = [bankTops[0], bankTops[1]]
        let matches = MCUController.channelMatches(name: "Vocals", bankTops: disjoint)
        XCTAssertEqual(matches, [MCUController.BankMatch(bank: 1, channel: 1)])
    }

    func testANameOnNoStripMatchesNothing() {
        XCTAssertTrue(MCUController.channelMatches(name: "Sidechain Bus", bankTops: bankTops).isEmpty)
        XCTAssertTrue(MCUController.channelMatches(name: "Set", bankTops: bankTops).isEmpty)
    }

    func testBankMapCellsListsEveryStripOnceForErrorMessages() {
        let cells = MCUController.bankMapCells(bankTops)
        // 25 strips, but two tracks share the cell "IvnVoc" — the list is of
        // NAMES the surface shows, so a duplicate name appears once.
        XCTAssertEqual(cells.count, 24)
        XCTAssertEqual(cells.first, "LofPad")
        XCTAssertEqual(cells.last, "Master")
        XCTAssertFalse(cells.contains(""))
    }

    // MARK: - Which plane addresses the name

    func testOnlyAMissingTrackHeaderReroutesToTheSurface() {
        XCTAssertTrue(isHeaderlessStripCandidate(
            .trackNotFound("Stereo Out", available: ["1: Bas"]), trackNumberGiven: false
        ))
    }

    func testATrackNumberPinsTheRequestToTheHeaderPlane() {
        // Numbers exist only on track headers, so a caller that passed one is
        // not talking about an output strip — rerouting would hide a typo.
        XCTAssertFalse(isHeaderlessStripCandidate(
            .trackNotFound("track 42", available: []), trackNumberGiven: true
        ))
    }

    func testRealTrackFailuresAreNeverRerouted() {
        // These all mean "the name IS a track and something else went wrong".
        XCTAssertFalse(isHeaderlessStripCandidate(
            .trackAmbiguous("Ivan Vocals", numbers: [21, 22]), trackNumberGiven: false
        ))
        XCTAssertFalse(isHeaderlessStripCandidate(
            .trackMismatch(number: 2, expected: "Bas", actual: "808"), trackNumberGiven: false
        ))
        XCTAssertFalse(isHeaderlessStripCandidate(
            .selectionFailed(requested: "Bas", actual: "808", restored: true), trackNumberGiven: false
        ))
        XCTAssertFalse(isHeaderlessStripCandidate(
            .accessibilityNotTrusted, trackNumberGiven: false
        ))
    }

    // MARK: - What a failed surface resolution says

    private func error(for resolution: MCUController.ChannelResolution) -> LogicianError {
        headerlessStripError(
            name: "Stereo Out",
            resolution: resolution,
            visibleTracks: ["Bas", "808"],
            trackMiss: .trackNotFound("Stereo Out", available: ["Bas", "808"])
        )
    }

    func testAnUnknownNameIsNotFoundAndNamesBothPlanes() {
        let failure = error(for: .notFound(cells: ["LofPad", "St Out"]))
        XCTAssertEqual(failure.code, "not_found")
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("Bas"), "the track headers it did see")
        XCTAssertTrue(message.contains("St Out"), "and the surface strips it did see")
        XCTAssertTrue(message.contains("Nothing was written"))
    }

    func testSeveralMatchingStripsAreAmbiguousAndListTheCells() {
        let failure = error(for: .ambiguous(cells: ["St Out", "StOutr"]))
        XCTAssertEqual(failure.code, "ambiguous")
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("St Out"))
        XCTAssertTrue(message.contains("StOutr"))
    }

    func testAnUnreachableSurfaceIsNotExposedAndCarriesTheReason() {
        let failure = error(for: .unavailable(reason: "the bridge is down"))
        XCTAssertEqual(failure.code, "not_exposed")
        XCTAssertTrue((failure.errorDescription ?? "").contains("the bridge is down"))
    }

    // MARK: - Plane naming (goes into results as selection_route)

    func testPlaneNamesAreTheRouteStringsResultsCarry() {
        XCTAssertEqual(StripPlane.trackHeader.rawValue, "ax_track_header")
        XCTAssertEqual(StripPlane.surfaceChannel.rawValue, "mcu_channel")
    }

    func testATrackTargetReportsOnlyItsRoute() {
        let target = MCPServer.StripTarget(
            name: "Bas", plane: .trackHeader, channel: nil, selection: [:], evidence: nil
        )
        XCTAssertEqual(target.resultFields as? [String: String], ["selection_route": "ax_track_header"])
    }

    func testASurfaceTargetReportsTheStripAndWhatProvedIt() {
        let target = MCPServer.StripTarget(
            name: "Stereo Out", plane: .surfaceChannel, channel: 7,
            selection: nil, evidence: "mcu_lcd_name_and_select_led"
        )
        let fields = target.resultFields
        XCTAssertEqual(fields["selection_route"] as? String, "mcu_channel")
        // 1-based for the agent, like every other slot/strip number in results.
        XCTAssertEqual(fields["mcu_strip"] as? Int, 8)
        XCTAssertEqual(fields["selection_readback_route"] as? String, "mcu_lcd_name_and_select_led")
    }
}
