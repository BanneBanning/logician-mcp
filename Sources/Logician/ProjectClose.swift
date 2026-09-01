import Foundation

/// The pure half of `logic_close_project`: the guards that run BEFORE Logic is
/// touched, the two constant AppleScripts the close may issue, and the verdict
/// computed from the readback afterwards. No Logic, no Accessibility,
/// unit-tested — the shape `ProjectReset` established for the reset.
///
/// It exists because every defect this tool carried was a PURE-LOGIC defect
/// (code triage 2026-09-01, `Logician-archive/profiles/logic_close_project.md`):
/// a `verified` computed from an empty document list that also meant "the read
/// failed", a `success` that was a hardcoded `true` no failure path could
/// reach, and an identity guard that skipped itself for exactly the project it
/// protects most. Pure logic that is wrong is cheap to test, and this tool had
/// no tests at all.
enum ProjectClose {

    // MARK: - What is being closed

    /// The document the close will act on.
    struct Target: Equatable {
        let name: String
        /// nil for a project that has never been saved.
        let path: String?
    }

    // MARK: - The guards

    /// `saving` is a decision the caller must make in words. Returns it as the
    /// bool the script needs, and refuses anything else before a single
    /// process is spawned.
    static func validateSaving(_ saving: String) throws -> Bool {
        switch saving {
        case "yes": return true
        case "no": return false
        default:
            throw LogicianError.invalidArguments(
                "saving must be 'yes' or 'no' (explicit decision), got '\(saving)'. Nothing was closed."
            )
        }
    }

    /// The refusal for a document list that did not ANSWER, as distinct from a
    /// document list that is empty.
    ///
    /// Logic's AppleScript suite returns nothing while Logic is modal or
    /// wedged, and until 2026-09-01 every project tool read that silence as
    /// "no documents are open" — which for the close meant
    /// `verified: true, remaining_documents: []` for a project that was still
    /// there. Every caller now refuses instead, and says which of the two it
    /// hit.
    static func unreadableDocumentList(
        whileTryingTo action: String, dialogsOnScreen: String
    ) -> LogicianError {
        LogicianError.trackNotExposed(
            requested: action,
            exposed: "Logic's document list did not answer — AppleScript returns nothing while"
                + " Logic is modal or wedged, and an unreadable list is NOT an empty one"
                + (dialogsOnScreen.isEmpty
                    ? ", and no dialog is on screen"
                    : "; Logic is showing: \(dialogsOnScreen)")
                + ". NOTHING was closed or changed"
        )
    }

    /// The one document a close may act on, or the refusal that says why there
    /// is none.
    ///
    /// The `expected_project_path` guard is the reason this is a function and
    /// not two lines at the call site. It used to read
    /// `if let expected = …, let path = document.path` — so an open document
    /// with NO path (never saved) skipped the caller's identity check
    /// entirely and the close went ahead. That fails OPEN on the one case
    /// where `saving: "no"` destroys the most: a project that exists nowhere
    /// but in Logic's memory. `saveProject` has always refused a pathless
    /// document (AXProjects.swift); this now refuses too, before touching
    /// Logic, and names the two ways forward.
    static func target(
        in documents: [(name: String, path: String?, modified: Bool)],
        expectedProjectPath: String?,
        normalize: (String) -> String
    ) throws -> Target {
        guard documents.count == 1, let document = documents.first else {
            throw LogicianError.trackNotExposed(
                requested: "exactly one open project",
                exposed: "open documents: "
                    + (documents.isEmpty ? "none" : documents.map(\.name).joined(separator: ", "))
                    + ". Nothing was closed"
            )
        }
        if let expected = expectedProjectPath {
            guard let path = document.path else {
                throw LogicianError.trackNotExposed(
                    requested: "the open project's file path, to check it against expected_project_path",
                    exposed: "'\(document.name)' has never been saved, so it has no path to compare"
                        + " — and an unsaved project is exactly where saving: 'no' destroys the most."
                        + " NOTHING was closed. Call logic_save_project (or logic_new_project for a"
                        + " pathed project) first, or drop expected_project_path to close it anyway"
                )
            }
            guard normalize(path) == normalize(expected) else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: path)
            }
        }
        return Target(name: document.name, path: document.path)
    }

    // MARK: - The script

    /// The close AppleScript, as one of two CONSTANTS.
    ///
    /// The document name is agent-controlled (it is just the `.logicx`
    /// filename the agent chose) and reaches the script through `argv`, never
    /// through the source — the rule that closed the arbitrary-execution hole
    /// recorded in FINDINGS.md, and the reason `saving` picks between two
    /// whole scripts instead of being interpolated into one.
    static func closeScript(saving: Bool) -> String {
        saving ? closeSavingYesScript : closeSavingNoScript
    }

    private static let closeSavingNoScript = """
    on run argv
        tell application "Logic Pro" to close document (item 1 of argv) saving no
    end run
    """

    private static let closeSavingYesScript = """
    on run argv
        tell application "Logic Pro" to close document (item 1 of argv) saving yes
    end run
    """

    // MARK: - The verdict

    /// Whether the close is PROVEN, from a readback that may itself have
    /// failed. `remaining` is nil when Logic's document list did not answer.
    ///
    /// The old line was `!remaining.contains(where: { $0.name == document.name })`
    /// over a non-optional array, so a readback that failed produced the same
    /// empty list as a project that had really gone — and the tool reported
    /// `verified: true` for a project that was still open. An unreadable
    /// readback is `false` with the reason attached, always.
    static func closeVerified(
        documentName: String, remaining: [String]?
    ) -> (verified: Bool, reason: String?) {
        guard let remaining else {
            return (false, "Logic's document list did not answer after the close, so the close"
                + " could not be confirmed — the project may or may not still be open."
                + " Read logic_list_windows before doing anything else.")
        }
        guard !remaining.contains(documentName) else {
            return (false, "'\(documentName)' is still in Logic's document list.")
        }
        return (true, nil)
    }
}
