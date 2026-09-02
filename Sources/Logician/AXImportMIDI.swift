import AppKit
import ApplicationServices
import Foundation

// MARK: - Driving File > Import > MIDI File…

/// The measured route, step for step (R2 import research, 2026-08-30, Logic Pro
/// 12.3.1). Every deviation below was a MEASURED failure, so the comments name
/// what was tried instead of what was reasoned:
///
/// * The menu walk, not ⌘I. `Import…` (⌘I) opens the identical panel and is no
///   faster, and its keystroke was dropped one run in two.
/// * Never `open -a "Logic Pro" file.mid`: Logic treats a `.mid` as a document
///   to open IN PLACE of the current project and asks to save it first.
/// * The panel's contents are served by an AppKit XPC process, but the WINDOW
///   hangs off Logic's own tree (`AXIdentifier == "open-panel"`), so everything
///   here walks down from Logic's window list. `savePanelApplication()`, which
///   looks for the XPC process's own windows, finds nothing at all.
/// * The Go-to-Folder sheet's path field is settable, and setting it is not
///   enough: the AX write leaves `AXFocused = 0`, and `AXConfirm` returns
///   `.success` without dismissing the sheet. Set, focus, then a REAL Return.
/// * `OKButton`'s `AXEnabled` LAGS. Pressing while it reads `0` returns
///   `.success` and does nothing, and the panel then sits for the full timeout.
extension LogicAccessibility {

    /// Imports one Standard MIDI File through Logic's own importer.
    ///
    /// Owns every dialog it opens: the panel, the Go-to-Folder sheet, and the
    /// unconditional tempo prompt. On any failure it cancels whatever is
    /// standing before it throws — a modal left on screen swallows Logic's
    /// keyboard and every later tool call with it.
    ///
    /// - Parameter importTempo: `true` presses **Import Tempo**, which REWRITES
    ///   the project's tempo map in the file's range. The caller is responsible
    ///   for having said so out loud and for invalidating the tempo-map cache.
    /// - Returns: the per-phase timings and what the tempo prompt was answered
    ///   with (or that it never appeared).
    func importMIDIFile(path: String, importTempo: Bool) throws -> [String: Any] {
        var steps: [[String: Any]] = []
        var phase = Date()
        func mark(_ name: String) {
            steps.append(["phase": name, "ms": Int(Date().timeIntervalSince(phase) * 1000)])
            phase = Date()
        }

        try ensureLogicFrontmost(for: "the MIDI import panel")
        mark("frontmost")

        try pressMenuItem(
            containing: LogicUIStrings.Menu.midiFile, underMenu: LogicUIStrings.Menu.importMenu
        )
        guard let panel = importPanel(timeout: 10) else {
            throw LogicianError.openVerificationFailed(
                "File > Import > MIDI File… was pressed and no import panel appeared within 10 s."
                    + " Nothing was imported and no dialog was left standing."
            )
        }
        mark("open_panel")

        do {
            try setImportPanelPath(path, panel: panel)
            mark("path_set")
            try commitImportPanel(panel: panel)
            mark("import_pressed")
        } catch {
            let cleanup = dismissImportPanel()
            throw LogicianError.openVerificationFailed(
                "\(error.localizedDescription) On the way out:"
                    + " \(cleanup["cleanup"] as? String ?? "nothing was standing")."
            )
        }

        // THE TEMPO PROMPT IS UNCONDITIONAL — measured. It fires before Logic
        // parses the file at all: it appeared for a format-0 file with no
        // FF 51 anywhere, and for a file that was not MIDI in any sense. But it
        // does NOT appear when the user has previously ticked "Don't ask again"
        // (which this tool must never touch), and it does not appear for a
        // truncated MTrk. So a missing prompt is normal, not a failure: poll
        // briefly and let the census be the judge.
        var prompt: [String: Any] = ["appeared": false]
        if let alert = importAlert(timeout: 2.5) {
            let texts = alertTexts(alert)
            // Two witnesses, either of which is enough: the alert's SHAPE
            // (three `action-button-*` plus a `supression-checkbox` — pure
            // identifiers, so it survives translation) and its English first
            // line. The result records which one recognised it.
            let recognition = ImportMIDI.recognise(
                texts: texts, shapeMatches: dialogShape(of: alert).isTempoPromptShape
            )
            guard recognition.recognised else {
                // The house rule: a modal whose grammar was never measured is
                // REPORTED and never pressed. Pressing a button whose
                // consequence is unknown is the one thing worse than leaving it.
                throw LogicianError.preconditionUnmet(
                    "Logic answered the import with an alert this server does not recognise:"
                        + " [\(texts.joined(separator: " / "))]. It was LEFT ALONE rather than"
                        + " pressed on a guess — answer it in Logic, then check"
                        + " logic_list_tracks to see what the import did."
                )
            }
            let answer = ImportMIDI.answer(importTempo: importTempo)
            let pressed = pressAlertButton(alert, identifier: answer.rawValue)
            // Logic instantiates the instruments while the alert is up, so the
            // press takes as long as the import does: 430 ms for one track,
            // 5.15 s for three (measured).
            let gone = waitForAlertToClose(timeout: 30)
            prompt = [
                "appeared": true,
                "texts": texts,
                "answered": answer == .importTempo ? "Import Tempo" : "No",
                "button_identifier": answer.rawValue,
                "recognised_by": recognition.rawValue,
                "pressed": pressed,
                "dismissed": gone
            ]
            guard pressed, gone else {
                throw LogicianError.verificationFailed(
                    requested: "answering Logic's tempo prompt with"
                        + " '\(answer == .importTempo ? "Import Tempo" : "No")'",
                    actual: pressed
                        ? "the prompt was still on screen 30 s after the press"
                        : "the button could not be pressed; the prompt is still on screen",
                    restored: false
                )
            }
        }
        mark("tempo_prompt")

        return [
            "steps": steps,
            "tempo_prompt": prompt,
            "route": "menu_import_midi_file+go_to_folder"
        ]
    }

    // MARK: The panel

    /// Logic's import panel. It is a window of LOGIC's, whatever process draws
    /// its insides.
    func importPanel(timeout: Double = 0) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = (try? logicWindows())?.first(where: {
                stringAttribute($0, kAXIdentifierAttribute as String)
                    == LogicUIStrings.Identifier.openPanel
            }) { return window }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        return nil
    }

    /// A control inside the panel, by the identifier the research measured.
    /// `OKButton` and `CancelButton` are children of the panel's split group,
    /// not of the window, so this is a walk rather than a `children(of:)`.
    ///
    /// FOUND BREADTH-FIRST, and this is 65% of the whole tool. Every control
    /// here — the Go-to-Folder sheet, its path field, Import, Cancel, the
    /// sheet's Close — is within three levels of its root, but the panel's
    /// FIRST child is the file browser, whose outline is thousands of elements
    /// deep, and a pre-order walk descends all of it first. Measured
    /// 2026-09-02, four lookups per import: **1 266-2 000 ms each pre-order,
    /// 1-203 ms breadth-first**, and the import as a whole went from
    /// 8 549-8 789 ms to 2 983-3 589 ms with this one word changed. Same cap,
    /// same predicate, same one control — exactly the finding
    /// `savePanelCommitButton` shipped for the bounce panel a day earlier.
    ///
    /// "Nearest the root" is the right rule here because these identifiers are
    /// AppKit's own and there is one of each per root: the sheet is searched
    /// from the SHEET, the panel's buttons from the PANEL, so a shallower
    /// namesake cannot outrank the control that is wanted.
    func importPanelControl(_ root: AXUIElement, identifier: String) -> AXUIElement? {
        nearestDescendant(of: root, maximumDepth: AXDepth.importPanelControl) {
            self.stringAttribute($0, kAXIdentifierAttribute as String) == identifier
        }
    }

    /// Whether an element this call HOLDS has left the Accessibility plane.
    ///
    /// ONLY `.invalidUIElement` counts as gone. `.cannotComplete` is an app
    /// that is busy — which is precisely what Logic is while it instantiates
    /// the instruments an import just created — and reading that as "the
    /// dialog closed" would report a panel still on screen as dismissed.
    func elementIsGone(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return ImportMIDI.elementIsGone(status)
    }

    /// Points the panel at one absolute FILE path through the Go-to-Folder
    /// sheet. Passing the file rather than its folder navigates AND selects it,
    /// which is what arms `Import` in a single write.
    private func setImportPanelPath(_ path: String, panel: AXUIElement) throws {
        var sheet: AXUIElement?
        // ⌘⇧G is a keystroke, and a keystroke posted while Logic slips out of
        // frontmost is simply lost. One retry, each preceded by the frontmost
        // escalation, because that was the measured cause.
        for attempt in 0..<2 {
            try ensureLogicFrontmost(for: "the panel's Go to Folder shortcut")
            try postKeystroke(virtualKey: 5, flags: [.maskCommand, .maskShift]) // ⌘⇧G
            sheet = goToFolderSheet(in: panel, timeout: attempt == 0 ? 5 : 3)
            if sheet != nil { break }
        }
        guard let sheet else {
            throw LogicianError.openVerificationFailed(
                "the panel's Go to Folder sheet (⌘⇧G) did not open."
            )
        }
        guard let field = importPanelControl(
            sheet, identifier: LogicUIStrings.Identifier.pathTextField
        ) else {
            throw LogicianError.windowNotFound("the Go to Folder sheet's path field")
        }
        let write = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, path as CFString
        )
        guard write == .success else {
            throw LogicianError.writeFailed(
                "setting the Go to Folder path returned AXError \(write.rawValue)."
            )
        }
        // Without this the Return goes nowhere: the AX write leaves the field
        // unfocused (measured).
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try postKeystroke(virtualKey: 36, flags: []) // Return — AXConfirm no-ops here
        let accepted = waitForDisappearance(
            timeout: 4, patience: 0.5,
            probe: { self.elementIsGone(sheet) },
            confirm: { self.goToFolderSheet(in: panel, timeout: 0) == nil }
        )
        if accepted { return }
        throw LogicianError.verificationFailed(
            requested: "the Go to Folder sheet accepting '\(path)'",
            actual: "the sheet was still open 4 s after the path was set and Return posted",
            restored: false
        )
    }

    private func goToFolderSheet(in panel: AXUIElement, timeout: Double) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let sheet = importPanelControl(
                panel, identifier: LogicUIStrings.Identifier.goToFolderSheet
            ) { return sheet }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        return nil
    }

    /// Presses `Import`, having first waited for it to actually be armed.
    private func commitImportPanel(panel: AXUIElement) throws {
        guard let ok = importPanelControl(
            panel, identifier: LogicUIStrings.Identifier.okButton
        ) else {
            throw LogicianError.windowNotFound("the import panel's Import button")
        }
        // `AXEnabled` lags the selection by 15-35 ms and, once in a dozen runs,
        // by longer than any poll is worth waiting. Press anyway when the poll
        // runs out — the second press below is what covers that run.
        let deadline = Date().addingTimeInterval(4)
        var armed = false
        while Date() < deadline {
            if stringAttribute(ok, kAXEnabledAttribute as String) == "1" { armed = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        // A good press closes the panel in ~600 ms — and measured 2026-09-02,
        // 3/3, the panel is already off the Accessibility plane the instant
        // the press returns, so the probe usually answers on its first look.
        if waitForDisappearance(
            timeout: 1.5, patience: 0.3,
            probe: { self.elementIsGone(panel) }, confirm: { self.importPanel() == nil }
        ) { return }
        // Measured: one run in ~12 needed a second press, which then worked
        // immediately.
        _ = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        if waitForDisappearance(
            timeout: 4, patience: 0.5,
            probe: { self.elementIsGone(panel) }, confirm: { self.importPanel() == nil }
        ) { return }
        throw LogicianError.verificationFailed(
            requested: "the import panel committing",
            actual: "the panel was still open after two presses of Import"
                + (armed ? "" : " and its Import button never reported itself enabled,"
                    + " which means the path did not select a file"),
            restored: false
        )
    }

    // MARK: The alert

    /// Any Logic alert. The tempo prompt is UNTITLED, so it is addressed by its
    /// `AXDescription` rather than by a title that does not exist.
    func importAlert(timeout: Double) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let alert = (try? logicWindows())?.first(where: {
                stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.alert
            }) { return alert }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        return nil
    }

    /// Presses an alert button by identifier. The tempo prompt's buttons carry
    /// LOCALISABLE titles and stable identifiers, so the identifier is the
    /// address; `supression-checkbox` is never touched by anything here.
    @discardableResult
    func pressAlertButton(_ alert: AXUIElement, identifier: String) -> Bool {
        guard let button = children(of: alert).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXIdentifierAttribute as String) == identifier
        }) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func waitForAlertToClose(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if importAlert(timeout: 0) == nil { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    // MARK: Cleanup

    /// Leaves no dialog standing, whatever went wrong, and says what it closed.
    ///
    /// Order matters: the sheet first (it is a child of the panel), then the
    /// panel, then a tempo prompt that is somehow still up. Cancelling the
    /// panel takes the sheet with it anyway, and cancelling it leaves NOTHING
    /// behind — measured: census unchanged, no alert follows.
    @discardableResult
    func dismissImportPanel() -> [String: Any] {
        var closed: [String] = []
        if let panel = importPanel() {
            if let sheet = goToFolderSheet(in: panel, timeout: 0),
               let close = importPanelControl(
                   sheet, identifier: LogicUIStrings.Identifier.closeButton
               ) {
                _ = AXUIElementPerformAction(close, kAXPressAction as CFString)
                _ = waitForDisappearance(
                    timeout: 1, patience: 0.3,
                    probe: { self.elementIsGone(sheet) },
                    confirm: { self.goToFolderSheet(in: panel, timeout: 0) == nil }
                )
                closed.append("the Go to Folder sheet")
            }
            if let cancel = importPanelControl(
                panel, identifier: LogicUIStrings.Identifier.cancelButton
            ) {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                _ = waitForDisappearance(
                    timeout: 2, patience: 0.5,
                    probe: { self.elementIsGone(panel) }, confirm: { self.importPanel() == nil }
                )
                closed.append("the import panel")
            }
        }
        // A tempo prompt still standing is the one alert whose Cancel button is
        // known (`action-button-3`), so it is the one alert cleanup may press.
        // Anything else is reported by the caller and left alone.
        if let alert = importAlert(timeout: 0),
           ImportMIDI.recognise(
               texts: alertTexts(alert), shapeMatches: dialogShape(of: alert).isTempoPromptShape
           ).recognised {
            if pressAlertButton(alert, identifier: ImportMIDI.TempoPrompt.cancel.rawValue) {
                _ = waitForAlertToClose(timeout: 10)
                closed.append("the tempo prompt (Cancel)")
            }
        }
        return [
            "cleanup": closed.isEmpty ? "nothing was standing" : "closed " + closed.joined(separator: ", "),
            "closed": closed,
            "dialog_left_standing": importPanel() != nil || importAlert(timeout: 0) != nil
        ]
    }

    // MARK: Keystrokes

    /// A real key event with modifiers. The panel and its sheet are AppKit's,
    /// not Logic's, and they answer keystrokes where they ignore AX actions.
    func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw LogicianError.writeFailed("could not create the keyboard events")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
    }
}
