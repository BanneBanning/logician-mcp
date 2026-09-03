import XCTest
@testable import Logician

/// The Region inspector's pure half: whose parameters the panel is showing,
/// what a row label means, and how a tool argument becomes the integer
/// Logic's slider takes. Every constant here was measured against Logic Pro
/// 12.3.1 on 2026-08-28; a test that fails is either a Logic change or a
/// regression, and both are worth stopping for.
final class RegionInspectorTests: XCTestCase {

    // MARK: - Whose parameters are on screen

    func testARegionNameIsTheOrdinaryCase() {
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "Crash"),
            .region(name: "Crash")
        )
    }

    func testNothingSelectedShowsTheTracksRegionDefaults() {
        // The hazard this classification exists for: a write here would change
        // what every FUTURE region on the track inherits.
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "MIDI Defaults"),
            .defaults(kind: "MIDI")
        )
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "Audio Defaults"),
            .defaults(kind: "Audio")
        )
    }

    func testSeveralSelectedRegionsAreCounted() {
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "2 selected"),
            .multiple(count: 2)
        )
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "17 selected"),
            .multiple(count: 17)
        )
    }

    func testARegionActuallyNamedLikeTheSpecialCasesIsStillARegion() {
        // "Defaults" alone is a legal region name; only the two-word form
        // Logic writes is the defaults panel.
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "Defaults"),
            .region(name: "Defaults")
        )
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "not selected"),
            .region(name: "not selected")
        )
    }

    // MARK: - Row labels

    func testLabelsLoseLogicsTrailingColon() {
        XCTAssertEqual(RegionInspector.normalizedLabel("Mute:"), "Mute")
        XCTAssertEqual(RegionInspector.normalizedLabel("Velocity Offset:"), "Velocity Offset")
        // Pop-up labels come without one, and "More" comes with a leading space.
        XCTAssertEqual(RegionInspector.normalizedLabel("Quantize"), "Quantize")
        XCTAssertEqual(RegionInspector.normalizedLabel(" More"), "More")
    }

    func testTheQuantizeRowIsFoundUnderBothOfItsLabels() {
        // On a MIDI region the LABEL cell is itself a pop-up that reads
        // "Quantize" or "Smart Quantize"; on an audio region it is the text
        // "Quantize:". All three name the same row.
        XCTAssertEqual(RegionInspector.parameter(forLabel: "Quantize")?.key, "quantize")
        XCTAssertEqual(RegionInspector.parameter(forLabel: "Quantize:")?.key, "quantize")
        XCTAssertEqual(RegionInspector.parameter(forLabel: "Smart Quantize")?.key, "quantize")
    }

    func testRowsThisServerDoesNotWriteHaveNoParameter() {
        for label in ["Pitch Source", "Flex", "Score", "Clip Length",
                      "Smart Tempo", "File Tempo", "-"] {
            XCTAssertNil(
                RegionInspector.parameter(forLabel: label),
                "\(label) is read but not written and must not resolve to a writable parameter"
            )
        }
    }

    func testEveryWritableParameterIsInTheWriteOrderAndViceVersa() {
        XCTAssertEqual(
            Set(RegionInspector.writeOrder),
            Set(RegionInspector.writable.map(\.key))
        )
        XCTAssertEqual(RegionInspector.writeOrder.count, RegionInspector.writable.count)
    }

    func testQuantizeIsWrittenBeforeEveryQRow() {
        // Logic disables Q-Swing and Q-Strength while Quantize is Off, so the
        // order is load-bearing, not cosmetic.
        let quantize = RegionInspector.writeOrder.firstIndex(of: "quantize")
        XCTAssertNotNil(quantize)
        for key in RegionInspector.writeOrder where key.hasPrefix("q_") {
            XCTAssertLessThan(
                quantize!, RegionInspector.writeOrder.firstIndex(of: key)!,
                "\(key) must be written after quantize"
            )
        }
    }

    // MARK: - Displayed values

    func testLogicPrintsADefaultBlankAndThatIsAnAnswerNotAMissingOne() {
        XCTAssertNil(RegionInspector.displayText("   "))
        XCTAssertNil(RegionInspector.displayText(""))
        XCTAssertEqual(RegionInspector.displayText("+12"), "+12")
        XCTAssertEqual(RegionInspector.displayText("-1/32"), "-1/32")
    }

    // MARK: - The two indexed vocabularies

    func testDynamicsIsAnIndexIntoLogicsScalings() {
        XCTAssertEqual(try RegionInspector.sliderValue(key: "dynamics", argument: "Fixed"), 0)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "dynamics", argument: "100%"), 6)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "dynamics", argument: "400%"), 14)
        // The percent sign is optional on the way in.
        XCTAssertEqual(try RegionInspector.sliderValue(key: "dynamics", argument: "125"), 9)
    }

    func testGateTimeHasLegatoAndDynamicsDoesNot() {
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gate_time", argument: "Legato"), 15)
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "dynamics", argument: "Legato")) {
            guard case RegionInspector.ValueError.unknownName(_, _, let available) = $0 else {
                return XCTFail("expected unknownName, got \($0)")
            }
            XCTAssertFalse(available.contains("Legato"))
        }
    }

    func testAnIndexNameIsReportedBackEvenWhenLogicPrintsItBlank() {
        // Index 6 is "no change" and Logic paints the cell empty, so the name
        // is derived from the measured table rather than read.
        let entry = RegionInspector.report(key: "dynamics", raw: 6, published: "   ")
        XCTAssertEqual(entry["value"] as? Int, 6)
        XCTAssertEqual(entry["name"] as? String, "100%")
        XCTAssertNil(entry["display"])
    }

    func testAScaleNameIsRefusedWithTheRealListRatherThanGuessedAt() {
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "dynamics", argument: "110%")) {
            guard case RegionInspector.ValueError.unknownName(let key, let given, let available) = $0 else {
                return XCTFail("expected unknownName, got \($0)")
            }
            XCTAssertEqual(key, "dynamics")
            XCTAssertEqual(given, "110%")
            XCTAssertEqual(available, RegionInspector.scaleNames)
        }
    }

    // MARK: - Numeric arguments

    func testNumericParametersTakeLogicsOwnRanges() {
        XCTAssertEqual(try RegionInspector.sliderValue(key: "transpose", argument: 12), 12)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "transpose", argument: -96), -96)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "delay_ticks", argument: -120), -120)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "q_swing", argument: 62), 62)
    }

    func testAValueOutsideLogicsRangeIsRefusedBeforeAnythingIsWritten() {
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "transpose", argument: 97)) {
            guard case RegionInspector.ValueError.outOfRange(let key, let given, let range, _) = $0 else {
                return XCTFail("expected outOfRange, got \($0)")
            }
            XCTAssertEqual(key, "transpose")
            XCTAssertEqual(given, 97)
            XCTAssertEqual(range, -96...96)
        }
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "q_swing", argument: 0))
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "velocity_offset", argument: 100))
    }

    func testAWholeNumberFromJSONIsAcceptedInEveryShapeItArrivesIn() {
        XCTAssertEqual(try RegionInspector.sliderValue(key: "transpose", argument: Double(7)), 7)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "transpose", argument: "7"), 7)
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "transpose", argument: 7.5))
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "transpose", argument: "a lot"))
    }

    // MARK: - Checkboxes and the mixed state

    func testACheckboxOverDisagreeingRegionsIsMixedRatherThanFalse() {
        XCTAssertEqual(RegionInspector.checkboxState("1"), true)
        XCTAssertEqual(RegionInspector.checkboxState("0"), false)
        // AXValue 2 is macOS's mixed state, measured with one muted region and
        // one unmuted selected together. Reading it as "off" would report the
        // muted region as audible.
        XCTAssertNil(RegionInspector.checkboxState("2"))
    }

    // MARK: - Region types

    func testMidiOnlyParametersAreMarkedAsSuch() {
        XCTAssertEqual(
            RegionInspector.parameter(key: "velocity_offset")?.regionTypes, [RegionInspector.midi]
        )
        XCTAssertEqual(
            RegionInspector.parameter(key: "dynamics")?.regionTypes, [RegionInspector.midi]
        )
        // Quantize, transpose, loop, mute and delay exist on both.
        for key in ["quantize", "transpose", "loop", "mute", "delay_ticks"] {
            XCTAssertEqual(
                RegionInspector.parameter(key: key)?.regionTypes, RegionInspector.both, key
            )
        }
    }

    func testTheParametersLogicHidesBehindMoreAreMarked() {
        for key in ["dynamics", "gate_time", "delay_ticks", "q_strength",
                    "fade_in_ms", "fade_in_curve", "fade_out_ms", "fade_type",
                    "fade_out_curve", "reverse"] {
            XCTAssertTrue(RegionInspector.parameter(key: key)?.underMore == true, key)
        }
        for key in ["mute", "loop", "quantize", "q_swing", "transpose", "velocity_offset",
                    "gain_db", "fine_tune"] {
            XCTAssertFalse(RegionInspector.parameter(key: key)?.underMore == true, key)
        }
    }

    func testAudioOnlyParametersAreMarkedAsSuch() {
        for key in ["gain_db", "fine_tune", "fade_in_ms", "fade_in_curve", "fade_out_ms",
                    "fade_type", "fade_out_curve", "reverse"] {
            XCTAssertEqual(
                RegionInspector.parameter(key: key)?.regionTypes, [RegionInspector.audio], key
            )
        }
    }

    // MARK: - Transpose: the same parameter, two ranges

    func testAudioTransposeCapsAtThirtySixWhereMidiRunsToNinetySix() {
        // Measured on both region types: Logic publishes AXMinValue/AXMaxValue
        // -96…96 on a MIDI region and -36…36 on an audio one. 50 semitones is
        // a legal MIDI value that an audio region would silently CLAMP, so it
        // is refused by name once the panel has said which type is on screen.
        XCTAssertNoThrow(
            try RegionInspector.checkRange(key: "transpose", value: 50, regionType: "midi")
        )
        XCTAssertNoThrow(
            try RegionInspector.checkRange(key: "transpose", value: 36, regionType: "audio")
        )
        XCTAssertThrowsError(
            try RegionInspector.checkRange(key: "transpose", value: 50, regionType: "audio")
        ) {
            guard case RegionInspector.ValueError.outOfRangeForRegionType(
                let key, let given, let range, _, let regionType
            ) = $0 else { return XCTFail("expected outOfRangeForRegionType, got \($0)") }
            XCTAssertEqual(key, "transpose")
            XCTAssertEqual(given, 50)
            XCTAssertEqual(range, -36...36)
            XCTAssertEqual(regionType, "audio")
        }
        // With the type not known yet, the widest range applies — the argument
        // check runs before the panel has been read.
        XCTAssertNoThrow(
            try RegionInspector.checkRange(key: "transpose", value: 50, regionType: nil)
        )
    }

    // MARK: - Gain: decibels in, tenths of a decibel out

    func testGainIsGivenInDecibelsAndHeldInTenths() {
        // Logic's slider runs -300…300 and 30 reads "+3,0 ㏈". The argument is
        // decibels precisely so that nobody has to know that.
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: 3.0), 30)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: -6.5), -65)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: -20), -200)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: 0), 0)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: "1.4"), 14)
        // A tenth is Logic's resolution; anything finer is rounded to it
        // rather than refused.
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: -6.53), -65)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "gain_db", argument: -6.57), -66)
    }

    func testGainOutsideThirtyDecibelsIsRefusedInDecibels() {
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "gain_db", argument: 42.0)) {
            guard case RegionInspector.ValueError.outOfDecibelRange(
                let key, let given, let limit
            ) = $0 else { return XCTFail("expected outOfDecibelRange, got \($0)") }
            XCTAssertEqual(key, "gain_db")
            XCTAssertEqual(given, 42.0)
            XCTAssertEqual(limit, 30.0)
        }
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "gain_db", argument: -30.1))
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "gain_db", argument: "loud"))
    }

    func testGainIsReportedBothWaysSoAResultCanBeFedBackIn() {
        let entry = RegionInspector.report(key: "gain_db", raw: -65, published: "-6,5 ㏈")
        XCTAssertEqual(entry["value"] as? Int, -65)          // what Logic holds
        XCTAssertEqual(entry["db"] as? Double, -6.5)         // what the tool takes
        XCTAssertEqual(entry["gain"] as? String, "-6.5 dB")
        XCTAssertEqual(entry["display"] as? String, "-6,5 ㏈") // what Logic paints
    }

    func testGainDisplaySignsAndTenthsTheWayLogicDoes() {
        XCTAssertEqual(RegionInspector.gainDisplay(tenths: 30), "+3.0 dB")
        XCTAssertEqual(RegionInspector.gainDisplay(tenths: -65), "-6.5 dB")
        XCTAssertEqual(RegionInspector.gainDisplay(tenths: 0), "0.0 dB")
        XCTAssertEqual(RegionInspector.gainDisplay(tenths: -200), "-20.0 dB")
        XCTAssertEqual(RegionInspector.gainDisplay(tenths: 7), "+0.7 dB")
    }

    // MARK: - Fades: milliseconds, unconverted

    func testFadeLengthsAreMillisecondsAndAreNotScaled() {
        XCTAssertEqual(try RegionInspector.sliderValue(key: "fade_in_ms", argument: 500), 500)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "fade_out_ms", argument: 0), 0)
        XCTAssertEqual(try RegionInspector.sliderValue(key: "fade_out_ms", argument: 99999), 99999)
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "fade_in_ms", argument: -1))
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "fade_out_ms", argument: 100000))
        // The curves are a shape, not a length, and run either side of zero.
        XCTAssertEqual(try RegionInspector.sliderValue(key: "fade_in_curve", argument: -40), -40)
        XCTAssertThrowsError(try RegionInspector.sliderValue(key: "fade_out_curve", argument: 100))
    }

    // MARK: - Two rows called "Curve"

    /// Logic's own audio row order, measured 2026-08-28. Row 11 is the "More"
    /// disclosure and rows 14 and 17 are BOTH called "Curve".
    private static let audioLabels = [
        "Mute:", "Loop:", "Quantize:", "Q-Swing:", "Transpose:", "Fine Tune:",
        "Pitch Source:", "Flex:", "Smart Tempo:", "File Tempo:", "Gain:", " More",
        "Delay:", "Fade-In", "Curve:", "Fade-Out", "Type:", "Curve:", "Reverse:",
        "-", "Q-Range:", "Q-Strength:"
    ]

    private static let midiLabels = [
        "Mute:", "Loop:", "Quantize", "Q-Swing:", "Transpose:", "-",
        "Pitch Source:", "Flex:", "-", "-", "Velocity Offset:", " More",
        "Delay:", "Dynamics:", "Gate Time:", "Clip Length:", "Score:", "Q-Velocity:",
        "Q-Length:", "Q-Flam:", "Q-Range:", "Q-Strength:"
    ]

    func testTheTwoCurveRowsAreToldApartByPositionNotByLabel() {
        let rows = RegionInspector.rowIndexes(labels: Self.audioLabels)
        XCTAssertEqual(rows["fade_in_ms"], 13)
        XCTAssertEqual(rows["fade_in_curve"], 14)   // the Curve AFTER Fade-In
        XCTAssertEqual(rows["fade_out_ms"], 15)
        XCTAssertEqual(rows["fade_type"], 16)
        XCTAssertEqual(rows["fade_out_curve"], 17)  // the Curve AFTER Fade-Out
        XCTAssertEqual(rows["reverse"], 18)
        XCTAssertEqual(rows["gain_db"], 10)
        XCTAssertEqual(rows["fine_tune"], 5)
        XCTAssertEqual(rows["transpose"], 4)
        XCTAssertEqual(rows["q_strength"], 21)
    }

    func testTheFadeRowsAreStillFoundWhenTheirLabelPopUpIsInTheOtherMode() {
        // The Fade-In label cell is a pop-up reading "Fade-In" or "Speed Up",
        // and the Fade-Out one "Fade-Out" or "Slow Down". The Curve rows must
        // still resolve, so that the write path can refuse the mode by name
        // instead of failing to find the row at all.
        var labels = Self.audioLabels
        labels[13] = "Speed Up"
        labels[15] = "Slow Down"
        let rows = RegionInspector.rowIndexes(labels: labels)
        XCTAssertEqual(rows["fade_in_ms"], 13)
        XCTAssertEqual(rows["fade_in_curve"], 14)
        XCTAssertEqual(rows["fade_out_ms"], 15)
        XCTAssertEqual(rows["fade_out_curve"], 17)
    }

    func testADuplicatedLabelWithNothingToAnchorItIsRefusedRatherThanGuessed() {
        // Fade-Out gone from the panel: the second Curve has no anchor, and
        // answering "row 14" would write the fade-IN curve while reporting the
        // fade-out one. nil makes the write path refuse instead.
        var labels = Self.audioLabels
        labels[15] = "Delay:"
        let rows = RegionInspector.rowIndexes(labels: labels)
        XCTAssertNil(rows["fade_out_curve"])
        XCTAssertEqual(rows["fade_in_curve"], 14)
    }

    func testAMidiPanelPublishesNoneOfTheAudioRows() {
        let rows = RegionInspector.rowIndexes(labels: Self.midiLabels)
        for key in ["gain_db", "fine_tune", "fade_in_ms", "fade_in_curve",
                    "fade_out_ms", "fade_type", "fade_out_curve", "reverse"] {
            XCTAssertNil(rows[key], key)
        }
        XCTAssertEqual(rows["velocity_offset"], 10)
        XCTAssertEqual(rows["dynamics"], 13)
        XCTAssertEqual(rows["gate_time"], 14)
        XCTAssertEqual(rows["quantize"], 2)
    }

    func testEveryFadeLengthIsWrittenBeforeItsOwnCurve() {
        // A curve is a shape ON a fade; setting the length last would leave the
        // curve on a fade of zero for the duration of the call.
        func index(_ key: String) -> Int {
            RegionInspector.writeOrder.firstIndex(of: key) ?? -1
        }
        XCTAssertLessThan(index("fade_in_ms"), index("fade_in_curve"))
        XCTAssertLessThan(index("fade_out_ms"), index("fade_out_curve"))
        XCTAssertLessThan(index("fade_out_ms"), index("fade_type"))
    }

    // MARK: - A pop-up that displays less than it offers

    func testTheFadeTypePopUpShowsTheHeadOfTheMenuItemItWasGiven() {
        // Measured 2026-08-28: the menu item is spelled "X (Crossfade)" and
        // the pop-up then READS "X". Comparing the two literally reported a
        // write that had worked as a verification failure.
        XCTAssertEqual(RegionInspector.popupShortForm("X (Crossfade)"), "X")
        XCTAssertEqual(RegionInspector.popupShortForm("EqP (Equal Power Crossfade)"), "EqP")
        XCTAssertEqual(RegionInspector.popupShortForm("X S (S-Curved Crossfade)"), "X S")
        XCTAssertEqual(RegionInspector.popupShortForm("Out"), "Out")
        XCTAssertEqual(RegionInspector.popupShortForm("1/16 Triplet (1/24)"), "1/16 Triplet")
    }

    func testAPopUpValueMatchesEitherSpellingInEitherDirection() {
        XCTAssertTrue(RegionInspector.popupValuesMatch("X", "X (Crossfade)"))
        XCTAssertTrue(RegionInspector.popupValuesMatch("X (Crossfade)", "X"))
        XCTAssertTrue(RegionInspector.popupValuesMatch("EqP", "EqP (Equal Power Crossfade)"))
        XCTAssertTrue(RegionInspector.popupValuesMatch("Out", "out"))
        // "X" and "X S" are two different fades and must not collapse.
        XCTAssertFalse(RegionInspector.popupValuesMatch("X", "X S (S-Curved Crossfade)"))
        XCTAssertFalse(RegionInspector.popupValuesMatch("Out", "X (Crossfade)"))
    }

    // MARK: - Logic's own two strings are refused as NAMES

    /// The trap: the panel's name field is where Logic says whose parameters
    /// are on screen AND the field `logic_rename_region` writes. A region
    /// named "2 selected" reads as a two-region selection to every
    /// Region-inspector tool, and the rename path reads the panel BEFORE it
    /// writes — so the inverse call refuses too and this server can never
    /// rename it back. Refused before the write instead.
    func testTheStringsLogicPrintsForItselfAreRefusedAsRegionNames() {
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("2 selected"))
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("17 selected"))
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("MIDI Defaults"))
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("Audio Defaults"))
        // Any " Defaults" the panel could print, not just Logic's two kinds.
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("Sparkle Defaults"))
        // Leading and trailing space does not smuggle one past the refusal:
        // the write is trimmed, so the panel would read the reserved shape.
        XCTAssertNotNil(RegionInspector.reservedPanelNameReason("  2 selected  "))
    }

    func testTheRefusalNamesWhichStringLogicReservedAndWhy() {
        let reason = RegionInspector.reservedPanelNameReason("2 selected")
        XCTAssertEqual(
            reason,
            "'2 selected' is the string Logic's Region inspector prints when 2 regions are selected"
        )
        XCTAssertEqual(
            RegionInspector.reservedPanelNameReason("MIDI Defaults"),
            "'MIDI Defaults' is the string Logic's Region inspector prints when NO region is "
                + "selected and the panel is showing the track's MIDI region defaults"
        )
    }

    func testOrdinaryNamesAndTheNearMissesAreNotRefused() {
        XCTAssertNil(RegionInspector.reservedPanelNameReason("Crash"))
        XCTAssertNil(RegionInspector.reservedPanelNameReason("Untitled_1#05.42"))
        // The near misses the classification already allows: "Defaults" alone
        // is not the two-word form, and "not selected" has no count.
        XCTAssertNil(RegionInspector.reservedPanelNameReason("Defaults"))
        XCTAssertNil(RegionInspector.reservedPanelNameReason("not selected"))
        XCTAssertNil(RegionInspector.reservedPanelNameReason("2 selected takes"))
    }

    func testTheAlternativeTheRefusalOffersIsItselfSafe() {
        // A refusal that names the alternative has to name a legal one.
        for reserved in ["2 selected", "17 selected", "MIDI Defaults", "Audio Defaults"] {
            let alternative = RegionInspector.unreservedAlternative(to: reserved)
            XCTAssertNil(
                RegionInspector.reservedPanelNameReason(alternative),
                "the alternative offered for '\(reserved)' is reserved too"
            )
        }
    }

    // MARK: - A region already named like a selection state

    /// The escape hatch for a region Logic's own UI (or an older build of this
    /// server) named into the trap: the panel string alone cannot tell it from
    /// the state, but the ARRANGEMENT can — one region selected, and the map's
    /// name for it is that very string.
    func testARegionNamedLikeASelectionStateIsStillARegion() {
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "2 selected",
                evidence: .init(selectedCount: 1, addressedRegionName: "2 selected")
            ),
            .region(name: "2 selected")
        )
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "MIDI Defaults",
                evidence: .init(selectedCount: 1, addressedRegionName: "MIDI Defaults")
            ),
            .region(name: "MIDI Defaults")
        )
        // The map prints a muted region as "<name>, muted" while the panel
        // shows the bare name; the tiebreak compares the bare names.
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "2 selected",
                evidence: .init(selectedCount: 1, addressedRegionName: "2 selected, muted")
            ),
            .region(name: "2 selected")
        )
    }

    func testNeitherHalfOfTheEvidenceOverrulesThePanelOnItsOwn() {
        // A GENUINE two-region selection, one of which happens to be named
        // "2 selected": the count says two are selected, so the panel stands.
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "2 selected",
                evidence: .init(selectedCount: 2, addressedRegionName: "2 selected")
            ),
            .multiple(count: 2)
        )
        // One region selected, but it is NOT the one whose name looks like the
        // state — so the panel is reporting a state, not showing a name.
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "2 selected",
                evidence: .init(selectedCount: 1, addressedRegionName: "Crash")
            ),
            .multiple(count: 2)
        )
        // Nobody counted: the count sees rendered rows only, and a missing
        // one is not a licence to write.
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "2 selected",
                evidence: .init(addressedRegionName: "2 selected")
            ),
            .multiple(count: 2)
        )
        // And the defaults panel keeps its meaning when the addressed region
        // is not the one it names.
        XCTAssertEqual(
            RegionInspector.panelSubject(
                nameField: "MIDI Defaults",
                evidence: .init(selectedCount: 1, addressedRegionName: "Crash")
            ),
            .defaults(kind: "MIDI")
        )
    }

    func testWithNoEvidenceTheClassificationIsWhatItAlwaysWas() {
        // What a call that addressed NO region sees: `logic_get_region_params`
        // with no track_name reads whatever the user left on screen, nothing
        // was selected by the call, and "2 selected" is then a true answer.
        XCTAssertEqual(RegionInspector.panelSubject(nameField: "2 selected"), .multiple(count: 2))
        XCTAssertEqual(
            RegionInspector.panelSubject(nameField: "Audio Defaults"), .defaults(kind: "Audio")
        )
        XCTAssertEqual(RegionInspector.panelSubject(nameField: "Crash"), .region(name: "Crash"))
    }

    /// What the settle poll waits for. MEASURED 2026-09-02: the panel read
    /// taken ~15 ms after an exclusive selection that cleared three regions on
    /// another row came back "MIDI Defaults" — Logic had processed the
    /// deselection and not yet the selection — so the write path polls this
    /// until the panel names a region rather than refusing the first look.
    func testOnlyARegionSubjectLetsAWritePastTheSettlePoll() {
        XCTAssertTrue(RegionInspector.PanelSubject.region(name: "Crash").isRegion)
        XCTAssertFalse(RegionInspector.PanelSubject.multiple(count: 3).isRegion)
        XCTAssertFalse(RegionInspector.PanelSubject.defaults(kind: "MIDI").isRegion)
    }

    // MARK: - What a call that ADDRESSED one region does with the panel

    /// The three Region-inspector tools that name a region — rename, get and
    /// set — select it exclusively and then have to agree on one question. Only
    /// a panel naming a region lets any of them past.
    func testOnlyTheAddressedRegionGetsPastTheAddressedCheck() {
        XCTAssertNil(
            RegionInspector.addressedPanelRefusal(
                .region(name: "Crash"), addressedRegionName: "Crash",
                outcome: "nothing was written"
            )
        )
        XCTAssertNotNil(
            RegionInspector.addressedPanelRefusal(
                .multiple(count: 3), addressedRegionName: "Crash",
                outcome: "nothing was written"
            )
        )
        XCTAssertNotNil(
            RegionInspector.addressedPanelRefusal(
                .defaults(kind: "MIDI"), addressedRegionName: "Crash",
                outcome: "nothing was read"
            )
        )
        // The map prints a muted region as "<name>, muted" and the panel shows
        // the bare name; that is not a mismatch.
        XCTAssertNil(
            RegionInspector.addressedPanelRefusal(
                .region(name: "Crash"), addressedRegionName: "Crash, muted",
                outcome: "nothing was read"
            )
        )
        // A caller that addressed no region (the no-arguments read) has
        // nothing to compare and nothing to refuse.
        XCTAssertNil(
            RegionInspector.addressedPanelRefusal(
                .region(name: "Crash"), addressedRegionName: nil, outcome: "nothing was read"
            )
        )
    }

    /// THE DEFECT, as it was measured. On 2026-09-02 the old build read
    /// `Latin` at bar 13 on "Acke Slagverk" straight after selecting it and
    /// came back `panel_name: "Crash"` — the region the previous call had
    /// selected, still painted — and reported Crash's twenty-two rows under a
    /// `region` key naming Latin. A well-formed `.region` subject, and the
    /// wrong region: the check that only asked "is this a region?" passed it.
    func testTheStalePanelIsAWellFormedRegionAndStillRefused() {
        let refusal = RegionInspector.addressedPanelRefusal(
            .region(name: "Crash"), addressedRegionName: "Latin", outcome: "nothing was read"
        )
        XCTAssertEqual(
            refusal,
            "the Region inspector is still showing the region 'Crash' rather than 'Latin', the "
                + "region that was addressed: nothing was read. Logic never repainted the panel "
                + "onto the new selection, so every row under it is 'Crash's."
        )
    }

    /// A refusal that does not say what the tool did NOT do leaves the agent
    /// guessing whether half a write landed. Each caller supplies its own
    /// words and they have to survive into the message.
    func testTheRefusalCarriesEachCallersOwnAccountOfWhatItDidNotDo() {
        for outcome in ["nothing was written", "nothing was read", "nothing was renamed"] {
            for subject in [
                RegionInspector.PanelSubject.multiple(count: 2), .defaults(kind: "Audio"),
                .region(name: "SomeoneElse")
            ] {
                let refusal = RegionInspector.addressedPanelRefusal(
                    subject, addressedRegionName: "Crash", outcome: outcome
                )
                XCTAssertNotNil(refusal)
                XCTAssertTrue(
                    refusal?.contains(outcome) == true,
                    "'\(outcome)' did not survive into the \(subject) refusal"
                )
            }
        }
    }

    /// The refusal has to name the state it found, not just decline: a
    /// defaults panel is a different THING (what future regions inherit), and
    /// a multi-selection refusal has to leave the door open for the region
    /// that is genuinely called "2 selected".
    func testTheRefusalNamesTheStateItFoundAndTheWayOutOfIt() {
        let defaults = RegionInspector.addressedPanelRefusal(
            .defaults(kind: "MIDI"), addressedRegionName: "Crash", outcome: "nothing was written"
        )
        XCTAssertEqual(
            defaults,
            "the Region inspector is showing the track's MIDI region DEFAULTS — what every FUTURE "
                + "region on that track inherits — rather than the region that was addressed: "
                + "nothing was written. The selection did not take."
        )
        let multiple = RegionInspector.addressedPanelRefusal(
            .multiple(count: 2), addressedRegionName: "Crash", outcome: "nothing was renamed"
        )
        XCTAssertEqual(
            multiple,
            "2 regions are selected, and the Region inspector's name field then reads '2 selected' "
                + "rather than naming the addressed region: nothing was renamed. The selection did "
                + "not take. (A region genuinely NAMED '2 selected' is addressed normally: the "
                + "arrangement map's name for the selected region is what tells the two apart, and "
                + "here it did not match.)"
        )
    }

    /// The whole chain, as the three tools walk it: classify the panel string
    /// with the arrangement's evidence, THEN decide. A region named
    /// "2 selected" is read and written like any other region; the same string
    /// with the same count but a different addressed region is the state, and
    /// is refused.
    func testARegionNamedLikeASelectionStateIsReadAndWrittenLikeAnyOther() {
        let asARegion = RegionInspector.panelSubject(
            nameField: "2 selected",
            evidence: .init(selectedCount: 1, addressedRegionName: "2 selected")
        )
        XCTAssertNil(
            RegionInspector.addressedPanelRefusal(
                asARegion, addressedRegionName: "2 selected", outcome: "nothing was written"
            ),
            "a region genuinely named '2 selected' is still locked out of its own parameters"
        )
        let asTheState = RegionInspector.panelSubject(
            nameField: "2 selected",
            evidence: .init(selectedCount: 2, addressedRegionName: "Crash")
        )
        XCTAssertNotNil(
            RegionInspector.addressedPanelRefusal(
                asTheState, addressedRegionName: "Crash", outcome: "nothing was written"
            )
        )
        // And the same for the defaults shape, which is the one the masked
        // race actually produced live.
        let namedDefaults = RegionInspector.panelSubject(
            nameField: "MIDI Defaults",
            evidence: .init(selectedCount: 1, addressedRegionName: "MIDI Defaults")
        )
        XCTAssertNil(
            RegionInspector.addressedPanelRefusal(
                namedDefaults, addressedRegionName: "MIDI Defaults", outcome: "nothing was read"
            )
        )
    }

    // MARK: - What the settle poll spends

    /// The race `logic_set_region_params` had masked: its `selectedRegionCount`
    /// walk was 72 ms of accidental settle in front of the panel read. Deleting
    /// the walk without replacing the wait would have made a correctly
    /// addressed write refuse itself (it did, on 2 of 4 live calls, in
    /// `logic_rename_region`). The replacement looks BEFORE it sleeps, so the
    /// honest call pays one 7 ms read.
    func testTheSettlePollLooksBeforeItSleeps() {
        XCTAssertLessThanOrEqual(
            LogicAccessibility.PanelSettlePoll.interval, 0.015,
            "a settle that sleeps first charges every honest call for the rare slow repaint"
        )
    }

    /// What the poll is actually waiting FOR, and the reason it is not
    /// `isRegion`: the stale panel measured live was a well-formed region — the
    /// previous one. A caller that knows the arrangement map's name for the
    /// region it just selected waits for that name.
    func testTheSettlePollWaitsForTheAddressedRegionAndNotJustForAnyRegion() {
        XCTAssertFalse(
            LogicAccessibility.panelHasCaughtUp(
                subject: .region(name: "Crash"), panelName: "Crash", wanted: "Latin"
            ),
            "the panel still showing the PREVIOUS region satisfied the old stop condition"
        )
        XCTAssertTrue(
            LogicAccessibility.panelHasCaughtUp(
                subject: .region(name: "Latin"), panelName: "Latin", wanted: "Latin"
            )
        )
        // A region NAMED like one of Logic's own strings never satisfies
        // `isRegion`, so waiting on that would burn the whole budget on it
        // every call. The name match stops the poll and `SelectionEvidence`
        // settles the classification afterwards.
        XCTAssertTrue(
            LogicAccessibility.panelHasCaughtUp(
                subject: .multiple(count: 2), panelName: "2 selected", wanted: "2 selected"
            )
        )
        // With no addressed region — the no-arguments read — there is no name
        // to wait for and the poll is not run at all; the fallback is the old
        // condition.
        XCTAssertTrue(
            LogicAccessibility.panelHasCaughtUp(
                subject: .region(name: "Crash"), panelName: "Crash", wanted: nil
            )
        )
        XCTAssertFalse(
            LogicAccessibility.panelHasCaughtUp(
                subject: .defaults(kind: "MIDI"), panelName: "MIDI Defaults", wanted: nil
            )
        )
    }

    /// Cut the WAIT, never the VERIFICATION: the budget has to be worth more
    /// than the 72 ms walk it replaced, so a selection that is genuinely slow
    /// to repaint is waited for rather than refused.
    func testTheSettlePollIsMorePatientThanTheWalkItReplaced() {
        XCTAssertGreaterThanOrEqual(LogicAccessibility.PanelSettlePoll.budget, 0.3 - 1e-9)
        XCTAssertGreaterThan(LogicAccessibility.PanelSettlePoll.budget, 0.072)
    }

    // MARK: - Both channels, exactly

    /// The description promised the rename was verified TWICE; the panel
    /// readback was taken (15 ms) and never compared, and the one comparison
    /// there was was case-INSENSITIVE while the already-set short-circuit
    /// above it was case-sensitive — so a case-only rename took the write path
    /// and was then unverified in both channels.
    func testBothChannelsHaveToCarryTheNewName() {
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "ProfRenamed", panelName: "ProfRenamed", mapName: "ProfRenamed"
            ),
            .verified
        )
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "ProfRenamed", panelName: "ProfRenamed", mapName: "Crash"
            ),
            .mapDisagrees(mapName: "Crash", panelName: "ProfRenamed")
        )
        // The divergence the old code read and discarded: the map says the
        // rename landed, Logic's own live view of the region says it did not.
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "ProfRenamed", panelName: "Crash", mapName: "ProfRenamed"
            ),
            .channelsDisagree(mapName: "ProfRenamed", panelName: "Crash")
        )
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "ProfRenamed", panelName: "ProfRenamed", mapName: nil
            ),
            .noRegionAtThatPosition(panelName: "ProfRenamed")
        )
    }

    func testACaseOnlyRenameIsVerifiedAsExactlyAsAnyOther() {
        // "Crash" → "CRASH" is a real rename, and the compare that proves it
        // has to see the difference.
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "CRASH", panelName: "CRASH", mapName: "CRASH"
            ),
            .verified
        )
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "CRASH", panelName: "CRASH", mapName: "Crash"
            ),
            .mapDisagrees(mapName: "Crash", panelName: "CRASH")
        )
        XCTAssertEqual(
            LogicAccessibility.renameVerification(
                wanted: "CRASH", panelName: "crash", mapName: "CRASH"
            ),
            .channelsDisagree(mapName: "CRASH", panelName: "crash")
        )
    }

    func testEveryRefusalSaysWhatBothChannelsRead() {
        let disagreement = LogicAccessibility.renameVerification(
            wanted: "CRASH", panelName: "Crash", mapName: "CRASH"
        )
        let mismatch = disagreement.mismatch ?? ""
        XCTAssertTrue(mismatch.contains("'CRASH'"), mismatch)
        XCTAssertTrue(mismatch.contains("'Crash'"), mismatch)
        XCTAssertTrue(mismatch.contains("disagree"), mismatch)
        XCTAssertNil(
            LogicAccessibility.renameVerification(
                wanted: "CRASH", panelName: "CRASH", mapName: "CRASH"
            ).mismatch
        )
    }

    func testTheChannelsAreComparedOnTheBareTrimmedName() {
        XCTAssertEqual(LogicAccessibility.comparableName("Fills, muted"), "Fills")
        XCTAssertEqual(LogicAccessibility.comparableName("  Fills  "), "Fills")
        // Case survives: it is what a case-only rename changes.
        XCTAssertEqual(LogicAccessibility.comparableName("FILLS"), "FILLS")
    }

    func testTheMapNameIsTheRegionAtTheAddressedBarAndBeat() {
        let snapshot: [[String: Any]] = [
            ["name": "Fills", "start_bar": 39, "start_beat": 4],
            ["name": "CRASH, muted", "start_bar": 41, "start_beat": 3]
        ]
        XCTAssertEqual(
            LogicAccessibility.mapName(in: snapshot, startBar: 41, startBeat: 3), "CRASH"
        )
        // The beat is part of the address: a region at the same bar on another
        // beat is not the one that was renamed.
        XCTAssertNil(LogicAccessibility.mapName(in: snapshot, startBar: 41, startBeat: 1))
        XCTAssertNil(LogicAccessibility.mapName(in: snapshot, startBar: 20, startBeat: 3))
    }

    // MARK: - The renumbering question

    func testARenameThatMovedNoOtherRegionReportsNoSideEffects() {
        let before: [[String: Any]] = [
            ["name": "Fills", "start_bar": 39, "start_beat": 4],
            ["name": "Fills.1", "start_bar": 55]
        ]
        let after: [[String: Any]] = [
            ["name": "Fills", "start_bar": 39, "start_beat": 4],
            ["name": "LogicianScratchAudio", "start_bar": 55]
        ]
        XCTAssertTrue(
            LogicAccessibility.otherRegionsThatChangedName(
                before: before, after: after, atStartBar: 55, startBeat: nil
            ).isEmpty
        )
    }

    func testARenameThatRenumberedTheNeighboursSaysSo() {
        // Logic renumbers DEFAULT marker names by position; whether regions do
        // the same is a live question, and this is how the answer is reported
        // rather than assumed.
        let before: [[String: Any]] = [
            ["name": "Fills", "start_bar": 39, "start_beat": 4],
            ["name": "Fills.1", "start_bar": 55]
        ]
        let after: [[String: Any]] = [
            ["name": "Fills.2", "start_bar": 39, "start_beat": 4],
            ["name": "Renamed", "start_bar": 55]
        ]
        let moved = LogicAccessibility.otherRegionsThatChangedName(
            before: before, after: after, atStartBar: 55, startBeat: nil
        )
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?["from"] as? String, "Fills")
        XCTAssertEqual(moved.first?["to"] as? String, "Fills.2")
    }

    func testTheMutedSuffixIsNotMistakenForARename() {
        // The arrangement map calls a muted region "<name>, muted" while the
        // inspector shows the bare name.
        let before: [[String: Any]] = [["name": "Fills", "start_bar": 39]]
        let after: [[String: Any]] = [["name": "Fills, muted", "start_bar": 39]]
        XCTAssertTrue(
            LogicAccessibility.otherRegionsThatChangedName(
                before: before, after: after, atStartBar: 55, startBeat: nil
            ).isEmpty
        )
    }

    // MARK: - What the disclosure poll spends

    /// 630 ms of every call with the panel collapsed at rest, and most of it
    /// was this: a loop that slept 0.1 s BEFORE its first look, four times a
    /// call, on toggles that had all already settled by then (measured
    /// 2026-09-02, 8 of 8).
    func testTheDisclosurePollLooksLongBeforeItSleepsLong() {
        XCTAssertLessThanOrEqual(
            LogicAccessibility.DisclosurePoll.interval, 0.015,
            "the old 0.1 s floor bought nothing on any measured toggle"
        )
    }

    /// Cut the WAIT, never the VERIFICATION: a triangle that genuinely refuses
    /// to move must still be given the 1.2 s the old 12 x 0.1 s loop gave it
    /// before `setDisclosure` calls it stuck and the read raises
    /// `trackNotExposed`.
    func testTheDisclosurePollIsExactlyAsPatientAsTheLoopItReplaced() {
        XCTAssertGreaterThanOrEqual(LogicAccessibility.DisclosurePoll.budget, 1.2 - 1e-9)
    }

    /// The same bargain for the pop-up menu: 1.2 s per press attempt, 3.0 s on
    /// the last one, 0.3 s for the dismissal — every budget kept, none of it
    /// spent before the first look.
    func testTheMenuPollKeepsEveryBudgetItsBlindSleepsHad() {
        XCTAssertGreaterThanOrEqual(LogicAccessibility.MenuPoll.budget, 1.2 - 1e-9)
        XCTAssertGreaterThanOrEqual(LogicAccessibility.MenuPoll.patientBudget, 3.0 - 1e-9)
        XCTAssertGreaterThanOrEqual(LogicAccessibility.MenuPoll.dismissBudget, 0.3 - 1e-9)
        XCTAssertLessThanOrEqual(LogicAccessibility.MenuPoll.interval, 0.03)
    }

    // MARK: - The disclosure debt

    /// A read that had to open both triangles leaves both open and owes both.
    func testOpeningBothDisclosuresLeavesThemOpenAndRecordsTheDebt() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: true, openedMore: true,
            projectDocument: "/Music/A.logicx"
        )
        XCTAssertFalse(plan.closeRegionPanelNow)
        XCTAssertFalse(plan.closeMoreNow)
        XCTAssertEqual(
            plan.debt,
            LogicAccessibility.InspectorDebt(
                regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
            )
        )
    }

    /// A panel found OPEN owes nothing: this server did not open it, so it has
    /// no business closing it at shutdown.
    func testAPanelFoundOpenIsNeverOwed() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: false, openedMore: false,
            projectDocument: "/Music/A.logicx"
        )
        XCTAssertNil(plan.debt)
        XCTAssertFalse(plan.closeRegionPanelNow)
        XCTAssertFalse(plan.closeMoreNow)
    }

    /// The second call in a chain finds both open and adds nothing — but the
    /// debt the FIRST call left has to survive it, or the shutdown restore
    /// quietly stops happening after two calls.
    func testTheDebtSurvivesACallThatOpensNothing() {
        let first = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: true, openedMore: true,
            projectDocument: "/Music/A.logicx"
        )
        let second = LogicAccessibility.planInspectorRestore(
            standing: first.debt, openedRegionPanel: false, openedMore: false,
            projectDocument: "/Music/A.logicx"
        )
        XCTAssertEqual(second.debt, first.debt)
    }

    /// A call that opens only "More" on top of a panel already owed must end
    /// up owing BOTH, not swapping one for the other.
    func testDebtsAccumulateRatherThanOverwrite() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: false, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: false, openedMore: true,
            projectDocument: "/Music/A.logicx"
        )
        XCTAssertEqual(
            plan.debt,
            LogicAccessibility.InspectorDebt(
                regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
            )
        )
    }

    /// A debt names a panel in ONE document. Once another song is open that
    /// panel is gone and the debt can never be verified again, so it is
    /// retired rather than pressed into a stranger's inspector.
    func testADebtFromAnotherProjectIsRetiredRatherThanPaidElsewhere() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: false, openedMore: false,
            projectDocument: "/Music/B.logicx"
        )
        XCTAssertNil(plan.debt)
    }

    func testANewDebtDoesNotInheritTheOldProjectsTriangles() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: true, openedMore: false,
            projectDocument: "/Music/B.logicx"
        )
        XCTAssertEqual(
            plan.debt,
            LogicAccessibility.InspectorDebt(
                regionPanel: true, more: false, projectDocument: "/Music/B.logicx"
            )
        )
    }

    /// No readable document, no deferral: a restore that cannot be scoped to
    /// the project it belongs to could be paid back into a different song, so
    /// it is paid on the spot instead.
    func testWithoutAProjectDocumentTheRestoreIsPaidImmediately() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: true, openedMore: true,
            projectDocument: nil
        )
        XCTAssertTrue(plan.closeRegionPanelNow)
        XCTAssertTrue(plan.closeMoreNow)
        XCTAssertNil(plan.debt)
    }

    // MARK: - …and the one state that cancels the deferral

    /// A call that had to SHOW a hidden Inspector closes what it opened before
    /// `callTool` presses the pane away. Deferring here would leave the user's
    /// disclosure state changed behind a pane that looks untouched — and out
    /// of reach of every later settle, which cannot show the Inspector.
    func testAHiddenInspectorIsPaidBackBeforeThePaneGoesAway() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: true, openedMore: true,
            projectDocument: "/Music/A.logicx", inspectorShownByThisCall: true
        )
        XCTAssertTrue(plan.closeRegionPanelNow)
        XCTAssertTrue(plan.closeMoreNow)
        XCTAssertNil(plan.debt)
    }

    /// It is also the last chance to pay an EARLIER call's debt in this
    /// document, so that one is settled here too rather than stranded.
    func testAHiddenInspectorAlsoSettlesAnEarlierCallsDebt() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: false, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: false, openedMore: false,
            projectDocument: "/Music/A.logicx", inspectorShownByThisCall: true
        )
        XCTAssertTrue(plan.closeRegionPanelNow)
        XCTAssertFalse(plan.closeMoreNow)
        XCTAssertNil(plan.debt)
    }

    /// …but never ANOTHER document's: that panel is gone, and pressing its
    /// triangles here would close a stranger's.
    func testAHiddenInspectorDoesNotPayAnotherProjectsDebt() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: false, openedMore: true,
            projectDocument: "/Music/B.logicx", inspectorShownByThisCall: true
        )
        XCTAssertFalse(plan.closeRegionPanelNow)
        XCTAssertTrue(plan.closeMoreNow)
        XCTAssertNil(plan.debt)
    }

    /// A hidden Inspector whose panel was already open (Logic remembers the
    /// triangle across a hide) presses nothing at all: this call opened
    /// nothing, so it owes nothing, and the disclosure is the user's.
    func testAHiddenInspectorClosesNothingItDidNotOpen() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: false, openedMore: false,
            projectDocument: "/Music/A.logicx", inspectorShownByThisCall: true
        )
        XCTAssertFalse(plan.closeRegionPanelNow)
        XCTAssertFalse(plan.closeMoreNow)
        XCTAssertNil(plan.debt)
    }

    /// The common case is untouched, stated explicitly: an Inspector the user
    /// already had open still gets the deferral the profile measured 13×
    /// cheaper.
    func testAnInspectorTheUserLeftOpenStillDefers() {
        let plan = LogicAccessibility.planInspectorRestore(
            standing: nil, openedRegionPanel: true, openedMore: true,
            projectDocument: "/Music/A.logicx", inspectorShownByThisCall: false
        )
        XCTAssertFalse(plan.closeRegionPanelNow)
        XCTAssertFalse(plan.closeMoreNow)
        XCTAssertEqual(
            plan.debt,
            LogicAccessibility.InspectorDebt(
                regionPanel: true, more: true, projectDocument: "/Music/A.logicx"
            )
        )
    }

    /// ...and a debt already standing is not thrown away by one unreadable
    /// document: it carries its own project and is checked again at settle
    /// time.
    func testAnUnreadableDocumentLeavesAnExistingDebtStanding() {
        let standing = LogicAccessibility.InspectorDebt(
            regionPanel: true, more: false, projectDocument: "/Music/A.logicx"
        )
        let plan = LogicAccessibility.planInspectorRestore(
            standing: standing, openedRegionPanel: false, openedMore: false,
            projectDocument: nil
        )
        XCTAssertEqual(plan.debt, standing)
    }

    // MARK: - Scoping the quantize vocabulary

    private func quantizeMenu() -> [String] {
        ["Off", "1/4-Note", "1/8-Note", "1/16-Note", "1/16 Swing F", "7-Tuplet"]
    }

    private func quantizeCacheFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quantize-\(UUID().uuidString).json")
    }

    func testTheQuantizeListRoundTripsWithinOneLogicInstall() {
        let url = quantizeCacheFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = LogicAccessibility.quantizeValuesScope(
            logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
        )
        saveScopedCache(quantizeMenu(), to: url, scope: scope)
        XCTAssertEqual(loadScopedCache(url, scope: scope, as: [String].self), quantizeMenu())
    }

    /// The list is Logic's own menu STRINGS. A Logic relaunched in German
    /// spells every one of them differently, and handing an agent the English
    /// vocabulary for a German menu is exactly the confidently-wrong answer
    /// this server exists to prevent.
    func testTheQuantizeListIsInvisibleAfterTheUILanguageChanges() {
        let url = quantizeCacheFile()
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(quantizeMenu(), to: url, scope: LogicAccessibility.quantizeValuesScope(
            logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
        ))
        XCTAssertNil(loadScopedCache(
            url,
            scope: LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "de"
            ),
            as: [String].self
        ))
    }

    /// A Logic UPDATE can add a grid. Same language, different build, no
    /// reuse.
    func testTheQuantizeListIsInvisibleAfterALogicUpdate() {
        let url = quantizeCacheFile()
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(quantizeMenu(), to: url, scope: LogicAccessibility.quantizeValuesScope(
            logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
        ))
        XCTAssertNil(loadScopedCache(
            url,
            scope: LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.4.0", logicBuild: "5500.10", uiLanguage: "en"
            ),
            as: [String].self
        ))
    }

    /// An install whose language could NOT be inferred must not quietly share
    /// a scope with one where it could: "unknown" is its own answer.
    func testAnUninferableLanguageIsItsOwnScope() {
        XCTAssertNotEqual(
            LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: nil
            ),
            LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
            )
        )
    }

    /// The project is deliberately NOT in the scope. The quantize menu is a
    /// property of the Logic install — 36 items, byte-identical across region
    /// types and songs (measured 2026-09-02) — and re-walking it per song
    /// would be the 715 ms this cache exists to stop paying.
    func testTheQuantizeScopeIgnoresWhichSongIsOpen() {
        let scope = LogicAccessibility.quantizeValuesScope(
            logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
        )
        XCTAssertFalse(scope.contains(".logicx"))
    }

    /// A file this install can never use again is retired on the way past,
    /// rather than left to be re-read and re-rejected on every call.
    func testAMismatchedQuantizeCacheIsDeletedWhenAskedTo() {
        let url = quantizeCacheFile()
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(quantizeMenu(), to: url, scope: LogicAccessibility.quantizeValuesScope(
            logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
        ))
        XCTAssertNil(loadScopedCache(
            url,
            scope: LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "sv"
            ),
            as: [String].self,
            deleteOnMismatch: true
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The Logician build is in the token too, so a version of this server
    /// that changes how the menu is read never inherits the previous build's
    /// list.
    func testTheQuantizeScopeCarriesTheServerBuild() {
        XCTAssertTrue(
            LogicAccessibility.quantizeValuesScope(
                logicVersion: "12.3.1", logicBuild: "5470.24", uiLanguage: "en"
            ).hasPrefix("v\(cacheSchemaVersion)|")
        )
    }
}
