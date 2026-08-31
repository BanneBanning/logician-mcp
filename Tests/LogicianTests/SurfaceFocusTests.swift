import XCTest
@testable import Logician

/// The rule that closes the silent wrong-strip read of 2026-08-31: a selected
/// TRACK HEADER stopped implying Logic's focused CHANNEL the moment a
/// headerless strip (Stereo Out) was selected on the surface, and
/// `logic_list_inserts {Bas, mcu}` returned Stereo Out's insert chain as Bas's
/// with `verified: true`. The decision "may the already-selected fast path be
/// trusted?" is pure, so it is exercised here without a surface — a wrong
/// verdict is a read (and by the same path a write) on the wrong channel.
final class SurfaceFocusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MCUController.knownChannelFocus = nil
    }

    override func tearDown() {
        MCUController.knownChannelFocus = nil
        super.tearDown()
    }

    /// The reference project's first bank, as the LCD paints it.
    private let bankTop = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "

    // MARK: - The live probe (pan-names view, SELECT LED, LCD cell)

    func testALitStripWhoseCellMatchesTheNameAgrees() {
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas", assignment: "PN", lcdTop: bankTop, litStrips: [1]
            ),
            .agrees(evidence: "mcu_select_led_lcd_name")
        )
    }

    func testAnAbbreviatedCellStillAgreesWithItsOwnName() {
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Lofi Pad", assignment: "PN", lcdTop: bankTop, litStrips: [0]
            ),
            .agrees(evidence: "mcu_select_led_lcd_name")
        )
    }

    func testALitStripWithAnotherNameIsAPositiveDivergence() {
        // The observed shape: Bas requested while the surface sits on another
        // strip. The verdict carries what the LCD showed, for the report.
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas", assignment: "PN", lcdTop: bankTop, litStrips: [0]
            ),
            .diverged(from: "LofPad")
        )
    }

    func testAnotherAssignmentViewNamesNoChannel() {
        // The PL and plugin-edit views do not name the channel they follow —
        // that gap is the original wrong-strip hazard, so they prove nothing.
        for assignment in ["PL", "P1", "SE", "IN", "CS", nil] {
            XCTAssertEqual(
                MCUController.focusProbeVerdict(
                    requested: "Bas", assignment: assignment, lcdTop: bankTop, litStrips: [1]
                ),
                .unknown, assignment ?? "nil"
            )
        }
    }

    func testNoLitLEDProvesNothing() {
        // The focused strip may simply be outside the visible bank, and a
        // surface that never echoes SELECT LEDs must not fail working calls.
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas", assignment: "PN", lcdTop: bankTop, litStrips: []
            ),
            .unknown
        )
    }

    func testSeveralLitLEDsProveNothing() {
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas", assignment: "PN", lcdTop: bankTop, litStrips: [0, 1]
            ),
            .unknown
        )
    }

    func testTheSingleChannelPanViewIsNotANamesRow() {
        // Same assignment code "PN", but the cells are a parameter banner —
        // the >= 4 dash-field signature `settledTop` refuses.
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas",
                assignment: "PN",
                lcdTop: "Pan    -      -      -      -      -      -      -   ",
                litStrips: [1]
            ),
            .unknown
        )
    }

    func testAnEmptyCellProvesNothing() {
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas",
                assignment: "PN",
                lcdTop: "LofPad Bas                                             ",
                litStrips: [4]
            ),
            .unknown
        )
    }

    func testALitStripOutsideTheRowProvesNothing() {
        XCTAssertEqual(
            MCUController.focusProbeVerdict(
                requested: "Bas", assignment: "PN", lcdTop: "", litStrips: [3]
            ),
            .unknown
        )
    }

    // MARK: - The process's own focus record

    private let project = "/Users/x/Testlåt Copy.logicx"

    func testTheObservedDivergenceIsCaughtByTheRecord() {
        // The live failure, verbatim: the surface had verifiably selected
        // Stereo Out (headerless), then Bas was requested while its header was
        // still selected. The record is what catches it when the surface sits
        // in a view that names no channel (it was on the plugin list).
        let record = MCUController.ChannelFocus(strip: "Stereo Out", projectPath: project)
        XCTAssertEqual(
            MCUController.focusRecordVerdict(requested: "Bas", record: record, projectPath: project),
            .diverged(from: "Stereo Out")
        )
    }

    func testARecordOnTheRequestedStripAgrees() {
        let record = MCUController.ChannelFocus(strip: "Bas", projectPath: project)
        XCTAssertEqual(
            MCUController.focusRecordVerdict(requested: "Bas", record: record, projectPath: project),
            .agrees(evidence: "process_focus_record")
        )
    }

    func testARecordFromAnotherProjectProvesNothing() {
        // A project switch rebuilds every selection; a record that outlives it
        // would realign against a strip map that no longer exists.
        let record = MCUController.ChannelFocus(strip: "Stereo Out", projectPath: project)
        XCTAssertEqual(
            MCUController.focusRecordVerdict(
                requested: "Bas", record: record, projectPath: "/Users/x/Other.logicx"
            ),
            .unknown
        )
    }

    func testNoRecordProvesNothing() {
        XCTAssertEqual(
            MCUController.focusRecordVerdict(requested: "Bas", record: nil, projectPath: project),
            .unknown
        )
    }

    // MARK: - The record lifecycle

    func testNotingAndForgettingTheFocus() {
        MCUController.noteChannelFocus("Stereo Out", projectPath: project)
        XCTAssertEqual(
            MCUController.knownChannelFocus,
            MCUController.ChannelFocus(strip: "Stereo Out", projectPath: project)
        )
        MCUController.forgetChannelFocus()
        XCTAssertNil(MCUController.knownChannelFocus)
    }

    // MARK: - What a realigned target reports

    func testARealignedTrackTargetCarriesRouteAndEvidence() {
        // Route stays the header plane (that is what resolved the NAME); the
        // readback says a realigning reselection happened. No `mcu_strip`:
        // the realign is an Accessibility reselection, deliberately not a
        // surface select — that one moves Logic's selection while the
        // plugin-list view stays latched (measured live 2026-08-31).
        let target = MCPServer.StripTarget(
            name: "Bas", plane: .trackHeader, channel: nil,
            selection: ["state": "selected"],
            evidence: "realigned_ax_reselect"
        )
        let fields = target.resultFields
        XCTAssertEqual(fields["selection_route"] as? String, "ax_track_header")
        XCTAssertNil(fields["mcu_strip"])
        XCTAssertEqual(fields["selection_readback_route"] as? String, "realigned_ax_reselect")
    }

    // MARK: - What an unrepairable divergence says

    func testAnUnrepairableDivergenceNamesBothHalvesAndTheFix() {
        let failure = focusRealignmentFailure(
            name: "Bas",
            focusedOn: "Stereo Out",
            reason: "no other track header exists to bounce the selection through"
        )
        XCTAssertEqual(failure.code, "verification_failed")
        let message = failure.errorDescription ?? ""
        XCTAssertTrue(message.contains("Bas"), "the strip the caller asked for")
        XCTAssertTrue(message.contains("Stereo Out"), "the strip the focus is actually on")
        XCTAssertTrue(message.contains("no other track header"), "why realigning was impossible")
        XCTAssertTrue(message.contains("Nothing was read or written"))
    }
}
