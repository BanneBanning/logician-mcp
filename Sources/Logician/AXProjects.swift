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

    /// Open documents as (name, path?, modified) via the standard suite — or
    /// `nil` when the READ ITSELF failed.
    ///
    /// The optional is the whole point. Until 2026-09-01 this returned `[]`
    /// both for "Logic has nothing open" and for "the AppleScript did not
    /// answer" (Logic modal, wedged, or too busy to service an Apple Event),
    /// and every caller treated the two as the same fact. The worst of them
    /// was `closeProject`, which turned a failed readback into
    /// `verified: true, remaining_documents: []` for a project that was still
    /// open. No caller may read silence as emptiness: each one either refuses
    /// (`ProjectClose.unreadableDocumentList`) or keeps polling.
    func readOpenDocuments() -> [(name: String, path: String?, modified: Bool)]? {
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
        """) else { return nil }
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
        guard let documents = readOpenDocuments() else {
            throw ProjectClose.unreadableDocumentList(
                whileTryingTo: "the open project, to save it",
                dialogsOnScreen: describeVisibleDialogs()
            )
        }
        return try saveProject(documents: documents, expectedProjectPath: expectedProjectPath)
    }

    /// The same save, against a document list the caller has already read.
    /// `logic_duplicate_project`'s `save_first` path holds one and used to
    /// throw it away and spend a second Apple Event on the identical read.
    func saveProject(
        documents: [(name: String, path: String?, modified: Bool)],
        expectedProjectPath: String?
    ) throws -> [String: Any] {
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
        // LOOK FIRST, then pace. This loop used to sleep 250 ms before its
        // first look, and the save is already provable when the key command
        // returns: measured live 2026-09-02, a zero-wait probe found the
        // modified flag CLEARED and the ProjectData mtime ADVANCED on the
        // first look, and the loop then completed on iteration 1 every time.
        // The 250 ms was ~34% of a ~725 ms call, bought nothing, and is gone —
        // the verification is untouched, only the wait in front of it.
        let deadline = Date().addingTimeInterval(ProjectSave.pollBudgetSeconds)
        while true {
            // A read that fails here is not a save that failed — the poll
            // simply has nothing to judge yet and looks again.
            if let fresh = readOpenDocuments()?.first, !fresh.modified {
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
            guard Date() < deadline else { break }
            Thread.sleep(forTimeInterval: ProjectSave.pollIntervalSeconds)
        }
        throw LogicianError.verificationFailed(
            requested: "save of '\(document.name)'",
            actual: "neither the modified flag cleared nor the project file changed within "
                + "\(Int(ProjectSave.pollBudgetSeconds)) s. "
                + "If saves keep failing, the key-command MIDI binding may be orphaned "
                + "(happens when the MIDI ports are recreated) - run logic_setup_key_commands "
                + "with relearn: true to repair all bindings",
            restored: false
        )
    }

    /// Opens a project (or creates one from the bundled empty template when
    /// creating). Logic runs single-project: an open modified project blocks
    /// unless the caller explicitly chose to save or discard it.
    ///
    /// THE open: `logic_open_project`, `logic_new_project`,
    /// `logic_duplicate_project` and `logic_reset_to` all come here, so the
    /// poll below is four tools' verification. Until 2026-09-01 it was wrong
    /// twice over, and both halves are `ProjectOpen`'s to decide now:
    ///
    /// - it matched Logic's document list by document NAME against the
    ///   destination's basename, so a destination in another directory with
    ///   the same basename matched the still-open ORIGINAL and returned
    ///   `verified: true` for a project Logic had not opened
    ///   (`ProjectOpen.openedDocument` matches by path);
    /// - it spawned that AppleScript read every 500 ms while *expecting* the
    ///   save-changes modal, under which Logic's AppleScript blocks for
    ///   ~120 s — far past this loop's own 30 s deadline — with the loop that
    ///   answers the modal stuck inside the read
    ///   (`ProjectOpen.mayAskDocumentList` gates it behind two 1–2 ms
    ///   Accessibility signals, as `closeOpenDocument` does).
    ///
    /// The same edit retires the `Thread.sleep(0.5)` that ran before the first
    /// look: the loop looks first and paces at the close's measured 200 ms.
    ///
    /// It also OWNS the sheet it raises. An empty project — every
    /// `logic_new_project`, by construction, and any reset into an empty
    /// template — makes Logic put up "Create New Track" the moment it opens,
    /// and until 2026-09-02 this function returned `success: true,
    /// verified: true` with that sheet standing over the project it had just
    /// handed the caller (measured live, D-NP1): the next tool call met a modal
    /// it could not name, and `logic_reset_to` would have failed its own
    /// `no_dialog_left_on_screen` check on a reset that worked. The sheet is
    /// now answered — with CREATE, because measured live 2026-09-02 Cancel does
    /// not dismiss it but abandons the project Logic just opened (3/3: no
    /// windows, no documents, Logic's template chooser) — and reported in
    /// `dialogs_answered`, including the one track that answer costs. It is
    /// answered on the Accessibility plane, after the open is proved: the sheet
    /// does not block Apple Events (measured), so it never stalls the poll.
    func openProject(
        path: String, createFromTemplate: Bool, ifCurrentModified: String,
        initialTrackType: String? = nil
    ) throws -> [String: Any] {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // Every check that can be made without writing anything, first. The
        // template COPY used to sit up here, above the document-list guard, so
        // `logic_new_project` on a modified project created the project and
        // then refused to open it — measured live 2026-09-02, and the caller
        // was told only "'X' has unsaved changes", never that a package now
        // existed at the path it asked for. The obvious retry, with the
        // decision the refusal asked for, then hit "'…' already exists; use
        // logic_open_project" for a project it had never knowingly made. Two
        // contradictory refusals and an orphan on disk, from one call that did
        // nothing wrong. This is `ProjectDuplicate.openDecisionRefusal`'s rule
        // (refuse before the copy, not after it) applied to the other tool
        // that writes before it opens.
        var template: URL?
        if createFromTemplate {
            guard target.pathExtension == "logicx" else {
                throw LogicianError.invalidArguments("path must end in .logicx")
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw LogicianError.invalidArguments("'\(target.path)' already exists; use logic_open_project")
            }
            guard let bundled = Bundle.module.url(
                forResource: "EmptyProject", withExtension: "logicx"
            ) else {
                throw LogicianError.trackNotExposed(
                    requested: "the bundled empty project template",
                    exposed: "EmptyProject.logicx missing from the resource bundle"
                )
            }
            template = bundled
        } else {
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw LogicianError.trackNotExposed(
                    requested: "project at '\(target.path)'", exposed: "no such file"
                )
            }
        }
        // Single-project guard: a modified current project needs an explicit
        // decision — so a document list that will not answer must refuse
        // rather than sail past the guard on an empty list it never read.
        //
        // Asked only when the answer can change the outcome. With
        // `if_current_modified: "save"` or `"dont_save"` the decision is
        // already made and `currentModifiedRefusal` returns nil whatever the
        // list holds, so this 260–412 ms Apple Event was computing a value the
        // next line discarded — 13% of a warm call, on four tools
        // (`ProjectOpen.needsCurrentDocumentList`).
        if ProjectOpen.needsCurrentDocumentList(ifCurrentModified: ifCurrentModified) {
            guard let current = readOpenDocuments() else {
                throw ProjectClose.unreadableDocumentList(
                    whileTryingTo: "the open-document list, before opening '\(target.lastPathComponent)'",
                    dialogsOnScreen: describeVisibleDialogs()
                )
            }
            if let refusal = ProjectOpen.currentModifiedRefusal(
                current: current,
                targetPath: target.path,
                targetName: target.lastPathComponent,
                ifCurrentModified: ifCurrentModified,
                creating: createFromTemplate,
                normalize: normalizedPath
            ) {
                throw refusal
            }
        }
        // Refusals are behind us; now the write.
        if let template {
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: template, to: target)
        }
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Logic Pro", target.path]
        try openProcess.run()
        openProcess.waitUntilExit()
        // Answer the save-changes prompt per the caller's explicit choice.
        let expectedName = target.deletingPathExtension().lastPathComponent
        let expectedPath = normalizedPath(target.path)
        // Which prompts actually appeared, in order. This used to be silent —
        // the two answerers return a Bool that nobody read — so a project that
        // opened after discarding someone's changes looked identical to one
        // that opened clean. `logic_reset_to` folds this into its dialog log,
        // and every other caller now gets the same receipt for free.
        var dialogsAnswered: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
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
            // The cheap identity read: one window walk plus one AXDocument,
            // 1–2 ms, and it answers with a PATH. It keeps answering while
            // Logic is modal, which is the whole reason the expensive read
            // hangs off it.
            let frontmost = (try? projectDocumentPath()).map(normalizedPath)
            if ProjectOpen.mayAskDocumentList(
                frontmostDocumentPath: frontmost,
                targetPath: expectedPath,
                recognisedAlertOnScreen: recognisedAlertOnScreen(),
                normalize: normalizedPath
            ) {
                // A read that fails while Logic is opening is not "nothing is
                // open" — it is no answer yet, so the loop looks again rather
                // than concluding anything from an empty list.
                if let docs = readOpenDocuments(),
                   let opened = ProjectOpen.openedDocument(
                       in: docs, targetPath: expectedPath, normalize: normalizedPath
                   ) {
                    // The project is open and PROVEN. Before handing it over,
                    // clear the sheet an empty project raises — a create always
                    // raises it, so that one waits briefly for it to appear;
                    // any other open pays a single 5–10 ms look and finds
                    // nothing.
                    var initialTrack: [String: Any]?
                    var typeWarning: String?
                    var selectedTrackType: ProjectOpen.TrackTypeOffer?
                    if let sheet = answerCreateTrackSheet(
                        waitingUpTo: createFromTemplate
                            ? ProjectOpen.createTrackSheetBudgetSeconds : 0,
                        wanting: initialTrackType
                    ) {
                        dialogsAnswered.append(sheet.entry)
                        selectedTrackType = sheet.selectedType
                        // WHICH track the caller now owns. The sheet cannot be
                        // answered without making one, so the tool that made it
                        // names it rather than leaving the caller to diff a
                        // track list it never asked for.
                        let named = sheet.dismissed
                            ? firstTrackRow(waitingUpTo: ProjectOpen.initialTrackNameBudgetSeconds)
                            : nil
                        initialTrack = ProjectOpen.initialTrackPayload(
                            requested: initialTrackType,
                            selected: sheet.selectedType,
                            offered: sheet.offered,
                            track: named,
                            trackUnavailable: sheet.dismissed
                                ? "the track list did not answer within"
                                    + " \(ProjectOpen.initialTrackNameBudgetSeconds) s"
                                : "the sheet is still on screen, so the track does not exist yet"
                        )
                        if let requested = initialTrackType,
                           initialTrack?["requested_honoured"] as? Bool != true {
                            typeWarning = ProjectOpen.trackTypeNotOfferedWarning(
                                requested: requested, offered: sheet.offered,
                                created: sheet.selectedType?.label
                            )
                        }
                    }
                    var payload: [String: Any] = [
                        "success": true, "verified": true,
                        "state": createFromTemplate ? "created" : "opened",
                        "project": opened.name, "path": target.path,
                        // Which plane proved it. The document list is the
                        // proof (it carries the path); the AX document path
                        // SETTLES afterwards, so it is reported and never
                        // required.
                        "verified_by": "document_list_path",
                        "frontmost_document": frontmost ?? NSNull(),
                        "note": ProjectOpen.openNote(
                            created: createFromTemplate,
                            answeredCreateTrackSheet: dialogsAnswered.contains {
                                $0["dialog"] as? String == "create_new_track"
                            }
                        )
                    ]
                    // Always present, empty list included: "no dialog stood in
                    // the way" is a fact worth stating on a tool whose whole
                    // defect was a sheet nobody mentioned.
                    payload["dialogs_answered"] = dialogsAnswered
                    if let initialTrack { payload["initial_track"] = initialTrack }
                    // A software-instrument initial_track makes Logic open
                    // that track's own plug-in window ~1.1–1.8 s AFTER this
                    // point (measured 2026-09-03) and leave it standing; an
                    // audio initial_track opens none. Only the create path
                    // can raise it (this window comes from the sheet's
                    // track, never from opening an existing project), so the
                    // check — and the key — exist only here, not on
                    // logic_open_project/duplicate/reset_to, which share
                    // this function but must never close a window a caller
                    // has open on purpose. The wait is paid only when the
                    // track just made is one measured to raise it.
                    if createFromTemplate {
                        let dialogsClosed = closeStrayPluginWindows(
                            waitingUpTo: ProjectOpen.selectedTrackTypeExpectsStrayWindow(selectedTrackType)
                                ? ProjectOpen.strayPluginWindowBudgetSeconds : 0
                        )
                        payload["dialogs_closed"] = dialogsClosed
                        appendWarning(
                            ProjectOpen.strayPluginWindowWarning(dialogsClosed: dialogsClosed),
                            to: &payload
                        )
                    }
                    appendWarning(typeWarning, to: &payload)
                    if dialogsAnswered.contains(where: { $0["verified_gone"] as? Bool == false }) {
                        appendWarning(
                            "'\(opened.name)' is open and verified, but Logic's Create New Track"
                                + " sheet is STILL on screen after it was answered. Anything that"
                                + " presses keys or menu items will go into the sheet, not the"
                                + " project — answer it in Logic, or read logic_list_windows,"
                                + " before the next call.",
                            to: &payload
                        )
                    }
                    return payload
                }
            }
            Thread.sleep(forTimeInterval: ProjectOpen.pollIntervalSeconds)
        }
        // A timeout with a dialog on screen and a timeout without one are
        // different diagnoses ("a dialog needs attention" was a guess at one
        // of them), so the message names whatever Logic is actually showing.
        let onScreen = describeVisibleDialogs()
        throw LogicianError.verificationFailed(
            requested: "'\(expectedName)' appearing in Logic's document list at '\(expectedPath)'"
                + " (the PATH, not the name — a project with the same basename in another"
                + " directory is a different project)",
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

    /// The first row of the track list, for naming the one track the Create
    /// New Track sheet just made — or nil when the list will not say.
    ///
    /// LOOKS BEFORE IT WAITS, and stops on the first row it sees: Logic builds
    /// the track while the sheet is closing, so the first read can land in the
    /// gap, and a fixed sleep would pay for the gap on every create that does
    /// not have one. A brand-new project has exactly one track, so "the first
    /// row" is not a heuristic here — it is the track, and this is the only
    /// place that is true.
    ///
    /// Failure is nil, never a guess: `initial_track.track_name` then carries
    /// the reason instead of a name nobody read.
    func firstTrackRow(waitingUpTo budget: TimeInterval) -> (number: Int, name: String)? {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if let rows = (try? listTracks())?["tracks"] as? [[String: Any]],
               let first = rows.first,
               let number = first["track_number"] as? Int,
               let name = first["track_name"] as? String {
                return (number, name)
            }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: ProjectOpen.pollIntervalSeconds)
        }
    }

    /// Duplicates the OPEN project on disk (Autosave data stripped from the
    /// copy so it opens without a recovery prompt) and optionally opens the
    /// copy — the safe way to let an agent experiment destructively.
    ///
    /// The order of operations IS the safety here, and it used to be the other
    /// way round: every refusal that can be made from the document list this
    /// function already read is made BEFORE a byte is written, so a call that
    /// is going to be refused leaves nothing on disk. What cannot be refused
    /// in advance — an open that times out — no longer throws the copy's path
    /// away with the error (`ProjectDuplicate.copyMadeButNotOpened`).
    func duplicateProject(
        destinationPath: String?, saveFirst: Bool,
        openCopy: Bool, ifCurrentModified: String
    ) throws -> [String: Any] {
        guard let documents = readOpenDocuments() else {
            throw ProjectClose.unreadableDocumentList(
                whileTryingTo: "the open project, to duplicate it",
                dialogsOnScreen: describeVisibleDialogs()
            )
        }
        let document = try ProjectDuplicate.source(in: documents)
        let sourcePath = document.path
        // Where the copy goes, and whether that path is free — decided here,
        // above `save_first`, because both refusals are pure filesystem facts
        // and `save_first` WRITES THE USER'S PROJECT. A malformed
        // `destination_path`, or one already occupied, used to be discovered
        // only after the save had committed the original to disk: the call
        // refused, having changed the one thing it promises not to.
        let source = URL(fileURLWithPath: sourcePath)
        let destination = try ProjectDuplicate.destination(
            forSource: sourcePath, requested: destinationPath
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectDuplicate.destinationExistsRefusal(path: destination.path)
        }
        var savedBeforeCopy = false
        var saveWarning: String?
        var saveFailure: String?
        if saveFirst, document.modified {
            do {
                // The document list this function already read, handed on
                // rather than re-fetched: `saveProject` opens with the same
                // read, and one Apple Event to Logic costs 208-353 ms in this
                // process (measured live 2026-09-02).
                _ = try saveProject(documents: documents, expectedProjectPath: sourcePath)
                savedBeforeCopy = true
            } catch {
                // Copy the disk state anyway — a failed save must not block
                // the duplication; the caller is told what the copy contains.
                saveFailure = "failed (\(error.localizedDescription))"
                saveWarning = "save_first failed (\(error.localizedDescription)); the copy is the last saved disk state"
            }
        }
        // The decision the OPEN would refuse on, made before the copy exists.
        // `openProject` makes the same call at the far end of this function —
        // after the copy is on disk — which is how a schema-legal
        // `if_current_modified: 'fail'` used to leave an orphaned copy on a
        // path the caller was never told about.
        if let refusal = ProjectDuplicate.openDecisionRefusal(
            openCopy: openCopy,
            ifCurrentModified: ifCurrentModified,
            sourceName: document.name,
            modifiedAtOpen: document.modified && !savedBeforeCopy,
            saveFailure: saveFailure
        ) {
            throw refusal
        }
        // Create the destination's folder, as the template open does for its
        // own path: `destination_path: "~/Desktop/Sandbox/Copy.logicx"` with no
        // Sandbox folder used to fail on a raw Cocoa error from the copy.
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
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
            // Did `save_first` write the original before the copy was taken —
            // i.e. does the copy contain what was on screen? It answers that
            // and nothing else; `original_written_to_disk` below answers the
            // question an agent actually has about the user's project.
            "saved_before_copy": savedBeforeCopy
        ]
        // Both of these can be true at once (a save that did not land AND a
        // modified document), and the second used to OVERWRITE the first —
        // losing the more alarming of the two. `appendWarning` joins them.
        appendWarning(saveWarning, to: &result)
        appendWarning(
            ProjectDuplicate.staleCopyWarning(modified: document.modified, saveFirst: saveFirst),
            to: &result
        )
        var saveChangesAnswer: ProjectDuplicate.SaveChangesAnswer?
        if openCopy {
            let opened: [String: Any]
            do {
                opened = try openProject(
                    path: destination.path, createFromTemplate: false,
                    ifCurrentModified: ifCurrentModified
                )
            } catch {
                // The copy is on disk. Throwing the bare open error would take
                // its path with it and burn the destination for the retry.
                throw ProjectDuplicate.copyMadeButNotOpened(
                    copyPath: destination.path, savedBeforeCopy: savedBeforeCopy, underlying: error
                )
            }
            result["opened"] = opened["state"] ?? "opened"
            result["copy_frontmost_document"] = opened["frontmost_document"] ?? NSNull()
            // The receipt for the prompts the open answered. `openProject`
            // builds it precisely so a project that opened after discarding
            // someone's changes does not look identical to one that opened
            // clean — and this is the tool whose default ANSWERS that prompt,
            // so dropping it lost the one fact the caller most needs.
            if let answered = opened["dialogs_answered"] as? [[String: Any]] {
                result["dialogs_answered"] = answered
                if answered.contains(where: { $0["dialog"] as? String == "save_changes" }) {
                    saveChangesAnswer = ifCurrentModified == "save" ? .saved : .discarded
                }
            }
        }
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: openCopy,
            savedBeforeCopy: savedBeforeCopy,
            saveChangesAnswer: saveChangesAnswer
        )
        result["original_written_to_disk"] = outcome.writtenToDisk
        result["original_unsaved_changes_discarded"] = outcome.unsavedChangesDiscarded
        result["note"] = outcome.note
        appendWarning(outcome.warning, to: &result)
        return result
    }

    /// Closes the open project. `saving` must be an explicit 'yes' or 'no'.
    ///
    /// The close is `logic_reset_to`'s close (`closeOpenDocument`), not a
    /// second implementation: issued off-thread while an Accessibility loop
    /// walks whatever Logic puts on screen, because Logic's AppleScript suite
    /// BLOCKS while a modal is up. Until 2026-09-01 this function ran the
    /// script synchronously on the calling thread with no dialog handling and
    /// no timeout, so a modal raised during the close deadlocked the call
    /// until osascript's own ~120 s AppleScript timeout and then threw
    /// "AppleScript close failed" — naming nothing, with the dialog still on
    /// screen locking out every later tool. Sharing the reset's loop also
    /// retires the blind `Thread.sleep(1.0)` that followed the close: the
    /// reset's 200 ms poll on two independent signals replaces it, so a close
    /// slower than a second is waited out instead of reported unverified, and
    /// a faster one costs what it costs.
    ///
    /// One difference from the reset, and it matters: the reset's contract IS
    /// discarding, so it answers "Do you want to save the changes…?" with
    /// Don't Save. Here that answer is only correct for `saving: "no"`. With
    /// `saving: "yes"` the same alert is treated as an unknown grammar —
    /// reported, never pressed — because pressing Don't Save would throw away
    /// the changes the caller just asked to keep.
    func closeProject(
        saving: String, expectedProjectPath: String?, timeoutSeconds: Double
    ) throws -> [String: Any] {
        // Cheapest guard first: no process is spawned for a malformed decision.
        let savingBool = try ProjectClose.validateSaving(saving)
        guard let documents = readOpenDocuments() else {
            throw ProjectClose.unreadableDocumentList(
                whileTryingTo: "the open project, to close it",
                dialogsOnScreen: describeVisibleDialogs()
            )
        }
        let target = try ProjectClose.target(
            in: documents,
            expectedProjectPath: expectedProjectPath,
            normalize: normalizedPath
        )
        let outcome = try closeOpenDocument(
            documentName: target.name, saving: savingBool, timeoutSeconds: timeoutSeconds
        )
        // `remaining` comes from a read that ACTUALLY ANSWERED — the poll has
        // no other way out, and a poll that never got an answer throws above
        // with what is on screen. The optional-taking verdict is still what
        // computes this, so an unreadable list can never become a `true`.
        let verdict = ProjectClose.closeVerified(
            documentName: target.name, remaining: outcome.remaining
        )
        var result: [String: Any] = [
            "success": verdict.verified,
            "verified": verdict.verified,
            "state": verdict.verified ? "closed" : "close_unverified",
            "project": target.name,
            "path": target.path ?? NSNull(),
            "saved": savingBool,
            "remaining_documents": outcome.remaining,
            "dialogs": outcome.dialogs,
            "dialog_count": outcome.dialogs.count
        ]
        appendWarning(verdict.reason, to: &result)
        return result
    }

}
