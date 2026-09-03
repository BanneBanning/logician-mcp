import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// What the MCU's 10-digit 7-segment display is currently showing.
///
/// The display has two modes — bars/beats or SMPTE — and the wire protocol
/// carries **no mode bit**: ten CC messages (0x40–0x49) paint ten digits
/// (`Bridge.swift`), and nothing says whether they mean
/// bars/beats/divisions/ticks or hours/minutes/seconds/frames. Everything
/// that synchronises against a bar therefore has to judge the digits
/// themselves, which is what this classification is for: in SMPTE mode the
/// old parse silently read hours as bars and minutes as beats, and MIDI
/// recording then synced against nonsense.
enum MCUTimecodeReading: Equatable {
    /// A plausible bars/beats position (`BBB bb dd ttt` field layout).
    /// `division`/`ticks` are 0 when Logic blanked those fields.
    case beats(bar: Int, beat: Int, division: Int, ticks: Int)
    /// No digits at all: the bridge has no status, or Logic has never painted
    /// the display. No information — not, in itself, a mode problem.
    case notReported
    /// A modal dialog has frozen the surface; Logic literally paints `ALERT`
    /// into the position display (FINDINGS, Toggle Track Freeze session), and
    /// no position exists until the dialog is dismissed.
    case alert
    /// Digits that cannot be a bars/beats position — the SMPTE case, plus any
    /// other unparseable display. `reason` names what was observed.
    case implausible(reason: String)
}

/// What a solo-bounced A/B may honestly say about the solo it worked under.
///
/// Two ways of being wrong used to be invisible here (`logic_evaluate_change`
/// profile §8, defects D1 and D3, 2026-09-01). A solo this tool switched ON and
/// could not switch off again was reported only as `solo_restored: false`, with
/// no `warning` at all on a tool registered `mayWarn: true` — and a track left
/// soloed silently poisons every later bounce in the project, which is exactly
/// what `logic_export_stems` warns about in words. And a solo already up on
/// ANOTHER track was never looked for, so both bounces contained that track
/// while the `note` went on saying they were made "with only this track soloed"
/// and the ear copies contained music the result said was not there.
///
/// Neither is a refusal. The A/B's deltas stay honest under a foreign solo,
/// because the same contamination is in A and in B — the sibling tool refuses
/// because a STEM must hold one track, which is not this tool's promise. What
/// must change is what the result says: the note, the warning, and the line
/// telling the agent what it is about to hear.
///
/// Pure, so the composition is pinned without Logic running: three facts in
/// (who else was soloed — `nil` when the track headers could not be READ, which
/// is not the same as nobody — whether this track was already soloed, and
/// whether the solo ended up restored), the result's strings out.
enum SoloBounceReport {

    struct Report {
        let note: String
        let warning: String?
        /// Appended to the ear-copy note, so "listen to both" and "what is in
        /// them" cannot disagree.
        let listenSuffix: String?
        /// The result's `solo_context`. Never an empty dictionary: a track
        /// list that could not be read says `unavailable` and why.
        let context: [String: Any]
    }

    /// Today's note, kept verbatim for the case it was always true of: this
    /// track soloed, nothing else soloed, and the headers readable enough to
    /// say so.
    static let exclusiveNote = "Two offline master bounces with only this track soloed - works on stack subtracks and shared-channel tracks that freeze refuses. Master-bus processing applies to both A and B. No playback occurred."

    private static let sharedTail = " The A/B deltas are still honest - whatever is in A is in B. Master-bus processing applies to both. No playback occurred."

    static func compose(
        trackName: String,
        preexistingSolos: [String]?,
        wasAlreadySoloed: Bool,
        soloRestored: Bool
    ) -> Report {
        let others = preexistingSolos?.filter {
            $0.caseInsensitiveCompare(trackName) != .orderedSame
        }
        let list = (others ?? []).joined(separator: ", ")
        let plural = (others ?? []).count > 1

        var note = exclusiveNote
        var listenSuffix: String?
        var warnings: [String] = []

        if let others {
            if !others.isEmpty {
                note = "Two offline master bounces with this track soloed - but \(list) "
                    + (plural ? "were" : "was") + " ALREADY soloed when the call started, so both"
                    + " bounces contain " + (plural ? "them" : "it") + " too and what you hear is"
                    + " NOT this track alone." + sharedTail
                listenSuffix = " Both copies also contain \(list), "
                    + (plural ? "which were" : "which was") + " already soloed before the A/B ran."
                warnings.append(
                    "\(list) " + (plural ? "were" : "was") + " already soloed before the A/B -"
                        + " both bounces contain " + (plural ? "them" : "it") + " as well as"
                        + " '\(trackName)', so the ear copies are not this track alone."
                        + " The deltas are unaffected; the audio is."
                )
            }
        } else {
            note = "Two offline master bounces with this track soloed - whether any OTHER track was"
                + " already soloed could NOT be read, so the bounces may contain more than this"
                + " track." + sharedTail
            listenSuffix = " Whether another track was already soloed could not be read, so both"
                + " copies may contain more than '\(trackName)'."
            warnings.append(
                "Logic's track headers could not be read before the A/B, so whether another track"
                    + " was already soloed is UNKNOWN - the bounces may contain more than"
                    + " '\(trackName)'."
            )
        }

        if !soloRestored && !wasAlreadySoloed {
            // The same sentence `logic_export_stems` uses for the same hazard.
            warnings.append(
                "'\(trackName)' is still soloed - every later bounce contains only it until that is fixed."
            )
        }

        let context: [String: Any]
        if let others {
            context = ["other_tracks_soloed": others]
        } else {
            context = ["unavailable": "Logic's track headers could not be read before the A/B"]
        }

        return Report(
            note: note,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ALSO: "),
            listenSuffix: listenSuffix,
            context: context
        )
    }
}

/// The four decisions a MIDI take makes around the recording itself, lifted out
/// of the live path so each can be pinned without Logic running. Every one of
/// them was wrong on 2026-09-02, and none of them was visible in the result:
///
/// * the SHUTDOWN aborted the MIDI stream — an all-notes-off blast on all
///   sixteen channels, into the very port Logic was recording from — BEFORE it
///   stopped the transport, so a two-note take read back through
///   `logic_list_events` as eighteen events, sixteen of them
///   `Control 64 = Sustain, 0`, measured twice;
/// * the SYNC took the pre-roll bar's beat count from the control bar's
///   signature AT THE PLAYHEAD, so on a project with a 5/4 stretch the beat
///   edge could never be observed and the take fell into the uncompensated
///   bar-line branch — silently, 39 ms late, while the same call with the
///   playhead at bar 1 landed 21.5 ms early;
/// * the PARK paid for Logic's own count-in bar, a whole extra bar of wall
///   clock (4 035 ms at 120 BPM 4/4 where 2 000 was asked for) that nothing in
///   the tool looked at although `logic_get_transport` already reports it;
/// * the RESULT named no region, while its description told the caller to
///   remove the take with Undo and `logic_delete_region` had been doing it in
///   0.7 s, 5/5.
enum MIDITakePlan {

    // MARK: Where to park before the record press

    /// Where the playhead goes before record is pressed, and where the sync
    /// then watches for its beat edge.
    struct Park: Equatable {
        /// The bar the playhead is parked at.
        let bar: Int
        /// The bar the sync watches: always `startBar - 1`, whether the
        /// playhead was parked there or Logic's count-in rolls through it.
        let preRollBar: Int
        /// `logic_count_in` or `own_pre_roll` — reported, because it decides
        /// what the call costs and which bar Logic starts recording at.
        let route: String
        let note: String
    }

    /// Measured 2026-09-02 (`profiles/logic_record_midi.md`): with count-in ON
    /// and the playhead parked at `startBar - 1`, the transport was observed
    /// rolling one bar BEFORE the parked bar (timecode `  0 1 1 13`), so the
    /// sync waited TWO bars — 4 035 ms at 120 BPM 4/4 against the one bar the
    /// tool asked for. Logic's count-in already IS a pre-roll bar, so when the
    /// flag says it is on the playhead is parked at `startBar` and the count-in
    /// bar does the leading in: one bar of wall clock, not two, and the sync
    /// still observes `startBar - 1` on the way past (a count-in longer than
    /// one bar simply passes through it).
    ///
    /// A count-in flag that could not be read (`nil`) keeps the tool's own
    /// pre-roll bar. Guessing the cheap route wrong would leave the sync with
    /// no bar to observe at all.
    static func park(startBar: Int, countIn: Bool?) -> Park {
        guard countIn == true else {
            return Park(
                bar: startBar - 1, preRollBar: startBar - 1, route: "own_pre_roll",
                note: countIn == nil
                    ? "Parked one bar early for the timecode sync; Logic's count-in flag could not be read, so the tool's own pre-roll bar was used."
                    : "Parked one bar early for the timecode sync (Logic's count-in is off)."
            )
        }
        return Park(
            bar: startBar, preRollBar: startBar - 1, route: "logic_count_in",
            note: "Logic's count-in provides the pre-roll bar, so the playhead is parked ON start_bar instead of one bar early - one bar of wall clock rather than two (measured -2.0 s at 120 BPM 4/4)."
        )
    }

    // MARK: The sync, and which branch of it ran

    /// Which crossing the stream was timed off.
    enum SyncBranch: String {
        /// The pre-roll bar's LAST BEAT was observed, so exactly one beat
        /// remains to the take's first bar line and the stream can be
        /// scheduled that beat ahead.
        case beatEdge = "beat_edge"
        /// The last beat was missed and the bar line itself was the first
        /// thing seen — there is no lead left to schedule into.
        case barLine = "bar_line"
    }

    /// How much of the pre-roll bar is LEFT, from the position the MCU display
    /// actually published — the number that replaces "one beat, presumably".
    ///
    /// The 10-digit display carries `BBB bb dd ttt`: `division` is the sixteenth
    /// of the beat (1-4) and `ticks` the tick inside it (1-240), 960 ticks to a
    /// beat. Logic blanks both to 0 on some paints, and then only the whole beat
    /// is known — `nil`, and the caller falls back to the nominal beat.
    ///
    /// WHY IT MATTERS, measured 2026-09-02 over five takes at bar 2 of the
    /// reference project, all on the beat-edge branch, all read back out of
    /// Logic's Event List: assuming exactly one beat of lead put the notes
    /// anywhere from 22.9 ms EARLY to 23.4 ms LATE on identical arguments — a
    /// 46 ms band, because the edge is not observed when it happens but when
    /// Logic next repaints the display, and the implied latency sampled 23.1,
    /// 40.7, 45.5, 46.4 and 48.1 ms. A constant can only centre that band. The
    /// position the same repaint publishes says exactly how far past the edge
    /// it is, so the lead is computed instead of assumed and the band collapses
    /// to the 5 ms poll interval.
    static func beatsRemainingInBar(
        beat: Int, division: Int, ticks: Int, beatsInBar: Int
    ) -> Double? {
        guard beatsInBar > 0, beat >= 1, beat <= beatsInBar else { return nil }
        guard (1...4).contains(division), (1...240).contains(ticks) else { return nil }
        let elapsed = Double(beat - 1) + Double((division - 1) * 240 + (ticks - 1)) / 960
        let remaining = Double(beatsInBar) - elapsed
        guard remaining > 0, remaining <= Double(beatsInBar) else { return nil }
        return remaining
    }

    /// The display latency still worth subtracting, in ms.
    ///
    /// With the sub-beat position READ (`beatsRemainingInBar`), what is left
    /// between the repaint and the note sounding is the 5 ms sync poll, the
    /// mirror read (0.4-1.3 ms measured) and everything from the bridge's
    /// CoreMIDI send to Logic's input. Measured 2026-09-02 with NO
    /// compensation at all, three takes: the notes landed 16.1, 17.2 and
    /// 20.3 ms late — a 4.2 ms band, against the 46 ms one an assumed beat
    /// gives — so the residual is real, constant, and 18 ms is the mean of
    /// those three.
    ///
    /// Where Logic blanked the division/ticks digits the lead is the nominal
    /// beat again, and then the old constants apply — and they differ by route,
    /// which is the other thing five takes showed (measured 2026-09-02, all off
    /// a 500 ms lead): inside a pre-roll bar THIS tool parked the lag is ~23 ms
    /// (the profile's two takes landed 21.5 ms early on the 45 ms default),
    /// while inside Logic's count-in bar it is ~46 ms. `sync_compensation_ms`
    /// overrides all three, and the result says which was applied.
    static func defaultCompensationMs(route: String, positionExact: Bool) -> Double {
        if positionExact { return 18 }
        return route == "logic_count_in" ? 46 : 23
    }

    /// What the bar-line branch's lateness measured, in ms — reported, never
    /// compensated. Measured 2026-09-02: 39 ms late, with `shiftMs` 0.
    static let barLineLatenessMs: Double = 39

    /// How the stream is offset against the observed crossing, and what the
    /// result says about it.
    struct SyncPlan: Equatable {
        let shiftMs: Double
        /// `SyncBranch.rawValue`.
        let branch: String
        /// The compensation that was actually APPLIED. `nil` on the bar-line
        /// branch, where there is nothing to subtract it from — which is the
        /// honest form of a knob documented as "raise if notes land early"
        /// that used to be silently inert exactly where the notes land late.
        let compensationApplied: Double?
        let note: String
    }

    static func syncPlan(
        branch: SyncBranch, leadMs: Double, compensationMs: Double,
        positionExact: Bool = false
    ) -> SyncPlan {
        switch branch {
        case .beatEdge:
            // The clamp stays: a compensation larger than the lead would ask
            // for a negative offset, which the bridge treats as "already due"
            // and sends at once — the same thing 0 does, minus the pretence.
            let how = positionExact
                ? "the exact position Logic's display published inside the pre-roll bar's last beat"
                : "the pre-roll bar's last beat, whose remaining length had to be ASSUMED because Logic blanked the display's division/tick digits"
            let caveat = positionExact
                ? " The lead is computed from that position rather than assumed, which is what keeps the take off the +/-23 ms band an assumed beat lands in (measured over five takes)."
                : " Expect up to ~23 ms either side: without the sub-beat digits the edge is only known to the repaint that revealed it."
            return SyncPlan(
                shiftMs: max(0, leadMs - compensationMs),
                branch: branch.rawValue,
                compensationApplied: min(compensationMs, leadMs),
                note: "Timed off \(how): the stream was scheduled \(Int(leadMs.rounded())) ms ahead"
                    + (compensationMs > 0
                        ? " minus \(Int(compensationMs.rounded())) ms of measured display latency."
                        : ".")
                    + caveat
            )
        case .barLine:
            return SyncPlan(
                shiftMs: 0,
                branch: branch.rawValue,
                compensationApplied: nil,
                note: "The pre-roll bar's last beat was missed and the take's own bar line was the first crossing seen, so there was no lead to schedule into and sync_compensation_ms does NOT apply: the stream went out on detection. Expect the notes ~\(Int(barLineLatenessMs.rounded())) ms late (measured). Quantize if that matters."
            )
        }
    }

    // MARK: The shutdown, whose ORDER is the whole of defect D1

    /// What the take's shutdown may do, given whether Logic was observed to
    /// have stopped recording.
    struct Shutdown: Equatable {
        /// Whether the all-notes-off blast may be sent at all.
        let silence: Bool
        let state: String
        let warning: String?
    }

    /// `midi_abort` calls the bridge's `silenceMIDIIn()`, which sends CC123 and
    /// **CC64 = 0 on all sixteen channels into the "Logic MCP MIDI In" port**
    /// (`Bridge.swift:440`). That port is the one Logic records from, so the
    /// blast is only safe once Logic has stopped recording — and until
    /// 2026-09-02 it was sent FIRST, which is why a two-note take read back as
    /// eighteen events with sixteen spurious sustain-pedal-ups in it.
    ///
    /// So the silence is a consequence of the stop, not a peer of it. When the
    /// record LED cannot be confirmed dark the blast is NOT sent: a stuck note
    /// is a sound the user can stop, and sixteen controller events written into
    /// their region are not.
    static func shutdown(recordingStopped: Bool) -> Shutdown {
        guard recordingStopped else {
            return Shutdown(
                silence: false,
                state: "stop_unconfirmed",
                warning: "The transport could not be confirmed OUT of record (the MCU record LED stayed lit), so the stuck-note all-notes-off was NOT sent - it would have been recorded into your region as sixteen sustain-pedal events. Press stop in Logic; if a note is left sounding, logic_transport with action 'stop' silences it."
            )
        }
        return Shutdown(silence: true, state: "stopped_then_silenced", warning: nil)
    }

    // MARK: What the take LEFT BEHIND

    /// The bar line the recorded region reaches, which is NOT where the take's
    /// last event sits: Logic keeps recording until the transport stops, and
    /// the take loop waits out the stream plus a 600 ms tail. Measured
    /// 2026-09-02: a two-note take whose `end_bar` was 3 produced a region
    /// spanning bars 2-4.
    ///
    /// Under a changing meter this is a walk over the map rather than a
    /// division, for the same reason `takeEnd` is.
    static func recordedEndBar(
        startBar: Int, lastBeat: Double, tailBeats: Double,
        beatsPerBar: Double, meterMap: MeterMap?
    ) -> Int {
        let meter = beatsPerBar > 0 ? beatsPerBar : 4
        let beats = max(lastBeat + max(tailBeats, 0), 0)
        guard let map = (meterMap?.isVariable == true) ? meterMap : nil else {
            return max(startBar + Int((beats / meter).rounded(.up)), startBar + 1)
        }
        let end = map.position(atBeatOffset: map.beatOffset(bar: startBar) + beats)
        return max(end.beatInBar > 1 + 1e-9 ? end.bar + 1 : end.bar, startBar + 1)
    }
}

/// The three-state contract a playhead-restore attempt owes its caller —
/// `already_at_baseline` (free, nothing needed moving), `restored` (the write
/// landed and a fresh read confirms it), `not_restored` (the write threw or
/// its readback disagreed, carrying `left_at` so the position is not just a
/// shrug). The same shape `logic_render_track` reports via
/// `MCUController.restorePlayheadReport` (MCURender.swift) — but until
/// 2026-09-03 `logic_record_midi`'s own cleanup `defer` was a bare
/// `try? logic.setPlayhead(...)` that reported nothing either way: a take from
/// bar 1 with the playhead found at bar 56 left it wherever the take's own
/// stop happened to land (measured live: bar 56 beat 3, and separately bar 5
/// beat 4 once the verification render's own playhead jump piled on top —
/// see the `restorePlayhead: true` note on that call site), and nothing in
/// the result said so.
///
/// Pure: given what was ASKED for, what Logic reports NOW, and whether the
/// write itself threw, this only SHAPES the verdict — the live read/write
/// lives in `recordMIDI`'s `restorePlayheadOnce`, which is what makes the
/// three states here testable without a Logic session at all.
enum PlayheadRestoreReport {
    /// `attempted` is what tells "was already there, nothing written" apart
    /// from "moved, written, and the write landed" — both read `current ==
    /// saved` afterwards, and only one of them is `already_at_baseline`
    /// rather than `restored`. `wroteSuccessfully` is meaningless when
    /// `attempted` is false and is ignored in that case.
    static func payload(
        saved: (bar: Int, beat: Int),
        current: (bar: Int, beat: Int)?,
        attempted: Bool,
        wroteSuccessfully: Bool
    ) -> [String: Any] {
        if !attempted, let current, current == saved {
            return [
                "restored": true, "verified": true, "state": "already_at_baseline",
                "bar": saved.bar, "beat": saved.beat
            ]
        }
        guard attempted, wroteSuccessfully, let current, current == saved else {
            return [
                "restored": false, "verified": false, "state": "not_restored",
                "bar": saved.bar, "beat": saved.beat,
                "left_at": current.map { ["bar": $0.bar, "beat": $0.beat] as [String: Any] }
                    ?? ["bar": NSNull(), "beat": NSNull()] as [String: Any],
                "note": "the playhead could NOT be put back to bar \(saved.bar) beat \(saved.beat)"
                    + " after the take — it is now at "
                    + (current.map { "bar \($0.bar) beat \($0.beat)" } ?? "an unreadable position")
                    + ". Move it yourself with logic_set_playhead."
            ]
        }
        return [
            "restored": true, "verified": true, "state": "restored",
            "bar": saved.bar, "beat": saved.beat,
            "note": "The take moved the playhead (parking it for the pre-roll sync, then"
                + " wherever its own stop left it); it was put back where you had it"
                + " (verified against Logic's control bar)."
        ]
    }
}

extension MCUController {
    // MARK: The timecode display: mode plausibility

    /// The four position fields of the 10-digit display, unparsed.
    ///
    /// The bridge decodes the ten 7-segment digits into exactly ten
    /// characters with no separators (a 10-byte buffer, `Bridge.swift:26`,
    /// blank-initialised to 0x20 and written right-to-left), so the fields
    /// are fixed slices: bar 3, beat 2, division 2, ticks 3. A
    /// space-separated rendering (four groups of exactly those widths, the
    /// shape the snapshot fixture in ProtocolTests spells out) is accepted
    /// too, so a future formatter change degrades into "still parsed"
    /// instead of "every position implausible".
    static func timecodeFields(
        _ raw: String
    ) -> (bar: String, beat: String, division: String, ticks: String)? {
        let widths = [3, 2, 2, 3]
        let groups = raw.split(separator: " ").map(String.init)
        if groups.count == 4, groups.map(\.count) == widths {
            return (groups[0], groups[1], groups[2], groups[3])
        }
        let characters = Array(raw)
        guard characters.count >= 10 else { return nil }
        var slices: [String] = []
        var start = 0
        for width in widths {
            slices.append(String(characters[start..<(start + width)]))
            start += width
        }
        return (slices[0], slices[1], slices[2], slices[3])
    }

    /// One display field: blank (Logic painted nothing there), a number, or
    /// something that is not a number at all.
    private enum TimecodeField: Equatable {
        case blank
        case number(Int)
        case garbage
    }

    private static func timecodeField(_ raw: String) -> TimecodeField {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed) else {
            return .garbage
        }
        return .number(value)
    }

    /// Classifies a raw display string as a bars/beats position or not.
    /// Pure — no bridge, no Logic, no side effects; unit-tested.
    ///
    /// The check refuses only on *positive* evidence, because a false refusal
    /// blocks a legitimate recording:
    /// - bars, beats and divisions are **one-based** everywhere in Logic,
    ///   while SMPTE's hours/minutes/seconds are zero-based — so a zero (or a
    ///   blank) in the bar or beat field, or a literal `00` division, is
    ///   evidence of SMPTE mode rather than of a musical position;
    /// - a blank division or ticks field is *tolerated* (leading-zero
    ///   suppression on the 7-segment display is only verified for digits and
    ///   spaces, FINDINGS 2026-08-25), reported as 0;
    /// - `expectedBar` is the decisive check and is passed wherever the
    ///   caller has just parked the playhead at a verified bar: SMPTE digits
    ///   that happen to be shaped like a position still disagree with it.
    static func classifyTimecode(
        _ raw: String?, expectedBar: Int? = nil, barTolerance: Int = 1
    ) -> MCUTimecodeReading {
        guard let raw else { return .notReported }
        if raw.uppercased().contains(MCULCDStrings.modalAlertTimecode) { return .alert }
        let shown = raw.trimmingCharacters(in: .whitespaces)
        if shown.isEmpty { return .notReported }
        guard let fields = timecodeFields(raw) else {
            return .implausible(
                reason: "the position display reads '\(shown)', which is not the 10-digit bars/beats layout"
            )
        }
        guard case .number(let bar) = timecodeField(fields.bar), bar >= 1 else {
            return .implausible(
                reason: "the position display reads '\(shown)', whose bar field is not a bar number (bars start at 1)"
            )
        }
        guard case .number(let beat) = timecodeField(fields.beat), beat >= 1 else {
            return .implausible(
                reason: "the position display reads '\(shown)', whose beat field is not a beat number (beats start at 1)"
            )
        }
        var division = 0
        switch timecodeField(fields.division) {
        case .blank: break
        case .number(let value) where value >= 1: division = value
        default:
            return .implausible(
                reason: "the position display reads '\(shown)', whose division field is not a division (divisions start at 1)"
            )
        }
        var ticks = 0
        switch timecodeField(fields.ticks) {
        case .blank: break
        case .number(let value): ticks = value
        case .garbage:
            return .implausible(
                reason: "the position display reads '\(shown)', whose tick field is not numeric"
            )
        }
        if let expectedBar, abs(bar - expectedBar) > barTolerance {
            return .implausible(
                reason: "the position display reads '\(shown)' (bar \(bar)) while the playhead is parked at bar \(expectedBar)"
            )
        }
        return .beats(bar: bar, beat: beat, division: division, ticks: ticks)
    }

    /// The live reading off the bridge mirror.
    static func timecodeReading(expectedBar: Int? = nil) -> MCUTimecodeReading {
        classifyTimecode(freshStatus()?["timecode"] as? String, expectedBar: expectedBar)
    }

    /// Refuses to run a bar-synchronised operation against a display that is
    /// not showing bars/beats — the guard that turns "silently recorded
    /// against hours-as-bars" into an actionable refusal. Nothing is written
    /// by this check itself.
    ///
    /// TODO (docs/ROADMAP.md item 1, "Guard the MCU timecode parse"): the
    /// bridge already maps the `smpte_beats` button (`Bridge.swift:447`), so
    /// this could press it once, re-read, and continue when the display
    /// becomes plausible (the press *is* the fix — nothing to restore). Not
    /// implemented because pressing it cannot be verified without a live
    /// Logic + bridge session; until someone confirms the button's effect on
    /// the mirrored display, refusing is better than guessing inside a
    /// sync-critical path.
    static func requireBeatsDisplay(expectedBar: Int? = nil, operation: String) throws {
        if let error = beatsDisplayError(
            for: timecodeReading(expectedBar: expectedBar), operation: operation
        ) {
            throw error
        }
    }

    /// The refusal a given reading deserves, or nil when it is a usable
    /// position. Split out of `requireBeatsDisplay` so the messages agents
    /// actually branch on are unit-testable without a bridge.
    static func beatsDisplayError(
        for reading: MCUTimecodeReading, operation: String
    ) -> LogicianError? {
        switch reading {
        case .beats:
            return nil
        case .alert:
            return LogicianError.openVerificationFailed(
                "Logic is showing a modal alert (MCU timecode reads ALERT); dismiss it and retry"
            )
        case .notReported:
            return LogicianError.trackNotExposed(
                requested: "the MCU position display for \(operation)",
                exposed: "the 10-digit position display is blank — Logic has not reported a playhead position on the control surface (check logic_health / the Mackie Control setup)"
            )
        case .implausible(let reason):
            return LogicianError.currentValueMismatch(
                expected: "the MCU position display in bars/beats mode for \(operation)",
                actual: "\(reason) — the MCU secondary display is in SMPTE mode; press the SMPTE/Beats button in Logic's control bar or the MCU display to switch to beats, then retry"
            )
        }
    }

    // MARK: MIDI recording (composition via the "Logic MCP MIDI In" port)

    /// The MCU's RECORD LED. It is the witness for both ends of a take: that
    /// Logic armed and rolled, and — since 2026-09-02 — that Logic is out of
    /// record again before the stream's all-notes-off is allowed to fire.
    static let recordLED = 0x5F

    /// Current bar from the MCU timecode display (BBB bb dd ttt layout), or
    /// nil when the display is not showing a plausible bars/beats position
    /// (SMPTE mode, `ALERT`, blank). Polling loops then see "no position
    /// yet" and time out with their own verification error instead of
    /// syncing against hours; `requireBeatsDisplay` is what names the fix.
    static func timecodeBar() -> Int? {
        guard case .beats(let bar, _, _, _) = timecodeReading() else { return nil }
        return bar
    }

    static func timecodeBarBeat() -> (bar: Int, beat: Int)? {
        guard case .beats(let bar, let beat, _, _) = timecodeReading() else { return nil }
        return (bar, beat)
    }

    /// Records composed notes onto the selected track by streaming them over
    /// the plain "Logic MCP MIDI In" port while Logic records: the playhead is
    /// parked so that one bar leads into `startBar` — Logic's own count-in bar
    /// when the transport reports count-in ON, the tool's own pre-roll bar when
    /// it does not (`MIDITakePlan.park`) — record is pressed, and the stream
    /// starts on the observed timecode crossing into `startBar`. Wholly
    /// data-plane: no dialogs, no files, no keypresses.
    ///
    /// `preRollLastBeat` and `preRollLastBeatMs` are computed by the caller from
    /// the project's own METER and TEMPO maps at bar `startBar - 1`, not from
    /// the control bar's reading at the playhead. That distinction is defect D3
    /// (2026-09-02): the control bar publishes the signature and tempo IN FORCE
    /// WHERE THE PLAYHEAD IS, so on a project whose bar 41 is 5/4 a take at bar
    /// 2 waited for a fifth beat of a four-beat bar, never saw it, and fell
    /// into the bar-line branch — which is the branch `sync_compensation_ms`
    /// cannot reach. The take's timing therefore depended on where the user had
    /// left the playhead.
    static func recordMIDI(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        events: [(offsetMs: Double, bytes: [UInt8])],
        listedEvents: Int,
        startBar: Int, tailMs: Double,
        preRollLastBeat: Int, preRollLastBeatMs: Double,
        meterRoute: String,
        syncCompensationMs: Double?
    ) throws -> [String: Any] {
        guard startBar >= 2 else {
            throw LogicianError.invalidArguments(
                "start_bar must be >= 2 (one bar of pre-roll is needed for the timecode sync)"
            )
        }
        guard freshStatus() != nil else {
            throw LogicianError.trackNotExposed(
                requested: "MCU bridge for MIDI recording",
                exposed: "the bridge is not running or Logic has not connected"
            )
        }
        // The whole sync below reads bars and beats off the 10-digit display,
        // which carries no mode bit — in SMPTE mode those digits are hours
        // and minutes. Cheap shape check FIRST, before anything is selected,
        // moved or armed, so the common case (display left in SMPTE) costs
        // one status read and refuses with the fix named.
        try requireBeatsDisplay(operation: "MIDI recording at bar \(startBar)")
        _ = try? setPlaying(false)
        let transport = try logic.getTransport()
        // BOTH fields, not just the bar: the cleanup below used to restore
        // `barNumber: bar, beat: nil`, which converges the bar slider and
        // leaves the beat wherever the take's own stop left it. Measured
        // 2026-09-03: a take parked from bar 56 came back to bar 56 but beat 3
        // (it had been beat 1), because nothing ever asked what the beat was.
        let savedPlayhead: (bar: Int, beat: Int)? = (transport["playhead_bar"] as? Int)
            .map { (bar: $0, beat: transport["playhead_beat"] as? Int ?? 1) }
        // The count-in flag rides along on the snapshot that was already being
        // read for `savedPlayhead`, so knowing what Logic's count-in will cost
        // is free. Nothing reads it beyond the park decision, and nothing
        // writes it: switching a user's count-in off would be a settings
        // write with a restore to get wrong.
        let park = MIDITakePlan.park(
            startBar: startBar, countIn: transport["count_in"] as? Bool
        )

        var selected = false
        if let channel = ((try? findChannel(trackName: trackName)) ?? nil) {
            selected = (try? selectFoundChannel(channel)) == true
        }
        if !selected {
            _ = try logic.selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }

        _ = try logic.setPlayhead(barNumber: park.bar, beat: nil)
        // A record press within ~0.5 s of the playhead LCD converge gets
        // swallowed by Logic while the field is still hot. That used to be a
        // blind `Thread.sleep(0.6)` — 3.9% of the warm call — with the DECISIVE
        // check eight lines below it costing 0.4–1.3 ms (measured 2026-09-02).
        // So the positive check is the wait now: `setPlayhead` has already
        // verified the playhead against Logic's own control bar, and the
        // display is settled once it shows that same bar. SMPTE digits that
        // merely LOOK like a position fail here too. Still nothing recorded;
        // restore the playhead ourselves since the cleanup `defer` below is not
        // armed yet.
        _ = quiescentStatus()
        var parkError: Error?
        let settleDeadline = Date().addingTimeInterval(1.5)
        while true {
            parkError = nil
            do {
                try requireBeatsDisplay(
                    expectedBar: park.bar,
                    operation: "MIDI recording sync at bar \(startBar)"
                )
                break
            } catch {
                parkError = error
                guard Date() < settleDeadline else { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        if let parkError {
            if let saved = savedPlayhead {
                _ = try? logic.setPlayhead(barNumber: saved.bar, beat: saved.beat)
            }
            throw parkError
        }
        try press("record")
        // The shutdown, whose ORDER is defect D1: the stop comes first and the
        // all-notes-off blast only after Logic is out of record, because that
        // blast goes into the port Logic is recording FROM. See
        // `MIDITakePlan.shutdown`. This closure is the shutdown for every path;
        // the happy path calls it explicitly so the result can report it, and
        // the `defer` catches the throwing and cancelled ones.
        var shutdownReport: MIDITakePlan.Shutdown?
        // The stop's own verdict — verified through a fallback witness, or
        // refused outright because the transport was never seen rolling —
        // used to vanish behind `try?` here. Captured once, alongside the
        // shutdown state it feeds `pollStatus` next.
        var transportStop: (payload: [String: Any], warning: String?)?
        func stopRecording() -> MIDITakePlan.Shutdown {
            if let report = shutdownReport { return report }
            transportStop = stopForCleanup()
            // The record LED is the same witness the arm check used, read the
            // same way: no new mechanism, and it costs one status look when
            // Logic has already stopped.
            let stopped = pollStatus(until: { !ledLit(recordLED, in: $0) }, attempts: 20) != nil
            let report = MIDITakePlan.shutdown(recordingStopped: stopped)
            if report.silence { _ = try? MCUBridge.send(.midiAbort) } // stuck-note safety
            shutdownReport = report
            return report
        }
        // The playhead restore's own verdict — until 2026-09-03 this was a
        // bare `try? logic.setPlayhead(barNumber: bar, beat: nil)` here, which
        // (a) never restored the BEAT at all (see `savedPlayhead` above) and
        // (b) threw the outcome away either way: a take from bar 1 with the
        // playhead found at bar 56 left it wherever the take's own stop
        // happened to leave it, with nothing in the result saying so — the
        // same class of defect `logic_render_track`'s `restorePlayheadReport`
        // exists to close. Captured once, alongside the shutdown state,
        // exactly like `stopRecording` above: the happy path calls it
        // explicitly so the result can report it, the `defer` is the net for
        // the throwing and cancelled paths.
        var playheadRestoreCache: [String: Any]?
        func restorePlayheadOnce() -> [String: Any]? {
            guard let saved = savedPlayhead else { return nil }
            if let cached = playheadRestoreCache { return cached }
            func currentPosition() -> (bar: Int, beat: Int)? {
                guard let now = try? logic.getTransport(),
                      let bar = now["playhead_bar"] as? Int else { return nil }
                return (bar, now["playhead_beat"] as? Int ?? 1)
            }
            let before = currentPosition()
            if let before, before == saved {
                // Already there — a project whose take started where the
                // playhead already was. A verified no-op, not a move; no
                // write attempted.
                let report = PlayheadRestoreReport.payload(
                    saved: saved, current: before, attempted: false, wroteSuccessfully: false
                )
                playheadRestoreCache = report
                return report
            }
            let wrote = (try? logic.setPlayhead(barNumber: saved.bar, beat: saved.beat)) != nil
            let report = PlayheadRestoreReport.payload(
                saved: saved, current: currentPosition(), attempted: true, wroteSuccessfully: wrote
            )
            playheadRestoreCache = report
            return report
        }
        defer {
            _ = stopRecording()
            _ = restorePlayheadOnce()
        }
        reportProgress("record pressed; waiting for the transport", percent: 10)
        // Record LED confirms Logic is actually rolling/armed.
        guard pollStatus(until: { ledLit(recordLED, in: $0) }) != nil else {
            throw LogicianError.verificationFailed(
                requested: "recording started",
                actual: "the MCU record LED never lit",
                restored: true
            )
        }
        // Sync on the timecode crossing into the LAST BEAT of the pre-roll
        // bar: from there exactly one beat remains to start_bar, so events are
        // scheduled one beat ahead minus the measured display latency. Both
        // numbers come from the project's maps AT THAT BAR (see the doc
        // comment); the control bar's reading at the playhead is what defect
        // D3 was.
        let lastBeat = max(preRollLastBeat, 1)
        let syncDeadline = Date().addingTimeInterval(20)
        var branch: MIDITakePlan.SyncBranch?
        // How much of the pre-roll bar the display said was left when the edge
        // was seen — nil when Logic blanked the sub-beat digits.
        var remainingBeats: Double?
        var syncPosition: String?
        // The parked display can already read e.g. "beat 4" from an earlier
        // stop (setPlayhead only converges the bar), so no edge may be
        // accepted until the timecode has visibly CHANGED — proof that the
        // transport is rolling, after which beat values are trustworthy.
        let parkedTimecode = freshStatus()?["timecode"] as? String
        var rolling = false
        var recordRetried = false
        // …and PROOF OF MOTION IS NOT PROOF OF POSITION. The bar-line branch
        // used to accept the first `position.bar >= startBar` it saw, so a
        // transport that started PAST the range would have had the whole take
        // streamed at the wrong bar under `success: true, verified: true`. The
        // pre-roll bar must be observed first; a transport already past it is
        // a refusal, not a take (candidate N5, and `logic_record_automation`'s
        // N4 is the same shape).
        var sawPreRoll = false
        let rollDeadline = Date().addingTimeInterval(4)
        reportProgress("armed; waiting for the playhead to reach bar \(startBar)", percent: 20)
        while Date() < syncDeadline {
            // The `defer` above stops the transport, silences the stream and
            // puts the playhead back, so a cancellation here unwinds through
            // exactly the same path a thrown sync failure does.
            try checkCancelled()
            if !rolling {
                let current = freshStatus()?["timecode"] as? String
                if current != nil, current != parkedTimecode { rolling = true }
                else {
                    // Swallowed record press: try once more if nothing rolls.
                    if !recordRetried, Date() > rollDeadline {
                        recordRetried = true
                        try press("record")
                    }
                    Thread.sleep(forTimeInterval: 0.005); continue
                }
            }
            if case .beats(let bar, let beat, let division, let ticks) = timecodeReading() {
                if bar < startBar { sawPreRoll = true }
                if bar >= startBar {
                    guard sawPreRoll else {
                        throw LogicianError.verificationFailed(
                            requested: "the take to start on the crossing into bar \(startBar)",
                            actual: "the transport was already at bar \(bar) the first time the position display could be read, so the pre-roll bar (\(park.preRollBar), \(park.route)) was never observed and the crossing could not be timed. Streaming now would put the whole take at the wrong position. Nothing was streamed",
                            restored: true
                        )
                    }
                    branch = .barLine // missed the beat edge; fall back to the bar line
                    break
                }
                if bar == park.preRollBar, beat >= lastBeat {
                    // The same repaint that revealed the edge also says how far
                    // PAST it we are, so the lead is measured rather than
                    // assumed to be a whole beat. `syncPosition` is reported:
                    // the position a take was timed off is part of the take,
                    // the way `logic_read_automation`'s sampled position is
                    // part of the reading.
                    remainingBeats = MIDITakePlan.beatsRemainingInBar(
                        beat: beat, division: division, ticks: ticks, beatsInBar: lastBeat
                    )
                    syncPosition = "\(bar) \(beat) \(division) \(ticks)"
                    branch = .beatEdge
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let branch else {
            throw LogicianError.verificationFailed(
                requested: "playhead reaching bar \(startBar)",
                actual: "the timecode never crossed into the start bar within 20 s",
                restored: true
            )
        }
        // The lead: the pre-roll bar's last beat scaled by how much of it the
        // display said was still to run. Without those digits it is the whole
        // beat, and then the route's measured constant compensates for it.
        let positionExact = branch == .beatEdge && remainingBeats != nil
        let leadMs = branch == .beatEdge
            ? preRollLastBeatMs * (remainingBeats ?? 1) : 0
        let sync = MIDITakePlan.syncPlan(
            branch: branch, leadMs: leadMs,
            compensationMs: syncCompensationMs ?? MIDITakePlan.defaultCompensationMs(
                route: park.route, positionExact: positionExact
            ),
            positionExact: positionExact
        )
        let streamResponse = try MCUBridge.send(.midiStream(
            events: events.map {
                MIDIStreamEvent(offsetMs: $0.offsetMs + sync.shiftMs, bytes: $0.bytes)
            }
        ))
        guard streamResponse.ok, let durationMs = streamResponse.durationMs else {
            throw LogicianError.writeFailed(
                "midi_stream failed: \(streamResponse.error ?? "?")"
            )
        }
        // The take. This used to be one blind `Thread.sleep` for the whole
        // duration — the single longest uninterruptible stretch in the server,
        // and the one place a client could ask for a four-minute recording and
        // then be unable to stop it. Polling the same wall clock costs nothing
        // and makes the take both reportable and cancellable.
        let takeSeconds = (Double(durationMs) + tailMs) / 1000
        reportProgress("rolling; streaming \(events.count) events", percent: 40)
        let takeStart = Date()
        while true {
            let elapsed = Date().timeIntervalSince(takeStart)
            if elapsed >= takeSeconds { break }
            try checkCancelled()
            reportProgress(
                "recording \(String(format: "%.1f", elapsed))/\(String(format: "%.1f", takeSeconds)) s",
                percent: 40 + 58 * (elapsed / takeSeconds), throttle: 1
            )
            Thread.sleep(forTimeInterval: min(0.1, takeSeconds - elapsed))
        }
        reportProgress("take finished", percent: 100)
        // Stop and silence HERE rather than in the `defer`, in that order, so
        // the result can say what the shutdown did. The `defer` still runs and
        // still restores the playhead; `stopRecording` is idempotent.
        let shutdown = stopRecording()
        // Same reasoning as `shutdown` above, and `restorePlayheadOnce` is
        // idempotent the same way: called here so the result can name the
        // verdict, with the `defer` as the net for the throwing paths. The
        // caller (`handleRecordMidi`) is where the top-level `warning` is
        // appended, not here — a verification render can run AFTER this
        // function returns and move the playhead AGAIN (`restorePlayhead:
        // true` on that call site), so whichever restore attempt is LAST is
        // the one the warning must describe, and only the caller sees both.
        let playheadRestore = restorePlayheadOnce()
        // `verified` belongs to the RECORDING: reaching here means the
        // transport was rolling, the stream went out with host-time stamps,
        // and the stop/restore path completed - anything less throws above.
        // Whether the result SOUNDS is a separate observation the caller
        // reports as verification_render.
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            // What `logic_list_events` will report on the region: notes count
            // once (their note-offs are the same row's length), CC and bend
            // events one each. Until 2026-09-02 this field was the wire
            // count — 4 for a two-note take — and could not be diffed against
            // the region it had just written.
            "events_streamed": listedEvents,
            "midi_messages_streamed": events.count,
            "events_note": "events_streamed counts events the way Logic's Event List does, so it can be diffed against logic_list_events; midi_messages_streamed is the raw count on the wire (a note is a note-on plus a note-off).",
            "stream_duration_ms": durationMs,
            "write_route": "midi_in_record",
            "sync_branch": sync.branch,
            "sync_lead_ms": (leadMs * 10).rounded() / 10,
            "sync_lead_route": positionExact ? "display_sub_beat_position" : "assumed_whole_beat",
            "sync_position": syncPosition ?? NSNull(),
            "sync_shift_ms": (sync.shiftMs * 10).rounded() / 10,
            "sync_compensation_ms_applied": sync.compensationApplied ?? NSNull(),
            "sync_beats_per_bar": lastBeat,
            "sync_meter_route": meterRoute,
            "sync_note": sync.note,
            "pre_roll_bar": park.preRollBar,
            "pre_roll_route": park.route,
            "pre_roll_note": park.note,
            "shutdown": shutdown.state,
            "shutdown_note": "The transport is stopped BEFORE the stream's all-notes-off, because that safety blast goes into the same MIDI port Logic records from: sent while the transport rolled it wrote sixteen 'Control 64 = Sustain, 0' events into the take (measured 2026-09-02)."
        ]
        result["transport_stop"] = transportStop?.payload
            ?? ["unavailable": "the cleanup stop was never reached"]
        result["playhead"] = playheadRestore
            ?? ["unavailable": "the playhead position before the take could not be read, so there was nothing to restore against"]
        if let warning = shutdown.warning { appendWarning(warning, to: &result) }
        appendWarning(transportStop?.warning, to: &result)
        return result
    }

    /// Track-level A/B: two freeze renders around one verified MCU parameter
    /// change, compared on the sliced bar range. Isolates the change to ONE
    /// track's output (no master bus in the way) and never plays back.
    static func evaluateChangeRendered(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        insertSlot: Int, parameter: String,
        expectedCurrentValue: String, targetValue: String,
        startBar: Int, endBar: Int,
        startSeconds: Double, endSeconds: Double,
        tempo: Double,
        keepChange: Bool, includeAudio: Bool
    ) throws -> [String: Any] {
        let projectPath = try logic.projectDocumentPath()
        if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
           let header = tracks.first(where: {
               ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
           }),
           header["is_stack"] as? Bool == true {
            throw LogicianError.trackNotExposed(
                requested: "render A/B of '\(trackName)'",
                exposed: "'\(trackName)' is a track stack — Logic cannot freeze stacks; evaluate on a subtrack or use method 'bounce'"
            )
        }
        // Select once; both renders and the parameter writes act on the
        // selected track.
        var selected = false
        if let channel = ((try? findChannel(trackName: trackName)) ?? nil) {
            selected = (try? selectFoundChannel(channel)) == true
        }
        if !selected {
            _ = try logic.selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }

        // The playhead is parked ONCE for the whole A/B. A freeze render jumps
        // it to the project start and rolls from there, so each render puts it
        // back — and stepping the control bar's bar slider costs ~0.12 s per
        // bar, which is a price to pay once here rather than twice. The
        // renders below are told not to.
        var savedPlayhead: (bar: Int, beat: Int)?
        if let transport = try? logic.getTransport(),
           let bar = transport["playhead_bar"] as? Int {
            savedPlayhead = (bar, transport["playhead_beat"] as? Int ?? 1)
        }

        // An A/B is four phases and two whole renders. Each render reports its
        // own 0…100, folded into the half of the scale it occupies, so the
        // client sees one line climbing from 0 to 100 instead of two renders
        // each racing to 100 and a counter that never moves in between.
        reportProgress("rendering the BASELINE", percent: 4)
        let renderA = try withProgressScope(5...45) {
            try renderSelectedTrack(
                projectPath: projectPath, label: "\(trackName.lowercased())-a",
                sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
                logic: logic, trackName: trackName,
                // This A/B never publishes a render's own audio block or
                // preview — `baseline_preview`/`after_preview` are null here
                // and the blocks come from `attachABAudio` below — so neither
                // render pays for one.
                restorePlayhead: false, includeAudio: false
            )
        }
        reportProgress("applying the change", percent: 46)
        // `trackName:` is what lets `setPluginParameter` use its own
        // bookkeeping at all: without it `hotMatchesRequest()` returns false on
        // its first line (MCUParameters.swift:533) and neither branch of
        // `if let trackName` runs, so the hot plugin view is never consulted
        // AND the plugin-edit `SurfaceDebt` is never recorded — this tool left
        // the surface in plugin-edit with nothing in the ledger saying so.
        //
        // It buys no time here, and that is worth writing down. The profile's
        // candidate N1 sized it at −1.0 to −1.5 s on the theory that the second
        // write (the rollback) would find the view still hot. Measured live
        // 2026-09-02 on the sandbox: **an offline bounce puts the surface back
        // in PN by itself** (assignment `P4` before `logic_bounce_range`, `PN`
        // straight after, LCD back to track names), so the two writes of an A/B
        // can never be adjacent and the same write costs 2 887 / 2 852 ms
        // either side of the bounce. Two writes with nothing in between DO get
        // the view — 2 990 ms cold, then 2 401 / 2 364 ms — so the cache works;
        // it is 590 ms, not 1.5 s, and this tool cannot reach it. What is left
        // is ~0.7 ms for one `freshStatus()` probe that correctly declines, and
        // a surface debt that is now recorded rather than inferred by the
        // crashed-predecessor fallback in `settleSurfaceDebt`.
        guard let change = try setPluginParameter(
            slot: insertSlot, parameter: parameter,
            targetValue: targetValue, expectedCurrentValue: expectedCurrentValue,
            tolerance: nil, trackName: trackName
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU write of '\(parameter)' in slot \(insertSlot)",
                exposed: "the MCU bridge could not resolve the parameter; nothing was changed (baseline render A kept)"
            )
        }
        let appliedValue = change["after"] as? String ?? targetValue
        let beforeValue = change["before"] as? String ?? expectedCurrentValue

        // Rolling back must survive the transient MCU/plugin-reload window
        // right after an unfreeze: retry with quiescence, and drop the
        // compare-and-set on the final attempt (we verified the applied
        // value moments ago; restoring wins over re-checking).
        func rollBack() -> Bool {
            for attempt in 0..<3 {
                if attempt > 0 {
                    _ = quiescentStatus()
                    Thread.sleep(forTimeInterval: 1.0)
                }
                let expected = attempt < 2 ? appliedValue : nil
                if ((try? setPluginParameter(
                    slot: insertSlot, parameter: parameter,
                    targetValue: beforeValue, expectedCurrentValue: expected,
                    tolerance: nil, trackName: trackName
                )) ?? nil) != nil {
                    return true
                }
            }
            return false
        }

        let renderB: [String: Any]
        do {
            reportProgress("rendering AFTER the change", percent: 50)
            renderB = try withProgressScope(50...92) {
                try renderSelectedTrack(
                    projectPath: projectPath, label: "\(trackName.lowercased())-b",
                    sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
                    logic: logic, trackName: trackName,
                    restorePlayhead: false, includeAudio: false
                )
            }
        } catch {
            // Never leave the change in place after a failed B render.
            _ = rollBack()
            _ = savedPlayhead.map { restorePlayheadReport(logic: logic, saved: $0) }
            throw error
        }

        var decision = "kept"
        var restored = true
        if !keepChange {
            if rollBack() {
                decision = "rolled_back"
            } else {
                decision = "rollback_failed"
                restored = false
            }
        }
        let playhead = savedPlayhead.map { restorePlayheadReport(logic: logic, saved: $0) }

        func sliceMetrics(_ render: [String: Any]) -> [String: Any]? {
            (render["slice"] as? [String: Any])?["metrics"] as? [String: Any]
        }
        reportProgress("measuring A against B", percent: 94)
        let metricsA = sliceMetrics(renderA)
        let metricsB = sliceMetrics(renderB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        var evalResult: [String: Any] = [
            "success": true,
            "verified": restored || keepChange,
            "state": "evaluated",
            "method": "render",
            "decision": decision,
            "change": [
                "track": trackName, "track_name": trackName,
                "insert_slot": insertSlot, "parameter": parameter,
                "before": beforeValue, "applied": appliedValue
            ],
            "range": ["start_bar": startBar, "end_bar": endBar, "tempo": tempo],
            "baseline_audio": (renderA["slice"] as? [String: Any])?["path"] ?? renderA["path"] ?? NSNull(),
            "after_audio": (renderB["slice"] as? [String: Any])?["path"] ?? renderB["path"] ?? NSNull(),
            // Same key set as the other two methods; a freeze render has no
            // AAC preview sibling, so those are present and null.
            "baseline_preview": NSNull(),
            "after_preview": NSNull(),
            "baseline_full_audio": renderA["path"] ?? NSNull(),
            "after_full_audio": renderB["path"] ?? NSNull(),
            "baseline_metrics": metricsA ?? NSNull(),
            "after_metrics": metricsB ?? NSNull(),
            "deltas": deltas,
            "note": "Two dialog-free freeze renders of this single track, compared on the sliced bar range only. No playback occurred."
        ]
        if let playhead {
            evalResult["playhead"] = playhead
            if playhead["restored"] as? Bool != true {
                appendWarning(playhead["note"] as? String, to: &evalResult)
            }
        }
        evalResult = attachABAudio(
            to: evalResult,
            baselinePath: ((renderA["slice"] as? [String: Any])?["path"] as? String) ?? (renderA["path"] as? String),
            afterPath: ((renderB["slice"] as? [String: Any])?["path"] as? String) ?? (renderB["path"] as? String),
            includeAudio: includeAudio
        )
        return evalResult
    }

    /// Attaches baseline+after ear copies as ordered MCP audio blocks so the
    /// A/B can be HEARD in the same result the keep/rollback decision is
    /// made from. First audio block = baseline (A), second = after (B).
    ///
    /// `includeAudio: false` is the caller's `include_audio` opt-out, and it
    /// reaches this far down on purpose: both copies used to be transcoded and
    /// base64-encoded anyway, for `toolResult` to lift out and throw away a
    /// moment later — 134–289 ms per call that bought the agent nothing,
    /// measured identical with the flag on and off (`logic_evaluate_change`
    /// profile §7, 2026-09-01). The agent-visible payload is unchanged:
    /// `_audio_suppressed` tells `toolResult` this result WOULD have carried
    /// audio, so it still rewrites the listen note into the "blocks were
    /// OMITTED" one and still adds the epistemics line, exactly as when it had
    /// blocks to drop.
    static func attachABAudio(
        to result: [String: Any], baselinePath: String?, afterPath: String?,
        includeAudio: Bool = true
    ) -> [String: Any] {
        var result = result
        guard let baselinePath, let afterPath else { return result }
        guard includeAudio else {
            result["_audio_suppressed"] = true
            return result
        }
        guard let a = LogicAccessibility.encodeEarCopy(path: baselinePath, maxBytes: 300_000),
              let b = LogicAccessibility.encodeEarCopy(path: afterPath, maxBytes: 300_000)
        else { return result }
        result["_audio_list"] = [
            ["data": a.base64EncodedString(), "mimeType": "audio/mp4"],
            ["data": b.base64EncodedString(), "mimeType": "audio/mp4"]
        ]
        result["listen_note"] = "This result CARRIES both versions as MCP audio blocks - the FIRST is the baseline (A), the SECOND is after the change (B). Listen to both before deciding. If no audio reached you, open the baseline_audio/after_audio preview files with your client's file viewer."
        return result
    }

    /// Track-level A/B for tracks that cannot be frozen (stack subtracks,
    /// tracks sharing a channel strip): solo the track, bounce the range
    /// offline before and after one verified MCU parameter change, then
    /// unsolo. The master chain still applies (inherent to solo-bouncing) -
    /// the deltas are still honest because it applies to both A and B.
    static func evaluateChangeSoloBounced(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        insertSlot: Int, parameter: String,
        expectedCurrentValue: String, targetValue: String,
        startBar: Int, endBar: Int,
        keepChange: Bool, includeAudio: Bool
    ) throws -> [String: Any] {
        _ = try logic.selectTrack(
            trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
        )

        // Who else is soloed, read BEFORE this tool adds its own solo — after
        // it, the answer is unreadable in principle. Not a refusal (the sibling
        // `logic_export_stems` refuses because a stem must hold ONE track; an
        // A/B's deltas survive a foreign solo, since the same contamination is
        // in both bounces) but the result must say so, because the ear copies
        // then contain music the note used to deny. `nil` is not `[]`: an
        // unreadable Tracks area answers "unknown", never "nobody".
        let preexistingSolos = logic.soloedTrackNamesIfReadable()

        // Solo on - with a track number the AX strip toggle is authoritative
        // (duplicate track names make the MCU name match ambiguous).
        func setSolo(_ enabled: Bool) throws -> [String: Any] {
            if trackNumber != nil {
                return try logic.setStripToggle(
                    trackName: trackName, trackNumber: trackNumber,
                    control: "solo", enabled: enabled
                )
            }
            return try setToggle(trackName: trackName, control: "solo", enabled: enabled)
                ?? logic.setStripToggle(
                    trackName: trackName, trackNumber: nil,
                    control: "solo", enabled: enabled
                )
        }
        let soloOn = try setSolo(true)
        let wasAlreadySoloed = ((soloOn["state"] as? String) ?? "").hasPrefix("already")
        var soloRestored = wasAlreadySoloed // nothing to restore when it was on
        func unsolo() {
            guard !wasAlreadySoloed, !soloRestored else { return }
            soloRestored = ((try? setSolo(false)) != nil)
        }

        // Solo toggling can move the selection - re-select so the MCU
        // parameter writes hit the right channel.
        _ = try? logic.selectTrack(
            trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
        )

        let bounceA: [String: Any]
        do {
            reportProgress("bouncing the BASELINE", percent: 4)
            bounceA = try withProgressScope(5...45) {
                try logic.bounceRange(
                    startBar: startBar, endBar: endBar,
                    label: "\(trackName.lowercased())-solo-a", expectedProjectPath: nil
                )
            }
        } catch {
            logic.cancelBounceDialog()
            unsolo()
            throw error
        }

        // setPluginParameter THROWS on the most common agent mistake (a wrong
        // expected_current_value), not just returns nil — both paths must
        // unsolo, or every later master bounce comes out silent.
        let changeOpt: [String: Any]?
        do {
            reportProgress("applying the change", percent: 46)
            // `trackName:` for the hot plugin view and the plugin-edit
            // SurfaceDebt — see the same call in `evaluateChangeRendered`.
            changeOpt = try setPluginParameter(
                slot: insertSlot, parameter: parameter,
                targetValue: targetValue, expectedCurrentValue: expectedCurrentValue,
                tolerance: nil, trackName: trackName
            )
        } catch {
            unsolo()
            throw error
        }
        guard let change = changeOpt else {
            unsolo()
            throw LogicianError.trackNotExposed(
                requested: "MCU write of '\(parameter)' in slot \(insertSlot)",
                exposed: "the MCU bridge could not resolve the parameter; nothing was changed (baseline bounce A kept)"
            )
        }
        let appliedValue = change["after"] as? String ?? targetValue
        let beforeValue = change["before"] as? String ?? expectedCurrentValue
        func rollBack() -> Bool {
            for attempt in 0..<3 {
                if attempt > 0 {
                    _ = quiescentStatus()
                    Thread.sleep(forTimeInterval: 1.0)
                }
                let expected = attempt < 2 ? appliedValue : nil
                if ((try? setPluginParameter(
                    slot: insertSlot, parameter: parameter,
                    targetValue: beforeValue, expectedCurrentValue: expected,
                    tolerance: nil, trackName: trackName
                )) ?? nil) != nil {
                    return true
                }
            }
            return false
        }

        let bounceB: [String: Any]
        do {
            reportProgress("bouncing AFTER the change", percent: 50)
            bounceB = try withProgressScope(50...92) {
                try logic.bounceRange(
                    startBar: startBar, endBar: endBar,
                    label: "\(trackName.lowercased())-solo-b", expectedProjectPath: nil
                )
            }
        } catch {
            logic.cancelBounceDialog()
            _ = rollBack() // never leave the change in place after a failed B
            unsolo()
            throw error
        }

        var decision = "kept"
        var restored = true
        if !keepChange {
            if rollBack() {
                decision = "rolled_back"
            } else {
                decision = "rollback_failed"
                restored = false
            }
        }
        unsolo()

        let pathA = bounceA["path"] as? String ?? ""
        let pathB = bounceB["path"] as? String ?? ""
        reportProgress("measuring A against B", percent: 94)
        let metricsA = LogicAccessibility.audioFileMetrics(path: pathA)
        let metricsB = LogicAccessibility.audioFileMetrics(path: pathB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        let soloReport = SoloBounceReport.compose(
            trackName: trackName,
            preexistingSolos: preexistingSolos,
            wasAlreadySoloed: wasAlreadySoloed,
            soloRestored: soloRestored || wasAlreadySoloed
        )

        var evalResult: [String: Any] = [
            "success": true,
            "verified": (restored || keepChange) && (soloRestored || wasAlreadySoloed),
            "state": "evaluated",
            "method": "solo_bounce",
            "decision": decision,
            "solo_restored": soloRestored || wasAlreadySoloed,
            "solo_context": soloReport.context,
            "change": [
                "track": trackName, "track_name": trackName,
                "insert_slot": insertSlot, "parameter": parameter,
                "before": beforeValue, "applied": appliedValue
            ],
            "range": ["start_bar": startBar, "end_bar": endBar],
            "baseline_audio": pathA,
            "after_audio": pathB,
            // The bounces ARE the full renders here, so full == audio.
            "baseline_full_audio": pathA,
            "after_full_audio": pathB,
            "baseline_preview": bounceA["preview_path"] ?? NSNull(),
            "after_preview": bounceB["preview_path"] ?? NSNull(),
            "baseline_metrics": metricsA ?? NSNull(),
            "after_metrics": metricsB ?? NSNull(),
            "deltas": deltas,
            "note": soloReport.note
        ]
        appendWarning(soloReport.warning, to: &evalResult)
        evalResult = attachABAudio(
            to: evalResult, baselinePath: pathA, afterPath: pathB, includeAudio: includeAudio
        )
        // The ear copies' own note last, so "listen to both of these" and
        // "here is what is in them besides the track you asked about" arrive
        // together rather than one of them being quietly false.
        if let suffix = soloReport.listenSuffix,
           let listen = evalResult["listen_note"] as? String {
            evalResult["listen_note"] = listen + suffix
        }
        return evalResult
    }

    /// The selected track's insert slots as shown on the MCU (physical slot
    /// numbering, which can differ from the AX occupied-slot ordinals).
    static func pluginInsertNames() throws -> [String]? {
        // Any earlier call's reason is stale the moment this one starts, and
        // `browserUnavailabilityDetail` prefers the browser's record over the
        // view's — so clear it here rather than let a read quote a write's
        // week-old excuse.
        lastBrowserRefusal = nil
        guard let status = try ensurePluginList(),
              let bottom = status["lcd_bottom"] as? String else { return nil }
        // SETTLED, not raw. `ensurePluginList` answers the moment the top row
        // says "insert list" and Logic paints the slot contents afterwards, so
        // the raw row could hand back a cell the previous view had left there:
        // live 2026-09-03 `logic_list_inserts {route: "mcu"}` reported the
        // strip's own instrument name in slot 8 of a two-insert chain, and
        // read `--` there a minute later. One 120 ms quiescence round in the
        // ordinary case, because the row already read is what the settle is
        // seeded with.
        return settledInsertCells(previous: lcdFields(bottom)) ?? lcdFields(bottom)
    }

    static func enterPluginEdit(slot: Int) throws -> Bool {
        guard (1...8).contains(slot) else { return false }
        let response = try MCUBridge.send(.vpotPress(index: slot - 1))
        guard response.ok else { return false }
        return waitFor(seconds: 2.5, { status in
            guard let assignment = status["assignment"] as? String,
                  let top = status["lcd_top"] as? String else { return false }
            return assignment == MCULCDStrings.Assignment.insertSlot(slot)
                && !top.hasPrefix(MCULCDStrings.insertListFirstSlotLabel)
        }) != nil
    }

    static func parameterPage() -> [(name: String, value: String)]? {
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return nil }
        return zip(lcdFields(top), lcdValueFields(bottom)).map { ($0, $1) }
    }

}
