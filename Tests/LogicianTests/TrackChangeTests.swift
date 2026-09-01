import XCTest
@testable import Logician

/// What `logic_create_track`, `logic_duplicate_track` and `logic_delete_track`
/// may claim, decided from two track listings.
///
/// The path shipped with no unit test at all, and the profile of 2026-09-01
/// found two defects in exactly the places a live run cannot easily reach: a
/// create whose new row is off-screen was reported as a failure, and the
/// result never said which track it had made. Both are decisions about two
/// arrays, so they are pinned here.
final class TrackChangeTests: XCTestCase {

    private func rows(_ names: [String], selected: String? = nil) -> [TrackChange.Row] {
        names.enumerated().map { index, name in
            TrackChange.Row(
                number: index + 1,
                name: name,
                selected: selected.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false
            )
        }
    }

    // MARK: Reading the rows out of a listing

    func testRowsDropsEntriesWithNoUsableName() {
        let parsed = TrackChange.rows([
            ["track_number": 1, "track_name": "Lofi Pad", "selected": true],
            ["track_number": 2, "track_name": ""],
            ["track_number": 3],
            ["track_number": 4, "track_name": "Audio 9", "selected": false]
        ])
        XCTAssertEqual(parsed.map(\.name), ["Lofi Pad", "Audio 9"])
        XCTAssertEqual(parsed.map(\.selected), [true, false])
    }

    // MARK: A track appeared

    func testCountRisingIsAnAppearance() {
        XCTAssertTrue(
            TrackChange.trackAppeared(before: rows(["A", "B"]), after: rows(["A", "B", "Audio 1"]))
        )
    }

    func testUnchangedListingIsNotAnAppearance() {
        XCTAssertFalse(
            TrackChange.trackAppeared(before: rows(["A", "B"]), after: rows(["A", "B"]))
        )
    }

    /// The case the count cannot see, and the reason `handleCreateTrack` no
    /// longer counts: Logic renders a WINDOW onto the track list, so inserting
    /// a row can push another out of the viewport. Nineteen rows before,
    /// nineteen after, and a track was plainly created.
    func testNewNameWithAnUnchangedCountIsAnAppearance() {
        XCTAssertTrue(
            TrackChange.trackAppeared(
                before: rows(["A", "B", "C"]),
                after: rows(["B", "C", "Audio 1"])
            )
        )
    }

    /// The listing merely SCROLLED — same rows, one off each end. Nothing was
    /// created, and a scroll must not be read as one.
    func testAScrollThatAddsNoNameIsNotAnAppearance() {
        XCTAssertFalse(
            TrackChange.trackAppeared(
                before: rows(["A", "B", "C"]),
                after: rows(["B", "C"])
            )
        )
    }

    /// A second row with a name the project already used — a set difference
    /// would call this "nothing new".
    func testASecondRowSharingANameIsAnAppearance() {
        XCTAssertEqual(
            TrackChange.addedNames(before: rows(["Audio 9"]), after: rows(["Audio 9", "Audio 9"])),
            ["Audio 9"]
        )
        XCTAssertTrue(
            TrackChange.trackAppeared(
                before: rows(["Audio 9"]), after: rows(["Audio 9", "Audio 9"])
            )
        )
    }

    func testAnUnreadableListingIsNeverAnAppearance() {
        XCTAssertFalse(TrackChange.trackAppeared(before: rows(["A", "B"]), after: []))
    }

    // MARK: Which row is the new one

    func testCreatedRowIsTheSelectedRowLogicJustMade() {
        let row = TrackChange.createdRow(
            before: rows(["Lofi Pad", "Audio 8"]),
            after: rows(["Lofi Pad", "Audio 8", "Audio 9"], selected: "Audio 9")
        )
        XCTAssertEqual(row?.name, "Audio 9")
        XCTAssertEqual(row?.number, 3)
    }

    /// The selection is only the primary answer while it AGREES with the named
    /// difference — a selection that moved elsewhere is not evidence about
    /// what was created, and the single added name is.
    func testCreatedRowPrefersTheAddedNameOverASelectionThatMovedAway() {
        let row = TrackChange.createdRow(
            before: rows(["Lofi Pad", "Audio 8"]),
            after: rows(["Lofi Pad", "Audio 8", "Audio 9"], selected: "Lofi Pad")
        )
        XCTAssertEqual(row?.name, "Audio 9")
    }

    func testCreatedRowFallsBackToTheOneAddedNameWhenNothingIsSelected() {
        let row = TrackChange.createdRow(
            before: rows(["Lofi Pad"]),
            after: rows(["Lofi Pad", "Inst 1"])
        )
        XCTAssertEqual(row?.name, "Inst 1")
    }

    /// Two rows appeared and none is selected: naming one would be a guess,
    /// and the guess would go straight into `logic_load_instrument`.
    func testCreatedRowIsNilWhenSeveralRowsAppearedAndNothingIsSelected() {
        XCTAssertNil(
            TrackChange.createdRow(
                before: rows(["A"]),
                after: rows(["A", "Audio 1", "Audio 2"])
            )
        )
    }

    /// The added name is carried by two rows and neither is selected — which
    /// of them is new is not decidable from here.
    func testCreatedRowIsNilWhenTheAddedNameIsAmbiguous() {
        XCTAssertNil(
            TrackChange.createdRow(
                before: rows(["Audio 9"]),
                after: rows(["Audio 9", "Audio 9"])
            )
        )
    }

    /// …but WITH a selection, the same listing is decidable: Logic selects the
    /// track it just made.
    func testCreatedRowResolvesADuplicateNameThroughTheSelection() {
        let after = [
            TrackChange.Row(number: 1, name: "Audio 9", selected: false),
            TrackChange.Row(number: 2, name: "Audio 9", selected: true)
        ]
        XCTAssertEqual(TrackChange.createdRow(before: rows(["Audio 9"]), after: after)?.number, 2)
    }

    func testCreatedRowIsNilWhenNothingWasAdded() {
        XCTAssertNil(
            TrackChange.createdRow(
                before: rows(["A", "B"]),
                after: rows(["A", "B"], selected: "B")
            )
        )
    }

    // MARK: What an unseen create may say

    /// D2. A listing that has proved itself incomplete cannot say "nothing
    /// happened" — the agent's next move on that answer is to fire the command
    /// again, and then there are two tracks.
    func testAPartialListingThatDidNotMoveMeansNotVisibleNotNothing() {
        XCTAssertEqual(TrackChange.unseenVerdict(partial: true), .notVisible)
    }

    func testAnUnrefutedListingThatDidNotMoveMeansNothingHappened() {
        XCTAssertEqual(TrackChange.unseenVerdict(partial: false), .nothing)
    }

    // MARK: A row went away

    func testRowRemovedWhenTheNamedRowIsGoneAndTheTotalDropped() {
        XCTAssertTrue(
            TrackChange.rowRemoved(
                before: rows(["A", "Doomed", "B"]),
                after: rows(["A", "B"]),
                name: "Doomed"
            )
        )
    }

    func testRowRemovedIsCaseInsensitiveOnTheName() {
        XCTAssertTrue(
            TrackChange.rowRemoved(
                before: rows(["A", "Doomed"]),
                after: rows(["A"]),
                name: "doomed"
            )
        )
    }

    /// Occurrence count, not absence: one of two rows sharing a name went,
    /// and the other is still there.
    func testRowRemovedCountsOccurrencesRatherThanAbsence() {
        XCTAssertTrue(
            TrackChange.rowRemoved(
                before: rows(["Audio 9", "Audio 9", "B"]),
                after: rows(["Audio 9", "B"]),
                name: "Audio 9"
            )
        )
    }

    func testRowStillListedIsNotARemoval() {
        XCTAssertFalse(
            TrackChange.rowRemoved(
                before: rows(["A", "Doomed"]),
                after: rows(["A", "Doomed"]),
                name: "Doomed"
            )
        )
    }

    /// The total dropped but a DIFFERENT row went — the listing scrolled, or
    /// the wrong track was deleted. Either way this is not proof of the
    /// requested deletion.
    func testADroppedTotalWithTheNamedRowStillThereIsNotARemoval() {
        XCTAssertFalse(
            TrackChange.rowRemoved(
                before: rows(["A", "Doomed", "B"]),
                after: rows(["Doomed", "B"]),
                name: "Doomed"
            )
        )
    }

    func testAnUnreadableListingIsNeverARemoval() {
        XCTAssertFalse(
            TrackChange.rowRemoved(before: rows(["A", "Doomed"]), after: [], name: "Doomed")
        )
    }

    // MARK: The polls look before they sleep

    /// The whole point of the 2026-09-01 fix: neither poll may pay a fixed
    /// sleep before its first look, and the retry tick has to be small enough
    /// that a genuine miss costs a tick rather than a tenth of a second.
    func testPollIntervalsAreTicksNotSleeps() {
        XCTAssertLessThanOrEqual(TrackChange.createPollInterval, 0.05)
        XCTAssertLessThanOrEqual(TrackChange.deletePollInterval, 0.05)
        XCTAssertGreaterThan(TrackChange.createPollDeadline, 1.0)
        XCTAssertGreaterThan(TrackChange.deletePollDeadline, 1.0)
    }
}
