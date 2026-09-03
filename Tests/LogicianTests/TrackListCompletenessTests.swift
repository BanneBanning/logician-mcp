import XCTest
@testable import Logician

/// The honesty verdict on `logic_list_tracks`. The producer audit called this
/// the project's one honesty failure — a partial world returned as
/// `success: true` with the caveat in a footnote — so the rules that decide
/// "partial" are worth pinning down without Logic running.
final class TrackListCompletenessTests: XCTestCase {

    private func rows(_ numbers: [Int]) -> [TrackListCompleteness.Row] {
        numbers.map {
            TrackListCompleteness.Row(number: $0, name: "T\($0)", isStack: false, expanded: nil)
        }
    }

    /// The decisive case, and the one the reference project produced: thirteen
    /// contiguous headers from track 1, with more below the viewport. Nothing in
    /// the NUMBERING betrays it — only Logic's scroll bar does, which is why the
    /// scroll signal had to exist at all.
    func testScrollableTracksAreaIsPartialEvenWithContiguousNumbers() {
        let verdict = TrackListCompleteness.evaluate(
            rows: rows(Array(1...13)), scrollable: true
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.completeness, "partial")
        XCTAssertTrue(verdict.evidence.contains { $0.contains("scroll") })
        XCTAssertEqual(verdict.missingTrackNumbers, [])
    }

    /// And its twin: the SAME rows with no scroll evidence are not "complete",
    /// they are "unknown". This is the assertion the whole type exists for.
    func testNoEvidenceIsUnknownAndNeverComplete() {
        for scrollable in [false, nil] as [Bool?] {
            let verdict = TrackListCompleteness.evaluate(
                rows: rows(Array(1...13)), scrollable: scrollable
            )
            XCTAssertFalse(verdict.partial)
            XCTAssertEqual(verdict.completeness, "unknown")
            XCTAssertNotEqual(verdict.completeness, "complete")
            XCTAssertTrue(verdict.evidence.isEmpty)
        }
    }

    func testHeadersScrolledOutAboveAreNamed() {
        let verdict = TrackListCompleteness.evaluate(rows: rows(Array(8...20)), scrollable: nil)
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.missingTrackNumbers, Array(1...7))
        XCTAssertTrue(verdict.evidence.contains { $0.contains("lowest track number rendered is 8") })
    }

    func testGapsInTheNumberingAreNamed() {
        let verdict = TrackListCompleteness.evaluate(rows: rows([1, 2, 5, 6, 9]), scrollable: nil)
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.missingTrackNumbers, [3, 4, 7, 8])
    }

    func testCollapsedStacksHideSubtracks() {
        let stacked = [
            TrackListCompleteness.Row(number: 1, name: "Drums", isStack: true, expanded: false),
            TrackListCompleteness.Row(number: 2, name: "Bass", isStack: false, expanded: nil)
        ]
        let verdict = TrackListCompleteness.evaluate(rows: stacked, scrollable: false)
        XCTAssertTrue(verdict.partial)
        XCTAssertTrue(verdict.evidence.contains { $0.contains("Drums") })
        // An EXPANDED stack hides nothing.
        let expanded = [
            TrackListCompleteness.Row(number: 1, name: "Drums", isStack: true, expanded: true)
        ]
        XCTAssertFalse(TrackListCompleteness.evaluate(rows: expanded, scrollable: false).partial)
    }

    /// An empty list is the most misleading answer of all: it looks like "this
    /// project has no tracks" and is usually "Accessibility rendered nothing".
    func testAnEmptyListIsPartialNotAnEmptyProject() {
        let verdict = TrackListCompleteness.evaluate(rows: [], scrollable: nil)
        XCTAssertTrue(verdict.partial)
        XCTAssertTrue(verdict.evidence.first?.contains("not even that it is empty") == true)
    }

    func testEvidenceAccumulatesRatherThanStoppingAtTheFirstSignal() {
        let mixed = [
            TrackListCompleteness.Row(number: 4, name: "Drums", isStack: true, expanded: false),
            TrackListCompleteness.Row(number: 7, name: "Bass", isStack: false, expanded: nil)
        ]
        let verdict = TrackListCompleteness.evaluate(rows: mixed, scrollable: true)
        XCTAssertEqual(verdict.evidence.count, 4)
        XCTAssertEqual(verdict.missingTrackNumbers, [1, 2, 3, 5, 6])
    }

    // MARK: - The join: which collapsed stack is hiding the missing numbers

    /// The reference project's exact shape (measured 2026-09-02): 19 rendered
    /// rows, 9 “Drum Synth Kit” the only collapsed stack, and the gap running
    /// 10…19 immediately after it. The two facts used to ship as independent
    /// sentences and the agent had to join them; the join costs no AX read.
    func testTheGapIsAttributedToTheCollapsedStackItFollows() {
        var rows: [TrackListCompleteness.Row] = (1...8).map {
            TrackListCompleteness.Row(number: $0, name: "T\($0)", isStack: false, expanded: nil)
        }
        rows.append(
            TrackListCompleteness.Row(
                number: 9, name: "Drum Synth Kit", isStack: true, expanded: false
            )
        )
        rows.append(contentsOf: (20...29).map {
            TrackListCompleteness.Row(number: $0, name: "T\($0)", isStack: false, expanded: nil)
        })
        let verdict = TrackListCompleteness.evaluate(rows: rows, scrollable: nil)

        XCTAssertEqual(verdict.missingTrackNumbers, Array(10...19))
        XCTAssertEqual(verdict.hiddenBy?.trackNumber, 9)
        XCTAssertEqual(verdict.hiddenBy?.trackName, "Drum Synth Kit")
        XCTAssertEqual(verdict.hiddenBy?.trackNumbers, Array(10...19))
        let gapSentence = verdict.evidence.first { $0.contains("fall inside the rendered range") }
        XCTAssertNotNil(gapSentence)
        XCTAssertTrue(gapSentence?.contains("Drum Synth Kit") == true)
        XCTAssertTrue(gapSentence?.contains("logic_set_track_stack") == true)
        // It is an inference and must read like one.
        XCTAssertTrue(gapSentence?.contains("almost certainly") == true)
    }

    /// A gap that does NOT begin right after a collapsed stack keeps the old,
    /// unattributed sentence. The join is only made when the rows in hand
    /// support it.
    func testAGapNotFollowingACollapsedStackIsNotAttributed() {
        let rows = [
            TrackListCompleteness.Row(number: 1, name: "Drums", isStack: true, expanded: false),
            TrackListCompleteness.Row(number: 2, name: "Bass", isStack: false, expanded: nil),
            TrackListCompleteness.Row(number: 5, name: "Vox", isStack: false, expanded: nil)
        ]
        let verdict = TrackListCompleteness.evaluate(rows: rows, scrollable: nil)
        XCTAssertEqual(verdict.missingTrackNumbers, [3, 4])
        XCTAssertNil(verdict.hiddenBy)
        XCTAssertTrue(verdict.evidence.contains { $0.contains("hidden or scrolled out") })
        // The stack is still named on its own — it just is not blamed.
        XCTAssertTrue(verdict.evidence.contains { $0.contains("collapsed track stack(s) 1") })
    }

    /// An EXPANDED stack above a gap explains nothing: its subtracks are on
    /// screen. Only `expanded == false` can be blamed.
    func testAnExpandedStackAboveAGapIsNotBlamed() {
        let rows = [
            TrackListCompleteness.Row(number: 1, name: "Drums", isStack: true, expanded: true),
            TrackListCompleteness.Row(number: 4, name: "Bass", isStack: false, expanded: nil)
        ]
        XCTAssertNil(TrackListCompleteness.evaluate(rows: rows, scrollable: nil).hiddenBy)
    }

    /// Only the run that starts at the gap's first number is claimed — a later,
    /// separate gap has its own cause and the sentence says so.
    func testOnlyTheRunTouchingTheStackIsClaimed() {
        let rows = [
            TrackListCompleteness.Row(number: 1, name: "Drums", isStack: true, expanded: false),
            TrackListCompleteness.Row(number: 4, name: "Bass", isStack: false, expanded: nil),
            TrackListCompleteness.Row(number: 7, name: "Vox", isStack: false, expanded: nil)
        ]
        let verdict = TrackListCompleteness.evaluate(rows: rows, scrollable: nil)
        XCTAssertEqual(verdict.missingTrackNumbers, [2, 3, 5, 6])
        XCTAssertEqual(verdict.hiddenBy?.trackNumbers, [2, 3])
        let gapSentence = verdict.evidence.first { $0.contains("fall inside the rendered range") }
        XCTAssertTrue(gapSentence?.contains("the rest are hidden or scrolled out") == true)
        XCTAssertEqual(TrackListCompleteness.contiguousRun(from: [2, 3, 5, 6]), [2, 3])
    }

    // MARK: - The scroll signal, including the silence

    /// D2: on the reference Logic the scroll bar is never published, so the one
    /// signal that could catch rows BELOW the viewport with no numbering gap
    /// never fires. Its absence must not read as "everything fits" — and it
    /// must not make the verdict partial either, because nothing was proved.
    func testAnUnavailableScrollBarSaysSoWithoutClaimingRowsAreMissing() {
        let verdict = TrackListCompleteness.evaluate(rows: rows(Array(1...13)), scrollable: nil)
        XCTAssertFalse(verdict.partial)
        XCTAssertEqual(verdict.completeness, "unknown")
        XCTAssertTrue(verdict.evidence.isEmpty)
        XCTAssertEqual(verdict.scrollSignal.state, "unavailable")
        XCTAssertTrue(verdict.scrollSignal.reason.contains("no vertical scroll bar"))
        XCTAssertTrue(verdict.scrollSignal.reason.contains("this silence is not a fit"))
        // It ships on every call, so it stays one sentence.
        XCTAssertLessThan(verdict.scrollSignal.reason.utf8.count, 200)
    }

    func testTheScrollSignalReportsWhatTheBarActuallySaid() {
        XCTAssertEqual(
            TrackListCompleteness.evaluate(rows: rows([1]), scrollable: true).scrollSignal.state,
            "scrollable"
        )
        XCTAssertEqual(
            TrackListCompleteness.evaluate(rows: rows([1]), scrollable: false).scrollSignal.state,
            "fits"
        )
        // Every state carries its reason — the field is never a bare enum a
        // reader has to interpret.
        for scrollable in [true, false, nil] as [Bool?] {
            XCTAssertFalse(
                TrackListCompleteness.evaluate(rows: rows([1]), scrollable: scrollable)
                    .scrollSignal.reason.isEmpty
            )
        }
    }

    // MARK: - What a refusal about a name owes the caller

    /// Rows 10–19 of the reference project sit inside collapsed stack 9 and
    /// are not rendered, so a name in there used to be refused in exactly the
    /// words a typo gets — while this very verdict, off the same walk, was
    /// already naming the stack that hides them.
    func testHiddenRowsHintNamesTheStackAndTheCallThatOpensIt() {
        var rows = self.rows(Array(1...8))
        rows.append(
            TrackListCompleteness.Row(number: 9, name: "Drums", isStack: true, expanded: false)
        )
        rows.append(contentsOf: self.rows(Array(20...29)))
        let hint = TrackListCompleteness.hiddenRowsHint(
            TrackListCompleteness.evaluate(rows: rows, scrollable: nil)
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("logic_set_track_stack"))
        XCTAssertTrue(hint!.contains("\"Drums\""))
        XCTAssertTrue(hint!.contains("track_number: 9"))
        XCTAssertTrue(hint!.contains("expanded: true"))
        // And it says WHICH rows are missing, so the caller can tell whether
        // the name it asked for could plausibly be one of them.
        XCTAssertTrue(hint!.contains("10, 11, 12, 13, 14, 15, 16, 17, 18, 19"))
    }

    /// The nil IS the feature: a genuinely nonexistent name on a listing that
    /// proved nothing missing gets the plain refusal, so the two messages
    /// differ exactly where the two situations do.
    func testNoEvidenceOfMissingRowsMeansNoHint() {
        XCTAssertNil(
            TrackListCompleteness.hiddenRowsHint(
                TrackListCompleteness.evaluate(rows: rows(Array(1...13)), scrollable: nil)
            )
        )
        XCTAssertNil(
            TrackListCompleteness.hiddenRowsHint(
                TrackListCompleteness.evaluate(rows: rows(Array(1...13)), scrollable: false)
            )
        )
    }

    /// Rows can be missing with no stack to blame — a scrolled Tracks area, or
    /// headers above the first one rendered. The hint still fires, and still
    /// names a move, but it may not point at a stack that was never found.
    func testHintWithoutAStackNamesScrollingInstead() {
        let hint = TrackListCompleteness.hiddenRowsHint(
            TrackListCompleteness.evaluate(rows: rows(Array(8...20)), scrollable: true)
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("logic_set_track_stack"))
        XCTAssertTrue(hint!.contains("scroll"))
        XCTAssertFalse(hint!.contains("track_number:"))
        XCTAssertTrue(hint!.contains("1, 2, 3, 4, 5, 6, 7"))
    }

    /// The standing note must keep saying the two things an agent forgets: this
    /// is not a census, and headerless strips are never in it.
    func testStandingNoteNamesBothLimits() {
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("never listed here"))
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("Stereo Out"))
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("partial: false"))
        // …and it must keep saying them SHORT. It was 570 bytes, 22% of a
        // 2 597-byte response, byte-identical on every call ever made; it is
        // 399 now, and this is the line that stops it growing back.
        XCTAssertLessThan(TrackListCompleteness.standingNote.utf8.count, 450)
    }
}
