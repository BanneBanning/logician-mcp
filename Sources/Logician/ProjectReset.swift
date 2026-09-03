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
        /// The substring that identifies the alert, matched
        /// case-INSENSITIVELY: `match` lowercases both sides, so a marker may
        /// be spelled the way Logic spells it. "Create New Track" is
        /// title-cased in Logic and in `LogicUIStrings.AlertMarker`.
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
        /// Does Logic's AppleScript suite BLOCK while this alert is up?
        ///
        /// A MEASURED property of the individual alert, not of alerts in
        /// general, and the only thing `recognisedAlertOnScreen` — the gate in
        /// front of every document-list read — is entitled to ask. The
        /// save-changes and recovery prompts block: a read under them waits out
        /// AppleScript's ~120 s timeout, far past any of these tools'
        /// deadlines. The Create New Track sheet does NOT — measured live
        /// 2026-09-02, the open poll's list read returned in 264–400 ms with
        /// that sheet standing, on 6 creates out of 6. Calling it blocking
        /// would shut the gate on a plane that is answering perfectly well and
        /// turn every create into a 30 s timeout; calling it non-blocking is
        /// what lets the open be PROVED and the sheet then be answered on the
        /// Accessibility plane, where it actually lives.
        let blocksAppleScript: Bool
    }

    /// Every dialog this tool knows how to answer. Anything else is reported,
    /// never pressed: a button whose consequence has not been measured is not
    /// a button an unattended reset may click.
    static let knownDialogs: [DialogGrammar] = [
        DialogGrammar(
            marker: LogicUIStrings.AlertMarker.saveChanges,
            answers: LogicUIStrings.Button.dontSaveSpellings,
            effect: "discarded the open project's unsaved changes (the contract of this tool)",
            requiresDiscardContract: true,
            blocksAppleScript: true
        ),
        DialogGrammar(
            marker: LogicUIStrings.AlertMarker.autoSaved,
            answers: [LogicUIStrings.Button.saved],
            effect: "opened the last SAVED version rather than the auto-saved one",
            requiresDiscardContract: false,
            blocksAppleScript: true
        ),
        createNewTrack
    ]

    /// The sheet an EMPTY project raises the moment it opens — "Create New
    /// Track", the MIDI/Pattern/Session Player/Audio chooser, Details, "Number
    /// of tracks to create:", Create and Cancel.
    ///
    /// THIS entry is the CLOSE's answer, and it is Cancel. The open's answer is
    /// the opposite button and lives in `createTrackOpenAnswer`, because
    /// measured live 2026-09-02 the two buttons do very different things and
    /// each operation wants the other one:
    ///
    /// **Cancel does not dismiss the sheet — it abandons the project.** Three
    /// times out of three (two `logic_new_project` creates and one
    /// `logic_reset_to` into an empty template, this worktree's binary),
    /// pressing Cancel left `logic_list_windows` reporting **no windows at
    /// all**: the document Logic had just opened was gone, the document list
    /// was empty, and Logic eventually put up its "Choose a Project" template
    /// chooser. Logic does not keep a project with no tracks on screen; the
    /// sheet is a REQUIRED step of opening one, not a suggestion.
    ///
    /// For a close, that is exactly the right button: the project is on its way
    /// out, an empty project has nothing in it to lose, and Cancel is Logic's
    /// own way out of a modal sheet — pressing Create instead would add a track
    /// to a project that is being closed, and on `saving: "yes"` would write
    /// it. So the close cancels, whatever its save contract.
    ///
    /// Measured live 2026-09-02 (`Logician-archive/profiles/logic_new_project.md`,
    /// D-NP1): EVERY successful `logic_new_project` left this sheet standing
    /// and unreported, because `openProject` never looked for it and this table
    /// did not know it. The next call, in a fresh process, reported it as
    /// "UNKNOWN dialog grammar — nothing was pressed".
    static let createNewTrack = DialogGrammar(
        marker: LogicUIStrings.AlertMarker.createNewTrack,
        answers: [LogicUIStrings.Button.cancel],
        effect: "cancelled the Create New Track sheet, which closes the empty project it"
            + " belongs to — which is what this close was doing anyway",
        // Cancel is right for a close that discards AND for one that saves: the
        // project it abandons is one with no tracks in it.
        requiresDiscardContract: false,
        blocksAppleScript: false
    )

    /// Which button answers this alert, or nil when the grammar is unknown —
    /// or known but not ours to answer. `texts` are the alert's static texts,
    /// `buttons` its button titles; `discardingChanges` says whether the
    /// operation asking is one that throws unsaved work away (every reset, and
    /// a close with `saving: "no"`). It has no default on purpose: getting it
    /// wrong presses Don't Save on someone's changes.
    static func answer(
        forTexts texts: [String], buttons: [String], discardingChanges: Bool
    ) -> (button: String, effect: String)? {
        for grammar in knownDialogs {
            guard let button = match(
                grammar, texts: texts, buttons: buttons, discardingChanges: discardingChanges
            ) else { continue }
            return (button, grammar.effect)
        }
        return nil
    }

    /// The button that answers THIS grammar on an alert with these texts and
    /// these offered buttons, or nil. Both halves are required: the marker has
    /// to be in the text, and the button we would press has to be on screen —
    /// a recognised alert whose answer is missing is left alone rather than
    /// answered with whatever else it offers.
    private static func match(
        _ grammar: DialogGrammar, texts: [String], buttons: [String], discardingChanges: Bool
    ) -> String? {
        guard discardingChanges || !grammar.requiresDiscardContract else { return nil }
        let haystack = texts.joined(separator: " ").lowercased()
        guard haystack.contains(grammar.marker.lowercased()) else { return nil }
        return grammar.answers.first(where: buttons.contains)
    }

    /// The OPEN's answer to the same sheet: **Create**.
    ///
    /// Narrow on purpose — the open answers the save-changes prompt itself,
    /// from the caller's explicit `if_current_modified` decision, and must
    /// never press Don't Save out of the table by accident.
    ///
    /// Create, because Cancel abandons the project (see `createNewTrack`), and
    /// a tool whose contract is "the project is open and verified" may not hand
    /// back a Logic with nothing open. The cost is honest and reported: the
    /// project gets ONE track, of whichever kind the sheet is showing — Logic
    /// remembers the last one used, and it was Audio on the machine this was
    /// measured on. `logic_list_tracks` names it, and the alternative was no
    /// project at all.
    ///
    /// There is a better fix upstream, deliberately not taken here: a bundled
    /// `EmptyProject.logicx` that already contains one track would never raise
    /// the sheet. That is a change to a 136 KB binary resource that has to be
    /// authored in Logic, and it does not belong in the same commit as the code
    /// that copes with the sheet.
    static func createTrackOpenAnswer(
        forTexts texts: [String], buttons: [String]
    ) -> (button: String, effect: String)? {
        guard let button = match(
            createTrackOnOpen, texts: texts, buttons: buttons, discardingChanges: false
        ) else { return nil }
        return (button, createTrackOnOpen.effect)
    }

    /// The open's grammar for the sheet — same marker, the other button. Not in
    /// `knownDialogs`: the close walks that table, and the close wants Cancel.
    static let createTrackOnOpen = DialogGrammar(
        marker: LogicUIStrings.AlertMarker.createNewTrack,
        answers: [LogicUIStrings.Button.create],
        effect: "answered Logic's Create New Track sheet with Create, so the project STAYED"
            + " OPEN and now has ONE track of the kind the sheet offered (Logic will not keep"
            + " a project with no tracks on screen — measured live 2026-09-02, Cancel closes"
            + " it). logic_list_tracks names the track; logic_delete_track removes it.",
        requiresDiscardContract: false,
        blocksAppleScript: false
    )

    /// Is this sheet the Create New Track sheet at all, whatever buttons it
    /// offers? The dismissal check, which must not depend on the button we
    /// meant to press still being there.
    static func isCreateTrackSheet(texts: [String]) -> Bool {
        texts.joined(separator: " ").lowercased()
            .contains(LogicUIStrings.AlertMarker.createNewTrack.lowercased())
    }

    /// Would an Apple Event block on this alert? The MODALITY question, which
    /// is not the same question as "is this alert one we know": the Create New
    /// Track sheet is known AND non-blocking, and reading those two as one fact
    /// is what would strand the open poll behind a sheet it can simply dismiss.
    static func blocksAppleScript(forTexts texts: [String], buttons: [String]) -> Bool {
        knownDialogs.contains { grammar in
            grammar.blocksAppleScript
                && match(grammar, texts: texts, buttons: buttons, discardingChanges: true) != nil
        }
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

    // MARK: - What counts as a dialog

    /// The title of a button an alert would actually offer, or nil for one it
    /// would not — pressed by its EXACT title, so the original string is
    /// returned rather than the trimmed one.
    ///
    /// The test used to be `!title.isEmpty`, which a single space passes.
    /// Measured live 2026-09-02: closing the sandbox project reported
    /// `dialog_count: 1` for a window publishing `texts: ["Sweeps"]` — a track
    /// name — and `buttons: [" "]`, logged as an "UNKNOWN dialog grammar" on a
    /// close that was entirely clean. An ordinary Logic utility window, read
    /// as an alert nobody could answer.
    static func alertButtonTitle(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    /// Is a window with these texts and these offered buttons alert-shaped?
    /// Both halves are required: an alert says something and offers a way out.
    static func isAlertShaped(texts: [String], buttons: [String]) -> Bool {
        !texts.isEmpty && !buttons.isEmpty
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

/// The Create New Track sheet's track-type chooser, with the Accessibility
/// elements still attached: four category groups, each holding its own radio
/// group of variants (`ProjectOpen.TrackTypeOffer` carries the measured table).
///
/// The elements live here and the pure half of the question —
/// which offer answers a request — lives in `ProjectOpen`, so the matching
/// rules are unit-tested without a running Logic.
struct CreateTrackTypeChooser {
    struct Variant {
        let element: AXUIElement
        /// The word the SHEET prints, not one from any table in this server:
        /// the chooser's contents differ between Logic versions and are
        /// localized, so the labels travel with the sheet they were read from.
        let name: String
        /// Selected WITHIN ITS OWN GROUP — true in every category at once, and
        /// therefore never on its own an answer to "what will be created".
        let selected: Bool
    }

    struct Group {
        let category: String
        /// Is this the category the sheet will actually create from? The one
        /// fact that separates the four groups, and the sheet publishes it in
        /// exactly one place (see `ProjectOpen.parseTrackTypeGroup`).
        let selected: Bool
        let variants: [Variant]
    }

    let groups: [Group]

    /// Every category/variant pair on the sheet, in the sheet's own order.
    var offers: [ProjectOpen.TrackTypeOffer] {
        groups.flatMap { group in
            group.variants.map {
                ProjectOpen.TrackTypeOffer(
                    category: group.category, variant: $0.name,
                    variantSelectedInCategory: $0.selected
                )
            }
        }
    }

    /// What this sheet will create if Create is pressed now — the selected
    /// category's selected variant — or nil when no group is marked selected.
    var selectedOffer: ProjectOpen.TrackTypeOffer? {
        guard let group = groups.first(where: \.selected) else { return nil }
        let variant = group.variants.first(where: \.selected) ?? group.variants.first
        guard let variant else { return nil }
        return ProjectOpen.TrackTypeOffer(
            category: group.category, variant: variant.name,
            variantSelectedInCategory: variant.selected
        )
    }

    /// The radio button to press for this offer.
    func element(of offer: ProjectOpen.TrackTypeOffer) -> AXUIElement? {
        groups.first { $0.category == offer.category }?
            .variants.first { $0.name == offer.variant }?.element
    }
}

/// What answering the Create New Track sheet produced: the log entry, whether
/// the sheet is provably gone, and which kind of track the answer created.
///
/// A struct rather than the bare dictionary it used to be because the caller
/// now needs the type back — `initial_track` reports it, and only the code
/// that had the sheet on screen can read it.
struct CreateTrackSheetAnswer {
    let entry: [String: Any]
    let dismissed: Bool
    /// What the sheet was set to create when Create was pressed, read back off
    /// the sheet — nil when this Logic marks no category as selected.
    let selectedType: ProjectOpen.TrackTypeOffer?
    /// Every type the sheet offered, in its own words — the vocabulary a
    /// caller whose `initial_track` was not honoured needs in order to retry.
    let offered: [ProjectOpen.TrackTypeOffer]
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
                    // A BLANK title is not a button an alert would offer, and
                    // counting one turned an ordinary Logic window into a
                    // phantom dialog in `dialogs`, in every message built by
                    // `describeVisibleDialogs`, and in `logic_reset_to`'s
                    // `no_dialog_left_on_screen` check — which would fail a
                    // reset that had worked. See `ProjectReset.alertButtonTitle`.
                    if let title = ProjectReset.alertButtonTitle(
                        stringAttribute(element, kAXTitleAttribute as String)
                    ) {
                        buttons.append(title)
                    }
                default:
                    break
                }
            }
            guard ProjectReset.isAlertShaped(texts: texts, buttons: buttons) else { continue }
            found.append((window, texts, buttons))
        }
        return found
    }

    /// Is Logic showing an alert that would BLOCK an Apple Event — the
    /// save-changes prompt or the auto-save recovery prompt?
    ///
    /// Read-only, AppleScript-free, ~1–2 ms, and a MODALITY test rather than a
    /// permission to press: `discardingChanges: true` deliberately widens the
    /// match to both grammars, because the question is "would an Apple Event
    /// block right now", not "may this button be clicked". The open poll asks
    /// it before every document-list read (`ProjectOpen.mayAskDocumentList`) —
    /// a poll stuck inside that read cannot answer the prompt it is waiting
    /// for.
    ///
    /// It asks `ProjectReset.blocksAppleScript` rather than "is this alert
    /// known", because since 2026-09-02 those are different questions. The
    /// Create New Track sheet is in the answer table (the close answers it, the
    /// open answers it, nothing logs it as an unknown grammar any more) and it
    /// is MEASURED not to block: reading the table's mere recognition as
    /// modality would shut this gate on every empty-template open and time the
    /// create out at 30 s while the document list was answering in 265 ms.
    func recognisedAlertOnScreen() -> Bool {
        visibleDialogs().contains { dialog in
            ProjectReset.blocksAppleScript(forTexts: dialog.texts, buttons: dialog.buttons)
        }
    }

    /// Answers the "Create New Track" sheet an EMPTY project raises on open,
    /// and PROVES it is gone. Returns the log entry for `dialogs_answered`, or
    /// nil when no such sheet appeared within `waitingUpTo` seconds.
    ///
    /// `waitingUpTo: 0` still LOOKS once (one Accessibility window walk, 5–10
    /// ms) — the budget paces the retries, it does not gate the first look, so
    /// an open that raises no sheet pays a walk and nothing else.
    ///
    /// CREATE is pressed, not Cancel: Cancel abandons the project Logic has
    /// just opened (measured 3/3, `ProjectReset.createNewTrack`), and an open
    /// that answers its own sheet by throwing the project away would be a worse
    /// lie than the sheet it was left standing. The one track that costs is
    /// named in the entry's `effect`, and in the caller's `initial_track`.
    ///
    /// `wanting` is the caller's `initial_track` — the KIND of track the one
    /// unavoidable track should be. It is selected on the sheet before Create
    /// is pressed, and whatever the sheet ends up showing as selected is read
    /// back rather than assumed, so `initial_track.type` reports Logic's state
    /// and not this server's intention.
    func answerCreateTrackSheet(
        waitingUpTo budget: TimeInterval, wanting requestedType: String? = nil
    ) -> CreateTrackSheetAnswer? {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            for dialog in visibleDialogs() {
                guard let answer = ProjectReset.createTrackOpenAnswer(
                    forTexts: dialog.texts, buttons: dialog.buttons
                ) else { continue }
                // The type FIRST, while the sheet is still up — pressing Create
                // is the last thing that happens to it.
                let chooser = chooseCreateTrackType(requestedType, in: dialog.element)
                let pressed = pressDialogButton(answer.button, in: dialog.element)
                // The press is not the proof. An AXPress that reports success
                // on a sheet still standing is exactly the failure this whole
                // fix exists for, so look again — cheaply, and only until the
                // sheet is actually gone.
                let gone = pressed && !createTrackSheetIsOnScreen(
                    waitingUpTo: ProjectOpen.createTrackSheetDismissalSeconds
                )
                var entry: [String: Any] = [
                    "phase": "open",
                    "dialog": "create_new_track",
                    "texts": dialog.texts,
                    "buttons": dialog.buttons,
                    "answered_with": answer.button,
                    "press_succeeded": pressed,
                    "verified_gone": gone,
                    "track_types_offered": chooser.offered.map(\.label),
                    "track_type_selected": chooser.selected?.label ?? NSNull()
                ]
                entry["effect"] = gone
                    ? answer.effect
                    : "the Create New Track sheet was found and '\(answer.button)' was pressed,"
                        + " but it is STILL on screen — answer it in Logic before the next call"
                return CreateTrackSheetAnswer(
                    entry: entry, dismissed: gone,
                    selectedType: chooser.selected, offered: chooser.offered
                )
            }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: ProjectOpen.pollIntervalSeconds)
        }
    }

    /// Selects `requested` among the sheet's track types when the sheet offers
    /// it, and reports what is selected either way.
    ///
    /// The read is unconditional and the press is not: an open that asked for
    /// nothing still comes away able to SAY which kind of track it was handed,
    /// which is the whole point of `initial_track` — Logic remembers the kind
    /// last used, so "one track, of the kind the sheet offered" was a fact
    /// about the user's last session that the caller had no way to learn.
    ///
    /// Nothing is pressed unless the request MATCHES something the sheet
    /// itself publishes (`ProjectOpen.matchedTrackTypeOffer`), and what the
    /// press achieved is READ BACK rather than assumed. Both halves were
    /// bought live: on 2026-09-03 a first attempt that treated the chooser as
    /// a flat list of radio buttons reported `Software Instrument` for a
    /// create that made `Audio 1`, because EVERY one of the sheet's four
    /// category groups holds a radio reading 1 and only the group's own
    /// description says which category is the live one.
    private func chooseCreateTrackType(
        _ requested: String?, in sheet: AXUIElement
    ) -> (selected: ProjectOpen.TrackTypeOffer?, offered: [ProjectOpen.TrackTypeOffer]) {
        var chooser = createTrackTypeCategories(in: sheet)
        if let requested,
           let wanted = ProjectOpen.matchedTrackTypeOffer(
               requested: requested, offers: chooser.offers
           ),
           chooser.selectedOffer != wanted,
           let element = chooser.element(of: wanted),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            // Read the chooser again rather than believing the press: an
            // AXPress that reports success and selects nothing is the same
            // failure `verified_gone` exists for, one control down.
            chooser = createTrackTypeCategories(in: sheet)
        }
        return (chooser.selectedOffer, chooser.offers)
    }


    /// The Create New Track sheet's track-type chooser, as the sheet publishes
    /// it: four category groups, each an `AXGroup` described
    /// `"<category>, <variant>"` — with `", selected"` on the live one — over
    /// an `AXRadioGroup` of that category's own variants. Measured live
    /// 2026-09-03; the table is in `ProjectOpen.TrackTypeOffer`.
    ///
    /// Only groups whose description PARSES are taken, and only the radio
    /// buttons inside them. The sheet is full of other controls — the Details
    /// disclosure, "Open Library", "Record Enable", two device pop-ups — and a
    /// wider net would put those in `initial_track.offered` and make them
    /// pressable. An empty result is therefore a real answer about this Logic,
    /// and `ProjectOpen.trackTypeUnreadable` says so instead of guessing.
    func createTrackTypeCategories(in sheet: AXUIElement) -> CreateTrackTypeChooser {
        var groups: [CreateTrackTypeChooser.Group] = []
        collect(from: sheet, maximumDepth: AXDepth.createTrackTypeChooser) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXGroup",
                  let parsed = ProjectOpen.parseTrackTypeGroup(
                      stringAttribute(element, kAXDescriptionAttribute as String)
                  ) else { return }
            var variants: [CreateTrackTypeChooser.Variant] = []
            collect(from: element, maximumDepth: AXDepth.createTrackTypeVariant) { candidate in
                guard stringAttribute(candidate, kAXRoleAttribute as String) == "AXRadioButton"
                else { return }
                // These radios are labelled by AXDescription, not AXTitle —
                // they are icon buttons — and a nameless one can be neither
                // reported nor asked for, so it is left out of both.
                let name = stringAttribute(candidate, kAXDescriptionAttribute as String)
                guard !name.isEmpty else { return }
                variants.append(CreateTrackTypeChooser.Variant(
                    element: candidate, name: name,
                    selected: stringAttribute(candidate, kAXValueAttribute as String) == "1"
                ))
            }
            guard !variants.isEmpty else { return }
            groups.append(CreateTrackTypeChooser.Group(
                category: parsed.category, selected: parsed.selected, variants: variants
            ))
        }
        return CreateTrackTypeChooser(groups: groups)
    }


    /// Is the Create New Track sheet on screen? Looks first, then paces, up to
    /// `budget` — used to confirm a dismissal, where the answer we want is
    /// "no" and the first look usually gives it.
    private func createTrackSheetIsOnScreen(waitingUpTo budget: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            // By MARKER, not by "is there a button we could press": a sheet
            // that lost its Create button is still a sheet on screen.
            let standing = visibleDialogs().contains { dialog in
                ProjectReset.isCreateTrackSheet(texts: dialog.texts)
            }
            if !standing { return false }
            guard Date() < deadline else { return true }
            Thread.sleep(forTimeInterval: ProjectOpen.pollIntervalSeconds)
        }
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
    /// Forgets the bank map, because the project's TRACK ORDER just moved.
    ///
    /// `bank-cache.json` (MCUTransportLCD.swift:250) is a picture of which
    /// track sits in which of the control surface's 8-channel banks, scoped by
    /// Logic version and project path — and neither of those moves when a
    /// track is created, duplicated or deleted, so the file survives the one
    /// event that makes it describe a project that no longer exists. Nothing
    /// is mis-addressed in the meantime: `navigateToBank` checks the bank's
    /// expected top row before trusting a cached hit and throws the file away
    /// on a mismatch. What that costs is a full 10-bank rescan, discovered
    /// later, inside whichever MCU call happened to be next. Deleting the file
    /// at the moment the order changes turns a wrong map into an absent one —
    /// and that is CHEAPER, not merely more honest. MEASURED 2026-09-01, one
    /// `logic_mcu_sends {track_name: "Aux 1"}` (a headerless strip, so it
    /// resolves through `findChannel`) immediately after a create, same warm
    /// server process: **11 854 ms with the stale map in place, 6 796 ms with
    /// it deleted** — the stale map still has to be banked to and disproved
    /// before the rescan it was supposed to save can even start. One run per
    /// condition; the direction is not in doubt, the exact figure is one
    /// sample.
    func invalidateBankMap() {
        try? FileManager.default.removeItem(at: MCUController.bankCacheURL)
    }

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
        // One last look for the Create New Track sheet, which a reset INTO AN
        // EMPTY TEMPLATE raises. `openProject` answers it before it returns;
        // this catches the one that arrived late — while the frontmost path was
        // settling, or during the document-list read above — because the check
        // on the next line would otherwise fail a reset that worked, and the
        // failure would be a sheet nobody had been asked about. A single 5–10 ms
        // Accessibility walk when there is nothing there.
        if let sheet = logic.answerCreateTrackSheet(waitingUpTo: 0) {
            var entry = sheet.entry
            entry["phase"] = "verify"
            dialogLog.append(entry)
        }
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
