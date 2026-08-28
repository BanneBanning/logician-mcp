import XCTest
@testable import Logician

/// The pure halves of the two eval-harness tools: `logic_reset_to`'s dialog
/// answer table, path handling and verification verdict, and
/// `logic_project_snapshot`'s scope/section model and completeness rule.
///
/// None of this needs Logic Pro, and all of it is the part that must not be
/// wrong: a dialog table that matches too loosely presses an unmeasured
/// button in an unattended reset, and a completeness rule that lets a failed
/// reader vanish turns "the Marker List did not open" into "this project has
/// no markers" in every eval that diffs the document.
final class EpisodeHarnessTests: XCTestCase {

    // MARK: - The dialog answer table

    func testSaveChangesPromptIsAnsweredWithDontSave() {
        let answer = ProjectReset.answer(
            forTexts: ["Do you want to save the changes made to the document “Testlåt Copy”?",
                       "Your changes will be lost if you don’t save them."],
            buttons: ["Save", "Cancel", "Don’t Save"]
        )
        XCTAssertEqual(answer?.button, "Don’t Save")
        XCTAssertTrue(answer?.effect.contains("discarded") == true)
    }

    /// Logic spells it with U+2019, but the straight apostrophe is accepted so
    /// an OS or localization change of the glyph does not turn a known dialog
    /// into an unknown one (which would stall the reset rather than break it,
    /// but stalling is still the wrong answer to a dialog we understand).
    func testSaveChangesPromptAcceptsAStraightApostrophe() {
        let answer = ProjectReset.answer(
            forTexts: ["Do you want to save the changes made to this document?"],
            buttons: ["Save", "Cancel", "Don't Save"]
        )
        XCTAssertEqual(answer?.button, "Don't Save")
    }

    func testRecoveryPromptIsAnsweredWithSaved() {
        let answer = ProjectReset.answer(
            forTexts: ["There is an auto-saved version of this project.", "Which one do you want to open?"],
            buttons: ["Auto-saved", "Saved", "Cancel"]
        )
        XCTAssertEqual(answer?.button, "Saved")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            ProjectReset.answer(
                forTexts: ["DO YOU WANT TO SAVE THE CHANGES?"], buttons: ["Don’t Save"]
            )?.button,
            "Don’t Save"
        )
    }

    func testUnknownDialogIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(
            forTexts: ["Delete Track and Regions?"],
            buttons: ["Delete", "Keep", "Cancel"]
        ))
    }

    /// A recognised dialog whose answering button is NOT on screen must come
    /// back nil rather than fall through to some other button. This is the
    /// case that would otherwise press `Save` on a tool whose contract is
    /// discarding.
    func testKnownDialogWithoutItsButtonIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(
            forTexts: ["Do you want to save the changes?"],
            buttons: ["Save", "Cancel"]
        ))
    }

    func testEmptyDialogIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(forTexts: [], buttons: []))
    }

    // MARK: - The target path

    func testTargetPathExpandsTildeAndTrimsTrailingSlash() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            ProjectReset.normalizedTargetPath("~/Music/Logic/Song.logicx/"),
            home + "/Music/Logic/Song.logicx"
        )
    }

    func testTargetPathLeavesAPlainAbsolutePathAlone() {
        XCTAssertEqual(
            ProjectReset.normalizedTargetPath("/Users/x/Song.logicx"),
            "/Users/x/Song.logicx"
        )
    }

    /// A `.logicx` is a bundle DIRECTORY, so several trailing slashes are a
    /// realistic thing to be handed by tab completion — and the comparison
    /// against Logic's own reported path is exact.
    func testTargetPathTrimsRepeatedTrailingSlashes() {
        XCTAssertEqual(ProjectReset.normalizedTargetPath("/a/b.logicx///"), "/a/b.logicx")
        XCTAssertEqual(ProjectReset.normalizedTargetPath("/"), "/")
    }

    func testTargetPathPrecomposesUnicode() {
        // "Testlåt" decomposed (a + combining diaeresis) is what the
        // filesystem and AppleScript hand back; clients send it precomposed.
        let decomposed = "/Users/x/Testla\u{30A}t.logicx"
        XCTAssertEqual(
            ProjectReset.normalizedTargetPath(decomposed),
            "/Users/x/Testl\u{E5}t.logicx"
        )
    }

    // MARK: - The verification verdict

    func testVerificationIsTheAndOfEveryCheck() {
        let checks = [
            ProjectReset.Check(name: "a", passed: true, detail: "ok"),
            ProjectReset.Check(name: "b", passed: true, detail: "ok")
        ]
        let verdict = ProjectReset.verification(checks)
        XCTAssertTrue(verdict.verified)
        XCTAssertTrue(verdict.failures.isEmpty)
        XCTAssertEqual(verdict.payload.count, 2)
        XCTAssertEqual(verdict.payload.first?["check"] as? String, "a")
        XCTAssertEqual(verdict.payload.first?["passed"] as? Bool, true)
    }

    /// One failed check sinks the whole verdict. A reset that opened the right
    /// file but could not confirm the document is clean has NOT established a
    /// known state, and an eval that branched on a `true` with a caveat buried
    /// in a list would run its episode against unknown state.
    func testOneFailedCheckSinksTheVerdictAndIsNamed() {
        let checks = [
            ProjectReset.Check(name: "frontmost_document_is_target", passed: true, detail: "match"),
            ProjectReset.Check(name: "document_is_unmodified", passed: false, detail: "already modified")
        ]
        let verdict = ProjectReset.verification(checks)
        XCTAssertFalse(verdict.verified)
        XCTAssertEqual(verdict.failures, ["document_is_unmodified: already modified"])
    }

    func testVerificationOfNothingIsVacuouslyTrue() {
        XCTAssertTrue(ProjectReset.verification([]).verified)
    }

    // MARK: - Snapshot scopes

    func testScopeDefaultsToStructure() throws {
        XCTAssertEqual(try SnapshotScope.parse(nil), .structure)
    }

    func testUnknownScopeIsRefusedWithTheRealList() {
        XCTAssertThrowsError(try SnapshotScope.parse("everything")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("structure"), message)
            XCTAssertTrue(message.contains("mix"), message)
            XCTAssertTrue(message.contains("full"), message)
            XCTAssertTrue(message.contains("Nothing was read"), message)
        }
    }

    func testStructureScopeIsAccessibilityOnly() throws {
        let sections = try SnapshotScope.parse("structure").sections
        XCTAssertFalse(sections.contains(.strips))
        XCTAssertFalse(sections.contains(.mixer))
        XCTAssertFalse(sections.contains(.inserts))
        XCTAssertFalse(sections.contains(.sends))
        XCTAssertEqual(sections, [.transport, .tempoMap, .meterMap, .markers, .tracks, .regions])
    }

    /// Each level is a strict superset of the one before it, prefix included:
    /// that is what lets a `full` snapshot be diffed against a `structure` one
    /// section by section instead of only as a whole.
    func testEachScopeIsAPrefixSupersetOfTheOneBefore() {
        let structure = SnapshotScope.structure.sections
        let mix = SnapshotScope.mix.sections
        let full = SnapshotScope.full.sections
        XCTAssertEqual(Array(mix.prefix(structure.count)), structure)
        XCTAssertEqual(Array(full.prefix(mix.count)), mix)
        XCTAssertEqual(full.count, mix.count + 2)
    }

    func testNoScopeEmitsASectionTwice() {
        for scope in SnapshotScope.allCases {
            let raws = scope.sections.map(\.rawValue)
            XCTAssertEqual(Set(raws).count, raws.count, scope.rawValue)
        }
    }

    func testUnavailableSectionsHaveExactlyOneAgreedKey() {
        let payload = SnapshotSection.unavailable("the Tempo tab published no rows")
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["unavailable"] as? String, "the Tempo tab published no rows")
    }

    // MARK: - The completeness contract

    func testCapturedSectionIsRecordedAndCounted() {
        var builder = SnapshotBuilder()
        builder.capture(.transport) { ["tempo": 120] }
        XCTAssertTrue(builder.complete)
        XCTAssertEqual((builder.sections["transport"] as? [String: Any])?["tempo"] as? Int, 120)
        XCTAssertNotNil(builder.timings["transport"])
    }

    /// A reader that threw becomes an `unavailable` section with the reason —
    /// never a missing key. This is the whole promise of the tool.
    func testFailedSectionBecomesUnavailableRatherThanMissing() {
        var builder = SnapshotBuilder()
        builder.capture(.markers) {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List", exposed: "the Marker tab published no table"
            )
        }
        XCTAssertFalse(builder.complete)
        let payload = builder.sections["markers"] as? [String: Any]
        XCTAssertNotNil(payload)
        let reason = payload?["unavailable"] as? String ?? ""
        XCTAssertTrue(reason.contains("Marker"), reason)
        XCTAssertEqual(builder.sortedUnavailable, ["markers"])
        // Timed even though it failed: an expensive failure is worth seeing.
        XCTAssertNotNil(builder.timings["markers"])
    }

    func testAFailedSectionDoesNotAbortTheOnesAfterIt() {
        var builder = SnapshotBuilder()
        builder.capture(.tempoMap) { throw LogicianError.logicNotRunning }
        builder.capture(.transport) { ["tempo": 90] }
        XCTAssertNotNil(builder.sections["tempo_map"])
        XCTAssertNotNil(builder.sections["transport"])
        XCTAssertEqual(builder.sortedUnavailable, ["tempo_map"])
    }

    func testUnavailableListIsSortedRegardlessOfWalkOrder() {
        var builder = SnapshotBuilder()
        builder.capture(.tracks) { throw LogicianError.logicNotRunning }
        builder.capture(.markers) { throw LogicianError.logicNotRunning }
        builder.capture(.meterMap) { throw LogicianError.logicNotRunning }
        XCTAssertEqual(builder.sortedUnavailable, ["markers", "meter_map", "tracks"])
    }

    /// The chain sections are timed by the caller (one walk feeds both), so
    /// `record` has to apply the same completeness rule `capture` does.
    func testPreTimedRecordHonoursTheSameUnavailableRule() {
        var builder = SnapshotBuilder()
        builder.record(.inserts, payload: ["tracks": []], milliseconds: 1200)
        builder.record(.sends, payload: ["unavailable": "no bridge"], milliseconds: 30)
        XCTAssertEqual(builder.timings["inserts"], 1200)
        XCTAssertEqual(builder.timings["sends"], 30)
        XCTAssertFalse(builder.complete)
        XCTAssertEqual(builder.sortedUnavailable, ["sends"])
    }

    func testAnEmptySnapshotIsComplete() {
        XCTAssertTrue(SnapshotBuilder().complete)
        XCTAssertTrue(SnapshotBuilder().sortedUnavailable.isEmpty)
    }

    // MARK: - The two tools as the registry advertises them

    func testResetToRequiresBothPathAndConfirmDiscard() throws {
        let server = MCPServer()
        let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_reset_to" })
        let required = try XCTUnwrap(tool.inputSchema["required"] as? [String])
        XCTAssertEqual(Set(required), ["path", "confirm_discard"])
        // The one tool whose contract IS discarding unsaved work says so in
        // bold, and is flagged destructive.
        XCTAssertTrue(tool.description.contains("**THIS TOOL DISCARDS"), tool.description)
        XCTAssertTrue(tool.annotations["destructiveHint"] as? Bool == true)
        XCTAssertFalse(tool.annotations["readOnlyHint"] as? Bool == true)
    }

    func testResetToRefusesWithoutConfirmDiscard() {
        let server = MCPServer()
        let result = server.callTool(
            name: "logic_reset_to", arguments: ["path": "/tmp/nope.logicx"]
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("confirm_discard"), text)
        XCTAssertTrue(text.contains("Nothing was closed"), text)
    }

    /// The existence check runs BEFORE Logic is touched, which is what makes a
    /// typo in the path cost nothing. Confirmed here by a path that cannot
    /// exist: the refusal must be about the file, not about Logic.
    func testResetToRefusesAMissingFileBeforeTouchingLogic() {
        let server = MCPServer()
        let result = server.callTool(
            name: "logic_reset_to",
            arguments: [
                "path": NSTemporaryDirectory() + "/definitely-not-here-\(UUID().uuidString).logicx",
                "confirm_discard": true
            ]
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("no such file"), text)
        XCTAssertTrue(text.contains("NOTHING was closed"), text)
    }

    func testResetToRefusesANonLogicxPath() {
        let server = MCPServer()
        let result = server.callTool(
            name: "logic_reset_to",
            arguments: ["path": "/tmp/song.wav", "confirm_discard": true]
        )
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains(".logicx"), text)
    }

    func testSnapshotScopeEnumInTheSchemaMatchesTheType() throws {
        let server = MCPServer()
        let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_project_snapshot" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let scope = try XCTUnwrap(properties["scope"] as? [String: Any])
        XCTAssertEqual(scope["enum"] as? [String], SnapshotScope.allCases.map(\.rawValue))
        // Nothing is required: the default scope is the cheap one.
        XCTAssertNil(tool.inputSchema["required"])
    }

    func testSnapshotIsNotAdvertisedAsReadOnly() throws {
        let server = MCPServer()
        let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_project_snapshot" })
        // It reads the PROJECT only, but it banks the control surface and
        // opens a List Editors pane — the same reason logic_mixer_snapshot is
        // not readOnly. Claiming readOnly here would invite auto-approval of a
        // call that moves the user's surface.
        XCTAssertEqual(tool.annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(tool.annotations["destructiveHint"] as? Bool, false)
        XCTAssertEqual(tool.annotations["idempotentHint"] as? Bool, true)
    }
}
