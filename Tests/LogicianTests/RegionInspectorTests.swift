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
}
