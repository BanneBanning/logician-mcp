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
        for label in ["Pitch Source", "Flex", "Score", "Clip Length", "Gain", "Fade-In", "-"] {
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
        for key in ["dynamics", "gate_time", "delay_ticks", "q_strength"] {
            XCTAssertTrue(RegionInspector.parameter(key: key)?.underMore == true, key)
        }
        for key in ["mute", "loop", "quantize", "q_swing", "transpose", "velocity_offset"] {
            XCTAssertFalse(RegionInspector.parameter(key: key)?.underMore == true, key)
        }
    }
}
