import Foundation

// logic_import_midi: a whole arrangement, written as bytes and handed to
// Logic's own importer.
extension MCPServer {

    /// The track header rows, or none — a census read that fails is a census of
    /// nothing, and every caller here compares two of them.
    private func trackRows() -> [[String: Any]] {
        ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
    }

    func handleImportMIDI(_ arguments: [String: Any]) throws -> Any {
        try logic.verifyProjectPath(arguments["expected_project_path"] as? String)
        guard let rawTracks = arguments["tracks"] as? [[String: Any]] else {
            throw LogicianError.invalidArguments(
                "tracks is required: [{name, channel?, notes: [...], control_changes?,"
                    + " pitch_bends?, program_changes?}, ...]"
            )
        }
        let tracks = try ImportMIDI.tracks(from: rawTracks)
        let atBar = arguments["at_bar"] as? Int ?? 1
        guard atBar >= 1 else {
            throw LogicianError.invalidArguments("at_bar must be 1 or greater; got \(atBar)")
        }
        let importTempo = arguments["import_tempo"] as? Bool ?? false
        let verify = (arguments["verify"] as? String) ?? "census"
        guard ["census", "events"].contains(verify) else {
            throw LogicianError.invalidArguments("verify must be 'census' or 'events'")
        }
        let fileTempo = doubleArgument("tempo", in: arguments)
        // Answering "Import Tempo" on a file that carries NO tempo of its own
        // would write the SMF default (120 BPM) over the project's map. That is
        // the one way this tool could destroy a tempo map by accident, so it is
        // refused before anything is written rather than warned about after.
        if importTempo, fileTempo == nil {
            throw LogicianError.invalidArguments(
                "import_tempo: true needs an explicit `tempo`. The generated file carries no"
                    + " tempo unless you name one, and answering Logic's prompt with"
                    + " 'Import Tempo' for a file with no tempo of its own writes the Standard"
                    + " MIDI File DEFAULT of 120 BPM over the project's tempo map. Pass the BPM"
                    + " you mean, or leave import_tempo out and the project's tempo is untouched."
            )
        }

        // The grid the arrangement is written against is the PROJECT's, read
        // once: Logic interprets the file's ticks as musical time against its
        // own tempo and signature tracks (measured — four quarter notes filled
        // one whole 4/4 bar at bar 9 and four of the five beats of the 5/4 bar
        // at bar 62), so a bar number here has to mean the same bar it means
        // there. The meter map is honoured only when it VARIES, per the
        // house-wide constant-meter contract.
        // A control bar that cannot be read falls back to 4, which is the
        // assumption every bar calculation in this server made before the maps
        // existed — and a VARYING meter is honoured through the map regardless
        // of what this scalar says.
        let beatsPerBar = (try? resolveTempoAndMeter(logic: logic, arguments: [:]))?.beatsPerBar ?? 4
        let meterKnowledge = resolveMeterKnowledge()
        var timing = SMFTiming()
        timing.beatsPerBar = beatsPerBar
        timing.meterMap = meterKnowledge.integratedMap
        timing.originBar = atBar
        if let fileTempo { timing.tempo = .constant(fileTempo) }
        // The time signature is NEVER written. A signature meta is a write to
        // the project's signature track the moment Logic imports it, and this
        // tool has no argument that asks for one.
        let writer = try SMFWriter(
            format: .multiTrack, tracks: tracks, timing: timing,
            sequenceName: tracks.first?.name
        )
        let directory = Captures.ensureRoot()
        let file = directory.appendingPathComponent(ImportMIDI.fileName(
            firstTrack: tracks.first?.name, timestamp: Int(Date().timeIntervalSince1970)
        ))
        let bytes = try writer.write(to: file)
        reportProgress("wrote \(bytes) bytes of Standard MIDI File", percent: 5)

        // FRONTMOST BEFORE THE CENSUS, not just before the panel. Measured
        // 2026-08-30: with Logic in the background `logic_list_regions` came
        // back with ZERO track rows on a project holding dozens — the region
        // rows hang off the standard window, and Logic publishes almost
        // nothing while it is not genuinely frontmost. An empty "before"
        // census would make every pre-existing region look newly imported,
        // which is the diff deciding the tool half-failed and rolling back
        // material it never created.
        try logic.ensureLogicFrontmost(for: "reading the project census")

        // The census, before anything moves. Both halves: tracks answer "how
        // many appeared", regions answer "and are they the ones we wrote" —
        // the region name is the ONLY handle the import gives back, because
        // Logic names the new TRACKS after whichever default patch it loaded.
        let tracksBefore = trackRows()
        let regionsBefore = ImportMIDI.RegionCensus.parse(
            (try? logic.listRegions(trackName: nil)) ?? [:]
        )

        // Logic imports at the bar line NEAREST the playhead, meter-aware and
        // rounding rather than truncating (beat 3 of a 4/4 bar lands on the
        // NEXT bar). Parking on the grid first is what turns that into an
        // exact landing — and it is the expensive step, not the import.
        try checkCancelled()
        reportProgress("parking the playhead at bar \(atBar)", percent: 10)
        let parked = try logic.parkPlayheadOnGrid(bar: atBar, beat: 1)
        reportProgress("importing \(tracks.count) track(s)", percent: 35)

        let route: [String: Any]
        do {
            try checkCancelled()
            route = try logic.importMIDIFile(path: file.path, importTempo: importTempo)
        } catch {
            // Nothing may be left standing, and anything that half-landed goes
            // back out one track at a time. Reported rather than thrown: the
            // cleanup's own outcome is the half of a failure the caller most
            // needs, and an error string cannot carry it.
            let cleanup = logic.dismissImportPanel()
            let rollback = rollbackImportedTracks(since: tracksBefore)
            return [
                "success": false,
                "verified": false,
                "state": "failed",
                "error_code": (error as? LogicianError)?.code ?? "failed",
                "error": error.localizedDescription,
                "cleanup": cleanup,
                "restored": rollback,
                "file": file.path,
                "at_bar": atBar,
                "tracks_before": tracksBefore.count,
                "tracks_after": trackRows().count
            ]
        }
        reportProgress("verifying what landed", percent: 70)

        if importTempo {
            // A tempo-map WRITE happened. The cached map describes the project
            // as it was, which is now confidently wrong.
            invalidateTempoMapCache()
        }

        // Same reason as the census before: a background Logic publishes no
        // region rows, and the diff would read that as a failed import.
        try? logic.ensureLogicFrontmost(for: "reading the project census")
        let tracksAfter = trackRows()
        let regionsAfter = ImportMIDI.RegionCensus.parse(
            (try? logic.listRegions(trackName: nil)) ?? [:]
        )
        let newTrackNumbers = ImportMIDI.addedTrackNumbers(before: tracksBefore, after: tracksAfter)
        let landed = regionsAfter.added(since: regionsBefore)
        let wantedNames = tracks.compactMap(\.name)
        let landedNames = landed.map(\.name)
        let missing = wantedNames.filter { name in
            !landedNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let atWrongBar = landed.filter { $0.startBar != atBar }

        var result: [String: Any] = [
            "file": file.path,
            "file_bytes": bytes,
            "at_bar": atBar,
            "requested_tracks": tracks.count,
            "tracks_before": tracksBefore.count,
            "tracks_after": tracksAfter.count,
            "new_track_numbers": newTrackNumbers,
            "new_tracks": tracksAfter.filter {
                newTrackNumbers.contains($0["track_number"] as? Int ?? -1)
            }.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] },
            "regions": landed.map(\.payload),
            "playhead": parked,
            "route": route,
            "meter_map": meterKnowledge.payload,
            "tempo_written": fileTempo.map { $0 as Any } ?? NSNull(),
            "note": "Logic names the new TRACKS after whatever default patch it loaded"
                + " ('Studio Grand', 'Epic Cloud Formation'); the SMF track names come back on the"
                + " REGIONS, which is what this result verified against. Rename the tracks with"
                + " logic_rename_track if the names matter. The .mid is left at `file` — re-import"
                + " it, or hand it to another tool."
        ]

        // THE FAILURE SIGNAL IS THE CENSUS. A file Logic cannot read fails
        // SILENTLY — no error dialog, sometimes not even the tempo prompt — so
        // "nothing appeared" is the only evidence there is, and it must not be
        // reported as a success with an empty list.
        guard !landed.isEmpty else {
            result["success"] = false
            result["verified"] = false
            result["state"] = "nothing_imported"
            result["error"] = "Logic imported NOTHING: the track census is unchanged"
                + " (\(tracksBefore.count) before, \(tracksAfter.count) after) and no new region"
                + " appeared. A file Logic cannot read fails silently — there is no error dialog —"
                + " so this is what that looks like. The file this call wrote is at \(file.path)."
            return result
        }
        if !missing.isEmpty || !atWrongBar.isEmpty {
            // A PARTIAL landing: some tracks arrived, or they arrived somewhere
            // else. Take them back out rather than leaving the project holding
            // half an arrangement.
            let rollback = rollbackImportedTracks(since: tracksBefore)
            result["success"] = false
            result["verified"] = false
            result["state"] = "partial"
            result["restored"] = rollback
            result["error"] = (missing.isEmpty
                ? ""
                : "these tracks never arrived: \(missing.joined(separator: ", ")). ")
                + (atWrongBar.isEmpty
                    ? ""
                    : "these regions landed away from bar \(atBar): "
                        + atWrongBar.map { "\($0.name)@bar\($0.startBar.map(String.init) ?? "?")" }
                            .joined(separator: ", ") + ". ")
                + (rollback["note"] as? String ?? "")
            return result
        }

        result["success"] = true
        result["state"] = "imported"
        result["verified"] = true
        if verify == "events" {
            let events = verifyImportedNotes(tracks: tracks, landed: landed)
            result["note_verification"] = events.perTrack
            result["verified"] = events.allMatch
            if !events.allMatch {
                appendWarning(
                    "The regions landed, but the NOTES in them do not all match what was written"
                        + " — see note_verification. The import itself completed; nothing was"
                        + " rolled back.",
                    to: &result
                )
            }
        } else {
            result["note_verification"] = "not run (verify: 'census'). Pass verify: 'events' to"
                + " read every new region's notes back out of Logic's Event List and diff them"
                + " against what was written (~2 s per region)."
        }
        if importTempo {
            appendWarning(
                "import_tempo: true answered Logic's prompt with 'Import Tempo', which REPLACED"
                    + " the project's tempo information in the range of the file with"
                    + " \(fileTempo.map { String(format: "%g", $0) } ?? "?") BPM. Any previously"
                    + " recorded audio that is not in Flex mode is now out of sync with the"
                    + " sequencer. The cached tempo map was discarded; read it back with"
                    + " logic_tempo_events.",
                to: &result
            )
        }
        appendWarning(meterKnowledge.warning(sliced: "the bar positions written into the file"), to: &result)
        return result
    }

    // MARK: - Note-level verification

    /// Reads each new region's notes back out of Logic's Event List and diffs
    /// them against what was written. ~2 s per region: the Event List opens and
    /// restores the List Editors pane on every read.
    ///
    /// RETRIED, because the first read after an import is taken while Logic is
    /// still busy. Measured 2026-08-30: the tempo prompt closes as soon as the
    /// import is done, but Logic goes on instantiating the new tracks'
    /// instruments — and during that window the View menu answered a press with
    /// nothing ("the List Editors pane could not be opened"), and one read
    /// later `NSRunningApplication` briefly listed no Logic at all ("Logic Pro
    /// is not running") on a Logic that was perfectly healthy. Both attempts
    /// came back clean a second apart. So: settle, then up to three tries a
    /// second and a half apart, each preceded by the frontmost escalation.
    private func verifyImportedNotes(
        tracks: [SMFTrack], landed: [ImportMIDI.RegionCensus.Entry]
    ) -> (perTrack: [[String: Any]], allMatch: Bool) {
        var reports: [[String: Any]] = []
        var allMatch = true
        Thread.sleep(forTimeInterval: 1.5)
        for track in tracks {
            guard let name = track.name,
                  let region = landed.first(where: {
                      $0.name.caseInsensitiveCompare(name) == .orderedSame
                  }) else { continue }
            var payload: [String: Any] = [
                "region": region.name, "read": false,
                "reason": "not attempted"
            ]
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
                try? logic.ensureLogicFrontmost(for: "reading '\(region.name)' back")
                do {
                    _ = try logic.selectRegion(
                        trackName: region.trackName, regionName: region.name,
                        startBar: region.startBar, exclusive: true
                    )
                    let read = logic.readEventList()
                    guard let events = read.events else {
                        payload["reason"] = read.failure?.reason
                            ?? "the Event tab published no table"
                        continue
                    }
                    let rows = EventListWrite.rows(
                        cells: events.map { ($0["cells"] as? [String]) ?? [] },
                        columns: read.columns
                    )
                    let diff = ImportMIDI.diff(expected: track.notes, observed: rows)
                    payload = diff.payload
                    payload["region"] = region.name
                    payload["track_name"] = region.trackName
                    payload["read"] = true
                    if attempt > 0 { payload["attempts"] = attempt + 1 }
                    break
                } catch {
                    payload["reason"] = error.localizedDescription
                }
            }
            if payload["read"] as? Bool != true || payload["matches"] as? Bool != true {
                allMatch = false
            }
            reports.append(payload)
        }
        return (reports, allMatch)
    }

    // MARK: - Rollback

    /// Deletes every track that appeared since `before`, newest number first.
    ///
    /// One at a time, with a two-second gap and Logic frontmost for each:
    /// `Delete Track` fails at its own 8.5 s timeout when Logic is not
    /// frontmost, and when it is fired less than ~2 s after the previous delete
    /// (measured — deleting three tracks as one batch failed on all three).
    private func rollbackImportedTracks(since before: [[String: Any]]) -> [String: Any] {
        let after = trackRows()
        let numbers = ImportMIDI.addedTrackNumbers(before: before, after: after)
        guard !numbers.isEmpty else {
            return ["deleted": [], "note": "Nothing had landed, so nothing had to be removed."]
        }
        var deleted: [String] = []
        var failed: [String] = []
        // Highest number first: deleting the last track never renumbers the
        // ones above it, so the numbers read here stay valid all the way down.
        for (index, number) in numbers.sorted(by: >).enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 2.0) }
            let current = trackRows()
            guard let row = current.first(where: { $0["track_number"] as? Int == number }),
                  let name = row["track_name"] as? String else { continue }
            try? logic.ensureLogicFrontmost(for: "removing the imported track '\(name)'")
            let outcome = try? handleDeleteTrack(["track_name": name, "track_number": number])
            if (outcome as? [String: Any])?["success"] as? Bool == true {
                deleted.append("\(number) '\(name)'")
            } else {
                failed.append("\(number) '\(name)'")
            }
        }
        let restored = ImportMIDI.addedTrackNumbers(before: before, after: trackRows()).isEmpty
        return [
            "deleted": deleted,
            "failed": failed,
            "restored": restored,
            "note": restored
                ? "The tracks the import created were removed; the track census is back where it started."
                : "Could NOT remove every imported track (\(failed.joined(separator: ", ")))."
                    + " Delete them in Logic, or with logic_delete_track."
        ]
    }
}
