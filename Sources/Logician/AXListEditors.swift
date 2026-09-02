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

    /// THE number of rows this list holds: its own `Number of Items`, falling
    /// back to what it published. The same rule `ListEditorCensus.count`
    /// applies, for a write that is polling its own effect and has not built a
    /// census yet — a row Logic counted and has not drawn is still a row.
    var count: Int { declaredCount ?? rows.count }
}

/// A List Editors pane one CALL keeps open across several tab reads.
///
/// WHY. `withListEditorsTab` opens the pane, reads one tab and closes it again,
/// which is right for a tool that reads one list and wrong for a call that reads
/// three. Measured 2026-09-02 (`logic_project_snapshot` profile §5): a cycle
/// costs **765–790 ms** with the pane closed at rest against **383–390 ms** with
/// it already open, and the −380 ms is exactly the open press (73–94 ms), the
/// pane settle (211–244 ms) and the close press (73–95 ms). A snapshot with both
/// map caches cold paid that three times back to back, on the same pane, in one
/// call: **2 615 ms measured live**, of which ~760 ms was a pane it kept
/// reopening.
///
/// IT IS LAZY, and that is the whole design. The hold opens NOTHING: the first
/// nested read that finds the pane closed opens it as it always did, hands the
/// hold its strip, and skips its own close and tab restore; the hold pays those
/// once on the way out. That matters because the sections are usually served
/// from their file caches, so the warm snapshot enters the pane exactly ONCE
/// (for the Marker List) and a hold that opened the pane eagerly paid an
/// open/settle/close for two sections that never came — measured live
/// 2026-09-02: eager 1 004–1 013 ms against 893–895 ms unheld, i.e. +110 ms for
/// nothing. Lazily, the warm call is parity (interleaved live pairs:
/// 1 025 / 1 073 / 1 117 ms held against 1 050 / 1 060 / 1 326 ms unheld) and
/// the cold-cache call, the one that really does read three tabs, went from
/// **2 615 ms to 1 603 ms (−1.0 s, −39%)**.
///
/// WHAT IT IS NOT: a session-level debt. The Region inspector's `InspectorDebt`
/// leaves its disclosure triangles open between calls, and that argument does
/// NOT carry here — the List Editors pane takes its height from the arrangement
/// area, so leaving it open shrinks the Tracks viewport and makes
/// `logic_list_tracks` and `logic_list_regions` report MORE rows missing than
/// the user has. A performance debt that degrades another reader's completeness
/// is not a debt, it is a bug. So the hold is scoped to one call and to the
/// contiguous run of sections that need it, and the pane is closed again before
/// the track and region walks run.
struct ListEditorsPaneHold {
    /// A nested read opened the pane under this hold, so this hold closes it.
    /// A pane the user left open stays open — the rule `withListEditorsTab` has
    /// always applied, unchanged.
    var openedByUs = false
    /// The tab strip, walked once by the first nested read and reused by the
    /// rest: 54–58 ms a walk for four radio buttons already in hand. The
    /// `selected` flags in it go stale as soon as a tab is pressed, so a read
    /// served from here presses its target unconditionally rather than trusting
    /// them — one 102 ms press at worst, and only when a snapshot reads the
    /// same tab twice, which none does.
    var tabs: [(name: String, element: AXUIElement, selected: Bool)]?
    /// The radio button of the tab Logic was resting on when the hold's first
    /// read found the pane (`Event`, 15/15 measured) — in hand, so the one
    /// restore this hold owes needs no second walk.
    var restingTabElement: AXUIElement?
    /// Did any nested read press a different tab? Nothing moved means nothing
    /// to put back, and the press costs 102 ms.
    var pressedATab = false
}

extension LogicAccessibility {

    /// Runs `body` with Logic's List Editors pane held open across every
    /// `withListEditorsTab` inside it: the first one opens the pane as usual,
    /// the rest cost a tab press, its settle and the read, and the pane and its
    /// remembered tab are put back ONCE, here, on the way out.
    ///
    /// See `ListEditorsPaneHold` for the measurement, for why the hold is lazy,
    /// and for why it is a per-CALL scope rather than the session-level debt the
    /// Region inspector keeps.
    ///
    /// Degrades to exactly the old behaviour, never to a failure: a nested read
    /// that cannot open the pane reports its own `paneUnavailable` as before and
    /// leaves nothing owed, and a hold nested inside a hold is a no-op.
    @discardableResult
    func withListEditorsPaneHeld<Value>(_ body: () throws -> Value) rethrows -> Value {
        guard listEditorsPaneHold == nil else { return try body() }
        listEditorsPaneHold = ListEditorsPaneHold()
        defer {
            let hold = listEditorsPaneHold
            listEditorsPaneHold = nil
            // Tab first, then the pane — the restore order `withListEditorsTab`
            // established, and for the same reason: the strip only exists while
            // the pane is open.
            if hold?.pressedATab == true, let element = hold?.restingTabElement {
                _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            }
            if hold?.openedByUs == true {
                try? pressMenuItem(
                    containing: LogicUIStrings.Menu.listEditors,
                    underMenu: LogicUIStrings.Menu.view
                )
            }
        }
        return try body()
    }

    /// Opens the List Editors pane if it is closed, switches to `tab`, runs
    /// `body`, and puts BOTH back: the previously selected tab is re-pressed and
    /// the pane is closed again — but only if this call was the one that opened
    /// it, so a pane the user left open stays open.
    ///
    /// Inside a `withListEditorsPaneHeld` scope the pane is already open, so
    /// neither the open nor the close branch runs, and the tab restore is the
    /// HOLD's — paid once on the way out instead of once per read.
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
        // This walk is BOTH "is the pane open?" and, when it is, the tab strip
        // itself — the same four radio buttons, read once instead of twice. A
        // hold that already walked it hands it over instead (54–58 ms), and
        // answers "open?" by owning the pane.
        let heldStrip = listEditorsPaneHold?.tabs
        var tabs = heldStrip ?? tempoListTabs(in: window)
        let wasOpen = tabs.isEmpty == false
        if !wasOpen {
            guard (try? pressMenuItem(
                containing: LogicUIStrings.Menu.listEditors, underMenu: LogicUIStrings.Menu.view
            )) != nil else {
                return (nil, .paneUnavailable)
            }
            // The settle polls for the strip and HANDS IT BACK, so the walk
            // that used to follow it is gone too.
            tabs = settleForListEditorsPane(tab: tab, in: window)
            // Under a hold it is the HOLD that closes what this read opened,
            // once, after the last of them.
            listEditorsPaneHold?.openedByUs = true
        }
        // The first read under a hold hands over what it found: the strip, and
        // the tab Logic was resting on before anything was pressed.
        if listEditorsPaneHold != nil, heldStrip == nil, !tabs.isEmpty {
            listEditorsPaneHold?.tabs = tabs
            listEditorsPaneHold?.restingTabElement = tabs.first(where: \.selected)?.element
        }
        let holding = listEditorsPaneHold != nil
        defer {
            if !wasOpen, !holding {
                try? pressMenuItem(
                    containing: LogicUIStrings.Menu.listEditors, underMenu: LogicUIStrings.Menu.view
                )
            }
        }
        guard let target = tabs.first(where: { $0.name == tab }) else {
            return (nil, .tabNotFound(tab))
        }
        let previous = tabs.first(where: \.selected)?.name
        // A strip served by the hold carries the `selected` flags of the read
        // BEFORE it, so it cannot say whether the target is already showing:
        // press, rather than trust a flag that may be one tab out of date.
        if !target.selected || heldStrip != nil {
            _ = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
            settleForListEditors(tab: tab, in: window)
            // The hold owes the restore now, and owes exactly one.
            listEditorsPaneHold?.pressedATab = true
        }
        // The element to press on the way out is one we are ALREADY HOLDING:
        // `tabs` was read with the pane open, the pane does not close until
        // this function returns, and pressing a sibling tab does not replace
        // the strip. Re-walking the window for it cost 214–230 ms against a ~100 ms
        // press (measured 2026-09-02, `logic_list_signatures` profile §6/C4) —
        // a whole tree walk to find something already in hand.
        let restore = holding ? nil : previous.flatMap { name in
            name == tab ? nil : tabs.first(where: { $0.name == name })
        }
        defer {
            if let restore {
                _ = AXUIElementPerformAction(restore.element, kAXPressAction as CFString)
            }
        }
        return (body(window), nil)
    }

    /// The settle that follows the pane-OPEN press — and it deliberately asks a
    /// different question from the one after a tab press.
    ///
    /// MEASURED 2026-09-02 (`logic_markers` profile §5, C1). Logic opens the
    /// pane on the tab it was last on: `previousTab == "Event"` **15/15**,
    /// never the tab the caller asked for. So the old call, which waited for
    /// the TARGET tab's table to be drawn, was waiting for something only the
    /// press that comes AFTER it can make true — it ran the deadline out
    /// **15/15, 610–1 094 ms (median 740)**, on every caller whose tab is not
    /// the resting one. The tab strip, which is what the caller needs next,
    /// appears in **58–260 ms**.
    ///
    /// So this waits for the STRIP, and keeps waiting for a drawn table only in
    /// the one case where no press follows — the target tab is already the
    /// selected one, which is the Event tab's own readers, where the old
    /// question was the right one and answered in 286–548 ms. The decision is
    /// `ListEditorSettle.goal`, pure and tested.
    ///
    /// The strip it polled is RETURNED rather than walked for again: 56–251 ms
    /// per walk, for four radio buttons already in hand.
    func settleForListEditorsPane(
        tab: String, in window: AXUIElement
    ) -> [(name: String, element: AXUIElement, selected: Bool)] {
        let deadline = Date().addingTimeInterval(0.6)
        var tabs = tempoListTabs(in: window)
        while true {
            switch ListEditorSettle.goal(
                target: tab, tabs: tabs.map { (name: $0.name, selected: $0.selected) }
            ) {
            case .ready:
                return tabs
            case .targetTabDrawn:
                if listEditorTabIsDrawn(tab: tab, in: window) { return tabs }
            case .tabStrip:
                break
            }
            guard Date() < deadline else { return tabs }
            Thread.sleep(forTimeInterval: 0.05)
            tabs = tempoListTabs(in: window)
        }
    }

    /// The pane repaints after a menu toggle or a tab switch; the table's rows
    /// are not there on the first look. So this WAITS FOR THE TAB, and only
    /// falls back on the clock.
    ///
    /// This is the settle AFTER A TAB PRESS. The one after the pane opens is
    /// `settleForListEditorsPane`, which asks a question that can be true
    /// before the press — see its comment for why they had to be split.
    ///
    /// MEASURED 2026-09-02: the readiness question answered true on the FIRST
    /// poll at 64–66 ms, 3/3 (`logic_list_signatures` profile §6/C1) and again
    /// at 55–349 ms, 15/15 (`logic_markers` profile §5) — this half is healthy,
    /// and it is the half that was already waiting for the right thing.
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

    /// Re-reads the tab's table INSIDE the pane scope until the write it
    /// follows can be seen in it, or until the deadline.
    ///
    /// This is the positive check that replaced the blind sleeps after the
    /// Marker List's create and delete: 0.5 s after a button press that the
    /// next read always found anyway, and 0.4 s after a row action that
    /// measured 13.9 ms (`logic_markers` profile 2026-09-02, C3). A re-read
    /// costs 55–260 ms and answers the real question; the clock answered none.
    ///
    /// Returns the LAST table it read even when it timed out: a poll that ran
    /// out still hands back what Logic is showing, which is what the caller
    /// reports as its readback.
    func pollListEditorTable(
        tab: String, in window: AXUIElement, deadline seconds: TimeInterval = 3.0,
        until isSettled: (ListEditorTable) -> Bool
    ) -> (table: ListEditorTable?, settled: Bool, polls: Int) {
        let deadline = Date().addingTimeInterval(seconds)
        var last: ListEditorTable?
        var polls = 0
        while true {
            polls += 1
            if let table = readListEditorTable(tab: tab, in: window).table {
                last = table
                if isSettled(table) { return (table, true, polls) }
            }
            guard Date() < deadline else { return (last, false, polls) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Selects one row and PROVES it took.
    ///
    /// Replaces the 0.2 s that used to be slept after every marker-row select.
    /// Measured 2026-09-02 (`logic_markers` profile C3, and the `logic_edit_event`
    /// profile before it): the set itself costs 0.3–0.5 ms and `AXSelected`
    /// reads back at 0 ms. The 0.5 s deadline is there for the Logic version
    /// where that stops being true, not for this one.
    @discardableResult
    func selectListEditorRowVerified(_ row: ListEditorRow, in table: ListEditorTable) -> Bool {
        selectListEditorRow(row, in: table)
        let deadline = Date().addingTimeInterval(0.5)
        while true {
            if ["1", "true"].contains(stringAttribute(row.element, kAXSelectedAttribute as String)) {
                return true
            }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
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
