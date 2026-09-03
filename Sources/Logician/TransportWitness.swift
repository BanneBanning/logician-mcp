import Foundation

// Who gets to say whether Logic is playing.
//
// `logic_set_playing` used to answer that question — for BOTH directions, and
// for the `already_*` no-op that skips the press entirely — from ONE bit: the
// MCU play LED, note 0x5E. That bit can be wrong, and it can STAY wrong.
// Reproduced live twice on 2026-09-03, by two agents, on two different
// triggers (profiles/logic_set_playing.md, DEFECT + N1):
//
//   * both note 93 (Stop) and note 94 (Play) lit at the same time — a pair
//     that corresponds to no real transport state — while the control bar's
//     own Play checkbox read `playing: false`;
//   * Logic auto-stopping at the end of the timeline leaves the play LED lit
//     with no corrective note-off ever arriving.
//
// The consequences were both silent and expensive. `already_playing` fired as
// a FALSE POSITIVE in 4.0/4.4 ms with nothing pressed, so the caller believed
// Logic was rolling. The next `setPlaying(false)` pressed stop against an
// already-stopped Logic — which is Logic's REWIND, not a stop: the playhead
// went 41 → ~8 → 1 — and then burned its full poll budget (2555.7/2483.6/
// 2479.4 ms, 3/3) waiting for an LED transition that a no-op press can never
// produce, before throwing `verification_failed` at a caller whose transport
// was in exactly the state it had asked for. Only a REAL play transition
// resyncs the pair, so the bit never heals on its own.
//
// So the state is settled by three independent witnesses instead of one:
//
//   | witness               | what it sees                        | cost |
//   |-----------------------|-------------------------------------|------|
//   | `mcu_position_motion` | the MCU position display advancing  | ~0 ms when the transport is rolling (the first position tick answers), one sample window when it is not |
//   | `ax_play_checkbox`    | the control bar's own Play checkbox | one shallow AX walk |
//   | `mcu_transport_leds`  | notes 0x5E/0x5D as a PAIR           | free (already in the mirror) |
//
// Nothing here talks to Logic, the bridge or the Accessibility tree: the
// arbitration is pure, so the whole witness matrix — LED says X, the control
// bar says Y, the position is moving or still — is unit-tested without a live
// session (`TransportWitnessTests`). `MCUController.observeTransport` is the
// one place that binds these to real reads, and it decides how MANY witnesses
// to pay for.

/// What each witness said. `nil` means that witness could not answer at all
/// (the control bar was unreadable, the position was never sampled, the LED
/// pair is self-contradictory) — never "no".
struct TransportEvidence: Equatable {
    /// Note 0x5E.
    var playLED: Bool
    /// Note 0x5D. Read as the play LED's PARTNER: Logic lights exactly one of
    /// the two, so "both" and "neither" are readings about the mirror rather
    /// than about the transport.
    var stopLED: Bool
    /// The control bar's Play checkbox, or nil when the control bar could not
    /// be read (Accessibility not trusted, no project window, a modal).
    var ax: Bool?
    /// Whether the MCU position display advanced inside the sample window, or
    /// nil when it was not sampled (the cheap witnesses already agreed) or the
    /// bridge did not answer.
    var positionMoving: Bool?

    /// The LED PAIR's reading, which is the whole point of reading the stop
    /// LED as well: one bit cannot tell "Logic says stopped" from "Logic never
    /// told us". `nil` for both-lit (impossible) and neither-lit (the mirror
    /// has no transport opinion yet).
    var ledPlaying: Bool? {
        if playLED == stopLED { return nil }
        return playLED
    }

    /// How the pair reads, for the result payload and the warning sentence.
    var ledReading: String {
        switch (playLED, stopLED) {
        case (true, true): return "both"
        case (true, false): return "play"
        case (false, true): return "stop"
        case (false, false): return "neither"
        }
    }
}

/// The arbitrated answer, plus everything a caller needs to disbelieve it.
struct TransportVerdict: Equatable {
    /// The state the witnesses settled on, or nil when not one of them could
    /// answer. A `nil` here is never turned into a stop press — see
    /// `MCUController.transportAction`.
    var playing: Bool?
    /// Which witness the verdict is quoted from.
    var route: String?
    /// Witnesses that answered the same way, in rank order.
    var agreed: [String]
    /// Witnesses that answered the other way.
    var disagreed: [String]
    /// The readings themselves, so nothing about the decision is hidden.
    var evidence: TransportEvidence
    /// The LED pair contradicts the verdict, or contradicts itself. This is
    /// the flag the defect above is diagnosed by, and it is reported to the
    /// caller as `led_desync`.
    var ledDesync: Bool
    /// Any disagreement at all among the witnesses that answered, plus the
    /// self-contradicting LED pair. A pair with NEITHER lamp lit is not a
    /// conflict — it is a witness with no opinion, like an unreadable control
    /// bar, and warning about it on every call of a session that has not
    /// touched the transport yet would be noise.
    var conflict: Bool { !disagreed.isEmpty || (evidence.playLED && evidence.stopLED) }

    /// One sentence naming what each witness said. Written for a human
    /// reading a warning or a refusal, not for parsing.
    var note: String {
        var parts: [String] = []
        parts.append("the surface's play/stop LEDs read '\(evidence.ledReading)'")
        parts.append(evidence.ax.map {
            "the control bar's Play checkbox reads \($0 ? "playing" : "stopped")"
        } ?? "the control bar's Play checkbox could not be read")
        if let moving = evidence.positionMoving {
            parts.append("the MCU position display is \(moving ? "advancing" : "standing still")")
        }
        return parts.joined(separator: ", ")
    }

    /// The witness readings as a result field.
    func payload() -> [String: Any] {
        [
            TransportWitnessName.leds: evidence.ledReading,
            TransportWitnessName.ax: evidence.ax.map { $0 as Any } ?? NSNull() as Any,
            TransportWitnessName.position: evidence.positionMoving
                .map { ($0 ? "moving" : "still") as Any } ?? NSNull() as Any
        ]
    }

    /// What to tell the caller when the witnesses did not all say the same
    /// thing. nil on the clean path, which is nearly every call.
    ///
    /// `pressed` matters because the two situations need opposite sentences:
    /// a press that landed was simply verified through a different witness,
    /// while a press that was WITHHELD is the fix for the defect and has to
    /// say so — a caller who asked for a stop and got `already_stopped` with a
    /// desynced play LED must not read that as the tool having given up.
    func warning(desired: Bool, pressed: Bool) -> String? {
        guard conflict else { return nil }
        let heading = ledDesync
            ? "The control surface's play/stop LEDs disagree with Logic itself"
            : "Logic's transport witnesses did not all agree"
        if pressed {
            return heading + " (\(note)), so the state BEFORE the press was settled by"
                + " \(route ?? "no witness") rather than by the lamps, and the press went ahead."
        }
        if desired {
            return heading + " (\(note)). Playback was already running by every witness that"
                + " outvoted the LED, so nothing was pressed."
        }
        return heading + " (\(note)), so Logic is already stopped and nothing was pressed:"
            + " pressing stop at an already-stopped transport is Logic's rewind-to-bar-1 and"
            + " would have MOVED the playhead. The LED pair resyncs by itself on the next real"
            + " play."
    }
}

/// The witness names, used as `readback_route` values and as the keys of the
/// `transport_witnesses` payload.
enum TransportWitnessName {
    static let position = "mcu_position_motion"
    static let ax = "ax_play_checkbox"
    static let leds = "mcu_transport_leds"
}

/// Settles the three readings into one answer.
///
/// MAJORITY of the witnesses that answered, with the rank
/// `position → control bar → LED` breaking a tie. Both halves of that are
/// deliberate:
///
/// * majority, because two witnesses agreeing beats one contradicting them —
///   an LED pair AND a control bar that both read "playing" outvote a
///   position display that simply stopped receiving updates;
/// * position first, because an advancing position display is direct evidence
///   that the transport is rolling and a standing one is direct evidence that
///   it is not, whereas the LED is the bit this whole file exists because of.
///   It also keeps the offline freeze render honest: Logic drives neither the
///   play LED nor the position display during one (MCURender.swift:219,
///   measured 2026-09-02), so a control bar that reads "playing" there does
///   not on its own earn a stop press.
///
/// Pure: no bridge, no Accessibility, no clock.
func transportVerdict(_ evidence: TransportEvidence) -> TransportVerdict {
    let ranked: [(name: String, value: Bool?)] = [
        (TransportWitnessName.position, evidence.positionMoving),
        (TransportWitnessName.ax, evidence.ax),
        (TransportWitnessName.leds, evidence.ledPlaying)
    ]
    let answers = ranked.compactMap { entry in entry.value.map { (entry.name, $0) } }
    guard let first = answers.first else {
        return TransportVerdict(
            playing: nil, route: nil, agreed: [], disagreed: [],
            evidence: evidence, ledDesync: evidence.playLED && evidence.stopLED
        )
    }
    let playingVotes = answers.filter { $0.1 }.count
    let stoppedVotes = answers.count - playingVotes
    let decided = playingVotes == stoppedVotes ? first.1 : playingVotes > stoppedVotes
    let agreed = answers.filter { $0.1 == decided }.map(\.0)
    let disagreed = answers.filter { $0.1 != decided }.map(\.0)
    let ledDesync = (evidence.playLED && evidence.stopLED)
        || (evidence.ledPlaying.map { $0 != decided } ?? false)
    return TransportVerdict(
        playing: decided,
        route: agreed.first,
        agreed: agreed,
        disagreed: disagreed,
        evidence: evidence,
        ledDesync: ledDesync
    )
}

/// What `setPlaying` should DO about a verdict.
enum TransportAction: Equatable {
    /// The transport is not where the caller wants it: press.
    case press
    /// It already is: a verified no-op, no press.
    case alreadyThere
    /// Not one witness could say, and the requested direction is the
    /// destructive one. Refuse rather than guess — see below.
    case unresolved
}

/// The press decision, kept pure and separate from the verdict so the
/// asymmetry between the two directions is stated once, here.
///
/// A play press against an already-playing Logic is a no-op with no side
/// effect, so an unresolvable state still gets its press: the worst case is a
/// press that changes nothing and a readback that then tells the truth. A STOP
/// press against an already-stopped Logic is not a no-op — it is Logic's
/// rewind-to-bar-1, the exact side effect that moved a live session's playhead
/// from bar 41 to bar 1 on 2026-09-03. So a stop is never pressed on a guess.
func transportAction(desired: Bool, verdict: TransportVerdict) -> TransportAction {
    guard let playing = verdict.playing else { return desired ? .press : .unresolved }
    return playing == desired ? .alreadyThere : .press
}
