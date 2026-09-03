import XCTest
@testable import Logician

/// What `logic_select_regions` decides about the count it read back, and what
/// it says when the count says no.
///
/// Two defects from the 2026-09-02 live profile live here. A successful
/// `mode: "none"` reported `state: "selected"` — the same string the other
/// three modes use to mean regions were just SELECTED — on 6 of 6 live calls,
/// each with `selected_count: 0`. And the poll that waited for the count broke
/// on "it moved at all" while the reported state was decided separately, so
/// the two could disagree; they are one function now, which is also the poll's
/// break condition, so a mode whose goal is already met stops looking
/// immediately instead of burning the old 8 × 0.25 s.
final class MultiRegionSelectionVerdictTests: XCTestCase {

    // MARK: - mode "none" says CLEARED, not selected

    func testAClearedSelectionIsNotReportedAsASelection() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "none", before: 3, after: 0
        )
        XCTAssertTrue(verdict.success)
        XCTAssertEqual(verdict.state, "cleared")
        XCTAssertNotEqual(verdict.state, "selected")
    }

    /// The whole project selected and then cleared is the same verdict as
    /// three regions cleared — the size of what went away changes nothing.
    func testClearingTheWholeProjectReadsCleared() {
        XCTAssertEqual(
            LogicAccessibility.multiRegionSelectionVerdict(mode: "none", before: 54, after: 0),
            LogicAccessibility.MultiRegionSelectionVerdict(success: true, state: "cleared")
        )
    }

    /// Nothing was selected to begin with: the command had nothing to do and
    /// the result says so with the server's own no-op vocabulary, rather than
    /// claiming a clear that never happened or failing a call whose goal is
    /// satisfied.
    func testAnAlreadyEmptySelectionIsAVerifiedNoOp() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "none", before: 0, after: 0
        )
        XCTAssertTrue(verdict.success)
        XCTAssertEqual(verdict.state, "already_clear")
    }

    /// The direction that was already accurate stays as it was.
    func testASelectionThatSurvivedTheClearIsAFailure() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "none", before: 3, after: 3
        )
        XCTAssertFalse(verdict.success)
        XCTAssertEqual(verdict.state, "unchanged")
    }

    // MARK: - the selecting modes are unchanged

    func testASelectionThatGrewIsASelection() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "track", before: 1, after: 9
        )
        XCTAssertTrue(verdict.success)
        XCTAssertEqual(verdict.state, "selected")
    }

    /// The anchor pass leaves exactly one region selected, so "still 1" is the
    /// shape of a command that did nothing at all — the `1 -> 1` the
    /// Tracks-area focus note was written about.
    func testStillOneSelectedRegionIsTheFailureShape() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "track", before: 1, after: 1
        )
        XCTAssertFalse(verdict.success)
        XCTAssertEqual(verdict.state, "unchanged")
    }

    /// `mode: "all"` fired at a project that is already fully selected: the
    /// count cannot move and the goal is met anyway. This is the case that used
    /// to cost the full 2.0 s of blind sleeps, because the poll was waiting for
    /// a change that was never coming.
    func testAnAlreadyFullySelectedProjectIsSatisfiedWithoutAChange() {
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: "all", before: 54, after: 54
        )
        XCTAssertTrue(verdict.success)
        XCTAssertEqual(verdict.state, "selected")
    }

    /// An empty project (or a Tracks area with nothing rendered) under
    /// `mode: "all"`: 0 -> 0 is not a selection and is not claimed as one.
    func testSelectAllOnNothingIsNotASelection() {
        XCTAssertFalse(
            LogicAccessibility.multiRegionSelectionVerdict(mode: "all", before: 0, after: 0).success
        )
    }

    // MARK: - the failure note points the right way

    /// The old note told a `mode: "none"` caller there was "nothing more to
    /// select", which is the opposite of what it asked for.
    func testTheClearFailureNoteTalksAboutClearing() {
        let note = LogicAccessibility.multiRegionSelectionFailure(
            mode: "none", before: 3, after: 3, focusSentence: nil
        )
        XCTAssertTrue(note.contains("did not clear"))
        XCTAssertTrue(note.contains("3 -> 3"))
        XCTAssertTrue(note.contains("Deselect All"))
        XCTAssertFalse(note.contains("nothing more to select"))
        XCTAssertTrue(note.hasSuffix("Nothing was edited."))
    }

    func testTheSelectFailureNoteKeepsItsTwoSuspects() {
        let note = LogicAccessibility.multiRegionSelectionFailure(
            mode: "track", before: 1, after: 1, focusSentence: nil
        )
        XCTAssertTrue(note.contains("1 -> 1"))
        XCTAssertTrue(note.contains("logic_list_key_commands"))
        XCTAssertTrue(note.contains("nothing more to select"))
    }

    /// The focus sentence is the third suspect, and the two anchorless modes
    /// could never carry it before — it hung off an anchor they do not have.
    func testTheFocusSentenceIsCarriedIntoTheNote() {
        let focus = TracksAreaFocus.Outcome.unverified(element: "AXWindow 'Compressor'")
        let note = LogicAccessibility.multiRegionSelectionFailure(
            mode: "none", before: 3, after: 3, focusSentence: focus.summary
        )
        XCTAssertTrue(note.contains("UNVERIFIED"))
        XCTAssertTrue(note.contains("Compressor"))
        XCTAssertTrue(note.hasSuffix("Nothing was edited."))
    }
}
