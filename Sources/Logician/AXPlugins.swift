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
        // Look FIRST, then every 25 ms: the press that opened this menu is
        // not answered until the menu is DOWN again, so by the time control
        // reaches here the menu is up (measured 8/8 at ~30 ms on the setting
        // pop-up, 2026-09-02). The 2 s budget is unchanged.
        var menu: AXUIElement?
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            if let found = pluginChooserMenu() { menu = found; break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: Self.trackingMenuPressInterval)
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
            // The chooser is a TRACKING menu: this press cannot be answered
            // while it is up and would otherwise sit out the whole messaging
            // timeout (measured 1.5 s on the identically shaped setting
            // pop-up, 2026-09-02) before reporting failure on a press that
            // worked. `chooseFromPluginMenu` finds the menu, which is the only
            // judge here and always was.
            pressOpeningTrackingMenu(appendSlot)
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
        let newWindow = try pollNewWindow(before: windowsBefore)
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
        // A tracking menu, like the append slot's — see `addPlugin`.
        pressOpeningTrackingMenu(listButton)
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
                // `swapped_in` counts: Logic reuses one plugin window per
                // channel, so an insert opened INTO the window a previous
                // insert left up is just as much this survey's doing, and
                // leaving it up would hand the next insert the same window
                // again. Only `already_open` — the user's own window,
                // untouched — is not ours to close.
                let openedByUs = ["opened", "swapped_in"].contains(openResult["state"] as? String ?? "")
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

        // ASK BEFORE PRESSING. The window list is read anyway, and the
        // channel's own plugin window — if one is up — says in its header
        // which plugin it is showing. That answers "is this plugin already
        // open?" for free.
        //
        // MEASURED 2026-09-02: the old code answered it by PRESSING the
        // toggle, which closed the user's window in 8.7 ms, then waited out a
        // 2.2 s poll for an appearance that was ruled out at 13 ms, pressed
        // again and polled again — `already_open` in 2 570 ms with the window
        // off the screen for 2.4 s of it.
        let windowsBefore = try logicWindows()
        let before = Set(windowsBefore.map(WindowKey.init))
        let channelWindows = pluginWindowsShowing(trackName: trackName, in: windowsBefore)
        if let open = windowAlreadyShowing(channelWindows, plugin: slot.name) {
            return openResult(
                state: "already_open",
                track: trackName,
                slot: slot,
                shows: channelWindows.first { $0.key == open }?.shows ?? slot.name,
                replacing: nil,
                verifiedBy: "window_header_before_press"
            )
        }

        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw LogicianError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        // What the channel's window was showing a moment ago, for the answer
        // to be able to say what this open REPLACED.
        let wasShowing = channelWindows.compactMap { $0.shows.isEmpty ? nil : $0.shows }.first

        let verdict = try pollWindowList { windows -> PluginOpenVerdict<WindowKey>? in
            pluginOpenVerdict(
                plugin: slot.name,
                before: channelWindows,
                allBefore: before,
                now: pluginWindowsShowing(trackName: trackName, in: windows),
                allNow: windows.map(WindowKey.init)
            )
        }

        switch verdict {
        case .showing(let window):
            let reused = channelWindows.contains { $0.key == window }
            let shown = pluginWindowsShowing(trackName: trackName, in: [window.element]).first?.shows
            return openResult(
                state: reused ? "swapped_in" : "opened",
                track: trackName,
                slot: slot,
                shows: shown ?? slot.name,
                replacing: reused ? wasShowing : nil,
                verifiedBy: "window_header"
            )
        case .changed:
            // The window would not name itself (its header is hidden), but it
            // is publishing a different shape than it did before the press,
            // and only the swap can have done that.
            return openResult(
                state: "swapped_in",
                track: trackName,
                slot: slot,
                shows: "",
                replacing: wasShowing,
                verifiedBy: "window_shape_changed"
            )
        case .appeared(let window):
            let title = stringAttribute(window.element, kAXTitleAttribute as String)
            guard title == trackName else {
                _ = closeWindowElement(window.element)
                throw LogicianError.openVerificationFailed(
                    "A window titled '\(title)' appeared, expected '\(trackName)'. It was closed again."
                )
            }
            let shown = pluginWindowsShowing(trackName: trackName, in: [window.element]).first?.shows
            return openResult(
                state: "opened",
                track: trackName,
                slot: slot,
                shows: shown ?? "",
                replacing: nil,
                verifiedBy: "window_appeared"
            )
        case .closed:
            // The plugin WAS open and nothing readable said so, so the toggle
            // press shut the user's window. Press again to put it back.
            let beforeRestore = Set(try logicWindows().map(WindowKey.init))
            let restoreStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
            guard restoreStatus == .success,
                  try pollNewWindow(before: beforeRestore) != nil else {
                throw LogicianError.openVerificationFailed(
                    "The open button toggled an already-open window closed and it could not be reopened."
                )
            }
            return openResult(
                state: "already_open",
                track: trackName,
                slot: slot,
                shows: "",
                replacing: nil,
                verifiedBy: "window_closed_and_reopened"
            )
        case nil:
            // The press reported success and nothing observable moved. Say
            // exactly that rather than calling a press that may well have
            // worked a failure — which is what this tool did until
            // 2026-09-02, on every in-place content swap.
            return [
                "success": false,
                "verified": false,
                "state": "unverified",
                "track": trackName,
                "insert_index": slot.index,
                "plugin_display_name": slot.name,
                "reason": "The insert's open button was pressed and Logic accepted the press, but 2 s"
                    + " later no window had opened or closed and the channel's plugin window"
                    + " publishes neither a plugin name nor a changed shape. The press may well"
                    + " have worked; this tool will not claim it did.",
                "note": "logic_list_plugin_parameters {window_title: \"\(trackName)\"} reads what the"
                    + " window contains, and logic_list_windows says what is open."
            ]
        }
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

        // The window list is read BEFORE the press, and it answers the whole
        // question when the plugin is not open. A plugin window's title is
        // the track name — `openPlugin` above refuses any other title — so a
        // list with no window called `trackName` means this plugin's window
        // is already closed, and the insert's open button being a TOGGLE
        // means pressing it would open the plugin rather than close it.
        // MEASURED 2026-09-01: that is exactly what the old code did, at
        // 2.63–2.79 s per call, with the plugin window visible on screen for
        // ~2.3 s of it, before refusing. The snapshot costs 1 ms and the tool
        // was taking it anyway.
        let before = try logicWindows()
        let beforeKeys = Set(before.map(WindowKey.init))
        let targets = Set(
            before
                .filter { stringAttribute($0, kAXTitleAttribute as String) == trackName }
                .map(WindowKey.init)
        )
        guard !targets.isEmpty else {
            return [
                "success": true,
                "verified": true,
                "state": "already_closed",
                "track": trackName, "track_name": trackName,
                "insert_index": slot.index,
                "plugin_display_name": slot.name,
                "note": "No window titled '\(trackName)' is open, so the plugin window was already closed"
                    + " and nothing was pressed. Plugin windows take the TRACK's name as their title;"
                    + " logic_list_windows shows what is open."
            ]
        }

        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw LogicianError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        switch try pollWindowToggle(targets: targets, before: beforeKeys) {
        case .closed:
            return [
                "success": true,
                "verified": true,
                "state": "closed",
                "track": trackName, "track_name": trackName,
                "insert_index": slot.index,
                "plugin_display_name": slot.name
            ]
        case .opened(let appeared):
            // A window titled after the track was open, but it belonged to a
            // DIFFERENT plugin on the same track: this insert's own window
            // was closed and the toggle just opened it. Close it again.
            _ = closeWindowElement(appeared.element)
            throw LogicianError.pluginNotOpen(
                "the open button opened a new window, which was closed again to restore the UI"
            )
        case nil:
            throw LogicianError.openVerificationFailed(
                "No window disappeared or appeared after pressing the open button."
            )
        }
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
        // The rule is the SUBROLE and nothing else — the tool description, the
        // guide and the refusal message say so since 2026-09-01, having each
        // claimed a document test the code has never performed.
        let subrole = stringAttribute(window, kAXSubroleAttribute as String)
        guard subrole == "AXDialog" else {
            throw LogicianError.windowNotClosable(title, subrole: subrole)
        }

        // No second window list: the element resolved above IS the window the
        // press is aimed at, and that identity is what the verification asks
        // about.
        guard closeWindowElement(window) else {
            throw LogicianError.writeFailed("AXPress on the window close button failed")
        }
        guard try pollPressedWindowGone(window, title: title) else {
            return [
                "success": false,
                "verified": false,
                "state": "open",
                "window": title,
                "reason": "The close button was pressed, and 2 s later a window titled '\(title)'"
                    + " is still open. Nothing else was touched.",
                "note": "Try logic_close_plugin with track, plugin and insert index — it closes the"
                    + " window through the insert's own button instead of the window's close box."
            ]
        }
        return [
            "success": true,
            "verified": true,
            "state": "closed",
            "window": title
        ]
    }

    /// Closes any plugin/auxiliary window standing over the project, waiting
    /// for one to appear when it is expected — the fix for `logic_new_project`
    /// leaving Logic's own instrument window open and unmentioned.
    ///
    /// MEASURED 2026-09-03 (`project-lifecycle-live.md` "Open" note; two
    /// timed live runs of this fix): a `logic_new_project` whose
    /// `initial_track` is a software instrument makes Logic open that
    /// track's plug-in window (`Inst 1`, `kind: plugin_or_auxiliary`,
    /// `AXDialog`) and leave it standing; an `audio` create opens none. Left
    /// open, it is the window `key_focus: unverified` / `blocked_by` names
    /// in every region tool (the region-focus fix, 0bafa09) — a brand-new
    /// project starting life already degraded.
    ///
    /// **The window is not there yet when the track is.** A look taken the
    /// instant `firstTrackRow` finds the new row finds NO plugin window on
    /// 5/5 creates; Logic opens it asymchronously, **1.13–1.60 s and
    /// 1.25–1.83 s after `openProject` would otherwise already have
    /// returned** on two separately timed runs (0.1–0.15 s poll
    /// resolution; the true edge is inside those brackets). This is Logic's
    /// own delay — the loop spends every tick of it inside a look, touching
    /// nothing else — not a blind sleep to cut, so `openProject` passes
    /// `waitingUpTo` a real budget (`ProjectOpen.strayPluginWindowBudgetSeconds`,
    /// 2.5 s, comfortably past the slower run's 1.83 s) only when the track
    /// just created is one measured to raise the window at all; every other
    /// kind gets `waitingUpTo: 0` — one look, ~1 ms, the same
    /// `logicWindows()` read `listWindows()` already pays warm.
    ///
    /// Detection is `LogicWindowKind.classify`, the exact rule
    /// `logic_list_windows` publishes — the poll only decides WHEN to look,
    /// never invents what counts as a plugin window. Closing is
    /// `closePluginWindow(title:)` itself, unchanged — the mechanism
    /// `logic_close_plugin_window` exposes — so there is exactly one way
    /// this server closes a plugin window, not two. A window this reuses
    /// `windowNotClosable`/`windowAmbiguous` on (raced shut, or sharing a
    /// title with another dialog) is reported unclosed rather than thrown,
    /// because the project create it is cleaning up after already
    /// succeeded. The report SHAPE lives in
    /// `ProjectOpen.strayPluginWindowClosedEntry`, pure and unit-tested;
    /// this function's only job is to supply it real inputs.
    func closeStrayPluginWindows(waitingUpTo deadline: TimeInterval) -> [[String: Any]] {
        let strayTitles: [String] = (try? pollWindowList(deadline: deadline) { windows -> [String]? in
            let titles = windows.compactMap { window -> String? in
                let title = stringAttribute(window, kAXTitleAttribute as String)
                let subrole = stringAttribute(window, kAXSubroleAttribute as String)
                let hasDocument = documentPath(of: window) != nil
                let kind = LogicWindowKind.classify(subrole: subrole, title: title, hasDocument: hasDocument)
                return kind == LogicWindowKind.pluginOrAuxiliary ? title : nil
            }
            return titles.isEmpty ? nil : titles
        }) ?? []
        guard !strayTitles.isEmpty else { return [] }
        return strayTitles.map { title in
            do {
                let outcome = try closePluginWindow(title: title)
                return ProjectOpen.strayPluginWindowClosedEntry(
                    title: title, closed: outcome["state"] as? String == "closed"
                )
            } catch {
                return ProjectOpen.strayPluginWindowClosedEntry(
                    title: title, closed: false, detail: error.localizedDescription
                )
            }
        }
    }

}
