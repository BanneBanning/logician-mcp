import XCTest
@testable import Logician

/// The row Logic counts and does not draw, on the READ side.
///
/// Every case here is a live observation from 2026-09-02 turned into a pure
/// test: after a note was created in a 25-event region, `logic_list_events`
/// answered 26 entries of which the last was blank, the region's real last note
/// (`12 4 2 1 Note D♯3 93`) was missing, and both counts said 26 — so the
/// result carried no signal at all that anything was wrong. Reproduced 3/3; it
/// is not a race, the row stays undrawn until the list is scrolled.
final class ListEditorCensusTests: XCTestCase {

    /// The Event tab's real columns, measured live 2026-08-28.
    private let eventColumns = ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"]

    /// The last three rows of the live 26-row read: two drawn notes and the row
    /// Logic had published, counted and not drawn.
    private var eventCells: [[String]] {
        [
            ["", "", "11 2 1 1 ", "Note", "1", "C3", "65", "0 1 0 0"],
            ["", "", "12 2 1 1 ", "Note", "1", "A♯2", "88", "0 1 0 0"],
            ["", "", "", "Note", "", "", "", ""]
        ]
    }

    // MARK: - Event

    func testTheUndrawnRowIsCountedAndNotReported() {
        let census = ListEditorCensus.of(
            cells: eventCells, columns: eventColumns, declaredCount: 3
        )
        // Reported: only the rows that carry text.
        XCTAssertEqual(census.entries.count, 2)
        XCTAssertEqual(census.entries.map(\.index), [0, 1])
        // Counted: the list's own number, which is the honest one.
        XCTAssertEqual(census.count, 3)
        XCTAssertEqual(census.unread, 1)
        XCTAssertFalse(census.isComplete)
        // Named: the row number a warning can print.
        XCTAssertEqual(census.unreadRowNumbers, [3])
    }

    /// The heart of the defect: the blank row must never reach a payload, where
    /// it appeared as `{"type": "Note", "cells": ["","","","Note",...]}` and took
    /// a real note's place in the answer.
    func testThePhantomNeverBecomesAnEvent() {
        let census = ListEditorCensus.of(
            cells: eventCells, columns: eventColumns, declaredCount: 3
        )
        let events = census.entries.map(ListEditorPayload.event(from:))
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0["bar"] != nil })
        XCTAssertTrue(events.allSatisfy { ($0["pitch"] as? String)?.isEmpty == false })
    }

    /// A readable event is never dropped, whichever row it sits in: the drawn
    /// rows come back whole, in table order, with their own row numbers.
    func testEveryDrawnRowSurvivesWithItsRowNumber() {
        let census = ListEditorCensus.of(
            cells: [eventCells[2]] + eventCells[0...1], columns: eventColumns, declaredCount: 3
        )
        XCTAssertEqual(census.entries.map(\.index), [1, 2])
        XCTAssertEqual(census.unreadRowNumbers, [1])
        XCTAssertEqual(
            census.entries.map { $0.field(["Num"]) ?? "" }, ["C3", "A♯2"]
        )
    }

    /// A list nobody has grown reads exactly as it always did — no warning, no
    /// missing row, count unchanged.
    func testACompleteListIsUnaffected() {
        let census = ListEditorCensus.of(
            cells: Array(eventCells[0...1]), columns: eventColumns, declaredCount: 2
        )
        XCTAssertTrue(census.isComplete)
        XCTAssertEqual(census.count, 2)
        XCTAssertEqual(census.unread, 0)
        XCTAssertTrue(census.unreadRowNumbers.isEmpty)
    }

    /// With no `Number of Items` to trust, the count falls back to what was
    /// published — the rows that exist, not the rows that could be read.
    func testWithNoDeclaredCountTheCountIsWhatWasPublished() {
        let census = ListEditorCensus.of(
            cells: eventCells, columns: eventColumns, declaredCount: nil
        )
        XCTAssertEqual(census.count, 3)
        XCTAssertEqual(census.unread, 1)
    }

    /// A table with no Position column at all cannot be judged this way (the
    /// Event tab's folder level publishes `L M Position Name Trk Length`, but a
    /// future one might not) — so nothing is filtered and the reader keeps the
    /// behaviour it has always had rather than inventing a refusal.
    func testATableWithoutAPositionColumnKeepsEveryRow() {
        let census = ListEditorCensus.of(
            cells: [["", ""], ["", ""]], columns: ["L", "M"], declaredCount: 2
        )
        XCTAssertEqual(census.entries.count, 2)
        XCTAssertTrue(census.isComplete)
    }

    /// The general case, found live while verifying the fix (2026-09-02): a
    /// 54-event region publishes 54 rows and DRAWS only the ones in view — a
    /// contiguous window that moves with the scroll position, blanks above and
    /// below. The old reader answered that region with 26 events and 28 blanks
    /// and called the result 54.
    func testOnlyTheRowsInViewAreDrawnAndTheRestAreNamed() {
        let blank = ["", "", "", "Note", "", "", "", ""]
        let drawn = { (bar: Int) in
            ["", "", "\(bar) 1 1 1 ", "Note", "1", "C3", "70", "0 1 0 0"]
        }
        let cells = Array(repeating: blank, count: 3)
            + (1...4).map(drawn)
            + Array(repeating: blank, count: 2)
        let census = ListEditorCensus.of(cells: cells, columns: eventColumns, declaredCount: 9)
        XCTAssertEqual(census.count, 9)
        XCTAssertEqual(census.entries.count, 4)
        XCTAssertEqual(census.unread, 5)
        XCTAssertEqual(census.unreadRowNumbers, [1, 2, 3, 8, 9])
        XCTAssertEqual(census.entries.map(\.index), [3, 4, 5, 6])
    }

    // MARK: - Marker

    /// The Marker tab is read by the same function and lied the same way — the
    /// undrawn row became a marker with no name and no bar, counted in the
    /// list that `logic_markers` and `logic_project_snapshot` report.
    func testTheMarkerTabDropsTheUndrawnRowToo() {
        let columns = ["L", "Position", "Marker Name"]
        let census = ListEditorCensus.of(
            cells: [
                ["", "1 1 1 1 ", "Intro"],
                ["", "33 1 1 1 ", "Chorus"],
                ["", "", ""]
            ],
            columns: columns, declaredCount: 3
        )
        let markers = census.entries.map(ListEditorPayload.marker(from:))
        XCTAssertEqual(markers.compactMap { $0["name"] as? String }, ["Intro", "Chorus"])
        XCTAssertEqual(census.count, 3)
        XCTAssertEqual(census.unreadRowNumbers, [3])
    }

    // MARK: - Signature

    /// The Signature tab's initial row publishes NO position (measured
    /// 2026-08-28) — that is the project's own first signature at bar 1 and it
    /// must stay readable. Only a row with an empty position AND nothing else
    /// is the undrawn one.
    func testTheProjectsInitialSignatureIsNotMistakenForAnUndrawnRow() {
        XCTAssertTrue(UndrawnListRows.isDrawn(
            cells: ["", "4/4"], positionIndex: 0, emptyPositionIsTheFirstRow: true
        ))
        XCTAssertTrue(UndrawnListRows.isDrawn(
            cells: ["", "B♭ Major"], positionIndex: 0, emptyPositionIsTheFirstRow: true
        ))
        XCTAssertFalse(UndrawnListRows.isDrawn(
            cells: ["", ""], positionIndex: 0, emptyPositionIsTheFirstRow: true
        ))
        XCTAssertTrue(UndrawnListRows.isDrawn(
            cells: ["41 1 1 1 ", "7/8"], positionIndex: 0, emptyPositionIsTheFirstRow: true
        ))
    }

    /// WHY the Signature reader refuses instead of reporting what it read: a
    /// blank row parses as "bar 1, no n/d in it" — a key change — so a time
    /// signature that had just been added would be dropped from the meter map
    /// with the counts still agreeing, and every later bar placed confidently
    /// wrong. This pins the misreading the guard exists to prevent.
    func testABlankSignatureRowWouldOtherwiseParseAsAKeyChangeAtBarOne() {
        XCTAssertEqual(
            MeterMap.parseSignatureRow(cells: ["", ""], positionIndex: 0),
            .keySignature(bar: 1)
        )
    }

    /// On the Event and Marker tabs an empty position is never a real row —
    /// only the Signature tab has an unpositioned first row.
    func testAnEmptyPositionIsUndrawnEverywhereElse() {
        XCTAssertFalse(UndrawnListRows.isDrawn(
            cells: ["", "", "", "Note", "", "", "", ""], positionIndex: 2
        ))
        // Nor is a position that is there and says nothing.
        XCTAssertFalse(UndrawnListRows.isDrawn(
            cells: ["", "", "   ", "Note", "1", "C3", "65", ""], positionIndex: 2
        ))
        XCTAssertFalse(UndrawnListRows.isDrawn(
            cells: ["", "", "—", "Note", "1", "C3", "65", ""], positionIndex: 2
        ))
        // A short-but-real position still names a bar, and the payload takes
        // its bar/beat from exactly this parse — so the row is reported, not
        // thrown away. The reader's test is "can this be named", not the
        // writer's stricter "can this be addressed".
        XCTAssertTrue(UndrawnListRows.isDrawn(
            cells: ["", "", "12 4", "Note", "1", "C3", "65", ""], positionIndex: 2
        ))
    }

    /// The reader's wording is the writer's wording, verbatim — one sentence
    /// for one phenomenon, whichever tool the agent met it through.
    func testTheReaderAndTheWriterSayTheSameThing() {
        let reader = ListEditorCensus(entries: [], published: 1, declared: 1)
        let writer = EventCensus(rows: [], published: 1, declared: 1)
        XCTAssertEqual(reader.unreadNote, writer.unreadNote)
        XCTAssertTrue(reader.unreadNote.contains("had not drawn yet"))
    }

    // MARK: - The meter map's own honesty

    /// The live project's map: `4/4` from bar 1, `5/4` from bar 41, with one
    /// key-signature row beside them (measured 2026-09-02).
    private var meterMap: MeterMap {
        MeterMap(
            events: [
                MeterEvent(bar: 1, numerator: 4, denominator: 4),
                MeterEvent(bar: 41, numerator: 5, denominator: 4)
            ],
            source: .signatureList
        )!
    }

    /// A map read from Logic says so, and reports the key rows it skipped —
    /// the count the reader always promised and never handed over, and the one
    /// that makes a row this server could not read visible.
    func testAFreshMeterMapNamesItsRouteAndItsKeyRows() {
        let block = MeterKnowledge(
            map: meterMap, failure: nil, servedFromCache: false, keySignatureRows: 1
        ).payload
        XCTAssertEqual(block["read_route"] as? String, "signature_list")
        XCTAssertEqual(block["key_signature_rows"] as? Int, 1)
        XCTAssertNil(block["warning"])
    }

    /// A cached map is not a verified one. The tempo twin has said so since
    /// 2026-08-30 (`tempo_list_cache` + a SERVED FROM CACHE warning); this
    /// cache needs it more, because its cross-check can only ever contradict
    /// the map and there is no TTL.
    func testACachedMeterMapSaysSoAndWarns() {
        let block = MeterKnowledge(
            map: meterMap, failure: nil, servedFromCache: true, keySignatureRows: nil
        ).payload
        XCTAssertEqual(block["read_route"] as? String, "signature_list_cache")
        XCTAssertEqual(block["warning"] as? String, MeterKnowledge.cacheWarning)
        XCTAssertTrue(MeterKnowledge.cacheWarning.contains("SERVED FROM CACHE, UNVERIFIED"))
        // Nothing was read from Logic, so no row was counted — the field is
        // absent rather than a zero that would read as "no key signatures".
        XCTAssertNil(block["key_signature_rows"])
    }

    /// An unreadable Signature List still reports the attempt, and never
    /// hardens into "this project has one meter".
    func testAnUnreadableSignatureListIsVisibleAsOne() {
        let block = MeterKnowledge(
            map: nil,
            failure: .rowsUnreadable(tab: "Signature", detail: "row(s) 3 of 3"),
            servedFromCache: false, keySignatureRows: nil
        ).payload
        XCTAssertEqual(block["read"] as? Bool, false)
        XCTAssertEqual(block["integrated"] as? Bool, false)
        XCTAssertTrue((block["reason"] as? String)?.contains("could not be parsed") == true)
    }

    // MARK: - The walks

    /// Both List Editors walks want things that sit BESIDE the table — the four
    /// tab radio buttons and the `Number of Items` static text — and neither
    /// wants anything inside it. Descending into the rows was the whole
    /// superlinear term (measured 2026-09-02: the tab-strip walk 265–290 ms at
    /// 54 rows → 56–62 ms, the table walk 308–368 → 4.4–5.4).
    func testTheWalksStopAtTheTable() {
        XCTAssertEqual(ListEditorWalk.step(role: "AXTable"), .skipChildren)
        for role in ["AXGroup", "AXScrollArea", "AXRadioButton", "AXStaticText", ""] {
            XCTAssertEqual(ListEditorWalk.step(role: role), .descend, role)
        }
    }
}

