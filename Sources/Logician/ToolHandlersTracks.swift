import Foundation

// Tracks, track stacks, selection and regions.
extension MCPServer {
    func handleListTracks(_ arguments: [String: Any]) throws -> Any {
        return try logic.listTracks()
    }

    func handleCreateTrack(_ arguments: [String: Any]) throws -> Any {
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
        return [
            "success": created,
            "verified": created,
            "type": kind,
            "dialog_answered": answered,
            "tracks_before": before,
            "tracks_after": after.count,
            "tracks": after.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] },
            "note": created ? "Track created." : "No new track appeared; a dialog may need attention."
        ]
    }

    func handleRenameTrack(_ arguments: [String: Any]) throws -> Any {
        return try logic.renameTrack(
            trackName: requiredString("track_name", in: arguments),
            newName: requiredString("new_name", in: arguments)
        )
    }

    func handleDuplicateTrack(_ arguments: [String: Any]) throws -> Any {
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
        return [
            "success": duplicated, "verified": duplicated,
            "state": duplicated ? "duplicated" : "failed",
            "track": dupTrack,
            "tracks_after": dupAfter.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] }
        ]
    }

    func handleDeleteTrack(_ arguments: [String: Any]) throws -> Any {
        let delTrack = try requiredString("track_name", in: arguments)
        _ = try logic.selectTrack(trackName: delTrack, trackNumber: arguments["track_number"] as? Int, expectedProjectPath: nil)
        // DESTRUCTIVE: re-verify that the selected track really is the
        // requested one right before firing.
        let delList = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
        guard let selected = delList.first(where: { $0["selected"] as? Bool == true }),
              (selected["track_name"] as? String)?.caseInsensitiveCompare(delTrack) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "'\(delTrack)' selected before Delete Track",
                actual: "the selection shows a different track; refusing",
                restored: true
            )
        }
        let delCommand = try MCUController.resolveKeyCommand(named: "Delete Track", logic: logic)
        _ = try MCUController.triggerKeyCommand(note: delCommand.note, channel: delCommand.channel)

        // A track that still holds REGIONS raises a modal confirmation
        // (measured 2026-08-28). It swallows the key-command plane while it
        // stands, so it is answered here rather than left for a human: Delete
        // only when the alert is the one we know AND the selection still names
        // the requested track, Cancel otherwise.
        var confirmation: [String: Any]?
        if let alert = logic.trackDeletionAlert() {
            let texts = logic.alertTexts(alert)
            let selectionStillMatches = logic.selectedTrackName()
                .map { $0.caseInsensitiveCompare(delTrack) == .orderedSame } ?? true
            let answer = TrackDeletionAlert.answer(
                texts: texts, selectionMatches: selectionStillMatches
            )
            let answered = logic.answerTrackDeletionAlert(alert, answer)
            confirmation = [
                "texts": texts, "answered": answer.rawValue, "dismissed": answered
            ]
            if answer == .cancel {
                throw LogicianError.verificationFailed(
                    requested: "deleting '\(delTrack)'",
                    actual: "Logic asked '\(texts.first ?? "an unrecognised alert")' and the"
                        + " selection could no longer be confirmed as '\(delTrack)', so the alert"
                        + " was CANCELLED and nothing was deleted",
                    restored: true
                )
            }
        }
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
        var result: [String: Any] = [
            "success": deleted, "verified": deleted,
            "state": deleted ? "deleted" : "failed",
            "track": delTrack,
            "note": deleted
                ? "Undo restores the track."
                : "The track is still listed. Nothing here left a dialog up - a confirmation, if"
                    + " one appeared, is reported in `confirmation`.",
            "tracks_after": delAfter.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] }
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
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }

    func handleListRegions(_ arguments: [String: Any]) throws -> Any {
        return try logic.listRegions(
            trackName: arguments["track_name"] as? String
        )
    }

    func handleSelectRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.selectRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            exclusive: arguments["exclusive"] as? Bool ?? true
        )
    }

    func handleDeleteRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.deleteRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int
        )
    }

    func handleRemoveSilence(_ arguments: [String: Any]) throws -> Any {
        return try logic.removeSilence(
            trackName: try requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            apply: (arguments["apply"] as? Bool) ?? false
        )
    }

    func handleSelectRegions(_ arguments: [String: Any]) throws -> Any {
        return try logic.selectRegions(
            mode: try requiredString("mode", in: arguments),
            trackName: arguments["track_name"] as? String,
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int
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
            notesCrossing: (arguments["notes_crossing"] as? String) ?? "split"
        )
    }

    func handleMoveRegion(_ arguments: [String: Any]) throws -> Any {
        return try logic.moveRegion(
            trackName: requiredString("track_name", in: arguments),
            regionName: arguments["region_name"] as? String,
            startBar: arguments["start_bar"] as? Int,
            byBars: arguments["by_bars"] as? Int ?? 0,
            byBeats: arguments["by_beats"] as? Int ?? 0
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
            move: arguments["move"] as? Bool ?? false
        )
    }
}
