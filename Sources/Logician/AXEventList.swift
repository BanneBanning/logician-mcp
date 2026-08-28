import AppKit
import ApplicationServices
import Foundation

// MARK: - Reading the Event and Marker tabs of the List Editors pane

/// One row of a List Editors table, mapped onto the table's OWN column titles.
///
/// Deliberately generic. The Tempo tab's three columns were verified by name in
/// 2026-08-27's research; the Event tab's set changes with what is selected and
/// the Marker tab's is short, so a reader hardcoding column positions would
/// misreport the day Logic adds one. The columns are published — so they are
/// reported, and the cells are keyed by them.
struct ListEditorEntry {
    let index: Int
    /// Column title (as Logic prints it) → cell text.
    let fields: [String: String]
    /// The cells in table order, for a caller that would rather have positions.
    let cells: [String]

    func field(_ names: [String]) -> String? {
        for name in names {
            if let match = fields.first(where: {
                $0.key.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                return match.value.isEmpty ? nil : match.value
            }
        }
        return nil
    }
}

extension LogicAccessibility {

    /// Reads one tab of the List Editors pane as column-keyed rows.
    ///
    /// The `Number of Items` cross-check applies here exactly as it does to the
    /// tempo map, and for the same reason: an AX table inside a scroll area may
    /// publish only the rows it has REALISED, and a list that silently stops at
    /// row 30 of 400 is worse than one that refuses — an agent would conclude
    /// the region holds thirty notes. A mismatch is a failure, never a shorter
    /// answer.
    func readListEditorEntries(
        tab: String
    ) -> (
        entries: [ListEditorEntry]?, columns: [String], declaredCount: Int?,
        failure: ListEditorFailure?
    ) {
        let read = withListEditorsTab(named: tab) { window in
            self.readListEditorTable(tab: tab, in: window)
        }
        if let failure = read.failure { return (nil, [], nil, failure) }
        guard let inner = read.value else { return (nil, [], nil, .tableNotFound(tab)) }
        guard let table = inner.table else {
            return (nil, [], nil, inner.failure ?? .tableNotFound(tab))
        }
        if let declared = table.declaredCount, declared != table.rows.count {
            return (
                nil, table.columns, declared,
                .countMismatch(tab: tab, rows: table.rows.count, declared: declared)
            )
        }
        let entries = table.rows.map { row in
            var fields: [String: String] = [:]
            for (index, column) in table.columns.enumerated() where !column.isEmpty {
                fields[column] = row.cell(index)
            }
            return ListEditorEntry(index: row.index, fields: fields, cells: row.cells)
        }
        return (entries, table.columns, table.declaredCount, nil)
    }

    /// The Event tab's rows for whatever is currently selected in Logic.
    ///
    /// SCOPE, and it is the whole honesty story of this read: the Event List
    /// shows the events of the SELECTED REGION (or of the selected track's
    /// region under the playhead) — never the project's MIDI as a whole. This
    /// function reads what the list is showing; deciding what it should show is
    /// the caller's job, done with `logic_select_region` before the call.
    func readEventList() -> (
        events: [[String: Any]]?, columns: [String], declaredCount: Int?,
        failure: ListEditorFailure?
    ) {
        let read = readListEditorEntries(tab: "Event")
        guard let entries = read.entries else {
            return (nil, read.columns, read.declaredCount, read.failure)
        }
        return (entries.map(ListEditorPayload.event(from:)), read.columns, read.declaredCount, nil)
    }

    /// The Marker tab's rows: position and name, plus every other column the
    /// list publishes.
    func readMarkerList() -> (
        markers: [[String: Any]]?, columns: [String], failure: ListEditorFailure?
    ) {
        let read = readListEditorEntries(tab: "Marker")
        guard let entries = read.entries else { return (nil, read.columns, read.failure) }
        return (entries.map(ListEditorPayload.marker(from:)), read.columns, nil)
    }
}

// MARK: - Rows to result entries (pure)

/// Turning a List Editors row into the dictionary a tool result carries.
///
/// Pure and separate from the reading so it can be tested without Logic: the
/// column names are Logic's, they differ per tab, and the whole design question
/// — report every published column verbatim AND a parsed view of the ones that
/// were recognised — is exactly the kind of thing that should be pinned by
/// tests rather than by a live session.
enum ListEditorPayload {

    /// One Event List row. The verbatim half cannot be wrong (it is Logic's own
    /// cell text); the parsed half is what an agent branches on, and a column
    /// this code does not recognise degrades to "no parsed field", never to a
    /// missing event or an invented number.
    static func event(from entry: ListEditorEntry) -> [String: Any] {
        var payload = base(entry)
        if let status = entry.field(["Status"]) { payload["type"] = status }
        // Logic's Event List names the two note columns `Num` (pitch) and `Val`
        // (velocity), and the SAME two columns carry controller number and value
        // on a CC row — which is why they keep Logic's names in the verbatim map
        // and only the NOTE reading is spelled out under names of its own.
        if let status = entry.field(["Status"]),
           status.localizedCaseInsensitiveContains("note") {
            if let pitch = entry.field(["Num", "Pitch"]) { payload["pitch"] = pitch }
            if let velocity = entry.field(["Val", "Velocity"]),
               let value = Int(velocity.trimmingCharacters(in: .whitespaces)) {
                payload["velocity"] = value
            }
            if let length = entry.field(["Length/Info", "Length"]) { payload["length"] = length }
        }
        return payload
    }

    /// One Marker List row.
    static func marker(from entry: ListEditorEntry) -> [String: Any] {
        var payload = base(entry)
        if let name = entry.field(["Marker", "Name", "Text"]) { payload["name"] = name }
        return payload
    }

    /// What every row carries: the raw cells, the column-keyed texts, and the
    /// position parsed into bar/beat.
    ///
    /// `cells` is unconditional on purpose. If Logic ever stops publishing the
    /// table header the column-keyed map goes empty, and a row that lost its
    /// fields would otherwise be reported as an empty row rather than as an
    /// event this code could not name.
    private static func base(_ entry: ListEditorEntry) -> [String: Any] {
        var payload: [String: Any] = ["row": entry.index + 1, "cells": entry.cells]
        for (column, value) in entry.fields where !value.isEmpty {
            payload[column] = value
        }
        if let position = entry.field(["Position"]),
           let parsed = TempoMap.parseTempoListPosition(position) {
            payload["bar"] = parsed.bar
            payload["beat"] = parsed.beatInBar
        }
        return payload
    }
}
