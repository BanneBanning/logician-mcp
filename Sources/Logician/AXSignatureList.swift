import AppKit
import ApplicationServices
import Foundation

// MARK: - Reading the meter map out of Logic's Signature List

extension LogicAccessibility {

    /// Reads the project's meter map out of the Signature tab of the List
    /// Editors pane, or returns nil with the reason.
    ///
    /// THE ROUTE. Identical to `readTempoMap()`'s, one tab over — `View > List
    /// Editors`, press the `Signature` radio button, read the table — which is
    /// why the pane discipline lives in `withListEditorsTab` and not here. (The
    /// Signature List also has a menu item of its own, `Window > Open Signature
    /// List`, unlike the Tempo List; the pane is used anyway so that both maps
    /// are read through one verified mechanism and one restore path.)
    ///
    /// WHAT THE LIST HOLDS. The Signature List carries the project's TIME
    /// signatures and its KEY signatures in the same table. A row whose
    /// signature cell is not an `n/d` is therefore not an error — it is a key
    /// change — so those rows are counted for the truncation cross-check and
    /// then skipped. `keySignatureRows` reports how many were skipped rather
    /// than letting them vanish.
    ///
    /// It never throws: a map that cannot be read means the bar math keeps the
    /// constant-meter assumption it has always had.
    func readMeterMap() -> (map: MeterMap?, failure: ListEditorFailure?, keySignatureRows: Int) {
        let read = withListEditorsTab(named: "Signature") { window in
            self.parseSignatureList(in: window)
        }
        if let failure = read.failure { return (nil, failure, 0) }
        guard let parsed = read.value else {
            return (nil, .tableNotFound("Signature"), 0)
        }
        return parsed
    }

    private func parseSignatureList(
        in window: AXUIElement
    ) -> (map: MeterMap?, failure: ListEditorFailure?, keySignatureRows: Int) {
        let read = readListEditorTable(tab: "Signature", in: window)
        guard let table = read.table else {
            return (nil, read.failure ?? .tableNotFound("Signature"), 0)
        }
        // The truncation cross-check, before anything is parsed: an AX table in
        // a scroll area may publish only the rows it has realised, and a meter
        // map missing its later events would place every later bar CONFIDENTLY
        // WRONG. Counted over ALL rows, key signatures included, because that is
        // what the list counts.
        if let declared = table.declaredCount, declared != table.rows.count {
            return (
                nil,
                .countMismatch(tab: "Signature", rows: table.rows.count, declared: declared),
                0
            )
        }
        // Which column is the position is read off the header rather than
        // assumed: it is column 0 on the Signature tab and column 1 on the
        // Marker tab, and the two tables are read by the same code.
        let positionIndex = table.columns.firstIndex { $0.lowercased().contains("position") } ?? 0
        var events: [MeterEvent] = []
        var keyRows = 0
        for row in table.rows {
            switch MeterMap.parseSignatureRow(cells: row.cells, positionIndex: positionIndex) {
            case .timeSignature(let event):
                events.append(event)
            case .keySignature:
                keyRows += 1
            case .unreadable(let detail):
                return (nil, .rowsUnreadable(tab: "Signature", detail: detail), keyRows)
            }
        }
        guard let map = MeterMap(events: events, source: .signatureList) else {
            // A Signature List with no time signature at all is not a project
            // Logic can have; treat it as unreadable rather than as "no meter".
            return (
                nil,
                .rowsUnreadable(
                    tab: "Signature",
                    detail: "no time signature in \(table.rows.count) row(s)"
                ),
                keyRows
            )
        }
        return (map, nil, keyRows)
    }
}
