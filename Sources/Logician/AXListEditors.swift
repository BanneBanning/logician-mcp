import AppKit
import ApplicationServices
import Foundation

// MARK: - The List Editors pane, shared by all four tabs

/// Why a List Editors read came back empty, in the words a result can carry.
/// Every case is "we do not know", never "the project has none" — the same
/// distinction `TempoListFailure` draws, generalised over the four tabs.
enum ListEditorFailure: Equatable {
    case paneUnavailable
    case tabNotFound(String)
    case tableNotFound(String)
    case rowsUnreadable(tab: String, detail: String)
    case countMismatch(tab: String, rows: Int, declared: Int)

    var reason: String {
        switch self {
        case .paneUnavailable:
            return "Logic's List Editors pane could not be opened from the View menu"
        case .tabNotFound(let tab):
            return "the List Editors pane opened but exposes no \(tab) tab"
        case .tableNotFound(let tab):
            return "the \(tab) tab exposes no table of rows"
        case .rowsUnreadable(let tab, let detail):
            return "the \(tab) List's rows could not be parsed (\(detail))"
        case .countMismatch(let tab, let rows, let declared):
            return "the \(tab) List published \(rows) row(s) but says it holds \(declared)"
                + " — a partially realised table would be read as a truncated list, so it was"
                + " discarded rather than trusted"
        }
    }

    var code: String {
        switch self {
        case .paneUnavailable: return "pane_unavailable"
        case .tabNotFound: return "tab_not_found"
        case .tableNotFound: return "table_not_found"
        case .rowsUnreadable: return "rows_unreadable"
        case .countMismatch: return "count_mismatch"
        }
    }
}

/// One row of a List Editors table, as Accessibility publishes it: the cells'
/// texts in column order, plus the row element itself for the actions
/// (`Delete`) and the selection attribute a write path needs.
struct ListEditorRow {
    let index: Int
    let cells: [String]
    let element: AXUIElement

    func cell(_ index: Int) -> String {
        cells.indices.contains(index) ? cells[index] : ""
    }
}

/// A whole tab's read: its column titles, its rows, and the count the list
/// itself declares — the cross-check that makes a truncated table detectable.
struct ListEditorTable {
    let tab: String
    let columns: [String]
    let rows: [ListEditorRow]
    let declaredCount: Int?
    /// The tab's own group — the one carrying the buttons (`Create new Tempo
    /// Event`, `Additional Info`) and pop-ups (`Tempo Set:`) that sit beside
    /// the table rather than in it.
    let group: AXUIElement
    /// The `AXTable` itself. Stable for as long as the pane is open, which is
    /// what lets a write loop ask it for `AXSelectedRows` instead of walking
    /// the window down to the table again and parsing every row to find the
    /// one that is selected (measured 2026-09-01: 164 ms of the 268 ms each
    /// Event List stepper write cost, and it grew with the region's size).
    let element: AXUIElement
}

extension LogicAccessibility {

    /// Opens the List Editors pane if it is closed, switches to `tab`, runs
    /// `body`, and puts BOTH back: the previously selected tab is re-pressed and
    /// the pane is closed again — but only if this call was the one that opened
    /// it, so a pane the user left open stays open.
    ///
    /// This is the discipline `readTempoMap` established live on 2026-08-27,
    /// lifted out unchanged so the Event, Marker and Signature tabs cannot each
    /// re-invent (or forget) half of it. The restore order matters and is
    /// preserved: tab first, then the pane.
    ///
    /// Never throws: a pane that cannot be opened is a fallback, not a failure.
    /// `body` runs with the tab showing and always produces a value; a failure
    /// INSIDE the tab (unreadable rows, a count mismatch) belongs in that value,
    /// because only the reader knows what its own rows should look like. The
    /// `failure` this returns is the pane's own: it could not be opened, or the
    /// tab is not there.
    func withListEditorsTab<Value>(
        named tab: String,
        body: (AXUIElement) -> Value
    ) -> (value: Value?, failure: ListEditorFailure?) {
        // The pane is a child of the PROJECT window, and `logicWindows()` is
        // ordered by Logic: with any plugin window open, `.first` was that
        // plugin window and the read came back "no tab" while a perfectly
        // readable list sat one window over (FINDINGS 2026-08-28, finding 9).
        guard let window = try? projectWindow() else { return (nil, .paneUnavailable) }
        let wasOpen = tempoListTabs(in: window).isEmpty == false
        if !wasOpen {
            guard (try? pressMenuItem(
                containing: LogicUIStrings.Menu.listEditors, underMenu: LogicUIStrings.Menu.view
            )) != nil else {
                return (nil, .paneUnavailable)
            }
            settleForListEditors(tab: tab, in: window)
        }
        defer {
            if !wasOpen {
                try? pressMenuItem(
                    containing: LogicUIStrings.Menu.listEditors, underMenu: LogicUIStrings.Menu.view
                )
            }
        }
        let tabs = tempoListTabs(in: window)
        guard let target = tabs.first(where: { $0.name == tab }) else {
            return (nil, .tabNotFound(tab))
        }
        let previous = tabs.first(where: \.selected)?.name
        if !target.selected {
            _ = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
            settleForListEditors(tab: tab, in: window)
        }
        // The element to press on the way out is one we are ALREADY HOLDING:
        // `tabs` was read with the pane open, the pane does not close until
        // this function returns, and pressing a sibling tab does not replace
        // the strip. Re-walking the window for it cost 214–230 ms against a ~100 ms
        // press (measured 2026-09-02, `logic_list_signatures` profile §6/C4) —
        // a whole tree walk to find something already in hand.
        let restore = previous.flatMap { name in
            name == tab ? nil : tabs.first(where: { $0.name == name })
        }
        defer {
            if let restore {
                _ = AXUIElementPerformAction(restore.element, kAXPressAction as CFString)
            }
        }
        return (body(window), nil)
    }

    /// The pane repaints after a menu toggle or a tab switch; the table's rows
    /// are not there on the first look. So this WAITS FOR THE TAB, and only
    /// falls back on the clock.
    ///
    /// MEASURED 2026-09-02, twice, and the two settles are NOT the same size:
    ///
    /// - **After the tab switch** (`logic_list_signatures` profile §6/C1) the
    ///   readiness question answered true on the FIRST poll at 64–66 ms, 3/3,
    ///   against the flat 0.6 s — **~535 ms of pure clock-watching** on every
    ///   caller whose tab is not the resting one (Signature, Marker, Tempo, and
    ///   `logic_project_snapshot` twice more).
    /// - **After the pane opens** (`logic_list_events` profile §4) it is real
    ///   work: ready at 286–462 ms there and 523–548 ms in the later
    ///   measurement, the first poll always false. **~50–80 ms**, not the
    ///   200–310 the earlier profile estimated — the pane genuinely needs that
    ///   time and only the tail was slack.
    ///
    /// The old 0.6 s stays as the DEADLINE, so a pane that never becomes
    /// readable costs exactly what it always did and the caller's own count
    /// cross-check still gets the last word.
    ///
    /// Shared by every List Editors tool: `logic_list_events`, `logic_markers`,
    /// `logic_list_signatures`, `logic_tempo_events`, `logic_edit_event`,
    /// `logic_create_marker` and the meter-map read behind all bar math.
    func settleForListEditors(tab: String, in window: AXUIElement) {
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if listEditorTabIsDrawn(tab: tab, in: window) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The cheap half of `readListEditorTable`: is the tab's group there, does
    /// it declare a count, and has its table published that many rows? Not one
    /// cell is read — this is a readiness question, not a read, and it costs
    /// ~60 ms because both walks it makes stop at the table (`ListEditorWalk`).
    ///
    /// Deliberately says "no" when the count is missing or short: the answer
    /// only ever gates a wait that has a deadline, so a false negative costs
    /// the 0.6 s that used to be unconditional, while a false positive would
    /// hand the reader a half-painted table.
    ///
    /// It does NOT ask whether every row has been drawn. A row Logic has
    /// published, counted and not drawn stays that way until the list is
    /// scrolled (`UndrawnListRows`), so waiting for it would spend the whole
    /// deadline on every read after a create and still not get it — the
    /// readers report and name that row instead, which is the honest answer.
    private func listEditorTabIsDrawn(tab: String, in window: AXUIElement) -> Bool {
        guard let group = listEditorTabGroup(tab: tab, in: window) else { return false }
        var table: AXUIElement?
        var declaredCount: Int?
        walk(from: group, maximumDepth: AXDepth.listEditorTable) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXStaticText",
               stringAttribute(element, kAXDescriptionAttribute as String)
                == LogicUIStrings.Element.numberOfItems {
                declaredCount = TempoMap.parseTempoListItemCount(
                    stringAttribute(element, kAXValueAttribute as String)
                )
            }
            if role == "AXTable", table == nil { table = element }
            return ListEditorWalk.step(role: role)
        }
        guard let table, let declaredCount else { return false }
        let rows = (attribute(table, kAXRowsAttribute as String) as? [AXUIElement])?.count
            ?? children(of: table).filter {
                stringAttribute($0, kAXRoleAttribute as String) == "AXRow"
            }.count
        return rows == declaredCount
    }

    /// The tab's OWN group — the one carrying a `Number of Items` child — so
    /// one tab's table can never be mistaken for another's.
    ///
    /// This walk `.stop`s at the group, before it can reach any table, which is
    /// why it is NOT pruned with `ListEditorWalk`: the same probe that found
    /// the pruning worth 115–540 ms on the other two walks measured no
    /// difference here (51.6–56.4 ms either way, 2026-09-02).
    private func listEditorTabGroup(tab: String, in window: AXUIElement) -> AXUIElement? {
        var tabGroup: AXUIElement?
        walk(from: window, maximumDepth: AXDepth.listEditorTab) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXGroup",
                  stringAttribute(element, kAXDescriptionAttribute as String) == tab,
                  children(of: element).contains(where: {
                      stringAttribute($0, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.numberOfItems
                  }) else { return .descend }
            tabGroup = element
            return .stop
        }
        return tabGroup
    }

    /// Reads the currently showing tab's table: column titles, every published
    /// row's cell texts, and the list's own "Number of Items".
    ///
    /// The cell text lives on each cell's child `AXGroup`'s **AXDescription**,
    /// not on any AXValue — the grammar the Tempo tab was verified with on
    /// 2026-08-27 and the other three tabs were confirmed to share on
    /// 2026-08-28. The search is scoped to the tab's OWN group (the one that
    /// carries a "Number of Items" child), so one tab's table can never be
    /// mistaken for another's.
    func readListEditorTable(
        tab: String, in window: AXUIElement
    ) -> (table: ListEditorTable?, failure: ListEditorFailure?) {
        guard let group = listEditorTabGroup(tab: tab, in: window) else {
            return (nil, .tableNotFound(tab))
        }
        var table: AXUIElement?
        var declaredCount: Int?
        walk(from: group, maximumDepth: AXDepth.listEditorTable) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if role == "AXStaticText", description == LogicUIStrings.Element.numberOfItems {
                declaredCount = TempoMap.parseTempoListItemCount(
                    stringAttribute(element, kAXValueAttribute as String)
                )
            }
            if role == "AXTable", table == nil { table = element }
            // `Number of Items` is a SIBLING of the table, never a descendant,
            // so the rows are walked for nothing: 68–75 ms at 25 rows and
            // 308–368 ms at 54 became 4.4–5.4 ms at any size (2026-09-02).
            return ListEditorWalk.step(role: role)
        }
        guard let table else { return (nil, .tableNotFound(tab)) }
        var columns: [String] = []
        if let header = elementAttribute(table, kAXHeaderAttribute as String) {
            columns = children(of: header)
                .map { stringAttribute($0, kAXTitleAttribute as String) }
                .filter { !$0.isEmpty }
        }
        let rowElements = (attribute(table, kAXRowsAttribute as String) as? [AXUIElement])
            ?? children(of: table).filter {
                stringAttribute($0, kAXRoleAttribute as String) == "AXRow"
            }
        let rows = rowElements.enumerated().map { index, row in
            ListEditorRow(
                index: index,
                cells: children(of: row).map(listEditorCellText(of:)),
                element: row
            )
        }
        return (
            ListEditorTable(
                tab: tab, columns: columns, rows: rows,
                declaredCount: declaredCount, group: group, element: table
            ),
            nil
        )
    }

    /// The text of one List Editors cell.
    ///
    /// Measured across all four tabs (2026-08-28), because the shape is NOT one
    /// thing and the tempo research only ever saw the simplest case:
    ///
    /// - Tempo/Marker/Event positions and lengths: one child `AXGroup` whose
    ///   **AXDescription** is the text (`"1 1 1 1 "`, `"4 0 0 0"`, `"∞"`).
    /// - The Event tab's Name cell: one child `AXTextField` with an empty
    ///   description and the text on its **AXValue** (`"Inst 4"`).
    /// - The Event tab's Trk cell and the Marker tab's name cell: a child
    ///   `AXCell` carrying the text on its description.
    /// - The Signature tab's Value cell: **two** children, an `AXSlider` whose
    ///   value is the numerator and an `AXPopUpButton` whose value is `"/4"` —
    ///   so the signature only exists as a string once they are joined.
    /// - The Event tab's Num and Val cells: an `AXSlider` whose **AXValue is not
    ///   the displayed text**. Num reads `51` while Logic shows `D♯2`, and Val
    ///   reads the SAME `3306422272` on every note (a raw 32-bit field, max
    ///   4294967295) while Logic shows the velocity, `98`. Both put the real
    ///   text on **AXValueDescription** — so a reader that trusted AXValue would
    ///   report a constant as every note's velocity, which is worse than
    ///   reporting nothing.
    ///
    /// Hence the order: description, then value DESCRIPTION, then value; every
    /// child joined; and the cell's own attributes when it has no children.
    func listEditorCellText(of cell: AXUIElement) -> String {
        func text(_ element: AXUIElement) -> String {
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if !description.isEmpty { return description }
            let valueDescription = stringAttribute(element, kAXValueDescriptionAttribute as String)
            if !valueDescription.isEmpty { return valueDescription }
            return stringAttribute(element, kAXValueAttribute as String)
        }
        let inner = children(of: cell)
        guard !inner.isEmpty else { return text(cell) }
        return inner.map(text).joined()
    }

    /// The `Delete` action a List Editors row carries. Returns whether the
    /// action was performed — NOT whether the row went away; every caller
    /// re-reads the list for that.
    ///
    /// The action's NAME is not `"Delete"`. Logic publishes these as CUSTOM
    /// actions, and `AXUIElementCopyActionNames` returns the whole descriptor as
    /// the name: `"Name:Delete\nTarget:0x0\nSelector:(null)"`. Performing
    /// `"Delete"` returns an error and does nothing, which is exactly what the
    /// first live run did (2026-08-28) — so the name is looked up rather than
    /// assumed, and any action whose descriptor names Delete is accepted.
    func performListEditorRowDelete(_ row: ListEditorRow) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(row.element, &names) == .success,
              let actions = names as? [String] else { return false }
        guard let delete = actions.first(where: {
            $0.localizedCaseInsensitiveContains(LogicUIStrings.Element.deleteRowAction)
        }) else { return false }
        return AXUIElementPerformAction(row.element, delete as CFString) == .success
    }

    /// Selects exactly one row (`AXSelected` is writable on these rows), which
    /// is what a row-scoped action needs before it fires.
    @discardableResult
    func selectListEditorRow(_ row: ListEditorRow, in table: ListEditorTable) -> Bool {
        for other in table.rows where other.index != row.index {
            _ = AXUIElementSetAttributeValue(
                other.element, kAXSelectedAttribute as CFString, kCFBooleanFalse
            )
        }
        return AXUIElementSetAttributeValue(
            row.element, kAXSelectedAttribute as CFString, kCFBooleanTrue
        ) == .success
    }
}
