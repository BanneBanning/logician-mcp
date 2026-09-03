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

    /// The rows `selectTrack` hands over come straight off the AX walk, so the
    /// drop-rule for an unusable name has to hold on that side too.
    func testRowsFromParsedHeadersDropsEntriesWithNoUsableName() {
        let parsed = TrackChange.rows(headers: [
            (number: 1, name: "Crash", selected: false),
            (number: 2, name: "", selected: false),
            (number: 3, name: "Audio 9", selected: true)
        ])
        XCTAssertEqual(parsed, [
            TrackChange.Row(number: 1, name: "Crash", selected: false),
            TrackChange.Row(number: 3, name: "Audio 9", selected: true)
        ])
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

    // MARK: Which row is the COPY

    /// Live 2026-09-01: `Crash` (track 26) duplicated to a second `Crash` at
    /// 27, selected, and `logic_delete_track {track_name: "Crash"}` was then
    /// refused as ambiguous. The number is the whole answer, and only the
    /// selection carries it.
    func testDuplicateKeepingTheSourceNameIsFoundByTheSelection() {
        let before = [
            TrackChange.Row(number: 25, name: "808", selected: false),
            TrackChange.Row(number: 26, name: "Crash", selected: true),
            TrackChange.Row(number: 27, name: "Vinyl", selected: false)
        ]
        let after = [
            TrackChange.Row(number: 25, name: "808", selected: false),
            TrackChange.Row(number: 26, name: "Crash", selected: false),
            TrackChange.Row(number: 27, name: "Crash", selected: true),
            TrackChange.Row(number: 28, name: "Vinyl", selected: false)
        ]
        XCTAssertTrue(TrackChange.trackAppeared(before: before, after: after))
        let copy = TrackChange.createdRow(before: before, after: after)
        XCTAssertEqual(copy?.number, 27)
        XCTAssertEqual(copy?.name, "Crash")
    }

    /// Live 2026-09-01: `Audio 9` duplicated to `Audio 10`. The caller's own
    /// `track_name` now addresses a DIFFERENT track, so a result that echoed
    /// it back would be worse than silence.
    func testDuplicateOfAnAutoNamedTrackIsFoundUnderLogicsNewName() {
        let before = [
            TrackChange.Row(number: 28, name: "Audio 8", selected: false),
            TrackChange.Row(number: 29, name: "Audio 9", selected: true)
        ]
        let after = [
            TrackChange.Row(number: 28, name: "Audio 8", selected: false),
            TrackChange.Row(number: 29, name: "Audio 9", selected: false),
            TrackChange.Row(number: 30, name: "Audio 10", selected: true)
        ]
        let copy = TrackChange.createdRow(before: before, after: after)
        XCTAssertEqual(copy?.number, 30)
        XCTAssertEqual(copy?.name, "Audio 10")
    }

    /// A duplicate whose row is off-screen: the visible count did not rise and
    /// no name is new, but the rows that ARE rendered plainly moved — Logic
    /// renumbered them around an insertion this listing cannot show. Reporting
    /// "failed" invites a second call, and a second copy carries a second set
    /// of the source's regions.
    func testACopyOffScreenIsNotVisibleRatherThanFailed() {
        let before = [
            TrackChange.Row(number: 20, name: "Kick", selected: false),
            TrackChange.Row(number: 21, name: "Snare", selected: false),
            TrackChange.Row(number: 22, name: "Crash", selected: false)
        ]
        // The copy landed above the rendered window: every number shifted by
        // one and the row that was 22 fell off the bottom.
        let after = [
            TrackChange.Row(number: 21, name: "Kick", selected: false),
            TrackChange.Row(number: 22, name: "Snare", selected: false),
            TrackChange.Row(number: 23, name: "Crash", selected: false)
        ]
        XCTAssertFalse(TrackChange.trackAppeared(before: before, after: after))
        XCTAssertEqual(
            TrackChange.unseenVerdict(partial: true, before: before, after: after), .notVisible
        )
    }

    // MARK: What an unseen create may say

    /// THE REGRESSION THIS FILE NOW EXISTS FOR. Observed live 2026-09-02:
    /// `logic_duplicate_track {track_name: "Drums", track_number: 5}` came
    /// back `state: "duplicated_not_visible"` in 4 488 ms while the listing
    /// before and after was byte-identical — 19 rows, `Fill` still at 6,
    /// nothing renumbered. `partial` is true on every call against that
    /// project, and `partial` alone used to decide this, so a key command that
    /// fired into the void was reported as a copy that might be off-screen.
    /// A census that did not move by one character is not that case.
    func testAnUnmovedRenderedCensusIsNeverNotVisible() {
        let before = rows(["Kick", "Drums", "Fill", "Bass"])
        let after = rows(["Kick", "Drums", "Fill", "Bass"])
        XCTAssertFalse(TrackChange.trackAppeared(before: before, after: after))
        XCTAssertEqual(
            TrackChange.unseenVerdict(partial: true, before: before, after: after), .unchanged
        )
    }

    func testAnUnrefutedListingThatDidNotMoveMeansNothingHappened() {
        let unmoved = rows(["A", "B"])
        XCTAssertEqual(
            TrackChange.unseenVerdict(partial: false, before: unmoved, after: unmoved), .nothing
        )
    }

    /// A row going AWAY is not an appearance, but it is movement: something
    /// happened to the rendered window and this plane cannot say what, so the
    /// cautious verdict is the right one.
    func testACensusThatLostARowIsNotVisibleRatherThanUnchanged() {
        XCTAssertEqual(
            TrackChange.unseenVerdict(
                partial: true, before: rows(["A", "B", "C"]), after: rows(["A", "B"])
            ),
            .notVisible
        )
    }

    // MARK: Did the rendered census move at all

    func testTheSelectionMovingIsNotTheCensusMoving() {
        // Both tools that ask this move the selection themselves — a duplicate
        // selects the copy, and `selectTrack` selects the source before the
        // key command is fired — so a differing `selected` flag is the tool's
        // own footprint and never evidence that a row appeared.
        XCTAssertFalse(
            TrackChange.censusMoved(
                before: rows(["Kick", "Drums", "Fill"], selected: "Kick"),
                after: rows(["Kick", "Drums", "Fill"], selected: "Drums")
            )
        )
    }

    func testRenumberingIsCensusMovementEvenWhenTheNamesAreTheSame() {
        let before = [TrackChange.Row(number: 6, name: "Fill", selected: false)]
        let after = [TrackChange.Row(number: 7, name: "Fill", selected: false)]
        XCTAssertTrue(TrackChange.censusMoved(before: before, after: after))
    }

    func testARenamedRowAtTheSameNumberIsCensusMovement() {
        let before = [TrackChange.Row(number: 6, name: "Fill", selected: false)]
        let after = [TrackChange.Row(number: 6, name: "Fill 2", selected: false)]
        XCTAssertTrue(TrackChange.censusMoved(before: before, after: after))
    }

    func testADifferentRowCountIsAlwaysCensusMovement() {
        XCTAssertTrue(
            TrackChange.censusMoved(before: rows(["A"]), after: rows(["A", "B"]))
        )
    }

    // MARK: Proving the copy was NOT made

    /// The insertion point is known: the copy lands directly below its source
    /// and renumbers every row under it (10 of 10 runs, 2026-09-01). So rows
    /// below the source that still carry their old numbers are evidence of
    /// absence — the one claim a row COUNT can never make on a partial list.
    func testRowsBelowTheSourceKeepingTheirNumbersRefuteTheInsertion() {
        let census = rows(["Kick", "Drums", "Fill", "Bass"])
        XCTAssertTrue(
            TrackChange.insertionRefutedBelow(before: census, after: census, number: 2)
        )
    }

    /// The same test against a duplicate that really happened: `Fill` 3 → 4.
    func testARealInsertionIsNotRefuted() {
        let before = rows(["Kick", "Drums", "Fill", "Bass"])
        let after = [
            TrackChange.Row(number: 1, name: "Kick", selected: false),
            TrackChange.Row(number: 2, name: "Drums", selected: false),
            TrackChange.Row(number: 3, name: "Drums", selected: true),
            TrackChange.Row(number: 4, name: "Fill", selected: false),
            TrackChange.Row(number: 5, name: "Bass", selected: false)
        ]
        XCTAssertFalse(
            TrackChange.insertionRefutedBelow(before: before, after: after, number: 2)
        )
    }

    /// Nothing rendered below the source: the copy would have landed outside
    /// the rendered rows, so this plane refutes nothing and must not pretend
    /// to. The result then keeps its "scroll and re-read" warning.
    func testNoRenderedRowBelowTheSourceRefutesNothing() {
        let census = rows(["Kick", "Drums"])
        XCTAssertFalse(
            TrackChange.insertionRefutedBelow(before: census, after: census, number: 2)
        )
    }

    /// The live shape of 2026-09-02, end to end: `Drums` at 5 with `Fill` at 6
    /// still at 6 afterwards. Unchanged AND refuted — the result may say "no
    /// copy was made" outright.
    func testTheDrumsReproIsUnchangedAndRefuted() {
        let census = [
            TrackChange.Row(number: 4, name: "Kick", selected: false),
            TrackChange.Row(number: 5, name: "Drums", selected: true),
            TrackChange.Row(number: 6, name: "Fill", selected: false),
            TrackChange.Row(number: 7, name: "Bass", selected: false)
        ]
        XCTAssertEqual(
            TrackChange.unseenVerdict(partial: true, before: census, after: census), .unchanged
        )
        XCTAssertTrue(
            TrackChange.insertionRefutedBelow(before: census, after: census, number: 5)
        )
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

    // MARK: Renaming

    /// The shipped check was *"does some visible row carry `new_name`,
    /// case-insensitively"*, and both of these measured calls satisfied it
    /// without any evidence of a rename (2026-09-02 profile, D3). The row is
    /// addressed by NUMBER now, so a name that was already there proves
    /// nothing about the row that was asked for.
    func testRenameIsProvenOnTheRowThatWasAddressed() {
        let after = rows(["Lofi Pad", "Inst 2", "Drums"])
        XCTAssertTrue(TrackChange.renameLanded(after: after, number: 2, to: "Inst 2"))
        XCTAssertFalse(TrackChange.renameLanded(after: after, number: 3, to: "Inst 2"))
    }

    /// The operation whose success was unverifiable: `resolveTrack` compares
    /// names case-SENSITIVELY, so `{Inst 2 → INST 2}` is a real rename whose
    /// result must be addressed by the new case — and the old check compared
    /// case-insensitively, so the pre-existing name satisfied it.
    func testACaseOnlyRenameIsNotAlreadyLanded() {
        XCTAssertFalse(
            TrackChange.renameLanded(after: rows(["Inst 2", "Drums"]), number: 1, to: "INST 2")
        )
        XCTAssertTrue(
            TrackChange.renameLanded(after: rows(["INST 2", "Drums"]), number: 1, to: "INST 2")
        )
    }

    /// Two rows sharing a name is the state `logic_duplicate_track`
    /// manufactures, and renaming one of them is the way out. A name-set
    /// verdict cannot see that rename at all; the by-number one does.
    func testRenamingOneOfTwoSameNamedRowsIsProvable() {
        XCTAssertTrue(
            TrackChange.renameLanded(
                after: rows(["Crash", "Crash Copy", "B"]), number: 2, to: "Crash Copy"
            )
        )
    }

    func testARowThatDidNotChangeIsUnchangedNotUnseen() {
        XCTAssertEqual(
            TrackChange.renameVerdict(
                after: rows(["Inst 2", "Drums"]), number: 1, to: "Fp1", partial: true
            ),
            .unchanged
        )
    }

    /// The mirror image of `logic_create_track`'s D2, and the reason this path
    /// may not throw: a rename of a scrolled-out row used to come back
    /// `verification_failed, restored: false` about a rename that had in fact
    /// landed — and the caller's natural retry is then addressed to a name
    /// that no longer exists.
    func testARowThatIsNotRenderedOnAPartialListingIsNotVisible() {
        XCTAssertEqual(
            TrackChange.renameVerdict(
                after: rows(["Inst 2", "Drums"]), number: 14, to: "Fp1", partial: true
            ),
            .notVisible
        )
    }

    /// A complete listing that does not hold the row at all is not "not
    /// visible" — there is nothing left for the scroll advice to be about.
    func testARowMissingFromACompleteListingIsUnchanged() {
        XCTAssertEqual(
            TrackChange.renameVerdict(
                after: rows(["Inst 2", "Drums"]), number: 14, to: "Fp1", partial: false
            ),
            .unchanged
        )
    }

    /// The tool must not manufacture the pair `logic_duplicate_track` leaves
    /// behind and rename is the only way out of.
    func testANameAnotherRowCarriesIsACollision() {
        let before = rows(["Lofi Pad", "Inst 2", "Drums"])
        XCTAssertEqual(
            TrackChange.nameCollision(rows: before, renaming: 2, to: "Drums")?.number, 3
        )
    }

    /// The row being renamed is never its own collision — that is the
    /// `already_named` no-op, not an unaddressable pair.
    func testTheRowBeingRenamedIsNotItsOwnCollision() {
        XCTAssertNil(
            TrackChange.nameCollision(
                rows: rows(["Lofi Pad", "Inst 2"]), renaming: 2, to: "Inst 2"
            )
        )
    }

    /// Case-sensitively, like `TrackRowAddressing.resolve`: `Drums` and
    /// `DRUMS` are two rows a caller can still tell apart by name.
    func testACaseDifferenceIsNotACollision() {
        XCTAssertNil(
            TrackChange.nameCollision(
                rows: rows(["Lofi Pad", "Inst 2", "Drums"]), renaming: 2, to: "DRUMS"
            )
        )
    }

    func testTheRenamedRowIsTheVerdict() {
        XCTAssertEqual(
            TrackChange.renameVerdict(
                after: rows(["Inst 2", "Fp1"]), number: 2, to: "Fp1", partial: true
            ),
            .renamed
        )
    }

    // MARK: The polls look before they sleep

    /// The whole point of the 2026-09-01 fix: neither poll may pay a fixed
    /// sleep before its first look, and the retry tick has to be small enough
    /// that a genuine miss costs a tick rather than a tenth of a second.
    func testPollIntervalsAreTicksNotSleeps() {
        XCTAssertLessThanOrEqual(TrackChange.createPollInterval, 0.05)
        XCTAssertLessThanOrEqual(TrackChange.duplicatePollInterval, 0.05)
        XCTAssertLessThanOrEqual(TrackChange.deletePollInterval, 0.05)
        XCTAssertLessThanOrEqual(TrackChange.renamePollInterval, 0.05)
        XCTAssertLessThanOrEqual(TrackChange.renameEditorInterval, 0.05)
        XCTAssertGreaterThan(TrackChange.createPollDeadline, 1.0)
        XCTAssertGreaterThan(TrackChange.duplicatePollDeadline, 1.0)
        XCTAssertGreaterThan(TrackChange.deletePollDeadline, 1.0)
        XCTAssertGreaterThan(TrackChange.renamePollDeadline, 1.0)
        // The editor loop's old budget was 15 × 0.2 s; the deadline keeps that
        // patience without charging any of it up front.
        XCTAssertGreaterThanOrEqual(TrackChange.renameEditorDeadline, 3.0)
    }
}
