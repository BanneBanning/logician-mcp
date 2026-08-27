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

    /// One item of an open preset menu, converted to the pure boundary type.
    /// Only the top level and one submenu level are read, which is every level
    /// Logic uses (2026-08-27: no plugin nested deeper).
    private func presetMenuItem(_ element: AXUIElement, descend: Bool) -> PresetMenuItem {
        let submenuItems: [PresetMenuItem]
        if descend, let submenu = children(of: element).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
        }) {
            submenuItems = children(of: submenu)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
                .map { presetMenuItem($0, descend: false) }
        } else {
            submenuItems = []
        }
        return PresetMenuItem(
            title: stringAttribute(element, kAXTitleAttribute as String),
            markChar: stringAttribute(element, "AXMenuItemMarkChar"),
            enabled: stringAttribute(element, kAXEnabledAttribute as String) == "1",
            children: submenuItems
        )
    }

    /// Opens the setting menu, reads it, and closes it again — for `list`, and
    /// as the lookup step of `select`.
    ///
    /// Logic must be frontmost: a menu cannot open in a background app, and
    /// activating Logic while a menu is already open dismisses it (2026-08-25).
    /// `AXPress` on the pop-up reports `AXError -25204` even though the menu
    /// opens, exactly like the insert slot's plugin chooser — so presence is
    /// verified by finding the menu, never by the status code.
    ///
    /// The menu is ALWAYS dismissed before returning, including on every
    /// throw: a menu left open swallows Logic's keyboard and the next tool
    /// call's key command with it.
    func readPresetMenu(windowTitle: String) throws -> [PresetMenuItem] {
        let items = try withPresetMenu(windowTitle: windowTitle) { menu in
            children(of: menu)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
                .map { presetMenuItem($0, descend: true) }
        }
        return items
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
        _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
        var opened: AXUIElement?
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.15)
            if let menu = popupMenus().first { opened = menu; break }
        }
        guard let menu = opened else {
            dismissPopupMenus()
            throw LogicianError.openVerificationFailed(PresetMenuFailure.menuDidNotOpen.reason)
        }
        defer {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            dismissPopupMenus()
            Thread.sleep(forTimeInterval: 0.3)
        }
        return try body(menu)
    }

    /// Presses one setting in the menu, by category and name.
    ///
    /// `AXPress` on a leaf works here even though the same call is a silent
    /// no-op in the insert slot's plugin chooser (2026-08-25) — the difference
    /// is that this menu materializes its submenus' children immediately, so
    /// the leaf is a real element without being hovered open. Verified live
    /// 2026-08-27: `AXPress` on `03 Guitars > Rock Bass` returned `.success`
    /// and the header label followed.
    ///
    /// Does NOT verify the outcome; the caller reads the label back, because
    /// the label read is what an agent gets to see as proof.
    func pressPresetMenuItem(windowTitle: String, category: String?, name: String) throws {
        try withPresetMenu(windowTitle: windowTitle) { menu in
            func matches(_ element: AXUIElement, _ title: String) -> Bool {
                stringAttribute(element, kAXTitleAttribute as String)
                    .compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            var container = menu
            if let category {
                guard let categoryItem = children(of: menu).first(where: { matches($0, category) }),
                      let submenu = children(of: categoryItem).first(where: {
                          stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
                      }) else {
                    throw LogicianError.openVerificationFailed(
                        "the setting category '\(category)' vanished from the menu between the read and the press"
                    )
                }
                container = submenu
            }
            guard let leaf = children(of: container).first(where: { matches($0, name) }) else {
                throw LogicianError.openVerificationFailed(
                    "the setting '\(name)' vanished from the menu between the read and the press"
                )
            }
            let status = AXUIElementPerformAction(leaf, kAXPressAction as CFString)
            guard status == .success else {
                throw LogicianError.writeFailed(
                    "AXPress on the setting '\(name)' returned AXError \(status.rawValue); nothing was loaded"
                )
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
}
