import AppKit
import ApplicationServices
import Foundation

// MARK: - Opening and closing Logic's Mixer

extension LogicAccessibility {

    /// Opens or closes Logic's Mixer WINDOW via `Window > Open Mixer`, and
    /// verifies against the window list.
    ///
    /// Why a window-control tool earns its place (COVERAGE G57): the
    /// Accessibility-plane strip tools can only reach a channel strip an
    /// inspector is SHOWING, which is why `logic_list_inserts` and
    /// `logic_survey_plugins` reach `Stereo Out` (the selected track's output)
    /// and not `Master` or `Aux 1`. That has been documented as a limitation
    /// with a workaround an agent could not perform. Now it can.
    ///
    /// WHAT IS VERIFIED, AND WHAT IS NOT. This reports the Mixer window's
    /// presence, and — because the claim above is the reason the tool exists —
    /// the strip names Accessibility can see afterwards, so the caller can check
    /// the limitation actually lifted rather than take this doc comment's word
    /// for it.
    func setMixerOpen(_ open: Bool) throws -> [String: Any] {
        let before = mixerWindow()
        var payload: [String: Any] = [
            "requested": open ? "open" : "closed",
            "write_route": open ? "menu_window_open_mixer" : "window_close_button"
        ]
        if (before != nil) == open {
            payload["success"] = true
            payload["verified"] = true
            payload["state"] = open ? "already_open" : "already_closed"
            payload["mixer_open"] = open
            payload["inspector_strips"] = visibleInspectorStripNames()
            return payload
        }
        if open {
            try pressMenuItem(containing: "Open Mixer", underMenu: "Window")
        } else if let window = before {
            guard closeWindowElement(window) else {
                throw LogicianError.writeFailed("the Mixer window has no reachable close button")
            }
        }
        var nowOpen = before != nil
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.12)
            nowOpen = mixerWindow() != nil
            if nowOpen == open { break }
        }
        payload["mixer_open"] = nowOpen
        payload["success"] = nowOpen == open
        payload["verified"] = nowOpen == open
        payload["state"] = nowOpen == open ? (open ? "open" : "closed") : "failed"
        payload["inspector_strips"] = visibleInspectorStripNames()
        guard nowOpen == open else {
            throw LogicianError.verificationFailed(
                requested: "the Mixer \(open ? "open" : "closed")",
                actual: "the window list still says \(nowOpen ? "open" : "closed")",
                restored: true
            )
        }
        return payload
    }

    /// Logic's Mixer window, when one is open. Told apart from the project
    /// window by its title and by carrying no document.
    func mixerWindow() -> AXUIElement? {
        (try? logicWindows())?.first { window in
            documentPath(of: window) == nil
                && stringAttribute(window, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveContains("mixer")
        }
    }

    /// Every channel strip Accessibility can currently see, by name — the
    /// evidence for (or against) "an open Mixer lifts the AX-only limitation".
    func visibleInspectorStripNames() -> [String] {
        var names: [String] = []
        for window in (try? logicWindows()) ?? [] {
            walk(from: window, maximumDepth: AXDepth.inspectorStrip) { element in
                guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem",
                      stringAttribute(element, kAXHelpAttribute as String)
                        .localizedCaseInsensitiveContains("channel strip") else { return .descend }
                let name = stringAttribute(element, kAXDescriptionAttribute as String)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
                return .skipChildren
            }
        }
        return names
    }
}
