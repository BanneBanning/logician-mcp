import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Plugin insertion and removal

    /// Popup menus that are not part of the menu bar (e.g. the insert slot's
    /// plugin chooser). Logic's press action reports an error even though the
    /// menu opens, so presence is verified by finding the menu itself.
    func popupMenus() -> [AXUIElement] {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menus: [AXUIElement] = []
        walk(from: appElement, maximumDepth: AXDepth.popupMenu) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXMenuBar" { return .skipChildren }
            if role == "AXMenu" { menus.append(element); return .skipChildren }
            return .descend
        }
        return menus
    }

    func pluginChooserMenu() -> AXUIElement? {
        popupMenus().first { menu in
            children(of: menu).contains {
                stringAttribute($0, kAXTitleAttribute as String) == LogicUIStrings.Value.audioUnits
            } || children(of: menu).contains {
                stringAttribute($0, kAXTitleAttribute as String) == LogicUIStrings.Value.noPlugIn
            }
        }
    }

    func dismissPopupMenus() {
        for menu in popupMenus() {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    /// First menu item with this title, searching `menu` and its submenus in
    /// pre-order. `menu` itself is an AXMenu, never an AXMenuItem, so the
    /// search including the root cannot match it.
    func findMenuItem(
        in menu: AXUIElement,
        titled title: String,
        maximumDepth: Int = AXDepth.popupMenuItem
    ) -> AXUIElement? {
        firstDescendant(of: menu, maximumDepth: maximumDepth) { item in
            stringAttribute(item, kAXRoleAttribute as String) == "AXMenuItem"
                && stringAttribute(item, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveCompare(title) == .orderedSame
        }
    }

    @discardableResult
    func chooseFromPluginMenu(pluginName: String, format: String) throws -> String {
        var menu: AXUIElement?
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if let found = pluginChooserMenu() { menu = found; break }
        }
        guard let chooser = menu else {
            throw LogicianError.openVerificationFailed("the plugin chooser menu did not open")
        }
        guard let item = findMenuItem(in: chooser, titled: pluginName) else {
            dismissPopupMenus()
            let topLevel = children(of: chooser)
                .map { stringAttribute($0, kAXTitleAttribute as String) }
                .filter { !$0.isEmpty }
            throw LogicianError.insertNotFound(track: "plugin menu", plugin: pluginName, available: topLevel)
        }
        // Plugins with channel-format submenus need a leaf item chosen; take
        // the requested format when offered, otherwise whatever the channel
        // supports (a mono track only offers "Mono").
        var target = item
        var chosenFormat = ""
        if let submenu = children(of: item).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
        }) {
            let options = children(of: submenu).filter {
                !stringAttribute($0, kAXTitleAttribute as String).isEmpty
            }
            if let requested = options.first(where: {
                stringAttribute($0, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveCompare(format) == .orderedSame
            }) {
                target = requested
            } else if let fallback = options.first {
                target = fallback
            }
            chosenFormat = stringAttribute(target, kAXTitleAttribute as String)
        }
        // AXPress on items inside closed submenus is a silent no-op in Logic's
        // custom chooser (verified 2026-08-25); drive the menu like a mouse
        // user instead: hover each ancestor open, then click the final item.
        do {
            try navigateMenu(chooser, along: titlePath(to: target, within: chooser))
        } catch {
            dismissPopupMenus()
            throw error
        }
        return chosenFormat
    }

    func titlePath(to item: AXUIElement, within chooser: AXUIElement) -> [String] {
        var titles: [String] = []
        var current: AXUIElement? = item
        for _ in 0..<12 {
            guard let element = current else { break }
            if CFEqual(element, chooser) { break }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" {
                titles.append(stringAttribute(element, kAXTitleAttribute as String))
            }
            // A parent that is not an element ends the walk with the titles
            // gathered so far, the same as reaching the top; `as!` trapped.
            current = elementAttribute(element, kAXParentAttribute as String)
        }
        return titles.reversed()
    }

    func navigateMenu(_ chooser: AXUIElement, along titles: [String]) throws {
        guard !titles.isEmpty else {
            throw LogicianError.openVerificationFailed("empty menu path")
        }
        // Logic must already be frontmost here: activating it now would
        // dismiss the open menu (verified 2026-08-25).
        let source = CGEventSource(stateID: .hidSystemState)
        let previousLocation = CGEvent(source: nil)?.location
        var menu = chooser
        for (index, title) in titles.enumerated() {
            guard let item = children(of: menu).first(where: {
                stringAttribute($0, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw LogicianError.openVerificationFailed("menu item '\(title)' vanished during navigation")
            }
            let itemFrame = try frame(of: item)
            let point = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.35)
            if index == titles.count - 1 {
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            } else {
                guard let submenu = children(of: item).first(where: {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
                }) else {
                    throw LogicianError.openVerificationFailed("submenu under '\(title)' did not open")
                }
                menu = submenu
            }
        }
        if let restore = previousLocation {
            Thread.sleep(forTimeInterval: 0.05)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: restore, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func addPlugin(
        trackName: String,
        trackNumber: Int?,
        pluginName: String,
        format: String
    ) throws -> [String: Any] {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        let before = insertSlots(of: strip)
        let bars = children(of: strip).filter {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.insertBar
        }
        // A pristine strip (no inserts yet) renders no "insert bar" elements;
        // its first empty slot is the "audio plug-in" button instead.
        let pristineSlot = children(of: strip).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.audioPlugIn
        }
        guard let appendSlot = bars.last ?? pristineSlot else {
            throw LogicianError.trackNotExposed(
                requested: "an empty insert slot on '\(trackName)'",
                exposed: "neither an insert bar nor the audio plug-in button was found in the strip"
            )
        }
        let windowsBefore = Set(try logicWindows().map(WindowKey.init))
        try ensureLogicFrontmost(for: "the plugin chooser") // activating later would close the menu
        if bars.isEmpty {
            // The pristine "audio plug-in" button is AXPress-dead (like the
            // track-header controls) — a hit-test-guarded click opens it.
            try clickElement(appendSlot, describedAs: "the empty audio plug-in slot")
        } else {
            _ = AXUIElementPerformAction(appendSlot, kAXPressAction as CFString) // opens the chooser
        }
        let chosenFormat = try chooseFromPluginMenu(pluginName: pluginName, format: format)

        // The new insert lands in the first empty slot, which is not
        // necessarily last (e.g. instrument-adjacent slots follow it), so
        // diff the slot lists positionally to find the addition.
        var added: InsertSlot?
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let refreshed = try? inspectorStrip(named: trackName) else { continue }
            let slots = insertSlots(of: refreshed)
            guard slots.count == before.count + 1 else { continue }
            for (position, slot) in slots.enumerated() {
                if position >= before.count || slot.name != before[position].name {
                    if pluginNamesMatch(slot.name, pluginName) {
                        added = slot
                    }
                    break
                }
            }
            if added != nil { break }
        }
        guard let slot = added else {
            dismissPopupMenus()
            throw LogicianError.openVerificationFailed(
                "no new insert matching '\(pluginName)' appeared on '\(trackName)'"
            )
        }
        let newWindow = try pollWindowDiff(before: windowsBefore, expectAppear: true)
        return [
            "success": true,
            "verified": true,
            "state": "plugin_added",
            "track": trackName, "track_name": trackName,
            "plugin_display_name": slot.name,
            "insert_index": slot.index,
            "format": chosenFormat.isEmpty ? format : chosenFormat,
            "plugin_window": newWindow != nil
                ? stringAttribute(newWindow!, kAXTitleAttribute as String) : "none_opened",
            "write_route": "insert_menu_navigation",
            "note": "Logic may open the plugin window automatically; close it with logic_close_plugin if unwanted."
        ]
    }

    func removePlugin(
        trackName: String,
        trackNumber: Int?,
        pluginName: String,
        insertIndex: Int?
    ) throws -> [String: Any] {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        let before = insertSlots(of: strip)
        let slot = try resolveSlot(before, track: trackName, plugin: pluginName, index: insertIndex)
        guard let listButton = children(of: slot.group).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.list
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "plugin menu button on slot \(slot.index)",
                exposed: "the insert group has no list button"
            )
        }
        try ensureLogicFrontmost(for: "the plugin chooser") // activating later would close the menu
        _ = AXUIElementPerformAction(listButton, kAXPressAction as CFString)
        try chooseFromPluginMenu(pluginName: "No Plug-in", format: "")

        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let refreshed = try? inspectorStrip(named: trackName) else { continue }
            if insertSlots(of: refreshed).count == before.count - 1 {
                return [
                    "success": true,
                    "verified": true,
                    "state": "plugin_removed",
                    "track": trackName, "track_name": trackName,
                    "removed_plugin": slot.name,
                    "was_insert_index": slot.index,
                    "write_route": "insert_menu_navigation"
                ]
            }
        }
        dismissPopupMenus()
        throw LogicianError.openVerificationFailed(
            "the insert count on '\(trackName)' did not decrease after choosing No Plug-in"
        )
    }

    func controlCensus(windowTitle: String) throws -> [String: Int] {
        let window = try logicWindow(title: windowTitle)
        var census: [String: Int] = [:]
        let interesting: Set<String> = [
            "AXSlider", "AXTextField", "AXCheckBox", "AXButton",
            "AXPopUpButton", "AXMenuButton", "AXValueIndicator",
            "AXLayoutArea", "AXLayoutItem", "AXIncrementor", "AXImage"
        ]
        for element in descendants(of: window) {
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if interesting.contains(role) {
                census[role, default: 0] += 1
            }
        }
        return census
    }

    // MARK: - Plugin survey

    func surveyPlugins(trackName: String, trackNumber: Int?) throws -> [String: Any] {
        // Output/aux strips (e.g. "Stereo Out") live in the right inspector
        // strip and are not track headers; fall back to any strip whose name
        // matches when track selection cannot resolve the name.
        do {
            _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        } catch let error as LogicianError {
            guard isHeaderlessStripCandidate(error, trackNumberGiven: trackNumber != nil),
                  (try? anyInspectorStrip(named: trackName)) != nil else {
                throw error
            }
        }
        let strip = try anyInspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        var surveyed: [[String: Any]] = []
        for slot in slots {
            var entry: [String: Any] = [
                "insert_index": slot.index,
                "plugin_display_name": slot.name,
                "bypassed": slot.bypassed
            ]
            do {
                let openResult = try openPlugin(
                    trackName: trackName,
                    pluginName: slot.name,
                    insertIndex: slot.index,
                    expectedProjectPath: nil
                )
                let openedByUs = (openResult["state"] as? String) == "opened"
                Thread.sleep(forTimeInterval: 0.3)
                let parameters = (try? listParameters(windowTitle: trackName)) ?? []
                entry["accessible_parameters"] = parameters.count
                entry["parameters"] = parameters.map { parameter -> [String: Any] in
                    [
                        "name": parameter["name"] ?? "",
                        "raw_value": parameter["raw_value"] ?? "",
                        "raw_min": parameter["raw_min"] ?? "",
                        "raw_max": parameter["raw_max"] ?? "",
                        "writable": parameter["writable"] ?? false
                    ]
                }
                entry["classification"] = parameters.isEmpty
                    ? "no_semantic_sliders"
                    : (parameters.allSatisfy { ($0["writable"] as? Bool) == true }
                        ? "read_write_candidate" : "partially_writable")
                if parameters.isEmpty {
                    // Distinguish "custom canvas with nothing" from "controls
                    // exposed with other roles than the Compressor-style sliders".
                    entry["control_census"] = (try? controlCensus(windowTitle: trackName)) ?? [:]
                }
                if openedByUs {
                    _ = try? closePlugin(
                        trackName: trackName, pluginName: slot.name, insertIndex: slot.index
                    )
                }
            } catch {
                entry["classification"] = "survey_failed"
                entry["error"] = error.localizedDescription
            }
            surveyed.append(entry)
        }
        return [
            "success": true,
            "track": trackName, "track_name": trackName,
            "surveyed_inserts": surveyed.count,
            "plugins": surveyed,
            "note": "classification reflects AX slider exposure only; verified write/readback per parameter still requires a live compare-and-set test"
        ]
    }

    // MARK: - Plugin window lifecycle

    func openPlugin(
        trackName: String,
        pluginName: String,
        insertIndex: Int?,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        if let expected = expectedProjectPath {
            let actual = try projectDocumentPath()
            guard normalizedPath(expected) == normalizedPath(actual) else {
                throw LogicianError.projectMismatch(expected: expected, actual: actual)
            }
        }

        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        let slot = try resolveSlot(slots, track: trackName, plugin: pluginName, index: insertIndex)
        guard let openButton = slot.openButton else {
            throw LogicianError.valueNotWritable("insert slot \(slot.index) (\(slot.name)) exposes no open button")
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw LogicianError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        if let appeared = try pollWindowDiff(before: before, expectAppear: true) {
            let title = stringAttribute(appeared, kAXTitleAttribute as String)
            guard title == trackName else {
                _ = closeWindowElement(appeared)
                throw LogicianError.openVerificationFailed(
                    "A window titled '\(title)' appeared, expected '\(trackName)'. It was closed again."
                )
            }
            return openResult(state: "opened", track: trackName, slot: slot, windowTitle: title)
        }

        if firstMissingWindow(from: before) != nil {
            // The plugin window was already open; the open button toggled it closed.
            // Press again to restore it and report the identified window.
            let beforeRestore = Set(try logicWindows().map(WindowKey.init))
            let restoreStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
            guard restoreStatus == .success,
                  let reopened = try pollWindowDiff(before: beforeRestore, expectAppear: true) else {
                throw LogicianError.openVerificationFailed(
                    "The open button toggled an already-open window closed and it could not be reopened."
                )
            }
            let title = stringAttribute(reopened, kAXTitleAttribute as String)
            return openResult(state: "already_open", track: trackName, slot: slot, windowTitle: title)
        }

        throw LogicianError.openVerificationFailed("No window appeared or disappeared after pressing the open button.")
    }

    func closePlugin(
        trackName: String,
        pluginName: String,
        insertIndex: Int?
    ) throws -> [String: Any] {
        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        let slot = try resolveSlot(slots, track: trackName, plugin: pluginName, index: insertIndex)
        guard let openButton = slot.openButton else {
            throw LogicianError.valueNotWritable("insert slot \(slot.index) (\(slot.name)) exposes no open button")
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw LogicianError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        if try pollWindowDisappeared(before: before) {
            return [
                "success": true,
                "verified": true,
                "state": "closed",
                "track": trackName, "track_name": trackName,
                "insert_index": slot.index,
                "plugin_display_name": slot.name
            ]
        }

        if let appeared = try pollWindowDiff(before: before, expectAppear: true) {
            // The plugin window was closed already; the toggle opened it. Close it again.
            _ = closeWindowElement(appeared)
            throw LogicianError.pluginNotOpen(
                "the open button opened a new window, which was closed again to restore the UI"
            )
        }
        throw LogicianError.openVerificationFailed("No window disappeared after pressing the open button.")
    }

    func closePluginWindow(title: String) throws -> [String: Any] {
        let windows = try logicWindows()
        let matches = windows.filter { stringAttribute($0, kAXTitleAttribute as String) == title }
        guard let window = matches.first else {
            throw LogicianError.windowNotFound(title)
        }
        guard matches.count == 1 else {
            throw LogicianError.windowAmbiguous(title, matches.count)
        }
        // Dialogs are plugin/auxiliary windows even when they carry the project
        // document (Drum Machine Designer does); never close standard windows.
        guard stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog" else {
            throw LogicianError.windowNotClosable(title)
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        guard closeWindowElement(window) else {
            throw LogicianError.writeFailed("AXPress on the window close button failed")
        }
        guard try pollWindowDisappeared(before: before) else {
            throw LogicianError.openVerificationFailed("The window '\(title)' did not disappear after pressing close.")
        }
        return [
            "success": true,
            "verified": true,
            "state": "closed",
            "window": title
        ]
    }

}
