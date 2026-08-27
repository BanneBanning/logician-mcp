import Foundation

// Plugins and instruments: inserts, windows, parameters, presets.
extension MCPServer {
    func handleListInserts(_ arguments: [String: Any]) throws -> Any {
        return try logic.listInserts(trackName: requiredString("track_name", in: arguments))
    }

    func handleSurveyPlugins(_ arguments: [String: Any]) throws -> Any {
        return try logic.surveyPlugins(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int
        )
    }

    func handleAddPlugin(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        // MCU plugin browser first (mouse-free); the AX chooser needs
        // the physical mouse for hover navigation, so it only runs
        // when explicitly allowed.
        _ = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
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
            throw LogicianError.trackNotExposed(
                requested: "mouse-free plugin insertion",
                exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
            )
        }
        return payload
    }

    func handleRemovePlugin(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        _ = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
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
            throw LogicianError.trackNotExposed(
                requested: "mouse-free plugin removal",
                exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
            )
        }
        return payload
    }

    func handleOpenPlugin(_ arguments: [String: Any]) throws -> Any {
        return try logic.openPlugin(
            trackName: requiredString("track_name", in: arguments),
            pluginName: requiredString("plugin_name", in: arguments),
            insertIndex: arguments["insert_index"] as? Int,
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }

    func handleClosePlugin(_ arguments: [String: Any]) throws -> Any {
        return try logic.closePlugin(
            trackName: requiredString("track_name", in: arguments),
            pluginName: requiredString("plugin_name", in: arguments),
            insertIndex: arguments["insert_index"] as? Int
        )
    }

    func handleClosePluginWindow(_ arguments: [String: Any]) throws -> Any {
        return try logic.closePluginWindow(title: requiredString("window_title", in: arguments))
    }

    func handleListPluginParameters(_ arguments: [String: Any]) throws -> Any {
        let windowTitle = try requiredString("window_title", in: arguments)
        return [
            "window": windowTitle,
            "parameters": try logic.listParameters(windowTitle: windowTitle)
        ]
    }

    func handleSetPluginParameter(_ arguments: [String: Any]) throws -> Any {
        return try logic.setParameter(
            windowTitle: requiredString("window_title", in: arguments),
            parameterName: requiredString("parameter", in: arguments),
            expectedCurrentValue: requiredString("expected_current_value", in: arguments),
            targetValue: requiredString("target_value", in: arguments)
        )
    }

    /// Which of the three things `logic_plugin_preset` can do this call means.
    ///
    /// Backward compatibility is the reason this is inferred rather than
    /// required: every argument set that worked before v2 (`track_name` +
    /// `plugin_name`, with or without `direction`/`steps`) still means `step`
    /// and still behaves identically. A `name` with no `action` means `select`,
    /// because there is nothing else a caller could have meant by it.
    static func presetAction(_ arguments: [String: Any]) throws -> String {
        if let explicit = arguments["action"] as? String {
            guard ["list", "select", "step"].contains(explicit) else {
                throw LogicianError.invalidArguments("action must be 'list', 'select' or 'step'")
            }
            if explicit == "select", (arguments["name"] as? String) == nil {
                throw LogicianError.invalidArguments("action 'select' needs name (the setting to load)")
            }
            return explicit
        }
        return (arguments["name"] as? String) == nil ? "step" : "select"
    }

    func handlePluginPreset(_ arguments: [String: Any]) throws -> Any {
        let presetTrack = try requiredString("track_name", in: arguments)
        let presetPlugin = try requiredString("plugin_name", in: arguments)
        let insertIndex = arguments["insert_index"] as? Int
        let action = try MCPServer.presetAction(arguments)

        // Routed exactly like every other plugin tool, so "Stereo Out" and the
        // aux/bus strips work wherever a track name does (item 2). The plugin
        // WINDOW is still an Accessibility object, so a headerless strip also
        // has to be showing in an inspector for the window to open at all —
        // that limit belongs to openPlugin and is stated in the tool schema.
        let target = try selectStripTarget(arguments)
        let opened = try logic.openPlugin(
            trackName: presetTrack, pluginName: presetPlugin,
            insertIndex: insertIndex, expectedProjectPath: nil
        )
        let openedByUs = (opened["state"] as? String) == "opened"
        // The window this call opened is closed again on every exit, including
        // the throwing ones: leaving windows behind changes what the user
        // sees, and on the master chain it changes what the NEXT call can read.
        defer {
            if openedByUs {
                _ = try? logic.closePlugin(
                    trackName: presetTrack, pluginName: presetPlugin, insertIndex: insertIndex
                )
            }
        }
        var payload: [String: Any]
        switch action {
        case "list":
            payload = try presetListPayload(track: presetTrack, plugin: presetPlugin)
        case "select":
            payload = try presetSelectPayload(
                track: presetTrack, plugin: presetPlugin,
                requested: try requiredString("name", in: arguments)
            )
        default:
            payload = try presetStepPayload(track: presetTrack, arguments: arguments)
        }
        payload["action"] = action
        payload["track"] = presetTrack
        payload["track_name"] = presetTrack
        payload["plugin_name"] = presetPlugin
        payload["window_title"] = opened["window_title"] ?? presetTrack
        payload.merge(target.resultFields) { current, _ in current }
        return payload
    }

    /// `action: "list"` — enumerate the setting menu without touching it.
    ///
    /// An unreadable menu is reported as `presets: null` plus the reason, never
    /// as an empty list: "this plugin has no factory settings" (Sensor,
    /// Trilian — a real, observed answer) and "its preset UI is invisible to
    /// Accessibility" are different facts, and an agent that cannot tell them
    /// apart will either give up on a working plugin or loop on a hopeless one.
    private func presetListPayload(track: String, plugin: String) throws -> [String: Any] {
        let label = logic.pluginPresetLabel(windowTitle: track)
        guard logic.presetPopUpButton(windowTitle: track) != nil else {
            return [
                "success": false,
                "verified": false,
                "presets": NSNull(),
                "preset_count": NSNull(),
                "current_preset": NSNull(),
                "reason": PresetMenuFailure.noPresetPopUp.reason,
                "note": "Fall back to action 'step', which needs no preset names — it reports"
                    + " honestly when the label cannot be read either."
            ]
        }
        let items: [PresetMenuItem]
        do {
            items = try logic.readPresetMenu(windowTitle: track)
        } catch {
            return [
                "success": false,
                "verified": false,
                "presets": NSNull(),
                "preset_count": NSNull(),
                "current_preset": label.map { $0 as Any } ?? NSNull() as Any,
                "reason": PresetMenuFailure.menuDidNotOpen.reason,
                "detail": error.localizedDescription
            ]
        }
        let entries = flattenPresetMenu(items)
        let categories = entries.compactMap(\.category).reduce(into: [String]()) { unique, name in
            if !unique.contains(name) { unique.append(name) }
        }
        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "presets": entries.map(\.dictionary),
            "preset_count": entries.count,
            "categories": categories,
            // The header pop-up's own value, which is what `step` verifies
            // against; the ✓-marked entry is Logic's own answer to the same
            // question and the two can disagree (a setting loaded from disk
            // and then edited keeps the name but loses the mark).
            "current_preset": label.map { $0 as Any } ?? NSNull() as Any,
            "current_preset_marked": entries.first(where: \.active)
                .map { $0.qualifiedName as Any } ?? NSNull() as Any
        ]
        if entries.isEmpty {
            payload["note"] = "The setting menu opened and lists no factory settings at all"
                + " (observed on Sensor and on third-party plugins). Read-only enumeration is"
                + " therefore complete, not failed; 'Load…' in Logic's own menu is the only way in."
        }
        return payload
    }

    /// `action: "select"` — load a setting by name, verified by the label.
    private func presetSelectPayload(
        track: String, plugin: String, requested: String
    ) throws -> [String: Any] {
        guard logic.presetPopUpButton(windowTitle: track) != nil else {
            throw LogicianError.trackNotExposed(
                requested: "loading the setting '\(requested)' by name",
                exposed: PresetMenuFailure.noPresetPopUp.reason + ". Nothing was loaded."
            )
        }
        let labelBefore = logic.pluginPresetLabel(windowTitle: track)
        let entries = flattenPresetMenu(try logic.readPresetMenu(windowTitle: track))
        let entry: PresetEntry
        switch matchPresetName(requested, in: entries) {
        case .resolved(let hit):
            entry = hit
        case .ambiguous(let paths):
            throw LogicianError.presetAmbiguous(requested: requested, paths: paths)
        case .notFound(let available):
            throw LogicianError.presetNotFound(
                plugin: plugin, requested: requested, available: available
            )
        }
        // Already there: say so and press nothing. Re-loading the same setting
        // would overwrite any tweak made on top of it for no gain.
        if labelBefore?.compare(entry.name, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame {
            return [
                "success": true,
                "verified": true,
                "state": "already_loaded",
                "preset_before": labelBefore.map { $0 as Any } ?? NSNull() as Any,
                "preset_after": labelBefore.map { $0 as Any } ?? NSNull() as Any,
                "preset": entry.qualifiedName,
                "note": "The setting was already loaded; nothing was pressed."
            ]
        }
        try logic.pressPresetMenuItem(
            windowTitle: track, category: entry.category, name: entry.name
        )
        let labelAfter = logic.pluginPresetLabel(windowTitle: track)
        let landed = labelAfter?.compare(entry.name, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
        guard landed else {
            throw LogicianError.verificationFailed(
                requested: entry.qualifiedName,
                actual: labelAfter ?? "no readable setting label",
                // Honest: the press happened, so the plugin may well be on
                // another setting now. There is no restore to claim.
                restored: false
            )
        }
        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "loaded",
            "preset": entry.qualifiedName,
            "preset_category": entry.category.map { $0 as Any } ?? NSNull() as Any,
            "preset_before": labelBefore.map { $0 as Any } ?? NSNull() as Any,
            "preset_after": labelAfter.map { $0 as Any } ?? NSNull() as Any,
            "note": "Loaded by pressing the item in the plugin window's setting menu;"
                + " verified against the header label."
        ]
        appendWarning(presetOverwriteWarning, to: &payload)
        return payload
    }

    /// `action: "step"` — unchanged from v1, including its semantics: relative
    /// only, verified by the label, `success: false` when nothing moved.
    ///
    /// It stays the fallback because it is the only route that needs no
    /// readable menu. What it does NOT need any more is the old label reader:
    /// `pluginPresetLabel` used to take the rightmost pop-up in the header,
    /// which on Channel EQ / Limiter / Pitch Shifter is a PARAMETER pop-up
    /// whose value never moves when the setting does — so a successful step
    /// was reported as `stepped: false`. Same code path, correct sensor.
    private func presetStepPayload(track: String, arguments: [String: Any]) throws -> [String: Any] {
        let direction = (arguments["direction"] as? String) ?? "next"
        guard ["next", "previous"].contains(direction) else {
            throw LogicianError.invalidArguments("direction must be 'next' or 'previous'")
        }
        let steps = max(arguments["steps"] as? Int ?? 1, 1)
        let labelBefore = logic.pluginPresetLabel(windowTitle: track)
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
        let labelAfter = logic.pluginPresetLabel(windowTitle: track)
        // success reports whether the preset actually MOVED. It used to be a
        // literal true, so at the end of a preset list - or on a plugin with
        // no factory settings - the agent was told the step happened and
        // reported it to the user.
        let stepped = labelAfter != nil && labelAfter != labelBefore
        var payload: [String: Any] = [
            "success": stepped,
            "verified": stepped,
            "direction": direction,
            "steps": steps,
            "preset_before": labelBefore.map { $0 as Any } ?? NSNull() as Any,
            "preset_after": labelAfter.map { $0 as Any } ?? NSNull() as Any,
            "note": labelAfter == labelBefore
                ? "The preset label did not change (end of the list, or the plugin has no factory settings)."
                : "Preset stepped via the topmost-plugin-window key command."
        ]
        if stepped { appendWarning(presetOverwriteWarning, to: &payload) }
        return payload
    }

    func handleMcuPluginInserts(_ arguments: [String: Any]) throws -> Any {
        let target = try selectStripTarget(arguments)
        guard let inserts = try MCUController.pluginInsertNames() else {
            throw LogicianError.trackNotExposed(
                requested: "MCU plugin insert list",
                exposed: "the MCU bridge is unavailable or the insert list did not appear"
            )
        }
        MCUController.exitToPan()
        var insertsPayload: [String: Any] = [
            "track": target.name,
            "track_name": target.name,
            "mcu_slots": inserts.enumerated().map { index, name in
                ["slot": index + 1, "plugin": name.isEmpty ? "--" : name]
            },
            "note": "MCU slot numbers are physical insert positions and can differ from AX occupied-slot ordinals — on an output strip they were observed in the REVERSE order (Stereo Out, 2026-08-27). Never translate an AX insert_index into an insert_slot."
        ]
        insertsPayload.merge(target.resultFields) { current, _ in current }
        return insertsPayload
    }

    func handleMcuPluginParameters(_ arguments: [String: Any]) throws -> Any {
        guard let slot = arguments["insert_slot"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
        }
        let target = try selectStripTarget(arguments)
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
            throw LogicianError.trackNotExposed(
                requested: "MCU parameter pages for slot \(slot)",
                exposed: "could not enter the plugin edit mode"
            )
        }
        MCUController.exitToPan()
        var pluginPayload: [String: Any] = [
            "track": target.name,
            "track_name": target.name,
            "insert_slot": slot,
            "pages": capped.pages.count,
            "pages_total": capped.total,
            "parameters": capped.pages.enumerated().flatMap { pageIndex, page in
                page.map { ["name": $0.name, "value": $0.value, "page": pageIndex + 1] }
            }
        ]
        pluginPayload.merge(target.resultFields) { current, _ in current }
        if capped.truncated {
            pluginPayload["truncated"] = true
            pluginPayload["note"] = "Showing \(capped.pages.count) of \(capped.total) pages (each uncached page costs ~1.7 s of LCD indicator fade). Pass max_pages for more."
        }
        return pluginPayload
    }

    func handleMcuSetPluginParameter(_ arguments: [String: Any]) throws -> Any {
        guard let slot = arguments["insert_slot"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
        }
        let target = try selectStripTarget(arguments)
        guard var result = try MCUController.setPluginParameter(
            slot: slot,
            parameter: requiredString("parameter", in: arguments),
            targetValue: requiredString("target_value", in: arguments),
            expectedCurrentValue: arguments["expected_current_value"] as? String,
            tolerance: arguments["tolerance"] as? Double,
            trackName: requiredString("track_name", in: arguments)
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU plugin parameter control",
                exposed: "the MCU bridge is unavailable or the plugin edit mode could not be entered"
            )
        }
        result.merge(target.resultFields) { current, _ in current }
        return result
    }

    func handleMcuInstrumentParameters(_ arguments: [String: Any]) throws -> Any {
        // Instruments live on tracks, not on outputs — but the routing is the
        // same call everywhere so a headerless name gets the same honest
        // error instead of "no visible track header matches".
        _ = try selectStripTarget(arguments)
        let instrumentMaxPages = arguments["max_pages"] as? Int ?? 12
        guard let entered = try MCUController.enterInstrumentEdit(
            trackName: requiredString("track_name", in: arguments)
        ), let capped = try MCUController.parameterPagesCapped(
            cacheKey: "instrument:" + entered.name,
            maxPages: instrumentMaxPages
        ) else {
            MCUController.exitToPan()
            throw LogicianError.trackNotExposed(
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
        return instrumentPayload
    }

    func handleMcuSetInstrumentParameter(_ arguments: [String: Any]) throws -> Any {
        _ = try selectStripTarget(arguments)
        guard let result = try MCUController.setInstrumentParameter(
            trackName: requiredString("track_name", in: arguments),
            parameter: requiredString("parameter", in: arguments),
            targetValue: requiredString("target_value", in: arguments),
            expectedCurrentValue: arguments["expected_current_value"] as? String,
            tolerance: arguments["tolerance"] as? Double
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU instrument parameter control",
                exposed: "no instrument in the slot, or the edit mode could not be entered"
            )
        }
        return result
    }
}
