import ApplicationServices
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
        return try readAutomationLane(
            trackName: try requiredString("track_name", in: arguments),
            parameter: (arguments["parameter"] as? String) ?? "volume",
            send: arguments["send"] as? Int,
            insertSlot: arguments["insert_slot"] as? Int,
            pluginParameter: arguments["plugin_parameter"] as? String,
            startBar: startBar,
            endBar: endBar,
            resolutionBeats: max(arguments["resolution_beats"] as? Int ?? 1, 1),
            maxPoints: min(max(arguments["max_points"] as? Int ?? 64, 1), 200),
            settleSeconds: min(max((arguments["settle_seconds"] as? Double) ?? 0.8, 0.2), 3.0)
        )
    }

    /// One lane read, addressed the way `logic_read_automation` addresses it.
    ///
    /// Extracted from the handler unchanged (2026-09-03) because
    /// `logic_remove_automation` needs the SAME read twice — once as the
    /// evidence that there is a curve to remove, once as the proof that it is
    /// gone — and a removal verified by a second implementation of the read
    /// would be verifying the wrong thing.
    func readAutomationLane(
        trackName track: String,
        parameter: String,
        send: Int?,
        insertSlot: Int?,
        pluginParameter: String?,
        startBar: Int,
        endBar: Int,
        resolutionBeats resolution: Int,
        maxPoints: Int,
        settleSeconds settle: Double
    ) throws -> [String: Any] {
        // The sampling grid's bar lengths. Read here, once, from the project's
        // own Signature List (7 ms on a cache hit) rather than taken from the
        // control bar inside the loop: the control bar publishes the signature
        // AT THE PLAYHEAD, which is how a read of bars 2-4 built a five-beat
        // grid because the playhead happened to sit in a 5/4 bar 41.
        let meter = resolveMeterKnowledge()

        switch parameter {
        case "volume":
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "volume",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle, meter: meter,
                enterView: { channel in try MCUController.volumeReader(channel: channel) },
                restoreView: { MCUController.exitToPan() },
                // Handed over in the Volume view instead of walking home from
                // it: 3.3-4.6 s, measured after the last byte the caller
                // waited for. `strip: nil` like the mixer snapshot's identical
                // view, so any Accessibility selection settles it first.
                viewDebt: MCUController.SurfaceDebt(
                    strip: nil, view: "channel_strip", slot: nil
                )
            )
        case "pan":
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "pan",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle, meter: meter,
                // Pan is read off the inspector strip's own knob, exactly as
                // logic_record_automation reads it while verifying a pan curve.
                enterView: { _ in { [logic] in logic.stripPanValue(trackName: track) } },
                restoreView: { }
            )
        case "send":
            guard let send, (1...8).contains(send) else {
                throw LogicianError.invalidArguments("parameter 'send' requires send: 1-8")
            }
            return try MCUController.readAutomation(
                logic: logic, trackName: track, kindLabel: "send \(send) level",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle, meter: meter,
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
                restoreView: { MCUController.exitToPan() },
                // The send view is the debt its sibling tools already record.
                viewDebt: MCUController.sendViewDebt(strip: track)
            )
        case "plugin":
            guard let slot = insertSlot, (1...8).contains(slot) else {
                throw LogicianError.invalidArguments("parameter 'plugin' requires insert_slot: 1-8")
            }
            guard let parameterName = pluginParameter, !parameterName.isEmpty else {
                throw LogicianError.invalidArguments(
                    "parameter 'plugin' requires plugin_parameter (the name as shown on the MCU)"
                )
            }
            return try MCUController.readAutomation(
                logic: logic, trackName: track,
                kindLabel: "plugin slot \(slot): \(parameterName)",
                startBar: startBar, endBar: endBar, resolutionBeats: resolution,
                maxPoints: maxPoints, settleSeconds: settle, meter: meter,
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
                restoreView: { MCUController.exitToPan() },
                // A plugin-edit view left standing is the exact hazard the debt
                // machinery was built for, and it is the one it handles:
                // `settleSurfaceDebt` pays it before any selection onto another
                // strip, exactly as the parameter tools' own deferral does.
                viewDebt: MCUController.SurfaceDebt(
                    strip: track, view: "plugin_edit", slot: slot
                )
            )
        default:
            throw LogicianError.invalidArguments(
                "parameter must be volume, pan, send or plugin"
            )
        }
    }
}

// The automation REMOVAL — the one thing the automation family could not do
// until 2026-09-03. See `AXRemoveAutomation.swift` for the route, the two
// press hazards it guards against, and why only one of Logic's five Delete
// Automation commands is wired up.
extension MCPServer {

    func handleRemoveAutomation(_ arguments: [String: Any]) throws -> Any {
        try logic.verifyProjectPath(arguments["expected_project_path"] as? String)
        let scope = (arguments["scope"] as? String) ?? "track"
        if let refusal = AutomationRemoval.scopeRefusal(
            scope, parameterGiven: arguments["parameter"] as? String
        ) {
            throw LogicianError.invalidArguments(refusal)
        }
        let trackName = try requiredString("track_name", in: arguments)
        let parameter = (arguments["parameter"] as? String) ?? "volume"
        let startBar = arguments["verify_start_bar"] as? Int ?? 2
        let endBar = arguments["verify_end_bar"] as? Int ?? (startBar + 2)
        guard startBar >= 1, endBar >= startBar else {
            throw LogicianError.invalidArguments(
                "verify_start_bar must be >= 1 and verify_end_bar >= verify_start_bar"
            )
        }
        let resolution = max(arguments["verify_resolution_beats"] as? Int ?? 4, 1)
        let maxPoints = min(max(arguments["verify_max_points"] as? Int ?? 6, 2), 32)
        let tolerance = max(
            (arguments["tolerance"] as? Double)
                ?? (arguments["tolerance"] as? Int).map(Double.init) ?? 0.05,
            0.0
        )
        let force = arguments["force"] as? Bool ?? false
        let send = arguments["send"] as? Int
        let insertSlot = arguments["insert_slot"] as? Int
        let pluginParameter = arguments["plugin_parameter"] as? String
        let clock = Date()

        // 1. Which row, and can this route even press? Both refusals are cheap
        //    and both come BEFORE the lane read they would otherwise waste.
        let target = try logic.resolveTrack(
            try logic.parsedTrackHeaders(), name: trackName, number: arguments["track_number"] as? Int
        )
        let item = LogicUIStrings.Menu.deleteAllAutomationOnSelectedTracks
        // Frontmost BEFORE the enabled state is read, and not only before the
        // press: a Logic menu item's enabled flag is the last validation
        // pass's, and validation depends on which window is key. Measured
        // 2026-09-03 on the same menu bar in the same second — `View >
        // Inspector` read `enabled=0` with Logic in the background and
        // `enabled=1` with it frontmost. The Delete Automation items read
        // enabled=1 either way in four dumps, so this is a guard against a
        // FALSE refusal rather than a fix for an observed one; the activation
        // has to happen before the press regardless.
        try logic.ensureLogicFrontmost(for: "the '\(item)' menu item")
        var menuBefore = try logic.automationMenuItem(containing: item)
        if !menuBefore.enabled {
            // One second look before a refusal that tells the caller to go and
            // fix something: the activation above may still be settling.
            Thread.sleep(forTimeInterval: 0.15)
            menuBefore = try logic.automationMenuItem(containing: item)
        }
        guard menuBefore.enabled else {
            throw LogicianError.preconditionUnmet(
                "Logic's '\(item)' menu item is greyed out, so nothing was pressed and no lane was"
                    + " read. It is enabled whenever a track row is selected; a modal standing in"
                    + " front of Logic is the usual reason it is not"
                    + (logic.modalWindowTitles().isEmpty
                        ? " (no modal window is open)"
                        : " (open: \(logic.modalWindowTitles().joined(separator: ", ")))")
                    + "."
            )
        }

        // 2. Exactly ONE selected row. The menu item says "Selected Tracks"
        //    and means it.
        let selection = try logic.selectTrack(
            trackName: target.name, trackNumber: target.number, expectedProjectPath: nil
        )
        let deselected = try logic.narrowSelectionToOneTrack(target.name, number: target.number)

        // 3. The evidence: what is on the lane the caller nominated as proof.
        let before = try readAutomationLane(
            trackName: target.name, parameter: parameter, send: send, insertSlot: insertSlot,
            pluginParameter: pluginParameter, startBar: startBar, endBar: endBar,
            resolutionBeats: resolution, maxPoints: maxPoints, settleSeconds: 0.8
        )
        let beforePoints = before["points"] as? [[String: Any]] ?? []
        let beforeEvidence = AutomationRemoval.evidence(
            values: beforePoints.map { ($0["value"] as? NSNumber)?.doubleValue }
        )

        var result: [String: Any] = [
            "success": true,
            "track": target.name,
            "track_name": target.name,
            "track_number": target.number,
            "scope": "all_lanes_on_track",
            "route": "menu:\(LogicUIStrings.Menu.mix) > \(LogicUIStrings.Menu.deleteAutomation)"
                + " > \(item)",
            "selection": [
                "state": selection["state"] as? String ?? "unknown",
                "deselected": deselected
            ],
            "verified_lane": [
                "parameter": before["parameter"] as? String ?? parameter,
                "start_bar": startBar,
                "end_bar": endBar,
                "resolution_beats": resolution,
                "sample_count": beforePoints.count
            ],
            "points_before": beforePoints,
            "automation_mode": before["automation_mode"] ?? NSNull(),
            "playhead_restored": before["playhead_restored"] ?? NSNull()
        ]
        if let spread = beforeEvidence.spread {
            result["value_spread_before"] = MCUController.automationSampleNumber(spread)
        }

        switch AutomationRemoval.decide(
            before: beforeEvidence, tolerance: tolerance, force: force
        ) {
        case .refuse(let why):
            throw LogicianError.preconditionUnmet(why)
        case .alreadyEmpty(let note):
            result["state"] = "already_empty"
            result["verified"] = true
            result["pressed"] = false
            result["elapsed_ms"] = Int(Date().timeIntervalSince(clock) * 1000)
            result["note"] = "Nothing was pressed and nothing was removed."
            appendWarning(note, to: &result)
            return result
        case .press:
            break
        }

        // 4. The press. The selection is re-proven first: the lane read above
        //    selects the strip on the control surface, and a surface selection
        //    IS a track selection — a step this call makes itself, and so a
        //    step it must re-check before a destructive press.
        let standing = try logic.parsedTrackHeaders().filter(\.selected)
        guard standing.count == 1, standing[0].number == target.number else {
            throw LogicianError.preconditionUnmet(
                "the selected track is no longer '\(target.name)' alone — Logic reports"
                    + " \(standing.map { "\($0.number): \($0.name)" }.joined(separator: ", "))"
                    + " — so the Delete Automation press was NOT made. Nothing was removed."
            )
        }
        // Again, and deliberately: the lane read above took seconds, and
        // anything could have taken the front in them. It returns immediately
        // when Logic is already frontmost and publishing its windows.
        try logic.ensureLogicFrontmost(for: "the '\(item)' menu press")
        if let standingModal = logic.modalWindowNow() {
            let named = logic.modalWindowTitles().joined(separator: ", ")
            let what = named.isEmpty
                ? logic.stringAttribute(standingModal, kAXSubroleAttribute as String)
                : named
            throw LogicianError.preconditionUnmet(
                "a modal window is standing in front of Logic (\(what)) and it swallows menu"
                    + " commands, so nothing was pressed. Answer it in Logic and call again."
            )
        }
        let windowsBefore = Set(((try? logic.logicWindows()) ?? []).map { WindowKey(element: $0) })
        // Re-resolved rather than reused: the lane read above took seconds,
        // and the enabled state is the half of this that can have changed.
        let menu = try logic.automationMenuItem(containing: item)
        guard menu.enabled else {
            throw LogicianError.preconditionUnmet(
                "'\(item)' went from enabled to greyed out while the lane was being read, so"
                    + " nothing was pressed and nothing was removed."
            )
        }
        let pressClock = Date()
        let status = AXUIElementPerformAction(menu.item, kAXPressAction as CFString)
        let pressMs = Int(Date().timeIntervalSince(pressClock) * 1000)
        guard status == .success else {
            throw LogicianError.writeFailed(
                "the '\(item)' menu press returned AXError \(status.rawValue); nothing was removed"
            )
        }
        result["press_ms"] = pressMs

        // 5. A dialog nobody has measured is CANCELLED, never answered.
        var dialogReport: [String: Any] = [
            "unavailable": "no window appeared within 600 ms of the press"
        ]
        if let window = ((try? logic.pollNewWindow(before: windowsBefore, deadline: 0.6)) ?? nil) {
            let subrole = logic.stringAttribute(window, kAXSubroleAttribute as String)
            let titles = [logic.stringAttribute(window, kAXTitleAttribute as String)]
                .filter { !$0.isEmpty }
            let texts = logic.alertTexts(window)
            if ["AXDialog", "AXSheet", "AXSystemDialog"].contains(subrole) {
                if let cancel = logic.cancelButton(of: window) {
                    _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                }
                throw LogicianError.preconditionUnmet(
                    AutomationRemoval.unknownDialogRefusal(titles: titles, texts: texts)
                )
            }
            dialogReport = [
                "appeared": true, "subrole": subrole, "titles": titles, "texts": texts,
                "answered": false
            ]
        }
        result["confirmation_dialog"] = dialogReport

        // 6. The proof: the same grid, read again.
        let after = try readAutomationLane(
            trackName: target.name, parameter: parameter, send: send, insertSlot: insertSlot,
            pluginParameter: pluginParameter, startBar: startBar, endBar: endBar,
            resolutionBeats: resolution, maxPoints: maxPoints, settleSeconds: 0.8
        )
        let afterPoints = after["points"] as? [[String: Any]] ?? []
        let afterEvidence = AutomationRemoval.evidence(
            values: afterPoints.map { ($0["value"] as? NSNumber)?.doubleValue }
        )
        let verdict = AutomationRemoval.verdict(
            before: beforeEvidence, after: afterEvidence, tolerance: tolerance, forced: force
        )
        result["points_after"] = afterPoints
        if let spread = afterEvidence.spread {
            result["value_spread_after"] = MCUController.automationSampleNumber(spread)
        }
        result["pressed"] = true
        result["state"] = verdict.state
        result["verified"] = verdict.verified
        result["elapsed_ms"] = Int(Date().timeIntervalSince(clock) * 1000)
        result["note"] = "EVERY automation lane on '\(target.name)' was removed, not just the one"
            + " read back here: Logic's command is per TRACK. The lane above is the proof, and it"
            + " is a sampled proof — logic_read_automation reads the value Logic chases to, not"
            + " the lane's breakpoints. THE CONTROL IS LEFT WHERE THE AUTOMATION LAST PUT IT, not"
            + " where it stood before the curve was written (measured 2026-09-03: a track at"
            + " -5.1 dB read -2.9 dB after its curve was deleted), so check the static value with"
            + " logic_mixer_snapshot and set it with logic_set_track_volume if it matters."
        appendWarning(verdict.warning, to: &result)
        return result
    }
}
