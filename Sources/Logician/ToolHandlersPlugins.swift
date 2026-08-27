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
            throw LogicianError.trackNotExposed(
                requested: "mouse-free plugin insertion",
                exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
            )
        }
        return payload
    }

    func handleRemovePlugin(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
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

    func handlePluginPreset(_ arguments: [String: Any]) throws -> Any {
        let presetTrack = try requiredString("track_name", in: arguments)
        let presetPlugin = try requiredString("plugin_name", in: arguments)
        let direction = (arguments["direction"] as? String) ?? "next"
        guard ["next", "previous"].contains(direction) else {
            throw LogicianError.invalidArguments("direction must be 'next' or 'previous'")
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
        return [
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
    }

    func handleMcuPluginInserts(_ arguments: [String: Any]) throws -> Any {
        _ = try logic.selectTrack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: nil
        )
        guard let inserts = try MCUController.pluginInsertNames() else {
            throw LogicianError.trackNotExposed(
                requested: "MCU plugin insert list",
                exposed: "the MCU bridge is unavailable or the insert list did not appear"
            )
        }
        MCUController.exitToPan()
        return [
            "track": try requiredString("track_name", in: arguments),
            "mcu_slots": inserts.enumerated().map { index, name in
                ["slot": index + 1, "plugin": name.isEmpty ? "--" : name]
            },
            "note": "MCU slot numbers are physical insert positions and can differ from AX occupied-slot ordinals."
        ]
    }

    func handleMcuPluginParameters(_ arguments: [String: Any]) throws -> Any {
        guard let slot = arguments["insert_slot"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
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
            throw LogicianError.trackNotExposed(
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
        return pluginPayload
    }

    func handleMcuSetPluginParameter(_ arguments: [String: Any]) throws -> Any {
        guard let slot = arguments["insert_slot"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
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
            throw LogicianError.trackNotExposed(
                requested: "MCU plugin parameter control",
                exposed: "the MCU bridge is unavailable or the plugin edit mode could not be entered"
            )
        }
        return result
    }

    func handleMcuInstrumentParameters(_ arguments: [String: Any]) throws -> Any {
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
            throw LogicianError.trackNotExposed(
                requested: "MCU instrument parameter control",
                exposed: "no instrument in the slot, or the edit mode could not be entered"
            )
        }
        return result
    }
}
