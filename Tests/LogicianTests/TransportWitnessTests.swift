import XCTest
@testable import Logician

/// The witness matrix behind `logic_set_playing`: the MCU play/stop LED pair,
/// the control bar's own Play checkbox, and whether the MCU position display
/// is advancing.
///
/// Every case below was a live observation before it was a test. On
/// 2026-09-03 two agents independently caught the play LED lying — once with
/// BOTH transport lamps lit while the control bar read `playing: false`, once
/// left permanently lit by a Logic that had auto-stopped at the end of the
/// timeline. The tool believed the bit: `already_playing` returned in 4 ms
/// with nothing pressed, and the next stop request pressed stop at an
/// already-stopped Logic — which is REWIND, not stop (the playhead went 41 →
/// 8 → 1) — and then spent 2.48-2.56 s, 3/3, waiting for an LED transition
/// that a no-op press never produces, before throwing.
///
/// A desynced surface cannot be arranged from a unit test, so the arbitration
/// is pure and the whole matrix is pinned here instead
/// (`profiles/logic_set_playing.md`, DEFECT + N1 + N2 + C1).
final class TransportWitnessTests: XCTestCase {

    private func evidence(
        play: Bool, stop: Bool, ax: Bool? = nil, moving: Bool? = nil
    ) -> TransportEvidence {
        TransportEvidence(playLED: play, stopLED: stop, ax: ax, positionMoving: moving)
    }

    // MARK: The LED pair on its own

    func testTheLEDPairReadsPlayStopBothOrNeither() {
        XCTAssertEqual(evidence(play: true, stop: false).ledReading, "play")
        XCTAssertEqual(evidence(play: false, stop: true).ledReading, "stop")
        XCTAssertEqual(evidence(play: true, stop: true).ledReading, "both")
        XCTAssertEqual(evidence(play: false, stop: false).ledReading, "neither")
    }

    /// The reason the STOP lamp is read at all: one bit cannot tell "Logic
    /// says stopped" from "Logic never said anything", and it cannot notice
    /// the impossible pair that was actually observed live.
    func testOnlyAnUnambiguousPairIsAWitness() {
        XCTAssertEqual(evidence(play: true, stop: false).ledPlaying, true)
        XCTAssertEqual(evidence(play: false, stop: true).ledPlaying, false)
        XCTAssertNil(evidence(play: true, stop: true).ledPlaying)
        XCTAssertNil(evidence(play: false, stop: false).ledPlaying)
    }

    // MARK: The healthy cases — nothing changes for them

    func testAllThreeWitnessesAgreeingOnPlaying() {
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: true, moving: true))
        XCTAssertEqual(verdict.playing, true)
        XCTAssertFalse(verdict.ledDesync)
        XCTAssertFalse(verdict.conflict)
        XCTAssertTrue(verdict.disagreed.isEmpty)
        XCTAssertNil(verdict.warning(desired: true, pressed: false))
    }

    func testTheLEDAndTheControlBarAgreeingOnStoppedNeedNoPositionSample() {
        let verdict = transportVerdict(evidence(play: false, stop: true, ax: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(verdict.route, "ax_play_checkbox")
        XCTAssertEqual(verdict.agreed, ["ax_play_checkbox", "mcu_transport_leds"])
        XCTAssertFalse(verdict.conflict)
    }

    // MARK: The defect, both shapes

    /// Shape one: both lamps lit at once while Logic reads stopped and the
    /// playhead is standing still.
    func testBothLampsLitIsResolvedAgainstTheLEDAndFlaggedAsDesync() {
        let verdict = transportVerdict(evidence(play: true, stop: true, ax: false, moving: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertTrue(verdict.ledDesync)
        XCTAssertTrue(verdict.conflict)
        XCTAssertEqual(transportAction(desired: false, verdict: verdict), .alreadyThere)
    }

    /// Shape two: the play lamp left lit for ever by Logic's own auto-stop.
    /// This is the exact reading that used to cost 2.5 s and a rewound
    /// playhead.
    func testAStuckPlayLampLosesToTheOtherTwoWitnesses() {
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: false, moving: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(verdict.route, "mcu_position_motion")
        XCTAssertEqual(verdict.disagreed, ["mcu_transport_leds"])
        XCTAssertTrue(verdict.ledDesync)
        XCTAssertEqual(transportAction(desired: false, verdict: verdict), .alreadyThere)
    }

    /// …and the same reading, when what the caller asked for is PLAY, is a
    /// real state change: the press happens, and pressing play is also what
    /// resyncs the lamps. Nothing here ever presses play just to repair a bit.
    func testAStuckPlayLampStillLetsARealPlayRequestPress() {
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: false, moving: false))
        XCTAssertEqual(transportAction(desired: true, verdict: verdict), .press)
    }

    // MARK: Majority, and what breaks a tie

    func testTwoWitnessesOutvoteOne() {
        // A position display that stopped receiving updates does not get to
        // overrule a control bar and an LED pair that both say "playing".
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: true, moving: false))
        XCTAssertEqual(verdict.playing, true)
        XCTAssertEqual(verdict.disagreed, ["mcu_position_motion"])
        XCTAssertFalse(verdict.ledDesync)
        XCTAssertEqual(transportAction(desired: false, verdict: verdict), .press)
    }

    /// The offline freeze render's shape: Logic drives neither the play lamp
    /// nor the position display during one (MCURender.swift:219), so a
    /// control bar reading "playing" is outvoted — which is what keeps this
    /// change from turning `render_track`'s stop calls into rewinds.
    func testAControlBarAloneDoesNotEarnAStopPress() {
        let verdict = transportVerdict(evidence(play: false, stop: true, ax: true, moving: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(verdict.disagreed, ["ax_play_checkbox"])
        XCTAssertEqual(transportAction(desired: false, verdict: verdict), .alreadyThere)
    }

    /// One against one — only reachable when the bridge stopped answering the
    /// position sample. Rank decides: the control bar over the LED.
    func testATieIsBrokenByRankNotByTheLED() {
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(verdict.route, "ax_play_checkbox")
        XCTAssertTrue(verdict.ledDesync)
    }

    func testPositionOutranksTheControlBarWhenTheLEDPairIsBroken() {
        let verdict = transportVerdict(evidence(play: true, stop: true, ax: true, moving: false))
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(verdict.route, "mcu_position_motion")
    }

    // MARK: Nobody could answer

    func testNoWitnessAtAllResolvesToNil() {
        let verdict = transportVerdict(evidence(play: false, stop: false))
        XCTAssertNil(verdict.playing)
        XCTAssertNil(verdict.route)
        XCTAssertFalse(verdict.ledDesync)
        XCTAssertFalse(verdict.conflict, "an unlit pair is a witness with no opinion, not a conflict")
    }

    func testAnImpossiblePairWithNoOtherWitnessIsStillFlagged() {
        let verdict = transportVerdict(evidence(play: true, stop: true))
        XCTAssertNil(verdict.playing)
        XCTAssertTrue(verdict.ledDesync)
        XCTAssertTrue(verdict.conflict)
    }

    // MARK: The press decision

    func testAnUnresolvableStateStillPressesPlayButNeverStop() {
        let verdict = transportVerdict(evidence(play: false, stop: false))
        XCTAssertEqual(transportAction(desired: true, verdict: verdict), .press)
        XCTAssertEqual(
            transportAction(desired: false, verdict: verdict), .unresolved,
            "a stop press at an already-stopped transport is Logic's rewind — never on a guess"
        )
    }

    /// The property the playhead's safety rests on, over the whole matrix: a
    /// stop is pressed only when the witnesses actually concluded "playing".
    func testAStopIsNeverPressedUnlessTheVerdictSaysPlaying() {
        let booleans: [Bool?] = [nil, true, false]
        for play in [true, false] {
            for stop in [true, false] {
                for ax in booleans {
                    for moving in booleans {
                        let verdict = transportVerdict(
                            evidence(play: play, stop: stop, ax: ax, moving: moving)
                        )
                        if transportAction(desired: false, verdict: verdict) == .press {
                            XCTAssertEqual(
                                verdict.playing, true,
                                "pressed stop on \(verdict.evidence)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testEveryCombinationResolvesToExactlyOneAction() {
        let booleans: [Bool?] = [nil, true, false]
        for play in [true, false] {
            for stop in [true, false] {
                for ax in booleans {
                    for moving in booleans {
                        let verdict = transportVerdict(
                            evidence(play: play, stop: stop, ax: ax, moving: moving)
                        )
                        for desired in [true, false] {
                            let action = transportAction(desired: desired, verdict: verdict)
                            switch action {
                            case .alreadyThere: XCTAssertEqual(verdict.playing, desired)
                            case .press: XCTAssertNotEqual(verdict.playing, desired)
                            case .unresolved:
                                XCTAssertNil(verdict.playing)
                                XCTAssertFalse(desired)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: What the caller is told

    func testAWithheldStopSaysWhyNothingWasPressed() {
        let verdict = transportVerdict(evidence(play: true, stop: false, ax: false, moving: false))
        let warning = verdict.warning(desired: false, pressed: false)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("rewind"), warning ?? "")
        XCTAssertTrue(warning!.contains("nothing was pressed"), warning ?? "")
    }

    func testAPressedWriteNamesTheWitnessThatConfirmedIt() {
        let verdict = transportVerdict(evidence(play: false, stop: true, ax: true, moving: true))
        let warning = verdict.warning(desired: true, pressed: true)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("mcu_position_motion"), warning ?? "")
    }

    func testACleanReadingCarriesNoWarning() {
        for (play, stop, state) in [(true, false, true), (false, true, false)] {
            let verdict = transportVerdict(evidence(play: play, stop: stop, ax: state, moving: state))
            XCTAssertNil(verdict.warning(desired: state, pressed: false))
            XCTAssertNil(verdict.warning(desired: state, pressed: true))
        }
    }

    func testThePayloadReportsUnreadWitnessesAsNullNotAsFalse() {
        let payload = transportVerdict(evidence(play: false, stop: true)).payload()
        XCTAssertEqual(payload["mcu_transport_leds"] as? String, "stop")
        XCTAssertTrue(payload["ax_play_checkbox"] is NSNull)
        XCTAssertTrue(payload["mcu_position_motion"] is NSNull)
    }

    func testThePayloadSpellsOutEveryReading() {
        let payload = transportVerdict(
            evidence(play: true, stop: false, ax: true, moving: true)
        ).payload()
        XCTAssertEqual(payload["mcu_transport_leds"] as? String, "play")
        XCTAssertEqual(payload["ax_play_checkbox"] as? Bool, true)
        XCTAssertEqual(payload["mcu_position_motion"] as? String, "moving")
    }

    func testTheNoteNamesEveryWitnessThatWasRead() {
        let note = transportVerdict(
            evidence(play: true, stop: true, ax: false, moving: false)
        ).note
        XCTAssertTrue(note.contains("'both'"), note)
        XCTAssertTrue(note.contains("Play checkbox reads stopped"), note)
        XCTAssertTrue(note.contains("standing still"), note)
    }

    func testTheNoteSaysWhenTheControlBarCouldNotBeRead() {
        let note = transportVerdict(evidence(play: true, stop: false, moving: true)).note
        XCTAssertTrue(note.contains("could not be read"), note)
    }

    // MARK: How many witnesses get paid for

    func testThePositionIsNotSampledWhenTheCheapWitnessesAgree() {
        var positionSamples = 0
        let verdict = MCUController.observeTransport(
            status: ["leds_lit": [0x5D]],
            ax: { false },
            positionMoving: { positionSamples += 1; return false }
        )
        XCTAssertEqual(verdict.playing, false)
        XCTAssertEqual(positionSamples, 0, "the sample window must not be paid on the healthy path")
    }

    func testThePositionIsSampledWhenTheLEDAndTheControlBarDisagree() {
        var positionSamples = 0
        let verdict = MCUController.observeTransport(
            status: ["leds_lit": [0x5E]],
            ax: { false },
            positionMoving: { positionSamples += 1; return false }
        )
        XCTAssertEqual(positionSamples, 1)
        XCTAssertEqual(verdict.playing, false)
        XCTAssertTrue(verdict.ledDesync)
    }

    func testThePositionIsSampledWhenTheControlBarCannotBeRead() {
        var positionSamples = 0
        _ = MCUController.observeTransport(
            status: ["leds_lit": [0x5D]],
            ax: { nil },
            positionMoving: { positionSamples += 1; return false }
        )
        XCTAssertEqual(positionSamples, 1)
    }

    func testThePositionIsSampledWhenTheLampsContradictThemselves() {
        var positionSamples = 0
        let verdict = MCUController.observeTransport(
            status: ["leds_lit": [0x5D, 0x5E]],
            ax: { true },
            positionMoving: { positionSamples += 1; return true }
        )
        XCTAssertEqual(positionSamples, 1)
        XCTAssertEqual(verdict.playing, true)
        XCTAssertTrue(verdict.ledDesync)
    }

    // MARK: C1 — the poll budget the deadline actually keeps

    func testARoundIsCappedToWhateverIsLeftOfTheBudget() {
        XCTAssertEqual(MCUController.waitRoundTimeoutMs(remaining: 2.0), 350)
        XCTAssertEqual(MCUController.waitRoundTimeoutMs(remaining: 0.2), 200)
        XCTAssertEqual(MCUController.waitRoundTimeoutMs(remaining: 0.35), 350)
    }

    func testASpentBudgetStartsNoFurtherRound() {
        XCTAssertNil(MCUController.waitRoundTimeoutMs(remaining: 0))
        XCTAssertNil(MCUController.waitRoundTimeoutMs(remaining: -1.2))
        XCTAssertNil(MCUController.waitRoundTimeoutMs(remaining: 0.0004))
    }

    /// The overshoot itself: rounds of a fixed 350 ms against a 2.25 s budget
    /// ran to 2.45 s before this, which is where the ledger's measured
    /// 2.48-2.56 s timeouts came from. Capped rounds land ON the budget.
    func testTheRoundsSumToTheBudgetInsteadOfOvershootingIt() {
        var remaining = 2.25
        var spent = 0.0
        while let timeoutMs = MCUController.waitRoundTimeoutMs(remaining: remaining) {
            spent += Double(timeoutMs) / 1000
            remaining -= Double(timeoutMs) / 1000
        }
        XCTAssertEqual(spent, 2.25, accuracy: 0.001)
    }

    // MARK: transport_stop — the cleanup stop's verdict, no longer discarded
    //
    // `logic_record_midi`, `logic_record_automation` and `logic_render_track`
    // all press `setPlaying(false)` on their way out through `try?`, which
    // used to throw away whatever it answered. `transportStopReport` is the
    // pure shaping step between that outcome and the `transport_stop` field
    // those three tools now report, so every shape is pinned here without
    // Logic running.

    func testAConfirmedStopReportsItsStateWitnessesAndNoDesync() {
        let (payload, warning) = transportStopReport(.result([
            "success": true, "verified": true, "state": "stopped", "playing": false,
            "readback_route": "mcu_transport_led",
            "transport_witnesses": ["mcu_transport_leds": "stop", "ax_play_checkbox": NSNull(), "mcu_position_motion": NSNull()]
        ]))
        XCTAssertEqual(payload["state"] as? String, "stopped")
        XCTAssertEqual(payload["led_desync"] as? Bool, false)
        XCTAssertNotNil(payload["transport_witnesses"])
        XCTAssertNil(warning)
    }

    /// A verified no-op — `setPlaying(false)` found the transport already
    /// stopped and pressed nothing — is not an error, and still reports a
    /// full shape.
    func testAnAlreadyStoppedVerdictReportsCleanly() {
        let (payload, warning) = transportStopReport(.result([
            "success": true, "verified": true, "state": "already_stopped", "playing": false,
            "readback_route": "ax_play_checkbox",
            "transport_witnesses": ["mcu_transport_leds": "neither", "ax_play_checkbox": false, "mcu_position_motion": NSNull()]
        ]))
        XCTAssertEqual(payload["state"] as? String, "already_stopped")
        XCTAssertEqual(payload["led_desync"] as? Bool, false)
        XCTAssertNil(warning)
    }

    /// The LED never echoed, but a fallback witness confirmed the stop
    /// anyway: `led_desync` is true and the warning `setPlaying` itself wrote
    /// is what surfaces — that used to vanish behind `try?` entirely.
    func testALedDesyncedStopCarriesItsWarningThrough() {
        let (payload, warning) = transportStopReport(.result([
            "success": true, "verified": true, "state": "stopped", "playing": false,
            "readback_route": "ax_play_checkbox", "led_desync": true,
            "warning": "The control surface's play/stop LEDs never echoed the press",
            "transport_witnesses": ["mcu_transport_leds": "play", "ax_play_checkbox": false, "mcu_position_motion": NSNull()]
        ]))
        XCTAssertEqual(payload["led_desync"] as? Bool, true)
        XCTAssertEqual(warning, "The control surface's play/stop LEDs never echoed the press")
    }

    /// No control surface at all: house style names the reason rather than
    /// returning an empty dictionary, and there is nothing to warn about — a
    /// tool with no surface has already failed elsewhere.
    func testAnUnreachableSurfaceNamesWhyInsteadOfAnEmptyPayload() {
        let (payload, warning) = transportStopReport(
            .unavailable("the play/stop transport buttons on the control surface were not reachable")
        )
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["unavailable"] as? String, "the play/stop transport buttons on the control surface were not reachable")
        XCTAssertNil(warning)
    }

    /// The fix's whole point: a stop REFUSED because no witness could say the
    /// transport was rolling (pressing would have been Logic's
    /// rewind-to-bar-1) is reported, not silently swallowed — and it always
    /// earns a warning, unconditionally.
    func testARefusedStopIsReportedAndAlwaysWarns() {
        let (payload, warning) = transportStopReport(.refused(
            "not one of the three witnesses could say whether Logic is playing"
        ))
        XCTAssertEqual(payload["state"] as? String, "refused")
        XCTAssertEqual(payload["reason"] as? String, "not one of the three witnesses could say whether Logic is playing")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("not one of the three witnesses"), warning ?? "")
    }

    /// A press that landed but that not even the fallback witnesses could
    /// confirm — `setPlaying`'s `verificationFailed` throw — is the other
    /// thrown shape, and it is reported the same way as a refusal: something
    /// is unconfirmed about the transport and the caller must not assume it
    /// stopped silently.
    func testAnUnconfirmedPressIsReportedLikeARefusal() {
        let (payload, warning) = transportStopReport(.refused(
            "the play LED never echoed the press and stopped could not be confirmed"
        ))
        XCTAssertEqual(payload["state"] as? String, "refused")
        XCTAssertNotNil(warning)
    }
}
