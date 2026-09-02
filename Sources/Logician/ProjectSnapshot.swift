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

    /// The sections read through Logic's List Editors pane — the Tempo,
    /// Signature and Marker tabs, one `withListEditorsTab` scope each.
    ///
    /// They are CONTIGUOUS in every scope's emission order (pinned by a test),
    /// which is what lets the handler run all three inside one pane cycle
    /// instead of three: measured 2026-09-02, a cycle costs 765–790 ms with
    /// the pane closed at rest against 383–390 ms with it already open, so the
    /// two cycles this saves on the cold-cache path are −760 ms of a 2.5 s
    /// call. The pane is closed again before `tracks` and `regions` run,
    /// deliberately: it takes its height from the arrangement area, and a
    /// snapshot that read the track list through a shrunken viewport would
    /// report MORE rows missing than the user has.
    static let listEditorTabs: Set<SnapshotSection> = [.tempoMap, .meterMap, .markers]
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

// MARK: - What the sections said about THEMSELVES

/// The half of the completeness contract a list of thrown sections cannot see.
///
/// THE DEFECT THIS CLOSES, reproduced on all 12 snapshot calls of the
/// 2026-09-02 profile. `complete` was `unavailableSections.isEmpty`: it counted
/// only sections whose reader THREW. Every call returned
///
///     "complete": true, "unavailable_sections": [], (no "warning")
///
/// while carrying, inside the same document,
/// `tracks: {"partial": true, "missing_track_numbers": [10…19], …}` and
/// `regions: {"partial": true, …}` — ten track rows and every region on them
/// absent from the document whose one headline promise, in its own description
/// and in the BEFORE/AFTER diff the AGENT-GUIDE prescribes, is that `complete`
/// says whether it is the WHOLE picture. An eval diffing two of them read both
/// as whole projects, and nothing in either said otherwise.
///
/// THE TWO CONDITIONS ARE DIFFERENT AND BOTH STAY VISIBLE. A section that threw
/// read NOTHING and is `{"unavailable": reason}` (`unavailable_sections`). A
/// section that read what Logic renders and can PROVE there is more read
/// something real and is short (`partial_sections`). Neither is allowed to hide
/// behind the other, and either one makes `complete` false.
///
/// And `complete: true` is still not a census: `partial: false` from the
/// Accessibility plane means "nothing proved anything missing", never "this is
/// every track" (see `TrackListCompleteness`). It is the strongest claim this
/// plane can make, which is exactly why it must not be made when the plane
/// already said otherwise.
///
/// Pure: the audit reads section payloads and nothing else, so every rule below
/// is pinned without a DAW.
enum SnapshotCaveats {

    /// One pass over the built sections: what is short, what came out of a
    /// cache, and the words each section used to say so.
    struct Audit: Equatable {
        /// Sections that reported themselves short of the project, sorted.
        let partialSections: [String]
        /// One line per signal, in the section's OWN words, named by section.
        let partialEvidence: [String]
        /// Every track number some section proved exists and could not show.
        let missingTrackNumbers: [Int]
        /// Sections served out of one of this server's caches rather than read
        /// from Logic on this call, sorted.
        let cachedSections: [String]
        /// Their SERVED-FROM-CACHE caveats, named by section, so the top level
        /// carries the words the section carries.
        let cacheCaveats: [String]

        /// True when no section reported itself short.
        var isWhole: Bool { partialSections.isEmpty }
    }

    /// What a cached section says when it carries no caveat of its own — a
    /// route ending in `_cache` is a fact even without the sentence.
    static let unlabelledCacheCaveat = "SERVED FROM CACHE: this section is this server's earlier"
        + " read, not a fresh one, and it carried no caveat of its own."

    static func audit(sections: [String: Any]) -> Audit {
        var partial: [String] = []
        var evidence: [String] = []
        var missing: Set<Int> = []
        var cached: [String] = []
        var caveats: [String] = []
        // Sorted, because this feeds a document that gets diffed: the same set
        // of caveats must serialize the same way however the walk ordered the
        // dictionary.
        for name in sections.keys.sorted() {
            guard let payload = sections[name] as? [String: Any] else { continue }
            // A section that threw is the OTHER condition, and it is already
            // named in `unavailable_sections`. Counting it here too would make
            // one failure look like two.
            guard payload["unavailable"] == nil else { continue }
            let reasons = partialReasons(of: payload)
            if !reasons.isEmpty {
                partial.append(name)
                evidence.append(contentsOf: reasons.map { "\(name): \($0)" })
                missing.formUnion(payload["missing_track_numbers"] as? [Int] ?? [])
            }
            // `read_route` is this server's standing way of saying where an
            // answer came from, and every cache route ends in `_cache`
            // (`tempo_list_cache`, `signature_list_cache`). Matching the
            // convention rather than a list of names means a section that
            // starts caching tomorrow is promoted without touching this.
            if let route = payload["read_route"] as? String, route.hasSuffix("_cache") {
                cached.append(name)
                caveats.append(
                    "\(name) (read_route \(route)): "
                        + ((payload["warning"] as? String) ?? unlabelledCacheCaveat)
                )
            }
        }
        return Audit(
            partialSections: partial,
            partialEvidence: evidence,
            missingTrackNumbers: missing.sorted(),
            cachedSections: cached,
            cacheCaveats: caveats
        )
    }

    /// Every way a section payload says "there is more of this project than
    /// what I am showing you", in the section's own words.
    ///
    /// Three signals, because there are three shapes in this server and all
    /// three are honest reports the top level was throwing away:
    /// `partial` + `partial_evidence` (`logic_list_tracks`,
    /// `logic_list_regions`), `unreadable_rows` (the List Editors census — rows
    /// Logic counted and did not draw), and `truncated` (the `full` scope's
    /// insert/send walk stopping at `max_tracks`, which makes that section a
    /// SAMPLE and says so).
    static func partialReasons(of payload: [String: Any]) -> [String] {
        var reasons: [String] = []
        if payload["partial"] as? Bool == true {
            let sentences = payload["partial_evidence"] as? [String] ?? []
            reasons += sentences.isEmpty
                ? ["reports completeness '\(payload["completeness"] as? String ?? "partial")'"
                    + " without an evidence sentence"]
                : sentences
        }
        if let unread = payload["unreadable_rows"] as? Int, unread > 0 {
            reasons.append(
                (payload["warning"] as? String)
                    ?? "\(unread) row(s) Logic counted could not be read"
            )
        }
        if payload["truncated"] as? Bool == true {
            reasons.append(
                (payload["warning"] as? String)
                    ?? "truncated at max_tracks: this section is a SAMPLE, not the whole project"
            )
        }
        return reasons
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

    /// What the captured sections said about themselves — see
    /// `SnapshotCaveats` for the defect this exists to close.
    var caveats: SnapshotCaveats.Audit { SnapshotCaveats.audit(sections: sections) }

    /// True only when every captured section produced a payload AND none of
    /// them reported itself short of the project. Both halves are required:
    /// a snapshot missing a whole section and a snapshot missing ten track rows
    /// are both "not the whole picture", which is the only thing this field
    /// claims to answer.
    var complete: Bool { unavailableSections.isEmpty && caveats.isWhole }

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
        // ONE resolution of the project document for the whole call, passed to
        // the two map readers and reported at the end. It was resolved 4 times
        // per call (both map caches, the tail, and once more inside every pane
        // cycle), measured 1.2–6.1 ms each and up to 60 ms on a cold process
        // (2026-09-02).
        let projectPath = try? logic.projectDocumentPath()

        /// One section, in its place in the emission order and on the progress
        /// scale. A local function because the three List Editors sections have
        /// to run INSIDE one shared pane scope (`SnapshotSection.listEditorTabs`)
        /// without leaving that order.
        func runSection(_ index: Int, _ section: SnapshotSection) throws {
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
                builder.capture(section) { try self.snapshotTempoMap(projectPath: projectPath) }

            case .meterMap:
                // The transport section already read the control bar's time
                // signature (129 AX reads); the meter cache's cross-check used
                // to read the whole transport AGAIN for that one field —
                // 5.5–9.1 ms warm, 109–132 ms when it was the call's first AX
                // walk (2026-09-02). Handed the value instead.
                let signature = (builder.sections[SnapshotSection.transport.rawValue]
                    as? [String: Any])?["time_signature"] as? String
                builder.capture(section) {
                    try self.snapshotMeterMap(
                        projectPath: projectPath, liveSignature: signature
                    )
                }

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

        var index = 0
        while index < scope.sections.count {
            let section = scope.sections[index]
            guard SnapshotSection.listEditorTabs.contains(section) else {
                try runSection(index, section)
                index += 1
                continue
            }
            // The contiguous run of List Editors sections, read inside ONE
            // pane cycle instead of one each — see `listEditorTabs`.
            var run = [section]
            var next = index + 1
            while next < scope.sections.count,
                  SnapshotSection.listEditorTabs.contains(scope.sections[next]) {
                run.append(scope.sections[next])
                next += 1
            }
            try logic.withListEditorsPaneHeld {
                for (offset, held) in run.enumerated() { try runSection(index + offset, held) }
            }
            index = next
        }
        reportProgress("snapshot complete (\(scope.sections.count) sections)", percent: 100)

        let caveats = builder.caveats
        var result: [String: Any] = [
            "success": true,
            // `verified` is about the READS: false as soon as a section was
            // served out of one of this server's caches instead of out of Logic
            // on this call — logic_list_signatures' rule, in the same words,
            // for the tool that embeds its map. It is INDEPENDENT of
            // `complete`, which is the field that says whether the document is
            // the WHOLE picture: a fresh read of a collapsed track stack is
            // verified and incomplete, and a cached meter map on a fully
            // rendered project is complete and unverified.
            "verified": caveats.cachedSections.isEmpty,
            "state": "snapshot",
            "scope": scope.rawValue,
            "complete": builder.complete,
            "sections": scope.sections.map(\.rawValue),
            // The two ways this document can fall short, side by side and never
            // merged: an `unavailable` section read NOTHING, a `partial` one
            // read what Logic renders and proved there is more.
            "unavailable_sections": builder.sortedUnavailable,
            "partial_sections": caveats.partialSections,
            "cached_sections": caveats.cachedSections,
            "project_path": projectPath ?? NSNull()
        ]
        // Omitted rather than empty, the way logic_list_tracks and
        // logic_list_regions omit it: these are numbers that provably exist.
        if !caveats.missingTrackNumbers.isEmpty {
            result["missing_track_numbers"] = caveats.missingTrackNumbers
        }
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
            + " {\"unavailable\": reason}, never a missing key. `complete` is false whenever"
            + " a section failed (`unavailable_sections`) OR a section that DID read reports"
            + " itself short of the project (`partial_sections`, with the track numbers in"
            + " `missing_track_numbers`) — and `complete: true` still means 'nothing proved"
            + " anything missing', never a census, because an unrendered row publishes"
            + " nothing. `cached_sections` names any section served from this server's cache"
            + " rather than read from Logic (that is what `verified: false` means here)."
            + " Arrays are in a fixed order and keys are serialized sorted, so two snapshots"
            + " of the same project diff cleanly; `timing_ms` is the one nondeterministic"
            + " block — drop it before diffing."
        if !builder.sortedUnavailable.isEmpty {
            appendWarning(
                "This snapshot is INCOMPLETE: \(builder.sortedUnavailable.joined(separator: ", "))"
                    + " could not be read. Do not treat an unavailable section as an empty one —"
                    + " each carries the reason it failed.",
                to: &result
            )
        }
        // The promotion D1 was about: a section's own honest partiality report
        // is the top level's problem, because the RESULT CONTRACT tells agents
        // to read `warning` first and the documented use of this tool is to
        // diff two of these documents as whole projects.
        if !caveats.partialSections.isEmpty {
            var text = "This snapshot is NOT the whole project: "
                + caveats.partialSections.joined(separator: ", ")
                + " report themselves PARTIAL"
            if !caveats.missingTrackNumbers.isEmpty {
                text += ", and track number(s) "
                    + caveats.missingTrackNumbers.map(String.init).joined(separator: ", ")
                    + " provably exist and are not in it"
            }
            text += ". " + caveats.partialEvidence.joined(separator: " · ")
                + " A diff of two of these documents compares what Logic had RENDERED, not the"
                + " project — expand the stacks (logic_set_track_stack) or ask the control"
                + " surface (logic_list_strips), which enumerates every strip on or off screen."
            appendWarning(text, to: &result)
        }
        // Each cached section's caveat, verbatim, at the level an agent reads
        // first. It used to sit one level down while the top said
        // `verified: true` and warned nothing (9 of 12 calls, 2026-09-02).
        for caveat in caveats.cacheCaveats { appendWarning(caveat, to: &result) }
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
    ///
    /// It also reports the route and the cross-check verdict, which this
    /// section used to COMPUTE and then drop: `resolveTempoMap` hands back
    /// `liveCrossChecked`, and a snapshot that said nothing about it could not
    /// tell whether the control-bar cross-check ran, passed, or never ran. The
    /// rule and the words are `logic_tempo_events`': a cache hit the control bar
    /// could vouch for is `tempo_list` (the route names what the answer is
    /// worth, not which bytes it came from), and a cache hit it could NOT be
    /// asked about — a non-English Logic UI, mainly — is `tempo_list_cache`,
    /// `live_cross_checked: false` and the caveat.
    private func snapshotTempoMap(projectPath: String? = nil) throws -> [String: Any] {
        let resolved = resolveTempoMap(projectPath: projectPath)
        guard let map = resolved.map, map.source == .tempoList else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Tempo List",
                exposed: resolved.failure?.reason ?? "the Tempo tab published no rows"
            )
        }
        var block: [String: Any] = [
            "source": "tempo_list",
            "read_route": resolved.liveCrossChecked ? "tempo_list" : "tempo_list_cache",
            "live_cross_checked": resolved.liveCrossChecked,
            "events": map.events.map { event -> [String: Any] in
                ["bar": event.bar, "beat": event.beatInBar, "bpm": event.bpm]
            },
            "event_count": map.events.count,
            "tempos": map.tempos,
            "constant": map.isConstant,
            "sub_beat_positions": map.subBeatPositions
        ]
        if !resolved.liveCrossChecked { block["warning"] = MCPServer.tempoCacheWarning }
        return block
    }

    /// The meter map as a snapshot block, straight off `MeterKnowledge` —
    /// whose payload already distinguishes "read" from "not read", which is
    /// exactly the distinction this section turns into availability.
    private func snapshotMeterMap(
        projectPath: String? = nil, liveSignature: String? = nil
    ) throws -> [String: Any] {
        let knowledge = resolveMeterKnowledge(
            projectPath: projectPath, liveSignature: liveSignature
        )
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
        guard let markers = read.markers, let census = read.census else {
            throw LogicianError.trackNotExposed(
                requested: "Logic's Marker List",
                exposed: read.failure?.reason ?? "the Marker tab published no table"
            )
        }
        var block: [String: Any] = [
            "markers": markers,
            // Logic's own count, so a snapshot never reports a marker list one
            // row short of itself (`ListEditorCensus`).
            "marker_count": census.count,
            "columns": read.columns
        ]
        if !census.isComplete {
            block["markers_read"] = markers.count
            block["unreadable_rows"] = census.unread
            block["warning"] = census.unreadNote
        }
        return block
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
