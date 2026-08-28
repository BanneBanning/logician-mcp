import XCTest
@testable import Logician

/// Turning a List Editors row into a result entry. Pure, so the column grammar
/// this slice discovered live is pinned here rather than only in a session log:
/// if Logic renames a column, one of these fails instead of a tool quietly
/// reporting events with no pitch.
final class ListEditorPayloadTests: XCTestCase {

    private func entry(_ columns: [String], _ cells: [String], index: Int = 0) -> ListEditorEntry {
        var fields: [String: String] = [:]
        for (position, column) in columns.enumerated() where !column.isEmpty {
            fields[column] = position < cells.count ? cells[position] : ""
        }
        return ListEditorEntry(index: index, fields: fields, cells: cells)
    }

    // MARK: - Event rows

    /// The Event tab's real columns and a real row, both measured live on
    /// 2026-08-28: eight columns, the pitch printed as a NOTE NAME and the
    /// velocity as a plain number.
    private let eventColumns = ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"]

    func testANoteRowIsParsedIntoBarBeatPitchVelocityLength() {
        let payload = ListEditorPayload.event(from: entry(
            eventColumns,
            ["", "", "1 3 1 1 ", "Note", "1", "D♯2", "98", "0 2 0 0"]
        ))
        XCTAssertEqual(payload["bar"] as? Int, 1)
        XCTAssertEqual(payload["beat"] as? Double, 3)
        XCTAssertEqual(payload["type"] as? String, "Note")
        XCTAssertEqual(payload["pitch"] as? String, "D♯2")
        XCTAssertEqual(payload["velocity"] as? Int, 98)
        XCTAssertEqual(payload["length"] as? String, "0 2 0 0")
        // The verbatim half is always there too, under Logic's own names.
        XCTAssertEqual(payload["Num"] as? String, "D♯2")
        XCTAssertEqual(payload["Val"] as? String, "98")
        XCTAssertEqual(payload["row"] as? Int, 1)
    }

    /// The Val cell's slider publishes a CONSTANT raw number on its AXValue
    /// (`3306422272`, the same on every note) and the real velocity on its
    /// AXValueDescription. The reader prefers the description — but if a Logic
    /// version ever routes the raw number here, "velocity 3306422272" must not
    /// be reported as a fact. Anything outside 0-127 is not a velocity.
    func testAnImplausibleVelocityIsOmittedRatherThanReported() {
        let payload = ListEditorPayload.event(from: entry(
            eventColumns,
            ["", "", "1 1 1 1 ", "Note", "1", "51", "3306422272", "0 2 0 0"]
        ))
        XCTAssertNil(payload["velocity"])
        // ...and the verbatim cell is still there, so nothing is hidden.
        XCTAssertEqual(payload["Val"] as? String, "3306422272")
        XCTAssertEqual(payload["pitch"] as? String, "51")
    }

    /// `Num` and `Val` mean pitch/velocity on a note row and controller/value on
    /// a CC row. Only the note reading gets the named fields; the CC row keeps
    /// Logic's column names and invents nothing.
    func testAControllerRowIsNotReadAsANote() {
        let payload = ListEditorPayload.event(from: entry(
            eventColumns,
            ["", "", "9 1 1 1 ", "Control", "1", "1", "64", ""]
        ))
        XCTAssertEqual(payload["type"] as? String, "Control")
        XCTAssertNil(payload["pitch"])
        XCTAssertNil(payload["velocity"])
        XCTAssertEqual(payload["Num"] as? String, "1")
        XCTAssertEqual(payload["Val"] as? String, "64")
    }

    /// A sub-beat position keeps its fraction: an event 1/16 into beat 2 is
    /// beat 2.25, not beat 2.
    func testSubBeatPositionsSurvive() {
        let payload = ListEditorPayload.event(from: entry(
            ["Position", "Status"], ["9 2 2 1 ", "Note"]
        ))
        XCTAssertEqual(payload["beat"] as? Double, 2.25)
    }

    /// The failure mode worth guarding: no published header. Every cell must
    /// still reach the caller, so an unnameable row is reported as an unnameable
    /// row and never as an empty one.
    func testRowsSurviveAMissingHeader() {
        let payload = ListEditorPayload.event(from: entry([], ["9 1 1 1 ", "Note", "1", "C3"]))
        XCTAssertEqual(payload["cells"] as? [String], ["9 1 1 1 ", "Note", "1", "C3"])
        XCTAssertNil(payload["bar"])
        XCTAssertNil(payload["type"])
    }

    func testAnUnparsablePositionIsOmittedRatherThanGuessed() {
        let payload = ListEditorPayload.event(from: entry(
            ["Position", "Status"], ["", "Note"]
        ))
        XCTAssertNil(payload["bar"])
        XCTAssertNil(payload["beat"])
        XCTAssertEqual(payload["type"] as? String, "Note")
    }

    // MARK: - Marker rows

    /// Logic's column is titled "Marker Name" (measured 2026-08-28); the others
    /// are accepted in case a version or locale titles it differently.
    func testMarkerNameIsFoundUnderAnyOfLogicsColumnNames() {
        for column in ["Marker Name", "Marker", "Name", "Text"] {
            let payload = ListEditorPayload.marker(from: entry(
                ["Position", column], ["33 1 1 1 ", "drop"]
            ))
            XCTAssertEqual(payload["name"] as? String, "drop", column)
            XCTAssertEqual(payload["bar"] as? Int, 33)
        }
    }

    func testAnUnnamedMarkerHasNoNameFieldRatherThanAnEmptyOne() {
        let payload = ListEditorPayload.marker(from: entry(
            ["Position", "Marker Name"], ["33 1 1 1 ", ""]
        ))
        XCTAssertNil(payload["name"])
        XCTAssertEqual(payload["bar"] as? Int, 33)
    }

    /// A whole Marker List row as Logic published it, columns and all.
    func testTheRealMarkerRowShape() {
        let payload = ListEditorPayload.marker(from: entry(
            ["L", "Position", "Marker Name", "Length"],
            ["", "161 1 1 1 ", "Marker 1", "∞"]
        ))
        XCTAssertEqual(payload["bar"] as? Int, 161)
        XCTAssertEqual(payload["name"] as? String, "Marker 1")
        XCTAssertEqual(payload["Length"] as? String, "∞")
    }

    func testColumnLookupIsCaseInsensitive() {
        let payload = ListEditorPayload.event(from: entry(
            ["position", "status"], ["5 1 1 1 ", "Note"]
        ))
        XCTAssertEqual(payload["bar"] as? Int, 5)
        XCTAssertEqual(payload["type"] as? String, "Note")
    }
}
