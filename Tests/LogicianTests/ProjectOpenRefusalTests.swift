import XCTest
@testable import Logician

/// The decision the shared project OPEN makes BEFORE it writes anything, and
/// the poll pacing the save proved it does not need.
///
/// `logic_new_project` copies the bundled template to the caller's path and
/// then opens it. Until 2026-09-02 the copy ran BEFORE the modified-project
/// decision, so a bare call against a modified project created an empty
/// project and then refused to open it — and said nothing about the package it
/// had just written. Proven live that day: the refusal arrived with
/// `Throwaway-projlife-new.logicx` already on disk, and the retry carrying the
/// decision the refusal had demanded was refused again with "'…' already
/// exists; use logic_open_project".
///
/// `ProjectDuplicate.openDecisionRefusal` had already established the rule for
/// the copy — refuse before you write, from the document list you have
/// already read. These are the same rule for the template create.
final class ProjectOpenRefusalTests: XCTestCase {

    private func documents(
        _ entries: [(String, String?, Bool)]
    ) -> [(name: String, path: String?, modified: Bool)] {
        entries.map { (name: $0.0, path: $0.1, modified: $0.2) }
    }

    private let normalize = ProjectReset.normalizedTargetPath

    private func refusal(
        current: [(name: String, path: String?, modified: Bool)],
        target: String = "/Users/x/Desktop/New.logicx",
        ifCurrentModified: String = "fail",
        creating: Bool = true
    ) -> LogicianError? {
        ProjectOpen.currentModifiedRefusal(
            current: current,
            targetPath: target,
            targetName: (target as NSString).lastPathComponent,
            ifCurrentModified: ifCurrentModified,
            creating: creating,
            normalize: normalize
        )
    }

    // MARK: - When the open must be refused

    /// The defect, pinned: a modified project open, no explicit decision. The
    /// refusal has to exist so the caller reaches it BEFORE the template copy.
    func testAModifiedProjectWithNoDecisionIsRefused() {
        XCTAssertNotNil(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ])))
    }

    /// The half that cost the caller a retry: the refusal must say the path is
    /// still free, because the whole point of moving it is that nothing has
    /// been written yet.
    func testTheCreateRefusalSaysNothingWasCreated() throws {
        let error = try XCTUnwrap(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ])))
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("NOTHING was created"), text)
        XCTAssertTrue(text.contains("still free"), text)
    }

    /// An open (not a create) writes nothing of its own, so it says the other
    /// true thing rather than borrowing the create's wording.
    func testTheOpenRefusalSaysNothingWasClosed() throws {
        let error = try XCTUnwrap(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ]), creating: false))
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("NOTHING was closed"), text)
        XCTAssertFalse(text.contains("NOTHING was created"), text)
    }

    /// Both ways forward are named, as every refusal in this server must.
    func testTheRefusalNamesBothDecisions() throws {
        let error = try XCTUnwrap(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ])))
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("'save'"), text)
        XCTAssertTrue(text.contains("'dont_save'"), text)
        XCTAssertTrue(text.contains("logic_save_project"), text)
    }

    /// The refusal names the project whose changes are at stake — not the
    /// target, which is the thing the caller already knows.
    func testTheRefusalNamesTheProjectAtRisk() throws {
        let error = try XCTUnwrap(refusal(current: documents([
            ("Half-finished mix", "/Users/x/Music/Logic/Half-finished mix.logicx", true)
        ])))
        XCTAssertTrue(error.localizedDescription.contains("Half-finished mix"),
                      error.localizedDescription)
    }

    // MARK: - When the open may go ahead

    func testAnExplicitSaveIsNotRefused() {
        XCTAssertNil(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ]), ifCurrentModified: "save"))
    }

    func testAnExplicitDontSaveIsNotRefused() {
        XCTAssertNil(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ]), ifCurrentModified: "dont_save"))
    }

    func testAnUnmodifiedProjectNeedsNoDecision() {
        XCTAssertNil(refusal(current: documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", false)
        ])))
    }

    func testNothingOpenNeedsNoDecision() {
        XCTAssertNil(refusal(current: documents([])))
    }

    /// Reopening the SAME path is what an eval reset does every episode. There
    /// is no second project to decide about, so it is never refused — even
    /// though the document is modified.
    func testReopeningTheSamePathIsNeverRefused() {
        XCTAssertNil(refusal(
            current: documents([("Song", "/Users/x/Music/Logic/Song.logicx", true)]),
            target: "/Users/x/Music/Logic/Song.logicx",
            creating: false
        ))
    }

    /// The same path spelled with a tilde and a trailing slash is the same
    /// path — `.logicx` is a bundle DIRECTORY, so a tab-completed argument
    /// arrives with a slash on it.
    func testTheSamePathSurvivesTildeAndTrailingSlash() {
        let home = NSHomeDirectory()
        XCTAssertNil(refusal(
            current: documents([("Song", "\(home)/Music/Logic/Song.logicx", true)]),
            target: "~/Music/Logic/Song.logicx/",
            creating: false
        ))
    }

    /// A project that has never been saved has no path, so it cannot BE the
    /// target — its changes are exactly the ones a silent close would destroy,
    /// and it must still be refused.
    func testAPathlessModifiedProjectIsStillRefused() {
        XCTAssertNotNil(refusal(current: documents([("Untitled", nil, true)])))
    }

    // MARK: - The save poll looks before it sleeps

    /// The budget is unchanged from the `40 × 250 ms` loop this replaces; only
    /// the wait in front of the first look went away.
    func testTheSaveBudgetIsStillTenSeconds() {
        XCTAssertEqual(ProjectSave.pollBudgetSeconds, 10)
    }

    /// Kept at the close's measured pacing rather than shrunk: each look costs
    /// an Apple Event (208-353 ms in-process, measured live 2026-09-02), so a
    /// tighter interval spends more than it can save.
    func testTheSaveIntervalIsNotShrunkBelowTheCostOfALook() {
        XCTAssertEqual(ProjectSave.pollIntervalSeconds, 0.25)
    }
}

/// What the close and the reset are willing to call a dialog.
///
/// Measured live 2026-09-02: closing the sandbox project reported
/// `dialog_count: 1` for `texts: ["Sweeps"], buttons: [" "]` — a TRACK NAME
/// and a space-titled control — as an "UNKNOWN dialog grammar", on a close
/// that was completely clean and returned `verified: true`. An ordinary Logic
/// utility window read as an alert. Nothing is ever pressed on such a window
/// (recognition keys on the texts, the press keys on a real title), so the
/// only thing the phantom cost was truthfulness — in `dialogs`, in every
/// error message `describeVisibleDialogs` builds, and in `logic_reset_to`'s
/// `no_dialog_left_on_screen` check, which it would have failed.
final class VisibleDialogShapeTests: XCTestCase {

    /// The window that was actually misread, pinned.
    func testASpaceTitledButtonIsNotAButtonAnAlertOffers() {
        XCTAssertNil(ProjectReset.alertButtonTitle(" "))
    }

    func testAnEmptyTitleIsStillRejected() {
        XCTAssertNil(ProjectReset.alertButtonTitle(""))
    }

    func testTabsAndNewlinesAreBlankToo() {
        XCTAssertNil(ProjectReset.alertButtonTitle("\t"))
        XCTAssertNil(ProjectReset.alertButtonTitle("\n"))
        XCTAssertNil(ProjectReset.alertButtonTitle("  \t \n "))
    }

    /// Buttons are pressed by their EXACT title, so the original string comes
    /// back — never the trimmed one.
    func testARealButtonKeepsItsExactTitle() {
        XCTAssertEqual(ProjectReset.alertButtonTitle("Don’t Save"), "Don’t Save")
        XCTAssertEqual(ProjectReset.alertButtonTitle(" Save "), " Save ")
    }

    /// The whole misread, end to end at the pure level: after the blank button
    /// is dropped there is nothing left to offer, so the window is not a
    /// dialog.
    func testTheSweepsWindowIsNotAlertShaped() {
        let buttons = [" "].compactMap(ProjectReset.alertButtonTitle)
        XCTAssertFalse(ProjectReset.isAlertShaped(texts: ["Sweeps"], buttons: buttons))
    }

    /// And the alert this server exists to answer still is.
    func testTheSaveChangesAlertIsStillAlertShaped() {
        let buttons = ["Save", "Don’t Save", "Cancel"].compactMap(ProjectReset.alertButtonTitle)
        XCTAssertTrue(ProjectReset.isAlertShaped(
            texts: ["Do you want to save the changes made to the document “Song”?"],
            buttons: buttons
        ))
    }

    /// Both halves are required. A window that says nothing is not an alert,
    /// and neither is one that offers no way out.
    func testAnAlertNeedsBothTextAndAButton() {
        XCTAssertFalse(ProjectReset.isAlertShaped(texts: [], buttons: ["OK"]))
        XCTAssertFalse(ProjectReset.isAlertShaped(texts: ["Something"], buttons: []))
    }
}
