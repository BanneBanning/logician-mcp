import ApplicationServices
import Foundation

extension LogicAccessibility {
    /// Temporarily exposes the evidence required by the destructive move. Every
    /// changed display option is restored, and failed restoration is a refusal.
    func midiRegionWitness(trackName: String, trackNumber: Int,
        region: RegionTransfer.Region, meter: MeterMap) throws -> MIDIRegionWitness {
        let census = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
        let (_, plan) = try regionEditPlan(.copy, regionRowNumbers: census.rowNumbers)
        _ = try establishExclusiveRegionSelection(.copy, plan: plan,
            trackName: trackName, regionName: region.name, startBar: region.start.bar,
            trackNumber: trackNumber)
        let parameters = try readRegionParameters(trackName: trackName,
            regionName: region.name, startBar: region.start.bar,
            includeQuantizeValues: false, trackNumber: trackNumber)
        guard let rows = parameters["rows"] as? [[String: Any]], !rows.isEmpty,
              parameters["panel_name"] as? String == region.name else {
            throw RegionTransfer.Failure("region parameters could not be identified")
        }
        let parameterData = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let read = withListEditorsTab(named: LogicUIStrings.Element.ListEditorTab.event) { window in
            Result<MIDIRegionWitness, Error> {
                try self.readMIDIWitness(in: window, region: region, meter: meter, parameters: parameterData)
            }
        }
        guard let value = read.value else {
            throw RegionTransfer.Failure(read.failure?.reason ?? "the Event List is unavailable")
        }
        return try value.get()
    }

    private func readMIDIWitness(in window: AXUIElement, region: RegionTransfer.Region,
                                 meter: MeterMap, parameters: Data) throws -> MIDIRegionWitness {
        func table() throws -> ListEditorTable {
            guard let table = readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.event, in: window).table else {
                throw RegionTransfer.Failure("the Event List table is unavailable")
            }
            return table
        }
        // The pane's group survives its display-option changes. Re-resolve its
        // controls, but do not reread every MIDI row just to open a menu.
        let group = try table().group
        func viewMenu() throws -> AXUIElement {
            try ensureLogicFrontmost(for: "the Event List View menu")
            guard let button = descendants(of: group, maximumDepth: 3).first(where: {
                stringAttribute($0, kAXRoleAttribute as String) == "AXMenuButton"
                    && stringAttribute($0, kAXDescriptionAttribute as String) == "View"
            }) else { throw RegionTransfer.Failure("the Event List View menu is unavailable") }
            pressOpeningTrackingMenu(button)
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            repeat {
                if let menu = popupMenus().first(where: {
                    findMenuItem(in: $0, titled: "Length as Absolute Position") != nil
                }) { return menu }
                Thread.sleep(forTimeInterval: 0.025)
            } while ProcessInfo.processInfo.systemUptime < deadline
            dismissPopupMenus()
            throw RegionTransfer.Failure("the Event List View menu did not open")
        }
        func settings() throws -> [String: Bool] {
            let menu = try viewMenu()
            defer { dismissPopupMenus() }
            var result: [String: Bool] = [:]
            for name in MIDIRegionWitness.viewOptions.map(\.0) + ["Off", "Same Level", "Content"] {
                guard let item = findMenuItem(in: menu, titled: name) else {
                    throw RegionTransfer.Failure("missing Event List setting '\(name)'")
                }
                let mark = stringAttribute(item, "AXMenuItemMarkChar")
                guard mark.isEmpty || mark == "✓" else {
                    throw RegionTransfer.Failure("unrecognised Event List setting state")
                }
                result[name] = mark == "✓"
            }
            return result
        }
        func choose(_ name: String) throws {
            let menu = try viewMenu()
            defer { dismissPopupMenus() }
            guard let item = findMenuItem(in: menu, titled: name),
                  AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                throw RegionTransfer.Failure("could not change Event List setting '\(name)'")
            }
        }
        func checkbox(_ name: String) throws -> (AXUIElement, Bool) {
            let hits = children(of: group).filter {
                stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                    && (stringAttribute($0, kAXTitleAttribute as String) == name
                        || stringAttribute($0, kAXDescriptionAttribute as String) == name)
            }
            guard hits.count == 1, let element = hits.first else {
                throw RegionTransfer.Failure("missing Event List filter '\(name)'")
            }
            let raw = stringAttribute(element, kAXValueAttribute as String)
            guard raw == "0" || raw == "1" else { throw RegionTransfer.Failure("unreadable MIDI filter state") }
            return (element, raw == "1")
        }
        func setCheckbox(_ name: String, _ enabled: Bool) throws {
            let (element, state) = try checkbox(name)
            if state != enabled { _ = AXUIElementPerformAction(element, kAXPressAction as CFString) }
            guard try checkbox(name).1 == enabled else {
                throw RegionTransfer.Failure("Event List filter '\(name)' did not change")
            }
        }

        let original = try settings()
        let links = ["Off", "Same Level", "Content"].filter { original[$0] == true }
        guard links.count == 1 else { throw RegionTransfer.Failure("Event List link mode is unreadable") }
        var changed: [String] = []
        var filters: [(String, Bool)] = []
        var linkChanged = false
        let result = Result<MIDIRegionWitness, Error> {
            if links[0] != "Content" { linkChanged = true; try choose("Content") }
            for (name, enabled) in MIDIRegionWitness.viewOptions where original[name] != enabled {
                changed.append(name)
                try choose(name)
            }
            for name in MIDIRegionWitness.filters {
                let old = try checkbox(name).1
                if !old { filters.append((name, old)); try setCheckbox(name, true) }
            }
            let actual = try settings()
            guard actual["Content"] == true,
                  MIDIRegionWitness.viewOptions.allSatisfy({ actual[$0.0] == $0.1 }) else {
                throw RegionTransfer.Failure("the complete absolute MIDI view was not established")
            }
            let current = try table()
            let regionPaths = children(of: current.group).filter {
                stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.regionPath
            }
            guard regionPaths.count == 1,
                  stringAttribute(regionPaths[0], kAXValueAttribute as String) == region.name,
                  let census = listEditorCensus(of: current).census, census.isComplete,
                  let velocityColumn = current.columns.firstIndex(of: "Val") else {
                throw RegionTransfer.Failure("the Event List is stale, incomplete or showing a different region")
            }
            var velocities: [[Int]] = []
            for row in current.rows {
                let cells = children(of: row.element)
                guard cells.indices.contains(velocityColumn) else { throw RegionTransfer.Failure("missing MIDI value cell") }
                let controls = children(of: cells[velocityColumn])
                guard controls.count == 2 else { throw RegionTransfer.Failure("note-on and note-off velocities are not both exposed") }
                let values = controls.compactMap { Int(stringAttribute($0, kAXValueDescriptionAttribute as String)) }
                guard values.count == 2 else { throw RegionTransfer.Failure("MIDI velocities are unreadable") }
                velocities.append(values)
            }
            return try MIDIRegionWitness(entries: census.entries, velocities: velocities,
                columns: current.columns, declared: current.declaredCount,
                anchor: region.start, meter: meter, parameters: parameters)
        }
        var restoreFailed = false
        for (name, old) in filters.reversed() {
            do { try setCheckbox(name, old) } catch { restoreFailed = true }
        }
        for name in changed.reversed() {
            do {
                if try settings()[name] != original[name] { try choose(name) }
            } catch { restoreFailed = true }
        }
        if linkChanged {
            do { try choose(links[0]) } catch { restoreFailed = true }
        }
        do {
            let restored = try settings()
            if restored != original { restoreFailed = true }
        } catch { restoreFailed = true }
        if restoreFailed {
            throw RegionTransfer.Failure("MIDI comparison display settings could not be fully restored; inspect the Event List")
        }
        return try result.get()
    }
}
