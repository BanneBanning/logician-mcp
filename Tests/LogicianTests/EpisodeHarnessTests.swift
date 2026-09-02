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
            buttons: ["Save", "Cancel", "Don’t Save"],
            discardingChanges: true
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
            buttons: ["Save", "Cancel", "Don't Save"],
            discardingChanges: true
        )
        XCTAssertEqual(answer?.button, "Don't Save")
    }

    func testRecoveryPromptIsAnsweredWithSaved() {
        let answer = ProjectReset.answer(
            forTexts: ["There is an auto-saved version of this project.", "Which one do you want to open?"],
            buttons: ["Auto-saved", "Saved", "Cancel"],
            discardingChanges: true
        )
        XCTAssertEqual(answer?.button, "Saved")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            ProjectReset.answer(
                forTexts: ["DO YOU WANT TO SAVE THE CHANGES?"], buttons: ["Don’t Save"],
                discardingChanges: true
            )?.button,
            "Don’t Save"
        )
    }

    func testUnknownDialogIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(
            forTexts: ["Delete Track and Regions?"],
            buttons: ["Delete", "Keep", "Cancel"],
            discardingChanges: true
        ))
    }

    /// A recognised dialog whose answering button is NOT on screen must come
    /// back nil rather than fall through to some other button. This is the
    /// case that would otherwise press `Save` on a tool whose contract is
    /// discarding.
    func testKnownDialogWithoutItsButtonIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(
            forTexts: ["Do you want to save the changes?"],
            buttons: ["Save", "Cancel"],
            discardingChanges: true
        ))
    }

    func testEmptyDialogIsNotAnswered() {
        XCTAssertNil(ProjectReset.answer(forTexts: [], buttons: [], discardingChanges: true))
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

    // MARK: - The OTHER half of completeness: sections that read, and are short

    /// The reference project's shape, live on all 12 snapshot calls of the
    /// 2026-09-02 profile: nothing threw, and ten track rows plus every region
    /// on them were missing from a document that called itself complete.
    private var collapsedStackTracks: [String: Any] {
        [
            "visible_tracks": 19,
            "partial": true,
            "completeness": "partial",
            "partial_evidence": [
                "track number(s) 10, 11 fall inside the rendered range and are not listed;"
                    + " they follow collapsed track stack 9 “Drums” immediately"
            ],
            "missing_track_numbers": [10, 11]
        ]
    }

    func testASectionThatReportsItselfPartialMakesTheSnapshotIncomplete() {
        var builder = SnapshotBuilder()
        builder.capture(.tracks) { self.collapsedStackTracks }
        XCTAssertTrue(builder.sortedUnavailable.isEmpty, "nothing threw")
        XCTAssertFalse(builder.complete, "19 of 21 track rows is not the whole picture")
        XCTAssertEqual(builder.caveats.partialSections, ["tracks"])
        XCTAssertEqual(builder.caveats.missingTrackNumbers, [10, 11])
    }

    /// The two conditions are different and BOTH stay visible: one section that
    /// read nothing and one that read what it could and knows it is short.
    func testThrownAndPartialSectionsAreReportedSeparately() {
        var builder = SnapshotBuilder()
        builder.capture(.markers) { throw LogicianError.logicNotRunning }
        builder.capture(.tracks) { self.collapsedStackTracks }
        XCTAssertFalse(builder.complete)
        XCTAssertEqual(builder.sortedUnavailable, ["markers"])
        XCTAssertEqual(builder.caveats.partialSections, ["tracks"])
    }

    /// A section that threw is named ONCE, in `unavailable_sections`. It has no
    /// payload to be partial with, and counting it twice would make one failure
    /// look like two.
    func testAThrownSectionIsNotAlsoCountedAsPartial() {
        var builder = SnapshotBuilder()
        builder.capture(.regions) { throw LogicianError.logicNotRunning }
        XCTAssertEqual(builder.caveats.partialSections, [])
        XCTAssertEqual(builder.sortedUnavailable, ["regions"])
    }

    /// Neither condition: a snapshot of a fully rendered project still says
    /// complete. Without this the fix would just be a louder way of never
    /// answering yes.
    func testAWholeSnapshotIsStillComplete() {
        var builder = SnapshotBuilder()
        builder.capture(.tracks) {
            ["visible_tracks": 19, "partial": false, "completeness": "unknown",
             "partial_evidence": [String]()]
        }
        builder.capture(.regions) { ["partial": false, "coverage_checked": "row_numbering"] }
        builder.capture(.markers) { ["marker_count": 4] }
        XCTAssertTrue(builder.complete)
        XCTAssertTrue(builder.caveats.partialSections.isEmpty)
        XCTAssertTrue(builder.caveats.missingTrackNumbers.isEmpty)
    }

    /// Rows Logic counted and did not draw are the List Editors' own way of
    /// saying "short", and they carry a count rather than a `partial` flag.
    func testUnreadableListRowsCountAsPartial() {
        var builder = SnapshotBuilder()
        builder.capture(.markers) {
            ["marker_count": 6, "markers_read": 4, "unreadable_rows": 2,
             "warning": "2 row(s) are published and not drawn"]
        }
        XCTAssertFalse(builder.complete)
        XCTAssertEqual(builder.caveats.partialSections, ["markers"])
        XCTAssertEqual(
            builder.caveats.partialEvidence, ["markers: 2 row(s) are published and not drawn"]
        )
    }

    /// `max_tracks` makes the chain sections a SAMPLE, and they say so — the
    /// third shape of "there is more of this project than I am showing you".
    func testATruncatedChainWalkCountsAsPartial() {
        var builder = SnapshotBuilder()
        builder.record(
            .inserts,
            payload: ["walked": 8, "truncated": true, "addressable_tracks": 19,
                      "warning": "Only the first 8 of 19 addressable tracks were walked"],
            milliseconds: 9000
        )
        XCTAssertFalse(builder.complete)
        XCTAssertEqual(builder.caveats.partialSections, ["inserts"])
    }

    /// A section claiming `partial: true` with no sentence still counts, and
    /// still says something: silence must not read as "not partial after all".
    func testPartialWithoutEvidenceStillCountsAndSaysSo() {
        let audit = SnapshotCaveats.audit(sections: ["tracks": ["partial": true]])
        XCTAssertEqual(audit.partialSections, ["tracks"])
        XCTAssertEqual(audit.partialEvidence.count, 1)
        XCTAssertTrue(audit.partialEvidence[0].contains("without an evidence sentence"))
    }

    func testPartialSectionsAndEvidenceAreSortedForACleanDiff() {
        let audit = SnapshotCaveats.audit(sections: [
            "tracks": ["partial": true, "partial_evidence": ["t"],
                       "missing_track_numbers": [12, 3]],
            "regions": ["partial": true, "partial_evidence": ["r"],
                        "missing_track_numbers": [3]],
            "markers": ["marker_count": 4]
        ])
        XCTAssertEqual(audit.partialSections, ["regions", "tracks"])
        XCTAssertEqual(audit.partialEvidence, ["regions: r", "tracks: t"])
        XCTAssertEqual(audit.missingTrackNumbers, [3, 12])
    }

    // MARK: - The cache caveat, promoted

    func testACachedSectionIsNamedAndItsCaveatIsCarriedUp() {
        let audit = SnapshotCaveats.audit(sections: [
            "meter_map": [
                "read": true, "read_route": "signature_list_cache",
                "warning": MeterKnowledge.cacheWarning
            ],
            "tempo_map": ["read_route": "tempo_list", "event_count": 2]
        ])
        XCTAssertEqual(audit.cachedSections, ["meter_map"])
        XCTAssertEqual(audit.cacheCaveats.count, 1)
        XCTAssertTrue(
            audit.cacheCaveats[0].hasPrefix("meter_map (read_route signature_list_cache)")
        )
        XCTAssertTrue(audit.cacheCaveats[0].contains("SERVED FROM CACHE, UNVERIFIED"))
    }

    /// Both map caches, both promoted, in a stable order.
    func testEveryCacheRouteIsRecognisedByItsSuffix() {
        let audit = SnapshotCaveats.audit(sections: [
            "tempo_map": ["read_route": "tempo_list_cache", "warning": MCPServer.tempoCacheWarning],
            "meter_map": ["read_route": "signature_list_cache", "warning": "cached"]
        ])
        XCTAssertEqual(audit.cachedSections, ["meter_map", "tempo_map"])
    }

    /// A cache route with no caveat of its own is still reported as one: the
    /// route is the fact, the sentence is the courtesy.
    func testACachedSectionWithoutAWarningStillGetsOne() {
        let audit = SnapshotCaveats.audit(
            sections: ["tempo_map": ["read_route": "tempo_list_cache"]]
        )
        XCTAssertEqual(audit.cachedSections, ["tempo_map"])
        XCTAssertTrue(audit.cacheCaveats[0].contains("SERVED FROM CACHE"))
    }

    /// Cache and completeness are INDEPENDENT: a cached map does not make the
    /// document short of a section, and `complete` must not claim it does.
    func testACachedSectionDoesNotMakeTheSnapshotIncomplete() {
        var builder = SnapshotBuilder()
        builder.capture(.meterMap) { ["read": true, "read_route": "signature_list_cache"] }
        XCTAssertTrue(builder.complete)
        XCTAssertEqual(builder.caveats.cachedSections, ["meter_map"])
    }

    /// The words the snapshot's `tempo_map` section now carries are
    /// logic_tempo_events' own — one constant, so the two cannot drift.
    func testTempoEventsPayloadAndTheSnapshotSectionShareTheCacheWording() throws {
        let map = try XCTUnwrap(
            TempoMap(events: [TempoEvent(bar: 1, bpm: 120)], source: .tempoList)
        )
        let cached = MCPServer.tempoEventsListPayload(map: map, liveCrossChecked: false)
        XCTAssertEqual(cached["read_route"] as? String, "tempo_list_cache")
        XCTAssertEqual(cached["warning"] as? String, MCPServer.tempoCacheWarning)
        XCTAssertEqual(cached["verified"] as? Bool, false)
    }

    // MARK: - One pane cycle per call

    /// The handler runs the List Editors sections inside ONE pane hold, which
    /// is only correct while they are contiguous in the emission order — and
    /// only safe while `tracks` and `regions` come AFTER the pane is closed
    /// again (an open pane shrinks the Tracks viewport those two read).
    func testTheListEditorSectionsAreContiguousAndPrecedeTheTrackWalks() {
        for scope in SnapshotScope.allCases {
            let positions = scope.sections.enumerated()
                .filter { SnapshotSection.listEditorTabs.contains($0.element) }
                .map(\.offset)
            XCTAssertEqual(positions.count, 3, scope.rawValue)
            XCTAssertEqual(positions, Array(positions[0]...positions[2]), scope.rawValue)
            for late in [SnapshotSection.tracks, .regions] {
                let index = scope.sections.firstIndex(of: late)
                XCTAssertNotNil(index, scope.rawValue)
                XCTAssertGreaterThan(index ?? -1, positions[2], scope.rawValue)
            }
        }
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
        XCTAssertTrue(text.localizedCaseInsensitiveContains("no such file"), text)
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
