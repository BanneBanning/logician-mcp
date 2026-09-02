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
    /// the plain "Logic MCP MIDI In" port while Logic records: playhead is
    /// parked one bar early, record is pressed, and the stream starts on the
    /// observed timecode crossing into start_bar — so count-in settings do
    /// not matter. Wholly data-plane: no dialogs, no files, no keypresses.
    static func recordMIDI(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        events: [(offsetMs: Double, bytes: [UInt8])],
        startBar: Int, tailMs: Double,
        tempo: Double, beatsPerBar: Double, syncCompensationMs: Double
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
        let savedBar = transport["playhead_bar"] as? Int

        var selected = false
        if let channel = ((try? findChannel(trackName: trackName)) ?? nil) {
            selected = (try? selectFoundChannel(channel)) == true
        }
        if !selected {
            _ = try logic.selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }

        _ = try logic.setPlayhead(barNumber: startBar - 1, beat: nil)
        // A record press within ~0.5 s of the playhead LCD converge gets
        // swallowed by Logic while the field is still hot — settle first.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.6)
        // Now the decisive check: setPlayhead verified the playhead against
        // Logic's own control bar, and the display has settled after that
        // move — so the bar it shows must be the bar we parked at. SMPTE
        // digits that merely LOOK like a position fail here. Still nothing
        // recorded; restore the playhead ourselves since the cleanup `defer`
        // below is not armed yet.
        do {
            try requireBeatsDisplay(
                expectedBar: startBar - 1,
                operation: "MIDI recording sync at bar \(startBar)"
            )
        } catch {
            if let bar = savedBar { _ = try? logic.setPlayhead(barNumber: bar, beat: nil) }
            throw error
        }
        try press("record")
        defer {
            _ = try? MCUBridge.send(.midiAbort) // stuck-note safety
            _ = try? setPlaying(false)
            if let bar = savedBar {
                _ = try? logic.setPlayhead(barNumber: bar, beat: nil)
            }
        }
        reportProgress("record pressed; waiting for the transport", percent: 10)
        // Record LED confirms Logic is actually rolling/armed.
        guard pollStatus(until: { ledLit(0x5F, in: $0) }) != nil else {
            throw LogicianError.verificationFailed(
                requested: "recording started",
                actual: "the MCU record LED never lit",
                restored: true
            )
        }
        // Sync on the timecode crossing into the LAST BEAT of the pre-roll
        // bar: from there exactly one beat remains to start_bar, so events
        // are scheduled one beat ahead minus the measured display latency
        // (~50 ms edge-detect lag when syncing on the bar line itself).
        let msPerBeat = 60000.0 / tempo
        let lastBeat = max(Int(beatsPerBar.rounded()), 1)
        let syncDeadline = Date().addingTimeInterval(20)
        var leadMs = 0.0
        var synced = false
        // The parked display can already read e.g. "beat 4" from an earlier
        // stop (setPlayhead only converges the bar), so no edge may be
        // accepted until the timecode has visibly CHANGED — proof that the
        // transport is rolling, after which beat values are trustworthy.
        let parkedTimecode = freshStatus()?["timecode"] as? String
        var rolling = false
        var recordRetried = false
        let rollDeadline = Date().addingTimeInterval(4)
        reportProgress("armed; waiting for the playhead to reach bar \(startBar)", percent: 20)
        while Date() < syncDeadline {
            // The `defer` above aborts the stream, stops the transport and puts
            // the playhead back, so a cancellation here unwinds through exactly
            // the same path a thrown sync failure does.
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
            if let position = timecodeBarBeat() {
                if position.bar >= startBar {
                    synced = true // missed the beat edge; fall back to the bar line
                    break
                }
                if position.bar == startBar - 1, position.beat >= lastBeat {
                    synced = true
                    leadMs = msPerBeat
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard synced else {
            throw LogicianError.verificationFailed(
                requested: "playhead reaching bar \(startBar)",
                actual: "the timecode never crossed into the start bar within 20 s",
                restored: true
            )
        }
        let shiftMs = max(0, leadMs - syncCompensationMs)
        let streamResponse = try MCUBridge.send(.midiStream(
            events: events.map {
                MIDIStreamEvent(offsetMs: $0.offsetMs + shiftMs, bytes: $0.bytes)
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
        // defer handles abort, stop and playhead restore
        // `verified` belongs to the RECORDING: reaching here means the
        // transport was rolling, the stream went out with host-time stamps,
        // and the stop/restore path completed - anything less throws above.
        // Whether the result SOUNDS is a separate observation the caller
        // reports as verification_render.
        return [
            "success": true,
            "verified": true,
            "events_streamed": events.count,
            "stream_duration_ms": durationMs,
            "write_route": "midi_in_record"
        ]
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
        guard let status = try ensurePluginList(),
              let bottom = status["lcd_bottom"] as? String else { return nil }
        return lcdFields(bottom)
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
