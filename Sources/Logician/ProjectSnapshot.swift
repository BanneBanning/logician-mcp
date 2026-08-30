import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// The truth document: one call that aggregates the existing readers into a
// structured, diffable picture of the project.
//
// Nothing here reaches into Logic on its own. Every section calls the SAME
// function the individual tool calls — `getTransport`, `resolveTempoMap`,
// `resolveMeterKnowledge`, `readMarkerList`, `listTracks`, `listRegions`,
// `MCUController.listStrips` / `mixerSnapshot` / `pluginInsertNames` /
// `readSends` — so a fix in any of them lands here too and there is no second
// implementation to drift.
//
// What IS new is the completeness contract. Ten readers called in sequence on
// a live UI will not all succeed every time, and a snapshot that quietly omits
// the section that failed is worse than no snapshot: an eval diffing two of
// them would read a missing section as "the project has no markers" rather
// than "the Marker List did not open". So every section is present in every
// result, a failed one as `{"unavailable": reason}`, and the top level carries
// `complete`.

/// One block of the snapshot. The raw values are the result keys, and the
/// declaration order here is the EMISSION order — see `SnapshotScope.sections`.
enum SnapshotSection: String, CaseIterable {
    case transport
    case tempoMap = "tempo_map"
    case meterMap = "meter_map"
    case markers
    case tracks
    case regions
    case strips
    case mixer
    case inserts
    case sends

    /// The shape a section that could not be read comes back as. A single
    /// key, always the same one, so a consumer can test for it without
    /// knowing which reader failed.
    static func unavailable(_ reason: String) -> [String: Any] {
        ["unavailable": reason]
    }
}

/// How much of the project to walk. Cost, not capability: each level is a
/// strict superset of the one before it.
enum SnapshotScope: String, CaseIterable {
    /// Accessibility only: transport, both maps, markers, tracks, regions.
    /// The control surface is never touched, so no bank moves.
    case structure
    /// Adds the control-surface census and the mixer snapshot — two bank
    /// walks, the expensive part of any snapshot.
    case mix
    /// Adds per-track inserts and sends, one strip selection each.
    case full

    static func parse(_ raw: String?) throws -> SnapshotScope {
        guard let raw else { return .structure }
        guard let scope = SnapshotScope(rawValue: raw) else {
            throw LogicianError.invalidArguments(
                "scope must be one of: "
                    + SnapshotScope.allCases.map(\.rawValue).joined(separator: ", ")
                    + " (got '\(raw)'). Nothing was read."
            )
        }
        return scope
    }

    /// The sections this scope emits, in a fixed order. Deterministic on
    /// purpose: these documents get diffed against each other.
    var sections: [SnapshotSection] {
        let structure: [SnapshotSection] = [
            .transport, .tempoMap, .meterMap, .markers, .tracks, .regions
        ]
        switch self {
        case .structure: return structure
        case .mix: return structure + [.strips, .mixer]
        case .full: return structure + [.strips, .mixer, .inserts, .sends]
        }
    }
}

/// Accumulates sections, their timings and the completeness verdict.
///
/// Pure: it never touches Logic, it only records what a caller's closure
/// produced. That is what makes the completeness rule — the one thing this
/// tool actually promises — testable without a DAW.
struct SnapshotBuilder {
    private(set) var sections: [String: Any] = [:]
    private(set) var timings: [String: Int] = [:]
    private(set) var unavailableSections: [String] = []

    /// Runs `body`, times it, and records either its payload or the reason it
    /// failed. A throwing section is recorded as unavailable — never dropped,
    /// and never allowed to abort the sections after it.
    mutating func capture(
        _ section: SnapshotSection,
        now: () -> Date = Date.init,
        _ body: () throws -> [String: Any]
    ) {
        let started = now()
        do {
            let payload = try body()
            sections[section.rawValue] = payload
        } catch {
            sections[section.rawValue] =
                SnapshotSection.unavailable(error.localizedDescription)
            unavailableSections.append(section.rawValue)
        }
        timings[section.rawValue] = Int(now().timeIntervalSince(started) * 1000)
    }

    /// Records a section whose work was timed by the caller — the two chain
    /// sections, which come out of one shared walk and would otherwise report
    /// the whole walk twice or once and zero.
    mutating func record(_ section: SnapshotSection, payload: [String: Any], milliseconds: Int) {
        sections[section.rawValue] = payload
        timings[section.rawValue] = milliseconds
        if payload["unavailable"] != nil { unavailableSections.append(section.rawValue) }
    }

    /// True only when every captured section produced a payload.
    var complete: Bool { unavailableSections.isEmpty }

    /// The unavailable list, sorted — a set of failures should diff the same
    /// however the walk happened to order them.
    var sortedUnavailable: [String] { unavailableSections.sorted() }
}

// MARK: - The tool

extension MCPServer {

    func handleProjectSnapshot(_ arguments: [String: Any]) throws -> Any {
        let scope = try SnapshotScope.parse(arguments["scope"] as? String)
        let maxTracks = min(max((arguments["max_tracks"] as? Int) ?? 8, 1), 64)
        let started = Date()
        var builder = SnapshotBuilder()

        for (index, section) in scope.sections.enumerated() {
            // Sections are independent captures, so a cancellation between two
            // of them costs nothing: no section is half-read, and the ones
            // already taken are simply discarded with the response.
            try checkCancelled()
            let slot = 100 / Double(scope.sections.count)
            reportProgress(
                "snapshot section \(index + 1)/\(scope.sections.count): \(section.rawValue)",
                percent: Double(index) * slot
            )
            // The `mixer` section is a whole logic_mixer_snapshot, which
            // reports on its own 0…100; give it this section's slice so the two
            // scales do not fight.
            withProgressScope((Double(index) * slot)...(Double(index + 1) * slot)) {
            switch section {
            case .transport:
                builder.capture(section) { try self.logic.getTransport() }

            case .tempoMap:
                builder.capture(section) { try self.snapshotTempoMap() }

            case .meterMap:
                builder.capture(section) { try self.snapshotMeterMap() }

            case .markers:
                builder.capture(section) { try self.snapshotMarkers() }

            case .tracks:
                builder.capture(section) { try self.logic.listTracks() }

            case .regions:
                builder.capture(section) { try self.logic.listRegions(trackName: nil) }

            case .strips:
                builder.capture(section) { try MCUController.listStrips(logic: self.logic) }

            case .mixer:
                builder.capture(section) { try MCUController.mixerSnapshot(logic: self.logic) }

            case .inserts, .sends:
                // Both come out of ONE walk (select the strip, read its
                // inserts, read its sends), so the walk runs on the first of
                // the two and the second reads what it left behind. Doing them
                // as two independent loops would double every strip selection.
                if builder.sections[SnapshotSection.inserts.rawValue] == nil {
                    let walk = self.snapshotChains(
                        limit: maxTracks,
                        census: builder.sections[SnapshotSection.strips.rawValue] as? [String: Any]
                    )
                    builder.record(.inserts, payload: walk.inserts, milliseconds: walk.insertsMs)
                    builder.record(.sends, payload: walk.sends, milliseconds: walk.sendsMs)
                }
            }
            }
        }
        reportProgress("snapshot complete (\(scope.sections.count) sections)", percent: 100)

        var result: [String: Any] = [
            "success": true,
            // The snapshot itself is always a truthful report of what could be
            // read; `complete` — not `verified` — is the field that says
            // whether it is the WHOLE picture.
            "verified": true,
            "state": "snapshot",
            "scope": scope.rawValue,
            "complete": builder.complete,
            "sections": scope.sections.map(\.rawValue),
            "unavailable_sections": builder.sortedUnavailable,
            "project_path": (try? logic.projectDocumentPath()) ?? NSNull()
        ]
        result.merge(builder.sections) { current, _ in current }
        // Timings live under one key so a diff can drop exactly one subtree
        // and compare the rest byte for byte. They are the only nondeterministic
        // thing in the document.
        var timing = builder.timings.mapValues { $0 as Any }
        timing["total"] = Int(Date().timeIntervalSince(started) * 1000)
        result["timing_ms"] = timing
        result["note"] = "Aggregated from the same readers the individual tools use — the"
            + " transport, both list-editor maps, the marker list, the track and region"
            + " walks, and (scope mix/full) the control-surface census and mixer snapshot."
            + " EVERY section named in `sections` is present: a reader that failed is"
            + " {\"unavailable\": reason}, never a missing key, and `complete` is false"
            + " whenever any of them did. Arrays are in a fixed order and keys are"
            + " serialized sorted, so two snapshots of the same project diff cleanly;"
            + " `timing_ms` is the one nondeterministic block — drop it before diffing."
        if !builder.complete {
            appendWarning(
                "This snapshot is INCOMPLETE: \(builder.sortedUnavailable.joined(separator: ", "))"
                    + " could not be read. Do not treat an unavailable section as an empty one —"
                    + " each carries the reason it failed.",
                to: &result
            )
        }
        if scope == .structure {
            result["scope_note"] = "scope 'structure' is Accessibility-only and does not touch"
                + " the control surface: no strip census, no fader values, no bank movement."
                + " Pass scope 'mix' for the mixer, 'full' to add per-track inserts and sends."
        }
        return result
    }

    // MARK: - Sections that need shaping

    /// The tempo map as a snapshot block. Only a map READ from the Tempo List
    /// counts: a `.singleReading` map is the constant-tempo assumption wearing
    /// the type's clothes, and a snapshot that reported it as the project's
    /// tempo map would be inventing a document.
    private func snapshotTempoMap() throws -> [String: Any] {
        let resolved = resolveTempoMap()
        guard let map = resolved.map, map.source == .tempoList else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Tempo List",
                exposed: resolved.failure?.reason ?? "the Tempo tab published no rows"
            )
        }
        return [
            "source": "tempo_list",
            "events": map.events.map { event -> [String: Any] in
                ["bar": event.bar, "beat": event.beatInBar, "bpm": event.bpm]
            },
            "event_count": map.events.count,
            "tempos": map.tempos,
            "constant": map.isConstant,
            "sub_beat_positions": map.subBeatPositions
        ]
    }

    /// The meter map as a snapshot block, straight off `MeterKnowledge` —
    /// whose payload already distinguishes "read" from "not read", which is
    /// exactly the distinction this section turns into availability.
    private func snapshotMeterMap() throws -> [String: Any] {
        let knowledge = resolveMeterKnowledge()
        let payload = knowledge.payload
        guard payload["read"] as? Bool == true else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Signature List",
                exposed: (payload["reason"] as? String) ?? "the Signature tab published no rows"
            )
        }
        return payload
    }

    private func snapshotMarkers() throws -> [String: Any] {
        let read = logic.readMarkerList()
        guard let markers = read.markers else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List",
                exposed: read.failure?.reason ?? "the Marker tab published no table"
            )
        }
        return [
            "markers": markers,
            "marker_count": markers.count,
            "columns": read.columns
        ]
    }

    /// One walk over the addressable tracks reading BOTH the insert chain and
    /// the sends, because both need the same strip selected and a selection is
    /// the expensive part.
    ///
    /// Addressable means: a strip the census resolved to a real track name (or,
    /// with no census, a rendered track header). Strips the census reports as
    /// `unresolved` are deliberately skipped — their only identity is a
    /// 6-character LCD abbreviation, which is not a name any tool may address
    /// a write or a read by.
    private func snapshotChains(
        limit: Int, census: [String: Any]?
    ) -> (inserts: [String: Any], sends: [String: Any], insertsMs: Int, sendsMs: Int) {
        var names: [String] = []
        if let strips = census?["strips"] as? [[String: Any]] {
            names = strips.compactMap { row in
                guard row["kind"] as? String == "track" else { return nil }
                return row["track_name"] as? String
            }
        }
        if names.isEmpty,
           let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]] {
            names = tracks.compactMap { $0["track_name"] as? String }
        }
        let truncated = names.count > limit
        let walked = Array(names.prefix(limit))
        // This walk SELECTS every strip it reads, which is the one way a
        // "snapshot" changes something a user could notice — and it showed up
        // in the live cross-check as regions reading `selected: false` in one
        // document and `true` in the next. Remember where the selection was
        // and put it back, and say whether that worked.
        let selectedBefore = ((try? logic.listTracks())?["tracks"] as? [[String: Any]])?
            .first { $0["selected"] as? Bool == true }?["track_name"] as? String

        var insertRows: [[String: Any]] = []
        var sendRows: [[String: Any]] = []
        // Timed separately rather than split from one total: the selection is
        // charged to the insert read that needs it, which is what a caller
        // deciding whether to pay for scope 'full' wants to see.
        var insertsSeconds = 0.0
        var sendsSeconds = 0.0
        for name in walked {
            var mark = Date()
            do {
                _ = try logic.selectTrack(
                    trackName: name, trackNumber: nil, expectedProjectPath: nil
                )
            } catch {
                let reason = "could not be selected: \(error.localizedDescription)"
                insertRows.append(["track_name": name, "unavailable": reason])
                sendRows.append(["track_name": name, "unavailable": reason])
                insertsSeconds += Date().timeIntervalSince(mark)
                continue
            }
            do {
                guard let inserts = try MCUController.pluginInsertNames() else {
                    throw LogicianError.trackNotExposed(
                        requested: "the MCU insert list",
                        exposed: "the bridge is unavailable or the insert view did not appear"
                    )
                }
                insertRows.append([
                    "track_name": name,
                    "mcu_slots": inserts.enumerated().map { index, plugin in
                        ["slot": index + 1, "plugin": plugin.isEmpty ? MCULCDStrings.emptySlot : plugin]
                    }
                ])
            } catch {
                insertRows.append(["track_name": name, "unavailable": error.localizedDescription])
            }
            MCUController.exitToPan()
            insertsSeconds += Date().timeIntervalSince(mark)
            mark = Date()
            do {
                guard let sends = try MCUController.readSends() else {
                    throw LogicianError.trackNotExposed(
                        requested: "the MCU send view",
                        exposed: "the bridge is unavailable or the send view did not appear"
                    )
                }
                sendRows.append(["track_name": name, "sends": sends])
            } catch {
                sendRows.append(["track_name": name, "unavailable": error.localizedDescription])
            }
            MCUController.exitToPan()
            sendsSeconds += Date().timeIntervalSince(mark)
        }

        // Put the selection back where it was, so a snapshot is as close to
        // selection-neutral as a walk that has to select can be.
        var selectionRestored: Any = NSNull()
        if let selectedBefore, !walked.isEmpty {
            selectionRestored = ((try? logic.selectTrack(
                trackName: selectedBefore, trackNumber: nil, expectedProjectPath: nil
            )) != nil)
        }

        let walkNote = "MCU slot numbers are physical insert positions and can differ from the"
            + " Accessibility ordinals logic_list_inserts reports; never translate between them."
            + " READING THIS SELECTED EVERY TRACK LISTED: the strip has to be selected to be"
            + " read. The track that was selected before is re-selected afterwards"
            + " (selected_before / selection_restored), but region selection and the"
            + " control surface's bank are NOT restored."
        var inserts: [String: Any] = [
            "tracks": insertRows,
            "walked": walked.count,
            "selected_before": selectedBefore.map { $0 as Any } ?? NSNull(),
            "selection_restored": selectionRestored,
            "note": walkNote
        ]
        var sends: [String: Any] = [
            "tracks": sendRows,
            "walked": walked.count,
            "note": "Send slots as the channel view shows them; level in dB, position pre/post."
        ]
        if truncated {
            let truncation = "Only the first \(limit) of \(names.count) addressable tracks were"
                + " walked (max_tracks). This section is a SAMPLE, not the whole project."
            inserts["truncated"] = true
            inserts["addressable_tracks"] = names.count
            appendWarning(truncation, to: &inserts)
            sends["truncated"] = true
            sends["addressable_tracks"] = names.count
            appendWarning(truncation, to: &sends)
        }
        return (inserts, sends, Int(insertsSeconds * 1000), Int(sendsSeconds * 1000))
    }
}
