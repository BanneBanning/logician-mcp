import XCTest
@testable import Logician

/// The Accessibility plane's locale surface, without Logic.
///
/// Three things are pinned here, and they are the three claims the R4 locale
/// work makes:
///
/// 1. A dialog can be classified by SHAPE — identifiers, roles, counts — and
///    the shape actually DISCRIMINATES between the two alerts a MIDI import
///    can meet. If it did not, shape-first matching would be a hazard rather
///    than an improvement.
/// 2. The English strings all live in one table, and the entries that are
///    load-bearing pairs (the two spellings of "Don't Save", the alert
///    markers the reset answers) still agree with the code that reads them.
/// 3. `logic_health`'s language inference is honest: English gets no warning,
///    a translated Logic gets one that names the planes, and "cannot tell"
///    never renders as "not English".
final class LocaleSurfaceTests: XCTestCase {

    // MARK: - Dialog shapes

    private func shape(
        buttonIdentifiers: [String] = [],
        checkBoxIdentifiers: [String] = [],
        radios: Int = 0,
        popUps: Int = 0,
        texts: Int = 0,
        defaultButton: Bool = false,
        cancelButton: Bool = false
    ) -> AXDialogShape {
        AXDialogShape(
            buttonIdentifiers: buttonIdentifiers,
            checkBoxIdentifiers: checkBoxIdentifiers,
            buttonCount: buttonIdentifiers.count,
            checkBoxCount: checkBoxIdentifiers.count,
            radioButtonCount: radios,
            popUpButtonCount: popUps,
            staticTextCount: texts,
            publishesDefaultButton: defaultButton,
            publishesCancelButton: cancelButton
        )
    }

    /// The measured tempo prompt (R2 §3.5): three numbered buttons AND the
    /// suppression checkbox.
    private var tempoPromptShape: AXDialogShape {
        shape(
            buttonIdentifiers: [
                LogicUIStrings.Identifier.actionButton1,
                LogicUIStrings.Identifier.actionButton2,
                LogicUIStrings.Identifier.actionButton3
            ],
            checkBoxIdentifiers: [LogicUIStrings.Identifier.suppressionCheckbox],
            texts: 2
        )
    }

    /// The measured save-changes alert (R2 §8): the same three buttons, no
    /// checkbox. This is the one the tempo prompt must never be confused with
    /// — `action-button-1` means "No, don't import tempo" on one and "Save the
    /// user's project" on the other.
    private var saveChangesShape: AXDialogShape {
        shape(
            buttonIdentifiers: [
                LogicUIStrings.Identifier.actionButton1,
                LogicUIStrings.Identifier.actionButton2,
                LogicUIStrings.Identifier.actionButton3
            ],
            texts: 2
        )
    }

    func testTheTempoPromptIsToldFromTheSaveChangesAlertByShapeAlone() {
        XCTAssertTrue(tempoPromptShape.isTempoPromptShape)
        XCTAssertFalse(saveChangesShape.isTempoPromptShape)
        // Both are the same SPECIES of alert; only the checkbox separates them.
        XCTAssertTrue(tempoPromptShape.hasActionButtonTriple)
        XCTAssertTrue(saveChangesShape.hasActionButtonTriple)
        XCTAssertTrue(tempoPromptShape.hasSuppressionCheckbox)
        XCTAssertFalse(saveChangesShape.hasSuppressionCheckbox)
    }

    func testAnAlertWithNoIdentifiersMatchesNoShape() {
        let anonymous = shape(buttonIdentifiers: ["", ""], texts: 2)
        XCTAssertFalse(anonymous.isTempoPromptShape)
        XCTAssertFalse(anonymous.hasActionButtonTriple)
        XCTAssertFalse(anonymous.isBounceInPlaceSheetShape)
    }

    func testTheBounceInPlaceSheetIsToldFromASavePanelByItsRadioButtons() {
        // Source (Mute/Leave/Delete) and destination (Selected/New Track)
        // radios plus the Normalize and file-split pop-ups.
        let sheet = shape(radios: 5, popUps: 2)
        XCTAssertTrue(sheet.isBounceInPlaceSheetShape)
        // A save panel: pop-ups (file format, where-to) and no radios.
        let savePanel = shape(popUps: 2)
        XCTAssertFalse(savePanel.isBounceInPlaceSheetShape)
    }

    // MARK: - Recognising the tempo prompt

    func testEitherWitnessRecognisesTheTempoPromptAndTheResultSaysWhich() {
        let english = ["Also import tempo information?", "This will replace…"]
        let swedish = ["Vill du även importera tempoinformation?", "Detta ersätter…"]

        XCTAssertEqual(
            ImportMIDI.recognise(texts: english, shapeMatches: true), .shapeAndText
        )
        // The case this whole exercise is for: a translated Logic, recognised
        // by identifiers alone.
        XCTAssertEqual(
            ImportMIDI.recognise(texts: swedish, shapeMatches: true), .shapeOnly
        )
        // A Logic build that publishes no identifiers still works in English.
        XCTAssertEqual(
            ImportMIDI.recognise(texts: english, shapeMatches: false), .textOnly
        )
        XCTAssertEqual(
            ImportMIDI.recognise(texts: swedish, shapeMatches: false), .unrecognised
        )
        XCTAssertFalse(
            ImportMIDI.recognise(texts: swedish, shapeMatches: false).recognised
        )
        XCTAssertTrue(ImportMIDI.recognise(texts: swedish, shapeMatches: true).recognised)
    }

    // MARK: - The string table

    func testTheResetStillAnswersTheTwoDialogsItsGrammarNames() {
        // The table now supplies both the markers and the button spellings;
        // this is the assertion that moving them changed nothing.
        let saveChanges = ProjectReset.answer(
            forTexts: ["Do you want to save the changes made to the document “X”?"],
            buttons: [LogicUIStrings.Button.save, LogicUIStrings.Button.dontSave, "Cancel"]
        )
        XCTAssertEqual(saveChanges?.button, LogicUIStrings.Button.dontSave)

        // The straight-quote spelling is accepted too, so a font or OS change
        // cannot turn a known dialog into an unknown one.
        let straight = ProjectReset.answer(
            forTexts: ["Do you want to save the changes made to the document “X”?"],
            buttons: ["Save", LogicUIStrings.Button.dontSaveStraightQuote, "Cancel"]
        )
        XCTAssertEqual(straight?.button, LogicUIStrings.Button.dontSaveStraightQuote)
        XCTAssertNotEqual(
            LogicUIStrings.Button.dontSave, LogicUIStrings.Button.dontSaveStraightQuote
        )
    }

    func testTheTrackDescriptionFormatUsesTypographicQuotes() {
        // Logic's own spelling: `Track 7 “Bass”`, U+201C/U+201D. A straight
        // quote here would take every region read with it.
        XCTAssertEqual(LogicUIStrings.Format.openQuote, "\u{201C}")
        XCTAssertEqual(LogicUIStrings.Format.closeQuote, "\u{201D}")
        XCTAssertEqual(LogicUIStrings.Format.trackDescriptionPrefix, "Track ")
    }

    func testDecibelTextIsNormalisedForBothDecimalSeparatorsAndBothGlyphs() {
        let normalize = LogicUIStrings.Format.normalizedDecibelText
        XCTAssertEqual(normalize("-10,6 dB"), "-10.6")
        XCTAssertEqual(normalize("-10.6 dB"), "-10.6")
        XCTAssertEqual(normalize("1,0 \u{33A9}"), "1.0")
        // The two independent parsers now agree because they share this.
        XCTAssertEqual(ChannelStrip.decibels("-10,6 dB"), -10.6)
        XCTAssertEqual(ChannelStrip.decibels("1,0 \u{33A9}"), 1.0)
    }

    // MARK: - An empty arrangement walk (the R4 silent failure)

    /// R4 regression (measured on a French Logic, 2026-08-30): the row walk
    /// found no `Track N "Name"` layout areas — their descriptions are
    /// localized — and `logic_list_regions` answered `{"tracks": []}` with a
    /// benign note and no error, so a 26-track project read as an empty
    /// arrangement. The verdict below is what `listRegions` now consults
    /// before it is allowed to say "empty": only a track header column that
    /// answered ZERO proves empty; a header column that cannot be read, or
    /// one that visibly holds tracks, must refuse instead.
    func testAnEmptyRegionWalkMayOnlyReportEmptyWhenTheHeadersProveIt() {
        XCTAssertEqual(
            LogicAccessibility.emptyArrangementVerdict(headerItemCount: nil),
            .headerUnreadable,
            "an unreadable header column cannot tell empty from unreadable — refuse"
        )
        XCTAssertEqual(
            LogicAccessibility.emptyArrangementVerdict(headerItemCount: 26),
            .rowsUnreadable(headerCount: 26),
            "26 visible track headers prove the arrangement is NOT empty — refuse"
        )
        XCTAssertEqual(
            LogicAccessibility.emptyArrangementVerdict(headerItemCount: 0),
            .genuinelyEmpty,
            "a header column that answered zero is the one real empty arrangement"
        )
    }

    // MARK: - The language inference

    private func evidence(
        localizations: [String],
        preferences: [String],
        perApp: Bool = false,
        matched: [String],
        development: String? = "en"
    ) -> LogicUILanguage.Evidence {
        LogicUILanguage.Evidence(
            appLocalizations: localizations,
            preferenceOrder: preferences,
            perApplicationOverride: perApp,
            matched: matched,
            developmentRegion: development
        )
    }

    func testAnEnglishLogicIsReportedWithoutAWarning() {
        let report = LogicUILanguage.report(evidence(
            localizations: ["en", "de", "sv"], preferences: ["en-GB", "sv-SE"], matched: ["en"]
        ))
        XCTAssertEqual(report.language, "en")
        XCTAssertEqual(report.isEnglish, true)
        // Nothing degrades, so nothing is said. A standing warning on the
        // supported configuration is noise an agent learns to skip.
        XCTAssertNil(report.note)
        XCTAssertTrue(report.method.contains("resolves to 'en'"))
        // A dialect still reads as English.
        let british = LogicUILanguage.report(evidence(
            localizations: ["en-GB"], preferences: ["en-GB"], matched: ["en-GB"]
        ))
        XCTAssertEqual(british.isEnglish, true)
    }

    /// The real configuration on the machine this was built on, and the
    /// reason the inference uses CFBundle's matcher instead of just reading
    /// `AppleLanguages`: a Swedish Mac running a Logic that ships no Swedish
    /// is showing an ENGLISH UI, and a naive read would have warned about a
    /// degradation that is not happening.
    func testAPreferredLanguageLogicDoesNotShipFallsBackToItsDevelopmentRegion() {
        let report = LogicUILanguage.report(evidence(
            localizations: ["en", "de", "fr", "ja", "zh-Hans"],
            preferences: ["sv-SE"],
            matched: [],
            development: "en"
        ))
        XCTAssertEqual(report.language, "en")
        XCTAssertEqual(report.isEnglish, true)
        XCTAssertNil(report.note)
        XCTAssertTrue(report.method.contains("NONE of them matches"))
        XCTAssertTrue(report.method.contains("development region 'en'"))
    }

    func testANonEnglishLogicIsWarnedAboutByPlane() {
        let report = LogicUILanguage.report(evidence(
            localizations: ["en", "sv"], preferences: ["sv-SE", "en"], matched: ["sv"]
        ))
        XCTAssertEqual(report.language, "sv")
        XCTAssertEqual(report.isEnglish, false)
        let note = try? XCTUnwrap(report.note)
        let text = note ?? ""
        // The note has to name what breaks AND what does not, or an agent
        // reading it cannot tell which half of the server to still trust.
        XCTAssertTrue(text.contains("'sv'"))
        XCTAssertTrue(text.lowercased().contains("modal"))
        XCTAssertTrue(text.contains("logic_list_regions"))
        XCTAssertTrue(text.contains("logic_learn_key_command"))
        XCTAssertTrue(text.contains("control-surface plane"))
        XCTAssertTrue(text.contains("UNAFFECTED"))
    }

    func testAPerApplicationOverrideIsNamedAsTheSourceOfTheAnswer() {
        let report = LogicUILanguage.report(evidence(
            localizations: ["en", "ja"], preferences: ["ja"], perApp: true, matched: ["ja"]
        ))
        XCTAssertTrue(report.method.contains("per-application"))
        XCTAssertEqual(report.isEnglish, false)
    }

    func testAnUnreadableBundleReportsUnknownAndNeverEnglish() {
        let report = LogicUILanguage.report(evidence(
            localizations: [], preferences: ["en"], matched: [], development: nil
        ))
        XCTAssertNil(report.language)
        // The whole point: "cannot tell" must not collapse into "not English"
        // OR into "English". Both would be a claim this has no evidence for.
        XCTAssertNil(report.isEnglish)
        XCTAssertEqual(report.note, LogicUILanguage.unknownNote)
        XCTAssertTrue(report.payload["language"] is NSNull)
        XCTAssertTrue(report.payload["is_english"] is NSNull)
    }

    func testTheHealthPayloadAlwaysSaysHowItDecided() {
        let report = LogicUILanguage.report(evidence(
            localizations: ["en"], preferences: ["en"], matched: ["en"]
        ))
        let payload = report.payload
        XCTAssertNotNil(payload["determined_by"])
        // Never claimed as a measurement.
        let confidence = (payload["confidence"] as? String) ?? ""
        XCTAssertTrue(confidence.hasPrefix("inferred"))
        XCTAssertTrue(confidence.contains("running application"))
    }
}
