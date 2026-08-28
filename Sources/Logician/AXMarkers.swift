import AppKit
import ApplicationServices
import Foundation

// MARK: - Markers: the Marker List, and the row-scoped writes it allows

extension LogicAccessibility {

    /// Runs `body` against one Marker List row, with the pane open and the row
    /// selected. Row ELEMENTS are only valid while the pane is showing, so every
    /// write that addresses a row has to happen inside this scope rather than
    /// against an element captured by an earlier read.
    ///
    /// The row is matched by name first (case-insensitively, exactly — never
    /// fuzzily: renaming or deleting the wrong marker is silent damage), and by
    /// bar when no name is given. Ambiguity refuses with the candidates listed.
    func withMarkerRow<Value>(
        name: String?, bar: Int?,
        body: (ListEditorRow, ListEditorTable) -> Value
    ) throws -> Value {
        let read = withListEditorsTab(named: "Marker") { window -> (ListEditorTable?, Value?, Error?) in
            let table = self.readListEditorTable(tab: "Marker", in: window).table
            guard let table else { return (nil, nil, nil) }
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
                return (table, nil, LogicianError.trackNotFound(
                    name.map { "marker '\($0)'" } ?? "a marker at bar \(bar ?? 0)",
                    available: table.rows.map {
                        "\(self.markerName(of: $0, in: table) ?? "(unnamed)")"
                            + " at bar \(self.markerBar(of: $0, in: table).map(String.init) ?? "?")"
                    }
                ))
            }
            guard candidates.count == 1 else {
                return (table, nil, LogicianError.trackAmbiguous(
                    name ?? "bar \(bar ?? 0)",
                    numbers: candidates.compactMap { self.markerBar(of: $0, in: table) }
                ))
            }
            self.selectListEditorRow(row, in: table)
            Thread.sleep(forTimeInterval: 0.2)
            return (table, body(row, table), nil)
        }
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
        if let error = inner.2 { throw error }
        guard let value = inner.1 else {
            throw LogicianError.trackNotExposed(
                requested: "the marker row", exposed: "it disappeared between the read and the write"
            )
        }
        return value
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
            $0.lowercased().contains("position")
        } ?? 0
        return TempoMap.parseTempoListPosition(row.cell(positionIndex))?.bar
    }

    /// Presses the Marker tab's own `Create new Marker` button, inside the pane
    /// scope. Returns false when the tab publishes no such button.
    ///
    /// Preferred over the `Create Marker` KEY COMMAND that COVERAGE named as the
    /// route (G46), and the reason is worth recording: the button is right there
    /// in the list the result is verified against, it needs no learned
    /// assignment, and it cannot be orphaned the way a MIDI-note binding is when
    /// Logic's ports are recreated. The key command stays as the fallback for a
    /// Logic version that does not publish the button.
    func pressCreateMarkerButton() -> Bool {
        let read = withListEditorsTab(named: "Marker") { window -> Bool in
            guard let table = self.readListEditorTable(tab: "Marker", in: window).table
            else { return false }
            guard let button = self.children(of: table.group).first(where: {
                self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                    && self.stringAttribute($0, kAXDescriptionAttribute as String)
                        .localizedCaseInsensitiveContains("Create new Marker")
            }) else { return false }
            let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            // Settle inside the scope: the pane closes on the way out and the
            // new row should exist before that happens.
            Thread.sleep(forTimeInterval: 0.5)
            return pressed
        }
        return read.value ?? false
    }

    /// Deletes one marker through the row's own `Delete` action — the action
    /// every List Editors row was observed to carry (2026-08-28, on a Tempo
    /// row). Verified by the marker being gone from a fresh read, never by the
    /// action's return code.
    func deleteMarker(name: String?, bar: Int?) throws -> [String: Any] {
        let before = readMarkerList().markers?.count
        let performed = try withMarkerRow(name: name, bar: bar) { row, _ in
            let done = self.performListEditorRowDelete(row)
            // Settle BEFORE the scope ends: the pane closes on the way out, and
            // a row action still being applied should not race a menu toggle.
            Thread.sleep(forTimeInterval: 0.4)
            return done
        }
        let after = readMarkerList()
        let remaining = after.markers?.count
        let gone = (before != nil && remaining != nil) ? remaining! < before! : false
        return [
            "success": gone,
            "verified": gone,
            "state": gone ? "deleted" : "failed",
            "action_performed": performed,
            "markers_before": before ?? NSNull(),
            "markers_after": remaining ?? NSNull(),
            "markers": after.markers ?? [],
            "write_route": "list_editor_row_delete",
            "note": gone
                ? "Deleted through the Marker List row's own Delete action; Undo restores it."
                : "The row's Delete action did not remove the marker — nothing else was tried."
        ]
    }

    /// Renames one marker by writing the name cell's value, IF Logic publishes a
    /// writable one. It is a runtime question, not an assumption: the cell's
    /// settability is checked and an unwritable cell is refused with the reason,
    /// never worked around by typing into the UI.
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
                    + " out to be steppers rather than fields. Rename the marker in Logic."
            )
        }
        let after = readMarkerList()
        let renamed = after.markers?.contains {
            ($0["name"] as? String)?.localizedCaseInsensitiveCompare(newName) == .orderedSame
        } ?? false
        return [
            "success": renamed,
            "verified": renamed,
            "state": renamed ? "renamed" : "failed",
            "before": outcome.1,
            "requested": newName,
            "markers": after.markers ?? [],
            "write_route": "list_editor_cell_value",
            "readback_route": "marker_list_reread"
        ]
    }
}
