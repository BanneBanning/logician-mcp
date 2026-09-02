import XCTest
@testable import Logician

/// The blink rule: a strip whose LED DIFFERS across a window is not in a
/// state, and which way that cuts depends on what the LED means.
///
/// This is the defect the reference project proved on 2026-09-02 with nothing
/// muted anywhere: one soloed track (`Bas`) and `logic_mixer_snapshot` came
/// back with six strips `"muted": true`, because Logic blinks the mute LED of
/// every channel a solo silences and the tool read one instantaneous frame of
/// it. An agent asked to undo a solo pass would have pressed mute on six
/// channels that were never muted.
///
/// Every rule here is a pure function of a sample sequence, so the sequences
/// no live surface can be asked to produce on demand — a perfectly aligned
/// blink, a repaint that lands one sample late, a window that caught nothing —
/// are exercised here rather than watched.
final class LEDWindowEvidenceTests: XCTestCase {

    /// Samples as the mirror hands them over: one lit-note set per read.
    private func samples(_ pattern: [Bool], note: Int) -> [Set<Int>] {
        pattern.map { $0 ? Set([note]) : Set<Int>() }
    }

    /// A blink across `MCUController.recBlinkWindow` at 60 ms per sample:
    /// ~640 ms on, ~640 ms off (measured 2026-08-28), so ~11 samples a phase.
    private func blinkPattern(samples count: Int = 27) -> [Bool] {
        (0..<count).map { ($0 / 11) % 2 == 0 }
    }

    // MARK: - The classifier

    func testAnLEDLitInEverySampleIsSteady() {
        let lit = samples(Array(repeating: true, count: 27), note: MCUController.muteLEDBase)
        XCTAssertEqual(
            MCUController.ledSteadiness(MCUController.muteLEDBase, across: lit),
            .steady(lit: true)
        )
    }

    func testAnLEDLitInNoSampleIsSteadilyOff() {
        let dark = samples(Array(repeating: false, count: 27), note: MCUController.muteLEDBase)
        XCTAssertEqual(
            MCUController.ledSteadiness(MCUController.muteLEDBase, across: dark),
            .steady(lit: false)
        )
    }

    /// TWO edges is the proof, and a 1.6 s window over a 640 ms phase always
    /// contains at least two. Whichever phase the window starts in.
    func testABlinkIsTwoEdgesWhicheverPhaseTheWindowStartsIn() {
        let note = MCUController.muteLEDBase + 3
        for offset in 0..<22 {
            let pattern = blinkPattern().enumerated().map { index, _ in
                ((index + offset) / 11) % 2 == 0
            }
            XCTAssertEqual(
                MCUController.ledSteadiness(note, across: samples(pattern, note: note)),
                .blinking,
                "a blink starting at sample offset \(offset) must classify as blinking"
            )
        }
    }

    /// ONE edge is not a blink. Logic's LED repaint after a bank step lands a
    /// few samples into the window, and a rule that demanded "lit in every
    /// sample" would report a genuinely muted strip as unmuted whenever its
    /// repaint was late — the same silent wrongness pointing the other way.
    func testAStateThatArrivesDuringTheWindowIsTheStateTheWindowEndsIn() {
        let note = MCUController.muteLEDBase
        let late = [false, false, false] + Array(repeating: true, count: 24)
        XCTAssertEqual(
            MCUController.ledSteadiness(note, across: samples(late, note: note)),
            .steady(lit: true)
        )
        let cleared = [true, true] + Array(repeating: false, count: 25)
        XCTAssertEqual(
            MCUController.ledSteadiness(note, across: samples(cleared, note: note)),
            .steady(lit: false)
        )
    }

    func testNoSamplesIsUnsampledAndNotOff() {
        XCTAssertEqual(MCUController.ledSteadiness(0x10, across: []), .unsampled)
        // The distinction has to survive into the decode: a window that caught
        // nothing must not become eight strips reading false.
        XCTAssertNil(MCUController.decodeBankLEDs(samples: [], includeRecordArm: true))
    }

    // MARK: - The two evidence rules, from one window

    /// The live failure, replayed: strip 1 genuinely muted, strips 3 and 4
    /// blinking because a solo on strip 2 silences them.
    func testAStandingSoloDoesNotMakeSixStripsMuted() {
        let window: [Set<Int>] = blinkPattern().map { blinkIsOn in
            var lit: Set<Int> = [
                // Strip 1 is really muted: its LED never moves.
                MCUController.muteLEDBase + 0,
                // The soloed strip's own solo LED is steady, and so is the
                // whole-project indicator.
                MCUController.soloLEDBase + 1,
                MCUController.rudeSoloLED
            ]
            if blinkIsOn {
                lit.insert(MCUController.muteLEDBase + 2)
                lit.insert(MCUController.muteLEDBase + 3)
            }
            return lit
        }
        let reading = MCUController.decodeBankLEDs(samples: window, includeRecordArm: false)
        XCTAssertEqual(reading?.muted, [0])
        XCTAssertEqual(reading?.muteBlinking, [2, 3])
        XCTAssertEqual(reading?.soloed, [1])
        XCTAssertEqual(reading?.unexpectedBlinks, [])
        // And the rows say it: silenced right now, not muted, and marked.
        guard let reading else { return XCTFail("no reading") }
        XCTAssertEqual(
            MCUController.ledRowFields(channel: 2, reading: reading)["muted"] as? Bool, false
        )
        XCTAssertEqual(
            MCUController.ledRowFields(channel: 2, reading: reading)["mute_led_blinking"] as? Bool,
            true
        )
        // A real mute is unmarked and true.
        XCTAssertEqual(
            MCUController.ledRowFields(channel: 0, reading: reading)["muted"] as? Bool, true
        )
        XCTAssertNil(MCUController.ledRowFields(channel: 0, reading: reading)["mute_led_blinking"])
    }

    /// Record-arm keeps the OPPOSITE rule out of the same samples: Logic
    /// flashes an armed strip's rec LED, so a blink is the armed answer.
    func testRecordArmTakesTheBlinkAsTheArmedAnswer() {
        let blink = blinkPattern()
        let window = blink.map { lit in
            lit ? Set([MCUController.recArmLEDBase + 6]) : Set<Int>()
        }
        let reading = MCUController.decodeBankLEDs(samples: window, includeRecordArm: true)
        XCTAssertEqual(reading?.recordArmed, [6])
        // Same samples, mute rule: the rec LED is not a mute LED and nothing
        // bleeds between the eight-wide rows.
        XCTAssertEqual(reading?.muted, [])
        XCTAssertEqual(reading?.muteBlinking, [])
    }

    /// A solo or select LED that blinks has never been measured. It is
    /// reported as unexpected rather than published as a state.
    func testAnUnexpectedBlinkIsNamedRatherThanGuessedAt() {
        let blink = blinkPattern()
        let window = blink.map { lit in lit ? Set([MCUController.soloLEDBase]) : Set<Int>() }
        let reading = MCUController.decodeBankLEDs(samples: window, includeRecordArm: false)
        XCTAssertEqual(reading?.soloed, [])
        XCTAssertEqual(reading?.unexpectedBlinks, ["solo"])
    }

    // MARK: - The opt-out shape

    /// ABSENT, never false. The same house rule `meter_level` already keeps:
    /// a field the call did not ask about must not read as a state read.
    func testRecordArmIsAbsentRatherThanFalseWhenNotAskedFor() {
        let window = [Set<Int>([MCUController.recArmLEDBase])]
        let asked = MCUController.decodeBankLEDs(samples: window, includeRecordArm: true)
        let notAsked = MCUController.decodeBankLEDs(samples: window, includeRecordArm: false)
        XCTAssertNotNil(asked?.recordArmed)
        XCTAssertNil(notAsked?.recordArmed)
        guard let asked, let notAsked else { return XCTFail("no reading") }
        // Asked for and not armed is an explicit false; not asked for is no key.
        XCTAssertEqual(
            MCUController.ledRowFields(channel: 4, reading: asked)["record_armed"] as? Bool, false
        )
        XCTAssertEqual(
            MCUController.ledRowFields(channel: 0, reading: asked)["record_armed"] as? Bool, true
        )
        XCTAssertNil(MCUController.ledRowFields(channel: 0, reading: notAsked)["record_armed"])
        // The other three fields are always answered.
        for channel in [0, 4] {
            for key in ["muted", "soloed", "selected"] {
                XCTAssertNotNil(
                    MCUController.ledRowFields(channel: channel, reading: notAsked)[key],
                    "\(key) must be answered even when record-arm is not"
                )
            }
        }
    }

    /// What the opt-out actually buys, and what it cannot buy: the blink
    /// window is also the evidence behind `muted`, so a standing solo keeps
    /// paying for it.
    func testTheShortWindowIsOnlyTakenWhenNothingCanBeBlinking() {
        XCTAssertEqual(
            MCUController.ledWindowSeconds(includeRecordArm: false, soloStanding: false),
            MCUController.settledLEDWindow
        )
        XCTAssertEqual(
            MCUController.ledWindowSeconds(includeRecordArm: false, soloStanding: true),
            MCUController.recBlinkWindow
        )
        XCTAssertEqual(
            MCUController.ledWindowSeconds(includeRecordArm: true, soloStanding: false),
            MCUController.recBlinkWindow
        )
        // The surface could not be asked: take the answer that stays correct.
        XCTAssertEqual(
            MCUController.ledWindowSeconds(includeRecordArm: false, soloStanding: nil),
            MCUController.recBlinkWindow
        )
        // And the short window must be too short to classify a blink, which is
        // exactly why it is gated on "no solo standing".
        XCTAssertLessThan(MCUController.settledLEDWindow, MCUController.recBlinkWindow)
    }

    /// The short window's own settle: the dB row it hands to the reader has to
    /// have stopped moving, or the value belongs to the previous bank.
    func testTheValueRowIsProvenSettledRatherThanAssumed() {
        XCTAssertFalse(MCUController.valueRowHeld([]))
        XCTAssertFalse(MCUController.valueRowHeld(["-6,0 dB"]))
        XCTAssertFalse(MCUController.valueRowHeld(["-6,0 dB", "-12,0 dB"]))
        XCTAssertTrue(MCUController.valueRowHeld(["-6,0 dB", "-12,0 dB", "-12,0 dB"]))
    }
}
