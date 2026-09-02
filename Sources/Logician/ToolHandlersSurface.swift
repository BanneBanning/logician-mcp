import Foundation
import LogicMCUBridge

// The control-surface reads and writes that decode data the bridge already
// holds: the strip census, the mixer snapshot, record-arm, the metronome, the
// instrument slot, and the automation read.
extension MCPServer {

    func handleListStrips(_ arguments: [String: Any]) throws -> Any {
        try MCUController.listStrips(logic: logic)
    }

    func handleMixerSnapshot(_ arguments: [String: Any]) throws -> Any {
        try MCUController.mixerSnapshot(
            logic: logic,
            includeRecordArm: arguments["include_record_arm"] as? Bool ?? true
        )
    }

    func handleSetTrackRecordArm(_ arguments: [String: Any]) throws -> Any {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: enabled")
        }
        return try MCUController.setRecordArm(
            logic: logic,
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            enabled: enabled
        )
    }

    func handleSetMetronome(_ arguments: [String: Any]) throws -> Any {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: enabled")
        }
        return try MCUController.setMetronome(logic: logic, enabled: enabled)
    }

    func handleLoadInstrument(_ arguments: [String: Any]) throws -> Any {
        try logic.verifyProjectPath(arguments["expected_project_path"] as? String)
        return try MCUController.loadInstrumentViaBrowser(
            logic: logic,
            trackName: requiredString("track_name", in: arguments),
            instrument: requiredString("instrument", in: arguments),
            format: arguments["format"] as? String,
            maxSteps: arguments["max_steps"] as? Int ?? MCUController.browseEntryCap
        )
    }

    func handleReadAutomation(_ arguments: [String: Any]) throws -> Any {
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("start_bar and end_bar are required integers")
        }
        let track = try requiredString("track_name", in: arguments)
        let parameter = (arguments["parameter"] as? String) ?? "volume"
        let resolution = max(arguments["resolution_beats"] as? Int ?? 1, 1)
        let maxPoints = min(max(arguments["max_points"] as? Int ?? 64, 1), 200)
        let settle = min(max((arguments["settle_seconds"] as? Double) ?? 0.8, 0.2), 3.0)

        switch parameter {
        case "volume":
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "volume",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle,
                enterView: { channel in try MCUController.volumeReader(channel: channel) },
                restoreView: { MCUController.exitToPan() }
            )
        case "pan":
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "pan",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle,
                // Pan is read off the inspector strip's own knob, exactly as
                // logic_record_automation reads it while verifying a pan curve.
                enterView: { _ in { [logic] in logic.stripPanValue(trackName: track) } },
                restoreView: { }
            )
        case "send":
            guard let send = arguments["send"] as? Int, (1...8).contains(send) else {
                throw LogicianError.invalidArguments("parameter 'send' requires send: 1-8")
            }
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "send \(send) level",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle,
                enterView: { _ in
                    guard try MCUController.ensureSendView() else {
                        throw LogicianError.trackNotExposed(
                            requested: "the send channel view", exposed: "not reachable"
                        )
                    }
                    try MCUController.sendViewToPage(forSend: send)
                    let levelIndex = ((send - 1) % 2) * 4 + 1
                    return {
                        guard let bottom = MCUController.freshStatus()?["lcd_bottom"] as? String
                        else { return nil }
                        return MCUController.parseDb(
                            MCUController.lcdValueFields(bottom)[levelIndex]
                        )
                    }
                },
                restoreView: { MCUController.exitToPan() }
            )
        case "plugin":
            guard let slot = arguments["insert_slot"] as? Int, (1...8).contains(slot) else {
                throw LogicianError.invalidArguments("parameter 'plugin' requires insert_slot: 1-8")
            }
            let parameterName = try requiredString("plugin_parameter", in: arguments)
            return try MCUController.readAutomation(
                logic: logic, trackName: track,
                kindLabel: "plugin slot \(slot): \(parameterName)",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle,
                enterView: { _ in
                    guard try MCUController.ensurePluginList() != nil,
                          try MCUController.enterPluginEdit(slot: slot) else {
                        throw LogicianError.trackNotExposed(
                            requested: "plugin edit mode for slot \(slot)", exposed: "could not enter"
                        )
                    }
                    guard let index = try MCUController.locateParameter(named: parameterName) else {
                        throw LogicianError.trackNotExposed(
                            requested: "parameter '\(parameterName)' in slot \(slot)",
                            exposed: "not found on the parameter pages"
                        )
                    }
                    return {
                        MCUController.parameterPage().flatMap {
                            MCUController.parseNumber($0[index].value)
                        }
                    }
                },
                restoreView: { MCUController.exitToPan() }
            )
        default:
            throw LogicianError.invalidArguments(
                "parameter must be volume, pan, send or plugin"
            )
        }
    }
}
