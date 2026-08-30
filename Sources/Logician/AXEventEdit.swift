import AppKit
import ApplicationServices
import Foundation

// MARK: - Writing single MIDI events: the Event List's edit, create and delete

/// Where a caller says the event IS.
struct EventAddress {
    let bar: Int
    let beat: Int?
    let division: Int?
    let tick: Int?
    let pitch: Int?
}

/// What a caller wants it to BE. Every field is optional and an omitted one is
/// left exactly as it stands — including the sub-beat position, so moving a
/// note to another beat does not quietly quantize it.
struct EventChange {
    let pitch: Int?
    let velocity: Int?
    let bar: Int?
    let beat: Int?
    let division: Int?
    let tick: Int?
    let length: [Int]?
    let expectedVelocity: Int?
    let expectedLength: [Int]?
}

extension LogicAccessibility {

    /// The sliders inside one Event List cell.
    ///
    /// They are NOT direct children of the cell — the same trap the Tempo List
    /// sprang on 2026-08-28, where a `children(of:)` filter found zero steppers
    /// on a row that had four. They sit one level further down, beside the
    /// `AXGroup` that carries the cell's text.
    ///
    /// Unlike the Tempo List's, these are published whether the row is SELECTED
    /// or not (measured 2026-08-28: a row with `AXSelected = 0` still offered
    /// four position and four length steppers), so no write here has to select
    /// a row first — the write does that by itself.
    func eventCellSliders(_ cell: AXUIElement) -> [AXUIElement] {
        descendants(of: cell, maximumDepth: 3).filter {
            stringAttribute($0, kAXRoleAttribute as String) == kAXSliderRole as String
        }
    }

    /// The live row element and the parsed rows of the Event tab, right now.
    private func eventTable(
        in window: AXUIElement
    ) -> (table: ListEditorTable, rows: [EventRow])? {
        let (table, _) = readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.event, in: window)
        guard let table else { return nil }
        return (table, EventListWrite.rows(cells: table.rows.map(\.cells), columns: table.columns))
    }

    /// The ONE row Logic currently has selected in the Event List, with its
    /// live element and its parsed content.
    ///
    /// This is the write loop's identity for a row, and it has to be: the table
    /// re-sorts on every position and pitch write, so the index is not one, and
    /// a chord of otherwise identical rows means the CONTENT is not one either.
    /// Logic selects the row a write landed on (measured 2026-08-28: a write to
    /// a row whose `AXSelected` was 0 came back with it 1), and it selects the
    /// row `Create new Event` just made — so the selection follows the edit
    /// through every re-sort. Nil when zero or more than one row is selected,
    /// which is a reason to stop rather than to guess.
    private func selectedEventRow(
        in window: AXUIElement
    ) -> (table: ListEditorTable, live: ListEditorRow, parsed: EventRow)? {
        guard let (table, rows) = eventTable(in: window) else { return nil }
        let selected = table.rows.filter {
            stringAttribute($0.element, kAXSelectedAttribute as String) == "1"
        }
        guard selected.count == 1, let live = selected.first,
              let parsed = rows.first(where: { $0.index == live.index }) else { return nil }
        return (table, live, parsed)
    }

    /// Steps ONE field of ONE event row until it reaches `target`.
    ///
    /// THE MECHANISM, measured live 2026-08-28 (Logic Pro 12.3.1) and the whole
    /// reason this is a loop rather than a write:
    ///
    /// - **Every editable cell is a STEPPER**, whatever its published range
    ///   says. The `Num` slider honestly reports `min 0 max 127` and still
    ///   moves exactly ONE semitone per `AXUIElementSetAttributeValue`: written
    ///   62 while it held 51 (`D♯2`) it landed on 52 (`E2`).
    /// - **`AXIncrement`/`AXDecrement` move TEN**, not one — on pitch (D3 → C4
    ///   → D3) and on velocity (97 → 107) alike. That is the coarse gear this
    ///   loop shifts into while it is more than ten away, and it is why a
    ///   velocity walk from 40 to 120 costs ten writes instead of eighty.
    /// - **The `Val` slider's AXValue is NOT the velocity.** It is a packed
    ///   32-bit field (`0xC5140000` at velocity 98) whose top byte tracks
    ///   `2 × velocity + 1`, and the displayed number lives on
    ///   AXValueDescription. So a velocity write cannot name its target at all:
    ///   the direction is all Logic reads, and this writes the slider's MAXIMUM
    ///   to go up and its MINIMUM to go down. (Writing `100` into it while it
    ///   held `3306422272` moved the velocity DOWN one, from 98 to 97 — a
    ///   "set velocity to 100" that decrements is exactly the shape of bug this
    ///   design exists to make impossible.)
    /// - **The element goes STALE after each write** (it reads back empty) and
    ///   **the table RE-SORTS** — rows are ordered by position and then by
    ///   pitch, so raising a note's pitch moves its row. The cursor is
    ///   therefore re-found from a fresh read on every single step, by holding
    ///   every other field fixed and taking the nearest candidate.
    ///
    /// Returns nil on success, or the reason it stopped.
    private func convergeEventField(
        _ field: EventField,
        segment: Int,
        target: Int,
        window: AXUIElement,
        columns: [String],
        cursor: inout EventRow,
        steps: inout [String],
        budget: Int = 80
    ) -> String? {
        func value(of row: EventRow) -> Int? {
            switch field {
            case .position: return row.position.indices.contains(segment) ? row.position[segment] : nil
            case .length: return row.length.indices.contains(segment) ? row.length[segment] : nil
            case .pitch: return row.pitch
            case .velocity: return row.velocity
            }
        }
        var writes = 0
        var stalled = 0
        var previous: Int?
        while writes <= budget {
            guard let found = selectedEventRow(in: window) else {
                return "the row being edited (\(cursor.describedBriefly)) is no longer the one"
                    + " Logic has selected in the Event List, so this write stopped after"
                    + " \(writes) write(s) rather than risk editing another note"
            }
            guard EventListWrite.agrees(found.parsed, with: cursor, exceptFor: field) else {
                return "the selected Event List row changed in more than the \(field.rawValue)"
                    + " this write is moving (was \(cursor.describedBriefly), is now"
                    + " \(found.parsed.describedBriefly)) — stopped after \(writes) write(s)"
            }
            cursor = found.parsed
            guard let current = value(of: cursor) else {
                return "Logic's \(field.rawValue) cell published no readable value"
            }
            if current == target {
                if writes > 0 {
                    steps.append("\(field.rawValue)\(field == .position || field == .length ? "[\(segment)]" : "")"
                                 + " reached \(target) in \(writes) write(s)")
                }
                return nil
            }
            // A stepper that answers a write with nothing is at a limit Logic
            // will not pass; hammering it wastes the budget instead of saying so.
            if current == previous {
                stalled += 1
                if stalled > 4 {
                    return "Logic's \(field.rawValue) stepper stopped at \(current) and will not"
                        + " move to \(target)"
                }
            } else {
                stalled = 0
            }
            previous = current
            guard writes < budget else { break }
            let cells = children(of: found.live.element)
            let columnNames: [String]
            switch field {
            case .position: columnNames = ["Position"]
            case .length: columnNames = ["Length/Info", "Length"]
            case .pitch: columnNames = ["Num"]
            case .velocity: columnNames = ["Val"]
            }
            guard let column = EventListWrite.columnIndex(columns, columnNames),
                  cells.indices.contains(column) else {
                return "the Event List publishes no \(columnNames[0]) column to write"
            }
            let sliders = eventCellSliders(cells[column])
            let index = (field == .position || field == .length) ? segment : 0
            guard sliders.indices.contains(index) else {
                return "the \(columnNames[0]) cell published \(sliders.count) stepper(s), not the"
                    + " \(index + 1) this write needs"
            }
            let slider = sliders[index]
            let delta = target - current
            if abs(delta) >= 10, field == .pitch || field == .velocity {
                // The coarse gear: one action, ten units.
                _ = AXUIElementPerformAction(
                    slider,
                    (delta > 0 ? kAXIncrementAction : kAXDecrementAction) as CFString
                )
            } else if field == .velocity {
                // The direction is all Logic reads off this slider, so the
                // written number is its own end of the range.
                let bound = stringAttribute(
                    slider, (delta > 0 ? kAXMaxValueAttribute : kAXMinValueAttribute) as String
                )
                _ = AXUIElementSetAttributeValue(
                    slider, kAXValueAttribute as CFString, (Int(bound) ?? (delta > 0 ? 1 : 0)) as CFNumber
                )
            } else {
                _ = AXUIElementSetAttributeValue(
                    slider, kAXValueAttribute as CFString, target as CFNumber
                )
            }
            writes += 1
            Thread.sleep(forTimeInterval: 0.09)
        }
        return "the \(field.rawValue) write did not reach \(target) within \(budget) steps"
    }

    /// Steps a whole position (or length) vector.
    private func convergeEventVector(
        _ field: EventField,
        target: [Int],
        window: AXUIElement,
        columns: [String],
        cursor: inout EventRow,
        steps: inout [String]
    ) -> String? {
        func current(_ row: EventRow) -> [Int] { field == .position ? row.position : row.length }
        // Up to three passes: stepping the BAR can change which beat exists
        // (a 5/4 bar's beat 5 does not survive a move into a 4/4 one), and
        // stepping the BEAT past the end of its bar ROLLS OVER into the next
        // one — measured: writing 9 into the beat of a 5/4 bar walked
        // 3 → 4 → 5 → next bar 1 → 2. Re-reading the whole vector each pass is
        // what keeps a rollover from being reported as a success.
        for _ in 0..<3 {
            if current(cursor) == target { return nil }
            for segment in 0..<4 where current(cursor).indices.contains(segment) {
                guard current(cursor)[segment] != target[segment] else { continue }
                if let problem = convergeEventField(
                    field, segment: segment, target: target[segment], window: window,
                    columns: columns, cursor: &cursor, steps: &steps
                ) { return problem }
            }
        }
        guard current(cursor) == target else {
            return "the \(field.rawValue) settled at \(EventListWrite.format(current(cursor)))"
                + " instead of \(EventListWrite.format(target)) — Logic rolled it over, which"
                + " happens when the requested beat does not exist in that bar's meter"
        }
        return nil
    }

    /// A fingerprint of every row EXCEPT the one being edited, so a write that
    /// disturbed a neighbour is caught rather than described.
    private func otherRows(_ rows: [EventRow], excluding row: EventRow) -> [String] {
        var remaining = rows
        if let position = remaining.firstIndex(where: { $0.index == row.index }) {
            remaining.remove(at: position)
        }
        return remaining.map(\.describedBriefly).sorted()
    }

    /// Edit, create or delete ONE MIDI event through Logic's Event List.
    ///
    /// The whole write grammar is documented on `convergeEventField`; the
    /// choreography here is the honest part around it. Every path re-reads the
    /// list afterwards and proves three things: the event count moved the way
    /// the action says it should, the addressed event now reads the way it was
    /// asked to, and **every other event in the region is untouched**.
    func editEvent(
        action: String, address: EventAddress, change: EventChange
    ) throws -> [String: Any] {
        guard ["set", "create", "delete"].contains(action) else {
            throw LogicianError.invalidArguments("action must be 'set', 'create' or 'delete'")
        }
        var steps: [String] = []

        // `Create new Event` places the note AT THE PLAYHEAD (measured: parked
        // at bar 63 beat 1 it landed on `63 1 1 1`, and at bar 66 on
        // `66 1 1 1`), so the playhead is parked before the pane is opened.
        var playhead: [String: Any]?
        if action == "create" {
            playhead = try setPlayhead(barNumber: address.bar, beat: address.beat ?? 1)
            steps.append("playhead parked at bar \(address.bar) beat \(address.beat ?? 1)")
        }

        let outcome = withListEditorsTab(named: LogicUIStrings.Element.ListEditorTab.event) { window -> Result<[String: Any], LogicianError> in
            self.runEventEdit(
                window: window, action: action, address: address, change: change, steps: &steps
            )
        }
        if let failure = outcome.failure {
            throw LogicianError.preconditionUnmet(failure.reason)
        }
        guard let result = outcome.value else {
            throw LogicianError.preconditionUnmet("the Event tab did not answer")
        }
        switch result {
        case .failure(let error): throw error
        case .success(var payload):
            payload["steps"] = steps
            if let playhead { payload["playhead"] = playhead }
            return payload
        }
    }

    // swiftlint:disable:next function_body_length
    private func runEventEdit(
        window: AXUIElement, action: String, address: EventAddress, change: EventChange,
        steps: inout [String]
    ) -> Result<[String: Any], LogicianError> {
        guard let (table, before) = eventTable(in: window) else {
            return .failure(.preconditionUnmet("the Event tab published no table of rows"))
        }
        // Mode first, because the other level of this same tab looks like a
        // perfectly good table and holds no notes at all.
        guard EventListWrite.isEventMode(columns: table.columns) else {
            return .failure(.preconditionUnmet(
                "the Event List is showing the project's REGIONS, not a region's events"
                    + " (columns: \(table.columns.joined(separator: ", "))). Nothing here is a MIDI"
                    + " event and none of these cells is editable. Select a region first —"
                    + " pass track_name (plus region_name and/or start_bar), or call"
                    + " logic_select_region — and read it back with logic_list_events."
            ))
        }
        if let declared = table.declaredCount, declared != table.rows.count {
            return .failure(.preconditionUnmet(
                "the Event List published \(table.rows.count) row(s) but says it holds \(declared)."
                    + " A partially realised table would be edited at the wrong row, so no write"
                    + " was made."
            ))
        }
        let columns = table.columns

        var payload: [String: Any] = [
            "action": action,
            "events_before": before.count,
            "columns": columns
        ]

        // MARK: create
        if action == "create" {
            if case .one(let clash) = EventListWrite.match(
                rows: before, bar: address.bar, beat: address.beat, division: address.division,
                tick: address.tick, pitch: change.pitch ?? address.pitch
            ) {
                return .failure(.preconditionUnmet(
                    "an event is already at that position and pitch (\(clash.describedBriefly))."
                        + " Two identical notes cannot be told apart by this tool afterwards, so"
                        + " the duplicate is refused; use action 'set' to change the one that is"
                        + " there."
                ))
            }
            guard let button = firstDescendant(
                of: table.group, maximumDepth: AXDepth.listEditorTable,
                where: {
                    self.stringAttribute($0, kAXDescriptionAttribute as String)
                        == LogicUIStrings.Element.createNewEvent
                }
            ) else {
                return .failure(.writeFailed("the Event tab publishes no 'Create new Event' button"))
            }
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                return .failure(.writeFailed("'Create new Event' could not be pressed"))
            }
            Thread.sleep(forTimeInterval: 0.8)
            guard let (afterCreate, createdRows) = eventTable(in: window) else {
                return .failure(.verificationFailed(
                    requested: "a new event", actual: "the Event List could not be re-read",
                    restored: false
                ))
            }
            guard createdRows.count == before.count + 1 else {
                return .failure(.verificationFailed(
                    requested: "\(before.count + 1) events after 'Create new Event'",
                    actual: "the list holds \(createdRows.count)", restored: false
                ))
            }
            // Logic SELECTS the row it just made, which is how it is told apart
            // from an identical neighbour.
            guard let freshIndex = afterCreate.rows.firstIndex(where: {
                self.stringAttribute($0.element, kAXSelectedAttribute as String) == "1"
            }), let created = createdRows.first(where: { $0.index == freshIndex }) else {
                return .failure(.verificationFailed(
                    requested: "the newly created row", actual: "no row came back selected",
                    restored: false
                ))
            }
            steps.append("created at '\(created.positionText)' as \(created.numberText)"
                         + " vel \(created.velocity.map(String.init) ?? "?") len \(created.lengthText)")
            var cursor = created
            let target = EventListWrite.targetPosition(
                current: created.position, bar: address.bar, beat: address.beat ?? 1,
                division: address.division ?? 1, tick: address.tick ?? 1
            )
            var problem = convergeEventVector(
                .position, target: target, window: window, columns: columns,
                cursor: &cursor, steps: &steps
            )
            if problem == nil, let pitch = change.pitch ?? address.pitch {
                problem = convergeEventField(
                    .pitch, segment: 0, target: pitch, window: window, columns: columns,
                    cursor: &cursor, steps: &steps
                )
            }
            if problem == nil, let velocity = change.velocity {
                problem = convergeEventField(
                    .velocity, segment: 0, target: velocity, window: window, columns: columns,
                    cursor: &cursor, steps: &steps
                )
            }
            if problem == nil, let length = change.length {
                problem = convergeEventVector(
                    .length, target: length, window: window, columns: columns,
                    cursor: &cursor, steps: &steps
                )
            }
            if let problem {
                // Take our own mess back out rather than leaving a note nobody
                // asked for in the user's region. No blind Undo is ever fired.
                var removed = false
                if let stranded = selectedEventRow(in: window) {
                    removed = performListEditorRowDelete(stranded.live)
                    Thread.sleep(forTimeInterval: 0.5)
                }
                return .failure(.writeFailed(
                    problem + ". The created event was "
                        + (removed ? "removed again" : "LEFT IN THE REGION at '\(cursor.positionText)'"
                           + " — delete it with action 'delete'")
                ))
            }
            return verify(
                window: window, action: action, before: before, editedBefore: nil,
                expected: cursor, payload: &payload
            )
        }

        // MARK: address an existing event
        let match = EventListWrite.match(
            rows: before, bar: address.bar, beat: address.beat, division: address.division,
            tick: address.tick, pitch: address.pitch
        )
        let target: EventRow
        switch match {
        case .none:
            return .failure(.preconditionUnmet(
                "no event in this region sits at bar \(address.bar)"
                    + (address.beat.map { " beat \($0)" } ?? "")
                    + (address.pitch.map { " with pitch \(EventListWrite.noteName($0))" } ?? "")
                    + ". The region holds: "
                    + before.prefix(40).map(\.describedBriefly).joined(separator: "; ")
                    + (before.count > 40 ? " …" : "")
            ))
        case .ambiguous(let candidates):
            return .failure(.preconditionUnmet(
                "\(candidates.count) events match that address and editing the wrong one is silent"
                    + " damage, so nothing was written. Candidates: "
                    + candidates.map(\.describedBriefly).joined(separator: "; ")
                    + ". Narrow it with pitch, beat, division and tick."
            ))
        case .one(let row):
            target = row
        }
        guard target.isNote else {
            return .failure(.preconditionUnmet(
                "the event at that address is a '\(target.status)', not a Note."
                    + " Logic's Num and Val columns carry a controller number and value on such a"
                    + " row, not a pitch and a velocity, and this tool only writes notes."
            ))
        }
        payload["addressed"] = target.describedBriefly

        // Compare-and-set, before anything is pressed.
        if let expected = change.expectedVelocity, target.velocity != expected {
            return .failure(.currentValueMismatch(
                expected: "velocity \(expected)",
                actual: "velocity \(target.velocity.map(String.init) ?? "unreadable")"
            ))
        }
        if let expected = change.expectedLength, target.length != expected {
            return .failure(.currentValueMismatch(
                expected: "length \(EventListWrite.format(expected))", actual: "length \(target.lengthText)"
            ))
        }

        // MARK: delete
        if action == "delete" {
            guard table.rows.indices.contains(target.index) else {
                return .failure(.writeFailed("the addressed row is no longer published"))
            }
            selectListEditorRow(table.rows[target.index], in: table)
            Thread.sleep(forTimeInterval: 0.3)
            guard performListEditorRowDelete(table.rows[target.index]) else {
                return .failure(.writeFailed(
                    "the row offers no Delete action this server could perform"
                ))
            }
            steps.append("row deleted")
            Thread.sleep(forTimeInterval: 0.6)
            return verify(
                window: window, action: action, before: before, editedBefore: target,
                expected: nil, payload: &payload
            )
        }

        // MARK: set
        let wantedPosition = EventListWrite.targetPosition(
            current: target.position, bar: change.bar, beat: change.beat,
            division: change.division, tick: change.tick
        )
        let wantedPitch = change.pitch ?? target.pitch
        let wantedVelocity = change.velocity ?? target.velocity
        let wantedLength = change.length ?? target.length
        guard change.pitch != nil || change.velocity != nil || change.length != nil
                || wantedPosition != target.position else {
            return .failure(.invalidArguments(
                "action 'set' needs something to write: new_pitch, velocity, length, or a"
                    + " to_bar/to_beat/to_division/to_tick move"
            ))
        }
        if wantedPosition == target.position, wantedPitch == target.pitch,
           wantedVelocity == target.velocity, wantedLength == target.length {
            payload["success"] = true
            payload["verified"] = true
            payload["state"] = "already_set"
            payload["event"] = describe(target)
            payload["events_after"] = before.count
            payload["note"] = "The event already reads exactly that; nothing was pressed."
            return .success(payload)
        }

        // Hand the row to Logic's own selection before touching a stepper: the
        // selection is what the converge loop tracks the row by through every
        // re-sort, and a chord of otherwise identical rows has no other
        // identity (see `EventListWrite.agrees`).
        guard table.rows.indices.contains(target.index) else {
            return .failure(.writeFailed("the addressed row is no longer published"))
        }
        selectListEditorRow(table.rows[target.index], in: table)
        Thread.sleep(forTimeInterval: 0.35)
        guard let anchored = selectedEventRow(in: window),
              anchored.parsed.describedBriefly == target.describedBriefly else {
            return .failure(.writeFailed(
                "the addressed event could not be given Logic's selection, and this write does not"
                    + " start without it: the Event List re-sorts under every write and the"
                    + " selection is the only thing that follows the right row through it"
            ))
        }
        var cursor = anchored.parsed
        var problem: String?
        // Pitch first, then velocity and length, and the position LAST: a
        // position write is the one that can roll into a neighbouring bar, and
        // doing it last means the cheap fields are already banked if it does.
        if let pitch = change.pitch, pitch != cursor.pitch {
            problem = convergeEventField(
                .pitch, segment: 0, target: pitch, window: window, columns: columns,
                cursor: &cursor, steps: &steps
            )
        }
        if problem == nil, let velocity = change.velocity, velocity != cursor.velocity {
            problem = convergeEventField(
                .velocity, segment: 0, target: velocity, window: window, columns: columns,
                cursor: &cursor, steps: &steps
            )
        }
        if problem == nil, let length = change.length, length != cursor.length {
            problem = convergeEventVector(
                .length, target: length, window: window, columns: columns,
                cursor: &cursor, steps: &steps
            )
        }
        if problem == nil, wantedPosition != cursor.position {
            problem = convergeEventVector(
                .position, target: wantedPosition, window: window, columns: columns,
                cursor: &cursor, steps: &steps
            )
        }
        if let problem {
            // A half-landed edit is reported as a failure WITH what did land,
            // because the caller's next move depends on knowing it.
            return .failure(.verificationFailed(
                requested: "\(EventListWrite.format(wantedPosition)) \(wantedPitch.map(EventListWrite.noteName) ?? "?")"
                    + " vel \(wantedVelocity.map(String.init) ?? "?")",
                actual: problem + ". The event now reads \(cursor.describedBriefly)",
                restored: false
            ))
        }
        return verify(
            window: window, action: action, before: before, editedBefore: target,
            expected: cursor, payload: &payload
        )
    }

    /// The proof, for all three actions: the count moved as the action says,
    /// the event reads what was asked, and every OTHER event is where it was.
    private func verify(
        window: AXUIElement, action: String, before: [EventRow], editedBefore: EventRow?,
        expected: EventRow?, payload: inout [String: Any]
    ) -> Result<[String: Any], LogicianError> {
        Thread.sleep(forTimeInterval: 0.3)
        guard let (_, after) = eventTable(in: window) else {
            return .failure(.verificationFailed(
                requested: action, actual: "the Event List could not be re-read", restored: false
            ))
        }
        let wanted: Int
        switch action {
        case "create": wanted = before.count + 1
        case "delete": wanted = before.count - 1
        default: wanted = before.count
        }
        payload["events_after"] = after.count
        guard after.count == wanted else {
            return .failure(.verificationFailed(
                requested: "\(wanted) event(s) after '\(action)'",
                actual: "the Event List holds \(after.count)", restored: false
            ))
        }
        var landed: EventRow?
        if let expected {
            let hits = after.filter { $0.describedBriefly == expected.describedBriefly }
            guard hits.count == 1 else {
                return .failure(.verificationFailed(
                    requested: expected.describedBriefly,
                    actual: hits.isEmpty
                        ? "no row in the re-read list reads that"
                        : "\(hits.count) rows read that — the edit produced a duplicate",
                    restored: false
                ))
            }
            landed = hits[0]
            payload["event"] = describe(hits[0])
        }
        if action == "delete", let editedBefore {
            guard !after.contains(where: { $0.describedBriefly == editedBefore.describedBriefly }) else {
                return .failure(.verificationFailed(
                    requested: "the event gone", actual: "it is still in the list", restored: false
                ))
            }
        }
        // The neighbours. A note edit that moved another note is a different
        // region, not a caveat — but it is reported rather than thrown, because
        // the write DID happen and the caller has to know both halves.
        let othersBefore = editedBefore.map { otherRows(before, excluding: $0) }
            ?? before.map(\.describedBriefly).sorted()
        let othersAfter = landed.map { otherRows(after, excluding: $0) }
            ?? after.map(\.describedBriefly).sorted()
        if othersBefore != othersAfter {
            let vanished = Set(othersBefore).subtracting(othersAfter)
            let appeared = Set(othersAfter).subtracting(othersBefore)
            appendWarning(
                "OTHER events in this region changed as a side effect of this write."
                    + " Gone: \(vanished.sorted().joined(separator: "; "))."
                    + " New: \(appeared.sorted().joined(separator: "; ")).",
                to: &payload
            )
        }
        payload["success"] = true
        payload["verified"] = true
        payload["state"] = action == "delete" ? "deleted" : (action == "create" ? "created" : "set")
        payload["write_route"] = action == "delete"
            ? "event_list_row_delete_action"
            : (action == "create"
               ? "event_list_create_new_event_button_plus_cell_steppers"
               : "event_list_cell_steppers")
        payload["readback_route"] = "event_list_reread"
        return .success(payload)
    }

    /// One event as a result carries it.
    private func describe(_ row: EventRow) -> [String: Any] {
        var payload: [String: Any] = [
            "position": row.positionText,
            "bar": row.position[0],
            "beat": row.position[1],
            "division": row.position[2],
            "tick": row.position[3],
            "type": row.status,
            "channel": row.channel,
            "length": row.lengthText
        ]
        if let pitch = row.pitch {
            payload["pitch"] = row.numberText
            payload["pitch_number"] = pitch
        } else if !row.numberText.isEmpty {
            payload["num"] = row.numberText
        }
        if let velocity = row.velocity { payload["velocity"] = velocity }
        return payload
    }
}
