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
