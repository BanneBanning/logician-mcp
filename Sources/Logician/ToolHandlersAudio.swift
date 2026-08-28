import Foundation

// Audio pipeline: bounce, render, A/B evaluation, audio clip reads.
extension MCPServer {
    func handleBounceRange(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integers: start_bar, end_bar")
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
        return payload
    }

    func handleEvaluateChange(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integers: start_bar, end_bar")
        }
        if (arguments["method"] as? String) == "render" {
            guard let slot = arguments["insert_slot"] as? Int else {
                throw LogicianError.invalidArguments(
                    "method 'render' requires insert_slot (1-8, MCU physical slot; list with logic_mcu_plugin_inserts)"
                )
            }
            // Method 'render' cuts BOTH the baseline and the changed audio out
            // of a freeze render by bar math. Under a tempo map, math that
            // assumes one tempo makes the two cuts land on different musical
            // material, so the A/B — the entire job of this tool — would compare
            // two different passages and report the difference as if the plugin
            // had caused it.
            //
            // With the tempo map READ from Logic's Tempo List that is no longer
            // a problem: both slices are integrated over the same map, so they
            // cover the same bars and the comparison is sound. The refusal
            // therefore applies only when the map is UNREADABLE and the
            // two-point sample says the tempo moves — knowledge, not assumption,
            // decides. 'bounce' and 'solo_bounce' never slice seconds, so they
            // pay nothing for any of this.
            let resolvedMeter = try resolveTempoAndMeter(logic: logic, arguments: arguments)
            let knowledge = resolveTempoKnowledge(
                startBar: startBar, endBar: endBar, beatsPerBar: resolvedMeter.beatsPerBar
            )
            if knowledge.readMap == nil, let span = knowledge.sample?.span, !span.isConstant {
                throw LogicianError.tempoMapUnsafe(
                    operation: "logic_evaluate_change method \"render\" over bars \(startBar)-\(endBar)",
                    detail: "\(knowledge.refusalDetail ?? span.mismatchClause). This method"
                        + " slices seconds out of a freeze render, and the project's tempo map"
                        + " could not be read"
                        + (knowledge.mapFailure.map { " (\($0.reason))" } ?? "")
                        + " — so the boundaries would come from (bar - 1) x beats x 60/BPM math,"
                        + " the baseline slice and the changed slice would cover DIFFERENT music,"
                        + " and their dB deltas would say nothing about the parameter. NOTHING was"
                        + " changed and no render was made. Use method \"bounce\" (offline master"
                        + " A/B) or \"solo_bounce\" (soloed offline A/B, for tracks freeze refuses)"
                        + " instead: those hand Logic the bar numbers and are correct under any"
                        + " tempo map."
                )
            }
            // The METER map, on the same terms as the tempo map: read once,
            // used only when it actually varies, so a constant-meter project's
            // two slices are cut exactly where they always were.
            let meterKnowledge = resolveMeterKnowledge()
            // The tempo and meter resolved above, not read a second time.
            let range = try MCPServer.barRangeSeconds(
                startBar: startBar, endBar: endBar,
                tempo: resolvedMeter.tempo, beatsPerBar: resolvedMeter.beatsPerBar,
                map: knowledge.readMap, meterMap: meterKnowledge.integratedMap
            )
            var rendered = try MCUController.evaluateChangeRendered(
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
            // A sample that could not run gets a warning, not a refusal: the
            // check failing must not break an A/B that works today.
            appendWarning(
                knowledge.warning(sliced: "the two compared slices"), to: &rendered
            )
            appendWarning(
                meterKnowledge.warning(sliced: "the two compared slices"), to: &rendered
            )
            if let block = knowledge.payload { rendered["tempo_map"] = block }
            rendered["meter_map"] = meterKnowledge.payload
            return rendered
        }
        if (arguments["method"] as? String) == "solo_bounce" {
            guard let slot = arguments["insert_slot"] as? Int else {
                throw LogicianError.invalidArguments(
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
            return payload
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
            return payload
        }
        throw LogicianError.invalidArguments(
            "method must be one of 'render' (single-track freeze A/B, needs insert_slot), "
                + "'bounce' (master A/B, needs plugin_name) or 'solo_bounce' "
                + "(soloed master A/B for tracks freeze refuses, needs insert_slot)"
        )
    }

    func handleRenderTrack(_ arguments: [String: Any]) throws -> Any {
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
            throw LogicianError.trackNotExposed(
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
        // Only the SLICE does bar math; the full-track render is a freeze from
        // project start and needs no tempo at all. So the tempo is resolved here
        // and nowhere else — a render without start_bar/end_bar costs nothing.
        var knowledge: TempoKnowledge?
        var meterKnowledge: MeterKnowledge?
        if let startBar = arguments["start_bar"] as? Int,
           let endBar = arguments["end_bar"] as? Int {
            let resolvedMeter = try resolveTempoAndMeter(logic: logic, arguments: arguments)
            let resolved = resolveTempoKnowledge(
                startBar: startBar, endBar: endBar, beatsPerBar: resolvedMeter.beatsPerBar
            )
            knowledge = resolved
            let meter = resolveMeterKnowledge()
            meterKnowledge = meter
            sliceRange = try MCPServer.barRangeSeconds(
                startBar: startBar, endBar: endBar,
                tempo: resolvedMeter.tempo, beatsPerBar: resolvedMeter.beatsPerBar,
                map: resolved.readMap, meterMap: meter.integratedMap
            )
        }
        var render = try MCUController.renderSelectedTrack(
            projectPath: projectPath, label: label,
            sliceStartSeconds: sliceRange?.start, sliceEndSeconds: sliceRange?.end,
            logic: logic, trackName: trackName
        )
        render["track"] = trackName
        render["track_name"] = trackName
        if let range = sliceRange {
            render["slice_tempo"] = range.tempo
            render["slice_beats_per_bar"] = range.beatsPerBar
        }
        // The full render is unaffected by any tempo map — only the slice's
        // boundaries are, and the warning says exactly that much.
        appendWarning(
            knowledge?.warning(sliced: "the requested bar-range slice (the FULL render is unaffected)"),
            to: &render
        )
        appendWarning(
            meterKnowledge?.warning(
                sliced: "the requested bar-range slice (the FULL render is unaffected)"
            ),
            to: &render
        )
        if let block = knowledge?.payload { render["tempo_map"] = block }
        if let block = meterKnowledge?.payload { render["meter_map"] = block }
        return render
    }

    func handleGetAudioClip(_ arguments: [String: Any]) throws -> Any {
        let clipPath = (try requiredString("path", in: arguments) as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: clipPath) else {
            throw LogicianError.trackNotExposed(requested: "audio file at '\(clipPath)'", exposed: "no such file")
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
            throw LogicianError.writeFailed("afconvert could not produce the clip (is the source a readable audio file?)")
        }
        guard clipData.count <= 400_000 else {
            throw LogicianError.invalidArguments(
                "the encoded clip is \(clipData.count / 1000) KB - too large to attach safely; request a shorter duration_seconds"
            )
        }
        return [
            "success": true,
            "source": clipPath,
            "start_seconds": clipStart,
            "duration_seconds": clipDuration,
            "encoded_bytes": clipData.count,
            "clip_path": scratch.path,
            "note": "An MCP AUDIO content block accompanies this text (mono AAC). SELF-CHECK: if no audio block reached you, your client DROPS them - do not pretend to hear; instead open clip_path with your client's file viewer (many viewers pass audio files to the model as real multimodal input; verified in Antigravity). NEVER read audio files as text/bash.",
            "_audio": ["data": clipData.base64EncodedString(), "mimeType": "audio/mp4"]
        ]
    }
}
