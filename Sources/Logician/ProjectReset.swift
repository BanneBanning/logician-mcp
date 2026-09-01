import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// The episode-reset primitive: close the open project WITHOUT saving, open a
// project file, prove the world is where it says it is.
//
// Everything here already existed in pieces — `closeProject`, `openProject`,
// the two dialog answerers, the scoped caches. What did NOT exist is the
// CHAIN, and the chain is the whole product: an eval harness that resets
// between episodes needs one call that either lands in a known state or says
// exactly which step failed and what is open now. Three parts were missing:
//
// 1. Nobody owned the dialogs. `openProject` answers two of them blind (it
//    presses every 0.5 s and never reports whether anything was there), and
//    `closeProject` ran an AppleScript that BLOCKS while a modal is up — so
//    a third dialog would have hung the close with no way to see it. The
//    close now runs off-thread while an Accessibility loop walks whatever
//    Logic puts on screen, answers the known grammars from a table, and
//    reports the rest verbatim instead of pressing a button it does not
//    understand. `closeOpenDocument` is THE close since 2026-09-01:
//    `logic_close_project` calls it too rather than keeping a second,
//    dialog-blind implementation of the same Apple Event.
// 2. Nobody invalidated the caches. They are project-scoped
//    (`cacheScopeToken`), which handles a switch to ANOTHER project — but the
//    eval case reopens the SAME path, where the scope token is identical and
//    a bank map measured against unsaved tracks would survive the reset and
//    be trusted. So the reset clears all four explicitly, and reports which.
// 3. Nobody said what "reset" verified. See `ProjectReset.verification`.

/// The pure half of the reset: the dialog answer table, path normalization
/// and the verification verdict. No Logic, no Accessibility, unit-tested.
enum ProjectReset {

    // MARK: - Dialog grammar

    /// A dialog Logic can put up during a project switch, and the button that
    /// answers it for a reset whose contract is discarding unsaved work.
    ///
    /// The match is on the alert's own static text because that is the only
    /// stable identity: Logic's alerts carry no AXIdentifier, their titles are
    /// empty, and their button sets overlap (`Cancel` is on all of them).
    struct DialogGrammar {
        /// Lowercased substring that identifies the alert.
        let marker: String
        /// Button titles that answer it, in preference order — Logic spells
        /// the apostrophe as U+2019, but a straight one is accepted so a
        /// localization or OS change that swaps the glyph does not turn a
        /// known dialog into an unknown one.
        let answers: [String]
        /// What the answer DOES, for the log the tool returns.
        let effect: String
        /// True when this answer is only correct for a close whose contract is
        /// DISCARDING changes.
        ///
        /// The save-changes prompt is answered with Don't Save, which is right
        /// for `logic_reset_to` (discarding is what it is for) and for
        /// `logic_close_project` with `saving: "no"` — and flatly wrong for
        /// `saving: "yes"`, where pressing it would throw away the changes the
        /// caller just asked to keep. For that close the alert is an unknown
        /// grammar: reported, never pressed.
        let requiresDiscardContract: Bool
    }

    /// Every dialog this tool knows how to answer. Anything else is reported,
    /// never pressed: a button whose consequence has not been measured is not
    /// a button an unattended reset may click.
    static let knownDialogs: [DialogGrammar] = [
        DialogGrammar(
            marker: LogicUIStrings.AlertMarker.saveChanges,
            answers: LogicUIStrings.Button.dontSaveSpellings,
            effect: "discarded the open project's unsaved changes (the contract of this tool)",
            requiresDiscardContract: true
        ),
        DialogGrammar(
            marker: LogicUIStrings.AlertMarker.autoSaved,
            answers: [LogicUIStrings.Button.saved],
            effect: "opened the last SAVED version rather than the auto-saved one",
            requiresDiscardContract: false
        )
    ]

    /// Which button answers this alert, or nil when the grammar is unknown —
    /// or known but not ours to answer. `texts` are the alert's static texts,
    /// `buttons` its button titles; `discardingChanges` says whether the
    /// operation asking is one that throws unsaved work away (every reset, and
    /// a close with `saving: "no"`). It has no default on purpose: getting it
    /// wrong presses Don't Save on someone's changes.
    static func answer(
        forTexts texts: [String], buttons: [String], discardingChanges: Bool
    ) -> (button: String, effect: String)? {
        let haystack = texts.joined(separator: " ").lowercased()
        for grammar in knownDialogs
        where haystack.contains(grammar.marker)
            && (discardingChanges || !grammar.requiresDiscardContract) {
            guard let button = grammar.answers.first(where: buttons.contains) else { continue }
            return (button, grammar.effect)
        }
        return nil
    }

    // MARK: - The target path

    /// The path argument as a filesystem path: tilde expanded, trailing
    /// slashes trimmed (a `.logicx` is a bundle DIRECTORY, so a caller that
    /// tab-completed one arrives with a slash), Unicode precomposed so it
    /// compares equal to what Logic's AppleScript suite hands back.
    static func normalizedTargetPath(_ raw: String) -> String {
        var path = (raw as NSString).expandingTildeInPath
            .precomposedStringWithCanonicalMapping
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - The close budget

    /// How long the close may take, from the caller's arguments: 30 s by
    /// default, clamped to 5–300, and accepted whichever way a JSON client
    /// spells the number. Shared by `logic_reset_to` and
    /// `logic_close_project`, which run the same close.
    static func closeTimeoutSeconds(_ arguments: [String: Any]) -> Double {
        let requested = (arguments["timeout_seconds"] as? Double)
            ?? (arguments["timeout_seconds"] as? Int).map(Double.init)
            ?? 30
        return min(max(requested, 5), 300)
    }

    // MARK: - The verdict

    /// One thing the reset claims to have established, and whether it did.
    struct Check {
        let name: String
        let passed: Bool
        let detail: String

        var payload: [String: Any] {
            ["check": name, "passed": passed, "detail": detail]
        }
    }

    /// The verification block, and the single boolean a caller may branch on.
    ///
    /// `verified` is the AND of every check, deliberately: a reset that opened
    /// the right file but could not confirm the document is unmodified has not
    /// established a known state, and reporting `verified: true` with a caveat
    /// buried in a list is exactly the confidently-wrong answer this server
    /// exists to prevent.
    static func verification(_ checks: [Check]) -> (verified: Bool, payload: [[String: Any]], failures: [String]) {
        (
            checks.allSatisfy(\.passed),
            checks.map(\.payload),
            checks.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }
        )
    }
}

/// "Has the detached close returned yet, and did the script itself answer?",
/// crossing one thread boundary.
///
/// A lock-guarded box rather than a captured `var` because the close runs on a
/// global queue while the dialog loop runs here, and a plain captured Bool is
/// a data race the compiler is right to warn about.
private final class CloseCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failed = false

    /// `scriptFailed` is `runAppleScript` having returned nil — osascript did
    /// not run, or Logic refused the event. Worth carrying across the thread
    /// boundary because it is the difference between "the close is taking a
    /// while" and "the close never happened", and the old synchronous code
    /// said the second one out loud (`writeFailed("AppleScript close failed")`).
    func finish(scriptFailed: Bool) {
        lock.lock(); done = true; failed = scriptFailed; lock.unlock()
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var didScriptFail: Bool {
        lock.lock(); defer { lock.unlock() }
        return done && failed
    }
}

// MARK: - The Accessibility half

extension LogicAccessibility {

    /// Every alert-shaped window Logic is showing right now, as data.
    ///
    /// Read-only and AppleScript-free ON PURPOSE: this runs while a modal is
    /// up, and Logic's AppleScript suite blocks in that state — `openDocuments`
    /// would hang rather than answer. Accessibility keeps working, which is
    /// why the close loop below polls with this and not with the document
    /// list.
    ///
    /// "Alert-shaped" is deliberately loose: Logic puts the save-changes
    /// prompt up as a window with buttons and no AXDocument, and the recovery
    /// prompt as a sheet. Rather than guess at subroles, any window carrying
    /// buttons and no document is reported, and the CALLER decides whether it
    /// recognises the text.
    func visibleDialogs() -> [(element: AXUIElement, texts: [String], buttons: [String])] {
        guard let windows = try? logicWindows() else { return [] }
        var found: [(AXUIElement, [String], [String])] = []
        for window in windows {
            guard documentPath(of: window) == nil else { continue }
            var texts: [String] = []
            var buttons: [String] = []
            collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
                switch stringAttribute(element, kAXRoleAttribute as String) {
                case "AXStaticText":
                    let value = stringAttribute(element, kAXValueAttribute as String)
                    if !value.isEmpty { texts.append(value) }
                case "AXButton":
                    let title = stringAttribute(element, kAXTitleAttribute as String)
                    if !title.isEmpty { buttons.append(title) }
                default:
                    break
                }
            }
            guard !buttons.isEmpty, !texts.isEmpty else { continue }
            found.append((window, texts, buttons))
        }
        return found
    }

    /// One line per dialog on screen, for an error message. Empty string when
    /// there is none — a timeout with no dialog is a different diagnosis from
    /// a timeout with one, and the message has to be able to say so.
    func describeVisibleDialogs() -> String {
        let described = visibleDialogs().map { dialog in
            "[\(dialog.texts.joined(separator: " / "))] buttons: \(dialog.buttons.joined(separator: ", "))"
        }
        return described.joined(separator: "; ")
    }

    /// Presses a named button inside `window`. Used only for buttons named by
    /// `ProjectReset.knownDialogs`.
    @discardableResult
    func pressDialogButton(_ title: String, in window: AXUIElement) -> Bool {
        var target: AXUIElement?
        collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
            guard target == nil,
                  stringAttribute(element, kAXRoleAttribute as String) == "AXButton",
                  stringAttribute(element, kAXTitleAttribute as String) == title else { return }
            target = element
        }
        guard let button = target else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Closes the open document, walking whatever Logic puts on screen while
    /// it happens. THE close: `logic_reset_to` and `logic_close_project` both
    /// come here, so there is one dialog loop in the server, not two.
    ///
    /// The AppleScript runs on a background queue for one reason: it BLOCKS
    /// while Logic is modal, and answering the modal is this function's job.
    /// `closeProject` used to issue the same script synchronously and then
    /// sleep a second, which is why it could neither see a dialog nor survive
    /// one; it now shares this loop.
    ///
    /// `saving: false` is the discard contract — it is what lets the loop
    /// answer "Do you want to save the changes…?" with Don't Save. With
    /// `saving: true` that alert is reported and NEVER pressed, because the
    /// caller asked for the opposite of what the button does.
    ///
    /// Returns the dialogs seen (answered or not) and the document list from
    /// the read that PROVED the close; throws when the document is still open
    /// at the deadline, when the list never answered, or when the close script
    /// itself failed.
    func closeOpenDocument(
        documentName: String, saving: Bool, timeoutSeconds: Double
    ) throws -> (dialogs: [[String: Any]], remaining: [String]) {
        // The document name is agent-adjacent (it is the .logicx filename) and
        // goes through argv, never into the script source; the source is one
        // of two constants picked by `saving`.
        let script = ProjectClose.closeScript(saving: saving)
        let finished = CloseCompletionFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            // Static on purpose: this class is not Sendable, so the detached
            // close must not capture one.
            let answer = LogicAccessibility.runAppleScript(script, arguments: [documentName])
            finished.finish(scriptFailed: answer == nil)
        }

        var log: [[String: Any]] = []
        var answeredElements: [AXUIElement] = []
        // Which of the two failure stories the deadline gets to tell: a list
        // that kept saying "still open" is a different diagnosis from a list
        // that never answered at all.
        var lastReadAnswered = false
        let started = Date()
        let deadline = started.addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            for dialog in visibleDialogs() {
                // Do not answer the same alert twice: pressing a button that
                // has already dismissed one window and been replaced by
                // another with the same text would be a blind second click.
                if answeredElements.contains(where: { CFEqual($0, dialog.element) }) { continue }
                var entry: [String: Any] = [
                    "phase": "close",
                    "texts": dialog.texts,
                    "buttons": dialog.buttons
                ]
                if let answer = ProjectReset.answer(
                    forTexts: dialog.texts, buttons: dialog.buttons, discardingChanges: !saving
                ) {
                    let pressed = pressDialogButton(answer.button, in: dialog.element)
                    entry["answered_with"] = answer.button
                    entry["effect"] = answer.effect
                    entry["press_succeeded"] = pressed
                    if pressed { answeredElements.append(dialog.element) }
                } else {
                    // An unknown dialog is REPORTED, not clicked. The reset
                    // then fails on the timeout below with this in the log,
                    // which is the honest outcome: a button whose consequence
                    // was never measured must not be pressed unattended.
                    entry["answered_with"] = NSNull()
                    entry["effect"] = "UNKNOWN dialog grammar — nothing was pressed"
                    answeredElements.append(dialog.element)
                }
                log.append(entry)
            }
            // The document window is gone from Accessibility AND the script
            // has returned AND the document list ANSWERED and no longer names
            // it: three signals, because the script can return while Logic is
            // still tearing the window down, the window can vanish while a
            // sheet still owns the event loop, and a document list that could
            // not be read is not an empty one.
            //
            // The list is asked ONLY once the two cheap signals agree. It is
            // an AppleScript round trip, and AppleScript is exactly what
            // blocks while Logic is modal — asking it every 200 ms would hang
            // the loop whose job is to answer the modal.
            if finished.isFinished, (try? projectDocumentPath()) == nil {
                let documents = readOpenDocuments()
                lastReadAnswered = documents != nil
                if let documents, !documents.contains(where: { $0.name == documentName }) {
                    return (log, documents.map(\.name))
                }
            }
            // A close script that FAILED will not close anything however long
            // we wait, so stop now rather than at the deadline — but only
            // once the document window is still demonstrably there half a
            // second later, so a script that errored while Logic was already
            // tearing the project down is not called a failure.
            if finished.didScriptFail, Date().timeIntervalSince(started) > 0.5,
               (try? projectDocumentPath()) != nil {
                throw LogicianError.writeFailed(
                    "the close AppleScript returned nothing and '\(documentName)' is still open"
                        + (describeVisibleDialogs().isEmpty
                            ? " with no dialog on screen"
                            : "; Logic is showing: \(describeVisibleDialogs())")
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LogicianError.verificationFailed(
            requested: "'\(documentName)' closing" + (saving ? " and saving" : " without saving"),
            actual: (lastReadAnswered
                        ? "it was still open after \(Int(timeoutSeconds)) s"
                        : "the close was NOT confirmed within \(Int(timeoutSeconds)) s — the"
                            + " document window was still on the Accessibility plane, the close"
                            + " script had not returned, or the document list would not answer,"
                            + " so the project may or may not still be open")
                + (finished.didScriptFail ? ". The close AppleScript itself returned nothing" : "")
                + (describeVisibleDialogs().isEmpty
                    ? " with no dialog on screen"
                    : "; dialogs on screen: \(describeVisibleDialogs())")
                + (log.isEmpty ? "" : ". Dialogs walked: \(log.count)"),
            restored: false
        )
    }
}

// MARK: - The tool

extension MCPServer {

    /// Forgets every per-project cache, and says which files were actually
    /// there to forget.
    ///
    /// All four are scoped to `cacheScopeToken(projectPath:)`, so switching to
    /// a DIFFERENT project already invalidates them by construction. This
    /// exists for the case that token cannot see: reopening the SAME path,
    /// which is precisely what an eval reset does. The bank map, the parameter
    /// names and both list-editor maps can all have been measured against
    /// unsaved state that the reset just threw away, while their scope stamp
    /// still matches — a cache that is not stale but WRONG.
    @discardableResult
    func invalidateAllProjectCaches() -> [String] {
        let caches: [(String, URL)] = [
            ("bank_map", MCUController.bankCacheURL),
            ("meter_map", MCPServer.meterMapCacheURL),
            ("param_names", MCUController.nameCacheURL),
            ("tempo_map", MCPServer.tempoMapCacheURL)
        ]
        var cleared: [String] = []
        for (name, url) in caches {
            let existed = FileManager.default.fileExists(atPath: url.path)
            try? FileManager.default.removeItem(at: url)
            if existed { cleared.append(name) }
        }
        return cleared.sorted()
    }

    func handleResetTo(_ arguments: [String: Any]) throws -> Any {
        guard (arguments["confirm_discard"] as? Bool) == true else {
            throw LogicianError.invalidArguments(
                "confirm_discard must be exactly true. This tool DISCARDS the open project's"
                    + " unsaved changes — that is its contract, not a side effect — so the"
                    + " decision is required in the arguments and has no default. Nothing was"
                    + " closed and nothing was opened. If you want the changes kept, call"
                    + " logic_save_project first."
            )
        }
        let requested = try requiredString("path", in: arguments)
        let target = ProjectReset.normalizedTargetPath(requested)
        guard (target as NSString).pathExtension == "logicx" else {
            throw LogicianError.invalidArguments(
                "path must end in .logicx (got '\(target)'). Nothing was closed."
            )
        }
        // Refuse BEFORE touching anything: closing the open project and only
        // then discovering the target does not exist would leave Logic with
        // nothing open and the episode's work destroyed for no reason.
        guard FileManager.default.fileExists(atPath: target) else {
            throw LogicianError.trackNotExposed(
                requested: "project at '\(target)'",
                exposed: "no such file. NOTHING was closed and nothing was discarded —"
                    + " this check runs before the reset touches Logic."
            )
        }
        let closeTimeout = ProjectReset.closeTimeoutSeconds(arguments)

        let started = Date()
        var dialogLog: [[String: Any]] = []
        var result: [String: Any] = [
            "requested_path": requested,
            "path": target
        ]

        // MARK: Phase 1 — what is open now
        // A document list that will not answer is NOT an empty one: reading
        // the silence as "nothing is open" would skip the close and then open
        // the target on top of whatever is actually there.
        guard let before = openDocumentsSnapshot() else {
            throw ProjectClose.unreadableDocumentList(
                whileTryingTo: "the open-document list, before resetting to '\(target)'",
                dialogsOnScreen: logic.describeVisibleDialogs()
            )
        }
        result["closed"] = before.map { document -> [String: Any] in
            [
                "project": document.name,
                "path": document.path ?? NSNull(),
                // The raw AppleScript flag, named for what it is. It is NOT a
                // reliable "the user had unsaved work" signal — Logic sets it
                // on a project that was merely opened; see
                // `modified_flag_after_open`.
                "modified_flag": document.modified
            ]
        }
        guard before.count <= 1 else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project (or none) to reset from",
                exposed: "Logic has \(before.count) documents open: "
                    + before.map(\.name).joined(separator: ", ")
                    + ". Nothing was closed — close the extras by hand first."
            )
        }
        let dirtyFlag = before.first?.modified ?? false

        // MARK: Phase 2 — close without saving
        let closeStarted = Date()
        if let open = before.first {
            dialogLog += try logic.closeOpenDocument(
                documentName: open.name, saving: false, timeoutSeconds: closeTimeout
            ).dialogs
            result["close_state"] = dirtyFlag ? "closed_discarding_changes" : "closed_clean"
        } else {
            result["close_state"] = "nothing_was_open"
        }
        result["modified_flag_before_close"] = dirtyFlag
        let closeMs = Int(Date().timeIntervalSince(closeStarted) * 1000)

        // MARK: Phase 3 — the caches, while nothing is open
        // Deliberately between the close and the open: a cache read that
        // happened to race the open would re-populate from the OLD scope.
        result["caches_cleared"] = invalidateAllProjectCaches()

        // MARK: Phase 4 — open the target
        let openStarted = Date()
        let opened: [String: Any]
        do {
            opened = try logic.openProject(
                path: target, createFromTemplate: false, ifCurrentModified: "dont_save"
            )
        } catch {
            // The close already happened. An agent that is told only "open
            // failed" would not know the previous episode is GONE and Logic is
            // sitting with nothing open — so say it, loudly, in the error.
            throw LogicianError.verificationFailed(
                requested: "opening '\(target)' after the close",
                actual: "\(error.localizedDescription) — and the previous project was ALREADY"
                    + " CLOSED WITHOUT SAVING, so Logic now has no project open and the"
                    + " discarded work is gone. Dialogs seen during the close:"
                    + " \(dialogLog.isEmpty ? "none" : "\(dialogLog.count)")."
                    + " Dialogs on screen now: "
                    + (logic.describeVisibleDialogs().isEmpty ? "none" : logic.describeVisibleDialogs()),
                restored: false
            )
        }
        if let answered = opened["dialogs_answered"] as? [[String: Any]] {
            dialogLog += answered
        }
        let openMs = Int(Date().timeIntervalSince(openStarted) * 1000)

        // MARK: Phase 5 — prove it
        var checks: [ProjectReset.Check] = []
        // The AX document path SETTLES; it is not there the instant
        // `openProject` returns. Measured live 2026-08-28: `openProject`'s own
        // criterion is Logic's AppleScript document list, and on the first of
        // two identical resets the list already held the project while the
        // window still published no AXDocument — a single read failed the
        // check on a reset that had actually worked. So poll for it.
        let expected = logic.normalizedPath(target)
        var frontmost: String?
        let settleStarted = Date()
        let settleDeadline = settleStarted.addingTimeInterval(15)
        while Date() < settleDeadline {
            frontmost = (try? logic.projectDocumentPath()).map(logic.normalizedPath)
            if frontmost == expected { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let settleMs = Int(Date().timeIntervalSince(settleStarted) * 1000)
        checks.append(ProjectReset.Check(
            name: "frontmost_document_is_target",
            passed: frontmost == expected,
            detail: "the frontmost document window reports "
                + (frontmost.map { "'\($0)'" } ?? "no AXDocument")
                + ", target '\(target)' (settled in \(settleMs) ms)"
        ))
        let after = openDocumentsSnapshot()
        checks.append(ProjectReset.Check(
            name: "exactly_one_document_open",
            passed: after?.count == 1,
            detail: after.map { documents in
                "open documents: "
                    + (documents.isEmpty ? "none" : documents.map(\.name).joined(separator: ", "))
            } ?? "Logic's document list did not answer, so the count is unknown"
        ))
        // NOT a check. Logic reports a freshly opened project as `modified`
        // immediately — measured live 2026-08-28 on two back-to-back resets of
        // an untouched project — because the flag also covers view state that
        // Cmd-S does not write (`saveProject` has documented the same thing
        // from the other side since v0.29). Gating `verified` on it would fail
        // every reset that worked, so it is reported as an observation with
        // the reason, and never as evidence of unsaved user work.
        result["modified_flag_after_open"] = after?.first?.modified ?? NSNull()
        let health = logic.health()
        checks.append(ProjectReset.Check(
            name: "accessibility_trusted",
            passed: health["accessibility_trusted"] as? Bool == true,
            detail: "logic_health reports accessibility_trusted="
                + String(describing: health["accessibility_trusted"] ?? "unknown")
        ))
        checks.append(ProjectReset.Check(
            name: "logic_running",
            passed: health["logic_running"] as? Bool == true,
            detail: "logic_health reports logic_running="
                + String(describing: health["logic_running"] ?? "unknown")
        ))
        let leftover = logic.describeVisibleDialogs()
        checks.append(ProjectReset.Check(
            name: "no_dialog_left_on_screen",
            passed: leftover.isEmpty,
            detail: leftover.isEmpty ? "none" : leftover
        ))

        let verdict = ProjectReset.verification(checks)
        result["success"] = verdict.verified
        result["verified"] = verdict.verified
        result["state"] = verdict.verified ? "reset" : "reset_unverified"
        result["opened"] = opened["state"] ?? "opened"
        result["project"] = (target as NSString).lastPathComponent
        result["verification"] = verdict.payload
        if !verdict.failures.isEmpty { result["verification_failures"] = verdict.failures }
        result["dialogs"] = dialogLog
        result["dialog_count"] = dialogLog.count
        result["health"] = health
        result["timing_ms"] = [
            "close": closeMs,
            "open": openMs,
            "total": Int(Date().timeIntervalSince(started) * 1000)
        ]
        result["note"] = "THE UNSAVED STATE OF THE PREVIOUS PROJECT IS GONE — that is what this"
            + " tool does. Every per-project cache was cleared explicitly (the scope token"
            + " cannot tell a reopened SAME path from a stale map measured against unsaved"
            + " tracks), so the first bank-walking call after this pays for a fresh scan."
            + " `dialogs` is the grammar Logic actually showed, in order; an unrecognised"
            + " dialog is reported and NEVER pressed — and measured live, the AppleScript"
            + " close with saving:no puts up NO dialog even on a dirty project, so an empty"
            + " list is the normal case rather than a sign nothing was discarded."
            + " The two `modified_flag_*` fields are Logic's own dirty bit and are"
            + " OBSERVATIONS, not evidence: Logic marks a project modified the moment it"
            + " opens (view state counts), so neither one proves real unsaved work"
            + " existed — and neither is part of `verified`."
        if !verdict.verified {
            appendWarning(
                "The reset ran but did NOT fully verify: "
                    + verdict.failures.joined(separator: "; ")
                    + ". Do not start an episode against this state — read logic_health and"
                    + " logic_list_windows before doing anything else.",
                to: &result
            )
        }
        return result
    }

    /// The open-document list as the reset reads it — nil when the read
    /// itself failed. A thin wrapper so the phases above read as one story
    /// instead of repeating the tuple type.
    private func openDocumentsSnapshot() -> [(name: String, path: String?, modified: Bool)]? {
        logic.readOpenDocuments()
    }
}
