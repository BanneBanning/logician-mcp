import XCTest

@testable import Logician

/// The three decisions `logic_remove_silence` used to take wrong, pinned
/// without Logic running: what the four numbers ARE, whether the window that
/// opened is the one the command asked for, and whether OK is worth pressing.
final class RemoveSilenceWindowTests: XCTestCase {

    // MARK: - The window, as measured

    /// The Remove Silence window's direct children in tree order, MEASURED
    /// 2026-09-02 and identical on 5/5 openings: each value's `AXGroup` is
    /// followed by the `AXStaticText` that names it.
    private static let measuredChildren: [RemoveSilence.Child] = [
        RemoveSilence.Child(role: "AXStaticText", value: "8 Regions"),
        RemoveSilence.Child(role: "AXCheckBox", value: "1", title: "Search Zero Crossing"),
        RemoveSilence.Child(role: "AXGroup", value: "0,1000"),
        RemoveSilence.Child(role: "AXStaticText", value: "Minimum Time to accept as Silence:"),
        RemoveSilence.Child(role: "AXGroup", value: "0,0000"),
        RemoveSilence.Child(role: "AXStaticText", value: "Post Release-Time:"),
        RemoveSilence.Child(role: "AXGroup", value: "0,0060"),
        RemoveSilence.Child(role: "AXStaticText", value: "Pre Attack-Time:"),
        RemoveSilence.Child(role: "AXGroup", value: "-28"),
        RemoveSilence.Child(role: "AXStaticText", value: "Threshold:"),
        RemoveSilence.Child(role: "AXButton", title: "OK"),
        RemoveSilence.Child(role: "AXButton", title: "Cancel")
    ]

    // MARK: - D1: the four numbers, named

    /// THE DEFECT. The array the tool ships is
    /// `[minimum silence, post release, pre attack, threshold]`; both prose
    /// orders said `(threshold, minimum silence, pre-attack, post-release)`, so
    /// an agent read the −28 dB threshold as a post-release TIME. Order is no
    /// longer the contract: every value carries the label Logic printed beside
    /// it.
    func testEachNumberIsPairedWithTheLabelLogicPrintedBesideIt() {
        let reading = RemoveSilence.read(Self.measuredChildren)
        XCTAssertEqual(
            reading.fields.map { [$0.label, $0.text] },
            [
                ["Minimum Time to accept as Silence:", "0,1000"],
                ["Post Release-Time:", "0,0000"],
                ["Pre Attack-Time:", "0,0060"],
                ["Threshold:", "-28"]
            ]
        )
        XCTAssertEqual(
            reading.fields.map(\.key),
            [.minimumSilenceSeconds, .postReleaseSeconds, .preAttackSeconds, .thresholdDb]
        )
        XCTAssertTrue(reading.allFieldsNamed)
    }

    /// The threshold is −28 dB and nothing else. Both prose orders made it
    /// `0,1000` (a tenth of a second) and made the post-release time −28.
    func testTheStableKeysCarryTheRightNumbers() {
        let payload = RemoveSilence.read(Self.measuredChildren).payload
        XCTAssertEqual(payload["threshold_db"] as? Double, -28)
        XCTAssertEqual(payload["minimum_silence_seconds"] as? Double, 0.1)
        XCTAssertEqual(payload["pre_attack_seconds"] as? Double, 0.006)
        XCTAssertEqual(payload["post_release_seconds"] as? Double, 0)
        XCTAssertEqual(payload["fields_identified_by"] as? String, "label")
    }

    /// The raw array stays for compatibility, in the order it is ACTUALLY in.
    func testTheRawArrayIsKeptInLogicsOwnOrder() {
        let payload = RemoveSilence.read(Self.measuredChildren).payload
        XCTAssertEqual(
            payload["numeric_fields_in_order"] as? [String],
            ["0,1000", "0,0000", "0,0060", "-28"]
        )
    }

    /// Logic prints these in the SYSTEM's locale — a decimal COMMA on the
    /// reference Mac even with an English UI — so a caller running `Double()`
    /// over the printed string gets nil, not a number.
    func testTheValuesUseADecimalCommaAndAreParsedAnyway() {
        XCTAssertNil(Double("0,1000"))
        XCTAssertEqual(RemoveSilence.numericValue("0,1000"), 0.1)
        XCTAssertEqual(RemoveSilence.numericValue("0.1000"), 0.1)
        XCTAssertEqual(RemoveSilence.numericValue(" -28 "), -28)
        XCTAssertNil(RemoveSilence.numericValue("Threshold:"))
        let payload = RemoveSilence.read(Self.measuredChildren).payload
        XCTAssertTrue((payload["decimal_note"] as? String)?.contains("comma") == true)
    }

    /// D5: keyed by something stable. The payload used to key the checkbox by
    /// its own TITLE — `"Search Zero Crossing": true` — which is a different
    /// string on a translated Logic and addressable by nobody on any Logic.
    func testTheZeroCrossingFlagIsKeyedStructurallyWithTheLabelBesideIt() {
        let payload = RemoveSilence.read(Self.measuredChildren).payload
        XCTAssertEqual(payload["zero_crossing"] as? Bool, true)
        XCTAssertEqual(payload["zero_crossing_label"] as? String, "Search Zero Crossing")
        XCTAssertNil(payload["Search Zero Crossing"])
    }

    func testThePreviewCountIsNotMistakenForAFieldLabel() {
        let reading = RemoveSilence.read(Self.measuredChildren)
        XCTAssertEqual(reading.previewRegions, 8)
        XCTAssertEqual(reading.previewText, "8 Regions")
        XCTAssertFalse(reading.fields.contains { $0.label.contains("Region") })
    }

    /// A TRANSLATED Logic: the values are language-independent, the labels are
    /// not. The tool must then publish NO stable key rather than guess which
    /// number is which from its position — that guess is the defect.
    func testUnrecognisedLabelsPublishNoStableKeys() {
        let translated: [RemoveSilence.Child] = [
            RemoveSilence.Child(role: "AXGroup", value: "0,1000"),
            RemoveSilence.Child(role: "AXStaticText", value: "Durée minimale de silence :"),
            RemoveSilence.Child(role: "AXGroup", value: "-28"),
            RemoveSilence.Child(role: "AXStaticText", value: "Niveau :")
        ]
        let reading = RemoveSilence.read(translated)
        XCTAssertFalse(reading.allFieldsNamed)
        XCTAssertEqual(reading.fields.map(\.label), ["Durée minimale de silence :", "Niveau :"])
        let payload = reading.payload
        XCTAssertEqual(payload["fields_identified_by"] as? String, "unrecognised")
        for key in RemoveSilence.FieldKey.allCases {
            XCTAssertNil(payload[key.rawValue], key.rawValue)
        }
        XCTAssertTrue((payload["fields_note"] as? String)?.contains("position") == true)
    }

    /// A value nothing labelled is still a value: dropping it would silently
    /// shorten the array a caller may still be reading.
    func testAnUnlabelledValueIsStillReported() {
        let reading = RemoveSilence.read([
            RemoveSilence.Child(role: "AXGroup", value: "0,1000"),
            RemoveSilence.Child(role: "AXGroup", value: "-28"),
            RemoveSilence.Child(role: "AXStaticText", value: "Threshold:")
        ])
        XCTAssertEqual(reading.fields.map(\.text), ["0,1000", "-28"])
        // Values queue and each label claims the OLDEST unclaimed one, so this
        // window labels the FIRST value and leaves the second bare.
        XCTAssertEqual(reading.fields.map(\.label), ["Threshold:", ""])
        XCTAssertNil(reading.fields[1].key)
    }

    // MARK: - D2: the window that appeared

    private func evidence(
        title: String = "Remove Silence",
        numericFieldCount: Int = 4,
        checkBoxCount: Int = 1,
        radioButtonCount: Int = 0,
        popUpButtonCount: Int = 0,
        publishesDefaultButton: Bool = true,
        publishesCancelButton: Bool = true
    ) -> RemoveSilence.WindowEvidence {
        RemoveSilence.WindowEvidence(
            title: title,
            numericFieldCount: numericFieldCount,
            checkBoxCount: checkBoxCount,
            radioButtonCount: radioButtonCount,
            popUpButtonCount: popUpButtonCount,
            publishesDefaultButton: publishesDefaultButton,
            publishesCancelButton: publishesCancelButton
        )
    }

    func testTheEnglishTitleStillIdentifiesTheWindow() {
        XCTAssertEqual(RemoveSilence.identify(evidence()), .title)
    }

    /// THE DEFECT. The window is `AXModal = 1` (measured 2026-09-02), so a
    /// title miss used to leave a modal standing that swallowed every later
    /// tool call — while the source comment claimed the failure was safe. A
    /// window that APPEARED when the command fired and carries the measured
    /// shape is recognised with no English at all.
    func testATranslatedTitleIsRecognisedByShapeInstead() {
        XCTAssertEqual(RemoveSilence.identify(evidence(title: "Supprimer le silence")), .appeared)
        XCTAssertEqual(RemoveSilence.identify(evidence(title: "")), .appeared)
    }

    /// The preview TEXT is deliberately NOT part of the shape gate: it is the
    /// one part of this window that is words, so requiring it would fail on
    /// exactly the translated Logic the shape route exists for.
    func testTheShapeGateDoesNotDependOnReadingTheRegionCount() {
        let reading = RemoveSilence.read([
            RemoveSilence.Child(role: "AXStaticText", value: "8 régions"),
            RemoveSilence.Child(role: "AXCheckBox", value: "0", title: "Chercher passage par zéro"),
            RemoveSilence.Child(role: "AXGroup", value: "0,1000"),
            RemoveSilence.Child(role: "AXStaticText", value: "Silence :"),
            RemoveSilence.Child(role: "AXGroup", value: "0,0000"),
            RemoveSilence.Child(role: "AXStaticText", value: "Relâchement :"),
            RemoveSilence.Child(role: "AXGroup", value: "0,0060"),
            RemoveSilence.Child(role: "AXStaticText", value: "Attaque :"),
            RemoveSilence.Child(role: "AXGroup", value: "-28"),
            RemoveSilence.Child(role: "AXStaticText", value: "Niveau :")
        ])
        XCTAssertNil(reading.previewRegions)
        XCTAssertEqual(
            RemoveSilence.identify(
                evidence(title: "Supprimer le silence", numericFieldCount: reading.fields.count)
            ),
            .appeared
        )
    }

    /// Anything else that opens is CANCELLED and refused — never pressed OK.
    /// The reason has to name both shapes, because the agent's next move
    /// depends on what actually appeared.
    func testSomeOtherWindowIsRefusedAndTheReasonNamesTheShape() {
        for wrong in [
            evidence(title: "Bounce", numericFieldCount: 12, popUpButtonCount: 3),
            evidence(title: "", numericFieldCount: 0, checkBoxCount: 0),
            evidence(title: "Notes Crossing Split Point", numericFieldCount: 0, checkBoxCount: 0),
            evidence(title: "Anything", publishesCancelButton: false)
        ] {
            guard case .unrecognised(let reason) = RemoveSilence.identify(wrong) else {
                return XCTFail("expected a refusal for \(wrong)")
            }
            XCTAssertTrue(reason.contains("four numeric fields"), reason)
            XCTAssertTrue(reason.contains("Remove Silence from Audio Region"), reason)
        }
    }

    /// The title is corroboration, not the gate — the result says which one
    /// recognised the window, the same way the MIDI import's tempo prompt does.
    func testTheResultCanSayHowTheWindowWasIdentified() {
        XCTAssertEqual(RemoveSilence.Identification.title.word, "title")
        XCTAssertEqual(RemoveSilence.Identification.appeared.word, "appeared")
    }

    // MARK: - The preview / apply split

    /// A preview presses CANCEL: nothing is written, so there is nothing for a
    /// project-wide clear to protect and the preview does not pay for one. The
    /// APPLY fires a project-wide command, so it takes the guard the other five
    /// region commands share — in its own words.
    func testRemoveSilenceRefusesInItsOwnWordsLikeTheOtherFive() {
        let hidden = RegionEditGuard.coverage(
            trackVerdict: TrackListCompleteness.evaluate(
                rows: [
                    TrackListCompleteness.Row(
                        number: 1, name: "Ivan Vocals", isStack: false, expanded: nil
                    ),
                    TrackListCompleteness.Row(
                        number: 9, name: "Drum Synth Kit", isStack: true, expanded: false
                    )
                ],
                scrollable: false
            ),
            headerNumbers: [1, 9],
            regionRowNumbers: [1, 9]
        )
        let plan = RegionEditGuard.plan(
            coverage: hidden, deselectAllRegistered: false, command: .removeSilence
        )
        guard case .refuse(let reason) = plan else {
            return XCTFail("expected a refusal, got \(plan)")
        }
        XCTAssertTrue(reason.contains("Refusing to fire Remove Silence blind"), reason)
        XCTAssertTrue(reason.contains("Nothing was stripped"), reason)
        XCTAssertTrue(reason.contains("would be stripped too"), reason)
    }

    /// The after-check the apply path needs the census for, and the preview
    /// does not: how far the PROJECT's rendered region total must move. The old
    /// check compared the target track's own count, which a Remove Silence that
    /// also stripped a region on another row satisfies exactly.
    func testTheApplyExpectsLogicsOwnPreviewCountAcrossTheWholeProject() {
        XCTAssertEqual(RemoveSilence.commit(previewRegions: 8), .press(expectedDelta: 7))
        // 54 regions in the project, one of them about to become eight.
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 7, before: 54, after: 61), .asExpected
        )
        XCTAssertEqual(RegionEditGuard.delta(expected: 7, before: 54, after: 54), .pending)
        // Eight from the addressed region and one more from a row nobody can
        // see: loud, and never a success.
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 7, before: 54, after: 63),
            .unexpected(actualDelta: 9)
        )
    }

    /// A preview of one region is Logic saying the settings find nothing silent
    /// enough. OK would write nothing, so it is not pressed at all.
    func testAPreviewOfOneRegionIsAVerifiedNoOpRatherThanAPress() {
        XCTAssertEqual(RemoveSilence.commit(previewRegions: 1), .nothingToStrip)
        XCTAssertEqual(RemoveSilence.commit(previewRegions: 0), .nothingToStrip)
    }

    /// An unreadable preview leaves "the total moved" as the only check there
    /// is, and the result must not claim a number it never read.
    func testAnUnreadablePreviewFallsBackToTheTotalMoving() {
        XCTAssertEqual(RemoveSilence.commit(previewRegions: nil), .press(expectedDelta: nil))
    }

    // MARK: - D4: the note a preview must not carry

    /// THE DEFECT. `Tool.listenNoteText` keys off the STATIC
    /// `changesArrangement` flag, so every `apply: false` result carried its own
    /// "NOTHING WAS CHANGED" and, beside it, 460 bytes telling the agent to
    /// bounce a range and undo a copy it had never made.
    func testAPreviewThatChangedNothingCarriesNoListenNote() {
        XCTAssertTrue(Tool.changedNothing(["state": "previewed", "applied": false]))
        XCTAssertTrue(Tool.changedNothing(["state": "already_one_region", "applied": false]))
        XCTAssertTrue(Tool.changedNothing(["state": "unchanged"]))
        XCTAssertTrue(Tool.changedNothing(["state": "already_muted"]))
        XCTAssertTrue(Tool.changedNothing(["applied": false]))
    }

    /// And a call that DID write still gets it — the note is the reason half of
    /// this server exists.
    func testAnAppliedResultStillCarriesTheListenNote() {
        XCTAssertFalse(Tool.changedNothing(["state": "applied", "applied": true]))
        XCTAssertFalse(Tool.changedNothing(["state": "split"]))
        XCTAssertFalse(Tool.changedNothing([:]))
        let tool = MCPServer().toolRegistry().first { $0.name == "logic_remove_silence" }
        XCTAssertEqual(tool?.listenNoteText, Tool.arrangementListenNote)
    }
}
