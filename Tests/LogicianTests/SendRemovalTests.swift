import XCTest
@testable import Logician

/// The two pure halves of `logic_remove_send`: which send an address means
/// against the list that was just read, and whether a readback proves the
/// removal happened — exactly the removal and nothing else.
///
/// Both are pure on purpose. The addressing contract (refuse a mismatch,
/// no-op an absence, refuse an ambiguity) and the readback equation (one send
/// fewer, same destinations minus one occurrence) are where a wrong branch
/// removes a send nobody asked for or reports a half-truth as verified, and
/// neither needs a surface to be pinned.
final class SendRemovalTests: XCTestCase {

    /// The shape `logic_mcu_sends` reads off the live surface: slot numbers
    /// as the Mackie send view paints them, destinations as 6-character LCD
    /// cells.
    private let twoSends: [(slot: Int, destination: String)] = [
        (1, "Bus 1"), (2, "Bus 12")
    ]

    private func code(_ error: Error) -> String? {
        (error as? LogicianError)?.code
    }

    // MARK: - Resolution: addressing by slot

    func testASlotAloneRemovesWhateverItHolds() throws {
        XCTAssertEqual(
            try MCUController.resolveSendRemoval(sendNumber: 2, destination: nil, sends: twoSends),
            .remove(slot: 2, destination: "Bus 12")
        )
    }

    func testAnEmptySlotAloneIsAVerifiedNoOp() throws {
        guard case .alreadyRemoved(let detail) = try MCUController.resolveSendRemoval(
            sendNumber: 5, destination: nil, sends: twoSends
        ) else { return XCTFail("expected alreadyRemoved") }
        XCTAssertTrue(detail.contains("slot 5 is empty"), detail)
        // The list the caller should re-plan from is in the detail.
        XCTAssertTrue(detail.contains("Bus 12"), detail)
    }

    func testASlotOutsideOneToEightIsRefusedBeforeAnythingIsRead() {
        for slot in [0, 9, -1] {
            XCTAssertThrowsError(try MCUController.resolveSendRemoval(
                sendNumber: slot, destination: nil, sends: twoSends
            )) { XCTAssertEqual(code($0), "invalid_arguments") }
        }
    }

    // MARK: - Resolution: addressing by destination

    func testADestinationAloneFindsItsSlot() throws {
        XCTAssertEqual(
            try MCUController.resolveSendRemoval(
                sendNumber: nil, destination: "bus 12", sends: twoSends
            ),
            .remove(slot: 2, destination: "Bus 12")
        )
    }

    func testADestinationNobodySendsToIsAVerifiedNoOp() throws {
        guard case .alreadyRemoved(let detail) = try MCUController.resolveSendRemoval(
            sendNumber: nil, destination: "Bus 3", sends: twoSends
        ) else { return XCTFail("expected alreadyRemoved") }
        XCTAssertTrue(detail.contains("no send goes to 'Bus 3'"), detail)
    }

    /// Two sends to the same bus is legal in Logic, and "the send to Bus 1"
    /// then names two things. Guessing removes a level somebody set.
    func testASharedDestinationAddressedByNameAloneIsRefused() {
        let doubled: [(slot: Int, destination: String)] = [
            (1, "Bus 1"), (2, "Bus 1"), (3, "Bus 12")
        ]
        XCTAssertThrowsError(try MCUController.resolveSendRemoval(
            sendNumber: nil, destination: "Bus 1", sends: doubled
        )) { error in
            XCTAssertEqual(code(error), "not_exposed")
            XCTAssertTrue("\(error.localizedDescription)".contains("1 and 2"),
                          error.localizedDescription)
        }
    }

    // MARK: - Resolution: addressing by both, which is the compare-and-set

    func testSlotAndDestinationTogetherMustAgree() throws {
        XCTAssertEqual(
            try MCUController.resolveSendRemoval(
                sendNumber: 1, destination: "Bus 1", sends: twoSends
            ),
            .remove(slot: 1, destination: "Bus 1")
        )
    }

    /// The refusal the tool exists to make: the slot holds something OTHER
    /// than what the caller believes. Removing it anyway would take out a
    /// send nothing asked for.
    func testASlotHoldingADifferentDestinationIsRefusedNotRemoved() {
        XCTAssertThrowsError(try MCUController.resolveSendRemoval(
            sendNumber: 1, destination: "Bus 12", sends: twoSends
        )) { error in
            XCTAssertEqual(code(error), "precondition_failed")
            XCTAssertTrue(error.localizedDescription.contains("Bus 1"), error.localizedDescription)
        }
    }

    /// An empty slot plus a destination that lives in ANOTHER slot is a stale
    /// numbering (sends renumber when one is removed) — refused with the real
    /// slot named, because both a removal and an "already removed" would be
    /// wrong about something.
    func testAStaleSlotNumberIsRefusedWithTheRealSlotNamed() {
        XCTAssertThrowsError(try MCUController.resolveSendRemoval(
            sendNumber: 5, destination: "Bus 12", sends: twoSends
        )) { error in
            XCTAssertEqual(code(error), "precondition_failed")
            XCTAssertTrue(error.localizedDescription.contains("send 2"), error.localizedDescription)
        }
    }

    func testAnEmptySlotAndAnAbsentDestinationIsAVerifiedNoOp() throws {
        guard case .alreadyRemoved = try MCUController.resolveSendRemoval(
            sendNumber: 5, destination: "Bus 3", sends: twoSends
        ) else { return XCTFail("expected alreadyRemoved") }
    }

    func testNoAddressAtAllIsRefused() {
        XCTAssertThrowsError(try MCUController.resolveSendRemoval(
            sendNumber: nil, destination: nil, sends: twoSends
        )) { XCTAssertEqual(code($0), "invalid_arguments") }
    }

    // MARK: - The readback verdict

    func testASlotLeftEmptyVerifiesWithoutRenumbering() {
        let verdict = MCUController.sendRemovalVerdict(
            before: twoSends, after: [(1, "Bus 1")],
            removedSlot: 2, removedDestination: "Bus 12"
        )
        XCTAssertTrue(verdict.verified)
        XCTAssertFalse(verdict.renumbered)
    }

    /// Logic's other possible after-state: the sends below the removed one
    /// compact upward, so the removed slot is re-occupied by its former
    /// neighbour. Verified — and flagged, because every slot number the
    /// caller holds is now stale.
    func testACompactedListVerifiesAndReportsTheRenumbering() {
        let verdict = MCUController.sendRemovalVerdict(
            before: twoSends, after: [(1, "Bus 12")],
            removedSlot: 1, removedDestination: "Bus 1"
        )
        XCTAssertTrue(verdict.verified)
        XCTAssertTrue(verdict.renumbered)
        XCTAssertTrue(verdict.detail.contains("stale"), verdict.detail)
    }

    func testRemovingTheLastSendVerifiesAgainstAnEmptyList() {
        let verdict = MCUController.sendRemovalVerdict(
            before: [(1, "Bus 1")], after: [],
            removedSlot: 1, removedDestination: "Bus 1"
        )
        XCTAssertTrue(verdict.verified)
        XCTAssertFalse(verdict.renumbered)
    }

    func testAnUnchangedListIsNotVerified() {
        let verdict = MCUController.sendRemovalVerdict(
            before: twoSends, after: twoSends,
            removedSlot: 2, removedDestination: "Bus 12"
        )
        XCTAssertFalse(verdict.verified)
        XCTAssertTrue(verdict.detail.contains("2 sends"), verdict.detail)
    }

    /// The count can come out right while the WRONG send went: one fewer
    /// send, but the destination that disappeared is not the one confirmed.
    /// A slot peek would pass this; the set equation refuses it.
    func testTheWrongSendGoingIsNotVerifiedEvenWithTheRightCount() {
        let verdict = MCUController.sendRemovalVerdict(
            before: twoSends, after: [(1, "Bus 12")],
            removedSlot: 2, removedDestination: "Bus 12"
        )
        XCTAssertFalse(verdict.verified)
        XCTAssertTrue(verdict.detail.contains("more than the one removal"), verdict.detail)
    }

    /// A removal that dragged a neighbour along shows the right delta at the
    /// removed slot and a wrong total — the count check catches it first.
    func testARemovalThatTookANeighbourAlongIsNotVerified() {
        let verdict = MCUController.sendRemovalVerdict(
            before: [(1, "Bus 1"), (2, "Bus 12"), (3, "Bus 3")], after: [(1, "Bus 3")],
            removedSlot: 2, removedDestination: "Bus 12"
        )
        XCTAssertFalse(verdict.verified)
    }

    /// Duplicate destinations: removing one of two sends to the same bus is
    /// verified by the set equation (one occurrence gone), whichever twin
    /// Logic compacted over the slot.
    func testRemovingOneOfTwoIdenticalDestinationsVerifies() {
        let verdict = MCUController.sendRemovalVerdict(
            before: [(1, "Bus 1"), (2, "Bus 1")], after: [(1, "Bus 1")],
            removedSlot: 1, removedDestination: "Bus 1"
        )
        XCTAssertTrue(verdict.verified)
        XCTAssertTrue(verdict.renumbered)
    }

    // MARK: - The list shape the surface hands the pure halves

    func testSendListEntriesKeepSlotAndDestinationAndDropMalformedRows() {
        let entries = MCUController.sendListEntries([
            ["send": 1, "destination": "Bus 1", "level": "-12.0dB"],
            ["send": 2],
            ["destination": "Bus 3"]
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.slot, 1)
        XCTAssertEqual(entries.first?.destination, "Bus 1")
    }

    /// The matcher takes the exact spelling case-insensitively and the LCD
    /// abbreviation of a longer name — the send list's values are 6-character
    /// cells, so 'Stereo Out' never arrives whole.
    func testDestinationMatchingIsCaseInsensitiveAndLCDAware() {
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "bus 12", listed: "Bus 12"))
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "Bus 100", listed: "Bus100"))
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "Stereo Out", listed: "StOut"))
    }

    /// The subsequence matcher the track tools use would let 'Bus 1' answer
    /// for 'Bus 12' — a wrong send removed on a trailing digit. A name short
    /// enough to fit its LCD cell whole is shown whole, so for those only the
    /// exact spelling counts.
    func testANameThatFitsTheCellMustMatchExactly() {
        XCTAssertFalse(MCUController.sendDestinationMatches(requested: "Bus 1", listed: "Bus 12"))
        XCTAssertFalse(MCUController.sendDestinationMatches(requested: "Bus 12", listed: "Bus 1"))
        XCTAssertFalse(MCUController.sendDestinationMatches(requested: "Bus 1", listed: "Bus 10"))
    }
}
