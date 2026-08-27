import Foundation

// Transport, cycle, playhead, MIDI recording and automation recording.
extension MCPServer {
    func handleGetTransport(_ arguments: [String: Any]) throws -> Any {
        return try logic.getTransport()
    }

    func handleSetPlaying(_ arguments: [String: Any]) throws -> Any {
        guard let playing = arguments["playing"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: playing")
        }
        return try MCUController.setPlaying(playing) ?? logic.setPlaying(playing: playing)
    }

    func handleSetPlayhead(_ arguments: [String: Any]) throws -> Any {
        guard let barNumber = arguments["bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: bar")
        }
        return try logic.setPlayhead(
            barNumber: barNumber,
            beat: arguments["beat"] as? Int
        )
    }

    func handleSetCycle(_ arguments: [String: Any]) throws -> Any {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: enabled")
        }
        return try MCUController.setCycle(enabled) ?? logic.setCycle(enabled: enabled)
    }

    func handleSetCycleRange(_ arguments: [String: Any]) throws -> Any {
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integers: start_bar, end_bar")
        }
        return try logic.setCycleRange(
            startBar: startBar,
            endBar: endBar,
            enabled: arguments["enabled"] as? Bool
        )
    }

    func handleRecordMidi(_ arguments: [String: Any]) throws -> Any {
        let trackName = try requiredString("track_name", in: arguments)
        guard let rawNotes = arguments["notes"] as? [[String: Any]], !rawNotes.isEmpty else {
            throw LogicianError.invalidArguments(
                "notes required: [{pitch, bar, beat?, duration_beats?, velocity?, channel?}, ...]"
            )
        }
        if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
           let header = tracks.first(where: {
               ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
           }),
           header["is_stack"] as? Bool == true {
            throw LogicianError.trackNotExposed(
                requested: "MIDI recording on '\(trackName)'",
                exposed: "'\(trackName)' is a track stack — record on one of its subtracks"
            )
        }
        // Note-name parsing: Logic convention, middle C (MIDI 60) = C3.
        func parsePitch(_ value: Any) throws -> Int {
            if let number = value as? Int {
                guard (0...127).contains(number) else {
                    throw LogicianError.invalidArguments("pitch \(number) outside 0-127")
                }
                return number
            }
            guard let name = value as? String else {
                throw LogicianError.invalidArguments("pitch must be 0-127 or a name like 'C3'/'F#1'")
            }
            let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
            var rest = name.uppercased()
            guard let letter = rest.first, let base = semitones[letter] else {
                throw LogicianError.invalidArguments("unknown pitch name '\(name)'")
            }
            rest.removeFirst()
            var accidental = 0
            if rest.hasPrefix("#") { accidental = 1; rest.removeFirst() }
            else if rest.hasPrefix("B") && rest.count > 1 { accidental = -1; rest.removeFirst() }
            guard let octave = Int(rest) else {
                throw LogicianError.invalidArguments("unknown pitch name '\(name)' (use e.g. 'C3' = MIDI 60)")
            }
            let midi = 60 + (octave - 3) * 12 + base + accidental
            guard (0...127).contains(midi) else {
                throw LogicianError.invalidArguments("pitch '\(name)' outside MIDI 0-127")
            }
            return midi
        }
        struct ParsedNote {
            let pitch: Int; let bar: Int; let beat: Double
            let durationBeats: Double; let velocity: Int; let channel: Int
        }
        var parsed: [ParsedNote] = []
        for raw in rawNotes {
            guard let bar = raw["bar"] as? Int, bar >= 1 else {
                throw LogicianError.invalidArguments("each note needs bar >= 1")
            }
            let velocity = raw["velocity"] as? Int ?? 100
            guard (1...127).contains(velocity) else {
                throw LogicianError.invalidArguments("velocity must be 1-127")
            }
            let channel = raw["channel"] as? Int ?? 1
            guard (1...16).contains(channel) else {
                throw LogicianError.invalidArguments("channel must be 1-16")
            }
            parsed.append(ParsedNote(
                pitch: try parsePitch(raw["pitch"] ?? ""),
                bar: bar,
                beat: (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0,
                durationBeats: (raw["duration_beats"] as? Double)
                    ?? (raw["duration_beats"] as? Int).map(Double.init) ?? 1.0,
                velocity: velocity,
                channel: channel
            ))
        }
        let extraBars: [Int] = ((arguments["cc_events"] as? [[String: Any]]) ?? []).compactMap { $0["bar"] as? Int }
            + ((arguments["pitch_bends"] as? [[String: Any]]) ?? []).compactMap { $0["bar"] as? Int }
        let startBar = arguments["start_bar"] as? Int
            ?? min(parsed.map(\.bar).min()!, extraBars.min() ?? Int.max)
        let lastExtraBeats = extraBars.map { Double($0 - startBar + 1) * 4 }.max() ?? 0
        let lastNoteEndBeats = max(parsed.map {
            Double($0.bar - startBar) * 4 + ($0.beat - 1) + $0.durationBeats
        }.max() ?? 4, lastExtraBeats)
        let endBarGuess = startBar + Int((lastNoteEndBeats / 4).rounded(.up))
        let range = try barRangeSeconds(
            logic: logic, startBar: startBar, endBar: max(endBarGuess, startBar + 1),
            arguments: arguments
        )
        // speed > 1 records at a raised tempo and scales event times:
        // the region lands at identical bar positions in a fraction
        // of the wall time. Default 1 = real time (audible playback).
        let requestedSpeed = (arguments["speed"] as? Double)
            ?? (arguments["speed"] as? Int).map(Double.init) ?? 1.0
        let effectiveSpeed = min(max(requestedSpeed, 1.0), 8.0, 960.0 / range.tempo)
        let recordingTempo = range.tempo * effectiveSpeed
        let msPerBeat = 60000.0 / recordingTempo
        var events: [(offsetMs: Double, bytes: [UInt8])] = []
        for note in parsed {
            let offsetBeats = Double(note.bar - startBar) * range.beatsPerBar + (note.beat - 1)
            guard offsetBeats >= 0 else {
                throw LogicianError.invalidArguments(
                    "note at bar \(note.bar) lies before start_bar \(startBar)"
                )
            }
            let status = UInt8(note.channel - 1)
            events.append((offsetBeats * msPerBeat,
                           [0x90 | status, UInt8(note.pitch), UInt8(note.velocity)]))
            events.append(((offsetBeats + note.durationBeats) * msPerBeat - 1,
                           [0x80 | status, UInt8(note.pitch), 0]))
        }
        // CC and pitch-bend events ride the same timed stream.
        if let rawCC = arguments["cc_events"] as? [[String: Any]] {
            for raw in rawCC {
                guard let bar = raw["bar"] as? Int,
                      let cc = raw["cc"] as? Int, (0...127).contains(cc),
                      let value = raw["value"] as? Int, (0...127).contains(value) else {
                    throw LogicianError.invalidArguments("each cc_event needs bar, cc (0-127) and value (0-127)")
                }
                let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                guard offsetBeats >= 0 else {
                    throw LogicianError.invalidArguments("cc_event at bar \(bar) lies before start_bar \(startBar)")
                }
                events.append((offsetBeats * msPerBeat,
                               [0xB0 | channel, UInt8(cc), UInt8(value)]))
            }
        }
        if let rawBends = arguments["pitch_bends"] as? [[String: Any]] {
            for raw in rawBends {
                guard let bar = raw["bar"] as? Int,
                      let value = raw["value"] as? Int, (-8192...8191).contains(value) else {
                    throw LogicianError.invalidArguments("each pitch_bend needs bar and value (-8192..8191; 0 = center)")
                }
                let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                guard offsetBeats >= 0 else {
                    throw LogicianError.invalidArguments("pitch_bend at bar \(bar) lies before start_bar \(startBar)")
                }
                let fourteen = value + 8192
                events.append((offsetBeats * msPerBeat,
                               [0xE0 | channel, UInt8(fourteen & 0x7F), UInt8((fourteen >> 7) & 0x7F)]))
            }
        }
        events.sort { $0.offsetMs < $1.offsetMs }
        if effectiveSpeed > 1.001 {
            _ = try logic.setTempo(recordingTempo)
        }
        var result: [String: Any]
        do {
            result = try MCUController.recordMIDI(
                logic: logic,
                trackName: trackName,
                trackNumber: arguments["track_number"] as? Int,
                events: events,
                startBar: startBar,
                tailMs: 600,
                tempo: recordingTempo,
                beatsPerBar: range.beatsPerBar,
                syncCompensationMs: (arguments["sync_compensation_ms"] as? Double)
                    ?? (arguments["sync_compensation_ms"] as? Int).map(Double.init) ?? 45
            )
        } catch {
            if effectiveSpeed > 1.001 { _ = try? logic.setTempo(range.tempo) }
            throw error
        }
        if effectiveSpeed > 1.001 {
            let restored = (try? logic.setTempo(range.tempo)) ?? -1
            result["speed"] = effectiveSpeed
            result["recording_tempo"] = recordingTempo
            result["tempo_restored"] = abs(restored - range.tempo) < 0.5
            result["speed_note"] = "Recorded at \(Int(recordingTempo)) BPM and restored to \(Int(range.tempo)); timing jitter scales with speed — quantize if it matters."
        }
        result["track"] = trackName
        result["track_name"] = trackName
        result["notes"] = parsed.count
        result["start_bar"] = startBar
        result["tempo"] = range.tempo
        if arguments["verify_render"] as? Bool ?? true {
            let endBar = startBar + Int((lastNoteEndBeats / range.beatsPerBar).rounded(.up))
            let verifyRange = try barRangeSeconds(
                logic: logic, startBar: startBar, endBar: max(endBar, startBar + 1),
                arguments: arguments
            )
            // `verified` describes THE RECORDING (the stream went out and the
            // transport rolled). The render is a separate OBSERVATION, and a
            // failed observation must never flip the operation's verdict:
            // agents are trained that verified: false means "treat as
            // suspect", so reporting it here made them re-record takes that
            // had landed perfectly. A legitimately quiet passage is the same
            // trap - silence is a fact about the music, not about the write.
            if let render = try? MCUController.renderSelectedTrack(
                projectPath: logic.projectDocumentPath(),
                label: "midi-verify",
                sliceStartSeconds: verifyRange.start, sliceEndSeconds: verifyRange.end,
                logic: logic, trackName: trackName
            ) {
                let slice = render["slice"] as? [String: Any]
                let audible = (slice?["metrics"] as? [String: Any])
                    .flatMap { ($0["peak_db"] as? [Double])?.first }
                    .map { $0 > -120 }
                result["verification_render"] = audible == true ? "ok" : (audible == nil ? "unreadable" : "silent")
                result["verification"] = [
                    "rendered_slice": slice?["path"] ?? NSNull(),
                    "metrics": slice?["metrics"] ?? NSNull(),
                    "note": audible == true
                        ? "freeze render of bars \(startBar)-\(endBar) after recording; non-silent metrics prove the notes landed and sound"
                        : "freeze render of bars \(startBar)-\(endBar) came back silent. The recording itself completed - this can mean the instrument made no sound (muted, no patch, notes out of range), not that the notes are missing."
                ]
            } else {
                result["verification_render"] = "failed"
                result["verification"] = ["note": "the verification render could not run; the recording itself completed. Bounce the range yourself to check the result."]
            }
        }
        return result
    }

    func handleRecordAutomation(_ arguments: [String: Any]) throws -> Any {
        guard let rawPoints = arguments["points"] as? [[String: Any]], rawPoints.count >= 1 else {
            throw LogicianError.invalidArguments("points required: [{bar, beat?, db}, ...]")
        }
        let parameter = (arguments["parameter"] as? String) ?? "volume"
        let automationPoints: [(bar: Int, beat: Double, value: Double)] = try rawPoints.map { raw in
            guard let bar = raw["bar"] as? Int,
                  let value = (raw["value"] as? Double) ?? (raw["value"] as? Int).map(Double.init)
                      ?? (raw["db"] as? Double) ?? (raw["db"] as? Int).map(Double.init) else {
                throw LogicianError.invalidArguments("each point needs bar (int) and value/db (number)")
            }
            let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
            return (bar, beat, value)
        }
        let automationTrack = try requiredString("track_name", in: arguments)
        let ramp = arguments["ramp"] as? Bool ?? true
        let verifyCurve = arguments["verify"] as? Bool ?? true
        let toleranceArg = (arguments["tolerance"] as? Double)
            ?? (arguments["tolerance"] as? Int).map(Double.init)
        var automationResult: [String: Any]
        switch parameter {
        case "volume":
            automationResult = try MCUController.recordVolumeAutomation(
                logic: logic,
                trackName: automationTrack,
                points: automationPoints.map { ($0.bar, $0.beat, $0.value) },
                ramp: ramp,
                verify: verifyCurve
            )
        case "pan":
            automationResult = try MCUController.recordVpotAutomation(
                logic: logic, trackName: automationTrack, kindLabel: "pan",
                points: automationPoints, ramp: ramp, verify: verifyCurve,
                tolerance: toleranceArg ?? 2.0,
                enterView: { _ in
                    // Pan reads and writes through the strip's pan
                    // knob (AX): exact echo, rapid-fire stepwise write.
                    (
                        { [logic] in logic.stripPanValue(trackName: automationTrack) },
                        { [logic] target, budget in
                            try logic.stripPanWrite(
                                trackName: automationTrack, target: target, budget: budget
                            )
                        }
                    )
                },
                restoreView: { }
            )
        case "send":
            guard let sendSlot = arguments["send"] as? Int, (1...8).contains(sendSlot) else {
                throw LogicianError.invalidArguments("parameter 'send' requires send: 1-8")
            }
            automationResult = try MCUController.recordVpotAutomation(
                logic: logic, trackName: automationTrack, kindLabel: "send \(sendSlot) level",
                points: automationPoints, ramp: ramp, verify: verifyCurve,
                tolerance: toleranceArg ?? 1.0,
                enterView: { _ in
                    guard try MCUController.ensureSendView() else {
                        throw LogicianError.trackNotExposed(
                            requested: "the send channel view", exposed: "not reachable"
                        )
                    }
                    try MCUController.sendViewToPage(forSend: sendSlot)
                    let levelIndex = ((sendSlot - 1) % 2) * 4 + 1
                    let read: () -> Double? = {
                        guard let status = MCUController.freshStatus(),
                              let bottom = status["lcd_bottom"] as? String else { return nil }
                        // parseDb handles "-oodB" (new sends start at -inf)
                        return MCUController.parseDb(
                            MCUController.lcdFields(bottom)[levelIndex]
                        )
                    }
                    let write = try MCUController.makeVpotWriter(index: levelIndex, read: read)
                    return (read, write)
                },
                refreshView: {
                    guard try MCUController.ensureSendView() else {
                        throw LogicianError.trackNotExposed(
                            requested: "the send view for verification", exposed: "not reachable"
                        )
                    }
                    try MCUController.sendViewToPage(forSend: sendSlot)
                },
                restoreView: { MCUController.exitToPan() }
            )
        case "plugin":
            guard let slot = arguments["insert_slot"] as? Int else {
                throw LogicianError.invalidArguments("parameter 'plugin' requires insert_slot (1-8)")
            }
            let paramName = try requiredString("plugin_parameter", in: arguments)
            let maxAbs = automationPoints.map { abs($0.value) }.max() ?? 1
            automationResult = try MCUController.recordVpotAutomation(
                logic: logic, trackName: automationTrack,
                kindLabel: "plugin slot \(slot): \(paramName)",
                points: automationPoints, ramp: ramp, verify: verifyCurve,
                tolerance: toleranceArg ?? max(0.5, maxAbs * 0.05),
                enterView: { _ in
                    guard try MCUController.ensurePluginList() != nil,
                          try MCUController.enterPluginEdit(slot: slot) else {
                        throw LogicianError.trackNotExposed(
                            requested: "plugin edit mode for slot \(slot)",
                            exposed: "could not enter"
                        )
                    }
                    guard let found = try MCUController.locateParameter(named: paramName) else {
                        throw LogicianError.trackNotExposed(
                            requested: "parameter '\(paramName)' in slot \(slot)",
                            exposed: "not found on the parameter pages"
                        )
                    }
                    let read: () -> Double? = {
                        MCUController.parameterPage().flatMap {
                            MCUController.parseNumber($0[found].value)
                        }
                    }
                    let write = try MCUController.makeVpotWriter(index: found, read: read)
                    return (read, write)
                },
                refreshView: {
                    guard try MCUController.ensurePluginList() != nil,
                          try MCUController.enterPluginEdit(slot: slot),
                          try MCUController.locateParameter(named: paramName) != nil else {
                        throw LogicianError.trackNotExposed(
                            requested: "the plugin view for verification", exposed: "not reachable"
                        )
                    }
                },
                restoreView: { MCUController.exitToPan() }
            )
        default:
            throw LogicianError.invalidArguments("parameter must be volume, pan, send or plugin")
        }
        automationResult["track"] = automationTrack
        return automationResult
    }
}
