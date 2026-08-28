import XCTest
@testable import Logician

/// The Event List's WRITE grammar, in the half of it that is pure: which mode
/// the tab is in, what a row says, which row an address means, and what
/// Logic's note names mean as numbers.
///
/// Every fixture here is a row measured live on 2026-08-28 in Logic Pro 12.3.1,
/// on a scratch copy of a real region. The live half — that every cell is a
/// one-step stepper and that the table re-sorts under the write — cannot be
/// pinned by a test, which is exactly why the parts that CAN be are.
final class EventListWriteTests: XCTestCase {

    private let eventColumns = ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"]
    /// The other level of the same tab: with no region open it lists the
    /// project's regions, and not one of those cells carries a control.
    private let regionColumns = ["L", "M", "Position", "Name", "Trk", "Length"]

    private func row(_ cells: [String], index: Int = 0) -> EventRow {
        guard let parsed = EventListWrite.row(index: index, cells: cells, columns: eventColumns) else {
            XCTFail("row did not parse: \(cells)")
            return EventRow(
                index: index, position: [], status: "", channel: "", numberText: "",
                pitch: nil, velocity: nil, length: [], lengthText: "", positionText: ""
            )
        }
        return parsed
    }

    // MARK: - Which level of the tab are we on

    func testEventModeIsRecognisedByItsOwnColumns() {
        XCTAssertTrue(EventListWrite.isEventMode(columns: eventColumns))
    }

    /// The refusal that matters most: the region list looks like a perfectly
    /// good table and holds no events at all.
    func testTheRegionListLevelIsNotEventMode() {
        XCTAssertFalse(EventListWrite.isEventMode(columns: regionColumns))
        XCTAssertFalse(EventListWrite.isEventMode(columns: []))
    }

    // MARK: - Positions and lengths

    func testAPositionParsesIntoItsFourFields() {
        XCTAssertEqual(EventListWrite.parse(segments: "62 1 1 1 "), [62, 1, 1, 1])
        XCTAssertEqual(EventListWrite.parse(segments: "0 1 3 235"), [0, 1, 3, 235])
    }

    /// Three fields is not a position. The Signature tab's initial rows publish
    /// an EMPTY position cell, and a writer that read a partial parse as a
    /// position would edit the wrong row.
    func testAPartialPositionIsNotAPosition() {
        XCTAssertNil(EventListWrite.parse(segments: ""))
        XCTAssertNil(EventListWrite.parse(segments: "62 1 1"))
        XCTAssertNil(EventListWrite.parse(segments: "62 1 1 1 1"))
        XCTAssertNil(EventListWrite.parse(segments: "62 1 1 x"))
    }

    func testPositionsRoundTripThroughTheirText() {
        XCTAssertEqual(EventListWrite.format([62, 3, 1, 1]), "62 3 1 1")
    }

    // MARK: - Note names

    /// Logic's Event List prints note names in the convention where C3 is
    /// middle C, and its own Num slider carries the matching number: the cell
    /// read `D♯2` while the slider read 51, and `A♯2` while it read 58.
    func testLogicsNoteNamesAreTheC3Convention() {
        XCTAssertEqual(EventListWrite.parseNoteName("C3"), 60)
        XCTAssertEqual(EventListWrite.parseNoteName("D♯2"), 51)
        XCTAssertEqual(EventListWrite.parseNoteName("A♯2"), 58)
        XCTAssertEqual(EventListWrite.parseNoteName("F3"), 65)
        XCTAssertEqual(EventListWrite.parseNoteName("C-2"), 0)
    }

    /// An agent typing a pitch will not reach for the typographic sharp.
    func testAsciiAccidentalsAreAccepted() {
        XCTAssertEqual(EventListWrite.parseNoteName("A#2"), 58)
        XCTAssertEqual(EventListWrite.parseNoteName("a#2"), 58)
        XCTAssertEqual(EventListWrite.parseNoteName("Bb2"), 58)
        XCTAssertEqual(EventListWrite.parseNoteName("B♭2"), 58)
    }

    func testNamesAreProducedInLogicsOwnSpelling() {
        XCTAssertEqual(EventListWrite.noteName(51), "D♯2")
        XCTAssertEqual(EventListWrite.noteName(60), "C3")
        XCTAssertEqual(EventListWrite.noteName(0), "C-2")
        XCTAssertEqual(EventListWrite.noteName(127), "G8")
    }

    func testAPitchArgumentIsANumberOrAName() {
        XCTAssertEqual(EventListWrite.parsePitchArgument(60), 60)
        XCTAssertEqual(EventListWrite.parsePitchArgument("60"), 60)
        XCTAssertEqual(EventListWrite.parsePitchArgument("C3"), 60)
        XCTAssertNil(EventListWrite.parsePitchArgument("H3"))
        XCTAssertNil(EventListWrite.parsePitchArgument(128))
        XCTAssertNil(EventListWrite.parsePitchArgument(-1))
        XCTAssertNil(EventListWrite.parsePitchArgument(nil))
    }

    // MARK: - Rows

    func testANoteRowIsParsedIntoEveryFieldAWriteNeeds() {
        let note = row(["", "", "62 3 1 1 ", "Note", "1", "D♯2", "98", "0 2 0 0"])
        XCTAssertEqual(note.position, [62, 3, 1, 1])
        XCTAssertEqual(note.pitch, 51)
        XCTAssertEqual(note.velocity, 98)
        XCTAssertEqual(note.length, [0, 2, 0, 0])
        XCTAssertEqual(note.channel, "1")
        XCTAssertTrue(note.isNote)
    }

    /// `Num` and `Val` mean controller number and value on a CC row, so no
    /// pitch is invented for one — the tool refuses such a row by name.
    func testANonNoteRowCarriesNoPitch() {
        let control = row(["", "", "62 3 1 1 ", "Control", "1", "7", "98", ""])
        XCTAssertFalse(control.isNote)
        XCTAssertNil(control.pitch)
        XCTAssertEqual(control.numberText, "7")
    }

    /// The velocity comes from the DISPLAYED text. The `Val` slider's AXValue
    /// is a packed 32-bit field (3306422272 at velocity 98), and if a Logic
    /// version ever routed that number into the cell, writing against it would
    /// be worse than refusing to read it.
    func testAnImpossibleVelocityIsDroppedRatherThanBelieved() {
        let broken = row(["", "", "62 3 1 1 ", "Note", "1", "D♯2", "3306422272", "0 2 0 0"])
        XCTAssertNil(broken.velocity)
    }

    func testARowWithoutAParsablePositionIsNotARow() {
        XCTAssertNil(EventListWrite.row(
            index: 0, cells: ["", "", "", "Note", "1", "D♯2", "98", "0 2 0 0"],
            columns: eventColumns
        ))
    }

    /// Columns are looked up by NAME, never by position: the Event tab's set
    /// changes with what the list is showing, and a writer counting positions
    /// would edit the wrong cell the day Logic adds one.
    func testColumnsAreFoundByNameEvenWhenTheyMove() {
        let shuffled = ["Position", "Num", "Val", "Status", "Ch", "Length/Info"]
        let parsed = EventListWrite.row(
            index: 0, cells: ["62 3 1 1 ", "D♯2", "98", "Note", "1", "0 2 0 0"],
            columns: shuffled
        )
        XCTAssertEqual(parsed?.pitch, 51)
        XCTAssertEqual(parsed?.velocity, 98)
        XCTAssertEqual(parsed?.length, [0, 2, 0, 0])
    }

    // MARK: - Addressing

    /// A chord publishes three rows on one position (measured: `62 1 1 1` held
    /// D♯2, G2 and A♯2), so a position is not an address.
    private var chord: [EventRow] {
        [
            row(["", "", "62 1 1 1 ", "Note", "1", "D♯2", "98", "0 2 0 0"], index: 0),
            row(["", "", "62 1 1 1 ", "Note", "1", "G2", "98", "0 1 3 235"], index: 1),
            row(["", "", "62 1 1 1 ", "Note", "1", "A♯2", "98", "0 2 0 8"], index: 2),
            row(["", "", "62 3 1 1 ", "Note", "1", "F2", "98", "0 2 0 0"], index: 3)
        ]
    }

    func testPositionAndPitchTogetherAddressOneNote() {
        guard case .one(let hit) = EventListWrite.match(
            rows: chord, bar: 62, beat: 1, division: nil, tick: nil, pitch: 55
        ) else { return XCTFail("expected exactly one match") }
        XCTAssertEqual(hit.index, 1)
    }

    func testAPositionAloneIsAmbiguousInAChord() {
        guard case .ambiguous(let candidates) = EventListWrite.match(
            rows: chord, bar: 62, beat: 1, division: nil, tick: nil, pitch: nil
        ) else { return XCTFail("expected an ambiguous match") }
        XCTAssertEqual(candidates.count, 3)
    }

    func testABarWithOneNoteNeedsNoPitch() {
        guard case .one(let hit) = EventListWrite.match(
            rows: chord, bar: 62, beat: 3, division: nil, tick: nil, pitch: nil
        ) else { return XCTFail("expected exactly one match") }
        XCTAssertEqual(hit.pitch, 53)
    }

    func testAnAddressThatMatchesNothingSaysSo() {
        XCTAssertEqual(
            EventListWrite.match(rows: chord, bar: 99, beat: nil, division: nil, tick: nil, pitch: nil),
            .none
        )
    }

    // MARK: - Following the row through a write

    /// The sanity check on Logic's own selection. It is deliberately NOT a
    /// nearest-match search: the first version was, and on a chord of rows
    /// identical but for pitch, a ten-semitone coarse step made the NEIGHBOUR
    /// the nearest candidate — the loop then transposed the wrong note twice
    /// and left three notes reading C3, C3, D♯3 where F2, A2, C3 had been.
    func testARowStillAgreesWhenOnlyTheMovingFieldMoved() {
        let before = row(["", "", "62 5 1 1 ", "Note", "1", "F2", "98", "0 4 0 0"])
        let raised = row(["", "", "62 5 1 1 ", "Note", "1", "F3", "98", "0 4 0 0"])
        XCTAssertTrue(EventListWrite.agrees(raised, with: before, exceptFor: .pitch))
        XCTAssertFalse(EventListWrite.agrees(raised, with: before, exceptFor: .velocity))
    }

    func testTheNeighbourInAnIdenticalChordDoesNotAgree() {
        let target = row(["", "", "62 5 1 1 ", "Note", "1", "F2", "98", "0 4 0 0"])
        let neighbour = row(["", "", "62 5 1 1 ", "Note", "1", "A♯2", "64", "0 4 0 0"])
        XCTAssertFalse(EventListWrite.agrees(neighbour, with: target, exceptFor: .pitch))
    }

    func testAPositionWriteMayChangeBothBarAndBeat() {
        // Measured: writing 9 into the beat of a 5/4 bar walked 3 → 4 → 5 and
        // then ROLLED OVER into the next bar's beat 1.
        let before = row(["", "", "62 5 1 1 ", "Note", "1", "F2", "98", "0 4 0 0"])
        let rolled = row(["", "", "63 1 1 1 ", "Note", "1", "F2", "98", "0 4 0 0"])
        XCTAssertTrue(EventListWrite.agrees(rolled, with: before, exceptFor: .position))
    }

    // MARK: - What a move actually asks for

    /// An omitted position field keeps its current value, so moving a note to
    /// another beat does not also quantize the sub-beat feel it was played with.
    func testAMoveLeavesTheFieldsItWasNotGiven() {
        XCTAssertEqual(
            EventListWrite.targetPosition(current: [62, 1, 3, 120], bar: nil, beat: 3, division: nil, tick: nil),
            [62, 3, 3, 120]
        )
        XCTAssertEqual(
            EventListWrite.targetPosition(current: [62, 1, 3, 120], bar: 64, beat: 1, division: 1, tick: 1),
            [64, 1, 1, 1]
        )
        XCTAssertEqual(
            EventListWrite.targetPosition(current: [62, 1, 3, 120], bar: nil, beat: nil, division: nil, tick: nil),
            [62, 1, 3, 120]
        )
    }
}
