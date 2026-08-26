import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCPServer {
    /// Enforces the `additionalProperties: false` every schema declares. An
    /// argument a tool does not read must be an ERROR, never silently
    /// dropped: an agent that passes expected_current_value to a setter
    /// without compare-and-set support would otherwise be told the write
    /// succeeded and believe a precondition was checked that never was.
    private func rejectUnknownArguments(tool: String, arguments: [String: Any]) throws {
        guard let definition = toolDefinitions().first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              (schema["additionalProperties"] as? Bool) == false,
              let properties = schema["properties"] as? [String: Any] else { return }
        let unknown = arguments.keys.filter { properties[$0] == nil }.sorted()
        guard !unknown.isEmpty else { return }
        throw DemoError.invalidArguments(
            "\(tool) does not accept: \(unknown.joined(separator: ", ")). "
                + "Accepted: \(properties.keys.sorted().joined(separator: ", ")). "
                + "The argument was NOT applied - do not assume it took effect."
        )
    }

    func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            try rejectUnknownArguments(tool: name, arguments: arguments)
            let payload: Any
            switch name {
            case "logic_health":
                var health = logic.health()
                // Doctor checks: every setup step as data, with the fix in text.
                MCUBridge.ensureRunning()
                let bridge = (try? MCUBridge.send(["cmd": "status"])) ?? [:]
                let bridgeUp = bridge["ok"] as? Bool == true
                health["bridge_running"] = bridgeUp
                health["mcu_connected"] = (bridge["received_events"] as? Int ?? 0) > 0
                if !bridgeUp {
                    health["bridge_fix"] = "the bridge subprocess could not be started (self-spawn with --bridge failed)"
                } else if (bridge["received_events"] as? Int ?? 0) == 0 {
                    health["mcu_fix"] = "no MIDI from Logic yet: add a Mackie Control in Logic > Control Surfaces > Setup with ports 'Logic MCP MCU', or play something"
                }
                let registered = Set(KeyCommandRegistry.commands().compactMap { $0["name"] as? String })
                health["key_commands"] = KeyCommandRegistry.standardCommands.map { command in
                    ["name": command.name, "registered": registered.contains(command.name)]
                }
                if !KeyCommandRegistry.standardCommands.allSatisfy({ registered.contains($0.name) }) {
                    health["key_commands_fix"] = "run logic_setup_key_commands (or let the first tool that needs one learn it automatically); if commands are listed as registered but never fire, run it with relearn: true - port recreation orphans the bindings in Logic"
                }
                if health["accessibility_trusted"] as? Bool != true {
                    health["accessibility_fix"] = "grant Accessibility in System Settings: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                }
                payload = health

            case "logic_list_windows":
                payload = ["windows": try logic.listWindows()]

            case "logic_list_tracks":
                payload = try logic.listTracks()

            case "logic_list_inserts":
                payload = try logic.listInserts(trackName: requiredString("track_name", in: arguments))

            case "logic_bounce_range":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                do {
                    payload = try logic.bounceRange(
                        startBar: startBar,
                        endBar: endBar,
                        label: (arguments["label"] as? String) ?? "bounce",
                        expectedProjectPath: arguments["expected_project_path"] as? String
                    )
                } catch {
                    // A modal Bounce dialog left open freezes EVERYTHING —
                    // always cancel it before surfacing the error.
                    logic.cancelBounceDialog()
                    throw error
                }

            case "logic_evaluate_change":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                if (arguments["method"] as? String) == "render" {
                    guard let slot = arguments["insert_slot"] as? Int else {
                        throw DemoError.invalidArguments(
                            "method 'render' requires insert_slot (1-8, MCU physical slot; list with logic_mcu_plugin_inserts)"
                        )
                    }
                    let range = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: endBar, arguments: arguments
                    )
                    payload = try MCUController.evaluateChangeRendered(
                        logic: logic,
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        insertSlot: slot,
                        parameter: requiredString("parameter", in: arguments),
                        expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                        targetValue: requiredString("target_value", in: arguments),
                        startBar: startBar, endBar: endBar,
                        startSeconds: range.start, endSeconds: range.end,
                        tempo: range.tempo,
                        keepChange: arguments["keep_change"] as? Bool ?? false
                    )
                    break
                }
                if (arguments["method"] as? String) == "solo_bounce" {
                    guard let slot = arguments["insert_slot"] as? Int else {
                        throw DemoError.invalidArguments(
                            "method 'solo_bounce' requires insert_slot (1-8, MCU physical slot; list with logic_mcu_plugin_inserts)"
                        )
                    }
                    payload = try MCUController.evaluateChangeSoloBounced(
                        logic: logic,
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        insertSlot: slot,
                        parameter: requiredString("parameter", in: arguments),
                        expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                        targetValue: requiredString("target_value", in: arguments),
                        startBar: startBar, endBar: endBar,
                        keepChange: arguments["keep_change"] as? Bool ?? false
                    )
                    break
                }
                if (arguments["method"] as? String) == "bounce" {
                    do {
                        payload = try logic.evaluateChangeBounced(
                        trackName: requiredString("track_name", in: arguments),
                        pluginName: requiredString("plugin_name", in: arguments),
                        insertIndex: arguments["insert_index"] as? Int,
                        parameter: requiredString("parameter", in: arguments),
                        expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                        targetValue: requiredString("target_value", in: arguments),
                        startBar: startBar,
                        endBar: endBar,
                        keepChange: arguments["keep_change"] as? Bool ?? false,
                        expectedProjectPath: arguments["expected_project_path"] as? String
                    )
                    } catch {
                        logic.cancelBounceDialog()
                        throw error
                    }
                    break
                }
                throw DemoError.invalidArguments(
                    "method must be one of 'render' (single-track freeze A/B, needs insert_slot), "
                        + "'bounce' (master A/B, needs plugin_name) or 'solo_bounce' "
                        + "(soloed master A/B for tracks freeze refuses, needs insert_slot)"
                )

            case "logic_mcu_plugin_inserts":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let inserts = try MCUController.pluginInsertNames() else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU plugin insert list",
                        exposed: "the MCU bridge is unavailable or the insert list did not appear"
                    )
                }
                MCUController.exitToPan()
                payload = [
                    "track": try requiredString("track_name", in: arguments),
                    "mcu_slots": inserts.enumerated().map { index, name in
                        ["slot": index + 1, "plugin": name.isEmpty ? "--" : name]
                    },
                    "note": "MCU slot numbers are physical insert positions and can differ from AX occupied-slot ordinals."
                ]

            case "logic_mcu_plugin_parameters":
                guard let slot = arguments["insert_slot"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
                }
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                let pluginMaxPages = arguments["max_pages"] as? Int ?? 12
                guard let listStatus = try MCUController.ensurePluginList(),
                      try MCUController.enterPluginEdit(slot: slot),
                      let capped = try MCUController.parameterPagesCapped(
                          cacheKey: (listStatus["lcd_bottom"] as? String).flatMap { bottom -> String? in
                              let name = MCUController.lcdFields(bottom)[slot - 1]
                                  .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                              return name.isEmpty || name == "--" ? nil : name
                          },
                          maxPages: pluginMaxPages
                      ) else {
                    MCUController.exitToPan()
                    throw DemoError.trackNotExposed(
                        requested: "MCU parameter pages for slot \(slot)",
                        exposed: "could not enter the plugin edit mode"
                    )
                }
                MCUController.exitToPan()
                var pluginPayload: [String: Any] = [
                    "track": try requiredString("track_name", in: arguments),
                    "insert_slot": slot,
                    "pages": capped.pages.count,
                    "pages_total": capped.total,
                    "parameters": capped.pages.enumerated().flatMap { pageIndex, page in
                        page.map { ["name": $0.name, "value": $0.value, "page": pageIndex + 1] }
                    }
                ]
                if capped.truncated {
                    pluginPayload["truncated"] = true
                    pluginPayload["note"] = "Showing \(capped.pages.count) of \(capped.total) pages (each uncached page costs ~1.7 s of LCD indicator fade). Pass max_pages for more."
                }
                payload = pluginPayload

            case "logic_mcu_set_plugin_parameter":
                guard let slot = arguments["insert_slot"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
                }
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let result = try MCUController.setPluginParameter(
                    slot: slot,
                    parameter: requiredString("parameter", in: arguments),
                    targetValue: requiredString("target_value", in: arguments),
                    expectedCurrentValue: arguments["expected_current_value"] as? String,
                    tolerance: arguments["tolerance"] as? Double,
                    trackName: requiredString("track_name", in: arguments)
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU plugin parameter control",
                        exposed: "the MCU bridge is unavailable or the plugin edit mode could not be entered"
                    )
                }
                payload = result

            case "logic_mcu_instrument_parameters":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                let instrumentMaxPages = arguments["max_pages"] as? Int ?? 12
                guard let entered = try MCUController.enterInstrumentEdit(
                    trackName: requiredString("track_name", in: arguments)
                ), let capped = try MCUController.parameterPagesCapped(
                    cacheKey: "instrument:" + entered.name,
                    maxPages: instrumentMaxPages
                ) else {
                    MCUController.exitToPan()
                    throw DemoError.trackNotExposed(
                        requested: "MCU instrument parameters",
                        exposed: "no instrument in the slot, or the edit mode could not be entered"
                    )
                }
                MCUController.exitToPan()
                var instrumentPayload: [String: Any] = [
                    "track": try requiredString("track_name", in: arguments),
                    "slot_type": "instrument",
                    "instrument": entered.name,
                    "pages": capped.pages.count,
                    "pages_total": capped.total,
                    "parameters": capped.pages.enumerated().flatMap { pageIndex, page in
                        page.map { ["name": $0.name, "value": $0.value, "page": pageIndex + 1] }
                    }
                ]
                if capped.truncated {
                    instrumentPayload["truncated"] = true
                    instrumentPayload["note"] = "Showing \(capped.pages.count) of \(capped.total) pages (each uncached page costs ~1.7 s of LCD indicator fade). Pass max_pages for more."
                }
                payload = instrumentPayload

            case "logic_mcu_set_instrument_parameter":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let result = try MCUController.setInstrumentParameter(
                    trackName: requiredString("track_name", in: arguments),
                    parameter: requiredString("parameter", in: arguments),
                    targetValue: requiredString("target_value", in: arguments),
                    expectedCurrentValue: arguments["expected_current_value"] as? String,
                    tolerance: arguments["tolerance"] as? Double
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU instrument parameter control",
                        exposed: "no instrument in the slot, or the edit mode could not be entered"
                    )
                }
                payload = result

            case "logic_mcu_status":
                payload = MCUBridge.status()

            case "logic_mcu_sends":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                guard let sends = try MCUController.readSends() else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU send view",
                        exposed: "the MCU bridge is unavailable or the send view did not appear"
                    )
                }
                payload = [
                    "track": try requiredString("track_name", in: arguments),
                    "sends": sends,
                    "note": "Send slots as the Mackie Control channel view shows them; level in dB, position pre/post, status active/muted."
                ]

            case "logic_mcu_set_send":
                guard let send = arguments["send"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: send (1-8)")
                }
                let levelDb = (arguments["level_db"] as? Double)
                    ?? (arguments["level_db"] as? Int).map(Double.init)
                guard let target = levelDb else {
                    throw DemoError.invalidArguments("missing number: level_db")
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
                    throw DemoError.trackNotExposed(
                        requested: "MCU send level write",
                        exposed: "the MCU bridge is unavailable or the send view layout was unexpected"
                    )
                }
                sendResult["track"] = try requiredString("track_name", in: arguments)
                payload = sendResult

            case "logic_record_automation":
                guard let rawPoints = arguments["points"] as? [[String: Any]], rawPoints.count >= 1 else {
                    throw DemoError.invalidArguments("points required: [{bar, beat?, db}, ...]")
                }
                let parameter = (arguments["parameter"] as? String) ?? "volume"
                let automationPoints: [(bar: Int, beat: Double, value: Double)] = try rawPoints.map { raw in
                    guard let bar = raw["bar"] as? Int,
                          let value = (raw["value"] as? Double) ?? (raw["value"] as? Int).map(Double.init)
                              ?? (raw["db"] as? Double) ?? (raw["db"] as? Int).map(Double.init) else {
                        throw DemoError.invalidArguments("each point needs bar (int) and value/db (number)")
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
                        throw DemoError.invalidArguments("parameter 'send' requires send: 1-8")
                    }
                    automationResult = try MCUController.recordVpotAutomation(
                        logic: logic, trackName: automationTrack, kindLabel: "send \(sendSlot) level",
                        points: automationPoints, ramp: ramp, verify: verifyCurve,
                        tolerance: toleranceArg ?? 1.0,
                        enterView: { _ in
                            guard try MCUController.ensureSendView() else {
                                throw DemoError.trackNotExposed(
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
                                throw DemoError.trackNotExposed(
                                    requested: "the send view for verification", exposed: "not reachable"
                                )
                            }
                            try MCUController.sendViewToPage(forSend: sendSlot)
                        },
                        restoreView: { MCUController.exitToPan() }
                    )
                case "plugin":
                    guard let slot = arguments["insert_slot"] as? Int else {
                        throw DemoError.invalidArguments("parameter 'plugin' requires insert_slot (1-8)")
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
                                throw DemoError.trackNotExposed(
                                    requested: "plugin edit mode for slot \(slot)",
                                    exposed: "could not enter"
                                )
                            }
                            guard let found = try MCUController.locateParameter(named: paramName) else {
                                throw DemoError.trackNotExposed(
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
                                throw DemoError.trackNotExposed(
                                    requested: "the plugin view for verification", exposed: "not reachable"
                                )
                            }
                        },
                        restoreView: { MCUController.exitToPan() }
                    )
                default:
                    throw DemoError.invalidArguments("parameter must be volume, pan, send or plugin")
                }
                automationResult["track"] = automationTrack
                payload = automationResult

            case "logic_record_midi":
                let trackName = try requiredString("track_name", in: arguments)
                guard let rawNotes = arguments["notes"] as? [[String: Any]], !rawNotes.isEmpty else {
                    throw DemoError.invalidArguments(
                        "notes required: [{pitch, bar, beat?, duration_beats?, velocity?, channel?}, ...]"
                    )
                }
                if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
                   let header = tracks.first(where: {
                       ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
                   }),
                   header["is_stack"] as? Bool == true {
                    throw DemoError.trackNotExposed(
                        requested: "MIDI recording on '\(trackName)'",
                        exposed: "'\(trackName)' is a track stack — record on one of its subtracks"
                    )
                }
                // Note-name parsing: Logic convention, middle C (MIDI 60) = C3.
                func parsePitch(_ value: Any) throws -> Int {
                    if let number = value as? Int {
                        guard (0...127).contains(number) else {
                            throw DemoError.invalidArguments("pitch \(number) outside 0-127")
                        }
                        return number
                    }
                    guard let name = value as? String else {
                        throw DemoError.invalidArguments("pitch must be 0-127 or a name like 'C3'/'F#1'")
                    }
                    let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
                    var rest = name.uppercased()
                    guard let letter = rest.first, let base = semitones[letter] else {
                        throw DemoError.invalidArguments("unknown pitch name '\(name)'")
                    }
                    rest.removeFirst()
                    var accidental = 0
                    if rest.hasPrefix("#") { accidental = 1; rest.removeFirst() }
                    else if rest.hasPrefix("B") && rest.count > 1 { accidental = -1; rest.removeFirst() }
                    guard let octave = Int(rest) else {
                        throw DemoError.invalidArguments("unknown pitch name '\(name)' (use e.g. 'C3' = MIDI 60)")
                    }
                    let midi = 60 + (octave - 3) * 12 + base + accidental
                    guard (0...127).contains(midi) else {
                        throw DemoError.invalidArguments("pitch '\(name)' outside MIDI 0-127")
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
                        throw DemoError.invalidArguments("each note needs bar >= 1")
                    }
                    let velocity = raw["velocity"] as? Int ?? 100
                    guard (1...127).contains(velocity) else {
                        throw DemoError.invalidArguments("velocity must be 1-127")
                    }
                    let channel = raw["channel"] as? Int ?? 1
                    guard (1...16).contains(channel) else {
                        throw DemoError.invalidArguments("channel must be 1-16")
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
                        throw DemoError.invalidArguments(
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
                            throw DemoError.invalidArguments("each cc_event needs bar, cc (0-127) and value (0-127)")
                        }
                        let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                        let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                        let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                        guard offsetBeats >= 0 else {
                            throw DemoError.invalidArguments("cc_event at bar \(bar) lies before start_bar \(startBar)")
                        }
                        events.append((offsetBeats * msPerBeat,
                                       [0xB0 | channel, UInt8(cc), UInt8(value)]))
                    }
                }
                if let rawBends = arguments["pitch_bends"] as? [[String: Any]] {
                    for raw in rawBends {
                        guard let bar = raw["bar"] as? Int,
                              let value = raw["value"] as? Int, (-8192...8191).contains(value) else {
                            throw DemoError.invalidArguments("each pitch_bend needs bar and value (-8192..8191; 0 = center)")
                        }
                        let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                        let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                        let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                        guard offsetBeats >= 0 else {
                            throw DemoError.invalidArguments("pitch_bend at bar \(bar) lies before start_bar \(startBar)")
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
                result["notes"] = parsed.count
                result["start_bar"] = startBar
                result["tempo"] = range.tempo
                if arguments["verify_render"] as? Bool ?? true {
                    let endBar = startBar + Int((lastNoteEndBeats / range.beatsPerBar).rounded(.up))
                    let verifyRange = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: max(endBar, startBar + 1),
                        arguments: arguments
                    )
                    if let render = try? MCUController.renderSelectedTrack(
                        projectPath: logic.projectDocumentPath(),
                        label: "midi-verify",
                        sliceStartSeconds: verifyRange.start, sliceEndSeconds: verifyRange.end,
                        logic: logic, trackName: trackName
                    ) {
                        let slice = render["slice"] as? [String: Any]
                        result["verification"] = [
                            "rendered_slice": slice?["path"] ?? NSNull(),
                            "metrics": slice?["metrics"] ?? NSNull(),
                            "note": "freeze render of bars \(startBar)-\(endBar) after recording; non-silent metrics prove the notes landed and sound"
                        ]
                        result["verified"] = (slice?["metrics"] as? [String: Any])
                            .flatMap { ($0["peak_db"] as? [Double])?.first }
                            .map { $0 > -120 } ?? false
                    } else {
                        result["verification"] = ["note": "verification render failed; the recording itself completed"]
                        result["verified"] = false
                    }
                }
                payload = result

            case "logic_save_project":
                payload = try logic.saveProject(
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_new_project":
                payload = try logic.openProject(
                    path: requiredString("path", in: arguments),
                    createFromTemplate: true,
                    ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
                )

            case "logic_open_project":
                payload = try logic.openProject(
                    path: requiredString("path", in: arguments),
                    createFromTemplate: false,
                    ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
                )

            case "logic_duplicate_project":
                payload = try logic.duplicateProject(
                    destinationPath: arguments["destination_path"] as? String,
                    saveFirst: arguments["save_first"] as? Bool ?? false,
                    openCopy: arguments["open_copy"] as? Bool ?? true,
                    ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "save"
                )

            case "logic_close_project":
                payload = try logic.closeProject(
                    saving: requiredString("saving", in: arguments),
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_plugin_preset":
                let presetTrack = try requiredString("track_name", in: arguments)
                let presetPlugin = try requiredString("plugin_name", in: arguments)
                let direction = (arguments["direction"] as? String) ?? "next"
                guard ["next", "previous"].contains(direction) else {
                    throw DemoError.invalidArguments("direction must be 'next' or 'previous'")
                }
                let steps = max(arguments["steps"] as? Int ?? 1, 1)
                _ = try logic.selectTrack(trackName: presetTrack, trackNumber: arguments["track_number"] as? Int, expectedProjectPath: nil)
                let opened = try logic.openPlugin(
                    trackName: presetTrack, pluginName: presetPlugin,
                    insertIndex: arguments["insert_index"] as? Int, expectedProjectPath: nil
                )
                let openedByUs = (opened["state"] as? String) == "opened"
                let labelBefore = logic.pluginPresetLabel(windowTitle: presetTrack)
                let presetCommand = try MCUController.resolveKeyCommand(
                    named: direction == "next"
                        ? "Next Plug-in Setting for topmost Plug-in Window"
                        : "Previous Plug-in Setting for topmost Plug-in Window",
                    logic: logic
                )
                for _ in 0..<steps {
                    _ = try MCUController.triggerKeyCommand(note: presetCommand.note, channel: presetCommand.channel)
                    Thread.sleep(forTimeInterval: 0.5)
                }
                Thread.sleep(forTimeInterval: 0.5)
                let labelAfter = logic.pluginPresetLabel(windowTitle: presetTrack)
                if openedByUs {
                    _ = try? logic.closePlugin(trackName: presetTrack, pluginName: presetPlugin, insertIndex: arguments["insert_index"] as? Int)
                }
                payload = [
                    "success": true,
                    "verified": labelAfter != nil && labelAfter != labelBefore,
                    "direction": direction,
                    "steps": steps,
                    "preset_before": labelBefore.map { $0 as Any } ?? NSNull() as Any,
                    "preset_after": labelAfter.map { $0 as Any } ?? NSNull() as Any,
                    "note": labelAfter == labelBefore
                        ? "The preset label did not change (end of the list, or the plugin has no factory settings)."
                        : "Preset stepped via the topmost-plugin-window key command."
                ]

            case "logic_rename_track":
                payload = try logic.renameTrack(
                    trackName: requiredString("track_name", in: arguments),
                    newName: requiredString("new_name", in: arguments)
                )

            case "logic_duplicate_track":
                let dupTrack = try requiredString("track_name", in: arguments)
                _ = try logic.selectTrack(trackName: dupTrack, trackNumber: arguments["track_number"] as? Int, expectedProjectPath: nil)
                let dupBefore = ((try? logic.listTracks())?["tracks"] as? [[String: Any]])?.count ?? 0
                let dupCommand = try MCUController.resolveKeyCommand(named: "New Track with Duplicate Settings and Content", logic: logic)
                _ = try MCUController.triggerKeyCommand(note: dupCommand.note, channel: dupCommand.channel)
                var dupAfter: [[String: Any]] = []
                var duplicated = false
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 0.3)
                    dupAfter = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
                    if dupAfter.count > dupBefore { duplicated = true; break }
                }
                payload = [
                    "success": duplicated, "verified": duplicated,
                    "state": duplicated ? "duplicated" : "failed",
                    "track": dupTrack,
                    "tracks_after": dupAfter.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] }
                ]

            case "logic_delete_track":
                let delTrack = try requiredString("track_name", in: arguments)
                _ = try logic.selectTrack(trackName: delTrack, trackNumber: arguments["track_number"] as? Int, expectedProjectPath: nil)
                // DESTRUCTIVE: re-verify that the selected track really is the
                // requested one right before firing.
                let delList = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
                guard let selected = delList.first(where: { $0["selected"] as? Bool == true }),
                      (selected["track_name"] as? String)?.caseInsensitiveCompare(delTrack) == .orderedSame else {
                    throw DemoError.verificationFailed(
                        requested: "'\(delTrack)' selected before Delete Track",
                        actual: "the selection shows a different track; refusing",
                        restored: true
                    )
                }
                let delCommand = try MCUController.resolveKeyCommand(named: "Delete Track", logic: logic)
                _ = try MCUController.triggerKeyCommand(note: delCommand.note, channel: delCommand.channel)
                var deleted = false
                var delAfter: [[String: Any]] = []
                let nameCountBefore = delList.filter {
                    ($0["track_name"] as? String)?.caseInsensitiveCompare(delTrack) == .orderedSame
                }.count
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 0.3)
                    delAfter = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
                    let nameCountAfter = delAfter.filter {
                        ($0["track_name"] as? String)?.caseInsensitiveCompare(delTrack) == .orderedSame
                    }.count
                    // Occurrence count, not absence: duplicates share the name.
                    if delAfter.count == delList.count - 1, nameCountAfter == nameCountBefore - 1 {
                        deleted = true; break
                    }
                }
                payload = [
                    "success": deleted, "verified": deleted,
                    "state": deleted ? "deleted" : "failed",
                    "track": delTrack,
                    "note": deleted ? "Undo restores the track." : "The track is still listed; a dialog may need attention.",
                    "tracks_after": delAfter.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] }
                ]

            case "logic_add_send":
                guard let addedSend = try MCUController.addSend(
                    logic: logic,
                    trackName: requiredString("track_name", in: arguments),
                    destination: requiredString("destination", in: arguments)
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "send creation via the control surface",
                        exposed: "the MCU bridge is unavailable"
                    )
                }
                var sendPayload = addedSend
                sendPayload["track"] = try requiredString("track_name", in: arguments)
                payload = sendPayload

            case "logic_create_track":
                let kind = (arguments["type"] as? String) ?? "software_instrument"
                let commandName = kind == "audio" ? "New Audio Track" : "New Software Instrument Track"
                let before = ((try? logic.listTracks())?["tracks"] as? [[String: Any]])?.count ?? 0
                let command = try MCUController.resolveKeyCommand(named: commandName, logic: logic)
                _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
                // The command opens the Create New Track dialog; answer Create.
                var answered = false
                for _ in 0..<50 {
                    Thread.sleep(forTimeInterval: 0.12)
                    if logic.answerCreateTrackDialog() { answered = true; break }
                }
                var created = false
                var after: [[String: Any]] = []
                for _ in 0..<25 {
                    Thread.sleep(forTimeInterval: 0.15)
                    after = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
                    if after.count > before { created = true; break }
                }
                payload = [
                    "success": created,
                    "verified": created,
                    "type": kind,
                    "dialog_answered": answered,
                    "tracks_before": before,
                    "tracks_after": after.count,
                    "tracks": after.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] },
                    "note": created ? "Track created." : "No new track appeared; a dialog may need attention."
                ]

            case "logic_setup_key_commands":
                let relearn = (arguments["relearn"] as? Bool) ?? false
                var targets = KeyCommandRegistry.standardCommands
                if let onlyNames = arguments["commands"] as? [String], !onlyNames.isEmpty {
                    targets = targets.filter { onlyNames.contains($0.name) }
                    guard !targets.isEmpty else {
                        throw DemoError.invalidArguments(
                            "no standard command matches; valid names: "
                                + KeyCommandRegistry.standardCommands.map(\.name).joined(separator: ", ")
                        )
                    }
                }
                let results = try logic.setupKeyCommands(targets, forceRelearn: relearn)
                payload = [
                    "results": results,
                    "note": "Assignments were added to the user's active key command set (additive; removable in the Key Commands window). The registry file records the final note numbers."
                ]

            case "logic_trigger_key_command":
                if let name = arguments["name"] as? String {
                    let found = try MCUController.resolveKeyCommand(named: name, logic: logic)
                    var triggered = try MCUController.triggerKeyCommand(
                        note: found.note, channel: found.channel
                    )
                    if MCUController.lastResolveLearned {
                        triggered["first_run_learning"] =
                            "This command was just learned: the Key Commands window opened briefly (one-time per machine). Run logic_setup_key_commands during onboarding to do all learning up front."
                    }
                    payload = triggered
                } else {
                    let note = arguments["note"] as? Int ?? -1
                    let channel = arguments["channel"] as? Int ?? 16
                    payload = try MCUController.triggerKeyCommand(note: note, channel: channel)
                }

            case "logic_render_track":
                let trackName = try requiredString("track_name", in: arguments)
                let label = (arguments["label"] as? String)
                    ?? trackName.lowercased().replacingOccurrences(of: " ", with: "-")
                let projectPath = try logic.projectDocumentPath()
                // Track stacks and buses cannot be frozen — refuse upfront
                // when the AX track headers can tell us.
                if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
                   let header = tracks.first(where: {
                       ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
                   }),
                   header["is_stack"] as? Bool == true {
                    throw DemoError.trackNotExposed(
                        requested: "freeze render of '\(trackName)'",
                        exposed: "'\(trackName)' is a track stack — Logic cannot freeze stacks; render its subtracks individually or use logic_bounce_range for the summed output"
                    )
                }
                // MCU-first selection; AX track headers as fallback.
                var selected = false
                if let channel = ((try? MCUController.findChannel(trackName: trackName)) ?? nil) {
                    selected = (try? MCUController.selectFoundChannel(channel)) == true
                }
                if !selected {
                    _ = try logic.selectTrack(
                        trackName: trackName,
                        trackNumber: arguments["track_number"] as? Int,
                        expectedProjectPath: arguments["expected_project_path"] as? String
                    )
                }
                var sliceRange: (start: Double, end: Double, tempo: Double, beatsPerBar: Double)?
                if let startBar = arguments["start_bar"] as? Int,
                   let endBar = arguments["end_bar"] as? Int {
                    sliceRange = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: endBar, arguments: arguments
                    )
                }
                var render = try MCUController.renderSelectedTrack(
                    projectPath: projectPath, label: label,
                    sliceStartSeconds: sliceRange?.start, sliceEndSeconds: sliceRange?.end,
                    logic: logic, trackName: trackName
                )
                render["track"] = trackName
                if let range = sliceRange {
                    render["slice_tempo"] = range.tempo
                    render["slice_beats_per_bar"] = range.beatsPerBar
                }
                payload = render

            case "logic_mcu_command":
                // The registry is the consent record: firing a raw MIDI note
                // could trigger whatever the user has bound to it. Route
                // `keycmd` through the registry-checked path (refuses unlisted
                // notes) instead of forwarding it raw to the bridge.
                if (arguments["cmd"] as? String) == "keycmd" {
                    guard let note = arguments["note"] as? Int else {
                        throw DemoError.invalidArguments("keycmd requires an integer note")
                    }
                    let channel = arguments["channel"] as? Int ?? 16
                    payload = try MCUController.triggerKeyCommand(note: note, channel: channel)
                    break
                }
                var command: [String: Any] = [:]
                for (key, value) in arguments where key != "expected_project_path" {
                    command[key] = value
                }
                payload = try MCUBridge.send(command)

            case "logic_get_audio_clip":
                let clipPath = (try requiredString("path", in: arguments) as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: clipPath) else {
                    throw DemoError.trackNotExposed(requested: "audio file at '\(clipPath)'", exposed: "no such file")
                }
                let clipStart = (arguments["start_seconds"] as? Double)
                    ?? (arguments["start_seconds"] as? Int).map(Double.init) ?? 0
                let clipDuration = min(
                    (arguments["duration_seconds"] as? Double)
                        ?? (arguments["duration_seconds"] as? Int).map(Double.init) ?? 8.0,
                    20.0
                )
                let scratchBase = FileManager.default.temporaryDirectory
                    .appendingPathComponent("logician-clip-\(UUID().uuidString)")
                let trimmed = scratchBase.appendingPathExtension("wav")
                // The encoded clip is kept on disk: clients that drop MCP
                // audio blocks need a FILE their viewer can hand to the model.
                let clipsDirectory = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Logician/captures")
                try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
                let scratch = clipsDirectory.appendingPathComponent(
                    "clip-\(Int(Date().timeIntervalSince1970))-\(URL(fileURLWithPath: clipPath).deletingPathExtension().lastPathComponent.suffix(24)).m4a"
                )
                defer {
                    try? FileManager.default.removeItem(at: trimmed)
                }
                // Trim with our own slicer (afconvert has no offset support),
                // then compress: mono AAC 64 kbps keeps a clip tiny.
                var convertSource = clipPath
                if LogicAccessibility.sliceAudioFile(
                    path: clipPath, startSeconds: clipStart,
                    endSeconds: clipStart + clipDuration,
                    destinationPath: trimmed.path
                ) != nil {
                    convertSource = trimmed.path
                }
                let convert = Process()
                convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                convert.arguments = [
                    convertSource, scratch.path,
                    "-f", "m4af", "-d", "aac", "-b", "64000", "-c", "1"
                ]
                convert.standardError = FileHandle.nullDevice
                try convert.run()
                convert.waitUntilExit()
                guard convert.terminationStatus == 0,
                      let clipData = try? Data(contentsOf: scratch), !clipData.isEmpty else {
                    throw DemoError.writeFailed("afconvert could not produce the clip (is the source a readable audio file?)")
                }
                guard clipData.count <= 400_000 else {
                    throw DemoError.invalidArguments(
                        "the encoded clip is \(clipData.count / 1000) KB - too large to attach safely; request a shorter duration_seconds"
                    )
                }
                payload = [
                    "success": true,
                    "source": clipPath,
                    "start_seconds": clipStart,
                    "duration_seconds": clipDuration,
                    "encoded_bytes": clipData.count,
                    "clip_path": scratch.path,
                    "note": "An MCP AUDIO content block accompanies this text (mono AAC). SELF-CHECK: if no audio block reached you, your client DROPS them - do not pretend to hear; instead open clip_path with your client's file viewer (many viewers pass audio files to the model as real multimodal input; verified in Antigravity). NEVER read audio files as text/bash.",
                    "_audio": ["data": clipData.base64EncodedString(), "mimeType": "audio/mp4"]
                ]

            case "logic_get_transport":
                payload = try logic.getTransport()

            case "logic_set_cycle":
                guard let enabled = arguments["enabled"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: enabled")
                }
                payload = try MCUController.setCycle(enabled) ?? logic.setCycle(enabled: enabled)

            case "logic_set_playing":
                guard let playing = arguments["playing"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: playing")
                }
                payload = try MCUController.setPlaying(playing) ?? logic.setPlaying(playing: playing)

            case "logic_set_playhead":
                guard let barNumber = arguments["bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: bar")
                }
                payload = try logic.setPlayhead(
                    barNumber: barNumber,
                    beat: arguments["beat"] as? Int
                )

            case "logic_set_cycle_range":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                payload = try logic.setCycleRange(
                    startBar: startBar,
                    endBar: endBar,
                    enabled: arguments["enabled"] as? Bool
                )

            case "logic_select_track":
                payload = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_set_track_stack":
                guard let expanded = arguments["expanded"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: expanded")
                }
                payload = try logic.setTrackStack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expanded: expanded,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_survey_plugins":
                payload = try logic.surveyPlugins(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int
                )

            case "logic_add_plugin":
                // MCU plugin browser first (mouse-free); the AX chooser needs
                // the physical mouse for hover navigation, so it only runs
                // when explicitly allowed.
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                if var viaBrowser = try MCUController.addPluginViaBrowser(
                    pluginName: requiredString("plugin_name", in: arguments),
                    logic: logic,
                    trackName: requiredString("track_name", in: arguments)
                ) {
                    viaBrowser["track"] = try requiredString("track_name", in: arguments)
                    payload = viaBrowser
                } else if arguments["allow_mouse"] as? Bool == true {
                    payload = try logic.addPlugin(
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        pluginName: requiredString("plugin_name", in: arguments),
                        format: (arguments["format"] as? String) ?? "Stereo"
                    )
                } else {
                    throw DemoError.trackNotExposed(
                        requested: "mouse-free plugin insertion",
                        exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
                    )
                }

            case "logic_remove_plugin":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                if var removed = try MCUController.removePluginViaBrowser(
                    pluginName: requiredString("plugin_name", in: arguments),
                    logic: logic,
                    trackName: requiredString("track_name", in: arguments)
                ) {
                    removed["track"] = try requiredString("track_name", in: arguments)
                    payload = removed
                } else if arguments["allow_mouse"] as? Bool == true {
                    payload = try logic.removePlugin(
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        pluginName: requiredString("plugin_name", in: arguments),
                        insertIndex: arguments["insert_index"] as? Int
                    )
                } else {
                    throw DemoError.trackNotExposed(
                        requested: "mouse-free plugin removal",
                        exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
                    )
                }

            case "logic_list_regions":
                payload = try logic.listRegions(
                    trackName: arguments["track_name"] as? String
                )

            case "logic_select_region":
                payload = try logic.selectRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    exclusive: arguments["exclusive"] as? Bool ?? true
                )

            case "logic_delete_region":
                payload = try logic.deleteRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int
                )

            case "logic_move_region":
                payload = try logic.moveRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    byBars: arguments["by_bars"] as? Int ?? 0,
                    byBeats: arguments["by_beats"] as? Int ?? 0
                )

            case "logic_copy_region":
                guard let toBar = arguments["to_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: to_bar")
                }
                payload = try logic.copyRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    toBar: toBar,
                    toTrack: arguments["to_track"] as? String,
                    move: arguments["move"] as? Bool ?? false
                )

            case "logic_set_tempo":
                let bpm = (arguments["bpm"] as? Double)
                    ?? (arguments["bpm"] as? Int).map(Double.init)
                guard let targetBpm = bpm else {
                    throw DemoError.invalidArguments("missing number: bpm")
                }
                let transportBefore = try logic.getTransport()
                let currentBpm = transportBefore["tempo"] as? Double
                if let expected = (arguments["expected_current_bpm"] as? Double)
                    ?? (arguments["expected_current_bpm"] as? Int).map(Double.init) {
                    guard let current = currentBpm, abs(current - expected) < 0.5 else {
                        throw DemoError.currentValueMismatch(
                            expected: "\(expected) BPM",
                            actual: "\(currentBpm.map { "\($0)" } ?? "unreadable") BPM"
                        )
                    }
                }
                let landed = try logic.setTempo(targetBpm)
                payload = [
                    "success": true,
                    "verified": true,
                    "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
                    "bpm": landed,
                    "write_route": "control_bar_tempo_slider",
                    "note": "Whole-BPM resolution (the slider steps 1 BPM). Constant project tempo assumed; tempo-track changes are not managed."
                ]

            case "logic_set_track_mute", "logic_set_track_solo":
                let control = name == "logic_set_track_mute" ? "mute" : "solo"
                guard let enabled = arguments["enabled"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: enabled")
                }
                let toggleTrack = try requiredString("track_name", in: arguments)
                payload = try MCUController.setToggle(
                    trackName: toggleTrack, control: control, enabled: enabled
                ) ?? logic.setStripToggle(
                    trackName: toggleTrack,
                    trackNumber: arguments["track_number"] as? Int,
                    control: control,
                    enabled: enabled
                )

            case "logic_set_track_volume":
                guard let db = (arguments["db"] as? Double) ?? (arguments["db"] as? Int).map(Double.init) else {
                    throw DemoError.invalidArguments("missing number: db")
                }
                let volumeTrack = try requiredString("track_name", in: arguments)
                let tolerance = (arguments["tolerance_db"] as? Double) ?? 0.15
                payload = try MCUController.setVolume(
                    trackName: volumeTrack, targetDb: db, toleranceDb: tolerance
                ) ?? logic.setTrackVolume(
                    trackName: volumeTrack,
                    trackNumber: arguments["track_number"] as? Int,
                    targetDb: db,
                    toleranceDb: tolerance
                )

            case "logic_set_track_pan":
                guard let position = arguments["position"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: position")
                }
                payload = try logic.setTrackPan(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    position: position
                )

            case "logic_open_plugin":
                payload = try logic.openPlugin(
                    trackName: requiredString("track_name", in: arguments),
                    pluginName: requiredString("plugin_name", in: arguments),
                    insertIndex: arguments["insert_index"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_close_plugin":
                payload = try logic.closePlugin(
                    trackName: requiredString("track_name", in: arguments),
                    pluginName: requiredString("plugin_name", in: arguments),
                    insertIndex: arguments["insert_index"] as? Int
                )

            case "logic_close_plugin_window":
                payload = try logic.closePluginWindow(title: requiredString("window_title", in: arguments))

            case "logic_list_plugin_parameters":
                let windowTitle = try requiredString("window_title", in: arguments)
                payload = [
                    "window": windowTitle,
                    "parameters": try logic.listParameters(windowTitle: windowTitle)
                ]

            case "logic_set_plugin_parameter":
                payload = try logic.setParameter(
                    windowTitle: requiredString("window_title", in: arguments),
                    parameterName: requiredString("parameter", in: arguments),
                    expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                    targetValue: requiredString("target_value", in: arguments)
                )

            default:
                throw DemoError.invalidArguments("unknown tool: \(name)")
            }
            // Every write that changes how the song SOUNDS carries a standing
            // instruction to judge it by ear. Parameter and fader numbers say
            // nothing about how loud or good something IS (recordings differ,
            // plugins differ) - only listening does. This lives in the result
            // so every future agent gets it at exactly the right moment.
            let soundChangingTools: Set<String> = [
                "logic_set_track_volume", "logic_set_track_pan",
                "logic_set_track_mute", "logic_set_track_solo",
                "logic_mcu_set_plugin_parameter", "logic_mcu_set_instrument_parameter",
                "logic_mcu_set_send", "logic_evaluate_change"
            ]
            let arrangementTools: Set<String> = [
                "logic_move_region", "logic_copy_region", "logic_delete_region",
                "logic_record_midi"
            ]
            if soundChangingTools.contains(name) || arrangementTools.contains(name),
               var successPayload = payload as? [String: Any],
               successPayload["success"] as? Bool == true,
               successPayload["listen_note"] == nil {
                if arrangementTools.contains(name) {
                    successPayload["listen_note"] = "You changed the ARRANGEMENT. Bounce a range that includes a few bars BEFORE your edit and listen across the seam: the classic failure is the copied phrase landing displaced (snare on the wrong beat) even though the region boundaries read as bar-aligned - region positions do NOT prove the groove inside is aligned. If the pattern does not match the original groove exactly, undo and copy from a region that starts ON the beat (watch out for pickup regions)."
                } else {
                    successPayload["listen_note"] = name == "logic_evaluate_change"
                        ? "Do not decide keep/rollback from the numbers alone: LISTEN to baseline_audio and after_audio (open the preview/clip files with your client's file viewer) before judging."
                        : "You changed how the song SOUNDS. Judge the result by LISTENING (bounce the section, open the preview with your client's file viewer) - a fader or parameter value is not loudness; recordings and plugins differ."
                }
                return toolResult(payload: successPayload, isError: false)
            }
            return toolResult(payload: payload, isError: false)
        } catch {
            return toolResult(
                payload: [
                    "success": false,
                    "verified": false,
                    "state": "failed",
                    "error_code": (error as? DemoError)?.code ?? "failed",
                    "error": error.localizedDescription
                ],
                isError: true
            )
        }
    }

    func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw DemoError.invalidArguments("missing non-empty string: \(key)")
        }
        return value
    }

    /// Bar positions → seconds from project start (freeze renders begin at
    /// bar 1). Tempo and meter come from the control bar unless overridden;
    /// constant tempo is assumed (tempo-track changes are not followed).
    func barRangeSeconds(
        logic: LogicAccessibility, startBar: Int, endBar: Int, arguments: [String: Any]
    ) throws -> (start: Double, end: Double, tempo: Double, beatsPerBar: Double) {
        guard startBar >= 1, endBar > startBar else {
            throw DemoError.invalidArguments("need start_bar >= 1 and end_bar > start_bar")
        }
        var tempo = (arguments["tempo"] as? Double)
            ?? (arguments["tempo"] as? Int).map(Double.init) ?? 0
        var beatsPerBar = (arguments["beats_per_bar"] as? Double)
            ?? (arguments["beats_per_bar"] as? Int).map(Double.init) ?? 0
        if tempo <= 0 || beatsPerBar <= 0 {
            let transport = try logic.getTransport()
            if tempo <= 0 {
                guard let read = transport["tempo"] as? Double else {
                    throw DemoError.trackNotExposed(
                        requested: "tempo from the control bar",
                        exposed: "no tempo readable; pass an explicit 'tempo' argument"
                    )
                }
                tempo = read
            }
            if beatsPerBar <= 0 {
                beatsPerBar = Double((transport["time_signature"] as? String)?
                    .split(separator: "/").first.flatMap { Int($0) } ?? 4)
            }
        }
        let secondsPerBar = beatsPerBar * 60.0 / tempo
        return (
            Double(startBar - 1) * secondsPerBar,
            Double(endBar - 1) * secondsPerBar,
            tempo, beatsPerBar
        )
    }

}
