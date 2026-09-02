import Foundation

/// The pure half of the shared project OPEN: which open document PROVES the
/// target is open, and when the poll may spend an AppleScript round trip to
/// ask. No Logic, no Accessibility, unit-tested — the shape `ProjectClose`
/// established for the close.
///
/// `openProject` is one function serving `logic_open_project`,
/// `logic_new_project`, `logic_duplicate_project` and `logic_reset_to`, so
/// these two decisions were four tools' decisions, made in two lines inside a
/// poll loop, and both were wrong (code triage 2026-09-01,
/// `Logician-archive/profiles/logic_duplicate_project.md` §5.1 and §5.2).
enum ProjectOpen {

    // MARK: - What proves the open

    /// The open document that IS the target, matched by PATH — or nil when the
    /// list does not hold it.
    ///
    /// The predicate used to be `docs.contains(where: { $0.name == expectedName })`
    /// over the destination's BASENAME, while the tuple it matches against
    /// carries a path and Logic's own document path is one Accessibility read
    /// away: the identifying field was available and the weaker one was used.
    /// A destination in a DIFFERENT DIRECTORY with the same basename —
    /// `logic_duplicate_project {destination_path: "~/Desktop/Sandbox/Song.logicx"}`,
    /// which is exactly what that parameter is for — matched the still-open
    /// ORIGINAL on the first poll tick, before Logic had switched anything,
    /// and the tool answered `verified: true` for a copy that was not open.
    /// The agent then made its destructive changes in the original, having
    /// been told it was in the sandbox: a check whose positive answer could
    /// not tell the thing it wanted from something else that fit.
    static func openedDocument(
        in documents: [(name: String, path: String?, modified: Bool)],
        targetPath: String,
        normalize: (String) -> String
    ) -> (name: String, path: String)? {
        let expected = normalize(targetPath)
        for document in documents {
            guard let path = document.path, normalize(path) == expected else { continue }
            return (document.name, path)
        }
        return nil
    }

    // MARK: - The decision that must be made before anything is written

    /// The refusal for a modified current project that the open would close
    /// without being told what to do with it — or nil when the open may go
    /// ahead. Nothing has been written when this returns a refusal.
    ///
    /// It is a function, and it runs where it does, because of what the order
    /// used to be. `logic_new_project` copies the bundled template to the
    /// caller's path and then opens it, and the copy ran BEFORE this decision:
    /// a bare `logic_new_project {path: X}` against a modified project created
    /// an empty project at X, refused with *"'Y' has unsaved changes; pass
    /// if_current_modified"*, and never mentioned the package it had just
    /// written. Measured live 2026-09-02: the retry carrying the very decision
    /// the refusal demanded was then refused again — *"'X' already exists; use
    /// logic_open_project"* — pointing the caller at a project it did not know
    /// it owned. `ProjectDuplicate.openDecisionRefusal` had already learned
    /// this on the copy; the template create is the same shape and was missed.
    ///
    /// Reopening the SAME path is never refused: there is no other project to
    /// decide about, which is exactly what an eval reset does.
    static func currentModifiedRefusal(
        current: [(name: String, path: String?, modified: Bool)],
        targetPath: String,
        targetName: String,
        ifCurrentModified: String,
        creating: Bool,
        normalize: (String) -> String
    ) -> LogicianError? {
        guard let open = current.first, open.modified else { return nil }
        guard normalize(open.path ?? "") != normalize(targetPath) else { return nil }
        guard ifCurrentModified != "save", ifCurrentModified != "dont_save" else { return nil }
        return LogicianError.trackNotExposed(
            requested: (creating ? "creating and opening '" : "opening '") + targetName + "'",
            exposed: "'\(open.name)' has unsaved changes; pass if_current_modified: 'save' or"
                + " 'dont_save' (explicit decision required), or call logic_save_project first."
                + (creating
                    ? " NOTHING was created — the template is copied only once this decision is made,"
                        + " so the path you asked for is still free."
                    : " NOTHING was closed.")
        )
    }

    /// Does the open have to READ Logic's document list before it may write
    /// anything? Only when the caller has made no explicit decision about the
    /// current project's unsaved changes.
    ///
    /// This mirrors `currentModifiedRefusal`'s third guard, and it exists
    /// because the read it skips is not cheap: **260–412 ms, one Apple Event,
    /// 13–16% of a warm 1.6–2.1 s call** (measured live 2026-09-02,
    /// `Logician-archive/profiles/logic_new_project.md` §2 phase 2). With
    /// `save` or `dont_save` the refusal returns nil no matter what the list
    /// says, and nothing else in `openProject` reads it — so the call was
    /// buying an answer it then discarded, on every
    /// `logic_open_project {if_current_modified: …}`, every `logic_reset_to`
    /// (which passes `dont_save`) and every
    /// `logic_duplicate_project {open_copy: true}`.
    ///
    /// The read is KEPT for `fail` — the default, and the one decision where
    /// the answer is load-bearing. It doubles there as an early diagnosis: a
    /// document list that will not answer refuses in 300 ms with the dialogs
    /// on screen named, instead of timing out 30 s later. That diagnosis is
    /// kept exactly where the read is the only thing providing it; on the
    /// explicit-decision path the poll's own read reaches the same verdict.
    static func needsCurrentDocumentList(ifCurrentModified: String) -> Bool {
        ifCurrentModified != "save" && ifCurrentModified != "dont_save"
    }

    // MARK: - The sheet an empty project raises

    /// How long the open waits for the "Create New Track" sheet after a
    /// TEMPLATE create, before concluding this Logic does not raise one.
    ///
    /// Spent only when the sheet has not appeared yet. Measured live
    /// 2026-09-02: on this Logic the sheet is already standing when the
    /// document-list read that proves the open returns (that read alone costs
    /// 264–400 ms after the load), so the first look finds it and the budget
    /// is never touched. It is small on purpose — a Logic version that stops
    /// prompting must cost the create a look, not a wait.
    static let createTrackSheetBudgetSeconds: TimeInterval = 1.5

    /// How long to keep looking for the sheet to GO AWAY after it is answered,
    /// before reporting it as still standing. A dismissal that has not happened
    /// in a second is a dismissal that did not happen.
    static let createTrackSheetDismissalSeconds: TimeInterval = 1.0

    /// What the caller is told about the project they now have. It differs by
    /// exactly one fact — whether Logic demanded a first track on the way in —
    /// and that fact must not be buried in the dialog log, because it is the
    /// difference between an empty project and a project with a track in it.
    static func openNote(created: Bool, answeredCreateTrackSheet: Bool) -> String {
        guard created else {
            return answeredCreateTrackSheet
                ? "Opened. It had no tracks, so Logic demanded one before it would show the"
                    + " project: its Create New Track sheet was answered with Create and this"
                    + " project now has ONE more track than the file on disk does"
                    + " (`dialogs_answered` says so; logic_list_tracks names it)."
                : "Opened."
        }
        return answeredCreateTrackSheet
            ? "Created from the bundled empty template and opened; already saved on disk."
                + " Logic will not show a project with no tracks, so its Create New Track sheet"
                + " was answered with Create: the project has ONE track, of the kind that sheet"
                + " offered (Logic remembers the last kind used — logic_list_tracks names it,"
                + " logic_delete_track removes it). Cancelling instead would have closed the"
                + " project Logic had just opened — measured, not guessed."
            : "Created from the bundled empty template and opened; already saved on disk."
                + " Logic raised no Create New Track sheet, so the project is EMPTY — add"
                + " tracks with logic_create_track."
    }

    // MARK: - When the expensive read may be spent

    /// Whether this poll tick may ask Logic's document list.
    ///
    /// The list is an `osascript` spawn (45–50 ms floor, measured) on the one
    /// plane that BLOCKS while Logic is modal — for AppleScript's ~120 s
    /// default timeout, far past any of these tools' deadlines — and this poll
    /// is the poll that is *expecting* the save-changes prompt: a loop stuck
    /// inside the read cannot answer the very dialog it is waiting for. So the
    /// read is gated behind two signals that cost 1–2 ms on the Accessibility
    /// plane, which keeps answering while Logic is modal. It is the same rule
    /// `closeOpenDocument` applies from the other side (ProjectReset.swift):
    /// ask the list only once the cheap signals agree.
    ///
    /// - An alert this server RECOGNISES is on screen: never ask. That is the
    ///   deadlock, and it is the state this loop is built to walk through.
    /// - A document window is up publishing a path that is NOT the target: the
    ///   switch is still in flight (that window is the outgoing project, the
    ///   one the prompt is about), so the answer would be "no" anyway.
    /// - The target's own path, or no document window at all: ask. The AX
    ///   document path SETTLES after the open rather than arriving with it
    ///   (measured live 2026-08-28, ProjectReset phase 5 — the document list
    ///   held the project while the window still published no AXDocument), so
    ///   treating "no AXDocument yet" as "do not ask" would trade this loop's
    ///   answer for a 30 s timeout.
    static func mayAskDocumentList(
        frontmostDocumentPath: String?,
        targetPath: String,
        recognisedAlertOnScreen: Bool,
        normalize: (String) -> String
    ) -> Bool {
        guard !recognisedAlertOnScreen else { return false }
        guard let frontmost = frontmostDocumentPath else { return true }
        return normalize(frontmost) == normalize(targetPath)
    }

    /// How often the open poll looks, in seconds. The close's measured pacing
    /// (`closeOpenDocument`, 200 ms on two cheap Accessibility signals),
    /// reused rather than re-guessed — and it replaces a `Thread.sleep(0.5)`
    /// that ran BEFORE the loop's first look, so a project Logic finished
    /// opening in 300 ms was reported at 500 ms.
    static let pollIntervalSeconds: TimeInterval = 0.2
}
