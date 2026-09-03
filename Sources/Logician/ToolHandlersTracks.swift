import Foundation

// Tracks, track stacks, selection and regions.
extension MCPServer {
    func handleListTracks(_ arguments: [String: Any]) throws -> Any {
        // `success` and `state` are added HERE rather than in `listTracks()`:
        // the reader is called internally (track counts before and after a
        // create, verification passes) and those callers want the rows, not a
        // result envelope. What reaches an agent carries the envelope every
        // other tool has, so "did this call work" is one key everywhere.
        var payload = try logic.listTracks()
        payload["success"] = true
        payload["state"] = "listed"
        return payload
    }

    func handleCreateTrack(_ arguments: [String: Any]) throws -> Any {
        let kind = (arguments["type"] as? String) ?? "software_instrument"
        let commandName = kind == "audio"
            ? KeyCommandRegistry.Name.newAudioTrack
            : KeyCommandRegistry.Name.newSoftwareInstrumentTrack
        // Read before writing, and REFUSE if the read fails: the whole
        // verification is a comparison against this listing, and an
        // unreadable "before" would make the first row seen afterwards look
        // like a track this call created.
        guard let beforePayload = try? logic.listTracks(),
              let beforeTracks = beforePayload["tracks"] as? [[String: Any]] else {
            throw LogicianError.preconditionUnmet(
                "The track list could not be read, so a new track could not be told from an"
                    + " existing one. Nothing was fired. See logic_health."
            )
        }
        let before = TrackChange.rows(beforeTracks)
        let command = try MCUController.resolveKeyCommand(named: commandName, logic: logic)
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)

        // ONE poll, over the thing this tool actually verifies, looking before
        // it sleeps — see `TrackChange.createPollDeadline` for the measurement
        // that replaced the 8.9 s dialog loop that used to stand here. The
        // dialog look rides on the MISS path: when the row is already there
        // (3 of 3 profiled runs, on the first look) nobody pays for the
        // question, and on a Logic version that does prompt it is asked
        // within milliseconds instead of after a fixed sleep.
        var answered = false
        var after: [TrackChange.Row] = []
        var partial = false
        var created = false
        var deadline = Date().addingTimeInterval(TrackChange.createPollDeadline)
        while true {
            let payload = (try? logic.listTracks()) ?? [:]
            after = TrackChange.rows((payload["tracks"] as? [[String: Any]]) ?? [])
            partial = payload["partial"] as? Bool == true
            if TrackChange.trackAppeared(before: before, after: after) { created = true; break }
            if !answered, logic.answerCreateTrackDialog() {
                // A dialog was standing in the way; the track is created after
                // it is answered, so the clock starts again from there.
                answered = true
                deadline = Date().addingTimeInterval(TrackChange.createPollDeadline)
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: TrackChange.createPollInterval)
        }

        var result: [String: Any] = [
            "success": created,
            "verified": created,
            "type": kind,
            "dialog_answered": answered,
            "tracks_before": before.count,
            "tracks_after": after.count,
            "tracks_partial": partial,
            "tracks": after.map { ["track_number": $0.number, "track_name": $0.name] }
        ]
        if created {
            result["state"] = "created"
            // The next call in the documented recipe is logic_load_instrument
            // {track_name}, and without this the agent has to diff two
            // listings or guess Logic's auto-name to get it.
            if let row = TrackChange.createdRow(before: before, after: after) {
                result["created_track"] = ["track_number": row.number, "track_name": row.name]
                result["note"] = kind == "audio"
                    ? "Track created; `created_track` names it. Its INPUT is not set from here —"
                        + " the mic or line input and input monitoring are assigned in Logic by"
                        + " hand before anything can be recorded onto it."
                    : "Track created; `created_track` names it. A software-instrument track is"
                        + " EMPTY — pass that track_name to logic_load_instrument next."
            } else {
                result["note"] = "Track created, but the listing moved in more than one place, so"
                    + " which row is the new one cannot be said from here. Re-read"
                    + " logic_list_tracks before naming it to logic_load_instrument."
            }
        } else {
            switch TrackChange.unseenVerdict(partial: partial, before: before, after: after) {
            case .notVisible:
                result["state"] = "created_not_visible"
                result["warning"] = "This project renders only part of its track list"
                    + " (`partial: true`) and the rendered rows moved without a new name"
                    + " appearing, so a track may have been created outside them."
                result["note"] = "The key command fired and the rendered rows shifted, but they"
                    + " are not all the rows. Scroll the Tracks area and re-read"
                    + " logic_list_tracks before firing this again — a repeat of a create that"
                    + " already worked leaves two tracks behind, and Undo is a blind instrument."
            case .unchanged, .nothing:
                // Same rule as `handleDuplicateTrack`: an unmoved census is a
                // positive observation, and `created_not_visible` may not be
                // claimed over it just because the listing is partial.
                result["state"] = "unchanged"
                let anchor = before.first(where: \.selected)?.number
                let refuted = anchor.map {
                    TrackChange.insertionRefutedBelow(before: before, after: after, number: $0)
                } ?? false
                result["insertion_refuted"] = refuted
                let census = "The \(after.count) rendered track rows read identically before and"
                    + " after this call — same numbers, same names, same order."
                let cause = " Nothing was created. Either the key command did not reach Logic —"
                    + " check logic_health, and answer any dialog Logic is showing — or Logic"
                    + " declined it here."
                if refuted {
                    result["note"] = census + " A new track lands directly BELOW the selected one"
                        + " and renumbers every row under it, and the rows under track"
                        + " \(anchor ?? 0) are rendered and did not renumber." + cause
                } else if !partial {
                    result["note"] = census + " Nothing proved this listing short of the project"
                        + " and it did not move." + cause
                } else {
                    result["warning"] = "This project renders only part of its track list"
                        + " (`partial: true`) and no rendered row sits below the selected one, so"
                        + " a new track below it would not show here."
                    result["note"] = census + " Nothing was inserted anywhere this call can see,"
                        + " which is NOT the same as nothing having happened. Scroll the Tracks"
                        + " area and re-read logic_list_tracks before firing this again — a repeat"
                        + " of a create that already worked leaves two tracks behind."
                }
            }
        }
        // The bank map describes this project's track ORDER — see
        // `invalidateBankMap()`. A create that may have landed invalidates it
        // just as surely as one that provably did; a census that refutes the
        // insertion outright has changed no order, and throwing the map away
        // then costs the next surface call a 1 378 ms rescan for nothing.
        if created
            || result["state"] as? String == "created_not_visible"
            || (result["state"] as? String == "unchanged"
                && result["insertion_refuted"] as? Bool == false) {
            invalidateBankMap()
        }
        return result
    }

    func handleRenameTrack(_ arguments: [String: Any]) throws -> Any {
        let result = try logic.renameTrack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            newName: requiredString("new_name", in: arguments)
        )
        // The bank map's payload IS the surface's LCD name rows, and a rename
        // rewrites one of their cells — so this tool was the only track
        // mutation without an invalidation, and its staleness is the WORST of
        // the four. `bankedAtMatch` (MCUTransportLCD.swift:487) deliberately
        // tolerates exactly one differing cell, which is the press-banner
        // signature; a rename changes exactly one cell. So a lookup of any
        // OTHER track in the renamed strip's bank still passes the fast path
        // off the stale map and the staleness is never discovered — it
        // survives the whole session instead of self-correcting on the next
        // MCU call (confirmed live 2026-09-02: `bank-cache.json` byte- and
        // mtime-identical after five renames while the live LCD cell had
        // changed).
        //
        // Repairing the one cell in place was considered and rejected: the
        // cached cell is Logic's own ABBREVIATION of the name, by a rule this
        // process cannot compute (`RenamedTrk1` painted as `RenmT1`, not a
        // truncation), so the new cell can only be READ — which means banking
        // the surface to that bank, an MCU round-trip that costs more than the
        // rescan it would save and moves a surface this call otherwise never
        // touches. Deleting the file is an unlink, and turns an undetectable
        // wrong map into an absent one — measured cheaper on the create side
        // (11 854 ms with a stale map against 6 796 ms with none).
        let state = result["state"] as? String
        if state == "renamed" || state == "renamed_not_visible" {
            invalidateBankMap()
        }
        return result
    }

    func handleDuplicateTrack(_ arguments: [String: Any]) throws -> Any {
        let dupTrack = try requiredString("track_name", in: arguments)
        // Selecting the source resolves it AND hands back the header rows it
        // walked to do so — this call used to re-read the same tree one line
        // later purely to count it (53–88 ms of an 807 ms call, measured
        // 2026-09-01). Read-before-write still holds: these ARE the rows the
        // key command is about to change, and a selection that cannot be made
        // throws before anything is fired.
        let selection = try logic.selectTrackReportingRows(
            trackName: dupTrack,
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: nil
        )
        let before = selection.rows
        let dupCommand = try MCUController.resolveKeyCommand(
            named: KeyCommandRegistry.Name.duplicateTrack, logic: logic
        )
        _ = try MCUController.triggerKeyCommand(note: dupCommand.note, channel: dupCommand.channel)

        // One poll over the thing this verifies, looking BEFORE it sleeps —
        // see `TrackChange.duplicatePollDeadline`. The old loop slept 300 ms
        // first and then found the row on its first look, 10 times out of 10.
        var after: [TrackChange.Row] = []
        var partial = false
        var duplicated = false
        let deadline = Date().addingTimeInterval(TrackChange.duplicatePollDeadline)
        while true {
            let payload = (try? logic.listTracks()) ?? [:]
            after = TrackChange.rows((payload["tracks"] as? [[String: Any]]) ?? [])
            partial = payload["partial"] as? Bool == true
            if TrackChange.trackAppeared(before: before, after: after) { duplicated = true; break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: TrackChange.duplicatePollInterval)
        }

        var result: [String: Any] = [
            "success": duplicated, "verified": duplicated,
            "track": dupTrack,
            "source_track": [
                "track_number": selection.result["track_number"] ?? 0,
                "track_name": selection.result["track_name"] ?? dupTrack
            ],
            "tracks_before": before.count,
            "tracks_after": after.count,
            "tracks_partial": partial,
            "tracks": after.map { ["track_number": $0.number, "track_name": $0.name] }
        ]
        if duplicated {
            result["state"] = "duplicated"
            // The copy is not addressable from the source's name, in EITHER
            // direction: keep the name and it now matches two rows, so every
            // track tool refuses it as ambiguous; let Logic auto-increment it
            // and the name the caller passed in belongs to a different track.
            // Both were measured live 2026-09-01. Logic selects the copy and
            // the verifying read already carries `selected`, so the answer is
            // free — it is only the saying of it that was missing.
            if let row = TrackChange.createdRow(before: before, after: after) {
                result["duplicate"] = ["track_number": row.number, "track_name": row.name]
                result["note"] = "The COPY is `duplicate` - address it by both of those fields,"
                    + " not by the source's name. Logic gives a copy either the source's own name"
                    + " (which then matches two rows, and every track tool refuses an ambiguous"
                    + " name) or an auto-incremented one (`Audio 9` copies to `Audio 10`)."
            } else {
                result["note"] = "The copy was made, but the listing moved in more than one place,"
                    + " so which row is the copy cannot be said from here. Re-read"
                    + " logic_list_tracks before addressing it - the source's name may now match"
                    + " two rows."
            }
        } else {
            switch TrackChange.unseenVerdict(partial: partial, before: before, after: after) {
            case .notVisible:
                result["state"] = "duplicated_not_visible"
                result["warning"] = "This project renders only part of its track list"
                    + " (`partial: true`) and the rendered rows moved without a new name"
                    + " appearing, so a copy may have landed outside them."
                result["note"] = "The key command fired and the rendered rows shifted, but they"
                    + " are not all the rows. Scroll the Tracks area and re-read"
                    + " logic_list_tracks before firing this again - a repeat of a duplicate that"
                    + " already worked leaves a second copy, carrying a second set of the"
                    + " source's regions, and Undo is a blind instrument."
            case .unchanged, .nothing:
                // The census did not move by one character, so no
                // `duplicated_*` state may be claimed over it - whatever the
                // listing is missing elsewhere. See `TrackChange.Unseen` for
                // the live call this replaces.
                result["state"] = "unchanged"
                let sourceNumber = selection.result["track_number"] as? Int
                let refuted = sourceNumber.map {
                    TrackChange.insertionRefutedBelow(before: before, after: after, number: $0)
                } ?? false
                result["insertion_refuted"] = refuted
                let census = "The \(after.count) rendered track rows read identically before and"
                    + " after this call - same numbers, same names, same order."
                let cause = " Nothing was changed and nothing needs undoing. LOGIC DOES NOT"
                    + " DUPLICATE A TRACK STACK: if the source is the MAIN track of a folder or"
                    + " summing stack (`is_stack: true` in logic_list_tracks) the command is a"
                    + " silent no-op, measured 2026-09-03 - duplicate the subtracks inside it"
                    + " instead, which works normally. Otherwise the key command did not reach"
                    + " Logic: check logic_health, and answer any dialog Logic is showing."
                if refuted {
                    result["note"] = census + " A copy lands directly BELOW its source and"
                        + " renumbers every row under it, and the rows under track"
                        + " \(sourceNumber ?? 0) are rendered and did not renumber, so NO copy was"
                        + " made." + cause
                } else if !partial {
                    result["note"] = census + " Nothing proved this listing short of the project"
                        + " and it did not move, so NO copy was made." + cause
                } else {
                    result["warning"] = "This project renders only part of its track list"
                        + " (`partial: true`) and no rendered row sits below the source, so a copy"
                        + " directly below it would not show here."
                    result["note"] = census + " Nothing was inserted anywhere this call can see,"
                        + " which is NOT the same as nothing having happened: no rendered row sits"
                        + " below the source, so a copy would have landed outside them. Scroll the"
                        + " Tracks area and re-read logic_list_tracks before firing this again - a"
                        + " repeat of a duplicate that already worked leaves a second copy,"
                        + " carrying a second set of the source's regions."
                }
            }
        }
        // The bank map describes this project's track ORDER, and this tool
        // inserts a row in the middle of it and renumbers everything below.
        // A duplicate that may have landed invalidates it as surely as one
        // that provably did - but a census that refutes the insertion outright
        // has changed no order, and throwing the map away then costs the next
        // surface call a 1 378 ms rescan for nothing.
        if duplicated
            || result["state"] as? String == "duplicated_not_visible"
            || (result["state"] as? String == "unchanged"
                && result["insertion_refuted"] as? Bool == false) {
            invalidateBankMap()
        }
        return result
    }

    func handleDeleteTrack(_ arguments: [String: Any]) throws -> Any {
        let delTrack = try requiredString("track_name", in: arguments)
        let selection = try logic.selectTrack(
            trackName: delTrack,
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: nil
        )
        // DESTRUCTIVE: re-verify that the selected track really is the
        // requested one right before firing — by NUMBER as well as by name.
        //
        // The name on its own is not a safety net on the state
        // `logic_duplicate_track` manufactures: a copy that kept the source's
        // name leaves two rows answering to it, and "the selected row is
        // called Crash" is then true of whichever one is selected. What
        // actually protected the ten duplicate-restores of 2026-09-01 was
        // `resolveTrack`'s number/name cross-check (AXTracks.swift:91), and
        // that is only reached when the caller passes `track_number`. So the
        // number `selectTrack` just resolved is carried down here and compared
        // too: it costs a dictionary read and it makes the guard mean what its
        // comment always claimed.
        let delList = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
        let selectedDescription = delList
            .filter { $0["selected"] as? Bool == true }
            .map { "\($0["track_number"] ?? "?"): \($0["track_name"] ?? "?")" }
            .joined(separator: ", ")
        guard let targetNumber = selection["track_number"] as? Int,
              let selected = delList.first(where: { $0["selected"] as? Bool == true }),
              (selected["track_name"] as? String)?.caseInsensitiveCompare(delTrack) == .orderedSame,
              selected["track_number"] as? Int == targetNumber else {
            throw LogicianError.verificationFailed(
                requested: "track \(selection["track_number"] ?? "?") '\(delTrack)' selected before Delete Track",
                actual: "the selection reads '\(selectedDescription.isEmpty ? "none" : selectedDescription)'; refusing",
                restored: true
            )
        }
        let delCommand = try MCUController.resolveKeyCommand(
            named: KeyCommandRegistry.Name.deleteTrack, logic: logic
        )
        _ = try MCUController.triggerKeyCommand(note: delCommand.note, channel: delCommand.channel)

        // ONE poll for both outcomes of the key command: the row going away,
        // and the modal that stands in the way of it going away.
        //
        // A track that still holds REGIONS raises a confirmation (measured
        // 2026-08-28) which swallows the key-command plane while it stands, so
        // it is answered here rather than left for a human: Delete only when
        // the alert is the one we know AND the selection still names the
        // requested track, Cancel otherwise. But a track with no regions
        // raises nothing, and waiting out the alert's whole 2.5 s timeout to
        // prove that cost 2.6 s of a 3.3 s call on 7 of 7 profiled deletes.
        // Asking the same question inside the verification loop prices it at
        // nothing on the common path: the row is gone on the first look and
        // the loop never reaches the alert check, while a delete that has NOT
        // happened yet — the only state a modal could explain — still gets the
        // full deadline of looks.
        let beforeRows = TrackChange.rows(delList)
        var confirmation: [String: Any]?
        var cancelled: [String]?
        var deleted = false
        var afterRows: [TrackChange.Row] = []
        var deadline = Date().addingTimeInterval(TrackChange.deletePollDeadline)
        while true {
            afterRows = TrackChange.rows(((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? [])
            if TrackChange.rowRemoved(before: beforeRows, after: afterRows, name: delTrack) {
                deleted = true; break
            }
            if confirmation == nil, let alert = logic.trackDeletionAlertNow() {
                let texts = logic.alertTexts(alert)
                let selectionStillMatches = logic.selectedTrackName()
                    .map { $0.caseInsensitiveCompare(delTrack) == .orderedSame } ?? true
                let answer = TrackDeletionAlert.answer(
                    texts: texts, selectionMatches: selectionStillMatches
                )
                let dismissed = logic.answerTrackDeletionAlert(alert, answer)
                confirmation = [
                    "texts": texts, "answered": answer.rawValue, "dismissed": dismissed
                ]
                if answer == .cancel { cancelled = texts; break }
                // Answered Delete: the deletion happens after the press, so
                // the clock starts again from there.
                deadline = Date().addingTimeInterval(TrackChange.deletePollDeadline)
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: TrackChange.deletePollInterval)
        }
        if let cancelled {
            throw LogicianError.verificationFailed(
                requested: "deleting '\(delTrack)'",
                actual: "Logic asked '\(cancelled.first ?? "an unrecognised alert")' and the"
                    + " selection could no longer be confirmed as '\(delTrack)', so the alert"
                    + " was CANCELLED and nothing was deleted",
                restored: true
            )
        }
        if deleted { invalidateBankMap() }
        let delAfter = afterRows.map { ["track_number": $0.number, "track_name": $0.name] }
        var result: [String: Any] = [
            "success": deleted, "verified": deleted,
            "state": deleted ? "deleted" : "failed",
            "track": delTrack,
            "note": deleted
                ? "Undo restores the track."
                : "The track is still listed. Nothing here left a dialog up - a confirmation, if"
                    + " one appeared, is reported in `confirmation`.",
            "tracks_after": delAfter
        ]
        if let confirmation { result["confirmation"] = confirmation }
        return result
    }

    func handleSelectTrack(_ arguments: [String: Any]) throws -> Any {
        return try logic.selectTrack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }

    func handleSetTrackStack(_ arguments: [String: Any]) throws -> Any {
        guard let expanded = arguments["expanded"] as? Bool else {
            throw LogicianError.invalidArguments("missing boolean: expanded")
        }
        return try logic.setTrackStack(
            trackName: requiredString("track_name", in: arguments),
            trackNumber: arguments["track_number"] as? Int,
            expanded: expanded,
            allowMouse: arguments["allow_mouse"] as? Bool == true,
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }

    func handleListRegions(_ arguments: [String: Any]) throws -> Any {
        return try logic.listRegions(
            trackName: arguments["track_name"] as? String,
            checkHiddenRows: arguments["check_hidden_rows"] as? Bool ?? false
        )
    }

    func handleDeleteRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.deleteRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleRemoveSilence(_ arguments: [String: Any]) throws -> Any {
        return try logic.removeSilence(
            trackName: try requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            apply: (arguments["apply"] as? Bool) ?? false,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    /// One tool over two implementations: the element-level selection of ONE
    /// region (`mode: "region"`, the default), and Logic's own selection
    /// COMMANDS for a track's worth of them, everything after a point, all, or
    /// none.
    ///
    /// Folded 2026-09-03 (token audit fold #5, `logic_select_region` removed):
    /// two tools advertised 5,648 bytes of `tools/list` to say the same things
    /// about anchors, project-wide scope and counts-see-visible-rows twice.
    /// Both write paths are untouched — `mode` is the whole of the dispatch,
    /// and it defaults to the single-region one, so a call written for the old
    /// tool works under the new name unchanged.
    func handleSelectRegions(_ arguments: [String: Any]) throws -> Any {
        let mode = (arguments["mode"] as? String) ?? "region"
        let exclusive = arguments["exclusive"] as? Bool
        guard mode == "region" else {
            // `exclusive` is the one argument that means nothing to the command
            // modes: each of them selects its anchor exclusively first and then
            // extends, so there is no additive form of "the whole track" to
            // ask for. Refused rather than dropped — a caller who passed it
            // believes their existing selection is being kept.
            guard exclusive == nil else {
                throw LogicianError.invalidArguments(
                    "exclusive belongs to mode 'region', which selects ONE region. Mode '\(mode)'"
                        + " fires Logic's own selection command, which REPLACES the selection"
                        + " (the anchor is selected exclusively first, then extended from)."
                        + " To add one more region to what it selected, call again with"
                        + " mode 'region' and exclusive: false. NOTHING was selected."
                )
            }
            return try logic.selectRegions(
                mode: mode,
                trackName: arguments["track_name"] as? String,
                regionName: arguments["region_name"] as? String,
                startBar: arguments["start_bar"] as? Int,
                trackNumber: try regionTrackNumber(in: arguments)
            )
        }
        return try logic.selectRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            exclusive: exclusive ?? true,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleSplitRegion(_ arguments: [String: Any]) throws -> Any {
        guard let atBar = arguments["at_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: at_bar")
        }
        return try logic.splitRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            atBar: atBar,
            atBeat: arguments["at_beat"] as? Int ?? 1,
            notesCrossing: (arguments["notes_crossing"] as? String) ?? "split",
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleMoveRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.moveRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            byBars: arguments["by_bars"] as? Int ?? 0,
            byBeats: arguments["by_beats"] as? Int ?? 0,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleGetRegionParams(_ arguments: [String: Any]) throws -> Any {
        return try logic.readRegionParameters(
            trackName: arguments["track_name"] as? String,
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            includeQuantizeValues: arguments["include_quantize_values"] as? Bool ?? false,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleSetRegionParams(_ arguments: [String: Any]) throws -> Any {
        let scope = (arguments["scope"] as? String) ?? "region"
        guard scope == "region" || scope == "selection" else {
            throw LogicianError.invalidArguments("scope must be 'region' or 'selection'")
        }
        return try logic.setRegionParameters(
            trackName: arguments["track_name"] as? String,
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            scope: scope,
            arguments: arguments,
            expected: (arguments["expected_current"] as? [String: Any]) ?? [:],
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleRenameRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.renameRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            newName: requiredString("new_name", in: arguments),
            expectedCurrentName: arguments["expected_current_name"] as? String,
            trackNumber: try regionTrackNumber(in: arguments)
        )
    }

    func handleCopyRegion(_ arguments: [String: Any]) throws -> Any {
        guard let toBar = arguments["to_bar"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: to_bar")
        }
        return try logic.copyRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            toBar: toBar,
            toTrack: arguments["to_track"] as? String,
            move: arguments["move"] as? Bool ?? false,
            fromTrackNumber: try regionTrackNumber(in: arguments),
            toTrackNumber: arguments["to_track_number"] as? Int
        )
    }

    func handleTrackInfo(_ arguments: [String: Any]) throws -> Any {
        var names: [String]?
        if let single = arguments["track_name"] as? String { names = [single] }
        if let list = arguments["track_names"] as? [String] { names = list }
        let number = arguments["track_number"] as? Int
        // `track_number` disambiguates ONE name, the way it does everywhere
        // else in the track family. Paired with a list it would have to mean
        // "this number goes with… which of them?", so it is refused instead of
        // answered by guessing.
        if number != nil, (names?.count ?? 0) > 1 {
            throw LogicianError.invalidArguments(
                "track_number disambiguates a single track_name. With track_names, read the rows"
                    + " you want one call at a time (track_name + track_number), or pass all: true"
                    + " and pick by track_number from the result."
            )
        }
        return try logic.trackInfo(
            trackNames: names,
            trackNumber: number,
            all: arguments["all"] as? Bool ?? false
        )
    }

    func handleSetTrackRouting(_ arguments: [String: Any]) throws -> Any {
        return try logic.setTrackRouting(
            trackName: requiredString("track_name", in: arguments),
            output: arguments["output"] as? String,
            input: arguments["input"] as? String,
            group: arguments["group"] as? String,
            expected: (arguments["expected_current"] as? [String: Any]) ?? [:]
        )
    }
}
