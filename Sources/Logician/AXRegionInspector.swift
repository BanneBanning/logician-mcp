import AppKit
import ApplicationServices
import Foundation

// The Accessibility half of the Region inspector: finding the panel, opening
// it, reading its rows and writing them. What the rows MEAN is
// `RegionInspector.swift`.
//
// The shape, measured live against Logic Pro 12.3.1 on 2026-08-28:
//
//     AXGroup desc='Inspector'
//       AXList
//         AXGroup                      <- the Region panel
//           AXDisclosureTriangle       <- collapsed by default
//           AXTextField  'Crash'       <- the region NAME, and it is writable
//           AXStaticText 'Region:'
//           AXScrollArea               <- only while the triangle is open
//             AXOutline
//               AXRow [label cell, value cell]   x 12, or 22 with "More" open
//         AXGroup                      <- the Track panel
//         AXGroup                      <- the channel strips
//
// Every row is a label cell and a value cell. The value cell is an AXCheckBox
// (AXPress toggles), an AXSlider (AXValue takes an ABSOLUTE write) or an
// AXPopUpButton (AXPress opens a menu whose item is pressed).
extension LogicAccessibility {

    // MARK: - The panel

    struct RegionInspectorPanel {
        let group: AXUIElement
        let disclosure: AXUIElement
        /// The region NAME field — writable, and Logic's own rename route.
        /// Nil when no region is selected: the panel then shows the track's
        /// region defaults and publishes the title as static text, because
        /// there is nothing to rename.
        let nameField: AXUIElement?
        var subject: RegionInspector.PanelSubject
        var panelName: String
    }

    /// One published row of the parameter outline.
    struct RegionInspectorRow {
        let index: Int
        let rawLabel: String
        let label: String
        let value: AXUIElement?
        let control: RegionInspector.Control
        let raw: String
        let display: String?
        let enabled: Bool
        let settable: Bool
        let minimum: Int?
        let maximum: Int?
        let isMoreRow: Bool

        var dictionary: [String: Any] {
            var entry: [String: Any] = [
                "index": index,
                "label": label,
                "control": control.rawValue,
                "enabled": enabled,
                "settable": settable
            ]
            if control == .slider, let number = Int(raw) {
                entry["value"] = number
            } else if control == .checkbox {
                entry["value"] = RegionInspector.checkboxState(raw) as Any? ?? NSNull()
                if RegionInspector.checkboxState(raw) == nil { entry["mixed"] = true }
            } else if !raw.isEmpty {
                entry["value"] = raw
                if raw == RegionInspector.mixedPopupValue { entry["mixed"] = true }
            }
            if let display { entry["display"] = display }
            if let minimum, let maximum { entry["range"] = [minimum, maximum] }
            return entry
        }
    }

    func regionInspectorPanel() throws -> RegionInspectorPanel {
        let window = try projectWindow()
        guard let inspector = firstDescendant(of: window, maximumDepth: AXDepth.inspectorPanel, where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.inspector
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the left inspector is not showing — open it in Logic (View > Show Inspector, or the I key)"
            )
        }
        guard let list = children(of: inspector).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXList"
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the Inspector group published no panel list"
            )
        }
        // The Region panel is the one carrying the static text "Region:";
        // its sibling carries "Track:".
        guard let group = children(of: list).first(where: { panel in
            children(of: panel).contains {
                stringAttribute($0, kAXRoleAttribute as String) == "AXStaticText"
                    && stringAttribute($0, kAXValueAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.regionPanelPrefix)
            }
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "no panel in the left inspector is labelled 'Region:'"
            )
        }
        guard let disclosure = children(of: group).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the Region panel published no disclosure triangle"
            )
        }
        // With a region selected the title is an editable AXTextField (that
        // field IS Logic's rename route). With NOTHING selected the panel
        // shows the track's region defaults and the title is static text —
        // measured 2026-08-28, and the reason this is not a hard requirement.
        let nameField = children(of: group).first {
            stringAttribute($0, kAXRoleAttribute as String) == "AXTextField"
        }
        let name = nameField.map { stringAttribute($0, kAXValueAttribute as String) }
            ?? children(of: group).first {
                stringAttribute($0, kAXRoleAttribute as String) == "AXStaticText"
                    && !stringAttribute($0, kAXValueAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.regionPanelPrefix)
            }.map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
        return RegionInspectorPanel(
            group: group, disclosure: disclosure, nameField: nameField,
            subject: RegionInspector.panelSubject(nameField: name), panelName: name
        )
    }

    /// Presses a disclosure triangle until it reads `open`, and says whether
    /// it had to. Returns nil when the triangle would not move.
    private func setDisclosure(_ triangle: AXUIElement, open: Bool) -> Bool? {
        let want = open ? "1" : "0"
        if stringAttribute(triangle, kAXValueAttribute as String) == want { return false }
        _ = AXUIElementPerformAction(triangle, kAXPressAction as CFString)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.1)
            if stringAttribute(triangle, kAXValueAttribute as String) == want { return true }
        }
        return nil
    }

    private func regionInspectorOutline(_ panel: RegionInspectorPanel) -> AXUIElement? {
        firstDescendant(of: panel.group, maximumDepth: AXDepth.regionInspectorOutline) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXOutline"
        }
    }

    /// Opens the panel (and, when asked, the "More" section), runs `body` and
    /// puts BOTH disclosures back the way they were found — the same
    /// discipline the List Editors reads follow. The panel is Logic's UI
    /// state, not the caller's.
    func withRegionInspector<Result>(
        needMore: Bool,
        _ body: (RegionInspectorPanel, [RegionInspectorRow]) throws -> Result
    ) throws -> (result: Result, panelState: [String: Any]) {
        var panel = try regionInspectorPanel()
        var state: [String: Any] = [:]

        let panelWasClosed = stringAttribute(panel.disclosure, kAXValueAttribute as String) != "1"
        if panelWasClosed {
            guard setDisclosure(panel.disclosure, open: true) != nil else {
                throw LogicianError.trackNotExposed(
                    requested: "the Region inspector's parameters",
                    exposed: "the panel's disclosure triangle did not open"
                )
            }
            state["region_panel"] = "opened and restored"
        } else {
            state["region_panel"] = "already open"
        }
        defer {
            if panelWasClosed { _ = setDisclosure(panel.disclosure, open: false) }
        }

        // Re-read: the name field is the same element, but the panel's own
        // children change when it opens.
        panel = try regionInspectorPanel()
        guard let outline = regionInspectorOutline(panel) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector's parameter rows",
                exposed: "the open panel published no outline"
            )
        }

        var moreTriangle: AXUIElement?
        var moreWasClosed = false
        if let row = regionInspectorRawRows(outline).first(where: { hasDisclosure($0) }),
           let triangle = firstDescendant(of: row, maximumDepth: 2, where: {
               stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
           }) {
            moreTriangle = triangle
            moreWasClosed = stringAttribute(triangle, kAXValueAttribute as String) != "1"
            if needMore, moreWasClosed {
                guard setDisclosure(triangle, open: true) != nil else {
                    throw LogicianError.trackNotExposed(
                        requested: "the Region inspector's 'More' rows",
                        exposed: "the More disclosure did not open"
                    )
                }
                state["more"] = "opened and restored"
            } else {
                state["more"] = moreWasClosed ? "closed" : "already open"
            }
        }
        defer {
            if needMore, moreWasClosed, let triangle = moreTriangle {
                _ = setDisclosure(triangle, open: false)
            }
        }

        let rows = regionInspectorRows(outline)
        return (try body(panel, rows), state)
    }

    private func hasDisclosure(_ row: AXUIElement) -> Bool {
        firstDescendant(of: row, maximumDepth: 2) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
        } != nil
    }

    private func regionInspectorRawRows(_ outline: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(outline, "AXRows") as? [AXUIElement] else { return [] }
        return value
    }

    func regionInspectorRows(_ outline: AXUIElement) -> [RegionInspectorRow] {
        regionInspectorRawRows(outline).enumerated().map { index, row in
            let cells = children(of: row)
            let more = hasDisclosure(row)
            let rawLabel = cells.first.map { cell -> String in
                if stringAttribute(cell, kAXRoleAttribute as String) == "AXGroup" {
                    return children(of: cell)
                        .first { stringAttribute($0, kAXRoleAttribute as String) == "AXTextField" }
                        .map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
                }
                return stringAttribute(cell, kAXValueAttribute as String)
            } ?? ""
            let valueCell = cells.count > 1 ? cells[1] : nil
            let role = valueCell.map { stringAttribute($0, kAXRoleAttribute as String) } ?? ""
            var control: RegionInspector.Control
            switch role {
            case "AXCheckBox": control = .checkbox
            case "AXSlider": control = .slider
            case "AXPopUpButton": control = .popup
            default: control = .other
            }
            // Logic parks the rows a region type does not use at "-", disabled
            // in both cells. Reported as placeholders, never written.
            if RegionInspector.normalizedLabel(rawLabel) == "-" { control = .placeholder }
            // The audio "File Tempo" row is three segment sliders rather than
            // one control; it is read as `other` and not written.
            if cells.count > 2, !more { control = .other }
            let raw = valueCell.map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
            let published = valueCell
                .map { stringAttribute($0, kAXValueDescriptionAttribute as String) } ?? ""
            return RegionInspectorRow(
                index: index,
                rawLabel: rawLabel,
                label: RegionInspector.normalizedLabel(rawLabel),
                value: valueCell,
                control: control,
                raw: raw,
                display: RegionInspector.displayText(published),
                enabled: valueCell.map { stringAttribute($0, kAXEnabledAttribute as String) == "1" } ?? false,
                settable: valueCell.map { isSettable($0, kAXValueAttribute as String) } ?? false,
                minimum: valueCell.flatMap { Int(stringAttribute($0, kAXMinValueAttribute as String)) },
                maximum: valueCell.flatMap { Int(stringAttribute($0, kAXMaxValueAttribute as String)) },
                isMoreRow: more
            )
        }
    }

    func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success else {
            return false
        }
        return flag.boolValue
    }

    /// The region type the panel itself is showing, read off the rows Logic
    /// published rather than off the arrangement map — an independent second
    /// source, and the only one available when several regions are selected.
    func inferredRegionType(_ rows: [RegionInspectorRow]) -> String? {
        let labels = Set(rows.map(\.label))
        if labels.contains("Velocity Offset") || labels.contains("Dynamics") { return RegionInspector.midi }
        if labels.contains("Gain") || labels.contains("Fine Tune") { return RegionInspector.audio }
        return nil
    }

    // MARK: - Pop-up menus

    /// The Region inspector's pop-up menus are parented deeper than
    /// `popupMenus()` looks, so this walk has its own cap. See
    /// `AXDepth.regionInspectorMenu`.
    private func inspectorMenus() -> [AXUIElement] {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menus: [AXUIElement] = []
        walk(from: appElement, maximumDepth: AXDepth.regionInspectorMenu) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXMenuBar" { return .skipChildren }
            if role == "AXMenu" { menus.append(element); return .skipChildren }
            return .descend
        }
        return menus
    }

    private func dismissInspectorMenus() {
        for menu in inspectorMenus() {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    /// Opens one pop-up's menu, hands it to `body`, and ALWAYS dismisses it —
    /// a menu left standing swallows Logic's keyboard and with it every key
    /// command the next tool fires.
    ///
    /// `AXPress` reports AXError -25205 here even when the menu opens, exactly
    /// as it does in the insert slot's plugin chooser and the plugin setting
    /// menu, so the press is verified by finding the menu and never by the
    /// status code.
    private func withInspectorMenu<Result>(
        _ popup: AXUIElement,
        _ body: (AXUIElement) throws -> Result
    ) throws -> Result {
        try ensureLogicFrontmost(for: "the Region inspector's pop-up")
        dismissInspectorMenus()
        var opened: AXUIElement?
        pressing: for attempt in 0..<3 {
            _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
            for _ in 0..<(attempt == 2 ? 20 : 8) {
                Thread.sleep(forTimeInterval: 0.15)
                if let menu = inspectorMenus().first { opened = menu; break pressing }
            }
            dismissInspectorMenus()
        }
        guard let menu = opened else {
            dismissInspectorMenus()
            throw LogicianError.openVerificationFailed(
                "the Region inspector pop-up's menu did not open"
            )
        }
        defer {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            dismissInspectorMenus()
            Thread.sleep(forTimeInterval: 0.3)
        }
        return try body(menu)
    }

    private func menuTitles(_ menu: AXUIElement) -> [String] {
        children(of: menu)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
            .map { stringAttribute($0, kAXTitleAttribute as String) }
            .filter { !$0.isEmpty }
    }

    /// Reads a pop-up's whole menu without changing anything.
    func regionInspectorMenuOptions(_ popup: AXUIElement) throws -> [String] {
        try withInspectorMenu(popup) { menu in menuTitles(menu) }
    }

    /// Presses one item by exact (case-insensitive) title. Never fuzzy: a near
    /// miss is refused with the real list, because picking the wrong quantize
    /// grid is a musical change nobody asked for.
    private func pickInspectorMenuItem(
        _ popup: AXUIElement, title: String, parameter: String
    ) throws {
        try withInspectorMenu(popup) { menu in
            let items = children(of: menu)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
            func titleOf(_ item: AXUIElement) -> String {
                stringAttribute(item, kAXTitleAttribute as String)
            }
            var chosen = items.first {
                titleOf($0).compare(title, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }
            if chosen == nil {
                // The fade Type pop-up DISPLAYS "X" for the item spelled
                // "X (Crossfade)", so the value read off Logic is not a legal
                // argument unless the short form is accepted too. Ambiguity is
                // still refused: two items with the same head is no answer.
                let heads = items.filter {
                    RegionInspector.popupValuesMatch(titleOf($0), title)
                }
                if heads.count == 1 { chosen = heads[0] }
            }
            guard let item = chosen else {
                throw LogicianError.presetNotFound(
                    plugin: "the Region inspector's \(parameter) pop-up",
                    requested: title,
                    available: menuTitles(menu)
                )
            }
            guard stringAttribute(item, kAXEnabledAttribute as String) == "1" else {
                throw LogicianError.valueNotWritable(
                    "'\(title)' is disabled in the \(parameter) menu"
                )
            }
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    // MARK: - Read

    func readRegionParameters(
        trackName: String?, regionName: String?, startBar: Int?, includeQuantizeValues: Bool
    ) throws -> [String: Any] {
        var addressed: [String: Any]?
        if let trackName {
            addressed = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
            )
        }
        let (payload, panelState) = try withRegionInspector(needMore: true) { panel, rows in
            var result: [String: Any] = [
                "project_document": (try? projectDocumentPath()) ?? NSNull(),
                "panel_name": panel.panelName,
                "subject": self.subjectDictionary(panel.subject),
                "rows": rows.filter { !$0.isMoreRow }.map(\.dictionary)
            ]
            if let type = self.inferredRegionType(rows) { result["region_type"] = type }
            result["parameters"] = self.namedParameters(rows)
            if includeQuantizeValues {
                if let quantize = rows.first(where: {
                    RegionInspector.parameter(forLabel: $0.label)?.key == "quantize"
                }), let popup = quantize.value {
                    result["quantize_values"] = try self.regionInspectorMenuOptions(popup)
                    result["quantize_values_note"] = "Logic's own quantize menu, verbatim — the "
                        + "vocabulary logic_set_region_params accepts for `quantize`. Separator rows "
                        + "are omitted; 'Make Groove Template' and 'Remove Groove Template from List' "
                        + "are commands rather than values and this server does not press them."
                }
            }
            return result
        }
        var result = payload
        result["panel_state"] = panelState
        if let addressed {
            result["region"] = [
                "track_name": addressed["track_name"] ?? "",
                "name": addressed["name"] ?? "",
                "start_bar": addressed["start_bar"] ?? NSNull(),
                "end_bar": addressed["end_bar"] ?? NSNull(),
                "type": addressed["type"] ?? NSNull()
            ]
        }
        result["note"] = "Every row the Region inspector publishes, in Logic's own order, plus the "
            + "named parameters logic_set_region_params can write. A row that is disabled is one "
            + "the region type does not use, or one Logic gates behind another setting (every Q-row "
            + "is dead while Quantize is Off). 'display' is Logic's own text and is ABSENT at a "
            + "parameter's default, which Logic prints blank."
        return result
    }

    private func subjectDictionary(_ subject: RegionInspector.PanelSubject) -> [String: Any] {
        switch subject {
        case .region(let name): return ["kind": "region", "name": name]
        case .multiple(let count): return ["kind": "multiple", "count": count]
        case .defaults(let kind): return ["kind": "defaults", "defaults_for": kind]
        }
    }

    /// Resolves every shipped parameter to the ROW it is, by position in
    /// Logic's own order — never by label alone, because the audio panel
    /// publishes two rows called `Curve`.
    func regionParameterRows(
        _ rows: [RegionInspectorRow]
    ) -> [String: RegionInspectorRow] {
        let indexes = RegionInspector.rowIndexes(labels: rows.map(\.label))
        var resolved: [String: RegionInspectorRow] = [:]
        for (key, index) in indexes where rows.indices.contains(index) {
            resolved[key] = rows[index]
        }
        return resolved
    }

    private func namedParameters(_ rows: [RegionInspectorRow]) -> [String: Any] {
        var named: [String: Any] = [:]
        for (key, row) in regionParameterRows(rows) {
            guard let parameter = RegionInspector.parameter(key: key) else { continue }
            // `writable` is what an agent needs, and it is NOT the AXValue
            // settable flag: a checkbox and a pop-up publish an unsettable
            // AXValue and are written by pressing them. Only a slider is
            // written through AXValue, and only while its row is enabled.
            var entry: [String: Any] = [
                "enabled": row.enabled,
                "writable": row.enabled && (row.control == .slider ? row.settable : true),
                // Which ROW this is, in Logic's own order. It is the address
                // the write path uses, and the only thing that tells the two
                // `Curve` rows apart.
                "row": row.index
            ]
            // A row whose LABEL is a pop-up can be in another mode, and then
            // the value is another quantity: `Speed Up` rather than `Fade-In`.
            if row.label.caseInsensitiveCompare(parameter.labels[0]) != .orderedSame {
                entry["row_label"] = row.label
            }
            switch row.control {
            case .checkbox:
                if let state = RegionInspector.checkboxState(row.raw) {
                    entry["value"] = state
                } else {
                    entry["value"] = NSNull()
                    entry["mixed"] = true
                }
            case .slider:
                guard let raw = Int(row.raw) else { continue }
                for (field, value) in RegionInspector.report(
                    key: parameter.key, raw: raw, published: row.display ?? ""
                ) { entry[field] = value }
            case .popup:
                entry["value"] = row.raw
                if row.raw == RegionInspector.mixedPopupValue { entry["mixed"] = true }
            default:
                continue
            }
            named[parameter.key] = entry
        }
        return named
    }

    // MARK: - Write

    /// One requested change, already validated against the catalogue.
    private struct PlannedWrite {
        let parameter: RegionInspector.Parameter
        let sliderValue: Int?
        let popupValue: String?
        let checkboxValue: Bool?
        let expected: Any?
    }

    func setRegionParameters(
        trackName: String?, regionName: String?, startBar: Int?,
        scope: String, arguments: [String: Any], expected: [String: Any]
    ) throws -> [String: Any] {
        // 1. What was asked for, checked before anything is touched.
        var planned: [PlannedWrite] = []
        for key in RegionInspector.writeOrder {
            guard let argument = arguments[key] else { continue }
            guard let parameter = RegionInspector.parameter(key: key) else { continue }
            switch parameter.control {
            case .checkbox:
                guard let flag = argument as? Bool else {
                    throw LogicianError.invalidArguments("\(key) takes true or false")
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: nil, popupValue: nil,
                    checkboxValue: flag, expected: expected[key]
                ))
            case .popup:
                guard let text = argument as? String else {
                    throw LogicianError.invalidArguments("\(key) takes a string, as the menu spells it")
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: nil, popupValue: text,
                    checkboxValue: nil, expected: expected[key]
                ))
            default:
                let value: Int
                do {
                    value = try RegionInspector.sliderValue(key: key, argument: argument)
                } catch let error as RegionInspector.ValueError {
                    throw LogicianError.invalidArguments(Self.describe(error))
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: value, popupValue: nil,
                    checkboxValue: nil, expected: expected[key]
                ))
            }
        }
        guard !planned.isEmpty else {
            throw LogicianError.invalidArguments(
                "nothing to set: pass at least one of "
                    + RegionInspector.writeOrder.joined(separator: ", ")
            )
        }
        let unknown = Set(expected.keys).subtracting(planned.map(\.parameter.key))
        guard unknown.isEmpty else {
            throw LogicianError.invalidArguments(
                "expected_current names parameters that are not being set: "
                    + unknown.sorted().joined(separator: ", ")
            )
        }

        // 2. A MULTI-SELECTION MAKES EVERY SLIDER RELATIVE. Measured
        //    2026-08-28: with two regions selected, a slider reads its own
        //    DEFAULT (Q-Strength 100, Q-Swing 50) whatever the regions hold,
        //    an AXValue write applies the DELTA from that default to each
        //    region separately (50 and 90 both moved by -10 when 90 was
        //    written), and the control snaps straight back to the default — so
        //    the write is neither absolute nor verifiable. Pop-ups and
        //    checkboxes are absolute over a selection and read back correctly,
        //    so those are what `selection` ships with.
        if scope == "selection" {
            let relative = planned
                .filter { $0.parameter.control != .popup && $0.parameter.control != .checkbox }
                .map(\.parameter.key)
            guard relative.isEmpty else {
                throw LogicianError.preconditionUnmet(
                    "scope 'selection' cannot set \(relative.joined(separator: ", ")): over a "
                        + "multi-selection Logic turns every numeric region control into a RELATIVE "
                        + "one — it shows the parameter's default, applies the difference to each "
                        + "region, and springs back, so the value cannot be set or verified "
                        + "(measured 2026-08-28). Nothing was written. The pop-up and checkbox "
                        + "parameters ARE absolute over a selection ("
                        + RegionInspector.writable
                            .filter { $0.control == .popup || $0.control == .checkbox }
                            .map(\.key).sorted().joined(separator: ", ")
                        + "); for the numeric ones address the regions one at a time with "
                        + "scope 'region'."
                )
            }
        }

        // 3. Address the region. `selection` deliberately leaves the selection
        //    alone: writing through a multi-selection is how one call reaches
        //    a whole track (measured: both selected regions took the write).
        var addressed: [String: Any]?
        var selectedCount: Int?
        if scope == "selection" {
            selectedCount = try? selectedRegionCount()
        } else {
            guard let trackName else {
                throw LogicianError.invalidArguments("scope 'region' needs track_name")
            }
            addressed = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
            )
            guard try selectedRegionCount() == 1 else {
                throw LogicianError.verificationFailed(
                    requested: "exactly one selected region before writing",
                    actual: "the selection drifted; refusing", restored: true
                )
            }
        }

        let needMore = planned.contains { $0.parameter.underMore }
        let (payload, panelState) = try withRegionInspector(needMore: needMore) { panel, rows in
            try self.applyRegionWrites(
                panel: panel, rows: rows, planned: planned, scope: scope,
                addressed: addressed, selectedCount: selectedCount
            )
        }
        var result = payload
        result["panel_state"] = panelState
        return result
    }

    private static func describe(_ error: RegionInspector.ValueError) -> String {
        switch error {
        case .notANumber(let key, let given, let unit):
            return "\(key) takes a whole number\(unit.isEmpty ? "" : " in \(unit)"); got '\(given)'"
        case .outOfRange(let key, let given, let range, let unit):
            return "\(key) = \(given) is outside Logic's own range "
                + "\(range.lowerBound)…\(range.upperBound)\(unit.isEmpty ? "" : " \(unit)")"
        case .outOfDecibelRange(let key, let given, let limit):
            return "\(key) = \(given) dB is outside Logic's own region-gain range "
                + "-\(limit)…+\(limit) dB"
        case .unknownName(let key, let given, let available):
            return "\(key) does not take '\(given)'; Logic's values are "
                + available.joined(separator: ", ")
        case .outOfRangeForRegionType(let key, let given, let range, let unit, let regionType):
            return "\(key) = \(given) is outside the range Logic gives \(regionType) regions, "
                + "\(range.lowerBound)…\(range.upperBound)\(unit.isEmpty ? "" : " \(unit)")"
        }
    }

    private func applyRegionWrites(
        panel: LogicAccessibility.RegionInspectorPanel,
        rows: [RegionInspectorRow],
        planned: [PlannedWrite],
        scope: String,
        addressed: [String: Any]?,
        selectedCount: Int?
    ) throws -> [String: Any] {
        // Whose parameters are on screen? A write into "MIDI Defaults" would
        // change what every FUTURE region on the track inherits, silently.
        switch panel.subject {
        case .defaults(let kind):
            throw LogicianError.preconditionUnmet(
                "No region is selected: the Region inspector is showing the track's \(kind) "
                    + "region DEFAULTS, which decide what every future region on that track "
                    + "inherits. Nothing was written. Select a region first — pass track_name "
                    + "with region_name/start_bar, or use logic_select_regions for a scope "
                    + "'selection' write."
            )
        case .multiple(let count):
            guard scope == "selection" else {
                throw LogicianError.preconditionUnmet(
                    "\(count) regions are selected and the Region inspector is showing them "
                        + "together. Nothing was written. Pass scope: 'selection' to write to all "
                        + "of them on purpose, or address one region with track_name + start_bar."
                )
            }
        case .region:
            break
        }

        let regionType = inferredRegionType(rows)

        // EVERY argument is checked against the region type BEFORE the first
        // write, not as its turn comes: a call that names one audio parameter
        // and one MIDI one must write neither, rather than write the first and
        // then refuse. Same for the ranges that depend on the type — audio
        // Transpose caps at ±36 where MIDI runs to ±96.
        var addressedRows = regionParameterRows(rows)
        for write in planned {
            let parameter = write.parameter
            if let regionType, !parameter.regionTypes.contains(regionType) {
                throw LogicianError.valueNotWritable(
                    "\(parameter.key) is a \(parameter.regionTypes.sorted().joined(separator: "/"))"
                        + "-region parameter and this is \(regionType == RegionInspector.midi ? "a MIDI" : "an audio")"
                        + " region — the inspector does not show it. Nothing was written."
                )
            }
            if let value = write.sliderValue {
                do {
                    try RegionInspector.checkRange(
                        key: parameter.key, value: value, regionType: regionType
                    )
                } catch let error as RegionInspector.ValueError {
                    throw LogicianError.invalidArguments(Self.describe(error) + "; nothing was written")
                }
            }
            // Compare-and-set is checked here too, for the same reason: "any
            // mismatch writes nothing" has to mean nothing, including the
            // parameters that come before the one that mismatched.
            if write.expected != nil, let row = addressedRows[parameter.key] {
                try enforceExpectation(write, row: row)
            }
        }

        var changed: [[String: Any]] = []
        var unchanged: [[String: Any]] = []
        var currentRows = rows

        for write in planned {
            let parameter = write.parameter
            guard let row = addressedRows[parameter.key], let control = row.value else {
                // Reverse is the row that actually goes missing in practice:
                // Logic replaces it with a placeholder while FLEX is on, and
                // transposing or fine-tuning an audio region switches Flex on
                // by itself (measured 2026-08-28 — transpose 12 made row 18
                // read "-", transpose 0 brought Reverse back, still ticked).
                let flexIsOn = currentRows.first { $0.label == "Flex" }?.raw == "1"
                throw LogicianError.parameterNotFound(
                    "the Region inspector published no '\(parameter.labels[0])' row"
                        + (parameter.underMore ? " (it lives under 'More')" : "")
                        + (parameter.after.isEmpty
                            ? ""
                            : " that follows the '\(parameter.after[0])' row — the panel has two rows "
                                + "called '\(parameter.labels[0])' and this one is addressed by position")
                        + (parameter.key == "reverse" && flexIsOn
                            ? ". Flex is ON for this region, and Logic hides Reverse entirely while "
                                + "it is: transposing or fine-tuning an audio region switches Flex on "
                                + "by itself, so set transpose and fine_tune back to 0 to get Reverse "
                                + "back (the setting survives — it is the row that disappears)"
                            : "")
                )
            }
            // The two fade rows carry a MODE pop-up as their label: the same
            // control is a fade length or a `Speed Up`/`Slow Down` ramp length,
            // and writing 400 ms of "fade" into a speed-up ramp would be a
            // silent wrong answer rather than an error.
            if parameter.refuseAlternateMode,
               row.label.caseInsensitiveCompare(parameter.labels[0]) != .orderedSame {
                throw LogicianError.preconditionUnmet(
                    "the row \(parameter.key) writes is switched to '\(row.label)' mode in Logic "
                        + "(its label is a pop-up: '\(parameter.labels.joined(separator: "' / '"))'), "
                        + "so its value is a \(row.label.lowercased()) length and not a fade length. "
                        + "Nothing was written. Switch the row back to '\(parameter.labels[0])' in "
                        + "Logic's Region inspector first."
                )
            }
            guard row.enabled else {
                throw LogicianError.valueNotWritable(
                    "the '\(row.label)' row is disabled"
                        + (parameter.key.hasPrefix("q_")
                            ? " — Logic greys every Q-row out while Quantize is Off; set quantize in the same call"
                            : "")
                )
            }

            let before = describeRow(row, parameter: parameter)
            var route = ""
            switch parameter.control {
            case .checkbox:
                guard let target = write.checkboxValue else { continue }
                let state = RegionInspector.checkboxState(row.raw)
                if state == target {
                    unchanged.append(["parameter": parameter.key, "value": target])
                    continue
                }
                // The control publishes only AXPress, so this is a converge
                // rather than a write — and over a multi-selection whose
                // regions DISAGREE it starts from Logic's mixed state (AXValue
                // 2), where one press turns them all ON. Reaching OFF from
                // there therefore takes two presses; the loop is capped at two
                // and the read-back below is what decides.
                for _ in 0..<2 {
                    _ = AXUIElementPerformAction(control, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.35)
                    if RegionInspector.checkboxState(
                        stringAttribute(control, kAXValueAttribute as String)
                    ) == target { break }
                }
                route = state == nil ? "ax_checkbox_press_from_mixed" : "ax_checkbox_press"
            case .popup:
                guard let target = write.popupValue else { continue }
                if RegionInspector.popupValuesMatch(row.raw, target) {
                    unchanged.append(["parameter": parameter.key, "value": row.raw])
                    continue
                }
                try pickInspectorMenuItem(control, title: target, parameter: parameter.key)
                route = "ax_popup_menu_press"
            default:
                guard let target = write.sliderValue else { continue }
                if Int(row.raw) == target {
                    unchanged.append([
                        "parameter": parameter.key,
                        "value": RegionInspector.report(
                            key: parameter.key, raw: target, published: row.display ?? ""
                        )
                    ])
                    continue
                }
                let status = AXUIElementSetAttributeValue(
                    control, kAXValueAttribute as CFString, NSNumber(value: target)
                )
                guard status == .success else {
                    throw LogicianError.writeFailed(
                        "the AXValue write on '\(row.label)' returned AXError \(status.rawValue)"
                    )
                }
                route = "ax_value_absolute"
            }
            Thread.sleep(forTimeInterval: 0.35)

            // Read back off Logic, then re-read the whole outline: setting
            // Quantize ENABLES six other rows, so the rows a later write in
            // this same call needs are not the ones read at the top.
            guard let outline = firstDescendant(
                of: panel.group, maximumDepth: AXDepth.regionInspectorOutline, where: {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXOutline"
                }
            ) else {
                throw LogicianError.verificationFailed(
                    requested: "a read-back of '\(row.label)'",
                    actual: "the parameter outline vanished after the write", restored: false
                )
            }
            currentRows = regionInspectorRows(outline)
            addressedRows = regionParameterRows(currentRows)
            guard let after = addressedRows[parameter.key] else {
                throw LogicianError.verificationFailed(
                    requested: "a read-back of '\(row.label)'",
                    actual: "the row vanished after the write", restored: false
                )
            }
            try verify(write, row: after, parameter: parameter)
            changed.append([
                "parameter": parameter.key,
                "row": after.index,
                "before": before,
                "after": describeRow(after, parameter: parameter),
                "write_route": route
            ])
        }

        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": changed.isEmpty ? "already_set" : "region_params_set",
            "scope": scope,
            "changed": changed,
            "unchanged": unchanged,
            "panel_name": panel.panelName,
            "subject": subjectDictionary(panel.subject)
        ]
        if let regionType { result["region_type"] = regionType }
        if let addressed {
            result["region"] = [
                "track_name": addressed["track_name"] ?? "",
                "name": addressed["name"] ?? "",
                "start_bar": addressed["start_bar"] ?? NSNull(),
                "type": addressed["type"] ?? NSNull()
            ]
        }
        if scope == "selection" {
            result["regions_affected"] = selectedCount ?? NSNull()
            result["selection_note"] = "Every SELECTED region took these values — measured, not "
                + "assumed. The count is the arrangement map's, which sees visible track rows only, "
                + "so the write can have reached more regions than the number shown."
        }
        result["note"] = "Region parameters are Logic's own non-destructive playback settings: the "
            + "recorded notes and the audio file on disk are untouched, so quantize, transpose, "
            + "gain, the fades and reverse are all reversible by setting them back. They do change "
            + "how the region SOUNDS."
        return result
    }

    private func describeRow(
        _ row: RegionInspectorRow, parameter: RegionInspector.Parameter
    ) -> Any {
        switch parameter.control {
        case .checkbox:
            return RegionInspector.checkboxState(row.raw) as Any? ?? "mixed"
        case .popup:
            return row.raw
        default:
            guard let raw = Int(row.raw) else { return row.raw }
            return RegionInspector.report(
                key: parameter.key, raw: raw, published: row.display ?? ""
            )
        }
    }

    /// Compare-and-set. A parameter reading as MIXED across a multi-selection
    /// cannot be compared to one expected value, and is refused rather than
    /// guessed at.
    private func enforceExpectation(_ write: PlannedWrite, row: RegionInspectorRow) throws {
        guard let expected = write.expected else { return }
        let key = write.parameter.key
        switch write.parameter.control {
        case .checkbox:
            guard let wanted = expected as? Bool else {
                throw LogicianError.invalidArguments("expected_current.\(key) takes true or false")
            }
            guard let actual = RegionInspector.checkboxState(row.raw) else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)",
                    actual: "\(key) differs between the selected regions (Logic's mixed state)"
                )
            }
            guard actual == wanted else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)", actual: "\(key) = \(actual)"
                )
            }
        case .popup:
            guard let wanted = expected as? String else {
                throw LogicianError.invalidArguments("expected_current.\(key) takes a string")
            }
            guard RegionInspector.popupValuesMatch(row.raw, wanted) else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = '\(wanted)'", actual: "\(key) = '\(row.raw)'"
                )
            }
        default:
            let wanted: Int
            do {
                wanted = try RegionInspector.sliderValue(key: key, argument: expected)
            } catch let error as RegionInspector.ValueError {
                throw LogicianError.invalidArguments("expected_current." + Self.describe(error))
            }
            guard Int(row.raw) == wanted else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)", actual: "\(key) = \(row.raw)"
                )
            }
        }
    }

    // MARK: - Rename

    /// Renames one region by writing the Region inspector's own name field.
    ///
    /// There is no rename DIALOG and no key command in this path: the panel's
    /// title is an `AXTextField` whose `AXValue` is settable (measured
    /// 2026-08-28), so the rename is one write and one confirm. The field is a
    /// direct child of the panel group and is published whether the panel's
    /// disclosure triangle is open or shut, so nothing is unfolded here and
    /// the inspector is left exactly as it was found.
    ///
    /// Verified twice over: the panel reads the new name back, AND the
    /// arrangement map shows it on the region at that position — the panel
    /// alone would only prove that a text field accepted text.
    func renameRegion(
        trackName: String, regionName: String?, startBar: Int?,
        newName: String, expectedCurrentName: String?
    ) throws -> [String: Any] {
        let wanted = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw LogicianError.invalidArguments("new_name must be non-empty")
        }
        guard !newName.contains(where: \.isNewline) else {
            throw LogicianError.invalidArguments("new_name must be a single line")
        }

        let before = try regionSnapshot(trackName: trackName)
        let addressed = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before renaming",
                actual: "the selection drifted; refusing", restored: true
            )
        }

        let panel = try regionInspectorPanel()
        switch panel.subject {
        case .defaults(let kind):
            throw LogicianError.preconditionUnmet(
                "the Region inspector is showing the track's \(kind) region DEFAULTS rather than a "
                    + "region — nothing was renamed. The selection did not take."
            )
        case .multiple(let count):
            throw LogicianError.preconditionUnmet(
                "\(count) regions are selected, and the Region inspector's name field then reads "
                    + "'\(count) selected' rather than a region name — nothing was renamed."
            )
        case .region:
            break
        }
        guard let field = panel.nameField else {
            throw LogicianError.valueNotWritable(
                "the Region inspector published its title as static text, not as a name field"
            )
        }
        let currentName = PrintedRegion.canonicalName(panel.panelName)
        if let expectedCurrentName,
           currentName.compare(expectedCurrentName, options: .caseInsensitive) != .orderedSame {
            throw LogicianError.currentValueMismatch(
                expected: "the region is named '\(expectedCurrentName)'",
                actual: "the Region inspector shows '\(currentName)'"
            )
        }
        if currentName == wanted {
            return [
                "success": true, "verified": true, "state": "already_set",
                "from": currentName, "to": wanted,
                "region": Self.addressedRegion(addressed),
                "note": "the region already carries that name; nothing was written"
            ]
        }
        guard isSettable(field, kAXValueAttribute as String) else {
            throw LogicianError.valueNotWritable(
                "the Region inspector's name field is not settable right now"
            )
        }
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, wanted as CFString
        )
        guard status == .success else {
            throw LogicianError.writeFailed(
                "the name write returned AXError \(status.rawValue)"
            )
        }
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)

        let panelAfter = try regionInspectorPanel()
        let panelName = PrintedRegion.canonicalName(panelAfter.panelName)
        let after = try regionSnapshot(trackName: trackName)
        let position = addressed["start_bar"] as? Int
        let beat = addressed["start_beat"] as? Int
        let renamed = after.first {
            ($0["start_bar"] as? Int) == position && ($0["start_beat"] as? Int) == beat
        }
        let mapName = (renamed?["name"] as? String).map(PrintedRegion.canonicalName)
        guard mapName?.compare(wanted, options: .caseInsensitive) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "the region at bar \(position.map(String.init) ?? "?") renamed to '\(wanted)'",
                actual: "the arrangement map shows '\(mapName ?? "no region there")'"
                    + " (the inspector reads '\(panelName)')",
                restored: false
            )
        }

        // Logic RENUMBERS default marker names by position when a marker is
        // added; regions are the neighbouring question, so the other regions
        // on the track are compared before and after and any that moved are
        // reported rather than assumed absent.
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "renamed",
            "from": currentName, "to": wanted,
            "panel_name": panelName,
            "region": Self.addressedRegion(addressed),
            "write_route": "ax_value_on_the_inspector_name_field"
        ]
        let sideEffects = Self.otherRegionsThatChangedName(
            before: before, after: after, atStartBar: position, startBeat: beat
        )
        if !sideEffects.isEmpty {
            result["also_renamed"] = sideEffects
            result["also_renamed_note"] = "Logic renamed OTHER regions on this track as a side "
                + "effect of this rename — the same positional renumbering markers do. Nothing "
                + "else was written by this server."
        }
        result["note"] = "The region's name in the arrangement, not the audio file's name and not "
            + "the track's: renaming a region never touches the file on disk. Undo restores the "
            + "old name."
        return result
    }

    private static func addressedRegion(_ addressed: [String: Any]) -> [String: Any] {
        [
            "track_name": addressed["track_name"] ?? "",
            "start_bar": addressed["start_bar"] ?? NSNull(),
            "end_bar": addressed["end_bar"] ?? NSNull(),
            "type": addressed["type"] ?? NSNull()
        ]
    }

    /// Regions on the same track, other than the renamed one, whose name is
    /// not what it was before the write.
    static func otherRegionsThatChangedName(
        before: [[String: Any]], after: [[String: Any]], atStartBar: Int?, startBeat: Int?
    ) -> [[String: Any]] {
        var moved: [[String: Any]] = []
        for old in before {
            let bar = old["start_bar"] as? Int
            let beat = old["start_beat"] as? Int
            if bar == atStartBar, beat == startBeat { continue }
            guard let fresh = after.first(where: {
                ($0["start_bar"] as? Int) == bar && ($0["start_beat"] as? Int) == beat
            }) else { continue }
            let was = PrintedRegion.canonicalName(old["name"] as? String ?? "")
            let now = PrintedRegion.canonicalName(fresh["name"] as? String ?? "")
            if was != now {
                moved.append(["start_bar": bar ?? NSNull(), "from": was, "to": now])
            }
        }
        return moved
    }

    private func verify(
        _ write: PlannedWrite, row: RegionInspectorRow, parameter: RegionInspector.Parameter
    ) throws {
        switch parameter.control {
        case .checkbox:
            guard RegionInspector.checkboxState(row.raw) == write.checkboxValue else {
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = \(write.checkboxValue.map(String.init) ?? "?")",
                    actual: "the checkbox reads '\(row.raw)'", restored: false
                )
            }
        case .popup:
            guard let target = write.popupValue,
                  RegionInspector.popupValuesMatch(row.raw, target) else {
                // Logic ACCEPTS the menu press and then springs the control
                // back where the value does not apply: a crossfade type on a
                // region with no neighbour to cross into reverted to 'Out'
                // every time, and took as 'X' the moment an adjacent region
                // existed (measured 2026-08-28).
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = '\(write.popupValue ?? "")'",
                    actual: "the pop-up reads '\(row.raw)'"
                        + (parameter.key == "fade_type"
                            ? " — Logic keeps a crossfade type only where there is an adjacent "
                                + "region to cross into; with none it springs back to 'Out'"
                            : ""),
                    restored: false
                )
            }
        default:
            guard Int(row.raw) == write.sliderValue else {
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = \(write.sliderValue.map(String.init) ?? "?")",
                    actual: "the control reads '\(row.raw)'", restored: false
                )
            }
        }
    }

}
