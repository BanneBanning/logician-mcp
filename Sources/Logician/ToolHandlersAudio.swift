import Foundation

// Audio pipeline: bounce, render, A/B evaluation, audio clip reads.
extension MCPServer {
    func handleBounceRange(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integers: start_bar, end_bar")
        }
        var options: [String: String] = [:]
        for key in ["file_type", "bit_depth", "sample_rate", "dithering", "normalize"] {
            if let value = arguments[key] as? String { options[key] = value }
            // A sample rate passed as a NUMBER (48000) is the obvious mistake
            // and is cheaper to accept than to refuse.
            if let number = arguments[key] as? Int { options[key] = String(number) }
            if let number = arguments[key] as? Double {
                options[key] = number == number.rounded()
                    ? String(Int(number)) : String(number)
            }
        }
        do {
            payload = try logic.bounceRange(
                startBar: startBar,
                endBar: endBar,
                label: (arguments["label"] as? String) ?? "bounce",
                expectedProjectPath: arguments["expected_project_path"] as? String,
                options: options,
                includeAudioTail: arguments["include_audio_tail"] as? Bool
            )
        } catch {
            // A modal Bounce dialog left open freezes EVERYTHING —
            // always cancel it before surfacing the error.
            logic.cancelBounceDialog()
            throw error
        }
        return payload
    }

    /// G54: aligned stems, composed out of machinery that already exists —
    /// the solo toggle, the offline bounce, and the frame count the metrics
    /// reader already computes. What makes them STEMS rather than a loop over
    /// renders is the shared bar contract: every file covers exactly the same
    /// range, and the tool says so only after comparing their frame counts.
    func handleExportStems(_ arguments: [String: Any]) throws -> Any {
        guard let startBar = arguments["start_bar"] as? Int,
              let endBar = arguments["end_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integers: start_bar, end_bar")
        }
        guard endBar > startBar else {
            throw LogicianError.invalidArguments("end_bar must be greater than start_bar")
        }
        guard let requested = arguments["tracks"] as? [String] else {
            throw LogicianError.invalidArguments("missing array of strings: tracks")
        }
        let tracks = try StemExport.normalizedTracks(requested)
        try logic.verifyProjectPath(arguments["expected_project_path"] as? String)

        // A solo that is already on poisons every stem: each bounce would
        // carry that track as well, and nothing downstream could tell. This
        // is the same failure logic_bounce_range warns about after the fact -
        // here it is a refusal before the first render, because the whole
        // point of a stem set is that each file holds ONE track.
        // `nil` is NOT `[]` here: an unreadable Tracks area used to answer
        // "is anything soloed?" with "no" and walk straight past this
        // refusal — the one check that makes a stem set stems.
        let preSoloed = logic.soloedTrackNamesIfReadable()
        if let preSoloed, !preSoloed.isEmpty {
            throw LogicianError.currentValueMismatch(
                expected: "no track soloed before the stem run",
                actual: "\(preSoloed.joined(separator: ", ")) already soloed. Nothing was bounced - "
                    + "every stem would have contained those tracks too. Unsolo and call again."
            )
        }

        let prefix = sanitizedFilenameComponent(
            (arguments["label"] as? String) ?? "stem", fallback: "stem"
        )
        var stems: [[String: Any]] = []
        var frames: [Int?] = []
        var warnings: [String] = []

        for (index, track) in tracks.enumerated() {
            // One stem is one whole bounce, so this is the only boundary that
            // matters: a cancellation between stems abandons the run with the
            // solo already down and the stems so far already on disk.
            try checkCancelled()
            let slot = 100 / Double(tracks.count)
            reportProgress(
                "bouncing stem \(index + 1)/\(tracks.count): \(track)",
                percent: Double(index) * slot
            )
            func setSolo(_ enabled: Bool) throws {
                _ = try MCUController.setToggle(trackName: track, control: "solo", enabled: enabled)
                    ?? logic.setStripToggle(
                        trackName: track, trackNumber: nil, control: "solo", enabled: enabled
                    )
            }
            try setSolo(true)
            var bounce: [String: Any]
            do {
                // The bounce reports 0…100 of ITS work; this stem owns one
                // slice of the export's, so its scale is folded into that
                // slice and the export's line keeps climbing across stems.
                bounce = try withProgressScope(
                    (Double(index) * slot)...(Double(index + 1) * slot)
                ) {
                    try logic.bounceRange(
                        startBar: startBar, endBar: endBar,
                        label: "\(prefix)-\(sanitizedFilenameComponent(track, fallback: "track"))",
                        expectedProjectPath: nil
                    )
                }
            } catch {
                // Never leave a solo up: the next tool call - or the user's
                // own next bounce - would be silently wrong.
                logic.cancelBounceDialog()
                try? setSolo(false)
                throw error
            }
            // Unsolo BEFORE reading the file: the render is already on disk,
            // and holding the solo one call longer is the risk this whole
            // handler is built to avoid.
            var soloRestored = true
            do { try setSolo(false) } catch { soloRestored = false }

            let path = bounce["path"] as? String ?? ""
            let metrics = LogicAccessibility.audioFileMetrics(path: path)
            frames.append(metrics?["frames"] as? Int)
            var stem: [String: Any] = [
                "track": track, "track_name": track,
                "path": path,
                "preview_path": bounce["preview_path"] ?? NSNull(),
                "bytes": bounce["bytes"] ?? NSNull(),
                "metrics": metrics ?? NSNull(),
                "solo_restored": soloRestored
            ]
            if !soloRestored {
                stem["warning"] = "the solo on '\(track)' could NOT be switched off again"
                warnings.append("'\(track)' is still soloed - every later bounce contains only it until that is fixed.")
            }
            if let rms = metrics?["rms_db"] as? [Double], rms.allSatisfy({ $0 <= -65 }) {
                stem["warning"] = "this stem is SILENT (rms \(rms) dB)"
                warnings.append("'\(track)' bounced silent - it is muted, empty across bars \(startBar)-\(endBar), or not the track you meant.")
            }
            stems.append(stem)
        }
        reportProgress("bounced \(stems.count) stem\(stems.count == 1 ? "" : "s")", percent: 100)

        // The stems are only stems if they line up.
        let alignment = StemExport.frameAlignment(frames)
        let leftSoloed = logic.soloedTrackNamesIfReadable()
        if let leftSoloed, !leftSoloed.isEmpty {
            warnings.append("Tracks still SOLOED after the run: \(leftSoloed.joined(separator: ", ")). Fix before any further bounce.")
        } else if leftSoloed == nil {
            warnings.append("Logic's track headers could not be read after the run, so whether a solo was left up is UNKNOWN - check the mixer before any further bounce.")
        }
        // Only a track list that was actually READ and came back empty clears
        // this; an unreadable one leaves `verified` false rather than claiming
        // a solo-clean project nobody looked at.
        let soloClear = leftSoloed?.isEmpty ?? false
        var result: [String: Any] = [
            "success": true,
            "verified": alignment.aligned && soloClear,
            "state": "exported",
            "range": ["start_bar": startBar, "end_bar": endBar],
            "count": stems.count,
            "stems": stems,
            "aligned": alignment.aligned,
            "alignment_note": alignment.note,
            "note": StemExport.contentsNote
                + " Verification: " + alignment.note
                + " No audio is attached - a stem set is far too much base64 for one result; open the paths with your client's file viewer, or logic_get_audio_clip one at a time."
        ]
        if !warnings.isEmpty { result["warning"] = warnings.joined(separator: " ALSO: ") }
        return result
    }

    /// G33 / U7: "print that" — the verb `logic_render_track` is not.
    func handleBounceInPlace(_ arguments: [String: Any]) throws -> Any {
        let scope = (arguments["scope"] as? String) ?? "region"
        guard ["region", "track"].contains(scope) else {
            throw LogicianError.invalidArguments("scope must be 'region' or 'track'")
        }
        // The sheet's checkbox titles are its own; the arguments are the
        // snake_case of the same names, mapped in one place.
        let checkboxNames = [
            "include_volume_pan_automation": "Include Volume/Pan Automation",
            "include_audio_tail_in_region": "Include Audio Tail in Region",
            "include_audio_tail_in_file": "Include Audio Tail in File",
            "bypass_effect_plugins": "Bypass Effect Plug-ins",
            "bounce_second_loop_pass": "Bounce Second Loop Pass",
            "include_instrument_multi_outputs": "Include Instrument Multi-Outputs"
        ]
        var checkboxes: [String: Bool] = [:]
        for (argument, title) in checkboxNames {
            if let value = arguments[argument] as? Bool { checkboxes[title] = value }
        }
        do {
            return try logic.bounceInPlace(
                scope: scope,
                trackName: arguments["track_name"] as? String,
                regionName: arguments["region_name"] as? String,
                startBar: arguments["start_bar"] as? Int,
                name: arguments["name"] as? String,
                normalize: arguments["normalize"] as? String,
                destination: arguments["destination"] as? String,
                source: arguments["source"] as? String,
                checkboxes: checkboxes
            )
        } catch {
            logic.cancelBounceInPlaceSheet()
            throw error
        }
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
                    "method 'render' requires insert_slot (1-8, MCU physical slot; list with logic_list_inserts route 'mcu')"
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
            reportProgress("A/B complete", percent: 100)
            return rendered
        }
        if (arguments["method"] as? String) == "solo_bounce" {
            guard let slot = arguments["insert_slot"] as? Int else {
                throw LogicianError.invalidArguments(
                    "method 'solo_bounce' requires insert_slot (1-8, MCU physical slot; list with logic_list_inserts route 'mcu')"
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
        let requestedDuration = (arguments["duration_seconds"] as? Double)
            ?? (arguments["duration_seconds"] as? Int).map(Double.init) ?? 8.0
        let clipDuration = min(requestedDuration, 20.0)
        // The encoded clip is kept on disk: clients that drop MCP
        // audio blocks need a FILE their viewer can hand to the model. The
        // name carries milliseconds and a random suffix, so two calls inside
        // one second cannot write the same path (they used to, and the second
        // overwrote the first).
        let clipsDirectory = Captures.ensureRoot()
        let scratch = clipsDirectory.appendingPathComponent(
            AudioClip.clipFileName(sourcePath: clipPath)
        )
        // Every failure below leaves the captures directory as it found it:
        // an orphaned .m4a from a refused call used to survive in the user's
        // own render folder, which nothing prunes.
        var delivered = false
        defer {
            if !delivered { try? FileManager.default.removeItem(at: scratch) }
        }
        // Window and encode in process: the range is SEEKED to (only the
        // window is decoded) and mixed to mono by us. Both halves of the old
        // route were wrong - see AudioClip.
        let clip: AudioClip.Clip
        do {
            clip = try AudioClip.write(
                sourcePath: clipPath, startSeconds: clipStart,
                durationSeconds: clipDuration, destination: scratch
            )
        } catch let fault as AudioClip.Fault {
            switch fault {
            case .startPastEnd, .startBeforeFile, .emptyWindow:
                throw LogicianError.invalidArguments(fault.message)
            case .unreadable, .emptySource:
                throw LogicianError.trackNotExposed(
                    requested: "an audio clip of '\(clipPath)'", exposed: fault.message
                )
            case .encoderRefused:
                throw LogicianError.writeFailed(fault.message)
            }
        }
        guard let clipData = try? Data(contentsOf: scratch), !clipData.isEmpty else {
            throw LogicianError.writeFailed(
                "the AAC encoder reported success but wrote no bytes to '\(scratch.path)'"
            )
        }
        guard clipData.count <= 400_000 else {
            // The advice has to be one the caller can follow: the window IS
            // honoured now, so a shorter duration really does return fewer
            // bytes, and the number named here is the length that fits at the
            // rate this very clip encoded at.
            let perSecond = Double(clipData.count) / max(clip.durationSeconds, 0.001)
            let fits = (400_000 / perSecond * 10).rounded(.down) / 10
            throw LogicianError.invalidArguments(
                "the encoded clip is \(clipData.count / 1000) KB - over the 400 KB this server "
                + "will attach; this source encodes at ~\(Int(perSecond / 1000)) KB per second, "
                + "so pass duration_seconds: \(fits) or less."
            )
        }
        var result: [String: Any] = [
            "success": true,
            "source": clipPath,
            "start_seconds": clip.startSeconds,
            "duration_seconds": clip.durationSeconds,
            "source_seconds": clip.sourceSeconds,
            "encoded_bytes": clipData.count,
            "clip_path": scratch.path,
            "note": "An MCP AUDIO content block accompanies this text (mono AAC, mixed down from \(clip.sourceChannels) channel\(clip.sourceChannels == 1 ? "" : "s")). SELF-CHECK: if no audio block reached you, your client DROPS them - do not pretend to hear; instead open clip_path with your client's file viewer (many viewers pass audio files to the model as real multimodal input; verified in Antigravity). NEVER read audio files as text/bash.",
            "_audio": ["data": clipData.base64EncodedString(), "mimeType": "audio/mp4"]
        ]
        if requestedDuration > 20.0 {
            appendWarning(
                "duration_seconds \(requestedDuration) is over this tool's 20 s ceiling; "
                + "the clip is 20 s.",
                to: &result
            )
        }
        if clip.truncated {
            appendWarning(
                "the file ends at \(clip.sourceSeconds) s, so the clip is "
                + "\(clip.durationSeconds) s rather than the \(clipDuration) s requested.",
                to: &result
            )
        }
        delivered = true
        return result
    }
}
