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

    func testANoteRowIsParsedIntoBarBeatPitchVelocityLength() {
        let payload = ListEditorPayload.event(from: entry(
            ["Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            ["9 2 1 1 ", "Note", "1", "C3", "100", "1 0 0"]
        ))
        XCTAssertEqual(payload["bar"] as? Int, 9)
        XCTAssertEqual(payload["beat"] as? Double, 2)
        XCTAssertEqual(payload["type"] as? String, "Note")
        XCTAssertEqual(payload["pitch"] as? String, "C3")
        XCTAssertEqual(payload["velocity"] as? Int, 100)
        XCTAssertEqual(payload["length"] as? String, "1 0 0")
        // The verbatim half is always there too, under Logic's own names.
        XCTAssertEqual(payload["Num"] as? String, "C3")
        XCTAssertEqual(payload["Val"] as? String, "100")
        XCTAssertEqual(payload["row"] as? Int, 1)
    }

    /// `Num` and `Val` mean pitch/velocity on a note row and controller/value on
    /// a CC row. Only the note reading gets the named fields; the CC row keeps
    /// Logic's column names and invents nothing.
    func testAControllerRowIsNotReadAsANote() {
        let payload = ListEditorPayload.event(from: entry(
            ["Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            ["9 1 1 1 ", "Control", "1", "1", "64", ""]
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

    func testMarkerNameIsFoundUnderAnyOfLogicsColumnNames() {
        for column in ["Marker", "Name", "Text"] {
            let payload = ListEditorPayload.marker(from: entry(
                ["Position", column], ["33 1 1 1 ", "drop"]
            ))
            XCTAssertEqual(payload["name"] as? String, "drop", column)
            XCTAssertEqual(payload["bar"] as? Int, 33)
        }
    }

    func testAnUnnamedMarkerHasNoNameFieldRatherThanAnEmptyOne() {
        let payload = ListEditorPayload.marker(from: entry(
            ["Position", "Marker"], ["33 1 1 1 ", ""]
        ))
        XCTAssertNil(payload["name"])
        XCTAssertEqual(payload["bar"] as? Int, 33)
    }

    func testColumnLookupIsCaseInsensitive() {
        let payload = ListEditorPayload.event(from: entry(
            ["position", "status"], ["5 1 1 1 ", "Note"]
        ))
        XCTAssertEqual(payload["bar"] as? Int, 5)
        XCTAssertEqual(payload["type"] as? String, "Note")
    }
}
