import AppKit
import ApplicationServices
import Foundation

// MARK: - Markers: the Marker List, and the row-scoped writes it allows

/// Where `goto` parks the playhead, decided from the marker row's own parsed
/// position.
///
/// Pure, because the bug this replaces was a DECISION and not a mechanism:
/// `goto` read only `marker["bar"]` and passed `beat: nil` to `setPlayhead`,
/// and `beat: nil` does not mean "beat 1" — the beat slider is simply never
/// touched, so the playhead keeps whatever beat it happened to carry. Measured
/// 2026-09-02 (`logic_markers` profile D1): `Marker 1` at `33 4 1 1` parked the
/// playhead at bar 33 BEAT 1, three beats early, and the result carried
/// `after: {bar: 33, beat: 1}` beside `marker: {bar: 33, beat: 4}` without
/// noticing the two disagreed.
enum MarkerPark {

    struct Target: Equatable {
        let bar: Int
        let beat: Int
        /// The marker sits EXACTLY on that beat. False when its position
        /// carries a division or a tick, which the control bar's two sliders
        /// cannot address (measured 2026-08-28: the position display publishes
        /// `bar` and `beat` and nothing below them) — the park is then the beat
        /// line at or before the marker, and the result says so instead of
        /// claiming the marker's own position.
        let exact: Bool
    }

    /// `beat` arrives as the payload's parsed `beatInBar`, which is a Double
    /// because `33 4 2 120` is beat 4.3 of the bar — so it is taken as `Any?`
    /// and read as either. A position that yielded no beat at all parks on
    /// beat 1: the bar is still worth going to, and beat 1 is the bar line.
    static func target(bar: Int, beat: Any?) -> Target {
        let value: Double
        switch beat {
        case let double as Double: value = double
        case let integer as Int: value = Double(integer)
        default: value = 1
        }
        let whole = max(1, Int(value.rounded(.down)))
        return Target(bar: bar, beat: whole, exact: abs(value - Double(whole)) < 0.0005)
    }
}

/// What one `create` did, read out of the SAME pane scope that pressed the
/// button — the counts on both sides, the markers afterwards, and whether the
/// tab published a button to press at all.
struct MarkerCreateReading {
    /// The list's own count before the press.
    let countBefore: Int
    /// The bars the list already held, so a create with no `bar` argument can
    /// still say WHICH row is the new one. (With a bar, the playhead's own is
    /// the answer — Logic renumbers the default names by position, so the name
    /// never is.)
    let barsBefore: [Int]
    /// False when the Marker tab publishes no `Create new Marker` button, or
    /// when pressing it was refused: nothing was written and the caller's key
    /// command is next.
    let pressed: Bool
    /// The list's own count grew.
    let created: Bool
    let countAfter: Int?
    let censusAfter: ListEditorCensus?
    let markers: [[String: Any]]
    /// The readback's own cross-check, when it failed: the count and the rows
    /// disagreed, so the markers below are not to be trusted as a full list.
    let readbackFailure: ListEditorFailure?
    /// How many times the list was re-read before the count moved. Reported so
    /// the sleep this replaced can never quietly come back.
    let polls: Int
}

extension LogicAccessibility {

    /// Runs `body` against one Marker List row, with the pane open and the row
    /// selected. Row ELEMENTS are only valid while the pane is showing, so every
    /// write that addresses a row has to happen inside this scope rather than
    /// against an element captured by an earlier read.
    func withMarkerRow<Value>(
        name: String?, bar: Int?,
        body: (ListEditorRow, ListEditorTable) -> Value
    ) throws -> Value {
        let tab = LogicUIStrings.Element.ListEditorTab.marker
        let read = withListEditorsTab(named: tab) { window -> Result<Value, Error> in
            Result {
                let table = try self.markerTable(tab: tab, in: window)
                let row = try self.markerRow(name: name, bar: bar, in: table)
                self.selectListEditorRowVerified(row, in: table)
                return body(row, table)
            }
        }
        return try unwrapMarkerScope(read)
    }

    /// The Marker tab's table, or the pane's own reason why not.
    private func markerTable(tab: String, in window: AXUIElement) throws -> ListEditorTable {
        let read = readListEditorTable(tab: tab, in: window)
        guard let table = read.table else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List",
                exposed: (read.failure ?? .tableNotFound(tab)).reason
            )
        }
        return table
    }

    /// The pane scope's two failure planes — the pane's and the body's —
    /// collapsed into one throw, so every marker write says the same things.
    private func unwrapMarkerScope<Value>(
        _ read: (value: Result<Value, Error>?, failure: ListEditorFailure?)
    ) throws -> Value {
        if let failure = read.failure {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List", exposed: failure.reason
            )
        }
        guard let inner = read.value else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List", exposed: "the tab published no table"
            )
        }
        return try inner.get()
    }

    /// The ONE row a marker write addresses.
    ///
    /// Matched by name first (case-insensitively, exactly — never fuzzily:
    /// renaming or deleting the wrong marker is silent damage), and by bar when
    /// no name is given. Ambiguity refuses with the candidates listed.
    func markerRow(name: String?, bar: Int?, in table: ListEditorTable) throws -> ListEditorRow {
        let candidates = table.rows.filter { row in
            if let name {
                return self.markerName(of: row, in: table)?
                    .localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            if let bar {
                return self.markerBar(of: row, in: table) == bar
            }
            return false
        }
        guard let row = candidates.first else {
            throw LogicianError.trackNotFound(
                name.map { "marker '\($0)'" } ?? "a marker at bar \(bar ?? 0)",
                available: table.rows.map {
                    "\(self.markerName(of: $0, in: table) ?? "(unnamed)")"
                        + " at bar \(self.markerBar(of: $0, in: table).map(String.init) ?? "?")"
                }
            )
        }
        guard candidates.count == 1 else {
            throw LogicianError.trackAmbiguous(
                name ?? "bar \(bar ?? 0)",
                numbers: candidates.compactMap { self.markerBar(of: $0, in: table) }
            )
        }
        return row
    }

    func markerName(of row: ListEditorRow, in table: ListEditorTable) -> String? {
        // Logic titles it "Marker Name" (measured 2026-08-28); matching by
        // containment also catches a version that shortens or prefixes it.
        for (index, column) in table.columns.enumerated()
        where ["marker", "name", "text"].contains(where: { column.lowercased().contains($0) }) {
            let value = row.cell(index)
            if !value.isEmpty { return value }
        }
        // No recognisable name column: the last non-empty cell that is not a
        // position is the best available answer, and it is reported as read.
        return row.cells.dropFirst().last(where: { !$0.isEmpty })
    }

    func markerBar(of row: ListEditorRow, in table: ListEditorTable) -> Int? {
        let positionIndex = table.columns.firstIndex {
            $0.lowercased().contains(LogicUIStrings.Element.positionColumn)
        } ?? 0
        return TempoMap.parseTempoListPosition(row.cell(positionIndex))?.bar
    }

    /// Creates a marker at the playhead through the Marker tab's own `Create
    /// new Marker` button, and reads the result back — all inside ONE pane
    /// scope.
    ///
    /// Preferred over the `Create Marker` KEY COMMAND that COVERAGE named as
    /// the route (G46), and the reason is worth recording: the button is right
    /// there in the list the result is verified against, it needs no learned
    /// assignment, and it cannot be orphaned the way a MIDI-note binding is when
    /// Logic's ports are recreated. The key command stays as the caller's
    /// fallback for a Logic version that does not publish the button —
    /// `pressed == false` is what asks for it.
    ///
    /// WHY ONE SCOPE. This used to be three pane cycles: read the list, open the
    /// pane again to press the button, open it a third time to verify. Measured
    /// 2026-09-02 at 1 509–2 130 ms EACH, against a read that costs 5–12 ms —
    /// the whole tool was choreography. Everything here wants the same pane on
    /// the same tab, and the button lives on the group the first read already
    /// returns.
    func createMarkerThroughListButton() throws -> MarkerCreateReading {
        let tab = LogicUIStrings.Element.ListEditorTab.marker
        let read = withListEditorsTab(named: tab) { window -> Result<MarkerCreateReading, Error> in
            Result { try self.createMarkerInScope(tab: tab, in: window) }
        }
        return try unwrapMarkerScope(read)
    }

    private func createMarkerInScope(
        tab: String, in window: AXUIElement
    ) throws -> MarkerCreateReading {
        let table = try markerTable(tab: tab, in: window)
        // The COUNT is the list's own on both sides of the create, never the
        // readable rows': a marker created into an undrawn row would otherwise
        // read as "no new marker appeared" and be reported as a failure that
        // had in fact worked — the exact mistake `EventCensus` was written to
        // stop on the Event List's writes (2026-09-01).
        let before = table.count
        let barsBefore = table.rows.compactMap { markerBar(of: $0, in: table) }
        func reading(
            pressed: Bool, created: Bool, table: ListEditorTable?, polls: Int
        ) -> MarkerCreateReading {
            let counted = table.map(listEditorCensus(of:))
            return MarkerCreateReading(
                countBefore: before,
                barsBefore: barsBefore,
                pressed: pressed,
                created: created,
                countAfter: counted?.census?.count ?? table?.count,
                censusAfter: counted?.census,
                markers: counted?.census?.entries.map(ListEditorPayload.marker(from:)) ?? [],
                readbackFailure: counted?.failure,
                polls: polls
            )
        }
        guard let button = children(of: table.group).first(where: {
            self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && self.stringAttribute($0, kAXDescriptionAttribute as String)
                    .localizedCaseInsensitiveContains(LogicUIStrings.Element.createNewMarker)
        }), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return reading(pressed: false, created: false, table: table, polls: 0)
        }
        // What used to be here: `sleep(0.5)` inside the press scope and another
        // `sleep(0.25)` before the caller's first read — 750 ms of clock for a
        // row the first read found anyway, `polls=1` 3/3 (profile C3). The
        // list's own count growing is the same evidence, taken as soon as it
        // is true.
        let settled = pollListEditorTable(tab: tab, in: window) { $0.count > before }
        return reading(
            pressed: true, created: settled.settled,
            table: settled.table ?? table, polls: settled.polls
        )
    }

    /// Deletes one marker through the row's own `Delete` action — the action
    /// every List Editors row was observed to carry (2026-08-28, on a Tempo
    /// row). Verified by the marker being gone from a fresh read, never by the
    /// action's return code.
    ///
    /// ONE pane scope, where this was three (count, find-the-row, read back):
    /// the count and the row come out of the same read, and the readback is the
    /// poll that waits for the count to fall.
    func deleteMarker(name: String?, bar: Int?) throws -> [String: Any] {
        let tab = LogicUIStrings.Element.ListEditorTab.marker
        let read = withListEditorsTab(named: tab) { window -> Result<[String: Any], Error> in
            Result { try self.deleteMarkerInScope(name: name, bar: bar, tab: tab, in: window) }
        }
        return try unwrapMarkerScope(read)
    }

    private func deleteMarkerInScope(
        name: String?, bar: Int?, tab: String, in window: AXUIElement
    ) throws -> [String: Any] {
        let table = try markerTable(tab: tab, in: window)
        // The list's OWN count on both sides, never the readable rows': a row
        // Logic has published and not drawn is a marker that exists, and
        // counting only what could be read would make a delete that worked
        // look like one that did not (`ListEditorCensus`).
        let before = table.count
        let row = try markerRow(name: name, bar: bar, in: table)
        let selected = selectListEditorRowVerified(row, in: table)
        let performed = performListEditorRowDelete(row)
        // The 0.4 s that used to be slept here guarded an action that measured
        // 13.9 ms (profile 2026-09-02, C3). The count falling is the evidence.
        let settled = pollListEditorTable(tab: tab, in: window) { $0.count < before }
        let counted = listEditorCensus(of: settled.table ?? table)
        let gone = settled.settled
        var payload: [String: Any] = [
            "success": gone,
            "verified": gone,
            "state": gone ? "deleted" : "failed",
            "action_performed": performed,
            "row_selected": selected,
            "markers_before": before,
            "markers_after": counted.census?.count ?? settled.table?.count ?? NSNull(),
            "markers": counted.census?.entries.map(ListEditorPayload.marker(from:)) ?? [],
            "write_route": "list_editor_row_delete",
            "readback_route": "marker_list_same_pane",
            "readback_polls": settled.polls,
            "note": gone
                ? "Deleted through the Marker List row's own Delete action; Undo restores it."
                : "The row's Delete action did not remove the marker — nothing else was tried."
        ]
        if !gone, !selected {
            appendWarning(
                "The row's AXSelected did not read back as true before the Delete action fired,"
                    + " so the action may have had no row to act on.",
                to: &payload
            )
        }
        if let failure = counted.failure {
            appendWarning(
                "The readback could not be trusted as a full list: " + failure.reason + ".",
                to: &payload
            )
        }
        return payload
    }

    /// Renames one marker by writing the name cell's value, IF Logic publishes a
    /// writable one. It is a runtime question, not an assumption: the cell's
    /// settability is checked and an unwritable cell is refused with the reason,
    /// never worked around by typing into the UI.
    ///
    /// MEASURED on Logic Pro 12.3.1 (2026-09-02): the answer is always no — no
    /// cell in a Marker List row publishes a settable `AXValue`. The check
    /// stays, because it is the only thing that would notice a Logic version
    /// where the answer changes; what does NOT stay is inviting the agent to
    /// pass a name to `create` and charging it a pane cycle to be refused, so
    /// `logic_markers` turns `name` down before it opens anything.
    func renameMarker(name: String?, bar: Int?, newName: String) throws -> [String: Any] {
        let outcome = try withMarkerRow(name: name, bar: bar) { row, table -> (Bool, String, String) in
            let nameIndex = table.columns.firstIndex { column in
                ["marker", "name", "text"].contains { column.lowercased().contains($0) }
            } ?? max(row.cells.count - 1, 0)
            let cells = self.children(of: row.element)
            guard cells.indices.contains(nameIndex) else { return (false, "", "no name cell") }
            // The text lives on the cell's child group; the WRITABLE element, if
            // there is one, is the cell or that child.
            let targets = [cells[nameIndex]] + self.children(of: cells[nameIndex])
            let before = self.markerName(of: row, in: table) ?? ""
            for target in targets {
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(
                    target, kAXValueAttribute as CFString, &settable
                ) == .success, settable.boolValue else { continue }
                guard AXUIElementSetAttributeValue(
                    target, kAXValueAttribute as CFString, newName as CFString
                ) == .success else { continue }
                _ = AXUIElementPerformAction(target, kAXConfirmAction as CFString)
                Thread.sleep(forTimeInterval: 0.3)
                return (true, before, "")
            }
            return (false, before, "no cell in the marker row publishes a settable value")
        }
        guard outcome.0 else {
            throw LogicianError.valueNotWritable(
                "the marker's name (\(outcome.2)). The Marker List's cells are read-only from"
                    + " this plane, the same way the Tempo List's position and tempo cells turned"
                    + " out to be steppers rather than fields — and on Logic Pro 12.3.1 this is"
                    + " the answer EVERY time, measured 2026-09-02. There is no Accessibility"
                    + " route to a marker's name: rename it in Logic, by double-clicking the name"
                    + " in the Marker List (or the marker in the Tracks area's global track)."
            )
        }
        let after = readMarkerList()
        let renamed = after.markers?.contains {
            ($0["name"] as? String)?.localizedCaseInsensitiveCompare(newName) == .orderedSame
        } ?? false
        // A readback that could not read every row is not evidence of failure.
        // Say which it was rather than letting `verified: false` stand alone.
        var payload: [String: Any] = [
            "success": renamed,
            "verified": renamed,
            "state": renamed ? "renamed" : "failed",
            "before": outcome.1,
            "requested": newName,
            "markers": after.markers ?? [],
            "write_route": "list_editor_cell_value",
            "readback_route": "marker_list_reread"
        ]
        if !renamed, let census = after.census, !census.isComplete {
            payload["warning"] = "The rename was written and the readback could not see every"
                + " row. " + census.unreadNote + " So this is 'not verified', NOT 'did not"
                + " happen' — read the Marker List again."
        }
        return payload
    }

    /// The key-command fallback's readback, and it is the one place a marker
    /// create still pays a second pane cycle: the command fires outside the
    /// list, so the list has to be opened again to be counted.
    ///
    /// Unexercised against Logic — 12.3.1 publishes the `Create new Marker`
    /// button and the button path was taken 3/3 (measured 2026-09-02).
    func readMarkerCreateFallback(countBefore: Int, barsBefore: [Int]) -> MarkerCreateReading {
        let deadline = Date().addingTimeInterval(2.0)
        var polls = 0
        while true {
            polls += 1
            let read = readMarkerList()
            let count = read.census?.count
            let grew = (count ?? countBefore) > countBefore
            if grew || Date() >= deadline {
                return MarkerCreateReading(
                    countBefore: countBefore,
                    barsBefore: barsBefore,
                    pressed: false,
                    created: grew,
                    countAfter: count,
                    censusAfter: read.census,
                    markers: read.markers ?? [],
                    readbackFailure: read.failure,
                    polls: polls
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
