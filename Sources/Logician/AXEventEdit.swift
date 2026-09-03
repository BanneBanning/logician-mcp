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

/// One read of the Event tab: the live table, and the ONE census every check in
/// this file counts by (see `EventCensus` — the row Logic has not drawn yet is
/// counted and not read, everywhere).
private struct EventTableRead {
    let table: ListEditorTable
    let census: EventCensus

    var rows: [EventRow] { census.rows }
    var count: Int { census.count }
}

/// The one row Logic has selected in the Event List: the live element a write
/// goes to, and what that row currently reads.
private struct SelectedEventRow {
    let live: ListEditorRow
    let parsed: EventRow
}

extension LogicAccessibility {

    /// How long one field's converge may take in wall-clock terms, whatever its
    /// step budget says. The budget counts writes; this catches the case where
    /// each write is slow — the fallback row read is a whole-table read — so a
    /// tool call cannot run away for a minute.
    private static let eventConvergeDeadline: TimeInterval = 25

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

    /// The live table of the Event tab and the census of what it holds.
    private func eventTable(in window: AXUIElement) -> EventTableRead? {
        let (table, _) = readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.event, in: window)
        guard let table else { return nil }
        return EventTableRead(
            table: table,
            census: EventListWrite.census(
                cells: table.rows.map(\.cells), columns: table.columns,
                declaredCount: table.declaredCount
            )
        )
    }

    /// Re-reads the Event tab until `accept` is satisfied, and hands back what
    /// it last saw either way — so a caller that ran out of deadline still
    /// reports the list as it found it rather than as it hoped.
    ///
    /// This is the positive check that replaced this file's blind sleeps: 0.8 s
    /// after the `Create new Event` press, 0.6 s after a row delete and 0.3 s
    /// before the verify read. The read IS the interval — one costs 154–209 ms
    /// at 25 events (profile 2026-09-01) — so there is nothing to sleep between
    /// looks.
    private func eventTable(
        in window: AXUIElement,
        until accept: (EventTableRead) -> Bool,
        within deadline: TimeInterval
    ) -> EventTableRead? {
        let limit = Date().addingTimeInterval(deadline)
        var last = eventTable(in: window)
        while let read = last, !accept(read), Date() < limit {
            last = eventTable(in: window)
        }
        return last
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
    ///
    /// It asks the table for `AXSelectedRows` and reads THAT row's cells. The
    /// scan it replaced read every row's every cell to find the one whose
    /// `AXSelected` was `"1"`: 164 ms of the 268 ms each stepper write cost
    /// (profile 2026-09-01), paid on every step of every converge, and it grew
    /// with the region — a 200-note region made one velocity nudge cost
    /// seconds. The scan stays as the fallback for a Logic that does not
    /// publish the attribute at all.
    private func selectedEventRow(
        in window: AXUIElement, of table: ListEditorTable
    ) -> SelectedEventRow? {
        guard let selected = attribute(table.element, kAXSelectedRowsAttribute as String)
                as? [AXUIElement] else {
            return selectedEventRowByScan(in: window)
        }
        guard selected.count == 1, let element = selected.first else { return nil }
        let cells = children(of: element).map(listEditorCellText(of:))
        let index = Int(stringAttribute(element, kAXIndexAttribute as String)) ?? -1
        guard let parsed = EventListWrite.row(index: index, cells: cells, columns: table.columns)
        else { return nil }
        return SelectedEventRow(
            live: ListEditorRow(index: index, cells: cells, element: element), parsed: parsed
        )
    }

    private func selectedEventRowByScan(in window: AXUIElement) -> SelectedEventRow? {
        guard let read = eventTable(in: window) else { return nil }
        let selected = read.table.rows.filter {
            stringAttribute($0.element, kAXSelectedAttribute as String) == "1"
        }
        guard selected.count == 1, let live = selected.first,
              let parsed = read.rows.first(where: { $0.index == live.index }) else { return nil }
        return SelectedEventRow(live: live, parsed: parsed)
    }

    /// Waits for Logic to publish the selection this server just wrote.
    ///
    /// It replaces two blind sleeps (0.35 s before a set's anchor read, 0.3 s
    /// before a delete) with the thing they were insuring against: `AXSelected`
    /// read back `"1"` at **0 ms on 6/6 probes** (profile 2026-09-01 §4). It is
    /// a check, not a wait — a row Delete acts on Logic's selection, so a
    /// selection that cannot be proven is a reason not to press.
    private func awaitRowSelected(_ row: ListEditorRow, within deadline: TimeInterval = 0.6) -> Bool {
        let limit = Date().addingTimeInterval(deadline)
        while true {
            if stringAttribute(row.element, kAXSelectedAttribute as String) == "1" { return true }
            if Date() >= limit { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Waits for a stepper write's effect to become READABLE, and hands back
    /// the read it stopped on so the converge loop does not pay for the same
    /// read twice.
    ///
    /// The 90 ms sleep this replaces was insuring against nothing: the effect
    /// showed on `AXValueDescription` within **0–4 ms on 16/16 probed writes**,
    /// and the write call itself blocks for 2–4 ms of that (profile 2026-09-01
    /// §4). The row also reads back EMPTY for a moment after a write, and the
    /// table RE-SORTS under a position or pitch write — so a read that comes
    /// back unreadable, or carrying a row that is not the one being edited, is
    /// a reason to look again rather than to stop. Only a row that still agrees
    /// with the cursor is ever handed back, which is what keeps a mid-repaint
    /// read from being mistaken for "the selection moved to another note".
    private func awaitStepperEffect(
        field: EventField, segment: Int, changedFrom current: Int, cursor: EventRow,
        window: AXUIElement, table: ListEditorTable, within deadline: TimeInterval = 0.25
    ) -> SelectedEventRow? {
        let limit = Date().addingTimeInterval(deadline)
        var agreeing: SelectedEventRow?
        while true {
            if let read = selectedEventRow(in: window, of: table),
               EventListWrite.agrees(read.parsed, with: cursor, exceptFor: field) {
                agreeing = read
                if EventListWrite.value(of: read.parsed, field: field, segment: segment) != current {
                    return read
                }
            }
            if Date() >= limit { return agreeing }
            Thread.sleep(forTimeInterval: 0.005)
        }
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
    ///   → D3) and on velocity (97 → 107) alike (2026-08-28), and on the
    ///   POSITION and LENGTH steppers too (2026-09-02: a tick moved 1 → 101 and
    ///   back in **10 writes** each way, 2/2, and a length's ticks 228 → 128 and
    ///   back in 10 each way). That is the coarse gear this loop shifts into
    ///   while it is more than ten away, and it is why a velocity walk from 40
    ///   to 120 costs ten writes instead of eighty — and why a note created off
    ///   the grid (Logic's playhead park landed one at `11 2 4 201`) is dragged
    ///   onto it in 23 writes rather than 203. A segment whose stepper ignored
    ///   the action would simply converge one unit at a time: the loop re-reads
    ///   the value after every write and the budget below is sized for the slow
    ///   path.
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
    /// `pending` is the read the caller already has in hand — the anchor read
    /// before the first field, and the read `awaitStepperEffect` stopped on
    /// after every write since. The loop used to re-read the whole table at the
    /// top of its first turn, ~180 ms after the anchor read had read the same
    /// row with nothing in between (profile 2026-09-01, candidate 9).
    ///
    /// Returns nil on success, or the reason it stopped.
    private func convergeEventField(
        _ field: EventField,
        segment: Int,
        target: Int,
        window: AXUIElement,
        table: ListEditorTable,
        cursor: inout EventRow,
        pending: inout SelectedEventRow?,
        steps: inout [String]
    ) -> String? {
        let columns = table.columns
        var writes = 0
        var stalled = 0
        var budget = 0
        var previous: Int?
        let deadline = Date().addingTimeInterval(Self.eventConvergeDeadline)
        while true {
            guard let found = pending ?? selectedEventRow(in: window, of: table) else {
                return "the row being edited (\(cursor.describedBriefly)) is no longer the one"
                    + " Logic has selected in the Event List, so this write stopped after"
                    + " \(writes) write(s) rather than risk editing another note"
            }
            pending = nil
            guard EventListWrite.agrees(found.parsed, with: cursor, exceptFor: field) else {
                return "the selected Event List row changed in more than the \(field.rawValue)"
                    + " this write is moving (was \(cursor.describedBriefly), is now"
                    + " \(found.parsed.describedBriefly)) — stopped after \(writes) write(s)"
            }
            cursor = found.parsed
            guard let current = EventListWrite.value(of: cursor, field: field, segment: segment) else {
                return "Logic's \(field.rawValue) cell published no readable value"
            }
            if current == target {
                if writes > 0 {
                    steps.append("\(field.rawValue)\(field == .position || field == .length ? "[\(segment)]" : "")"
                                 + " reached \(target) in \(writes) write(s)")
                }
                return nil
            }
            // The budget is the DISTANCE, not a constant — see
            // `EventListWrite.stepBudget`. Taken on the first look, because
            // that is where the distance is known.
            if writes == 0 { budget = EventListWrite.stepBudget(field, from: current, to: target) }
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
            guard writes < budget else {
                return "the \(field.rawValue) write reached \(current) and did not reach \(target)"
                    + " within \(budget) steps"
            }
            guard Date() < deadline else {
                return "the \(field.rawValue) write reached \(current) of \(target) in \(writes)"
                    + " write(s) and ran out of its \(Int(Self.eventConvergeDeadline)) second budget"
            }
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
            if abs(delta) >= 10 {
                // The coarse gear: one action, ten units — on every one of
                // these steppers, position and length included (measured
                // 2026-09-02, see above).
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
            pending = awaitStepperEffect(
                field: field, segment: segment, changedFrom: current, cursor: cursor,
                window: window, table: table
            )
        }
    }

    /// Steps a whole position (or length) vector.
    private func convergeEventVector(
        _ field: EventField,
        target: [Int],
        window: AXUIElement,
        table: ListEditorTable,
        cursor: inout EventRow,
        pending: inout SelectedEventRow?,
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
                    table: table, cursor: &cursor, pending: &pending, steps: &steps
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

    private func runEventEdit(
        window: AXUIElement, action: String, address: EventAddress, change: EventChange,
        steps: inout [String]
    ) -> Result<[String: Any], LogicianError> {
        guard let read = eventTable(in: window) else {
            return .failure(.preconditionUnmet("the Event tab published no table of rows"))
        }
        let table = read.table
        let before = read.census
        // Mode first, because the other level of this same tab looks like a
        // perfectly good table and holds no notes at all.
        guard EventListWrite.isEventMode(columns: table.columns) else {
            return .failure(.preconditionUnmet(
                "the Event List is showing the project's REGIONS, not a region's events"
                    + " (columns: \(table.columns.joined(separator: ", "))). Nothing here is a MIDI"
                    + " event and none of these cells is editable. Select a region first —"
                    + " pass track_name (plus region_name and/or start_bar), or call"
                    + " logic_select_regions — and read it back with logic_list_events."
            ))
        }
        // Logic's own two counts disagreeing with each other is the truncated
        // table this has always refused. A row it has published and not drawn
        // is a different thing and is NOT refused: it is counted, it cannot be
        // read, and `EventCensus` says so everywhere below.
        if before.truncated {
            return .failure(.preconditionUnmet(
                "the Event List published \(before.published) row(s) but says it holds"
                    + " \(before.declared.map(String.init) ?? "?"). A partially realised table would"
                    + " be edited at the wrong row, so no write was made."
            ))
        }

        var payload: [String: Any] = [
            "action": action,
            "events_before": before.count,
            "columns": table.columns
        ]
        if !before.isComplete { payload["unreadable_rows"] = before.unread }

        if action == "create" {
            return createEvent(
                window: window, table: table, before: before, address: address, change: change,
                steps: &steps, payload: &payload
            )
        }

        // MARK: address an existing event
        let match = EventListWrite.match(
            rows: before.rows, bar: address.bar, beat: address.beat, division: address.division,
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
                    + before.rows.prefix(40).map(\.describedBriefly).joined(separator: "; ")
                    + (before.rows.count > 40 ? " …" : "")
                    + (before.isComplete ? "" : ". " + before.unreadNote
                       + " Scroll the Event List (or make its pane taller) and try again if the note"
                       + " you mean is not in that list.")
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

        if action == "delete" {
            return deleteEvent(
                window: window, table: table, before: before, target: target,
                steps: &steps, payload: &payload
            )
        }
        return setEvent(
            window: window, table: table, before: before, target: target, change: change,
            steps: &steps, payload: &payload
        )
    }

    // MARK: - create

    // swiftlint:disable:next function_body_length
    private func createEvent(
        window: AXUIElement, table: ListEditorTable, before: EventCensus,
        address: EventAddress, change: EventChange,
        steps: inout [String], payload: inout [String: Any]
    ) -> Result<[String: Any], LogicianError> {
        if case .one(let clash) = EventListWrite.match(
            rows: before.rows, bar: address.bar, beat: address.beat, division: address.division,
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
        steps.append("'Create new Event' pressed")
        // The positive check that replaced a blind 0.8 s: the list grows by one.
        let wanted = before.count + 1
        guard let afterPress = eventTable(in: window, until: { $0.count == wanted }, within: 2.5) else {
            return .failure(.verificationFailed(
                requested: "a new event",
                actual: "the Event List could not be re-read after the press, so this server cannot"
                    + " say whether a note was made — read the region with logic_list_events before"
                    + " trying again",
                restored: false
            ))
        }
        // From here on NOTHING returns without either verifying the note or
        // taking it back out. The failure that started this rewrite was the
        // count check just below: it returned before the cleanup the converge
        // path already had, and left the note in the user's region while
        // telling the caller nothing had happened.
        guard afterPress.count != before.count else {
            return .failure(.writeFailed(
                "'Create new Event' was pressed and the Event List still holds"
                    + " \(afterPress.count) event(s), so no note was made and nothing was changed."
            ))
        }
        guard afterPress.count == wanted else {
            return .failure(.verificationFailed(
                requested: "\(wanted) event(s) after 'Create new Event'",
                actual: "the list holds \(afterPress.count). This server will not guess which row(s)"
                    + " that press made, so nothing was deleted — read the region with"
                    + " logic_list_events",
                restored: false
            ))
        }
        // Logic SELECTS the row it just made, which is how it is told apart
        // from an identical neighbour. Failing that, the row that APPEARED
        // between the two reads names it — and if neither does, nothing is
        // deleted, because deleting "whatever is selected" would delete a
        // neighbour.
        let appeared = EventListWrite.neighbourVerdict(
            before: before.rows.map(\.describedBriefly),
            after: afterPress.rows.map(\.describedBriefly),
            unreadBefore: before.unread, unreadAfter: afterPress.census.unread
        ).appeared
        var pending = selectedEventRow(in: window, of: afterPress.table)
        guard let selected = pending else {
            return failedCreate(
                window: window, identity: appeared.count == 1 ? appeared[0] : nil,
                restoringTo: before.count,
                requested: "the newly created row",
                actual: "no single row came back selected, so this server could not follow the note"
                    + " it had just made"
            )
        }
        let created = selected.parsed
        steps.append("created at '\(created.positionText)' as \(created.numberText)"
                     + " vel \(created.velocity.map(String.init) ?? "?") len \(created.lengthText)")
        var cursor = created
        let target = EventListWrite.targetPosition(
            current: created.position, bar: address.bar, beat: address.beat ?? 1,
            division: address.division ?? 1, tick: address.tick ?? 1
        )
        var problem = convergeEventVector(
            .position, target: target, window: window, table: afterPress.table,
            cursor: &cursor, pending: &pending, steps: &steps
        )
        if problem == nil, let pitch = change.pitch ?? address.pitch {
            problem = convergeEventField(
                .pitch, segment: 0, target: pitch, window: window, table: afterPress.table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if problem == nil, let velocity = change.velocity {
            problem = convergeEventField(
                .velocity, segment: 0, target: velocity, window: window, table: afterPress.table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if problem == nil, let length = change.length {
            problem = convergeEventVector(
                .length, target: length, window: window, table: afterPress.table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if let problem {
            return failedCreate(
                window: window, identity: cursor.describedBriefly, restoringTo: before.count,
                requested: "a note at \(EventListWrite.format(target))"
                    + ((change.pitch ?? address.pitch).map { " reading \(EventListWrite.noteName($0))" } ?? ""),
                actual: problem
            )
        }
        let verdict = verify(
            window: window, action: "create", before: before, editedBefore: nil,
            expected: cursor, payload: &payload
        )
        if case .failure(let error) = verdict {
            return failedCreate(
                window: window, identity: cursor.describedBriefly, restoringTo: before.count,
                requested: "the created note to read '\(cursor.describedBriefly)'",
                actual: error.errorDescription ?? "the list did not verify"
            )
        }
        return verdict
    }

    /// Take our own note back out, and say plainly whether that worked.
    ///
    /// A `create` that cannot be finished must not leave a note nobody asked
    /// for in the user's region. This is reached from EVERY failure after the
    /// press — the profile of 2026-09-01 caught a `create` that returned
    /// `verification_failed`, `restored: false`, with the note sitting in the
    /// region, because the count check that failed returned before the cleanup
    /// the converge path already had.
    private func failedCreate(
        window: AXUIElement, identity: String?, restoringTo count: Int,
        requested: String, actual: String
    ) -> Result<[String: Any], LogicianError> {
        let removed = removeCreatedRow(identity, window: window, restoringTo: count)
        return .failure(.verificationFailed(
            requested: requested,
            actual: actual + (removed
                ? ". The note 'Create new Event' had already made was deleted again and the region"
                    + " re-read at \(count) event(s), so nothing of this call survives"
                : ". The note 'Create new Event' made is LEFT IN THE REGION"
                    + (identity.map { " reading '\($0)'" } ?? "")
                    + " — remove it with action 'delete'"),
            restored: removed
        ))
    }

    /// Deletes the row this call created, identified by its own content and
    /// verified gone by the count coming back.
    ///
    /// It does NOT delete whatever Logic has selected: the commonest way for a
    /// create to fail is the converge loop reporting that the selection is no
    /// longer the row it was moving, and deleting the selection THEN would
    /// delete somebody else's note. A row that cannot be named uniquely is
    /// reported and left alone. No blind Undo is ever fired.
    private func removeCreatedRow(
        _ identity: String?, window: AXUIElement, restoringTo count: Int
    ) -> Bool {
        guard let identity, let read = eventTable(in: window) else { return false }
        let hits = read.rows.filter { $0.describedBriefly == identity }
        guard hits.count == 1, read.table.rows.indices.contains(hits[0].index) else { return false }
        let row = read.table.rows[hits[0].index]
        selectListEditorRow(row, in: read.table)
        guard awaitRowSelected(row), performListEditorRowDelete(row) else { return false }
        return eventTable(in: window, until: { $0.count == count }, within: 2.0)?.count == count
    }

    // MARK: - delete

    private func deleteEvent(
        window: AXUIElement, table: ListEditorTable, before: EventCensus, target: EventRow,
        steps: inout [String], payload: inout [String: Any]
    ) -> Result<[String: Any], LogicianError> {
        guard table.rows.indices.contains(target.index) else {
            return .failure(.writeFailed("the addressed row is no longer published"))
        }
        let row = table.rows[target.index]
        selectListEditorRow(row, in: table)
        guard awaitRowSelected(row) else {
            return .failure(.writeFailed(
                "the addressed row would not take Logic's selection. The row's Delete action fires"
                    + " at the SELECTION, so pressing it now could remove another note — nothing"
                    + " was pressed."
            ))
        }
        guard performListEditorRowDelete(row) else {
            return .failure(.writeFailed(
                "the row offers no Delete action this server could perform"
            ))
        }
        steps.append("row deleted")
        return verify(
            window: window, action: "delete", before: before, editedBefore: target,
            expected: nil, payload: &payload
        )
    }

    // MARK: - set

    private func setEvent(
        window: AXUIElement, table: ListEditorTable, before: EventCensus, target: EventRow,
        change: EventChange, steps: inout [String], payload: inout [String: Any]
    ) -> Result<[String: Any], LogicianError> {
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
        let row = table.rows[target.index]
        selectListEditorRow(row, in: table)
        var pending = awaitRowSelected(row) ? selectedEventRow(in: window, of: table) : nil
        guard let anchored = pending,
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
                .pitch, segment: 0, target: pitch, window: window, table: table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if problem == nil, let velocity = change.velocity, velocity != cursor.velocity {
            problem = convergeEventField(
                .velocity, segment: 0, target: velocity, window: window, table: table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if problem == nil, let length = change.length, length != cursor.length {
            problem = convergeEventVector(
                .length, target: length, window: window, table: table,
                cursor: &cursor, pending: &pending, steps: &steps
            )
        }
        if problem == nil, wantedPosition != cursor.position {
            problem = convergeEventVector(
                .position, target: wantedPosition, window: window, table: table,
                cursor: &cursor, pending: &pending, steps: &steps
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
            window: window, action: "set", before: before, editedBefore: target,
            expected: cursor, payload: &payload
        )
    }

    /// The proof, for all three actions: the count moved as the action says,
    /// the event reads what was asked, and every OTHER event is where it was.
    ///
    /// The count is `EventCensus.count` on BOTH sides — the list's own
    /// `Number of Items`, cross-checked against the rows it published — never
    /// the length of the parsed array. That was D1: the two counts differed by
    /// the row Logic had not drawn yet, so a `create` that worked reported
    /// "found the list holds 25" and a `delete` that worked reported
    /// "Requested 24, found 25".
    private func verify(
        window: AXUIElement, action: String, before: EventCensus, editedBefore: EventRow?,
        expected: EventRow?, payload: inout [String: Any]
    ) -> Result<[String: Any], LogicianError> {
        let wanted: Int
        switch action {
        case "create": wanted = before.count + 1
        case "delete": wanted = before.count - 1
        default: wanted = before.count
        }
        // The positive check that replaced a blind 0.3 s: re-read until the
        // list says what the action implies, and stop the moment it does.
        func settled(_ candidate: EventTableRead) -> Bool {
            guard candidate.count == wanted else { return false }
            if let expected, !candidate.rows.contains(where: {
                $0.describedBriefly == expected.describedBriefly
            }) { return false }
            if action == "delete", let editedBefore, candidate.rows.contains(where: {
                $0.describedBriefly == editedBefore.describedBriefly
            }) { return false }
            return true
        }
        guard let read = eventTable(in: window, until: settled, within: 1.5) else {
            return .failure(.verificationFailed(
                requested: action, actual: "the Event List could not be re-read", restored: false
            ))
        }
        let after = read.rows
        payload["events_after"] = read.count
        // The AFTER read's answer replaces the BEFORE read's: a row that was
        // undrawn when this call started and is drawn now is not a caveat.
        if read.census.isComplete {
            payload.removeValue(forKey: "unreadable_rows")
        } else {
            payload["unreadable_rows"] = read.census.unread
        }
        guard read.count == wanted else {
            return .failure(.verificationFailed(
                requested: "\(wanted) event(s) after '\(action)'",
                actual: "the Event List holds \(read.count)", restored: false
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
                            + (read.census.isComplete ? "" : " (" + read.census.unreadNote + ")")
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
        let othersBefore = editedBefore.map { otherRows(before.rows, excluding: $0) }
            ?? before.rows.map(\.describedBriefly).sorted()
        let othersAfter = landed.map { otherRows(after, excluding: $0) }
            ?? after.map(\.describedBriefly).sorted()
        let verdict = EventListWrite.neighbourVerdict(
            before: othersBefore, after: othersAfter,
            unreadBefore: before.unread, unreadAfter: read.census.unread
        )
        if verdict.suspect {
            appendWarning(
                "OTHER events in this region changed as a side effect of this write."
                    + " Gone: \(verdict.vanished.joined(separator: "; "))."
                    + " New: \(verdict.appeared.joined(separator: "; ")).",
                to: &payload
            )
        } else if !before.isComplete || !read.census.isComplete {
            appendWarning(
                read.census.isComplete ? before.unreadNote : read.census.unreadNote
                    + " The event count is Logic's own and is unaffected; the 'every other event"
                    + " untouched' check covered the \(othersAfter.count) row(s) that could be read.",
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
