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
        // Smart Tempo write-protection. An Adapt-mode project REWRITES its own
        // tempo map to follow the recording — MIDI recordings included since
        // Logic 10.4.2 — so arming a take here does not merely misplace notes,
        // it destroys the user's tempo track, on a constant-tempo project,
        // with nothing in the result to say so. Read the mode BEFORE anything
        // is armed, and treat "cannot read it" as its own answer: assuming
        // Keep is exactly the assumption that loses the tempo track.
        let tempoModeFix = "set the project tempo mode to KEEP: click the tempo display in the LCD (the small Project Tempo pop-up under the tempo, with the LCD in a display mode that shows it, e.g. 'Beats & Project'), or File → Project Settings → Smart Tempo, then retry."
        let projectTempoMode = logic.projectTempoMode()
        var smartTempoWarning: String?
        switch projectTempoMode {
        case .keep:
            break
        case .adapt:
            throw LogicianError.projectTempoModeUnsafe(
                mode: "ADAPT",
                detail: "an ADAPT-mode project rewrites its tempo map to follow the recording, so this take would overwrite the project's tempo track. Nothing was recorded and nothing was written — \(tempoModeFix)"
            )
        case .auto:
            throw LogicianError.projectTempoModeUnsafe(
                mode: "AUTO",
                detail: "AUTO can resolve to Adapt (it leans that way when the metronome is off), and which one Logic picks for this take cannot be verified from here — so this is refused for the same reason as ADAPT: the tempo track would be rewritten. Nothing was recorded and nothing was written — \(tempoModeFix)"
            )
        case .unreadable, .absent:
            // Proceed, but never silently: the caller has to know that the one
            // destructive side effect of this tool went unchecked.
            smartTempoWarning = "SMART TEMPO NOT VERIFIED. \(projectTempoMode.explanation ?? "") If this project is in ADAPT — or in an AUTO that resolved to Adapt — this recording has REWRITTEN the project's tempo map: check the tempo track and Undo in Logic if it moved. To make later takes safe, \(tempoModeFix)"
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
        // Tempo and meter are resolved ONCE, before the take's length is
        // measured in beats — that math needs the project's real beats-per-bar,
        // which used to be hardcoded to 4 here while the verification render
        // below already used the resolved meter. In 3/4 or 6/8 the two therefore
        // disagreed about where the take ends, and the hardcoded one decided how
        // long a range the tempo/meter were read for.
        let resolved = try resolveTempoAndMeter(logic: logic, arguments: arguments)
        let beatsPerBar = resolved.beatsPerBar
        // The METER map, read once and honoured only when it varies: where the
        // take ENDS is a bar count, and under a changing signature that is a
        // walk over the bars rather than one division. A constant-meter project
        // takes the arithmetic it always did.
        let meterKnowledge = resolveMeterKnowledge()
        let meterMap = meterKnowledge.integratedMap
        let endBar = MCPServer.takeEnd(
            startBar: startBar,
            beatsPerBar: beatsPerBar,
            notes: parsed.map { (bar: $0.bar, beat: $0.beat, durationBeats: $0.durationBeats) },
            extraEventBars: extraBars,
            meterMap: meterMap
        ).endBar
        // What we know about the tempo, resolved ONCE for this invocation: the
        // note scheduling and the verification render's slice cover the same
        // bars, so they share one answer. With Logic's Tempo List readable that
        // answer is the whole map (and no playhead is moved at all); without it,
        // it is the two-point sample that shipped before.
        let knowledge = resolveTempoKnowledge(
            startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar
        )
        let tempoMap = knowledge.readMap
        let range = try MCPServer.barRangeSeconds(
            startBar: startBar, endBar: endBar,
            tempo: resolved.tempo, beatsPerBar: beatsPerBar, map: tempoMap, meterMap: meterMap
        )
        // speed > 1 records at a raised tempo and scales event times:
        // the region lands at identical bar positions in a fraction
        // of the wall time. Default 1 = real time (audible playback).
        let requestedSpeed = (arguments["speed"] as? Double)
            ?? (arguments["speed"] as? Int).map(Double.init) ?? 1.0
        let effectiveSpeed = min(max(requestedSpeed, 1.0), 8.0, 960.0 / range.tempo)
        let recordingTempo = range.tempo * effectiveSpeed
        // Speed mode is a TEMPO WRITE: it converges the control bar's tempo
        // slider up for the take and writes one BPM back afterwards. On a
        // constant-tempo project that restores the project exactly; against a
        // tempo map it does not — the slider edits whichever tempo node the
        // playhead sits on, and the single value written back cannot restore a
        // map. Refuse before anything is written; real-time recording (speed 1)
        // touches no tempo at all and stays available.
        if effectiveSpeed > 1.001, knowledge.isVarying == true {
            let evidence: String
            if let map = tempoMap {
                evidence = "Logic's Tempo List holds \(map.events.count) tempo events"
                    + " (\(map.tempos.map(formattedBPM).joined(separator: ", ")) BPM), so this"
                    + " project has a tempo map"
            } else {
                evidence = knowledge.refusalDetail
                    ?? knowledge.sample?.span?.mismatchClause
                    ?? "the tempo is not constant across the take"
            }
            throw LogicianError.tempoMapUnsafe(
                operation: "logic_record_midi at speed \(String(format: "%g", effectiveSpeed))",
                detail: "\(evidence). Speed mode records"
                    + " at a raised tempo by OVERWRITING the control bar's tempo slider and"
                    + " restoring a SINGLE value afterwards — against a tempo map that write"
                    + " lands on whichever tempo node the playhead sits on and the restore"
                    + " cannot put the map back, so it is destructive. NOTHING was recorded and"
                    + " no tempo was written. Record with speed 1 (real time, the default): it"
                    + " never touches the tempo"
                    + (tempoMap != nil
                        ? ", and the note timing is integrated over the tempo map read from the"
                            + " Tempo List, so the notes land on the right beats."
                        : ". The note timing will still be placed by constant-tempo bar math,"
                            + " which the result's warning describes.")
            )
        }
        let msPerBeat = 60000.0 / recordingTempo
        // Event times. With the tempo map READ, each offset is the integral of
        // the map from the take's first bar line to the event — so a note in
        // bar 9 of a take that crosses a tempo change lands on the beat instead
        // of drifting by everything the change accumulated. Without a map it is
        // the single linear `msPerBeat` ramp that shipped before, unchanged.
        //
        // A CONSTANT map takes the `msPerBeat` path too, deliberately: it is the
        // same arithmetic, and `speed` (which scales `recordingTempo`) is only
        // ever allowed there.
        let takeStartBeats = TempoMap.beatOffset(
            bar: startBar, beatsPerBar: range.beatsPerBar, meter: meterMap
        )
        let takeStartSeconds = tempoMap.map {
            $0.seconds(
                atBeatOffset: takeStartBeats, beatsPerBar: range.beatsPerBar, meter: meterMap
            )
        } ?? 0
        func offsetMs(_ offsetBeats: Double) -> Double {
            guard let tempoMap, !tempoMap.isConstant else { return offsetBeats * msPerBeat }
            return (tempoMap.seconds(
                atBeatOffset: takeStartBeats + offsetBeats, beatsPerBar: range.beatsPerBar,
                meter: meterMap
            ) - takeStartSeconds) * 1000
        }
        /// Beats from the take's first bar line to (`bar`, `beat`) — one bar
        /// times beats-per-bar, unless the meter map says the bars in between
        /// are not all that long.
        func eventBeats(bar: Int, beat: Double) -> Double {
            meterMap?.beatOffset(fromBar: startBar, toBar: bar, beat: beat)
                ?? (Double(bar - startBar) * range.beatsPerBar + (beat - 1))
        }
        var events: [(offsetMs: Double, bytes: [UInt8])] = []
        for note in parsed {
            let offsetBeats = eventBeats(bar: note.bar, beat: note.beat)
            guard offsetBeats >= 0 else {
                throw LogicianError.invalidArguments(
                    "note at bar \(note.bar) lies before start_bar \(startBar)"
                )
            }
            let status = UInt8(note.channel - 1)
            events.append((offsetMs(offsetBeats),
                           [0x90 | status, UInt8(note.pitch), UInt8(note.velocity)]))
            events.append((offsetMs(offsetBeats + note.durationBeats) - 1,
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
                let offsetBeats = eventBeats(bar: bar, beat: beat)
                guard offsetBeats >= 0 else {
                    throw LogicianError.invalidArguments("cc_event at bar \(bar) lies before start_bar \(startBar)")
                }
                events.append((offsetMs(offsetBeats),
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
                let offsetBeats = eventBeats(bar: bar, beat: beat)
                guard offsetBeats >= 0 else {
                    throw LogicianError.invalidArguments("pitch_bend at bar \(bar) lies before start_bar \(startBar)")
                }
                let fourteen = value + 8192
                events.append((offsetMs(offsetBeats),
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
        if let name = projectTempoMode.name {
            result["project_tempo_mode"] = name
        }
        if let block = knowledge.payload { result["tempo_map"] = block }
        result["meter_map"] = meterKnowledge.payload
        appendWarning(
            meterKnowledge.warning(
                sliced: "the note timing and the verification render's slice"
            ),
            to: &result
        )
        // A recording made while the Smart Tempo mode was NOT verifiably Keep
        // can have rewritten the tempo map (Adapt follows the recording), so the
        // cached map is no longer a description of this project. Forget it: the
        // next caller re-reads the Tempo List, which is cheap, while a stale map
        // would integrate confidently wrong boundaries.
        if projectTempoMode != .keep { invalidateTempoMapCache() }
        appendWarning(smartTempoWarning, to: &result)
        // Both honest complaints can be true at once (an unreadable Smart Tempo
        // mode AND a tempo map), so they are appended, never assigned.
        appendWarning(
            knowledge.warning(
                sliced: tempoMap != nil
                    ? "the note timing and the verification render's slice"
                    : "the note timing (bars x beats x 60/BPM) and the verification render's slice"
            ),
            to: &result
        )
        if arguments["verify_render"] as? Bool ?? true {
            // Same range the notes were scheduled against — one resolve, one
            // sample, one set of boundaries.
            let verifyRange = range
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
        // The tempo map, read ONCE for this curve: point placement, the pre-roll
        // bar and the per-point convergence budgets all integrate it. The
        // playhead-chase verification is bar-based already, so it is the proof
        // this arithmetic landed the points on the beats they were asked for.
        let automationTempoMap = resolveTempoMap().map
        // Same for the meter: point placement is a bar-to-beat conversion, and
        // under a changing signature that is not one multiplication.
        let automationMeter = resolveMeterKnowledge()
        let automationMeterMap = automationMeter.integratedMap
        var automationResult: [String: Any]
        switch parameter {
        case "volume":
            automationResult = try MCUController.recordVolumeAutomation(
                logic: logic,
                trackName: automationTrack,
                points: automationPoints.map { ($0.bar, $0.beat, $0.value) },
                ramp: ramp,
                verify: verifyCurve,
                tempoMap: automationTempoMap,
                meterMap: automationMeterMap
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
                restoreView: { },
                tempoMap: automationTempoMap,
                meterMap: automationMeterMap
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
                            MCUController.lcdValueFields(bottom)[levelIndex]
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
                restoreView: { MCUController.exitToPan() },
                tempoMap: automationTempoMap,
                meterMap: automationMeterMap
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
                restoreView: { MCUController.exitToPan() },
                tempoMap: automationTempoMap,
                meterMap: automationMeterMap
            )
        default:
            throw LogicianError.invalidArguments("parameter must be volume, pan, send or plugin")
        }
        automationResult["track"] = automationTrack
        if let map = automationTempoMap, map.source == .tempoList {
            automationResult["tempo_map"] = [
                "source": "tempo_list",
                "events": map.events.count,
                "tempos": map.tempos,
                "constant": map.isConstant,
                "integrated": true
            ]
        }
        automationResult["meter_map"] = automationMeter.payload
        appendWarning(
            automationMeter.warning(sliced: "each point's musical moment"),
            to: &automationResult
        )
        return automationResult
    }
}
