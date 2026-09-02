import AppKit
import ApplicationServices
import Foundation

// The Accessibility half of plugin preset browsing: finding the setting pop-up
// in a plugin window's header, reading its menu, and pressing one item.
// The pure half — what the menu MEANS — is `PluginPresets.swift`.

extension LogicAccessibility {

    /// The actions an element offers. Needed here because the setting pop-up is
    /// identified by its action set and nothing else (see below).
    func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    /// The plugin window header's SETTING pop-up.
    ///
    /// Identified by its action set, which is the only thing that separates it
    /// from the *parameter* pop-ups sitting right next to it in the same
    /// header:
    ///
    /// | control                                | actions                     |
    /// |----------------------------------------|-----------------------------|
    /// | setting pop-up (what we want)          | `AXPress`                   |
    /// | View / zoom menu button                | `AXShowMenu`, `AXPress`     |
    /// | parameter pop-up (EQ stereo mode, …)   | `AXShowMenu`, `AXPress`     |
    ///
    /// Measured on five plugins 2026-08-27. The setting pop-up is also the
    /// only one of them that publishes text-field attributes (`AXSelectedText`
    /// & co., 6 of 6) and no `AXHelp` — corroborating signals, not needed.
    ///
    /// This replaces "the rightmost pop-up that has a value", which was WRONG
    /// wherever a parameter pop-up sits to the right of the setting pop-up:
    /// on Channel EQ it returned the stereo mode (`Stereo`), on Limiter the
    /// algorithm (`Precision`), on Pitch Shifter the mode (`Vocals`). Those
    /// values never change when the preset steps, so the old step verification
    /// reported `stepped: false` on a step that worked.
    /// The PLUGIN window with this title, never the project window.
    ///
    /// Plugin windows are titled after the strip, not the plugin, so a track
    /// named like the open document would otherwise let `logicWindow(title:)`
    /// hand back the project window and have its header pop-ups read as a
    /// plugin's settings. The predecessor of this file filtered on the same
    /// subrole for the same reason.
    private func pluginWindowElement(title: String) -> AXUIElement? {
        guard let windows = try? logicWindows() else { return nil }
        return windows.first {
            stringAttribute($0, kAXTitleAttribute as String) == title
                && stringAttribute($0, kAXSubroleAttribute as String) != "AXStandardWindow"
        }
    }

    func presetPopUpButton(windowTitle: String) -> AXUIElement? {
        guard let window = pluginWindowElement(title: windowTitle) else { return nil }
        var found: AXUIElement?
        walk(from: window, maximumDepth: AXDepth.pluginWindowHeader) { element in
            guard found == nil else { return .stop }
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXPopUpButton",
                  actionNames(element) == [kAXPressAction as String] else { return .descend }
            found = element
            return .stop
        }
        return found
    }

    /// The name of the setting currently loaded, as the header shows it.
    /// `nil` when the window is not there or exposes no setting pop-up.
    func pluginPresetLabel(windowTitle: String) -> String? {
        guard let popup = presetPopUpButton(windowTitle: windowTitle) else { return nil }
        let value = stringAttribute(popup, kAXValueAttribute as String)
        return value.isEmpty ? nil : value
    }

    /// The setting label, read until it says what the caller is waiting for.
    ///
    /// MEASURED 2026-09-02 (`logic_plugin_preset` §4.2): the header already
    /// showed the requested setting **49–62 ms after the leaf press on 3 of 3
    /// loads**, identical to the read taken after the 0.8 s blind sleep this
    /// replaces. So look FIRST, retry every 25 ms, and keep the old 0.8 s as
    /// the deadline rather than as the price.
    ///
    /// The last label read comes back either way, deadline or not: what it
    /// means is the caller's verdict to draw, not this function's.
    func pollPresetLabel(windowTitle: String, until settled: (String?) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(0.8)
        while true {
            let label = pluginPresetLabel(windowTitle: windowTitle)
            if settled(label) || Date() >= deadline { return label }
            Thread.sleep(forTimeInterval: Self.trackingMenuPressInterval)
        }
    }

    /// One item of an open preset menu: what Accessibility said about it, and
    /// the element it was read from.
    ///
    /// Keeping the element is the whole point — it is what lets `select`
    /// press inside the same menu cycle it read, instead of dismissing the
    /// menu and opening the identical one again to find the leaf by title
    /// (measured 2026-09-02: the second cycle was 3 144 ms of a 6 234 ms
    /// `select`). `item.children` and `children` are built in one pass, so
    /// they are the same nodes in the same order.
    private struct PresetMenuNode {
        let item: PresetMenuItem
        let element: AXUIElement
        let children: [PresetMenuNode]
    }

    private func presetMenuNode(_ element: AXUIElement, descend: Bool) -> PresetMenuNode {
        var childNodes: [PresetMenuNode] = []
        if descend, let submenu = children(of: element).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
        }) {
            childNodes = children(of: submenu)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
                .map { presetMenuNode($0, descend: false) }
        }
        return PresetMenuNode(
            item: PresetMenuItem(
                title: stringAttribute(element, kAXTitleAttribute as String),
                markChar: stringAttribute(element, "AXMenuItemMarkChar"),
                enabled: stringAttribute(element, kAXEnabledAttribute as String) == "1",
                children: childNodes.map(\.item)
            ),
            element: element,
            children: childNodes
        )
    }

    /// The whole open menu, top level and one submenu level — every level
    /// Logic uses (2026-08-27: no plugin nested deeper).
    private func presetMenuNodes(_ menu: AXUIElement) -> [PresetMenuNode] {
        children(of: menu)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
            .map { presetMenuNode($0, descend: true) }
    }

    /// One AXUIElement per entry of `flattenPresetMenu`, in the same order.
    /// The alignment is by construction: both walks are
    /// `flattenPresetMenuPositions` over the same item tree.
    private func presetLeafElements(_ nodes: [PresetMenuNode]) -> [AXUIElement] {
        flattenPresetMenuPositions(nodes.map(\.item)).map { position in
            let node = nodes[position.item]
            guard let child = position.child else { return node.element }
            return node.children[child].element
        }
    }

    /// Opens the setting menu, reads it, and closes it again — for `list`.
    ///
    /// Logic must be frontmost: a menu cannot open in a background app, and
    /// activating Logic while a menu is already open dismisses it (2026-08-25).
    /// `AXPress` on the pop-up reports `AXError -25204` even though the menu
    /// opens, exactly like the insert slot's plugin chooser — so presence is
    /// verified by finding the menu, never by the status code, and the press
    /// no longer waits for the reply either (`pressOpeningTrackingMenu`).
    ///
    /// The menu is ALWAYS dismissed before returning, including on every
    /// throw: a menu left open swallows Logic's keyboard and the next tool
    /// call's key command with it.
    func readPresetMenu(windowTitle: String) throws -> [PresetMenuItem] {
        try withPresetMenu(windowTitle: windowTitle) { menu in
            presetMenuNodes(menu).map(\.item)
        }
    }

    /// Reads the setting menu, lets the caller resolve the request against
    /// it, and presses the entry it resolved to — all inside ONE menu cycle.
    ///
    /// `resolve` is the pure half (`matchPresetName`, 0.0 ms) and it runs
    /// with the menu still open, so the press reuses the very element the
    /// read produced. That is what removes the second menu cycle a `select`
    /// used to pay, and with it the two "vanished from the menu between the
    /// read and the press" guards the old two-cycle shape needed: there is no
    /// longer a gap for anything to vanish across.
    ///
    /// `resolve` answering `press: false` is the `already_loaded_by_name`
    /// fast path — the menu is read and dismissed, nothing is pressed.
    func selectPreset(
        windowTitle: String,
        resolve: ([PresetEntry]) throws -> (entry: PresetEntry, press: Bool)
    ) throws -> PresetSelection {
        try withPresetMenu(windowTitle: windowTitle) { menu in
            let nodes = presetMenuNodes(menu)
            let items = nodes.map(\.item)
            let entries = flattenPresetMenu(items)
            let decision = try resolve(entries)
            guard decision.press else {
                return PresetSelection(
                    entries: entries, entry: decision.entry, pressed: false, label: nil
                )
            }
            // `matchPresetName` only ever resolves to an entry that is unique
            // by name and category (two identical ones come back `ambiguous`),
            // so this index is the entry's own row and no other.
            guard let index = entries.firstIndex(of: decision.entry) else {
                throw LogicianError.writeFailed(
                    "the setting '\(decision.entry.qualifiedName)' is not in the menu that was"
                        + " just read; nothing was pressed"
                )
            }
            let leaf = presetLeafElements(nodes)[index]
            let status = AXUIElementPerformAction(leaf, kAXPressAction as CFString)
            guard status == .success else {
                throw LogicianError.writeFailed(
                    "AXPress on the setting '\(decision.entry.name)' returned AXError"
                        + " \(status.rawValue); nothing was loaded"
                )
            }
            return PresetSelection(
                entries: entries, entry: decision.entry, pressed: true,
                label: pollPresetLabel(windowTitle: windowTitle) {
                    presetLabelNames($0, decision.entry)
                }
            )
        }
    }

    /// Raises a plugin window and makes it the application's focused window,
    /// so a press on a control inside it is delivered. Best effort by design:
    /// every failure here is silent because the press that follows is verified
    /// by whether the menu appeared, and a window that cannot be raised is not
    /// on its own a reason to refuse.
    func focusPluginWindow(titled title: String) {
        guard let window = try? logicWindow(title: title) else { return }
        _ = AXUIElementPerformAction(window, "AXRaise" as CFString)
        if let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first {
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(application.processIdentifier),
                kAXFocusedWindowAttribute as CFString, window
            )
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        // DELIBERATELY still blind. Measured 2026-09-02 at 158 ms of a menu
        // cycle, but unsized: what it waits for is Logic having ACTED on the
        // focus set, and nothing here has been proved to read that back
        // (`kAXFocusedWindowAttribute` immediately after the set has not been
        // probed). The press that follows is the thing this guards, and a
        // press into an unfocused window arrives nowhere at all — so this one
        // stays until a probe sizes it.
        Thread.sleep(forTimeInterval: 0.15)
    }

    /// Opens the setting menu, hands it to `body`, and dismisses it.
    private func withPresetMenu<Result>(
        windowTitle: String,
        _ body: (AXUIElement) throws -> Result
    ) throws -> Result {
        guard let popup = presetPopUpButton(windowTitle: windowTitle) else {
            throw LogicianError.trackNotExposed(
                requested: "the plugin setting menu of window '\(windowTitle)'",
                exposed: PresetMenuFailure.noPresetPopUp.reason
            )
        }
        try ensureLogicFrontmost(for: "the plugin setting menu")
        // Any menu left over from an earlier call would be found instead of
        // ours and read as this plugin's settings.
        dismissPopupMenus()
        // A press on a control in a window that does not hold the focus is
        // SWALLOWED, and `ensureLogicFrontmost` cannot see that: it returns as
        // soon as the APPLICATION is frontmost, which says nothing about which
        // of Logic's windows is focused. Measured 2026-08-28: two consecutive
        // `list` calls on `Stereo Out`'s Channel EQ failed with "the menu did
        // not open" while the terminal held the front, and every call after a
        // first successful one — same plugin, same window — opened on the
        // FIRST poll. Waiting longer does not help; the press never arrived.
        //
        // So the plugin window is raised and focused first, and the press is
        // retried. `dismissPopupMenus` between attempts keeps a press that DID
        // work but was polled too early from being toggled shut by the retry.
        //
        // The look comes FIRST and the retry is 25 ms: measured 2026-09-02,
        // the menu was already open on 8 of 8 cycles the instant the press
        // returned (~30 ms in, while the press itself was still waiting out
        // its timeout), and the loop answered on its first look every time.
        // The shape this replaces slept 0.15 s in front of that first look.
        // The total budgets are unchanged — 1.2 s per attempt, 3.0 s on the
        // last — because what they cover is the press that did NOT arrive,
        // which is the failure this ladder exists for.
        var opened: AXUIElement?
        pressing: for attempt in 0..<3 {
            if attempt > 0 { try? ensureLogicFrontmost(for: "the plugin setting menu") }
            focusPluginWindow(titled: windowTitle)
            pressOpeningTrackingMenu(popup)
            let deadline = Date().addingTimeInterval(attempt == 2 ? 3.0 : 1.2)
            while true {
                if let menu = popupMenus().first { opened = menu; break pressing }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: Self.trackingMenuPressInterval)
            }
            dismissPopupMenus()
        }
        guard let menu = opened else {
            dismissPopupMenus()
            throw LogicianError.openVerificationFailed(PresetMenuFailure.menuDidNotOpen.reason)
        }
        defer {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            dismissPopupMenus()
            // DELIBERATELY still blind, and the last blind sleep on this
            // path. The cancel + dismiss themselves take 34–58 ms (measured
            // 2026-09-02), so this is not waiting for them: it is the gap
            // that keeps the NEXT press from landing in a menu Logic has not
            // finished tearing down, which is a claim nothing here reads
            // back. Sizing it needs a probe that presses immediately after
            // the cancel and counts the misses; until then it stays.
            Thread.sleep(forTimeInterval: 0.3)
        }
        return try body(menu)
    }

    /// Presses one item of the menu's fixed COMMAND block by title — `Undo`
    /// and nothing else today.
    ///
    /// `AXPress` on an item of this menu works even though the same call is a
    /// silent no-op in the insert slot's plugin chooser (2026-08-25) — the
    /// difference is that this menu materializes its submenus' children
    /// immediately, so an item is a real element without being hovered open.
    /// Verified live 2026-08-27: `AXPress` on `03 Guitars > Rock Bass`
    /// returned `.success` and the header label followed.
    ///
    /// The label is read back until it MOVES, which is a pace rather than a
    /// verdict: an undo between two unnamed states leaves the label alone, so
    /// the deadline expiring is not a failure and the caller (see
    /// `presetUndoNote`) says as much. Returns the last label read.
    func pressPresetCommand(
        windowTitle: String, titled title: String, movedFrom labelBefore: String?
    ) throws -> String? {
        try withPresetMenu(windowTitle: windowTitle) { menu in
            guard let item = children(of: menu).first(where: {
                stringAttribute($0, kAXTitleAttribute as String)
                    .compare(title, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }) else {
                throw LogicianError.openVerificationFailed(
                    "the plugin's setting menu has no item titled '\(title)'; nothing was pressed"
                )
            }
            let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard status == .success else {
                throw LogicianError.writeFailed(
                    "AXPress on the setting menu's '\(title)' returned AXError"
                        + " \(status.rawValue); nothing was changed"
                )
            }
            return pollPresetLabel(windowTitle: windowTitle) { $0 != labelBefore }
        }
    }
}
