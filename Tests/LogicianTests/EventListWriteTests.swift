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

    // MARK: - One count: the row Logic has published and not drawn

    /// The cells of a region that has just grown, exactly as Logic published
    /// them on 2026-09-01 (profile §5, reproduced 2/2): the note that was just
    /// created is there, the list's genuine last row is NOT, and in its place
    /// sits a row with every cell empty but the Status one. `Number of Items`
    /// and `AXRows` both already say 26.
    private var grownList: [[String]] {
        [
            ["", "", "11 1 1 1 ", "Note", "1", "D♯2", "65", "0 0 2 228"],
            ["", "", "11 2 1 1 ", "Note", "1", "C3", "65", "0 0 2 228"],
            ["", "", "", "Note", "", "", "", ""]
        ]
    }

    /// The defect this pins, in one line: the unrealised row is COUNTED and
    /// not READ. Counting it by the parsed array's length instead made a
    /// `create` that had worked report `verification_failed` "found the list
    /// holds 25" — and leave the note in the user's region.
    func testARowLogicHasNotDrawnIsCountedAndNotRead() {
        let census = EventListWrite.census(
            cells: grownList, columns: eventColumns, declaredCount: 3
        )
        XCTAssertEqual(census.count, 3)
        XCTAssertEqual(census.rows.count, 2)
        XCTAssertEqual(census.unread, 1)
        XCTAssertFalse(census.isComplete)
        // Logic's own two counts agree with each other, so this is NOT the
        // truncated table that has always been refused.
        XCTAssertFalse(census.truncated)
    }

    /// The parsed rows keep their TABLE index, so the row element a write goes
    /// to is still found by it when a row above was not drawn.
    func testTheParsedRowsKeepTheirTableIndex() {
        let census = EventListWrite.census(
            cells: [grownList[2], grownList[0]], columns: eventColumns, declaredCount: 2
        )
        XCTAssertEqual(census.rows.map(\.index), [1])
    }

    /// At rest every row is drawn and the three counts are one count.
    func testASettledListCountsTheSameThreeWays() {
        let census = EventListWrite.census(
            cells: Array(grownList.prefix(2)), columns: eventColumns, declaredCount: 2
        )
        XCTAssertEqual(census.count, 2)
        XCTAssertEqual(census.rows.count, 2)
        XCTAssertTrue(census.isComplete)
        XCTAssertFalse(census.truncated)
    }

    /// A table that stopped publishing rows is a different failure and keeps
    /// its refusal: 30 rows of a 400-note region reads as a 30-note region.
    func testATruncatedTableIsStillTruncated() {
        let census = EventListWrite.census(
            cells: Array(grownList.prefix(2)), columns: eventColumns, declaredCount: 26
        )
        XCTAssertTrue(census.truncated)
    }

    /// With no `Number of Items` to go by, the published rows are the count.
    func testWithoutADeclaredCountThePublishedRowsAreTheCount() {
        let census = EventListWrite.census(
            cells: grownList, columns: eventColumns, declaredCount: nil
        )
        XCTAssertEqual(census.count, 3)
        XCTAssertFalse(census.truncated)
    }

    // MARK: - Did a neighbour move, or was it simply not read

    func testANeighbourThatReallyChangedIsSuspect() {
        let verdict = EventListWrite.neighbourVerdict(
            before: ["a", "b", "c"], after: ["a", "b", "z"], unreadBefore: 0, unreadAfter: 0
        )
        XCTAssertEqual(verdict.vanished, ["c"])
        XCTAssertEqual(verdict.appeared, ["z"])
        XCTAssertTrue(verdict.suspect)
    }

    /// The false alarm this exists to stop: the row Logic had not drawn was
    /// missing from the BEFORE read and present in the AFTER one, and the old
    /// set comparison called that "OTHER events changed as a side effect".
    func testARowThatWasSimplyNotReadIsNotASideEffect() {
        let verdict = EventListWrite.neighbourVerdict(
            before: ["a", "b"], after: ["a", "b", "c"], unreadBefore: 1, unreadAfter: 0
        )
        XCTAssertEqual(verdict.appeared, ["c"])
        XCTAssertFalse(verdict.suspect)
    }

    func testMoreChangesThanTheReadCanExcuseAreStillSuspect() {
        let verdict = EventListWrite.neighbourVerdict(
            before: ["a", "b"], after: ["a", "b", "c", "d"], unreadBefore: 1, unreadAfter: 0
        )
        XCTAssertTrue(verdict.suspect)
    }

    /// Two identical notes are two events, not one: the difference is a
    /// multiset difference, so losing one of a pair is still losing one.
    func testTwoIdenticalNeighboursAreCountedSeparately() {
        let verdict = EventListWrite.neighbourVerdict(
            before: ["a", "a"], after: ["a"], unreadBefore: 0, unreadAfter: 0
        )
        XCTAssertEqual(verdict.vanished, ["a"])
        XCTAssertTrue(verdict.suspect)
    }

    // MARK: - How many steps a move may take

    /// The budget was a flat 80, and Logic's own tick field runs 1–240: a
    /// legitimate move of more than 80 ticks stepped 80 times and then refused,
    /// at ~21 s of stepping to say no.
    func testAPositionMoveMayTakeAsManyStepsAsItIsFar() {
        XCTAssertGreaterThanOrEqual(EventListWrite.stepBudget(.position, from: 1, to: 240), 239)
        XCTAssertGreaterThanOrEqual(EventListWrite.stepBudget(.length, from: 240, to: 1), 239)
    }

    /// Pitch and velocity have the coarse gear (`AXIncrement` moves ten), so
    /// their budget is the ten-step count plus the remainder, not the distance.
    func testTheCoarseGearMakesAPitchMoveCheap() {
        XCTAssertEqual(EventListWrite.stepBudget(.pitch, from: 0, to: 127), 12 + 7 + 8)
        XCTAssertEqual(EventListWrite.stepBudget(.velocity, from: 65, to: 90), 2 + 5 + 8)
    }

    /// A move that is already there still gets enough slack for a stale read.
    func testEveryBudgetCarriesSlack() {
        XCTAssertEqual(EventListWrite.stepBudget(.pitch, from: 60, to: 60), 8)
    }

    func testTheBudgetIsCappedAgainstARunaway() {
        XCTAssertEqual(EventListWrite.stepBudget(.position, from: 1, to: 100_000), 320)
    }

    func testTheValueUnderAConvergeIsTheFieldItIsMoving() {
        let note = row(["", "", "62 3 1 1 ", "Note", "1", "D♯2", "98", "0 2 0 0"])
        XCTAssertEqual(EventListWrite.value(of: note, field: .position, segment: 3), 1)
        XCTAssertEqual(EventListWrite.value(of: note, field: .length, segment: 1), 2)
        XCTAssertEqual(EventListWrite.value(of: note, field: .pitch, segment: 0), 51)
        XCTAssertEqual(EventListWrite.value(of: note, field: .velocity, segment: 0), 98)
        XCTAssertNil(EventListWrite.value(of: note, field: .position, segment: 9))
    }

    // MARK: - What a call has to say before anything is selected

    /// `handleEditEvent` used to select the caller's region — exclusively,
    /// which clears every other selection and moves keyboard focus — and only
    /// then parse the arguments, so an `invalid_arguments` refusal had already
    /// changed the user's project. Every refusal below now happens in a type
    /// that has no way to reach Logic at all, which is what fixes the order:
    /// the handler cannot learn which region to select until this has parsed.
    private func refusal(_ arguments: [String: Any]) -> String? {
        do {
            _ = try EventEditRequest(arguments: arguments)
            return nil
        } catch {
            return (error as? LogicianError)?.errorDescription ?? "\(error)"
        }
    }

    func testEveryBadArgumentIsRefusedByAPureParse() {
        let track: [String: Any] = ["track_name": "Bas", "start_bar": 9]
        XCTAssertNotNil(refusal(track.merging(["action": "set"]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "sett", "bar": 11]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["bar": 11]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 0]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 11, "velocity": 200]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 11, "velocity": 0]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 11, "length": "a quarter"]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 11, "to_tick": 0]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(["action": "set", "bar": 11, "new_pitch": "H3"]) { $1 }))
        XCTAssertNotNil(refusal(track.merging(
            ["action": "set", "bar": 11, "expected_current_length": "0 1 0"]
        ) { $1 }))
        // A create with no pitch has nothing to make.
        XCTAssertNotNil(refusal(track.merging(["action": "create", "bar": 11]) { $1 }))
    }

    func testAGoodCallParsesIntoTheAddressAndTheChangeItAsksFor() throws {
        let request = try EventEditRequest(arguments: [
            "action": "set", "track_name": "Bas", "start_bar": 9, "region_name": "Inst 31",
            "bar": 11, "beat": 1, "pitch": "D♯2", "new_pitch": 52, "velocity": 90,
            "length": "0 0 2 228", "to_tick": 2
        ])
        XCTAssertEqual(request.action, "set")
        XCTAssertEqual(request.trackName, "Bas")
        XCTAssertEqual(request.regionName, "Inst 31")
        XCTAssertEqual(request.startBar, 9)
        XCTAssertEqual(request.address.bar, 11)
        XCTAssertEqual(request.address.beat, 1)
        XCTAssertEqual(request.address.pitch, 51)
        XCTAssertEqual(request.change.pitch, 52)
        XCTAssertEqual(request.change.velocity, 90)
        XCTAssertEqual(request.change.length, [0, 0, 2, 228])
        XCTAssertEqual(request.change.tick, 2)
    }

    /// The refusals name the argument and the spelling that would work — the
    /// whole reason they are worth keeping in one place.
    func testARefusalNamesWhatWouldHaveWorked() throws {
        let velocity = try XCTUnwrap(refusal(["action": "set", "bar": 11, "velocity": 200]))
        XCTAssertTrue(velocity.contains("1-127"), velocity)
        let length = try XCTUnwrap(refusal(["action": "set", "bar": 11, "length": "quarter"]))
        XCTAssertTrue(length.contains("0 1 0 0"), length)
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
