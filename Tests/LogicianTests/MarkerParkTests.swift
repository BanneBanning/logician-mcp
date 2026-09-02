import XCTest
@testable import Logician

/// Where `logic_markers` parks the playhead, and what the List Editors pane's
/// opening settle is allowed to wait for. Both were bugs that no live session
/// could show — one reported two disagreeing numbers in the same payload, the
/// other waited for something that could not become true and looked like a slow
/// pane — so both decisions are pure and pinned here.
final class MarkerParkTests: XCTestCase {

    /// The Marker tab's real columns, measured live 2026-08-28.
    private let markerColumns = ["Position", "Marker Name", "Length"]

    private func marker(_ cells: [String]) -> [String: Any] {
        var fields: [String: String] = [:]
        for (position, column) in markerColumns.enumerated() {
            fields[column] = position < cells.count ? cells[position] : ""
        }
        return ListEditorPayload.marker(
            from: ListEditorEntry(index: 0, fields: fields, cells: cells)
        )
    }

    // MARK: - goto parks on the marker's beat (D1)

    /// THE regression. `Marker 1` in the profiled project sits at `33 4 1 1` —
    /// bar 33, BEAT 4 — and `goto` parked the playhead at bar 33 beat 1,
    /// because it read only the bar and passed `beat: nil`, which does not
    /// touch the beat slider at all. The row's own payload has always carried
    /// the beat; this is the arithmetic that uses it.
    func testAMarkerOnBeatFourParksOnBeatFour() {
        let row = marker(["33 4 1 1 ", "Marker 1", "∞"])
        XCTAssertEqual(row["bar"] as? Int, 33)
        let target = MarkerPark.target(bar: row["bar"] as? Int ?? 0, beat: row["beat"])
        XCTAssertEqual(target, MarkerPark.Target(bar: 33, beat: 4, exact: true))
    }

    func testAMarkerOnTheBarLineParksOnBeatOne() {
        let row = marker(["161 1 1 1 ", "Marker 4", "∞"])
        let target = MarkerPark.target(bar: row["bar"] as? Int ?? 0, beat: row["beat"])
        XCTAssertEqual(target, MarkerPark.Target(bar: 161, beat: 1, exact: true))
    }

    /// A marker between beats. The control bar publishes a bar slider and a
    /// beat slider and nothing below them, so the playhead can only reach the
    /// beat LINE — and the result has to say that rather than claim the
    /// marker's position.
    func testAMarkerBetweenBeatsParksOnTheBeatLineAndSaysItIsNotExact() {
        let row = marker(["33 4 2 120 ", "Marker 2", "∞"])
        let target = MarkerPark.target(bar: row["bar"] as? Int ?? 0, beat: row["beat"])
        XCTAssertEqual(target.bar, 33)
        XCTAssertEqual(target.beat, 4)
        XCTAssertFalse(target.exact)
    }

    /// A position the parser could not read leaves no `beat` in the payload.
    /// The bar is still worth going to, and beat 1 is the bar line.
    func testAMissingBeatParksOnTheBarLine() {
        XCTAssertEqual(MarkerPark.target(bar: 9, beat: nil), MarkerPark.Target(bar: 9, beat: 1, exact: true))
    }

    /// The payload's beat is a Double (`4 2 120` is beat 4.37), but an Int is
    /// accepted too rather than silently falling back to beat 1.
    func testAnIntegerBeatIsAcceptedAsWellAsADouble() {
        XCTAssertEqual(MarkerPark.target(bar: 5, beat: 3), MarkerPark.Target(bar: 5, beat: 3, exact: true))
        XCTAssertEqual(MarkerPark.target(bar: 5, beat: 3.0), MarkerPark.Target(bar: 5, beat: 3, exact: true))
        XCTAssertEqual(MarkerPark.target(bar: 5, beat: "4"), MarkerPark.Target(bar: 5, beat: 1, exact: true))
    }

    /// Beats are ONE-based in Logic's display and in the playhead's slider, so
    /// nothing below 1 may ever be asked of it.
    func testABeatBelowOneIsClampedToTheBarLine() {
        XCTAssertEqual(MarkerPark.target(bar: 2, beat: 0.0).beat, 1)
        XCTAssertEqual(MarkerPark.target(bar: 2, beat: -3.0).beat, 1)
    }

    // MARK: - what the pane-open settle waits for (C1)

    /// THE regression. Logic opens the List Editors pane on the tab it was last
    /// on — `Event` 15/15 — so a settle that waited for the MARKER tab's table
    /// to be drawn was waiting for the press that follows it. It ran the
    /// deadline out every time, 610–1 094 ms per pane cycle.
    func testATabThatIsNotSelectedYetIsReadyAsSoonAsTheStripIsThere() {
        XCTAssertEqual(
            ListEditorSettle.goal(target: "Marker", tabs: [
                (name: "Event", selected: true), (name: "Marker", selected: false),
                (name: "Tempo", selected: false), (name: "Signature", selected: false)
            ]),
            .ready
        )
    }

    /// The case that must NOT regress into "ready": nothing is going to be
    /// pressed, so this settle is the only one and it still has to wait for the
    /// table. This is every `logic_list_events` read.
    func testATabThatIsAlreadySelectedStillWaitsForItsTable() {
        XCTAssertEqual(
            ListEditorSettle.goal(target: "Event", tabs: [
                (name: "Event", selected: true), (name: "Marker", selected: false),
                (name: "Tempo", selected: false), (name: "Signature", selected: false)
            ]),
            .targetTabDrawn
        )
    }

    func testNoStripYetMeansKeepWaitingForTheStrip() {
        XCTAssertEqual(ListEditorSettle.goal(target: "Marker", tabs: []), .tabStrip)
    }

    /// A strip that does not carry the tab keeps the settle waiting rather than
    /// returning early: the caller's `tab_not_found` refusal is worth more
    /// after the deadline than before the pane has finished painting.
    func testAStripWithoutTheTargetTabKeepsWaiting() {
        XCTAssertEqual(
            ListEditorSettle.goal(target: "Marqueur", tabs: [
                (name: "Event", selected: true), (name: "Marker", selected: false)
            ]),
            .tabStrip
        )
    }
}
