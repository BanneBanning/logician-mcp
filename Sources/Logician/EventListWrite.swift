import Foundation

// MARK: - The Event List's write grammar, as pure functions

/// One Event List row parsed out of Logic's own cell texts.
///
/// Deliberately built from the table's OWN column titles rather than from cell
/// positions, for the same reason the reader is (`ListEditorEntry`): the Event
/// tab's column set changes with what the list is showing, and a writer that
/// counted positions would edit the wrong cell the day Logic adds a column —
/// which, unlike a misreport, cannot be taken back.
struct EventRow: Equatable {
    /// The row's index in the table AS IT WAS READ. Not an identity: the table
    /// re-sorts on every position and pitch write (measured 2026-08-28).
    let index: Int
    /// bar, beat, division, tick — Logic's four position fields.
    let position: [Int]
    let status: String
    let channel: String
    /// Logic's `Num` cell verbatim: a note NAME (`D♯2`) on a note row, a
    /// controller number on a CC row.
    let numberText: String
    /// The note number behind `numberText`, when the row is a note and the name
    /// parsed. This is the number Logic's own slider carries on its AXValue.
    let pitch: Int?
    /// The velocity, from the `Val` cell's DISPLAYED text — never from the
    /// slider's AXValue, which is a packed field (see `AXEventEdit`).
    let velocity: Int?
    /// bars, beats, divisions, ticks.
    let length: [Int]
    let lengthText: String
    let positionText: String

    var isNote: Bool { status.localizedCaseInsensitiveContains("note") }

    /// What a refusal prints so the caller can see what it addressed.
    var describedBriefly: String {
        "\(EventListWrite.format(position)) \(status) \(numberText)"
            + " vel \(velocity.map(String.init) ?? "?") len \(lengthText)"
    }
}

/// Which single field a converge loop is currently moving. Every OTHER field
/// stays put while it does, and that is what makes the row findable again after
/// the table re-sorts.
enum EventField: String {
    case position, pitch, velocity, length
}

/// What the Event List holds, and how much of it a read could read.
///
/// MEASURED 2026-09-01 (profile §5, reproduced 2/2). When the list GROWS,
/// Logic publishes the new size in `Number of Items` and in `AXRows` at once —
/// and leaves the row it has not drawn yet with every cell empty but the
/// Status one: `["", "", "", "Note", "", "", "", ""]`. That row is a real
/// event; the delete that followed proved it, because the row missing from the
/// parsed set was the list's genuine last note. It simply has no text yet, and
/// it stays that way until the list is scrolled.
///
/// So: **an unrealised row is COUNTED and not READ**, and that is the one rule
/// this type exists to apply everywhere. The code it replaced had two counts —
/// the published row count for the declared-count cross-check and the parsed
/// array's length for every check after it — and they disagreed by exactly this
/// row: a `create` that had worked came back `verification_failed` "found the
/// list holds 25", with the note left sitting in the user's region, and a
/// `delete` that had worked came back "Requested 24, found 25".
struct EventCensus: Equatable {
    /// Every row that carried readable text, in table order. `index` is the
    /// row's index in the TABLE, so an unrealised row leaves a gap.
    let rows: [EventRow]
    /// How many rows Logic published.
    let published: Int
    /// What the list's own `Number of Items` says it holds, when it says.
    let declared: Int?

    /// THE count of events in the region: the list's own, cross-checked against
    /// the rows it published. Never the parsed array's length — that one is
    /// short by however many rows Logic has not drawn.
    var count: Int { declared ?? published }
    /// Rows that exist and could not be read.
    var unread: Int { max(0, published - rows.count) }
    var isComplete: Bool { unread == 0 }
    /// Logic's two counts disagreeing with EACH OTHER — a genuinely truncated
    /// table, which is a reason to refuse rather than to read on: a list that
    /// stops at row 30 of 400 reads as a thirty-note region.
    var truncated: Bool { declared.map { $0 != published } ?? false }
    /// What a refusal or a warning calls the rows it could not read. The
    /// wording lives in `UndrawnListRows` because the READERS say it too now
    /// (`ListEditorCensus`), and an agent should meet one sentence for one
    /// phenomenon whichever tool it came from.
    var unreadNote: String { UndrawnListRows.note(unread) }
}

enum EventListWrite {

    // MARK: Columns

    /// Where a column sits, by NAME. Nil when Logic does not publish it.
    static func columnIndex(_ columns: [String], _ names: [String]) -> Int? {
        for name in names {
            if let index = columns.firstIndex(where: {
                $0.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) { return index }
        }
        return nil
    }

    /// Is the Event tab showing a region's EVENTS, or the project's REGIONS?
    ///
    /// The tab has two levels (measured 2026-08-28): with a region open it
    /// publishes `L M Position Status Ch Num Val Length/Info`, and after its
    /// own `Leave Folder` button it publishes `L M Position Name Trk Length` —
    /// 55 rows, one per region, and NOT ONE of those cells carries a slider.
    /// A write addressed at that table would find nothing to write and would
    /// have to guess why; it refuses on the columns instead.
    static func isEventMode(columns: [String]) -> Bool {
        columnIndex(columns, ["Status"]) != nil
            && columnIndex(columns, ["Num"]) != nil
            && columnIndex(columns, ["Val"]) != nil
    }

    // MARK: Positions and lengths

    /// `"62 1 1 1 "` → `[62, 1, 1, 1]`. Logic pads with a trailing space and
    /// separates with single spaces; anything that is not four integers is
    /// nil rather than a partially parsed position.
    static func parse(segments text: String) -> [Int]? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        return numbers
    }

    static func format(_ segments: [Int]) -> String {
        segments.map(String.init).joined(separator: " ")
    }

    /// A comparable weight for "how far apart are these two positions", used to
    /// pick the row that MOVED when the table re-sorted under a position write.
    /// Not musical time — bar lengths vary — just a stable ordering metric.
    static func distance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        guard lhs.count == 4, rhs.count == 4 else { return Int.max }
        let weights = [1_000_000_000, 1_000_000, 1_000, 1]
        return zip(zip(lhs, rhs), weights).reduce(0) { total, pair in
            total + abs(pair.0.0 - pair.0.1) * pair.1
        }
    }

    // MARK: Note names

    private static let semitones = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]
    private static let sharpNames = [
        "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"
    ]

    /// `"D♯2"` → 51. Logic's Event List prints note names in the convention
    /// where **C3 is middle C = 60**, which is also what its own `Num` slider
    /// carries on its AXValue — verified live: the cell read `D♯2` while the
    /// slider read 51, and `A♯2` while it read 58.
    ///
    /// Accepts ASCII `#`/`b` as well as `♯`/`♭`, because an agent typing a
    /// pitch will not reach for the typographic ones.
    static func parseNoteName(_ text: String) -> Int? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let letter = rest.popFirst().map({ String($0).uppercased() }),
              var value = semitones[letter] else { return nil }
        while let next = rest.first, next == "#" || next == "♯" || next == "b" || next == "♭" {
            value += (next == "#" || next == "♯") ? 1 : -1
            rest = rest.dropFirst()
        }
        guard let octave = Int(rest) else { return nil }
        let number = (octave + 2) * 12 + value
        guard (0...127).contains(number) else { return nil }
        return number
    }

    static func noteName(_ number: Int) -> String {
        let octave = Int(floor(Double(number) / 12.0)) - 2
        return sharpNames[((number % 12) + 12) % 12] + String(octave)
    }

    /// A pitch argument as an agent may plausibly give it: `60`, `"60"` or
    /// `"D#2"`. A bare number is a MIDI note number, never a name.
    static func parsePitchArgument(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return (0...127).contains(number) ? number : nil }
        if let number = value as? Double, number == number.rounded() {
            return parsePitchArgument(Int(number))
        }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let number = Int(trimmed) { return parsePitchArgument(number) }
        return parseNoteName(trimmed)
    }

    // MARK: Rows

    static func row(index: Int, cells: [String], columns: [String]) -> EventRow? {
        func cell(_ names: [String]) -> String {
            guard let position = columnIndex(columns, names),
                  cells.indices.contains(position) else { return "" }
            return cells[position]
        }
        let positionText = cell(["Position"])
        guard let position = parse(segments: positionText) else { return nil }
        let status = cell(["Status"]).trimmingCharacters(in: .whitespaces)
        let numberText = cell(["Num"]).trimmingCharacters(in: .whitespaces)
        let lengthText = cell(["Length/Info", "Length"])
        let velocityText = cell(["Val"]).trimmingCharacters(in: .whitespaces)
        // A velocity outside 0-127 is not a velocity. Same rule as the reader's:
        // the `Val` slider's AXValue is a packed 32-bit field, and if a Logic
        // version ever routed THAT into the cell text, writing against it would
        // be worse than refusing.
        let velocity = Int(velocityText).flatMap { (0...127).contains($0) ? $0 : nil }
        return EventRow(
            index: index,
            position: position,
            status: status,
            channel: cell(["Ch"]).trimmingCharacters(in: .whitespaces),
            numberText: numberText,
            pitch: status.localizedCaseInsensitiveContains("note")
                ? parseNoteName(numberText) : nil,
            velocity: velocity,
            length: parse(segments: lengthText) ?? [],
            lengthText: lengthText.trimmingCharacters(in: .whitespaces),
            positionText: positionText.trimmingCharacters(in: .whitespaces)
        )
    }

    static func rows(cells: [[String]], columns: [String]) -> [EventRow] {
        cells.enumerated().compactMap { row(index: $0.offset, cells: $0.element, columns: columns) }
    }

    /// The value one converge loop is moving, out of the row it is moving it in.
    static func value(of row: EventRow, field: EventField, segment: Int) -> Int? {
        switch field {
        case .position: return row.position.indices.contains(segment) ? row.position[segment] : nil
        case .length: return row.length.indices.contains(segment) ? row.length[segment] : nil
        case .pitch: return row.pitch
        case .velocity: return row.velocity
        }
    }

    // MARK: The census — ONE count of the list, and what could be read of it

    static func census(cells: [[String]], columns: [String], declaredCount: Int?) -> EventCensus {
        EventCensus(
            rows: rows(cells: cells, columns: columns),
            published: cells.count,
            declared: declaredCount
        )
    }

    /// Did the write disturb a neighbour, or did the read simply not see one?
    ///
    /// The multiset difference both ways, plus the judgement a partial read
    /// forces: a row Logic published and had not drawn reads as nothing at all,
    /// so at most `unreadAfter` of the vanished are unread rather than gone,
    /// and at most `unreadBefore` of the appeared were there all along. Beyond
    /// that slack the difference is real and the caller must be told.
    static func neighbourVerdict(
        before: [String], after: [String], unreadBefore: Int, unreadAfter: Int
    ) -> (vanished: [String], appeared: [String], suspect: Bool) {
        func missing(_ lhs: [String], from rhs: [String]) -> [String] {
            var remaining = rhs
            var absent: [String] = []
            for row in lhs {
                if let hit = remaining.firstIndex(of: row) {
                    remaining.remove(at: hit)
                } else {
                    absent.append(row)
                }
            }
            return absent.sorted()
        }
        let vanished = missing(before, from: after)
        let appeared = missing(after, from: before)
        return (
            vanished, appeared,
            vanished.count > unreadAfter || appeared.count > unreadBefore
        )
    }

    /// How many stepper writes a move of this size may take.
    ///
    /// The budget used to be a flat 80 per field, which **could not reach half
    /// of Logic's own tick field** (1–240): a legitimate `to_tick` move of more
    /// than 80 ticks stepped 80 times and then refused — at the profile's
    /// measured cost, ~21 s spent to say no. Every cell is a one-unit stepper
    /// (ten units on `AXIncrement`, and only pitch and velocity have that
    /// gear), so the number of writes a move needs is not a constant at all:
    /// it is the distance. This is that distance plus eight, for the rollovers
    /// a position write can take and for a read that comes back stale.
    ///
    /// Position and length are budgeted for ONE unit per write even though
    /// their steppers do honour the ten-unit coarse gear (measured 2026-09-02):
    /// the budget is the safety net, and a net sized for the fast path would
    /// refuse a legitimate move the day a Logic version stops answering
    /// `AXIncrement` on one of those cells. Pitch and velocity keep the coarse
    /// count because their gear has been measured since 2026-08-28 and their
    /// whole range is 127 wide.
    ///
    /// The cap is a runaway guard, not a limit anything legitimate meets; the
    /// converge loop's wall-clock deadline is the other half of it.
    static func stepBudget(_ field: EventField, from current: Int, to target: Int) -> Int {
        let distance = abs(target - current)
        let coarse = field == .pitch || field == .velocity
        let writes = coarse ? distance / 10 + distance % 10 : distance
        return min(writes + 8, 320)
    }

    // MARK: Addressing

    enum Match: Equatable {
        case one(EventRow)
        case none
        case ambiguous([EventRow])
    }

    /// Finds the ONE row a caller means.
    ///
    /// A note is addressed by its position and its pitch, and both halves are
    /// needed: a chord publishes three rows on the same position (measured —
    /// `62 1 1 1` held D♯2, G2 and A♯2), so a position alone is not an address.
    /// `beat`, `division` and `tick` narrow further when they are given, and
    /// two rows that are still indistinguishable are AMBIGUOUS rather than
    /// first-wins — editing the wrong note is silent damage.
    static func match(
        rows: [EventRow], bar: Int, beat: Int?, division: Int?, tick: Int?, pitch: Int?
    ) -> Match {
        let hits = rows.filter { row in
            guard row.position.count == 4, row.position[0] == bar else { return false }
            if let beat, row.position[1] != beat { return false }
            if let division, row.position[2] != division { return false }
            if let tick, row.position[3] != tick { return false }
            if let pitch, row.pitch != pitch { return false }
            return true
        }
        if hits.isEmpty { return .none }
        if hits.count > 1 { return .ambiguous(hits) }
        return .one(hits[0])
    }

    /// Is `row` still recognisably the row that `previous` was, given that a
    /// converge is moving exactly ONE field of it?
    ///
    /// This is the sanity check on Logic's own selection, which is what the
    /// write loop tracks a re-sorting row by. It is NOT an identity search, and
    /// the difference is a bug that was written and then measured: the first
    /// version re-found the row by holding every other field fixed and taking
    /// the CLOSEST remaining candidate, which is fine until the region holds a
    /// chord of rows identical but for pitch. Transposing `F2` (53) up an
    /// octave took the coarse ten-step gear to 63, and "closest to 53" among
    /// {57, 60, 63} was the NEIGHBOUR at 57 — so the loop kept transposing the
    /// wrong note and left three notes reading C3, C3, D♯3 where F2, A2, C3
    /// had been. Nearness is not identity; the selection is.
    static func agrees(_ row: EventRow, with previous: EventRow, exceptFor field: EventField) -> Bool {
        guard row.status == previous.status else { return false }
        if field != .position, row.position != previous.position { return false }
        if field != .pitch, row.pitch != previous.pitch { return false }
        if field != .velocity, row.velocity != previous.velocity { return false }
        if field != .length, row.length != previous.length { return false }
        return true
    }

    /// The target position a `set` produces: the caller's segments where they
    /// were given, the row's own where they were not.
    ///
    /// Leaving the unspecified segments ALONE is the deliberate choice. "Move
    /// this note one beat later" should not also quantize it: a note recorded
    /// at `62 1 3 120` and moved to beat 3 lands on `62 3 3 120`, keeping the
    /// feel it was played with. A caller who wants it on the grid says so by
    /// passing division and tick.
    static func targetPosition(
        current: [Int], bar: Int?, beat: Int?, division: Int?, tick: Int?
    ) -> [Int] {
        guard current.count == 4 else { return current }
        return [
            bar ?? current[0], beat ?? current[1],
            division ?? current[2], tick ?? current[3]
        ]
    }
}

// MARK: - One logic_edit_event call, parsed and validated

/// Everything `logic_edit_event` refuses on, in a form that CANNOT touch Logic.
///
/// It is a type rather than a run of `guard`s in the handler because of the
/// order the handler used to run in: it selected the caller's region FIRST —
/// `exclusive: true`, which clears every other region's selection and moves
/// keyboard focus — and only then looked at whether the arguments made sense.
/// A call with a velocity of 200, a misspelled length or no bar therefore
/// refused `invalid_arguments` **after** changing the user's selection, which
/// is the same family as a refusal that claims `restored: true`. Validation
/// that has no way to reach the UI makes that order impossible to get wrong:
/// the handler cannot know which region to select until this has parsed.
struct EventEditRequest {
    let action: String
    let trackName: String?
    /// The ROW, when several tracks carry `trackName`. Cross-checked against
    /// the name by `resolveRegionRow`, so a stale pair refuses rather than
    /// editing a namesake's region.
    let trackNumber: Int?
    let regionName: String?
    let startBar: Int?
    let address: EventAddress
    let change: EventChange

    init(arguments: [String: Any]) throws {
        guard let action = arguments["action"] as? String, !action.isEmpty else {
            throw LogicianError.invalidArguments("missing non-empty string: action")
        }
        guard ["set", "create", "delete"].contains(action) else {
            throw LogicianError.invalidArguments("action must be 'set', 'create' or 'delete'")
        }
        self.action = action
        trackName = arguments["track_name"] as? String
        trackNumber = arguments["track_number"] as? Int
        // A row number with no name beside it is refused rather than ignored:
        // the number's whole value is that it is CROSS-CHECKED against the
        // name, and a call that passed one and had it silently dropped would
        // edit whatever region happened to be selected while believing it had
        // addressed row 26.
        guard trackNumber == nil || trackName != nil else {
            throw LogicianError.invalidArguments(
                "track_number needs track_name as well — the two are cross-checked against each"
                    + " other, which is the whole point of passing the number. Nothing was read"
                    + " or written."
            )
        }
        regionName = arguments["region_name"] as? String
        startBar = arguments["start_bar"] as? Int

        guard let bar = arguments["bar"] as? Int, bar >= 1 else {
            throw LogicianError.invalidArguments("bar is required and must be 1 or greater")
        }
        func segment(_ key: String) throws -> Int? {
            guard let value = arguments[key] else { return nil }
            guard let number = value as? Int, number >= 1 else {
                throw LogicianError.invalidArguments("\(key) must be a whole number, 1 or greater")
            }
            return number
        }
        func pitch(_ key: String) throws -> Int? {
            guard let value = arguments[key] else { return nil }
            guard let parsed = EventListWrite.parsePitchArgument(value) else {
                throw LogicianError.invalidArguments(
                    "\(key) must be a MIDI note number 0-127 or a note name in Logic's own"
                        + " spelling, where C3 is middle C (60): 'D#2', 'A♯2', 'C3'"
                )
            }
            return parsed
        }
        var velocity: Int?
        if let value = arguments["velocity"] {
            guard let number = value as? Int, (1...127).contains(number) else {
                throw LogicianError.invalidArguments(
                    "velocity must be 1-127 (0 is a note-off, not a quiet note)"
                )
            }
            velocity = number
        }
        var length: [Int]?
        if let value = arguments["length"] {
            guard let text = value as? String,
                  let parsed = EventListWrite.parse(segments: text),
                  parsed.allSatisfy({ $0 >= 0 }) else {
                throw LogicianError.invalidArguments(
                    "length must be Logic's own four-field spelling, 'bars beats divisions ticks'"
                        + " — the same text logic_list_events prints in the Length/Info column."
                        + " A quarter note is '0 1 0 0'."
                )
            }
            length = parsed
        }
        var expectedLength: [Int]?
        if let value = arguments["expected_current_length"] {
            guard let text = value as? String, let parsed = EventListWrite.parse(segments: text) else {
                throw LogicianError.invalidArguments(
                    "expected_current_length must be Logic's 'bars beats divisions ticks' spelling"
                )
            }
            expectedLength = parsed
        }
        address = EventAddress(
            bar: bar,
            beat: try segment("beat"),
            division: try segment("division"),
            tick: try segment("tick"),
            pitch: try pitch("pitch")
        )
        change = EventChange(
            pitch: try pitch("new_pitch"),
            velocity: velocity,
            bar: try segment("to_bar"),
            beat: try segment("to_beat"),
            division: try segment("to_division"),
            tick: try segment("to_tick"),
            length: length,
            expectedVelocity: arguments["expected_current_velocity"] as? Int,
            expectedLength: expectedLength
        )
        if action == "create", address.pitch == nil, change.pitch == nil {
            throw LogicianError.invalidArguments("action 'create' requires a pitch")
        }
    }
}
