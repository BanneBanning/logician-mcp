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
        if raw.uppercased().contains("ALERT") { return .alert }
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
        while Date() < syncDeadline {
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
        Thread.sleep(forTimeInterval: (Double(durationMs) + tailMs) / 1000)
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
        keepChange: Bool
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

        let renderA = try renderSelectedTrack(
            projectPath: projectPath, label: "\(trackName.lowercased())-a",
            sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
            logic: logic, trackName: trackName
        )
        guard let change = try setPluginParameter(
            slot: insertSlot, parameter: parameter,
            targetValue: targetValue, expectedCurrentValue: expectedCurrentValue,
            tolerance: nil
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
                    tolerance: nil
                )) ?? nil) != nil {
                    return true
                }
            }
            return false
        }

        let renderB: [String: Any]
        do {
            renderB = try renderSelectedTrack(
                projectPath: projectPath, label: "\(trackName.lowercased())-b",
                sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
                logic: logic, trackName: trackName
            )
        } catch {
            // Never leave the change in place after a failed B render.
            _ = rollBack()
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

        func sliceMetrics(_ render: [String: Any]) -> [String: Any]? {
            (render["slice"] as? [String: Any])?["metrics"] as? [String: Any]
        }
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
        evalResult = attachABAudio(
            to: evalResult,
            baselinePath: ((renderA["slice"] as? [String: Any])?["path"] as? String) ?? (renderA["path"] as? String),
            afterPath: ((renderB["slice"] as? [String: Any])?["path"] as? String) ?? (renderB["path"] as? String)
        )
        return evalResult
    }

    /// Attaches baseline+after ear copies as ordered MCP audio blocks so the
    /// A/B can be HEARD in the same result the keep/rollback decision is
    /// made from. First audio block = baseline (A), second = after (B).
    static func attachABAudio(to result: [String: Any], baselinePath: String?, afterPath: String?) -> [String: Any] {
        var result = result
        guard let baselinePath, let afterPath,
              let a = LogicAccessibility.encodeEarCopy(path: baselinePath, maxBytes: 300_000),
              let b = LogicAccessibility.encodeEarCopy(path: afterPath, maxBytes: 300_000) else { return result }
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
        keepChange: Bool
    ) throws -> [String: Any] {
        _ = try logic.selectTrack(
            trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
        )

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
            bounceA = try logic.bounceRange(
                startBar: startBar, endBar: endBar,
                label: "\(trackName.lowercased())-solo-a", expectedProjectPath: nil
            )
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
            changeOpt = try setPluginParameter(
                slot: insertSlot, parameter: parameter,
                targetValue: targetValue, expectedCurrentValue: expectedCurrentValue,
                tolerance: nil
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
                    tolerance: nil
                )) ?? nil) != nil {
                    return true
                }
            }
            return false
        }

        let bounceB: [String: Any]
        do {
            bounceB = try logic.bounceRange(
                startBar: startBar, endBar: endBar,
                label: "\(trackName.lowercased())-solo-b", expectedProjectPath: nil
            )
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
        let metricsA = LogicAccessibility.audioFileMetrics(path: pathA)
        let metricsB = LogicAccessibility.audioFileMetrics(path: pathB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        var evalResult: [String: Any] = [
            "success": true,
            "verified": (restored || keepChange) && (soloRestored || wasAlreadySoloed),
            "state": "evaluated",
            "method": "solo_bounce",
            "decision": decision,
            "solo_restored": soloRestored || wasAlreadySoloed,
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
            "note": "Two offline master bounces with only this track soloed - works on stack subtracks and shared-channel tracks that freeze refuses. Master-bus processing applies to both A and B. No playback occurred."
        ]
        evalResult = attachABAudio(to: evalResult, baselinePath: pathA, afterPath: pathB)
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
            return assignment == "P\(slot)" && !top.hasPrefix("Ins1Pl")
        }) != nil
    }

    static func parameterPage() -> [(name: String, value: String)]? {
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return nil }
        return zip(lcdFields(top), lcdValueFields(bottom)).map { ($0, $1) }
    }

}
