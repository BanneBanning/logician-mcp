import Foundation

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
        return try MCUController.setToggle(
            trackName: toggleTrack, control: control, enabled: enabled
        ) ?? logic.setStripToggle(
            trackName: toggleTrack,
            trackNumber: arguments["track_number"] as? Int,
            control: control,
            enabled: enabled
        )
    }

    func handleSetTrackVolume(_ arguments: [String: Any]) throws -> Any {
        guard let db = (arguments["db"] as? Double) ?? (arguments["db"] as? Int).map(Double.init) else {
            throw LogicianError.invalidArguments("missing number: db")
        }
        let volumeTrack = try requiredString("track_name", in: arguments)
        let tolerance = (arguments["tolerance_db"] as? Double) ?? 0.15
        return try MCUController.setVolume(
            trackName: volumeTrack, targetDb: db, toleranceDb: tolerance
        ) ?? logic.setTrackVolume(
            trackName: volumeTrack,
            trackNumber: arguments["track_number"] as? Int,
            targetDb: db,
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
            position: position
        )
    }

    func handleAddSend(_ arguments: [String: Any]) throws -> Any {
        guard let addedSend = try MCUController.addSend(
            logic: logic,
            trackName: requiredString("track_name", in: arguments),
            destination: requiredString("destination", in: arguments)
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "send creation via the control surface",
                exposed: "the MCU bridge is unavailable"
            )
        }
        var sendPayload = addedSend
        sendPayload["track"] = try requiredString("track_name", in: arguments)
        return sendPayload
    }

    func handleMcuSends(_ arguments: [String: Any]) throws -> Any {
        _ = try logic.selectTrack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
        guard let sends = try MCUController.readSends() else {
            throw LogicianError.trackNotExposed(
                requested: "MCU send view",
                exposed: "the MCU bridge is unavailable or the send view did not appear"
            )
        }
        return [
            "track": try requiredString("track_name", in: arguments),
            "sends": sends,
            "note": "Send slots as the Mackie Control channel view shows them; level in dB, position pre/post, status active/muted."
        ]
    }

    func handleMcuSetSend(_ arguments: [String: Any]) throws -> Any {
        guard let send = arguments["send"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: send (1-8)")
        }
        let levelDb = (arguments["level_db"] as? Double)
            ?? (arguments["level_db"] as? Int).map(Double.init)
        guard let target = levelDb else {
            throw LogicianError.invalidArguments("missing number: level_db")
        }
        _ = try logic.selectTrack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
        guard var sendResult = try MCUController.setSendLevel(
            sendNumber: send,
            targetDb: target,
            expectedCurrentValue: arguments["expected_current_value"] as? String
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU send level write",
                exposed: "the MCU bridge is unavailable or the send view layout was unexpected"
            )
        }
        sendResult["track"] = try requiredString("track_name", in: arguments)
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
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
            "bpm": landed,
            "write_route": "control_bar_tempo_slider",
            "note": "Whole-BPM resolution (the slider steps 1 BPM). Refuses when a tempo map is detected: the slider is position-dependent, so on a mapped project it edits one tempo node rather than the project tempo."
        ]
        if let span = tempoSample.span {
            // What was actually checked, in bars — two agreeing points are
            // evidence of a constant tempo, not proof of one.
            result["tempo_sampled_at_bars"] = [span.startBar, span.endBar]
        }
        appendWarning(tempoSample.writeWarning, to: &result)
        return result
    }
}
