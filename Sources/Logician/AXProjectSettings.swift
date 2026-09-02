import AppKit
import ApplicationServices
import Foundation

// MARK: - File > Project Settings, and the Smart Tempo pane

/// What a Project Settings read did to the UI, so a result can say it.
///
/// The distinction is not cosmetic: this read is called on the arming path of
/// a recording, and "we left a window open" is a fact the caller has to be
/// able to report. `openedAndClosed` is the ordinary case and leaves Logic
/// exactly as it was found.
enum ProjectSettingsVisit: Equatable {
    /// No Project Settings window existed; one was opened on the Smart Tempo
    /// pane, read, and closed again.
    case openedAndClosed
    /// A Project Settings window was ALREADY open and already showing the
    /// pane; nothing was opened, nothing was closed.
    case usedOpenWindow
    /// A Project Settings window was already open on a DIFFERENT pane; the
    /// Smart Tempo pane was selected to do the read and the window was left
    /// open, because the pane it was showing is not published anywhere and
    /// therefore cannot be put back.
    case switchedPaneOfOpenWindow
    /// The window could not be opened, or the pane published no mode.
    case failed(String)

    var name: String {
        switch self {
        case .openedAndClosed: return "opened_and_closed"
        case .usedOpenWindow: return "used_open_window"
        case .switchedPaneOfOpenWindow: return "switched_pane_of_open_window"
        case .failed: return "failed"
        }
    }

    /// The side effect a caller may have to mention, nil when there is none.
    var note: String? {
        switch self {
        case .openedAndClosed, .usedOpenWindow:
            return nil
        case .switchedPaneOfOpenWindow:
            return "a Project Settings window was already open on another pane; it was switched to"
                + " Smart Tempo to read the mode and LEFT OPEN, because Logic does not publish which"
                + " pane was showing and a guess would be a second change"
        case .failed(let reason):
            return reason
        }
    }
}

extension LogicAccessibility {

    /// Logic's Project Settings window, when one is open. Told apart by the
    /// title's view segment, exactly like `isMixerWindow` — Logic titles this
    /// window `"<project> - Project Settings"`.
    func projectSettingsWindow() -> AXUIElement? {
        (try? logicWindows())?.first {
            stringAttribute($0, kAXTitleAttribute as String)
                .components(separatedBy: LogicUIStrings.Window.viewSeparator).last
                == LogicUIStrings.Window.projectSettingsView
        }
    }

    /// The Smart Tempo pane's "Project Tempo Mode" pop-up, if that pane is the
    /// one showing.
    ///
    /// Identified by its `AXHelp` prefix, not by position: the pane is a flat
    /// list of static texts and controls with no grouping, and its neighbours
    /// ("Set Imported Files To", "Set New Recordings To", "Export Tempo
    /// Resolution", "Default Tempo Behavior") are pop-ups too. Measured
    /// 2026-08-28 on Logic Pro 12.3.1.
    func projectTempoModePopUp(in window: AXUIElement) -> AXUIElement? {
        firstDescendant(of: window, maximumDepth: AXDepth.projectSettingsControl) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXPopUpButton"
                && stringAttribute(element, kAXHelpAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.projectTempoModeHelpPrefix)
        }
    }

    /// Presses the Project Settings toolbar's `Smart Tempo` button.
    private func selectSmartTempoPane(in window: AXUIElement) -> Bool {
        guard let button = firstDescendant(of: window, maximumDepth: AXDepth.projectSettingsControl, where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == LogicUIStrings.Button.smartTempo
        }) else { return false }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    /// Reads the Smart Tempo project tempo mode out of `File > Project
    /// Settings > Smart Tempo…`, and puts the UI back as it was found.
    ///
    /// WHY THIS EXISTS. The control bar's Project Tempo pop-up publishes no
    /// value at all (probed 2026-08-27, see `projectTempoMode()`), which left
    /// `logic_record_midi`'s Adapt/Auto refusal unreachable: an Adapt-mode
    /// project could have its tempo map rewritten by a take and the tool could
    /// only warn. This route was the COVERAGE audit's open question 8, and the
    /// answer is yes: the settings pane publishes the mode as an ordinary
    /// `AXValue` on a labelled pop-up.
    ///
    /// MEASURED 2026-08-28, Logic Pro 12.3.1: `File > Project Settings > Smart
    /// Tempo…` opens `"<project> - Project Settings"` (an `AXDialog`-subrole
    /// standard window, not app-modal) straight onto the Smart Tempo pane, and
    /// the pop-up carries `AXValue = "Keep Project Tempo"`. The three menu
    /// wordings are Logic's own — "Keep Project Tempo", "Adapt Project Tempo",
    /// "Automatic" — which is exactly what `normalizedProjectTempoMode` was
    /// written for, and why that mapping tests substrings rather than the bare
    /// words.
    ///
    /// COST: ~0.73 s to open, read and close, measured 2026-09-02 on the
    /// reference project — 0.20 s for the first visit in a server process,
    /// 0.72–0.74 s for every later one (Logic rebuilds the File menu after the
    /// first press). It was 0.85–0.87 s until the two blind sleeps below came
    /// out. Nothing is written; the pop-up is read, never pressed.
    func projectTempoModeViaSettings() -> (mode: ProjectTempoMode, visit: ProjectSettingsVisit) {
        let existing = projectSettingsWindow()
        var opened = false
        var switchedPane = false
        var window: AXUIElement

        if let existing {
            window = existing
            if projectTempoModePopUp(in: existing) == nil {
                guard selectSmartTempoPane(in: existing) else {
                    return (.unreadable, .failed(
                        "a Project Settings window is open on another pane and its Smart Tempo"
                            + " toolbar button could not be pressed"
                    ))
                }
                switchedPane = true
            }
        } else {
            let before = Set(((try? logicWindows()) ?? []).map(WindowKey.init))
            do {
                try pressMenuItem(
                    containing: LogicUIStrings.Menu.smartTempo,
                    underMenu: LogicUIStrings.Menu.projectSettings,
                    settled: { [weak self] in
                        guard let self else { return false }
                        return self.projectSettingsWindow() != nil
                    }
                )
            } catch {
                return (.unreadable, .failed(
                    "File > Project Settings > Smart Tempo… could not be opened (\(error.localizedDescription))"
                ))
            }
            // LOOK BEFORE SLEEPING. `pressMenuItem(settled:)` above polls
            // `projectSettingsWindow() != nil` and only returns once that is
            // true, so the window is already there when this loop starts —
            // measured 2026-09-02 with a zero-wait probe: "settings window
            // present before first sleep = true", loop ticks = 1. The 120 ms
            // that used to be spent before the first look was pure waste on
            // every `read_smart_tempo_mode` call and on every
            // `logic_record_midi` arming check. The loop stays: it is the
            // verification that the window is a NEW one, not the pane check
            // `settled` cannot make.
            var found: AXUIElement?
            for tick in 0..<25 {
                if tick > 0 { Thread.sleep(forTimeInterval: 0.12) }
                if let candidate = projectSettingsWindow(),
                   !before.contains(WindowKey(element: candidate)) {
                    found = candidate
                    break
                }
            }
            guard let candidate = found else {
                return (.unreadable, .failed(
                    "File > Project Settings > Smart Tempo… was pressed and no Project Settings window appeared"
                ))
            }
            window = candidate
            opened = true
        }

        // The pane can take a beat to publish its controls after a fresh open.
        var popUp = projectTempoModePopUp(in: window)
        if popUp == nil {
            for _ in 0..<10 where popUp == nil {
                Thread.sleep(forTimeInterval: 0.12)
                popUp = projectTempoModePopUp(in: window)
            }
        }
        defer {
            // The close press BLOCKS until the teardown has landed — the same
            // family as every other AX press in this server. Measured
            // 2026-09-02 with a zero-wait probe: "settings window gone right
            // after press = true", so the 250 ms that used to follow this line
            // waited for something that had already happened. Nothing was
            // verified by it and nothing is lost with it: it was a blind sleep
            // inside a `defer`, after the mode had already been returned.
            if opened {
                _ = closeWindowElement(window)
            }
        }
        guard let popUp else {
            return (.unreadable, .failed(
                "the Project Settings window opened but published no 'Project Tempo Mode' pop-up"
            ))
        }
        let raw = stringAttribute(popUp, kAXValueAttribute as String)
        guard let mode = normalizedProjectTempoMode(raw) else {
            return (.unreadable, .failed(
                "the Project Tempo Mode pop-up published '\(raw)', which names no known mode"
            ))
        }
        let visit: ProjectSettingsVisit = opened
            ? .openedAndClosed
            : (switchedPane ? .switchedPaneOfOpenWindow : .usedOpenWindow)
        return (mode, visit)
    }
}
