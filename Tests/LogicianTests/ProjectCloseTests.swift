import XCTest
@testable import Logician

/// The pure half of `logic_close_project`: the guards that run before Logic is
/// touched, the two constant close scripts, the shared close budget, and the
/// `verified` computation.
///
/// The tool had ZERO tests until 2026-09-01, and every defect the code triage
/// found in it lived exactly here — in logic that needs no Logic Pro to check:
/// a `verified` computed from an empty array that also meant "the read
/// failed", and an identity guard that skipped itself for the one project it
/// protects most.
final class ProjectCloseTests: XCTestCase {

    /// The tuple `readOpenDocuments()` hands the guards.
    private func documents(
        _ entries: [(String, String?, Bool)]
    ) -> [(name: String, path: String?, modified: Bool)] {
        entries.map { (name: $0.0, path: $0.1, modified: $0.2) }
    }

    // MARK: - Guard 1: the saving decision

    func testSavingLiteralsMapToTheTwoScripts() throws {
        XCTAssertTrue(try ProjectClose.validateSaving("yes"))
        XCTAssertFalse(try ProjectClose.validateSaving("no"))
    }

    /// No default, no near-misses, and the refusal says nothing happened —
    /// the caller has to be able to tell a rejected argument from a close
    /// that failed halfway.
    func testAnythingButYesOrNoIsRefusedBeforeAnythingIsClosed() {
        for bad in ["", "YES", "true", "dont_save", "y", " no"] {
            XCTAssertThrowsError(try ProjectClose.validateSaving(bad), bad) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("'yes' or 'no'"), message)
                XCTAssertTrue(message.contains("Nothing was closed"), message)
            }
        }
    }

    // MARK: - Guard 2: exactly one open project

    func testTheSingleOpenDocumentIsTheTarget() throws {
        let target = try ProjectClose.target(
            in: documents([("Testlåt Copy", "/Music/Testlåt Copy.logicx", true)]),
            expectedProjectPath: nil,
            normalize: ProjectReset.normalizedTargetPath
        )
        XCTAssertEqual(target, ProjectClose.Target(
            name: "Testlåt Copy", path: "/Music/Testlåt Copy.logicx"
        ))
    }

    func testNoOpenDocumentIsRefusedAndSaysSoInWords() {
        XCTAssertThrowsError(try ProjectClose.target(
            in: [], expectedProjectPath: nil, normalize: ProjectReset.normalizedTargetPath
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("none"), message)
            XCTAssertTrue(message.contains("Nothing was closed"), message)
        }
    }

    func testSeveralOpenDocumentsAreRefusedAndBothAreNamed() {
        XCTAssertThrowsError(try ProjectClose.target(
            in: documents([("A", "/A.logicx", false), ("B", "/B.logicx", true)]),
            expectedProjectPath: nil,
            normalize: ProjectReset.normalizedTargetPath
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("A"), message)
            XCTAssertTrue(message.contains("B"), message)
        }
    }

    // MARK: - Guard 3: the identity check

    func testExpectedPathMatchesThroughNormalization() throws {
        // Decomposed from the filesystem, precomposed from the JSON client,
        // and a trailing slash from a shell that tab-completed the bundle
        // DIRECTORY: all the same project.
        let decomposed = "/Music/Testla\u{30A}t Copy.logicx"
        let target = try ProjectClose.target(
            in: documents([("Testlåt Copy", decomposed, true)]),
            expectedProjectPath: "/Music/Testlåt Copy.logicx/",
            normalize: ProjectReset.normalizedTargetPath
        )
        XCTAssertEqual(target.name, "Testlåt Copy")
    }

    func testExpectedPathMismatchRefusesWithBothPaths() {
        XCTAssertThrowsError(try ProjectClose.target(
            in: documents([("Other", "/Music/Other.logicx", true)]),
            expectedProjectPath: "/Music/Mine.logicx",
            normalize: ProjectReset.normalizedTargetPath
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("/Music/Mine.logicx"), message)
            XCTAssertTrue(message.contains("/Music/Other.logicx"), message)
            XCTAssertTrue(message.contains("No write was attempted"), message)
        }
    }

    /// The defect this test exists for: the guard used to read
    /// `if let expected = …, let path = document.path`, so a never-saved
    /// project — no path — skipped the caller's identity check entirely and
    /// was closed anyway. That is the case where `saving: "no"` destroys the
    /// most, and it must fail CLOSED.
    func testAnUnsavedProjectIsRefusedRatherThanClosedUnguarded() {
        XCTAssertThrowsError(try ProjectClose.target(
            in: documents([("Untitled", nil, true)]),
            expectedProjectPath: "/Music/Mine.logicx",
            normalize: ProjectReset.normalizedTargetPath
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("never been saved"), message)
            XCTAssertTrue(message.contains("NOTHING was closed"), message)
            XCTAssertTrue(message.contains("logic_save_project"), message)
        }
    }

    /// A caller who passed no guard still gets to close an unsaved project —
    /// the refusal is about the guard being unenforceable, not about the
    /// project being unsaved.
    func testAnUnsavedProjectClosesWhenNoGuardWasAskedFor() throws {
        let target = try ProjectClose.target(
            in: documents([("Untitled", nil, true)]),
            expectedProjectPath: nil,
            normalize: ProjectReset.normalizedTargetPath
        )
        XCTAssertEqual(target, ProjectClose.Target(name: "Untitled", path: nil))
    }

    // MARK: - Guard 4: an unreadable list is not an empty one

    func testUnreadableDocumentListSaysWhichFailureItIsAndNamesTheDialog() {
        let message = ProjectClose.unreadableDocumentList(
            whileTryingTo: "the open project, to close it",
            dialogsOnScreen: "[Do you want to save the changes?] buttons: Save, Cancel"
        ).localizedDescription
        XCTAssertTrue(message.contains("did not answer"), message)
        XCTAssertTrue(message.contains("NOT an empty one"), message)
        XCTAssertTrue(message.contains("Do you want to save the changes?"), message)
        XCTAssertTrue(message.contains("NOTHING was closed"), message)
    }

    func testUnreadableDocumentListWithNoDialogSaysThatToo() {
        let message = ProjectClose.unreadableDocumentList(
            whileTryingTo: "the open project, to save it", dialogsOnScreen: ""
        ).localizedDescription
        XCTAssertTrue(message.contains("no dialog is on screen"), message)
    }

    // MARK: - The script

    /// The document name is agent-controlled, so it reaches osascript through
    /// argv and the source stays one of two constants. A `saving` that got
    /// interpolated into a script string would be the same hole.
    func testTheCloseScriptIsAConstantThatOnlyReadsItsArgument() {
        for saving in [true, false] {
            let script = ProjectClose.closeScript(saving: saving)
            XCTAssertTrue(script.contains("item 1 of argv"), script)
            XCTAssertTrue(script.contains("on run argv"), script)
        }
        XCTAssertTrue(ProjectClose.closeScript(saving: true).contains("saving yes"))
        XCTAssertTrue(ProjectClose.closeScript(saving: false).contains("saving no"))
        XCTAssertNotEqual(
            ProjectClose.closeScript(saving: true), ProjectClose.closeScript(saving: false)
        )
    }

    // MARK: - The verdict

    func testAProjectGoneFromTheListIsVerified() {
        let verdict = ProjectClose.closeVerified(documentName: "Mine", remaining: [])
        XCTAssertTrue(verdict.verified)
        XCTAssertNil(verdict.reason)
    }

    func testAnotherProjectRemainingOpenDoesNotSinkTheVerdict() {
        let verdict = ProjectClose.closeVerified(documentName: "Mine", remaining: ["Someone Else"])
        XCTAssertTrue(verdict.verified)
    }

    func testAProjectStillInTheListIsNotVerified() {
        let verdict = ProjectClose.closeVerified(documentName: "Mine", remaining: ["Mine"])
        XCTAssertFalse(verdict.verified)
        XCTAssertEqual(verdict.reason?.contains("still in Logic's document list"), true)
    }

    /// THE defect. `remaining` used to be a non-optional array, and a readback
    /// that FAILED produced the same empty list as a project that had really
    /// gone — so the tool answered `verified: true, remaining_documents: []`
    /// for a project that was still open. An unreadable readback is false,
    /// with the reason attached, forever.
    func testAReadbackThatFailedIsNeverVerified() {
        let verdict = ProjectClose.closeVerified(documentName: "Mine", remaining: nil)
        XCTAssertFalse(verdict.verified)
        XCTAssertEqual(verdict.reason?.contains("did not answer"), true)
        XCTAssertEqual(verdict.reason?.contains("may or may not still be open"), true)
    }

    // MARK: - The shared close budget

    func testCloseTimeoutDefaultsToThirtySeconds() {
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds([:]), 30)
    }

    func testCloseTimeoutTakesTheNumberWhicheverWayItIsSpelled() {
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": 45]), 45)
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": 45.5]), 45.5)
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": "soon"]), 30)
    }

    func testCloseTimeoutIsClampedAtBothEnds() {
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": 0]), 5)
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": -10]), 5)
        XCTAssertEqual(ProjectReset.closeTimeoutSeconds(["timeout_seconds": 9999]), 300)
    }

    // MARK: - The dialog table under a keep-my-changes contract

    /// `logic_close_project` with `saving: "yes"` runs the same close loop as
    /// the reset, and the reset's answer to "Do you want to save the changes?"
    /// is **Don't Save**. Pressing it there would throw away exactly what the
    /// caller asked to keep, so for that close the alert is an unknown
    /// grammar: reported, never pressed.
    func testTheSaveChangesPromptIsNotAnsweredWhenTheCallerAskedToSave() {
        XCTAssertNil(ProjectReset.answer(
            forTexts: ["Do you want to save the changes made to the document “Mine”?"],
            buttons: ["Save", "Cancel", "Don’t Save"],
            discardingChanges: false
        ))
    }

    /// The recovery prompt does not depend on the contract — "open the last
    /// SAVED version" discards nothing — so it stays answerable either way.
    func testTheRecoveryPromptIsStillAnsweredWhenNotDiscarding() {
        XCTAssertEqual(
            ProjectReset.answer(
                forTexts: ["There is an auto-saved version of this project."],
                buttons: ["Auto-saved", "Saved", "Cancel"],
                discardingChanges: false
            )?.button,
            "Saved"
        )
    }
}
