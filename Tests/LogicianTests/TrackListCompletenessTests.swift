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

    /// The standing note must keep saying the two things an agent forgets: this
    /// is not a census, and headerless strips are never in it.
    func testStandingNoteNamesBothLimits() {
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("never listed here"))
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("Stereo Out"))
        XCTAssertTrue(TrackListCompleteness.standingNote.contains("partial: false"))
    }
}
