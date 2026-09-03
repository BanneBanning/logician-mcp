import XCTest
@testable import Logician
import LogicMCUBridge

/// The pure half of `logic_remove_plugin`'s mouse-free route: which slot the
/// browse clears, and what counts as proof afterwards. All three functions
/// run without a surface, and all three earned a test the hard way — a strip
/// holding three `Gain` inserts (2026-08-31) could not be cleaned up at all,
/// because ambiguity threw past the fallback and the after-checks demanded
/// the NAME be gone rather than one instance fewer.
final class RemovalResolutionTests: XCTestCase {

    /// Eight LCD cells the way `pluginInsertNames` yields them: trimmed,
    /// "--" for an empty slot.
    private func row(_ cells: String...) -> [String] {
        cells + Array(repeating: MCULCDStrings.emptySlot, count: 8 - cells.count)
    }

    // MARK: - resolveRemovalSlot: the unique-name path

    func testAUniqueNameMatchResolvesWithoutInsertSlot() throws {
        let inserts = row("Gain", "Cha EQ", "Limitr")
        XCTAssertEqual(
            try MCUController.resolveRemovalSlot(
                inserts: inserts, pluginName: "Channel EQ", trackName: "Bas", insertSlot: nil
            ),
            1
        )
    }

    func testABypassedInsertStillMatchesByName() throws {
        let inserts = row("Gain", MCULCDStrings.bypassMarker + "PitchS")
        XCTAssertEqual(
            try MCUController.resolveRemovalSlot(
                inserts: inserts, pluginName: "Pitch Shifter", trackName: "Bas", insertSlot: nil
            ),
            1
        )
    }

    func testNoMatchThrowsNotFoundWithTheSlotNumberedInserts() {
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Cha EQ"), pluginName: "Compressor",
                trackName: "Bas", insertSlot: nil
            )
        ) { error in
            guard case .insertNotFound(let track, let plugin, let available)
                = error as? LogicianError else {
                return XCTFail("expected insertNotFound, got \(error)")
            }
            XCTAssertEqual(track, "Bas")
            XCTAssertEqual(plugin, "Compressor")
            XCTAssertEqual(available, ["1: Gain", "2: Cha EQ"])
        }
    }

    /// The cosmetic defect this fix closes: a not-found refusal must quote
    /// the channel strip inspector's own insert readback, never the raw MCU
    /// cells `inserts` carries — an aborted add-browse earlier in the
    /// session can leave one of those cells showing a stale catalog-scroll
    /// entry until the next press repaints it, and the two readbacks
    /// disagreeing is exactly the situation `stripInsertNames` exists for.
    func testNotFoundQuotesTheInspectorReadbackNotTheStaleMCUCells() {
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Parametric EQ (s/s)  --", "Cha EQ"), pluginName: "Compressor",
                trackName: "Bas", insertSlot: nil,
                stripInsertNames: ["Gain", "Channel EQ"]
            )
        ) { error in
            guard case .insertNotFound(_, _, let available) = error as? LogicianError else {
                return XCTFail("expected insertNotFound, got \(error)")
            }
            XCTAssertEqual(available, ["1: Gain", "2: Channel EQ"])
            XCTAssertFalse(
                available.contains { $0.contains("Parametric EQ") },
                "the stale MCU cell must not leak into the refusal"
            )
        }
    }

    func testNotFoundFallsBackToMCUCellsWhenNoInspectorReadbackExists() {
        // stripInsertNames omitted entirely (nil default) — the only source
        // there ever was before this fix, and still the honest fallback when
        // no inspector shows the strip.
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Cha EQ"), pluginName: "Compressor",
                trackName: "Bas", insertSlot: nil
            )
        ) { error in
            guard case .insertNotFound(_, _, let available) = error as? LogicianError else {
                return XCTFail("expected insertNotFound, got \(error)")
            }
            XCTAssertEqual(available, ["1: Gain", "2: Cha EQ"])
        }
    }

    func testNotFoundFallsBackToMCUCellsWhenTheInspectorReadbackIsEmpty() {
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Cha EQ"), pluginName: "Compressor",
                trackName: "Bas", insertSlot: nil, stripInsertNames: []
            )
        ) { error in
            guard case .insertNotFound(_, _, let available) = error as? LogicianError else {
                return XCTFail("expected insertNotFound, got \(error)")
            }
            XCTAssertEqual(available, ["1: Gain", "2: Cha EQ"])
        }
    }

    // MARK: - resolveRemovalSlot: duplicates

    func testDuplicatesWithoutInsertSlotThrowAmbiguousNamingTheMackieSlots() {
        // The live defect: three Gain inserts, no way to name one.
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Gain", "Gain"), pluginName: "Gain",
                trackName: "Sweeps", insertSlot: nil
            )
        ) { error in
            guard case .insertAmbiguous(let track, let plugin, let slots, let parameter, _)
                = error as? LogicianError else {
                return XCTFail("expected insertAmbiguous, got \(error)")
            }
            XCTAssertEqual(track, "Sweeps")
            XCTAssertEqual(plugin, "Gain")
            XCTAssertEqual(slots, [1, 2, 3], "Mackie physical slots, 1-based")
            XCTAssertEqual(parameter, "insert_slot", "the mouse-free remedy, not insert_index")
        }
    }

    func testInsertSlotPicksAmongDuplicates() throws {
        XCTAssertEqual(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Gain", "Gain"), pluginName: "Gain",
                trackName: "Sweeps", insertSlot: 2
            ),
            1, "insert_slot is 1-based, the return is the 0-based vpot index"
        )
    }

    // MARK: - resolveRemovalSlot: the name proof holds on the insert_slot path

    func testInsertSlotNamingACellThatShowsAnotherPluginIsRefused() {
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Cha EQ", "Gain"), pluginName: "Gain",
                trackName: "Bas", insertSlot: 2
            )
        ) { error in
            guard case .insertMismatch(let slot, let expected, let actual)
                = error as? LogicianError else {
                return XCTFail("expected insertMismatch, got \(error)")
            }
            XCTAssertEqual(slot, 2)
            XCTAssertEqual(expected, "Gain")
            XCTAssertEqual(actual, "Cha EQ")
        }
    }

    func testInsertSlotNamingAnEmptyCellIsRefused() {
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain"), pluginName: "Gain", trackName: "Bas", insertSlot: 5
            )
        ) { error in
            guard case .insertMismatch(_, _, let actual) = error as? LogicianError else {
                return XCTFail("expected insertMismatch, got \(error)")
            }
            XCTAssertEqual(actual, MCULCDStrings.emptySlot)
        }
    }

    func testInsertSlotOutsideTheMackieRangeIsInvalid() {
        for slot in [0, 9, -1] {
            XCTAssertThrowsError(
                try MCUController.resolveRemovalSlot(
                    inserts: row("Gain"), pluginName: "Gain", trackName: "Bas", insertSlot: slot
                )
            ) { error in
                guard case .invalidArguments = error as? LogicianError else {
                    return XCTFail("expected invalidArguments for slot \(slot), got \(error)")
                }
            }
        }
    }

    // MARK: - lcdRowShowsRemoval: the slot readback

    func testRemovingTheLastOccupiedInsertClearsTheSlotInPlace() {
        XCTAssertTrue(MCUController.lcdRowShowsRemoval(
            before: row("Gain", "Cha EQ"), after: row("Gain"), slotIndex: 1
        ))
    }

    func testRemovingAMiddleInsertIsShownByTheCompactedRow() {
        // Logic closes the gap: the later inserts slide up one.
        XCTAssertTrue(MCUController.lcdRowShowsRemoval(
            before: row("Gain", "Gain", "Gain"), after: row("Gain", "Gain"), slotIndex: 1
        ))
    }

    func testAnUnchangedRowOfDuplicatesIsNotMistakenForARemoval() {
        // The trap the compaction model must not fall into: with three Gains,
        // "the slot still shows Gain" is exactly what a failed press looks
        // like, and only the tail's length tells the two apart.
        XCTAssertFalse(MCUController.lcdRowShowsRemoval(
            before: row("Gain", "Gain", "Gain"), after: row("Gain", "Gain", "Gain"), slotIndex: 1
        ))
    }

    func testAnUnchangedRowOfDistinctNamesIsNotMistakenForARemoval() {
        XCTAssertFalse(MCUController.lcdRowShowsRemoval(
            before: row("Gain", "Cha EQ", "Limitr"),
            after: row("Gain", "Cha EQ", "Limitr"), slotIndex: 1
        ))
    }

    func testAReshuffledRowIsNotMistakenForARemoval() {
        XCTAssertFalse(MCUController.lcdRowShowsRemoval(
            before: row("Gain", "Cha EQ", "Limitr"),
            after: row("Gain", "Limitr", "Cha EQ"), slotIndex: 1
        ))
    }

    func testABlankCellAndTheEmptySlotMarkerAreTheSameEmptiness() {
        XCTAssertTrue(MCUController.lcdRowShowsRemoval(
            before: ["Gain", "Cha EQ", "", "", "", "", "", ""],
            after: ["Gain", MCULCDStrings.emptySlot, "", "", "", "", "", ""],
            slotIndex: 1
        ))
    }

    // MARK: - axConfirmsRemoval: the duplicate-aware cross-check

    func testASingleInstanceMustBeGone() {
        XCTAssertTrue(MCUController.axConfirmsRemoval(
            beforeCount: 1, afterNames: ["Channel EQ"], pluginName: "Gain"
        ))
        XCTAssertFalse(MCUController.axConfirmsRemoval(
            beforeCount: 1, afterNames: ["Gain", "Channel EQ"], pluginName: "Gain"
        ))
    }

    func testOneOfSeveralInstancesRemovedIsConfirmedByTheCountDropping() {
        // The live defect's other half: with three Gains, absence is the
        // wrong bar — one fewer is the honest signal.
        XCTAssertTrue(MCUController.axConfirmsRemoval(
            beforeCount: 3, afterNames: ["Gain", "Gain"], pluginName: "Gain"
        ))
        XCTAssertFalse(MCUController.axConfirmsRemoval(
            beforeCount: 3, afterNames: ["Gain", "Gain", "Gain"], pluginName: "Gain"
        ))
    }

    func testAnUnreadableBeforeCountFallsBackToRequiringAbsence() {
        XCTAssertTrue(MCUController.axConfirmsRemoval(
            beforeCount: nil, afterNames: ["Channel EQ"], pluginName: "Gain"
        ))
        XCTAssertFalse(MCUController.axConfirmsRemoval(
            beforeCount: nil, afterNames: ["Gain"], pluginName: "Gain"
        ))
    }

    // MARK: - removalJumpEntries: the undershoot invariant

    /// The invariant the removal's jump lives or dies by. Overshooting `--`
    /// wraps into the far end of a 590+-entry catalog, so the landing must
    /// stay ABOVE the origin for every hint the map can produce — exact, or
    /// too small, which is the only direction it can err.
    func testTheJumpNeverCarriesTheBrowsePastTheBoundary() {
        let margin = MCUController.browseRemovalUndershootEntries
        for trueOrdinal in [1, 2, 5, 35, 120, 331, 590] {
            for travelled in 0...min(trueOrdinal, 12) {
                for shortfall in 0...min(trueOrdinal, 6) {
                    let hint = trueOrdinal - shortfall // a map can only undercount
                    guard let jump = MCUController.removalJumpEntries(
                        cachedOrdinal: hint, entriesTravelled: travelled
                    ) else { continue }
                    let landing = trueOrdinal - travelled - jump
                    XCTAssertGreaterThanOrEqual(
                        landing, margin,
                        "hint \(hint) for ordinal \(trueOrdinal) after \(travelled) travelled"
                            + " landed at \(landing), inside the undershoot margin"
                    )
                }
            }
        }
    }

    func testAnExactHintLandsExactlyTheMarginShortOfTheBoundary() {
        let margin = MCUController.browseRemovalUndershootEntries
        // `Gain` sat at ordinal ~35 on the profiled install, one step travelled.
        let jump = MCUController.removalJumpEntries(cachedOrdinal: 35, entriesTravelled: 1)
        XCTAssertEqual(jump, 35 - 1 - margin)
        XCTAssertEqual(35 - 1 - (jump ?? 0), margin, "the landing, for an exact hint")
    }

    func testNoJumpIsTakenWhenTheBoundaryIsAlreadyInsideTheMargin() {
        let margin = MCUController.browseRemovalUndershootEntries
        XCTAssertNil(MCUController.removalJumpEntries(cachedOrdinal: margin, entriesTravelled: 0))
        XCTAssertNil(MCUController.removalJumpEntries(cachedOrdinal: 1, entriesTravelled: 0))
        XCTAssertNil(MCUController.removalJumpEntries(cachedOrdinal: 40, entriesTravelled: 40))
        XCTAssertNotNil(
            MCUController.removalJumpEntries(cachedOrdinal: margin + 1, entriesTravelled: 0)
        )
    }

    func testTheRemovalUndershootsWhereTheAddAimsStraight() {
        // The asymmetry is deliberate: an add that lands short walks one step
        // forward, a removal that lands past `--` walks the whole catalog.
        XCTAssertGreaterThan(MCUController.browseRemovalUndershootEntries, 0)
        XCTAssertEqual(MCUController.browseJumpUndershootEntries, 0)
    }

    // MARK: - The bound the backward walk promises

    func testTheBackwardWalkIsBoundedInEntriesAndWallClock() {
        // The old bound was 400 MESSAGES, which at the unpaced loop's 15-23%
        // swallow rate reached ~330 entries of a catalog running past 590: a
        // plug-in deeper than that could not be removed at all.
        XCTAssertGreaterThan(MCUController.browseEntryCap, 590)
        XCTAssertGreaterThanOrEqual(MCUController.browseRemovalBudget, 30)
    }

    func testTheBoundaryRefusalNamesTheEntryLimitAndReadsTheTailBack() {
        let refusal = MCUController.removalBoundaryRefusal(
            entriesSeen: MCUController.browseEntryCap,
            tail: ["Silver Gate", "Modulation Delay", "EnVerb"],
            jumped: false
        )
        XCTAssertTrue(refusal.contains("\(MCUController.browseEntryCap) catalog entries"))
        XCTAssertTrue(refusal.contains("\(MCUController.browseEntryCap)-entry limit"))
        XCTAssertTrue(refusal.contains("Silver Gate, Modulation Delay, EnVerb"))
        XCTAssertTrue(refusal.contains("Nothing was written"))
        XCTAssertFalse(refusal.contains("steps"), "the old bound counted messages and said 'steps'")
    }

    func testTheBoundaryRefusalNamesTheSearchBudgetWhenThatIsWhatStoppedIt() {
        let refusal = MCUController.removalBoundaryRefusal(
            entriesSeen: 120, tail: ["Gain"], jumped: false
        )
        XCTAssertTrue(refusal.contains("120 catalog entries"))
        XCTAssertTrue(refusal.contains("\(Int(MCUController.browseRemovalBudget)) s search budget"))
        XCTAssertFalse(refusal.contains("-entry limit"))
    }

    func testAFailedJumpSaysTheCachedPositionWasDiscarded() {
        let refusal = MCUController.removalBoundaryRefusal(
            entriesSeen: 400, tail: [], jumped: true
        )
        XCTAssertTrue(refusal.contains("discarded"))
        XCTAssertFalse(
            MCUController.removalBoundaryRefusal(entriesSeen: 400, tail: [], jumped: false)
                .contains("discarded")
        )
    }

    func testTheRefusalCountsOneEntrySingular() {
        XCTAssertTrue(
            MCUController.removalBoundaryRefusal(entriesSeen: 1, tail: [], jumped: false)
                .contains("1 catalog entry")
        )
    }

    // MARK: - The drift refusal reports the browse cell, not a pan row

    /// The message's whole job is to say what the browse drifted to, and it
    /// used to read the LCD after `exitToPan()` had already run — so it
    /// reported '0', strip 1's PAN value, live on 2026-09-02. Taking the cell
    /// as a parameter is what makes the ordering impossible to get wrong.
    func testTheDriftRefusalReportsTheCellItWasGiven() {
        let refusal = MCUController.removalDriftActual(driftedTo: "Silver Gate (s/s)")
        XCTAssertTrue(refusal.contains("'Silver Gate (s/s)'"))
        XCTAssertTrue(
            refusal.contains("before the surface was restored"),
            "the message says which view the cell was read on"
        )
        XCTAssertTrue(refusal.contains("aborted without removing"))
    }

    func testTheDriftRefusalSaysSoWhenTheCellCouldNotBeReadAtAll() {
        XCTAssertTrue(MCUController.removalDriftActual(driftedTo: nil).contains("'?'"))
    }
}
