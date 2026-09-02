import LogicMCUBridge
import XCTest

@testable import Logician

/// The WRITE side of the blink rule: `logic_set_track_mute` and
/// `logic_set_track_solo` decide whether to press a button from one strip LED,
/// and Logic uses a flashing LED as a state of its own. These are the four
/// cases that used to be answered from a single instant.
final class ToggleLEDEvidenceTests: XCTestCase {

    // MARK: A blinking mute LED is a SOLO, not a mute

    /// The defect, from the caller's side: with a solo standing, the mute LED of
    /// every silenced channel flashes. Asked to UNMUTE such a track, the write
    /// must conclude "already unmuted" and press nothing — pressing would mute
    /// the user's track and report success.
    func testBlinkingMuteAskedToUnmuteIsAVerifiedNoOp() {
        XCTAssertEqual(
            MCUController.toggleDecision(control: .mute, verdict: .blinking, requested: false),
            .alreadySet(ledBlinking: true)
        )
    }

    /// The same blink in the other direction: asked to MUTE the track, the write
    /// must press. Reading the lit phase as an existing mute would return a
    /// verified no-op having done nothing at all.
    func testBlinkingMuteAskedToMutePresses() {
        XCTAssertEqual(
            MCUController.toggleDecision(control: .mute, verdict: .blinking, requested: true),
            .press(currentlyOn: false, ledBlinking: true)
        )
    }

    /// And the reading behind both: a flashing mute LED means not muted.
    func testBlinkingMuteReadsUnmuted() {
        XCTAssertEqual(
            MCUController.toggleReading(control: .mute, verdict: .blinking),
            .state(false, ledBlinking: true)
        )
    }

    // MARK: A steady LED is the state, both ways

    func testSteadyMuteDecidesBothDirections() {
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .mute, verdict: .steady(lit: true), requested: true
            ),
            .alreadySet(ledBlinking: false)
        )
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .mute, verdict: .steady(lit: true), requested: false
            ),
            .press(currentlyOn: true, ledBlinking: false)
        )
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .mute, verdict: .steady(lit: false), requested: false
            ),
            .alreadySet(ledBlinking: false)
        )
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .mute, verdict: .steady(lit: false), requested: true
            ),
            .press(currentlyOn: false, ledBlinking: false)
        )
    }

    func testSteadySoloDecidesBothDirections() {
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .solo, verdict: .steady(lit: true), requested: true
            ),
            .alreadySet(ledBlinking: false)
        )
        XCTAssertEqual(
            MCUController.toggleDecision(
                control: .solo, verdict: .steady(lit: false), requested: true
            ),
            .press(currentlyOn: false, ledBlinking: false)
        )
    }

    // MARK: The two answers that are not states

    /// No sample at all is NEVER `steady(lit: false)`. The route hands the write
    /// to the inspector strip rather than inventing an unmuted reading.
    func testNoWindowCapturedIsUnreadableForBothControls() {
        for control in [BridgeCommandName.mute, .solo] {
            XCTAssertEqual(
                MCUController.toggleReading(control: control, verdict: .unsampled), .unreadable
            )
            for requested in [true, false] {
                XCTAssertEqual(
                    MCUController.toggleDecision(
                        control: control, verdict: .unsampled, requested: requested
                    ),
                    .unreadable
                )
            }
        }
    }

    /// A flashing SOLO LED has never been measured. It is refused rather than
    /// read as the phase the window happened to end in.
    func testBlinkingSoloIsRefusedNotGuessed() {
        XCTAssertEqual(
            MCUController.toggleReading(control: .solo, verdict: .blinking), .unexplainedBlink
        )
        for requested in [true, false] {
            XCTAssertEqual(
                MCUController.toggleDecision(
                    control: .solo, verdict: .blinking, requested: requested
                ),
                .unexplainedBlink
            )
        }
    }

    // MARK: Which window gets paid

    /// The blink window is bought only where a blink is possible: a mute LED
    /// with a solo standing somewhere in the project. Everything else settles.
    func testOnlyAMuteUnderAStandingSoloPaysTheBlinkWindow() {
        XCTAssertEqual(
            MCUController.toggleLEDWindow(control: .mute, soloStanding: true),
            MCUController.recBlinkWindow
        )
        XCTAssertEqual(
            MCUController.toggleLEDWindow(control: .mute, soloStanding: false),
            MCUController.settledLEDWindow
        )
        XCTAssertEqual(
            MCUController.toggleLEDWindow(control: .solo, soloStanding: true),
            MCUController.settledLEDWindow
        )
        XCTAssertEqual(
            MCUController.toggleLEDWindow(control: .solo, soloStanding: nil),
            MCUController.settledLEDWindow
        )
    }

    /// A surface that could not be asked takes the long window: nil is not the
    /// same answer as "nothing is soloed".
    func testUnknownSoloStateTakesTheLongWindow() {
        XCTAssertEqual(
            MCUController.toggleLEDWindow(control: .mute, soloStanding: nil),
            MCUController.recBlinkWindow
        )
    }

    /// The window has to outlast one FULL blink cycle, or a window opening just
    /// after an edge sees a single edge and calls a flashing LED steady — which
    /// is the defect, restored. The mute blink's phase measures ~733 ms and the
    /// slowest gap seen was 741 ms (2026-09-02), so the bound is 1 482 ms.
    func testTheBlinkWindowOutlastsAWholeMuteBlinkCycle() {
        XCTAssertGreaterThan(MCUController.recBlinkWindow, 2 * 0.741)
        // …and the settle window deliberately does NOT reach it: it is only
        // ever taken where note 0x73 has said nothing can be blinking.
        XCTAssertLessThan(MCUController.settledLEDWindow, 2 * 0.741)
    }

    /// And it is long enough to hold the two edges `ledSteadiness` needs, at any
    /// phase: the worst case is a window that opens one sample after an edge.
    func testABlinkSampledAcrossTheBlinkWindowIsClassifiedBlinking() {
        let note = MCUController.muteLEDBase + 3
        let perPhase = Int((0.741 / MCUController.ledSampleInterval).rounded())
        let count = Int((MCUController.recBlinkWindow / MCUController.ledSampleInterval))
        for offset in 0..<(2 * perPhase) {
            let samples = (0..<count).map { index -> Set<Int> in
                ((index + offset) / perPhase) % 2 == 0 ? [note] : []
            }
            XCTAssertEqual(
                MCUController.ledSteadiness(note, across: samples), .blinking,
                "phase offset \(offset) sampled as steady"
            )
        }
    }
}
