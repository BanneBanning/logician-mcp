import Foundation

/// The pure half of `logic_duplicate_project`: the source guard, the
/// destination derivation, the refusals that run BEFORE anything is written,
/// and the truthful account of what happened to the ORIGINAL. No Logic, no
/// Accessibility, no filesystem — unit-tested, the shape `ProjectClose`
/// established for the close.
///
/// It exists because the tool that an agent is told to reach for *before*
/// making changes nobody approved (AGENT-GUIDE, "Experiment safely on a copy")
/// had zero behavioural coverage and is on the MUST-NOT-RUN-LIVE list — it
/// writes a project copy to disk and changes which project is open, so nothing
/// else will ever exercise it. Every defect the code triage found in it
/// (2026-09-01, `Logician-archive/profiles/logic_duplicate_project.md` §5.3
/// and §5.5) lived in logic that needs no Logic Pro to check: an order of
/// operations that made the copy first and refused afterwards, and a result
/// that called the original untouched while the call had committed it to disk.
enum ProjectDuplicate {

    // MARK: - What is being duplicated

    /// The open document the duplicate copies.
    struct Source: Equatable {
        let name: String
        /// Never optional here: a project with no path has nothing on disk to
        /// copy, and the guard below refuses it rather than inventing one.
        let path: String
        /// Logic's raw AppleScript flag. NOT a reliable "the user has unsaved
        /// work" signal — Logic sets it on a project that was merely opened
        /// (measured live 2026-08-28, `ProjectReset` phase 5) — which is why
        /// the refusal it feeds names `dont_save` as the answer for a project
        /// you have not edited.
        let modified: Bool
    }

    /// The one document a duplicate may act on, or the refusal that says why
    /// there is none. Nothing has been copied when this throws.
    static func source(
        in documents: [(name: String, path: String?, modified: Bool)]
    ) throws -> Source {
        guard documents.count == 1, let document = documents.first else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project with a file path, to duplicate",
                exposed: "open documents: "
                    + (documents.isEmpty ? "none" : documents.map(\.name).joined(separator: ", "))
                    + ". NOTHING was copied"
            )
        }
        guard let path = document.path else {
            throw LogicianError.trackNotExposed(
                requested: "the open project's file path, to copy it",
                exposed: "'\(document.name)' has never been saved, so there is nothing on disk to"
                    + " copy. NOTHING was copied — call logic_save_project first, or"
                    + " logic_new_project for a project with a path"
            )
        }
        return Source(name: document.name, path: path, modified: document.modified)
    }

    // MARK: - Where the copy goes

    /// The copy's destination: the caller's `destination_path` (tilde
    /// expanded), or `<name> Copy.logicx` beside the original.
    static func destination(forSource sourcePath: String, requested: String?) throws -> URL {
        guard let requested else {
            let source = URL(fileURLWithPath: sourcePath)
            return source.deletingLastPathComponent().appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + " Copy.logicx"
            )
        }
        let expanded = URL(fileURLWithPath: ProjectReset.normalizedTargetPath(requested))
        guard expanded.pathExtension == "logicx" else {
            throw LogicianError.invalidArguments(
                "destination_path must end in .logicx (got '\(requested)'). NOTHING was copied."
            )
        }
        return expanded
    }

    /// The refusal for a destination that is already there. It names the two
    /// ways forward, because the caller who hits this most often is one whose
    /// PREVIOUS call left the copy behind (see `copyMadeButNotOpened`).
    static func destinationExistsRefusal(path: String) -> LogicianError {
        LogicianError.invalidArguments(
            "'\(path)' already exists and this tool never overwrites a project."
                + " NOTHING was copied. Pass a different destination_path, or open the copy that"
                + " is already there with logic_open_project."
        )
    }

    // MARK: - Refuse before the copy, not after it

    /// The `if_current_modified` decision, checked BEFORE a byte is written.
    ///
    /// It used to be checked by `openProject`, which runs at the END of this
    /// tool — so `if_current_modified: "fail"` (the default since 2026-09-01)
    /// against a modified original threw *after* the copy was on disk, the
    /// result carrying the copy's path was discarded with the throw, and the
    /// obvious retry hit "already exists" on a path the caller was never told
    /// about. Nothing had gone wrong; the order of operations was the defect.
    /// Now the same decision is made from the document list this tool already
    /// read, before the copy exists.
    ///
    /// `modifiedAtOpen` is the original's state as the OPEN will find it: a
    /// successful `save_first` clears the flag, so the prompt never appears
    /// and no decision is required.
    static func openDecisionRefusal(
        openCopy: Bool,
        ifCurrentModified: String,
        sourceName: String,
        modifiedAtOpen: Bool,
        saveFailure: String?
    ) -> LogicianError? {
        guard openCopy, modifiedAtOpen else { return nil }
        guard ifCurrentModified != "save", ifCurrentModified != "dont_save" else { return nil }
        return LogicianError.trackNotExposed(
            requested: "opening the copy, which closes '\(sourceName)'",
            exposed: "'\(sourceName)' is marked modified and if_current_modified is"
                + " '\(ifCurrentModified)', so this call would have to decide what happens to"
                + " those changes — and it will not decide that for you."
                + (saveFailure.map { " (save_first was asked for and \($0).)" } ?? "")
                + " NOTHING was copied and nothing was closed. Choose one:"
                + " save_first: true (the changes go INTO the copy and the original is saved),"
                + " if_current_modified: 'save' (the changes stay in the ORIGINAL, which is"
                + " written to disk, and the copy is the older disk state),"
                + " if_current_modified: 'dont_save' (the changes are DISCARDED — and note that"
                + " Logic marks a project modified as soon as it is opened, so this is the right"
                + " answer for a project you have not actually edited), or"
                + " open_copy: false (the copy is made and the original stays open)."
        )
    }

    /// The error for an open that failed with the copy already on disk — a
    /// timeout, or a dialog nobody answered.
    ///
    /// The copy's path is the one fact the caller cannot reconstruct and the
    /// one this used to throw away: `try openProject(...)` propagated and took
    /// the half-built result with it, so the retry hit "already exists" on a
    /// path that had never been reported. The two halves are now reported
    /// separately, the way `logic_reset_to` reports `close_state` and its open.
    static func copyMadeButNotOpened(
        copyPath: String, savedBeforeCopy: Bool, underlying: Error
    ) -> LogicianError {
        LogicianError.verificationFailed(
            requested: "opening the copy at '\(copyPath)'",
            actual: "\(underlying.localizedDescription) — THE COPY WAS MADE AND THE OPEN WAS NOT."
                + " The copy is on disk at '\(copyPath)'"
                + (savedBeforeCopy
                    ? " and contains the changes save_first saved into it"
                    : " and contains the last saved disk state")
                + ", and the original is still the open project. Repeating this call with the same"
                + " destination will be refused ('already exists'), so either open the copy with"
                + " logic_open_project, or delete it, or pass a different destination_path.",
            restored: false
        )
    }

    // MARK: - What actually happened to the original

    /// How Logic's save-changes prompt was answered while the copy was opened,
    /// as observed — nil when no such prompt appeared.
    enum SaveChangesAnswer: Equatable {
        case saved
        case discarded
    }

    /// The truthful account of the ORIGINAL, which is the promise this tool is
    /// sold on and the one it used to get wrong.
    ///
    /// The result said *"the original is untouched on disk"* unconditionally,
    /// while `if_current_modified` defaulted to `"save"` — so duplicating a
    /// modified project committed the user's in-progress edits to the original
    /// and then said it had not. Three fields of the same result contradicted
    /// each other: `saved_before_copy: false`, a warning that the copy lacks
    /// the unsaved changes, and a note that the original was untouched. All
    /// three were true of different moments. This says which moment.
    struct OriginalOutcome: Equatable {
        /// The original was WRITTEN TO DISK by this call.
        let writtenToDisk: Bool
        /// The original's unsaved changes were thrown away by this call. They
        /// are not in the copy either, unless `save_first` put them there.
        let unsavedChangesDiscarded: Bool
        let note: String
        let warning: String?
    }

    static func originalOutcome(
        openedCopy: Bool, savedBeforeCopy: Bool, saveChangesAnswer: SaveChangesAnswer?
    ) -> OriginalOutcome {
        guard openedCopy else {
            return OriginalOutcome(
                writtenToDisk: savedBeforeCopy,
                unsavedChangesDiscarded: false,
                note: savedBeforeCopy
                    ? "The copy is on disk and the ORIGINAL IS STILL THE OPEN PROJECT — nothing"
                        + " was closed. save_first saved the original to disk so the copy would"
                        + " contain its unsaved changes."
                    : "The copy is on disk and the ORIGINAL IS STILL THE OPEN PROJECT — nothing"
                        + " was closed and nothing was written to the original. Open the copy with"
                        + " logic_open_project when you want to work in it.",
                warning: nil
            )
        }
        let written = savedBeforeCopy || saveChangesAnswer == .saved
        let discarded = saveChangesAnswer == .discarded
        var note = "The COPY is now the open project - experiment freely."
        if written {
            note += " THE ORIGINAL WAS WRITTEN TO DISK by this call"
                + (savedBeforeCopy
                    ? " (save_first, so the copy contains those changes)"
                    : " (if_current_modified: 'save' answered Logic's prompt while closing it, so"
                        + " those changes are in the ORIGINAL and NOT in the copy)")
                + "; its previous on-disk state is gone."
        } else if discarded {
            note += " The original's unsaved changes were DISCARDED"
                + " (if_current_modified: 'dont_save'); the original on disk is unchanged."
        } else {
            note += " The original is closed and unchanged on disk."
        }
        return OriginalOutcome(
            writtenToDisk: written,
            unsavedChangesDiscarded: discarded,
            note: note,
            warning: discarded
                ? "the original's unsaved changes were DISCARDED when it closed, and they are not"
                    + " in the copy either (the copy is the disk state) - pass save_first: true"
                    + " next time to keep them"
                : nil
        )
    }

    /// The warning for a copy that does not contain what is on screen.
    static func staleCopyWarning(modified: Bool, saveFirst: Bool) -> String? {
        guard modified, !saveFirst else { return nil }
        return "the open project has unsaved changes that are NOT in the copy (disk state was"
            + " copied); pass save_first: true to include them"
    }
}
