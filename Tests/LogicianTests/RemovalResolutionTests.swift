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

    // MARK: - resolveRemovalSlot: duplicates

    func testDuplicatesWithoutInsertSlotThrowAmbiguousNamingTheMackieSlots() {
        // The live defect: three Gain inserts, no way to name one.
        XCTAssertThrowsError(
            try MCUController.resolveRemovalSlot(
                inserts: row("Gain", "Gain", "Gain"), pluginName: "Gain",
                trackName: "Sweeps", insertSlot: nil
            )
        ) { error in
            guard case .insertAmbiguous(let track, let plugin, let slots, let parameter)
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
}
