import Foundation

/// What one `logic_set_track_volume` call asks for, resolved against the value
/// the fader is actually sitting at.
///
/// The whole point is that BOTH routes (control surface and inspector strip)
/// already read the current dB before they move anything, so "2 dB louder" and
/// "only if it is still at -6" can be answered from a value the write path has
/// in hand — no extra read, no read-then-guess round trip for the agent.
///
/// Pure and unit-tested: this is arithmetic and a comparison, and getting
/// either wrong writes a wrong fader value that reports itself as verified.
struct VolumeWrite {
    /// `db`, when the caller named an absolute target.
    let absoluteDb: Double?
    /// `relative_db`, when the caller named an offset instead.
    let relativeDb: Double?
    /// `expected_current_db`, the compare-and-set precondition.
    let expectedCurrentDb: Double?

    /// How far a reading may sit from `expected_current_db` and still count as
    /// a match. Results round dB to one decimal and Logic's own steps are
    /// 0.1-0.3 dB apart, so a tighter window would refuse an agent that passed
    /// back exactly the number the previous call reported.
    static let preconditionToleranceDb = 0.5

    init(absoluteDb: Double?, relativeDb: Double?, expectedCurrentDb: Double?) throws {
        guard absoluteDb == nil || relativeDb == nil else {
            throw LogicianError.invalidArguments(
                "db and relative_db are mutually exclusive: db is an ABSOLUTE target,"
                    + " relative_db an offset from the value read immediately before the write."
                    + " Pass one of them. NOTHING was written."
            )
        }
        guard absoluteDb != nil || relativeDb != nil else {
            throw LogicianError.invalidArguments(
                "missing number: db (the absolute target in dB) or relative_db (an offset in dB"
                    + " from the current value, e.g. 2 for '2 dB louder')"
            )
        }
        self.absoluteDb = absoluteDb
        self.relativeDb = relativeDb
        self.expectedCurrentDb = expectedCurrentDb
    }

    private init(absoluteDb: Double) {
        self.absoluteDb = absoluteDb
        self.relativeDb = nil
        self.expectedCurrentDb = nil
    }

    /// For the INTERNAL callers that already hold the exact dB they want
    /// (automation calibration, restores) — no argument parsing, no
    /// precondition, and no way to be mis-constructed.
    static func absolute(_ db: Double) -> VolumeWrite { VolumeWrite(absoluteDb: db) }

    /// The dB to converge on, given what the fader reads right now.
    /// Throws `precondition_failed` when `expected_current_db` disagrees with
    /// that reading — before a single tick is sent.
    func target(currentDb: Double) throws -> Double {
        if let expected = expectedCurrentDb,
           abs(currentDb - expected) > VolumeWrite.preconditionToleranceDb {
            throw LogicianError.currentValueMismatch(
                expected: String(format: "%.1f dB", expected),
                actual: String(format: "%.1f dB", currentDb)
            )
        }
        if let absoluteDb { return absoluteDb }
        return currentDb + (relativeDb ?? 0)
    }
}

// Mixing: volume, pan, mute, solo, sends and tempo.
extension MCPServer {
    func handleSetTrackMute(_ arguments: [String: Any]) throws -> Any {
        try setStripToggle(control: "mute", arguments: arguments)
    }

    func handleSetTrackSolo(_ arguments: [String: Any]) throws -> Any {
        try setStripToggle(control: "solo", arguments: arguments)
    }

    /// Mute and solo differ only in which strip control they drive;
    /// the old switch branched on the tool name to pick one.
    private func setStripToggle(control: String, arguments: [String: Any]) throws -> Any {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: enabled")
        }
        let toggleTrack = try requiredString("track_name", in: arguments)
        // Both routes already read the control's current state before deciding
        // whether to press it, so compare-and-set costs nothing extra here.
        let expected = arguments["expected_current"] as? Bool
        return try MCUController.setToggle(
            trackName: toggleTrack, control: control, enabled: enabled,
            expectedCurrent: expected
        ) ?? logic.setStripToggle(
            trackName: toggleTrack,
            trackNumber: arguments["track_number"] as? Int,
            control: control,
            enabled: enabled,
            expectedCurrent: expected
        )
    }

    func handleSetTrackVolume(_ arguments: [String: Any]) throws -> Any {
        let request = try VolumeWrite(
            absoluteDb: doubleArgument("db", in: arguments),
            relativeDb: doubleArgument("relative_db", in: arguments),
            expectedCurrentDb: doubleArgument("expected_current_db", in: arguments)
        )
        let volumeTrack = try requiredString("track_name", in: arguments)
        let tolerance = (arguments["tolerance_db"] as? Double) ?? 0.15
        return try MCUController.setVolume(
            trackName: volumeTrack, request: request, toleranceDb: tolerance
        ) ?? logic.setTrackVolume(
            trackName: volumeTrack,
            trackNumber: arguments["track_number"] as? Int,
            request: request,
            toleranceDb: tolerance
        )
    }

    func handleSetTrackPan(_ arguments: [String: Any]) throws -> Any {
        guard let position = arguments["position"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: position")
        }
        return try logic.setTrackPan(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            position: position,
            expectedCurrentPosition: arguments["expected_current_position"] as? Int
        )
    }

    func handleAddSend(_ arguments: [String: Any]) throws -> Any {
        let track = try requiredString("track_name", in: arguments)
        let level = (arguments["level_db"] as? Double)
            ?? (arguments["level_db"] as? Int).map(Double.init)
        guard let addedSend = try MCUController.addSend(
            logic: logic,
            trackName: track,
            destination: requiredString("destination", in: arguments),
            // The level write below runs in the send view this call is
            // already in, so hand it the view instead of walking home and
            // pressing straight back in. Everything after this point is
            // responsible for the restore.
            restoringView: level == nil
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "send creation via the control surface",
                exposed: "the MCU bridge is unavailable"
            )
        }
        var sendPayload = addedSend
        sendPayload["track"] = track
        // "Send the snare to the plate at -12" is ONE thought and used to be two
        // calls, with the mix silently wrong in between: a new send lands at
        // -oo dB, so an agent that stopped after this tool had created an
        // inaudible send and reported success (COVERAGE U5). The level is set
        // through the same tool logic_mcu_set_send uses, on the strip this call
        // has already selected.
        guard let level, let slot = addedSend["send"] as? Int else { return sendPayload }
        do {
            guard let levelled = try MCUController.setSendLevel(
                sendNumber: slot, targetDb: level, expectedCurrentValue: nil
            ) else {
                // `setSendLevel` restores the view from its own defer, but
                // it can refuse before registering one. Exiting twice is a
                // ~100 ms no-op on a surface already in Pan; not exiting at
                // all leaves the send view standing for the next call.
                MCUController.exitToPan()
                throw LogicianError.trackNotExposed(
                    requested: "the send level vpot", exposed: "the send view did not answer"
                )
            }
            sendPayload["level"] = levelled["after"] ?? NSNull()
            sendPayload["level_db_requested"] = level
            sendPayload["level_verified"] = levelled["verified"] ?? false
            sendPayload["level_write_route"] = levelled["write_route"] ?? NSNull()
            sendPayload["state"] = "added_and_levelled"
        } catch {
            // The SEND EXISTS — that write is verified and must not be reported
            // as a failure. What failed is the level, so the send is sitting at
            // -oo dB and the result says exactly that rather than letting an
            // agent assume the whole intent landed.
            // Same reasoning as above: the add handed its restore to the
            // level write, and the level write can throw before it owns one.
            MCUController.exitToPan()
            sendPayload["level_verified"] = false
            sendPayload["level_db_requested"] = level
            sendPayload["level"] = "-oo dB (unchanged)"
            appendWarning(
                "The send WAS created and verified, but its level could not be set to"
                    + " \(formattedBPM(level)) dB (\(error.localizedDescription)). It is therefore"
                    + " still at -oo dB and inaudible: set it with logic_mcu_set_send"
                    + " {send: \(slot), level_db: \(level)} before judging the mix.",
                to: &sendPayload
            )
        }
        return sendPayload
    }

    func handleMcuSends(_ arguments: [String: Any]) throws -> Any {
        // Selection routes itself: a track through Accessibility, an
        // output/aux/bus strip through the control surface (the send view
        // shows the SELECTED strip either way).
        let target = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
        )
        guard let sends = try MCUController.readSends() else {
            throw LogicianError.trackNotExposed(
                requested: "MCU send view",
                exposed: "the MCU bridge is unavailable or the send view did not appear"
            )
        }
        var sendsPayload: [String: Any] = [
            "track": target.name,
            "track_name": target.name,
            "sends": sends,
            "note": "Send slots as the Mackie Control channel view shows them; level in dB, position pre/post, status active/muted."
        ]
        sendsPayload.merge(target.resultFields) { current, _ in current }
        return sendsPayload
    }

    func handleMcuSetSend(_ arguments: [String: Any]) throws -> Any {
        guard let send = arguments["send"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: send (1-8)")
        }
        let levelDb = (arguments["level_db"] as? Double)
            ?? (arguments["level_db"] as? Int).map(Double.init)
        guard let targetDb = levelDb else {
            throw LogicianError.invalidArguments("missing number: level_db")
        }
        let target = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
        )
        guard var sendResult = try MCUController.setSendLevel(
            sendNumber: send,
            targetDb: targetDb,
            expectedCurrentValue: arguments["expected_current_value"] as? String
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU send level write",
                exposed: "the MCU bridge is unavailable or the send view layout was unexpected"
            )
        }
        sendResult["track"] = target.name
        sendResult["track_name"] = target.name
        sendResult.merge(target.resultFields) { current, _ in current }
        return sendResult
    }

    func handleSetTempo(_ arguments: [String: Any]) throws -> Any {
        let bpm = (arguments["bpm"] as? Double)
            ?? (arguments["bpm"] as? Int).map(Double.init)
        guard let targetBpm = bpm else {
            throw LogicianError.invalidArguments("missing number: bpm")
        }
        let transportBefore = try logic.getTransport()
        let currentBpm = transportBefore["tempo"] as? Double
        if let expected = (arguments["expected_current_bpm"] as? Double)
            ?? (arguments["expected_current_bpm"] as? Int).map(Double.init) {
            guard let current = currentBpm, abs(current - expected) < 0.5 else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(expected) BPM",
                    actual: "\(currentBpm.map { "\($0)" } ?? "unreadable") BPM"
                )
            }
        }
        // The value this tool writes is POSITION-DEPENDENT. The control bar shows
        // the tempo at the playhead, so on a project with a tempo map a slider
        // write does not set "the project tempo" — it edits the tempo node the
        // playhead happens to sit on, which is an edit to the user's tempo track
        // that nothing in the result would have mentioned. Two reads answer
        // whether such a map exists; see `sampleTempoAgainstProjectStart` for why
        // bar 1 is the second point and what two points cannot prove.
        //
        // The Tempo List answers it OUTRIGHT when it can be read (item 3): the
        // whole map, exactly, with no playhead travel at all — where the sample
        // costs ~0.13 s per bar between the playhead and bar 1. So the map is
        // tried first, and the sample is only the fallback.
        let resolvedMap = resolveTempoMap()
        if let map = resolvedMap.map, map.source == .tempoList {
            if !map.isConstant {
                throw LogicianError.tempoMapUnsafe(
                    operation: "logic_set_tempo",
                    detail: "the project has a TEMPO MAP — Logic's Tempo List holds"
                        + " \(map.events.count) tempo events"
                        + " (\(map.tempos.map(formattedBPM).joined(separator: ", ")) BPM), read row"
                        + " by row out of the Tempo tab of the List Editors. This tool writes ONE"
                        + " slider, and that slider shows and sets the tempo AT THE PLAYHEAD, so"
                        + " on a mapped project it would edit whichever tempo node the playhead"
                        + " sits on instead of the project tempo — and which node Logic edits, or"
                        + " whether it creates a new one, has not been verified from here."
                        + " NOTHING was written. Change the tempo where the map lives: Logic's"
                        + " tempo track, or the Tempo List (View > List Editors > Tempo), where"
                        + " every tempo event is an editable row. There is deliberately no"
                        + " override argument — parking the playhead and passing"
                        + " expected_current_bpm would still be a single-slider write with"
                        + " unverified semantics, so it is not offered as a workaround."
                )
            }
            let landed = try logic.setTempo(targetBpm)
            // The write moved a tempo node; whatever the cache holds describes
            // the map as it was BEFORE it.
            invalidateTempoMapCache()
            return [
                "success": true,
                "verified": true,
                "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
                "bpm": landed,
                "write_route": "control_bar_tempo_slider",
                "tempo_map": [
                    "source": "tempo_list",
                    "events": map.events.count,
                    "tempos": map.tempos,
                    "constant": true
                ],
                "note": "Whole-BPM resolution (the slider steps 1 BPM). Logic's Tempo List was read and holds a single tempo, so this write set the project tempo rather than one node of a map. No playhead was moved."
            ]
        }
        let tempoSample = logic.sampleTempoAgainstProjectStart()
        if let span = tempoSample.span, !span.isConstant {
            throw LogicianError.tempoMapUnsafe(
                operation: "logic_set_tempo",
                detail: "the project has a TEMPO MAP — \(tempoSample.refusalDetail ?? span.mismatchClause)"
                    + ", both read off the control bar, which shows the tempo AT THE PLAYHEAD."
                    + " This tool writes ONE slider, so on a mapped project it would edit"
                    + " whichever tempo node the playhead sits on (bar \(span.startBar)) instead"
                    + " of the project tempo — and which node Logic edits, or whether it creates"
                    + " a new one, has not been verified from here. NOTHING was written. Change"
                    + " the tempo where the map lives: Logic's tempo track, or the Tempo List"
                    + " (the Tempo tab of the List Editors, also openable as a floating window),"
                    + " where every tempo event is an editable row. There is deliberately no"
                    + " override argument — parking the playhead and passing expected_current_bpm"
                    + " would still be a single-slider write with unverified semantics, so it is"
                    + " not offered as a workaround."
            )
        }
        let landed = try logic.setTempo(targetBpm)
        // Same reason as above: a tempo write can have edited a node of a map
        // that a later call would otherwise read out of the cache.
        invalidateTempoMapCache()
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
            "bpm": landed,
            "write_route": "control_bar_tempo_slider",
            "note": "Whole-BPM resolution (the slider steps 1 BPM). Refuses when a tempo map is detected: the slider is position-dependent, so on a mapped project it edits one tempo node rather than the project tempo."
        ]
        if let failure = resolvedMap.failure {
            result["tempo_map_read"] = "unavailable: \(failure.reason)"
        }
        if let span = tempoSample.span {
            // What was actually checked, in bars — two agreeing points are
            // evidence of a constant tempo, not proof of one.
            result["tempo_sampled_at_bars"] = [span.startBar, span.endBar]
        }
        appendWarning(tempoSample.writeWarning, to: &result)
        return result
    }
}
