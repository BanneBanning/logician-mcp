import AppKit
import ApplicationServices
import Foundation

// MARK: - Reading the tempo map out of Logic's Tempo List

/// Why a tempo-map read came back empty, in the words a result can carry.
/// Every case is "we do not know the map", never "the project has none" — the
/// distinction the whole tempo-honesty family is built on.
enum TempoListFailure: Equatable {
    case listEditorsUnavailable
    case tempoTabNotFound
    case tableNotFound
    case rowsUnreadable(String)
    case countMismatch(rows: Int, declared: Int)

    var reason: String {
        switch self {
        case .listEditorsUnavailable:
            return "Logic's List Editors pane could not be opened from the View menu"
        case .tempoTabNotFound:
            return "the List Editors pane opened but exposes no Tempo tab"
        case .tableNotFound:
            return "the Tempo tab exposes no table of tempo events"
        case .rowsUnreadable(let detail):
            return "the Tempo List's rows could not be parsed (\(detail))"
        case .countMismatch(let rows, let declared):
            return "the Tempo List published \(rows) row(s) but says it holds \(declared)"
                + " — a partially realised table would integrate a truncated map, so it was"
                + " discarded rather than trusted"
        }
    }
}

extension LogicAccessibility {

    /// Reads the project's whole tempo map out of the Tempo List, or returns
    /// nil with the reason.
    ///
    /// THE ROUTE (found live 2026-08-27, Logic Pro 12.3.1; there is no
    /// "Open Tempo List" menu item — the roadmap's ⌥⇧T floating window does not
    /// exist in this version's menus): `View > List Editors` toggles a pane in
    /// the main window carrying an `AXRadioGroup` of four tabs whose
    /// `AXDescription`s are `Event` / `Marker` / `Tempo` / `Signature`. Pressing
    /// the Tempo radio button reveals `AXGroup` desc `Tempo` → `AXScrollArea` →
    /// `AXTable` with three columns (header buttons titled `Position`, `Tempo`,
    /// `SMPTE Position`). Each `AXRow` has three `AXCell`s and the text lives on
    /// each cell's child `AXGroup`'s **AXDescription**: `"1 1 1 1 "`,
    /// `"120,0000"`, `"01:00:00:00.00"`.
    ///
    /// UI DISCIPLINE: this OPENS a pane and switches a tab, so it restores both
    /// — the previously selected tab is re-pressed and the pane is closed again
    /// with the same menu item, but only if this call was the one that opened it
    /// (a pane the user left open stays open). Nothing is written to the
    /// project; the Tempo List is only read.
    ///
    /// It never throws: a map that cannot be read is a fallback, not a failure —
    /// callers drop back to the two-point sampling that shipped before it.
    func readTempoMap() -> (map: TempoMap?, failure: TempoListFailure?, tempoSet: String?) {
        // The pane discipline (open if closed, restore the tab, close what we
        // opened) lives in `withListEditorsTab` — established here on
        // 2026-08-27 and lifted out when the Event, Marker and Signature tabs
        // needed exactly the same dance.
        let read = withListEditorsTab(named: "Tempo") { self.parseTempoList(in: $0) }
        if let failure = read.failure {
            // The shared vocabulary, translated back into this reader's own —
            // the tempo family's warnings and payloads are written against it.
            switch failure {
            case .paneUnavailable: return (nil, .listEditorsUnavailable, nil)
            case .tabNotFound: return (nil, .tempoTabNotFound, nil)
            default: return (nil, .tableNotFound, nil)
            }
        }
        guard let parsed = read.value else { return (nil, .tableNotFound, nil) }
        return parsed
    }

    /// The four List Editors tabs, by their `AXDescription`, with which one is
    /// selected. Empty when the pane is not open.
    func tempoListTabs(in window: AXUIElement) -> [(name: String, element: AXUIElement, selected: Bool)] {
        var found: [(String, AXUIElement, Bool)] = []
        walk(from: window, maximumDepth: AXDepth.listEditorTab) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXRadioButton" else {
                return .descend
            }
            let name = stringAttribute(element, kAXDescriptionAttribute as String)
            guard LogicUIStrings.Element.listEditorTabs.contains(name) else { return .descend }
            found.append((
                name, element, stringAttribute(element, kAXValueAttribute as String) == "1"
            ))
            return .skipChildren
        }
        // All four or none: a partial match means this is not the tab strip.
        return found.count == 4 ? found.map { (name: $0.0, element: $0.1, selected: $0.2) } : []
    }

    /// Reads the Tempo tab's table with the Tempo tab already showing.
    private func parseTempoList(
        in window: AXUIElement
    ) -> (map: TempoMap?, failure: TempoListFailure?, tempoSet: String?) {
        var table: AXUIElement?
        var declaredCount: Int?
        var tempoSet: String?
        // The Tempo tab's own group carries both the item count and the scroll
        // area, so the search is scoped to it — the Event tab's table must never
        // be mistaken for this one.
        var tempoGroup: AXUIElement?
        walk(from: window, maximumDepth: AXDepth.listEditorTab) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXGroup",
                  stringAttribute(element, kAXDescriptionAttribute as String) == LogicUIStrings.Element.tempo,
                  children(of: element).contains(where: {
                      stringAttribute($0, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.numberOfItems
                  }) else { return .descend }
            tempoGroup = element
            return .stop
        }
        guard let group = tempoGroup else { return (nil, .tableNotFound, nil) }
        walk(from: group, maximumDepth: AXDepth.listEditorTable) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if role == "AXStaticText", description == LogicUIStrings.Element.numberOfItems {
                declaredCount = TempoMap.parseTempoListItemCount(
                    stringAttribute(element, kAXValueAttribute as String)
                )
            }
            // "Tempo Set:" names which of the project's alternative tempo sets
            // is live. Recorded for the payload; the list always shows the
            // active one, which is the one the transport follows.
            if role == "AXPopUpButton", description.isEmpty, tempoSet == nil {
                let value = stringAttribute(element, kAXValueAttribute as String)
                if !value.isEmpty { tempoSet = value }
            }
            if role == "AXTable", table == nil { table = element }
            return .descend
        }
        guard let table else { return (nil, .tableNotFound, tempoSet) }
        let rows = (attribute(table, kAXRowsAttribute as String) as? [AXUIElement])
            ?? children(of: table).filter {
                stringAttribute($0, kAXRoleAttribute as String) == "AXRow"
            }
        var events: [TempoEvent] = []
        var offBeat = false
        for row in rows {
            let cells = children(of: row)
            guard cells.count >= 2 else {
                return (nil, .rowsUnreadable("a row published \(cells.count) cells, expected 3"), tempoSet)
            }
            // The cell's text is its child group's AXDescription, not its value.
            func cellText(_ index: Int) -> String {
                guard let inner = children(of: cells[index]).first else { return "" }
                return stringAttribute(inner, kAXDescriptionAttribute as String)
            }
            guard let position = TempoMap.parseTempoListPosition(cellText(0)) else {
                return (nil, .rowsUnreadable("position '\(cellText(0))' is not bar/beat/division/tick"), tempoSet)
            }
            guard let bpm = TempoMap.parseTempoListBPM(cellText(1)) else {
                return (nil, .rowsUnreadable("tempo '\(cellText(1))' is not a BPM"), tempoSet)
            }
            offBeat = offBeat || position.offBeat
            events.append(TempoEvent(
                bar: position.bar, beatInBar: position.beatInBar, bpm: bpm, rampToNext: false
            ))
        }
        if let declaredCount, declaredCount != events.count {
            return (nil, .countMismatch(rows: events.count, declared: declaredCount), tempoSet)
        }
        guard let map = TempoMap(
            events: events, source: .tempoList, subBeatPositions: offBeat
        ) else {
            return (nil, .rowsUnreadable("no usable tempo events in \(rows.count) row(s)"), tempoSet)
        }
        return (map, nil, tempoSet)
    }
}
