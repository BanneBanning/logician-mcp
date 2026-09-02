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

    // MARK: - The read the decision does not need

    /// The skip, stated: with the decision already made, the document list
    /// cannot change the outcome, so the 260–412 ms Apple Event that reads it
    /// is not spent (measured live 2026-09-02, 13% of a warm create).
    func testAnExplicitDecisionDoesNotNeedTheDocumentList() {
        XCTAssertFalse(ProjectOpen.needsCurrentDocumentList(ifCurrentModified: "save"))
        XCTAssertFalse(ProjectOpen.needsCurrentDocumentList(ifCurrentModified: "dont_save"))
    }

    /// `fail` is the default and the one decision the list actually decides —
    /// and where the read doubles as the early "the list will not answer"
    /// diagnosis. It stays.
    func testTheDefaultStillReadsTheDocumentList() {
        XCTAssertTrue(ProjectOpen.needsCurrentDocumentList(ifCurrentModified: "fail"))
    }

    /// Anything else is not a decision. A typo'd or empty value must fall to
    /// the refusing path, not skip the guard on its way past it.
    func testAnUnrecognisedValueIsNotAnExplicitDecision() {
        for value in ["", "dontsave", "dont save", "DONT_SAVE", "Save", "yes", "no", "true"] {
            XCTAssertTrue(
                ProjectOpen.needsCurrentDocumentList(ifCurrentModified: value),
                "'\(value)' is not one of the two explicit decisions"
            )
        }
    }

    /// The property the skip rests on, over every document list the guard can
    /// meet: when the read is skipped, the refusal it feeds would have been nil
    /// anyway. This is the test that fails if `currentModifiedRefusal` ever
    /// grows a fourth reason to refuse without teaching
    /// `needsCurrentDocumentList` about it.
    func testSkippingTheReadNeverSkipsARefusal() {
        let lists: [[(name: String, path: String?, modified: Bool)]] = [
            documents([]),
            documents([("Song", "/Users/x/Music/Logic/Song.logicx", true)]),
            documents([("Song", "/Users/x/Music/Logic/Song.logicx", false)]),
            documents([("Untitled", nil, true)]),
            documents([("New", "/Users/x/Desktop/New.logicx", true)]),
            documents([("A", "/Users/x/A.logicx", true), ("B", "/Users/x/B.logicx", true)])
        ]
        for decision in ["save", "dont_save"] where
            !ProjectOpen.needsCurrentDocumentList(ifCurrentModified: decision) {
            for list in lists {
                for creating in [true, false] {
                    XCTAssertNil(
                        refusal(current: list, ifCurrentModified: decision, creating: creating),
                        "'\(decision)' must never refuse, whatever the document list holds"
                    )
                }
            }
        }
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

/// The sheet an EMPTY project raises, and what the open is allowed to do
/// about it.
///
/// Measured live 2026-09-02 (`Logician-archive/profiles/logic_new_project.md`,
/// D-NP1): every successful `logic_new_project` returned `success: true,
/// verified: true` with Logic's "Create New Track" sheet standing over the
/// project it had just handed back. The tool never looked — `openProject`
/// answers the save-changes and recovery prompts and knew no third grammar —
/// so the next call in a fresh process met the sheet as an "UNKNOWN dialog
/// grammar", and `logic_reset_to` into an empty template would have failed its
/// own `no_dialog_left_on_screen` check on a reset that had worked.
///
/// The texts and buttons below are the ones the profiling pass actually read
/// off the sheet, verbatim.
final class CreateTrackSheetTests: XCTestCase {

    private let texts = [
        "Create New Track", "Details", "Audio Input:", "Audio Output:",
        "Number of tracks to create:"
    ]
    private let buttons = [
        "Device: (MacBook Pro-mikrofon) ", "Device: (Högtalare i MacBook Pro) ",
        "Create", "Cancel"
    ]

    // MARK: - What answers it

    /// The measurement that decided this, and the reason the two operations
    /// press different buttons: **Cancel does not dismiss the sheet, it
    /// abandons the project**. Live 2026-09-02, 3 times out of 3 (two creates
    /// and a reset into an empty template), a Cancel left `logic_list_windows`
    /// reporting NO windows, an empty document list and Logic's own "Choose a
    /// Project" chooser. So the OPEN presses Create — a project with a track in
    /// it beats no project at all — and the CLOSE presses Cancel, because the
    /// project is on its way out anyway.
    func testTheOpenAnswersTheSheetWithCreate() {
        XCTAssertEqual(
            ProjectReset.createTrackOpenAnswer(forTexts: texts, buttons: buttons)?.button,
            LogicUIStrings.Button.create
        )
    }

    func testTheCloseAnswersTheSheetWithCancel() {
        for discarding in [true, false] {
            XCTAssertEqual(
                ProjectReset.answer(
                    forTexts: texts, buttons: buttons, discardingChanges: discarding
                )?.button,
                LogicUIStrings.Button.cancel
            )
        }
    }

    /// The one track Create costs is the thing an agent must not have to
    /// discover for itself, so both the log entry and the result's note say it.
    func testTheEffectSaysATrackWasCreated() throws {
        let answer = try XCTUnwrap(
            ProjectReset.createTrackOpenAnswer(forTexts: texts, buttons: buttons)
        )
        XCTAssertTrue(answer.effect.contains("ONE track"), answer.effect)
        XCTAssertTrue(answer.effect.contains("logic_list_tracks"), answer.effect)

        let created = ProjectOpen.openNote(created: true, answeredCreateTrackSheet: true)
        XCTAssertTrue(created.contains("ONE track"), created)
        let opened = ProjectOpen.openNote(created: false, answeredCreateTrackSheet: true)
        XCTAssertTrue(opened.contains("ONE more track"), opened)
    }

    /// And when Logic raises no sheet, the note may not claim a track that does
    /// not exist.
    func testTheNoteWithoutASheetPromisesAnEmptyProject() {
        let created = ProjectOpen.openNote(created: true, answeredCreateTrackSheet: false)
        XCTAssertTrue(created.contains("EMPTY"), created)
        XCTAssertFalse(created.contains("ONE track"), created)
        XCTAssertEqual(ProjectOpen.openNote(created: false, answeredCreateTrackSheet: false),
                       "Opened.")
    }

    /// The marker is title-cased the way Logic spells it, so the match has to
    /// lowercase BOTH sides — the bug that would have made this whole table
    /// entry inert.
    func testTheMarkerMatchesWhateverCaseLogicUses() {
        XCTAssertNotNil(ProjectReset.createTrackOpenAnswer(
            forTexts: ["create new track"], buttons: ["Create", "Cancel"]
        ))
        XCTAssertNotNil(ProjectReset.createTrackOpenAnswer(
            forTexts: ["CREATE NEW TRACK"], buttons: ["Create", "Cancel"]
        ))
        XCTAssertTrue(ProjectReset.isCreateTrackSheet(texts: ["create new track"]))
        XCTAssertFalse(ProjectReset.isCreateTrackSheet(texts: ["Delete Track and Regions?"]))
    }

    /// A recognised sheet without the button we would press is left alone
    /// rather than answered with whatever else it offers — a Create-less sheet
    /// must never fall through to Cancel on the open path.
    func testASheetWithoutItsButtonIsNotAnswered() {
        XCTAssertNil(ProjectReset.createTrackOpenAnswer(
            forTexts: texts, buttons: ["Cancel", "Details"]
        ))
        XCTAssertNil(ProjectReset.answer(
            forTexts: texts, buttons: ["Create", "Details"], discardingChanges: true
        ))
    }

    /// …but it is still ON SCREEN, and the dismissal check has to say so, or a
    /// press that changed nothing would be reported as verified.
    func testASheetIsStillASheetWithoutItsButtons() {
        XCTAssertTrue(ProjectReset.isCreateTrackSheet(texts: texts))
    }

    /// The open answers the save-changes prompt itself, from the caller's
    /// explicit decision — this narrow matcher must never reach it.
    func testTheCreateTrackMatcherIgnoresEveryOtherAlert() {
        XCTAssertNil(ProjectReset.createTrackOpenAnswer(
            forTexts: ["Do you want to save the changes made to the document “Song”?"],
            buttons: ["Save", "Don’t Save", "Cancel"]
        ))
        XCTAssertNil(ProjectReset.createTrackOpenAnswer(
            forTexts: ["There is an auto-saved version of this project."],
            buttons: ["Auto-saved", "Saved", "Cancel"]
        ))
        XCTAssertNil(ProjectReset.createTrackOpenAnswer(forTexts: [], buttons: []))
        XCTAssertFalse(ProjectReset.isCreateTrackSheet(texts: []))
    }

    // MARK: - Known is not the same as blocking

    /// The distinction the fix turns on. The sheet is in the answer table, and
    /// it does NOT close the gate in front of the document-list read: measured
    /// live, that read returned in 264–400 ms with the sheet up, 6 creates out
    /// of 6. Were it treated as blocking, every empty-template open would time
    /// out at 30 s while Logic was answering perfectly well.
    func testTheSheetDoesNotBlockAppleEvents() {
        XCTAssertFalse(ProjectReset.blocksAppleScript(forTexts: texts, buttons: buttons))
    }

    /// And the two that really do block still do — that is the deadlock the
    /// gate exists for.
    func testTheSaveAndRecoveryPromptsStillBlock() {
        XCTAssertTrue(ProjectReset.blocksAppleScript(
            forTexts: ["Do you want to save the changes made to the document “Song”?"],
            buttons: ["Save", "Don’t Save", "Cancel"]
        ))
        XCTAssertTrue(ProjectReset.blocksAppleScript(
            forTexts: ["There is an auto-saved version of this project."],
            buttons: ["Auto-saved", "Saved", "Cancel"]
        ))
    }

    func testAnUnknownDialogIsNotTreatedAsBlocking() {
        XCTAssertFalse(ProjectReset.blocksAppleScript(
            forTexts: ["Delete Track and Regions?"], buttons: ["Delete", "Cancel"]
        ))
        XCTAssertFalse(ProjectReset.blocksAppleScript(forTexts: [], buttons: []))
    }

    /// A gate that is open is only useful if the poll then reads the list.
    func testTheOpenPollMayAskTheListWhileTheSheetIsUp() {
        XCTAssertTrue(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: "/Users/x/Desktop/New.logicx",
            targetPath: "/Users/x/Desktop/New.logicx",
            recognisedAlertOnScreen: ProjectReset.blocksAppleScript(
                forTexts: texts, buttons: buttons
            ),
            normalize: ProjectReset.normalizedTargetPath
        ))
    }

    // MARK: - Being seen at all

    /// `visibleDialogs` only reports alert-SHAPED windows, and only their
    /// non-blank buttons — the sheet has to survive both filters or none of
    /// the above ever runs. Logic's device buttons carry a trailing space.
    func testTheSheetIsAlertShapedAsLogicPublishesIt() {
        let offered = buttons.compactMap(ProjectReset.alertButtonTitle)
        XCTAssertEqual(offered.count, buttons.count)
        XCTAssertTrue(ProjectReset.isAlertShaped(texts: texts, buttons: offered))
        XCTAssertEqual(
            ProjectReset.createTrackOpenAnswer(forTexts: texts, buttons: offered)?.button, "Create"
        )
    }

    // MARK: - The budgets

    /// Paid only when the sheet has not appeared yet: on this Logic it is
    /// already standing when the read that proves the open returns. Small on
    /// purpose — a Logic that stops prompting must cost a create a LOOK, not a
    /// wait.
    func testTheSheetBudgetIsSmallEnoughToBeWrongAbout() {
        XCTAssertEqual(ProjectOpen.createTrackSheetBudgetSeconds, 1.5)
        XCTAssertEqual(ProjectOpen.createTrackSheetDismissalSeconds, 1.0)
        XCTAssertLessThanOrEqual(
            ProjectOpen.createTrackSheetDismissalSeconds,
            ProjectOpen.createTrackSheetBudgetSeconds
        )
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
