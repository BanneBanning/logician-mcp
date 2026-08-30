import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Project lifecycle (AppleScript standard suite + template)

    // Logic's standard AppleScript suite is partially real: documents with
    // name/path/modified and `close saving yes/no` work; `save` is a stub
    // (event timeout) and `make new document` creates a windowless ghost.
    // Saving therefore goes through the Save key command, and new projects
    // through a bundled empty template.

    /// Runs an AppleScript. Any runtime value MUST be passed via `arguments`
    /// (reachable in the script as `item N of argv`), NEVER interpolated into
    /// `source` — a value that becomes code is an arbitrary-shell-execution
    /// hole, because agent-controlled strings (project names, which are just
    /// filenames the agent chose) reach here. `source` must be a constant.
    func runAppleScript(_ source: String, arguments: [String] = []) -> String? {
        LogicAccessibility.runAppleScript(source, arguments: arguments)
    }

    /// The same call, without an instance. `logic_reset_to` issues its close
    /// from a background queue (Logic's AppleScript blocks while a modal is
    /// up, and answering the modal is the point), and this class is not
    /// Sendable — so the detached work must not capture one.
    static func runAppleScript(_ source: String, arguments: [String] = []) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open documents as (name, path?, modified) via the standard suite.
    func openDocuments() -> [(name: String, path: String?, modified: Bool)] {
        guard let raw = runAppleScript("""
        set out to ""
        tell application "Logic Pro"
            repeat with d in documents
                try
                    set p to path of d
                on error
                    set p to ""
                end try
                set out to out & (name of d) & "\u{1F}" & p & "\u{1F}" & (modified of d) & "\u{1E}"
            end repeat
        end tell
        return out
        """) else { return [] }
        return raw.split(separator: "\u{1E}").compactMap { entry in
            let parts = entry.components(separatedBy: "\u{1F}")
            guard parts.count == 3 else { return nil }
            // NFC-normalize: the filesystem/AppleScript return decomposed
            // Unicode (Sma¨llare) while JSON clients send precomposed (Smä).
            return (parts[0].precomposedStringWithCanonicalMapping,
                    parts[1].isEmpty ? nil : parts[1].precomposedStringWithCanonicalMapping,
                    parts[2] == "true")
        }
    }

    /// Answers the "Create New Track" dialog's Create button.
    func answerCreateTrackDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var isPrompt = false
            var create: AXUIElement?
            collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains(LogicUIStrings.AlertMarker.createNewTrack) { isPrompt = true }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String)
                       == LogicUIStrings.Button.create {
                    create = element
                }
            }
            if isPrompt, let button = create {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Answers Logic's "open the auto-saved version or the last saved?"
    /// recovery prompt with Saved. Returns false when not visible.
    func answerRecoveryDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var isPrompt = false
            var savedButton: AXUIElement?
            collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains(LogicUIStrings.AlertMarker.autoSaved) { isPrompt = true }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String)
                       == LogicUIStrings.Button.saved {
                    savedButton = element
                }
            }
            if isPrompt, let button = savedButton {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Answers Logic's "Do you want to save the changes…?" prompt.
    /// Returns false when no such prompt is visible.
    ///
    /// RECOGNITION is still English (`save the changes`): the alert publishes
    /// no identifier on the WINDOW, and its shape — three `action-button-*`
    /// and no suppression checkbox — is shared with other three-button alerts,
    /// so it does not discriminate. Recognising nothing is the safe failure:
    /// the prompt is left alone rather than answered on a guess.
    ///
    /// ANSWERING is locale-independent. The alert's buttons carry measured
    /// identifiers (R2 §8): `action-button-1` = Save, `action-button-2` =
    /// Don't Save, `action-button-3` = Cancel. The English titles remain as
    /// the fallback for a Logic build that publishes no identifiers, and both
    /// apostrophe spellings of "Don't Save" are accepted.
    func answerSaveChangesDialog(save: Bool) -> Bool {
        guard let windows = try? logicWindows() else { return false }
        let identifier = save
            ? LogicUIStrings.Identifier.actionButton1
            : LogicUIStrings.Identifier.actionButton2
        let titles = save ? [LogicUIStrings.Button.save] : LogicUIStrings.Button.dontSaveSpellings
        for window in windows {
            var isPrompt = false
            var byIdentifier: AXUIElement?
            var byTitle: AXUIElement?
            collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains(LogicUIStrings.AlertMarker.saveChanges) { isPrompt = true }
                guard role == "AXButton" else { return }
                if stringAttribute(element, kAXIdentifierAttribute as String) == identifier {
                    byIdentifier = element
                }
                if titles.contains(stringAttribute(element, kAXTitleAttribute as String)) {
                    byTitle = element
                }
            }
            if isPrompt, let button = byIdentifier ?? byTitle {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Saves the open project via the Save key command, verified through the
    /// AppleScript modified flag and the ProjectData mtime. Refuses when the
    /// open document does not match expectedProjectPath (when given) or has
    /// no path yet.
    func saveProject(expectedProjectPath: String?) throws -> [String: Any] {
        let documents = openDocuments()
        guard documents.count == 1, let document = documents.first else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project to save",
                exposed: "open documents: \(documents.map(\.name).joined(separator: ", "))"
            )
        }
        guard let path = document.path else {
            throw LogicianError.trackNotExposed(
                requested: "a project with a file path",
                exposed: "'\(document.name)' has never been saved; use logic_new_project to create pathed projects"
            )
        }
        if let expected = expectedProjectPath {
            guard normalizedPath(path) == normalizedPath(expected) else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: path)
            }
        }
        if !document.modified {
            return [
                "success": true, "verified": true, "state": "already_saved",
                "project": document.name, "path": path
            ]
        }
        // Two independent success signals: the modified flag clearing, OR the
        // project file actually being rewritten (mtime) — Logic sometimes
        // keeps the dirty flag for view-only state that Cmd-S does not touch.
        let projectData = URL(fileURLWithPath: path)
            .appendingPathComponent("Alternatives/000/ProjectData").path
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: projectData)[.modificationDate] as? Date)
            .flatMap { $0 }
        let save = try MCUController.resolveKeyCommand(named: KeyCommandRegistry.Name.save, logic: self)
        _ = try MCUController.triggerKeyCommand(note: save.note, channel: save.channel)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let fresh = openDocuments().first, !fresh.modified {
                return [
                    "success": true, "verified": true, "state": "saved",
                    "project": document.name, "path": path,
                    "write_route": "midi_key_command_save"
                ]
            }
            if let before = mtimeBefore,
               let after = (try? FileManager.default.attributesOfItem(atPath: projectData)[.modificationDate] as? Date).flatMap({ $0 }),
               after > before {
                return [
                    "success": true, "verified": true, "state": "saved",
                    "project": document.name, "path": path,
                    "write_route": "midi_key_command_save",
                    "note": "Verified via the project file being rewritten; Logic kept the modified flag (view-only state does that)."
                ]
            }
        }
        throw LogicianError.verificationFailed(
            requested: "save of '\(document.name)'",
            actual: "neither the modified flag cleared nor the project file changed within 10 s. "
                + "If saves keep failing, the key-command MIDI binding may be orphaned "
                + "(happens when the MIDI ports are recreated) - run logic_setup_key_commands "
                + "with relearn: true to repair all bindings",
            restored: false
        )
    }

    /// Opens a project (or creates one from the bundled empty template when
    /// creating). Logic runs single-project: an open modified project blocks
    /// unless the caller explicitly chose to save or discard it.
    func openProject(
        path: String, createFromTemplate: Bool, ifCurrentModified: String
    ) throws -> [String: Any] {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if createFromTemplate {
            guard target.pathExtension == "logicx" else {
                throw LogicianError.invalidArguments("path must end in .logicx")
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw LogicianError.invalidArguments("'\(target.path)' already exists; use logic_open_project")
            }
            guard let template = Bundle.module.url(
                forResource: "EmptyProject", withExtension: "logicx"
            ) else {
                throw LogicianError.trackNotExposed(
                    requested: "the bundled empty project template",
                    exposed: "EmptyProject.logicx missing from the resource bundle"
                )
            }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: template, to: target)
        } else {
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw LogicianError.trackNotExposed(
                    requested: "project at '\(target.path)'", exposed: "no such file"
                )
            }
        }
        // Single-project guard: a modified current project needs an explicit decision.
        let current = openDocuments()
        if let open = current.first, open.modified, normalizedPath(open.path ?? "") != normalizedPath(target.path) {
            switch ifCurrentModified {
            case "save", "dont_save":
                break // answered below once Logic asks
            default:
                throw LogicianError.trackNotExposed(
                    requested: "opening '\(target.lastPathComponent)'",
                    exposed: "'\(open.name)' has unsaved changes; pass if_current_modified: 'save' or 'dont_save' (explicit decision required), or call logic_save_project first"
                )
            }
        }
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Logic Pro", target.path]
        try openProcess.run()
        openProcess.waitUntilExit()
        // Answer the save-changes prompt per the caller's explicit choice.
        let expectedName = target.deletingPathExtension().lastPathComponent
        // Which prompts actually appeared, in order. This used to be silent —
        // the two answerers return a Bool that nobody read — so a project that
        // opened after discarding someone's changes looked identical to one
        // that opened clean. `logic_reset_to` folds this into its dialog log,
        // and every other caller now gets the same receipt for free.
        var dialogsAnswered: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if ifCurrentModified == "save" || ifCurrentModified == "dont_save" {
                let save = ifCurrentModified == "save"
                if answerSaveChangesDialog(save: save) {
                    dialogsAnswered.append([
                        "phase": "open",
                        "dialog": "save_changes",
                        "answered_with": save
                            ? LogicUIStrings.Button.save : LogicUIStrings.Button.dontSave,
                        "effect": save
                            ? "saved the previously open project before closing it"
                            : "discarded the previously open project's unsaved changes"
                    ])
                }
            }
            // Auto-save recovery prompt: always prefer the canonical saved
            // version (the auto-saved one is what a crash would recover).
            if answerRecoveryDialog() {
                dialogsAnswered.append([
                    "phase": "open",
                    "dialog": "autosave_recovery",
                    "answered_with": LogicUIStrings.Button.saved,
                    "effect": "opened the last SAVED version rather than the auto-saved one"
                ])
            }
            let docs = openDocuments()
            if docs.contains(where: { $0.name == expectedName }) {
                var payload: [String: Any] = [
                    "success": true, "verified": true,
                    "state": createFromTemplate ? "created" : "opened",
                    "project": expectedName, "path": target.path,
                    "note": createFromTemplate
                        ? "Created from the bundled empty template and opened; already saved on disk."
                        : "Opened."
                ]
                if !dialogsAnswered.isEmpty { payload["dialogs_answered"] = dialogsAnswered }
                return payload
            }
        }
        // A timeout with a dialog on screen and a timeout without one are
        // different diagnoses ("a dialog needs attention" was a guess at one
        // of them), so the message names whatever Logic is actually showing.
        let onScreen = describeVisibleDialogs()
        throw LogicianError.verificationFailed(
            requested: "'\(expectedName)' appearing in Logic's document list",
            actual: "not there within 30 s"
                + (onScreen.isEmpty
                    ? " and no dialog is on screen"
                    : "; Logic is showing: \(onScreen)")
                + (dialogsAnswered.isEmpty
                    ? ""
                    : ". Answered on the way: "
                        + dialogsAnswered.compactMap { $0["dialog"] as? String }.joined(separator: ", ")),
            restored: false
        )
    }

    /// Duplicates the OPEN project on disk (Autosave data stripped from the
    /// copy so it opens without a recovery prompt) and optionally opens the
    /// copy — the safe way to let an agent experiment destructively.
    func duplicateProject(
        destinationPath: String?, saveFirst: Bool,
        openCopy: Bool, ifCurrentModified: String
    ) throws -> [String: Any] {
        let documents = openDocuments()
        guard documents.count == 1, let document = documents.first,
              let sourcePath = document.path else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project with a file path",
                exposed: "open documents: " + documents.map(\.name).joined(separator: ", ")
            )
        }
        var savedBeforeCopy = false
        var saveWarning: String?
        if saveFirst, document.modified {
            do {
                _ = try saveProject(expectedProjectPath: sourcePath)
                savedBeforeCopy = true
            } catch {
                // Copy the disk state anyway — a failed save must not block
                // the duplication; the caller is told what the copy contains.
                saveWarning = "save_first failed (\(error.localizedDescription)); the copy is the last saved disk state"
            }
        }
        let source = URL(fileURLWithPath: sourcePath)
        let destination: URL
        if let given = destinationPath {
            destination = URL(fileURLWithPath: (given as NSString).expandingTildeInPath)
            guard destination.pathExtension == "logicx" else {
                throw LogicianError.invalidArguments("destination_path must end in .logicx")
            }
        } else {
            destination = source.deletingLastPathComponent().appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + " Copy.logicx"
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LogicianError.invalidArguments("'\(destination.path)' already exists")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        // Strip autosave data or the copy greets its first open with a
        // "Saved or Auto-saved?" recovery prompt.
        if let alternatives = try? FileManager.default.contentsOfDirectory(
            atPath: destination.appendingPathComponent("Alternatives").path
        ) {
            for alternative in alternatives {
                try? FileManager.default.removeItem(
                    at: destination.appendingPathComponent("Alternatives/\(alternative)/Autosave")
                )
            }
        }
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "duplicated",
            "source": sourcePath,
            "copy": destination.path,
            "saved_before_copy": savedBeforeCopy
        ]
        // Both of these can be true at once (a save that did not land AND a
        // modified document), and the second used to OVERWRITE the first —
        // losing the more alarming of the two. `appendWarning` joins them.
        appendWarning(saveWarning, to: &result)
        if document.modified && !saveFirst {
            appendWarning(
                "the open project has unsaved changes that are NOT in the copy (disk state was copied); pass save_first: true to include them",
                to: &result
            )
        }
        if openCopy {
            let opened = try openProject(
                path: destination.path, createFromTemplate: false,
                ifCurrentModified: ifCurrentModified
            )
            result["opened"] = opened["state"] ?? "opened"
            result["note"] = "The COPY is now the open project - experiment freely; the original is untouched on disk."
        }
        return result
    }

    /// Closes the open project. `saving` must be an explicit 'yes' or 'no'.
    func closeProject(saving: String, expectedProjectPath: String?) throws -> [String: Any] {
        guard saving == "yes" || saving == "no" else {
            throw LogicianError.invalidArguments("saving must be 'yes' or 'no' (explicit decision)")
        }
        let documents = openDocuments()
        guard documents.count == 1, let document = documents.first else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project",
                exposed: "open documents: \(documents.map(\.name).joined(separator: ", "))"
            )
        }
        if let expected = expectedProjectPath, let path = document.path {
            guard normalizedPath(path) == normalizedPath(expected) else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: path)
            }
        }
        // The document name is agent-controlled (it is just the .logicx
        // filename the agent chose) and MUST NOT be interpolated into the
        // script — it goes through argv so it can never become code. `saving`
        // is already constrained to the two literals above.
        let savingBool = saving == "yes"
        guard runAppleScript(
            """
            on run argv
                tell application "Logic Pro" to close document (item 1 of argv) saving \(savingBool ? "yes" : "no")
            end run
            """,
            arguments: [document.name]
        ) != nil else {
            throw LogicianError.writeFailed("AppleScript close failed")
        }
        Thread.sleep(forTimeInterval: 1.0)
        let remaining = openDocuments()
        return [
            "success": true,
            "verified": !remaining.contains(where: { $0.name == document.name }),
            "state": "closed",
            "project": document.name,
            "saved": saving == "yes",
            "remaining_documents": remaining.map(\.name)
        ]
    }

}
