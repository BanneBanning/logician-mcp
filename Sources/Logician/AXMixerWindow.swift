import AppKit
import ApplicationServices
import Foundation

// MARK: - Opening and closing Logic's Mixer

extension LogicAccessibility {

    /// Opens or closes Logic's Mixer WINDOW via `Window > Open Mixer`, and
    /// verifies against the window list.
    ///
    /// WHAT THE LIVE RUN SAID (2026-08-28, COVERAGE G57). The tool was built on
    /// the hope that an open Mixer would put `Master` and the auxes within
    /// reach of the Accessibility-plane strip tools. The experiment ran, and
    /// the answer is **no — and it costs something**:
    ///
    /// - The Mixer's channel strips ARE in the Accessibility tree, `Master`,
    ///   `Stereo Out` and `Aux 1`–`Aux 3` included. They are reported here as
    ///   `mixer_strips`, read off each strip's own `name` text field, because
    ///   their `AXDescription` is a numeric triple (`"84 76 8"` = `Master`) and
    ///   not the strip name.
    /// - But they are NOT inspector strips: they carry no
    ///   "inspector channel strip" help, they live in a DIFFERENT window, and
    ///   their insert slots publish placeholder descriptions (`audio plug-in`)
    ///   where the inspector publishes plugin names. `logic_list_inserts`,
    ///   `logic_open_plugin`, `logic_plugin_preset` and `logic_set_insert_bypass`
    ///   address the inspector and do not read them. `Master` and the auxes
    ///   stay on the `logic_mcu_*` plane, which never needed a window.
    /// - And an open Mixer SHADOWS the project window: it is a standard window
    ///   carrying the same document, so it can be the window Accessibility
    ///   hands back for "the project window" (it is skipped explicitly now, in
    ///   `projectWindow()`), and while Logic is in the background it can be the
    ///   only document window published at all.
    ///
    /// So the tool is honest window management with a warning, not a lever that
    /// lifts the limitation. What it is genuinely good for: putting the Mixer
    /// in front of a human, and reading the complete strip census out of the
    /// window when the surface plane is unavailable.
    func setMixerOpen(_ open: Bool) throws -> [String: Any] {
        // Window management needs Logic in front, in BOTH directions. A
        // background Logic publishes only its main/focused window, so closing
        // the Mixer while it was the main one left Logic publishing NO windows
        // at all (measured 2026-08-28: `AXWindows` empty, `AXMainWindow` nil,
        // and every Accessibility tool failing) until the app was activated.
        try ensureLogicFrontmost(for: open ? "opening the Mixer" : "closing the Mixer")
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
            addStripCensus(to: &payload, mixerOpen: open)
            return payload
        }
        if open {
            // `settled:` matters here: a menu AXPress that answers `.success`
            // and does nothing is a measured Logic 12.3.1 behaviour, and the
            // item's own advertised shortcut is the fallback.
            try pressMenuItem(
                containing: "Open Mixer", underMenu: "Window",
                settled: { [weak self] in self?.mixerWindow() != nil }
            )
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
        addStripCensus(to: &payload, mixerOpen: nowOpen)
        guard nowOpen == open else {
            throw LogicianError.verificationFailed(
                requested: "the Mixer \(open ? "open" : "closed")",
                actual: "the window list still says \(nowOpen ? "open" : "closed")",
                restored: true
            )
        }
        return payload
    }

    /// The two strip censuses, plus the note and the warning that make them
    /// readable: which strips the AX strip tools can actually address, and
    /// which ones are merely visible in the Mixer.
    private func addStripCensus(to payload: inout [String: Any], mixerOpen: Bool) {
        payload["inspector_strips"] = visibleInspectorStripNames()
        payload["note"] = "inspector_strips is what the Accessibility strip tools"
            + " (logic_list_inserts, logic_survey_plugins, logic_open_plugin,"
            + " logic_plugin_preset, logic_set_insert_bypass) can address: the selected track's"
            + " strip and its output. mixer_strips is what the Mixer WINDOW shows — measured"
            + " 2026-08-28, those strips are not inspector strips and those tools do not read"
            + " them. Master, the auxes and the buses are reachable through the logic_mcu_* tools,"
            + " which need no window at all."
        if mixerOpen {
            payload["mixer_strips"] = mixerStripNames()
            payload["warning"] = "an open Mixer is a second document window and can SHADOW the"
                + " project window: while Logic is in the background it may be the only window"
                + " Accessibility publishes, and then every track-header read fails. Close it"
                + " when you are done."
        }
    }

    /// Logic's Mixer window, when one is open.
    ///
    /// Told apart by its TITLE, and by nothing else: measured 2026-08-28 the
    /// Mixer window is `"<project> - Mixer: Tracks"`, an `AXStandardWindow`
    /// that carries the SAME `AXDocument` as the project window. The old rule
    /// here ("a window with no document whose title mentions the mixer") could
    /// therefore never match it — the tool reported `verification failed` after
    /// successfully opening the Mixer, and `already_closed` while one stood
    /// open, which also meant it could not close it again.
    func mixerWindow() -> AXUIElement? {
        (try? logicWindows())?.first { isMixerWindow($0) }
    }

    /// Whether a window is a Mixer window. The view name follows the last
    /// `" - "` in Logic's window titles (`"… - Tracks"`, `"… - Mixer: Tracks"`),
    /// so the test is on that segment and a project called "Mixer Notes" does
    /// not fool it.
    func isMixerWindow(_ window: AXUIElement) -> Bool {
        let title = stringAttribute(window, kAXTitleAttribute as String)
        guard let view = title.components(separatedBy: " - ").last else { return false }
        return view.hasPrefix("Mixer")
    }

    /// Every channel strip an INSPECTOR is showing, by name — the strips the
    /// Accessibility-plane strip tools can actually address.
    func visibleInspectorStripNames() -> [String] {
        var names: [String] = []
        for window in (try? logicWindows()) ?? [] {
            walk(from: window, maximumDepth: AXDepth.inspectorStrip) { element in
                guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem",
                      stringAttribute(element, kAXHelpAttribute as String)
                        .localizedCaseInsensitiveContains("inspector channel strip") else { return .descend }
                let name = stringAttribute(element, kAXDescriptionAttribute as String)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
                return .skipChildren
            }
        }
        return names
    }

    /// Every channel strip the Mixer window shows, by name.
    ///
    /// The name comes from the strip's own `name` text field, not from
    /// `AXDescription`: the strips whose track header is not rendered publish a
    /// numeric triple there instead (`"84 76 8"` is `Master`, `"124 68 8"` is
    /// `Aux 1`), so a description-based census would report the master chain as
    /// three numbers.
    func mixerStripNames() -> [String] {
        guard let mixer = mixerWindow() else { return [] }
        var names: [String] = []
        walk(from: mixer, maximumDepth: AXDepth.inspectorStrip + 2) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem",
                  !stringAttribute(element, kAXDescriptionAttribute as String).isEmpty,
                  let field = children(of: element).first(where: {
                      stringAttribute($0, kAXDescriptionAttribute as String) == "name"
                  }) else { return .descend }
            let name = stringAttribute(field, kAXValueAttribute as String)
            if !name.isEmpty { names.append(name) }
            return .skipChildren
        }
        return names
    }
}
