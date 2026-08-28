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
