import XCTest
@testable import Logician

/// The pure halves of `logic_duplicate_project` and of the shared project
/// OPEN: the guards that run before anything is copied or closed, the
/// destination derivation, the path-identity predicate that decides whether an
/// open is PROVEN, the gate in front of the AppleScript read, and the account
/// the result gives of what happened to the original.
///
/// `logic_duplicate_project` had zero behavioural tests until 2026-09-01 and
/// is on the MUST-NOT-RUN-LIVE list — it writes a project copy to disk and
/// changes which project is open — so nothing else will ever exercise it. A
/// tool that cannot be run live is precisely the one whose pure half has to be
/// unit-tested, and every defect the code triage found in it
/// (`Logician-archive/profiles/logic_duplicate_project.md` §5.1–§5.5) lives
/// here, in logic that needs no Logic Pro to check.
final class ProjectDuplicateTests: XCTestCase {

    /// The tuple `readOpenDocuments()` hands the guards.
    private func documents(
        _ entries: [(String, String?, Bool)]
    ) -> [(name: String, path: String?, modified: Bool)] {
        entries.map { (name: $0.0, path: $0.1, modified: $0.2) }
    }

    private let normalize = ProjectReset.normalizedTargetPath

    // MARK: - The open is proven by PATH, never by name (§5.1)

    /// The defect, pinned: the destination is `~/Desktop/Sandbox/Song.logicx`,
    /// the still-open original is `~/Music/Logic/Song.logicx`, and the two
    /// share a basename. The old predicate (`$0.name == expectedName`) matched
    /// the original on the first poll tick and answered `verified: true` for a
    /// copy Logic had not opened — so the agent's destructive changes landed
    /// in the user's project while the result said "sandbox".
    func testSameBasenameInAnotherDirectoryIsNotTheOpenedCopy() {
        let stillTheOriginal = documents([
            ("Song", "/Users/x/Music/Logic/Song.logicx", true)
        ])
        XCTAssertNil(ProjectOpen.openedDocument(
            in: stillTheOriginal,
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            normalize: normalize
        ))
        // And the name it would have matched on really is identical.
        XCTAssertEqual(
            stillTheOriginal[0].name,
            URL(fileURLWithPath: "/Users/x/Desktop/Sandbox/Song.logicx")
                .deletingPathExtension().lastPathComponent
        )
    }

    func testTheDocumentAtTheTargetPathIsTheProof() throws {
        let opened = try XCTUnwrap(ProjectOpen.openedDocument(
            in: documents([("Song", "/Users/x/Desktop/Sandbox/Song.logicx", true)]),
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            normalize: normalize
        ))
        XCTAssertEqual(opened.name, "Song")
        XCTAssertEqual(opened.path, "/Users/x/Desktop/Sandbox/Song.logicx")
    }

    /// A `.logicx` is a bundle DIRECTORY and Logic's AppleScript suite hands
    /// paths back decomposed, so the two spellings of the same project must
    /// compare equal or the poll would never terminate on a Swedish filename.
    func testTrailingSlashAndDecomposedUnicodeStillMatch() throws {
        let decomposed = "/Users/x/Music/Testla\u{30A}t Copy.logicx"
        let opened = try XCTUnwrap(ProjectOpen.openedDocument(
            in: documents([("Testlåt Copy", decomposed, false)]),
            targetPath: "/Users/x/Music/Testlåt Copy.logicx/",
            normalize: normalize
        ))
        XCTAssertEqual(opened.name, "Testlåt Copy")
    }

    /// A never-saved document has no path, and "no path" is not a match for
    /// anything — least of all for an empty target.
    func testAPathlessDocumentNeverMatches() {
        XCTAssertNil(ProjectOpen.openedDocument(
            in: documents([("Untitled", nil, true)]),
            targetPath: "/Users/x/Music/Untitled.logicx",
            normalize: normalize
        ))
    }

    func testTheTargetIsFoundAmongSeveralOpenDocuments() throws {
        let opened = try XCTUnwrap(ProjectOpen.openedDocument(
            in: documents([
                ("Other", "/Users/x/Music/Other.logicx", false),
                ("Song", "/Users/x/Desktop/Sandbox/Song.logicx", true)
            ]),
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            normalize: normalize
        ))
        XCTAssertEqual(opened.path, "/Users/x/Desktop/Sandbox/Song.logicx")
    }

    // MARK: - When the AppleScript read may be spent (§5.2)

    /// The deadlock: Logic's AppleScript suite blocks while a modal is up, for
    /// ~120 s, and this is the poll that EXPECTS the save-changes prompt. A
    /// read started under the modal takes the loop that would answer it with
    /// it.
    func testNoDocumentListReadWhileARecognisedAlertIsUp() {
        XCTAssertFalse(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            recognisedAlertOnScreen: true,
            normalize: normalize
        ))
    }

    /// The outgoing project is still the frontmost document: the switch has
    /// not happened, the answer would be "no", and the prompt is about to
    /// appear over exactly this window.
    func testNoDocumentListReadWhileAnotherProjectIsStillFrontmost() {
        XCTAssertFalse(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: "/Users/x/Music/Logic/Song.logicx",
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            recognisedAlertOnScreen: false,
            normalize: normalize
        ))
    }

    func testTheReadIsSpentOnceTheTargetIsFrontmost() {
        XCTAssertTrue(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: "/Users/x/Desktop/Sandbox/Song.logicx/",
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            recognisedAlertOnScreen: false,
            normalize: normalize
        ))
    }

    /// The AX document path SETTLES after the open rather than arriving with
    /// it (measured 2026-08-28: the document list held the project while the
    /// window still published no AXDocument), so "no AXDocument yet" must
    /// leave the read available — treating it as "do not ask" would trade the
    /// loop's answer for a 30 s timeout.
    func testNoDocumentWindowYetStillAllowsTheRead() {
        XCTAssertTrue(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: nil,
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            recognisedAlertOnScreen: false,
            normalize: normalize
        ))
        // …but never under a modal, whatever the windows say.
        XCTAssertFalse(ProjectOpen.mayAskDocumentList(
            frontmostDocumentPath: nil,
            targetPath: "/Users/x/Desktop/Sandbox/Song.logicx",
            recognisedAlertOnScreen: true,
            normalize: normalize
        ))
    }

    /// The poll looks before it waits, and paces at the close's measured
    /// 200 ms rather than the 500 ms blind sleep it replaced.
    func testThePollReusesTheClosePacing() {
        XCTAssertEqual(ProjectOpen.pollIntervalSeconds, 0.2, accuracy: 0.0001)
    }

    // MARK: - The source guard

    func testTheSingleOpenPathedDocumentIsTheSource() throws {
        let source = try ProjectDuplicate.source(
            in: documents([("Testlåt Copy", "/Music/Testlåt Copy.logicx", true)])
        )
        XCTAssertEqual(source, ProjectDuplicate.Source(
            name: "Testlåt Copy", path: "/Music/Testlåt Copy.logicx", modified: true
        ))
    }

    func testNothingOpenIsRefusedAndSaysNothingWasCopied() {
        XCTAssertThrowsError(try ProjectDuplicate.source(in: [])) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("none"), message)
            XCTAssertTrue(message.contains("NOTHING was copied"), message)
        }
    }

    func testTwoOpenProjectsAreRefusedByName() {
        XCTAssertThrowsError(try ProjectDuplicate.source(in: documents([
            ("One", "/Music/One.logicx", false),
            ("Two", "/Music/Two.logicx", false)
        ]))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("One, Two"), message)
        }
    }

    /// A project that lives nowhere but in Logic's memory has nothing to copy,
    /// and the refusal names the tool that gives it a path.
    func testANeverSavedProjectIsRefusedWithTheWayForward() {
        XCTAssertThrowsError(try ProjectDuplicate.source(
            in: documents([("Untitled", nil, true)])
        )) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("never been saved"), message)
            XCTAssertTrue(message.contains("logic_save_project"), message)
        }
    }

    // MARK: - Where the copy goes

    func testTheDefaultDestinationSitsBesideTheOriginal() throws {
        let destination = try ProjectDuplicate.destination(
            forSource: "/Users/x/Music/Logic/Testlåt.logicx", requested: nil
        )
        XCTAssertEqual(destination.path, "/Users/x/Music/Logic/Testlåt Copy.logicx")
    }

    /// Duplicating a copy is the sandbox agent's second call, and the name it
    /// gets is the one the profile measured against.
    func testDuplicatingACopyStacksTheSuffix() throws {
        let destination = try ProjectDuplicate.destination(
            forSource: "/Users/x/Music/Logic/Testlåt Copy.logicx", requested: nil
        )
        XCTAssertEqual(destination.path, "/Users/x/Music/Logic/Testlåt Copy Copy.logicx")
    }

    func testAGivenDestinationIsTildeExpandedAndSlashTrimmed() throws {
        let destination = try ProjectDuplicate.destination(
            forSource: "/Users/x/Music/Logic/Song.logicx", requested: "~/Desktop/Sandbox/Song.logicx/"
        )
        XCTAssertEqual(
            destination.path,
            NSHomeDirectory() + "/Desktop/Sandbox/Song.logicx"
        )
        XCTAssertFalse(destination.path.contains("~"))
    }

    func testADestinationThatIsNotALogicxIsRefusedBeforeAnythingIsCopied() {
        for bad in ["~/Desktop/Song", "~/Desktop/Song.logic", "~/Desktop/Song.zip"] {
            XCTAssertThrowsError(try ProjectDuplicate.destination(
                forSource: "/Music/Song.logicx", requested: bad
            ), bad) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(".logicx"), message)
                XCTAssertTrue(message.contains("NOTHING was copied"), message)
            }
        }
    }

    /// The caller who meets this most often is the one whose PREVIOUS call
    /// made the copy and failed to open it, so the refusal has to offer more
    /// than "no".
    func testTheExistsRefusalNamesBothWaysForward() {
        let message = ProjectDuplicate.destinationExistsRefusal(
            path: "/Users/x/Music/Logic/Song Copy.logicx"
        ).localizedDescription
        XCTAssertTrue(message.contains("/Users/x/Music/Logic/Song Copy.logicx"), message)
        XCTAssertTrue(message.contains("destination_path"), message)
        XCTAssertTrue(message.contains("logic_open_project"), message)
    }

    // MARK: - Refuse before the copy, not after it (§5.3)

    /// The whole defect in one assertion: `if_current_modified: 'fail'` is
    /// schema-legal and now the DEFAULT, and against a modified original it
    /// used to throw from inside `openProject` — after the copy was on disk,
    /// with the result carrying the copy's path discarded, so the retry hit
    /// "already exists" on a path nobody had been told about.
    func testAModifiedOriginalIsRefusedBeforeTheCopyIsMade() throws {
        let refusal = try XCTUnwrap(ProjectDuplicate.openDecisionRefusal(
            openCopy: true, ifCurrentModified: "fail",
            sourceName: "Testlåt Copy", modifiedAtOpen: true, saveFailure: nil
        ))
        let message = refusal.localizedDescription
        XCTAssertTrue(message.contains("NOTHING was copied"), message)
        XCTAssertTrue(message.contains("save_first: true"), message)
        XCTAssertTrue(message.contains("'save'"), message)
        XCTAssertTrue(message.contains("'dont_save'"), message)
        XCTAssertTrue(message.contains("open_copy: false"), message)
        // Logic flags a project modified the moment it opens, so the refusal
        // has to say which answer covers a project nobody edited.
        XCTAssertTrue(message.contains("modified as soon as it is opened"), message)
    }

    func testAnExplicitDecisionIsNotRefused() {
        for decision in ["save", "dont_save"] {
            XCTAssertNil(ProjectDuplicate.openDecisionRefusal(
                openCopy: true, ifCurrentModified: decision,
                sourceName: "Song", modifiedAtOpen: true, saveFailure: nil
            ), decision)
        }
    }

    /// Nothing is being closed, so there is no decision to make.
    func testNoDecisionIsNeededWhenTheCopyIsNotOpened() {
        XCTAssertNil(ProjectDuplicate.openDecisionRefusal(
            openCopy: false, ifCurrentModified: "fail",
            sourceName: "Song", modifiedAtOpen: true, saveFailure: nil
        ))
    }

    /// A successful `save_first` clears the flag, so Logic never asks and the
    /// guide's recommended call is not refused by the new default.
    func testSaveFirstMakesTheRecommendedCallGoThroughOnTheFailDefault() {
        XCTAssertNil(ProjectDuplicate.openDecisionRefusal(
            openCopy: true, ifCurrentModified: "fail",
            sourceName: "Song", modifiedAtOpen: false, saveFailure: nil
        ))
    }

    /// A `save_first` that did NOT land leaves the project modified, and the
    /// refusal that follows must say why it is being asked at all.
    func testAFailedSaveFirstIsNamedInTheRefusal() throws {
        let refusal = try XCTUnwrap(ProjectDuplicate.openDecisionRefusal(
            openCopy: true, ifCurrentModified: "fail", sourceName: "Song",
            modifiedAtOpen: true, saveFailure: "failed (the key command is not bound)"
        ))
        XCTAssertTrue(
            refusal.localizedDescription.contains("the key command is not bound"),
            refusal.localizedDescription
        )
    }

    func testTheOpenFailureCarriesTheCopysPathAndSaysTheCopyWasMade() {
        let message = ProjectDuplicate.copyMadeButNotOpened(
            copyPath: "/Users/x/Music/Logic/Song Copy.logicx",
            savedBeforeCopy: false,
            underlying: LogicianError.verificationFailed(
                requested: "the open", actual: "not there within 30 s", restored: false
            )
        ).localizedDescription
        XCTAssertTrue(message.contains("/Users/x/Music/Logic/Song Copy.logicx"), message)
        XCTAssertTrue(message.contains("THE COPY WAS MADE AND THE OPEN WAS NOT"), message)
        XCTAssertTrue(message.contains("already exists"), message)
        XCTAssertTrue(message.contains("not there within 30 s"), message)
    }

    func testTheOpenFailureSaysWhatTheOrphanedCopyContains() {
        let saved = ProjectDuplicate.copyMadeButNotOpened(
            copyPath: "/c.logicx", savedBeforeCopy: true,
            underlying: LogicianError.writeFailed("x")
        ).localizedDescription
        XCTAssertTrue(saved.contains("save_first saved into it"), saved)
        let unsaved = ProjectDuplicate.copyMadeButNotOpened(
            copyPath: "/c.logicx", savedBeforeCopy: false,
            underlying: LogicianError.writeFailed("x")
        ).localizedDescription
        XCTAssertTrue(unsaved.contains("last saved disk state"), unsaved)
    }

    // MARK: - What actually happened to the original (§5.5)

    /// The old note said "the original is untouched on disk" unconditionally,
    /// including on the default path that had just committed the user's
    /// in-progress edits to it.
    func testAnOriginalSavedByThePromptIsReportedAsWritten() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: true, savedBeforeCopy: false, saveChangesAnswer: .saved
        )
        XCTAssertTrue(outcome.writtenToDisk)
        XCTAssertFalse(outcome.unsavedChangesDiscarded)
        XCTAssertTrue(outcome.note.contains("WRITTEN TO DISK"), outcome.note)
        XCTAssertTrue(outcome.note.contains("NOT in the copy"), outcome.note)
        XCTAssertFalse(outcome.note.contains("untouched"), outcome.note)
    }

    /// `save_first` is a write to the user's project too — that is how their
    /// unsaved work reaches the copy — and the guide's recommended call is
    /// exactly this one.
    func testSaveFirstIsAlsoAWriteToTheOriginal() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: true, savedBeforeCopy: true, saveChangesAnswer: nil
        )
        XCTAssertTrue(outcome.writtenToDisk)
        XCTAssertTrue(outcome.note.contains("save_first"), outcome.note)
        XCTAssertNil(outcome.warning)
    }

    /// Discarding leaves the file on disk alone but destroys work that is in
    /// neither the original nor the copy — the loudest thing this result can
    /// say, so it says it in the warning as well as the note.
    func testDiscardedChangesAreReportedAsALoss() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: true, savedBeforeCopy: false, saveChangesAnswer: .discarded
        )
        XCTAssertFalse(outcome.writtenToDisk)
        XCTAssertTrue(outcome.unsavedChangesDiscarded)
        XCTAssertTrue(outcome.note.contains("DISCARDED"), outcome.note)
        let warning = outcome.warning ?? ""
        XCTAssertTrue(warning.contains("DISCARDED"), warning)
        XCTAssertTrue(warning.contains("save_first: true"), warning)
    }

    /// The clean case, and the only one where "untouched" was ever true: no
    /// prompt appeared, so nothing was written and nothing was lost.
    func testACleanOriginalIsClosedAndUnchanged() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: true, savedBeforeCopy: false, saveChangesAnswer: nil
        )
        XCTAssertFalse(outcome.writtenToDisk)
        XCTAssertFalse(outcome.unsavedChangesDiscarded)
        XCTAssertTrue(outcome.note.contains("unchanged on disk"), outcome.note)
        XCTAssertNil(outcome.warning)
    }

    func testWithoutOpenCopyTheOriginalStaysOpen() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: false, savedBeforeCopy: false, saveChangesAnswer: nil
        )
        XCTAssertFalse(outcome.writtenToDisk)
        XCTAssertTrue(outcome.note.contains("STILL THE OPEN PROJECT"), outcome.note)
        XCTAssertTrue(outcome.note.contains("logic_open_project"), outcome.note)
    }

    func testWithoutOpenCopySaveFirstIsStillAWrite() {
        let outcome = ProjectDuplicate.originalOutcome(
            openedCopy: false, savedBeforeCopy: true, saveChangesAnswer: nil
        )
        XCTAssertTrue(outcome.writtenToDisk)
        XCTAssertTrue(outcome.note.contains("STILL THE OPEN PROJECT"), outcome.note)
    }

    // MARK: - What the copy contains

    func testTheStaleCopyWarningFiresOnlyWhenTheCopyLacksTheChanges() {
        XCTAssertNotNil(ProjectDuplicate.staleCopyWarning(modified: true, saveFirst: false))
        XCTAssertNil(ProjectDuplicate.staleCopyWarning(modified: true, saveFirst: true))
        XCTAssertNil(ProjectDuplicate.staleCopyWarning(modified: false, saveFirst: false))
    }

    func testTheStaleCopyWarningNamesTheFix() throws {
        let warning = try XCTUnwrap(
            ProjectDuplicate.staleCopyWarning(modified: true, saveFirst: false)
        )
        XCTAssertTrue(warning.contains("save_first: true"), warning)
    }

    /// The two warnings can be true at once — a save that did not land AND a
    /// modified document — and the second used to overwrite the first.
    func testBothWarningsSurviveEachOther() {
        var result: [String: Any] = [:]
        appendWarning("save_first failed (the key command is not bound)", to: &result)
        appendWarning(
            ProjectDuplicate.staleCopyWarning(modified: true, saveFirst: false), to: &result
        )
        let warning = (result["warning"] as? String) ?? ""
        XCTAssertTrue(warning.contains("save_first failed"), warning)
        XCTAssertTrue(warning.contains("NOT in the copy"), warning)
    }
}
