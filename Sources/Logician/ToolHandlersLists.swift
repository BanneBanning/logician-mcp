import Foundation

// The List Editors family (Event / Marker / Signature), insert bypass and the
// Mixer window — the four tools that came out of the producer audit's
// List-Editors slice.
extension MCPServer {

    // MARK: - logic_list_events (G04)

    func handleListEvents(_ arguments: [String: Any]) throws -> Any {
        // Optionally point the list at a region first: the Event List shows what
        // is SELECTED, so "read this region's notes" is two steps and the tool
        // does both rather than leaving an agent to discover the coupling.
        var selection: [String: Any]?
        if let trackName = arguments["track_name"] as? String {
            selection = try logic.selectRegion(
                trackName: trackName,
                regionName: arguments["region_name"] as? String,
                startBar: arguments["start_bar"] as? Int,
                exclusive: true
            )
        }
        let read = logic.readEventList()
        guard let events = read.events else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Event List",
                exposed: read.failure?.reason ?? "the Event tab published no table"
            )
        }
        let limit = (arguments["limit"] as? Int) ?? 500
        let truncated = events.count > limit
        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "listed",
            "events": Array(events.prefix(limit)),
            "event_count": events.count,
            "columns": read.columns,
            "scope": "the SELECTED region (or the selected track's region at the playhead) — this"
                + " is what Logic's Event List shows, never the whole project. Select with"
                + " track_name/region_name/start_bar here, or with logic_select_region first.",
            "note": "Read out of View > List Editors > Event; the pane and the previously selected"
                + " tab are restored afterwards. Values are Logic's own cell texts, plus parsed"
                + " bar/beat/pitch/velocity/length where the columns were recognised."
        ]
        if let declared = read.declaredCount { payload["declared_count"] = declared }
        if truncated {
            payload["truncated"] = true
            payload["limit"] = limit
            appendWarning(
                "The list holds \(events.count) events and only the first \(limit) are in this"
                    + " result. Raise `limit`, or narrow the selection.",
                to: &payload
            )
        }
        if events.isEmpty {
            appendWarning(
                "The Event List is EMPTY. That means nothing is selected (or the selected region"
                    + " holds no events) — it is NOT evidence that the project has no MIDI. Select"
                    + " a region first.",
                to: &payload
            )
        }
        if let selection { payload["selection"] = selection }
        return payload
    }

    // MARK: - logic_markers (G46)

    func handleMarkers(_ arguments: [String: Any]) throws -> Any {
        let action = (arguments["action"] as? String) ?? "list"
        let name = arguments["name"] as? String
        let bar = arguments["bar"] as? Int
        switch action {
        case "list":
            let read = logic.readMarkerList()
            guard let markers = read.markers else {
                throw LogicianError.trackNotExposed(
                    requested: "Logic's Marker List",
                    exposed: read.failure?.reason ?? "the Marker tab published no table"
                )
            }
            return [
                "success": true, "verified": true, "state": "listed",
                "markers": markers,
                "marker_count": markers.count,
                "columns": read.columns,
                "note": "Read out of View > List Editors > Marker; the pane and the previously"
                    + " selected tab are restored afterwards."
            ]
        case "create":
            return try createMarker(bar: bar, name: name)
        case "goto":
            let read = logic.readMarkerList()
            guard let markers = read.markers else {
                throw LogicianError.trackNotExposed(
                    requested: "Logic's Marker List",
                    exposed: read.failure?.reason ?? "the Marker tab published no table"
                )
            }
            let matches = markers.filter { marker in
                if let name {
                    return (marker["name"] as? String)?
                        .localizedCaseInsensitiveCompare(name) == .orderedSame
                }
                if let bar { return (marker["bar"] as? Int) == bar }
                return false
            }
            guard let marker = matches.first, let target = marker["bar"] as? Int else {
                throw LogicianError.trackNotFound(
                    name.map { "marker '\($0)'" } ?? "a marker at bar \(bar ?? 0)",
                    available: markers.map {
                        "\(($0["name"] as? String) ?? "(unnamed)") at bar \(($0["bar"] as? Int).map(String.init) ?? "?")"
                    }
                )
            }
            guard matches.count == 1 else {
                throw LogicianError.trackAmbiguous(
                    name ?? "bar \(bar ?? 0)", numbers: matches.compactMap { $0["bar"] as? Int }
                )
            }
            var moved = try logic.setPlayhead(barNumber: target, beat: nil)
            moved["marker"] = marker
            moved["state"] = "playhead_at_marker"
            // The playhead lands WITHIN the bar, not exactly on its line
            // (FINDINGS 2026-08-28) — said here because a caller that then
            // creates something at the playhead depends on it.
            moved["note"] = "The playhead was parked at bar \(target). Logic's position stepping"
                + " lands inside the bar, not exactly on its line, so anything placed at the"
                + " playhead afterwards can sit up to a beat late."
            return moved
        case "delete":
            return try logic.deleteMarker(name: name, bar: bar)
        case "rename":
            guard let newName = arguments["new_name"] as? String, !newName.isEmpty else {
                throw LogicianError.invalidArguments("action 'rename' requires new_name")
            }
            return try logic.renameMarker(name: name, bar: bar, newName: newName)
        default:
            throw LogicianError.invalidArguments(
                "action must be list, create, goto, rename or delete"
            )
        }
    }

    /// Creates a marker at the playhead (moving it first when a bar is given)
    /// through the `Create Marker` key command, and verifies against the Marker
    /// List — the count grew, and a marker is at the bar asked for.
    private func createMarker(bar: Int?, name: String?) throws -> [String: Any] {
        let before = logic.readMarkerList().markers ?? []
        var moved: [String: Any]?
        if let bar { moved = try logic.setPlayhead(barNumber: bar, beat: nil) }
        let command = try MCUController.resolveKeyCommand(named: "Create Marker", logic: logic)
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
        var after: [[String: Any]] = []
        var created = false
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            after = logic.readMarkerList().markers ?? []
            if after.count > before.count { created = true; break }
        }
        let beforeRows = Set(before.compactMap { $0["row"] as? Int })
        let fresh = after.first { !beforeRows.contains(($0["row"] as? Int) ?? -1) }
        var payload: [String: Any] = [
            "success": created,
            "verified": created,
            "state": created ? "created" : "failed",
            "markers_before": before.count,
            "markers_after": after.count,
            "markers": after,
            "write_route": "midi_key_command_create_marker",
            "readback_route": "marker_list_reread",
            "note": created
                ? "Created at the PLAYHEAD (Logic's Create Marker places it there, and the"
                    + " playhead lands within the bar rather than exactly on its line). Remove it"
                    + " with action 'delete' or logic_trigger_key_command {name: \"Undo\"}."
                : "No new marker appeared in the Marker List after the key command fired."
        ]
        if let moved { payload["playhead"] = moved }
        if let fresh { payload["marker"] = fresh }
        if let name {
            // Naming is a SEPARATE write and is reported separately: Logic's
            // Create Marker names the marker itself, and whether the row can be
            // renamed from this plane is a runtime question.
            if let renamed = try? logic.renameMarker(name: nil, bar: fresh?["bar"] as? Int, newName: name) {
                payload["renamed"] = renamed["success"] ?? false
                payload["markers"] = renamed["markers"] ?? after
            } else {
                payload["renamed"] = false
                appendWarning(
                    "The marker was created and verified, but it could NOT be renamed to"
                        + " '\(name)' — the Marker List's cells are not writable from"
                        + " Accessibility. It carries Logic's own default name.",
                    to: &payload
                )
            }
        }
        return payload
    }

    // MARK: - logic_list_signatures (G48)

    func handleListSignatures(_ arguments: [String: Any]) throws -> Any {
        let knowledge = resolveMeterKnowledge()
        guard let map = knowledge.map else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Signature List",
                exposed: knowledge.failure?.reason ?? "the Signature tab published no table"
            )
        }
        return [
            "success": true, "verified": true, "state": "listed",
            "signatures": zip(map.bars, map.signatures).map { bar, signature in
                [
                    "bar": bar,
                    "signature": signature,
                    "beats_per_bar": map.beatsPerBar(atBar: bar)
                ] as [String: Any]
            },
            "constant": map.isConstant,
            "meter_map": knowledge.payload,
            "note": "beats_per_bar counts QUARTER notes, which is what Logic's BPM counts: 6/8 is"
                + " three beats a bar, 7/8 three and a half. A map with one bar length is reported"
                + " and NOT used by the bar math — the control bar's time signature (or an explicit"
                + " beats_per_bar argument) stays authoritative there, which keeps a constant-meter"
                + " project's boundaries exactly what they have always been. A map with more than"
                + " one bar length IS integrated by every tool that converts bars to seconds."
        ]
    }

    // MARK: - logic_set_insert_bypass (G36)

    func handleSetInsertBypass(_ arguments: [String: Any]) throws -> Any {
        guard let bypassed = arguments["bypassed"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: bypassed")
        }
        return try logic.setInsertBypass(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            pluginName: arguments["plugin_name"] as? String,
            insertIndex: arguments["insert_index"] as? Int,
            bypassed: bypassed,
            expectedCurrentBypassed: arguments["expected_current_bypassed"] as? Bool
        )
    }

    // MARK: - logic_set_mixer (G57)

    func handleSetMixer(_ arguments: [String: Any]) throws -> Any {
        guard let open = arguments["open"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: open")
        }
        return try logic.setMixerOpen(open)
    }
}
