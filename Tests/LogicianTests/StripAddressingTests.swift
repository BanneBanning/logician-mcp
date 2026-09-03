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

    func testAnUnreadableHeaderColumnReroutesToTheSurfaceToo() {
        // A non-English Logic publishes a localized description on the header
        // column, so EVERY track name dies with this exact signature before
        // either plane is asked — while the surface found the same track by
        // its LCD name in the same session (measured 2026-08-30, French
        // Logic: "Crash" at bank 2 channel 8). The literal string is what
        // `trackHeaderGroup()` throws; the constant and the throw are the
        // same declaration, and this pins both.
        XCTAssertEqual(LogicAccessibility.tracksHeaderGroupMissing, "Tracks header group")
        XCTAssertTrue(isHeaderlessStripCandidate(
            .windowNotFound("Tracks header group"), trackNumberGiven: false
        ))
    }

    func testOtherMissingWindowsAreNeverRerouted() {
        // Any other windowNotFound means the plane's own preconditions failed
        // for reasons the surface cannot vouch for — a missing PROJECT window
        // means the project-path check never ran at all, so a rerouted write
        // could land in the wrong project.
        for missing in [
            "project window with AXDocument",
            "left inspector channel strip",
            "Control Bar group",
            "bounce dialog"
        ] {
            XCTAssertFalse(isHeaderlessStripCandidate(
                .windowNotFound(missing), trackNumberGiven: false
            ), missing)
        }
    }

    func testATrackNumberPinsTheRequestToTheHeaderPlane() {
        // Numbers exist only on track headers, so a caller that passed one is
        // not talking about an output strip — rerouting would hide a typo.
        XCTAssertFalse(isHeaderlessStripCandidate(
            .trackNotFound("track 42", available: []), trackNumberGiven: true
        ))
        // And numbers exist only on headers even when the header column is
        // unreadable: the surface cannot verify a NUMBER, so a non-English
        // Logic must refuse rather than guess.
        XCTAssertFalse(isHeaderlessStripCandidate(
            .windowNotFound("Tracks header group"), trackNumberGiven: true
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
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("the bridge is down"))
        // The header column WAS readable here (the miss is trackNotFound),
        // so the header-plane half keeps its original phrasing.
        XCTAssertTrue(message.contains("not a track header"))
    }

    func testAGenuinelyAbsentNameOnANonEnglishLogicStillNamesBothPlanes() {
        // The header column was unreadable AND the surface has no such strip:
        // the message must say the column could not be read — not claim the
        // name "is not a track header", which nothing ever established — and
        // still show what the surface DID see.
        let failure = headerlessStripError(
            name: "Chrash",
            resolution: .notFound(cells: ["LofPad", "Crash"]),
            visibleTracks: [],
            trackMiss: .windowNotFound("Tracks header group")
        )
        XCTAssertEqual(failure.code, "not_found")
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("none readable"), "no header list to show, and it says so")
        XCTAssertTrue(message.contains("Crash"), "the surface strips it did see")
        XCTAssertTrue(message.contains("Nothing was written"))
    }

    func testAnUnreachableSurfaceOnANonEnglishLogicNamesTheUnreadableColumn() {
        let failure = headerlessStripError(
            name: "Crash",
            resolution: .unavailable(reason: "the bridge is down"),
            visibleTracks: [],
            trackMiss: .windowNotFound("Tracks header group")
        )
        XCTAssertEqual(failure.code, "not_exposed")
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("could not be read"))
        XCTAssertTrue(message.contains("the bridge is down"))
        XCTAssertFalse(message.contains("not a track header"),
                       "nothing established that; the column was unreadable")
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

    // MARK: - The PL view's third proof

    /// The SELECT LED said strip 8 (`Stereo Out`, confirmed on two banks)
    /// while the PL row read `Cha EQ | *PShft | Cha EQ | Comprs` — the track
    /// `Bas`. Observed live 2026-08-28. A browser write in that state inserts
    /// into the wrong strip, and re-selecting cannot fix it: a SELECT press on
    /// an already-lit strip is a no-op.
    private let stereoOutMCU = ["Cha EQ", "Limitr", "Sensor", "--", "--", "--", "--", "--"]
    private let stereoOutAX = ["Sensor", "Limiter", "Channel EQ"]
    private let basMCU = ["Cha EQ", "*PShft", "Cha EQ", "Comprs", "--", "--", "--", "--"]

    func testThePLViewAgreesWithAccessibilityOnTheRightStrip() {
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(mcuCells: stereoOutMCU, axNames: stereoOutAX),
            true
        )
    }

    func testSlotOrderIsNotComparedBecauseAnOutputStripReversesIt() {
        // AX reads Sensor/Limiter/Channel EQ, the surface reads the reverse.
        // Comparing order would refuse every legitimate output-strip write.
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: stereoOutMCU, axNames: ["Channel EQ", "Limiter", "Sensor"]
            ),
            true
        )
    }

    func testTheObservedWrongStripIsCaught() {
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(mcuCells: basMCU, axNames: stereoOutAX),
            false
        )
    }

    func testABypassMarkerIsNotPartOfThePluginName() {
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: ["*Cha EQ", "Limitr", "Sensor"],
                axNames: stereoOutAX
            ),
            true
        )
    }

    func testAStripNoInspectorShowsCannotBeCheckedRatherThanFailed() {
        // `Master` and most auxes answer Accessibility with nothing. An
        // unanswerable check degrades to nil; it must never refuse a write
        // that the two other proofs already allowed.
        XCTAssertNil(MCUController.pluginListAgreesWithAX(mcuCells: basMCU, axNames: []))
    }

    func testACountMismatchIsEnoughOnItsOwn() {
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: ["Cha EQ", "Limitr", "--", "--"], axNames: stereoOutAX
            ),
            false
        )
    }

    // MARK: - Naming a plugin across the two planes

    /// Adding `Parametric EQ` worked and was then reported as a failure,
    /// because Accessibility calls the result `ParEQ` and the cross-check was
    /// a two-way `hasPrefix`: neither string is a prefix of the other, so a
    /// correct write came back as "it may have landed on another channel" and
    /// was left in place. Observed live on `Sweeps`, 2026-08-31.
    func testAnAbbreviatedAXNameStillNamesThePlugin() {
        XCTAssertTrue(MCUController.axNamesPlugin("ParEQ", requested: "Parametric EQ"))
        XCTAssertTrue(MCUController.axNamesPlugin("Comprs", requested: "Compressor"))
        XCTAssertTrue(MCUController.axNamesPlugin("Gain", requested: "Gain"))
        XCTAssertTrue(MCUController.axNamesPlugin("Channel EQ", requested: "Channel EQ"))
        XCTAssertTrue(MCUController.axNamesPlugin("Cha EQ", requested: "Channel EQ"))
    }

    /// `LoPass`/`Low Pass Filter` and `Ovrdr`/`Overdrive` — measured live on
    /// `Crash`, twice: the insertion LANDED and `logic_add_plugin` refused it
    /// as `verification_failed`, `restored: false`, leaving the plugin in
    /// place while reporting the write as failed. Same shape of false failure
    /// as `ParEQ`/`Parametric EQ`, except the dropped characters are the
    /// abbreviation's OWN third character (`Low`'s trailing consonant `w`,
    /// `Overdrive`'s interior vowel `e`), which is exactly what the old
    /// "first three characters match verbatim" guard could not tolerate.
    func testAWordInitialOrVowelDroppedAbbreviationStillNamesThePlugin() {
        XCTAssertTrue(MCUController.axNamesPlugin("LoPass", requested: "Low Pass Filter"))
        XCTAssertTrue(MCUController.axNamesPlugin("Ovrdr", requested: "Overdrive"))
    }

    /// `ARPV3`/`ARP 2600 V3`: the load that worked and was reported a failure
    /// on a `safety: .destructive` tool (`instrumentSlotNames`'s doc comment).
    /// `instrumentSlotNames` also falls back to `lcdAbbreviationPlausible`,
    /// but that test's 6-character floor rejects a 5-character cell outright,
    /// so this case reaches `axNamesPlugin` alone and must still pass here —
    /// which needs the bare model number `2600` skipped as a whole word
    /// rather than contributing a digit.
    func testANumericWordIsSkippedWhole() {
        XCTAssertTrue(MCUController.axNamesPlugin("ARPV3", requested: "ARP 2600 V3"))
    }

    /// The FIX_SPEC's anti-collision requirement: two real Logic plugins
    /// (`Bass Amp Designer`, `Guitar Amp Designer`) that share every word but
    /// their first could plausibly BOTH abbreviate their shared tail to
    /// `AmpDes`. Confirming a request by name alone must not let one answer
    /// for the other — a collision has to come back `false` on both sides so
    /// the caller falls back to the slot-index proof instead of a wrong
    /// `verified: true`.
    func testAxNamesPluginCollisionDegradesSafely() {
        XCTAssertFalse(MCUController.axNamesPlugin("AmpDes", requested: "Bass Amp Designer"))
        XCTAssertFalse(MCUController.axNamesPlugin("AmpDes", requested: "Guitar Amp Designer"))
    }

    func testTheChannelFormatSuffixIsNotPartOfTheName() {
        // The browser entry carries Logic's channel format; the AX name never
        // does, and `browser_entry` is what a caller is most likely to echo.
        XCTAssertTrue(MCUController.axNamesPlugin("Gain", requested: "Gain (s/s)"))
        XCTAssertTrue(
            MCUController.axNamesPlugin("Abbey Road Saturator", requested: "Abbey Road Saturator (m)")
        )
    }

    /// The loosening must not turn into a subsequence free-for-all: an
    /// abbreviation keeps the opening characters, so unrelated plugins that
    /// merely share letters stay unmatched.
    func testAnUnrelatedPluginIsNotMistakenForTheRequestedOne() {
        XCTAssertFalse(MCUController.axNamesPlugin("Gain", requested: "Guitar Amp Pro"))
        XCTAssertFalse(MCUController.axNamesPlugin("Limiter", requested: "Compressor"))
        XCTAssertFalse(MCUController.axNamesPlugin("Echo", requested: "Enveloper"))
        XCTAssertFalse(MCUController.axNamesPlugin("", requested: "Gain"))
        XCTAssertFalse(MCUController.axNamesPlugin("Gain", requested: ""))
    }

    func testTwoCopiesOfOnePluginNeedTwoAXEntries() {
        // `Bas` really does have two Channel EQs; one AX entry must not
        // satisfy both cells.
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: ["Cha EQ", "Cha EQ"], axNames: ["Channel EQ"]
            ),
            false
        )
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: ["Cha EQ", "Cha EQ"], axNames: ["Channel EQ", "Channel EQ"]
            ),
            true
        )
    }

}
