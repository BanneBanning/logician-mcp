import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Regions (Tracks-area layout items)

    /// Region elements grouped per track row. Each row is an AXLayoutArea
    /// described 'Track N “Name”'; its AXLayoutItem children are the regions,
    /// with name in AXDescription and musical position in AXHelp
    /// ("Region starts at X bars ... and ends at Y bars ..., MIDI region.").
    func regionRows() throws -> [(number: Int, track: String, regions: [AXUIElement])] {
        // `projectWindow()`, not "the first standard window": Logic's floats
        // and utility windows are standard windows too, and whichever one is
        // first in the list decides what this walk sees. Measured 2026-08-30
        // with `Control Surface Setup` open — it sorted first, the walk found
        // no `Track N “Name”` layout areas under it, and `logic_list_regions`
        // reported a project full of regions as having NO track rows at all.
        // A silently empty arrangement map is the worst possible answer here:
        // it is the same shape as a correct one.
        regionRows(in: try projectWindow())
    }

    /// The same walk against a project window the caller ALREADY resolved.
    /// `listRegions` needs that window a second time for `AXDocument`, and
    /// `projectWindow()` is four window-list reads (measured 2026-09-02:
    /// `AXWindows`, `AXMainWindow`, `AXFocusedWindow`, `AXDocument` were each
    /// read TWICE per call). Resolving it once also removes a latent
    /// disagreement: `projectDocumentPath()` takes the first window carrying a
    /// document, which is a rule `projectWindow()` deliberately refuses (it
    /// excludes the Mixer), so the two could name different projects.
    func regionRows(in window: AXUIElement) -> [(number: Int, track: String, regions: [AXUIElement])] {
        var rows: [(Int, String, [AXUIElement])] = []
        walk(from: window, maximumDepth: AXDepth.trackRegionRow) { element in
            // ROLE FIRST, then the description. Measured 2026-09-02: this walk
            // visits 448 nodes and 22 of them are `AXLayoutArea`, so reading
            // `AXDescription` up front spent 426 reads (0.089 ms each) to
            // discard 95% of them — 25–40 ms of a 118–209 ms warm call, and
            // ×4 on every region WRITE, which walks this four times. The
            // predicate is unchanged; only the order it is evaluated in is.
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea" else {
                return .descend
            }
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            guard description.hasPrefix(LogicUIStrings.Format.trackDescriptionPrefix),
                  description.contains(LogicUIStrings.Format.openQuote) else {
                return .descend
            }
            // The SHARED parse (`TrackRowAddressing.parseRowDescription`), not
            // a second one. This walk used to split on the opening quote and
            // keep the tail, which meant it kept whatever Logic had appended
            // AFTER the closing quote — and Logic appends the row's live state
            // there, so a soloed row read as `Crash, solo` here while
            // `logic_list_tracks` read the same row as `Crash`, and every
            // region tool refused the caller's own reported name with
            // `trackMismatch` (measured live 2026-09-03, see that function).
            //
            // A description this parse cannot read keeps its row: the walk has
            // already proved it is a track layout area, and dropping it would
            // silently shrink the arrangement map — the one answer shaped
            // exactly like a correct one. It keeps the raw description as the
            // name and row 0, which is what this code always did on that
            // branch, and both are visible to the caller as wrong.
            let parsed = TrackRowAddressing.parseRowDescription(description)
            let digits = parsed.map(\.number)
            let name = parsed?.name ?? description
            let regions = children(of: element).filter {
                stringAttribute($0, "AXRoleDescription")
                    == LogicUIStrings.Element.regionRoleDescription
            }
            rows.append((digits ?? 0, name, regions))
            return .skipChildren // region items have no nested rows
        }
        return rows
    }

    /// One region, as the arrangement map reports it.
    ///
    /// `selected` is emitted only when TRUE, the same rule `start_beat` and
    /// `end_beat` already followed. Measured 2026-09-02 on the reference
    /// project: 52 of 54 regions carried `"selected": false`, ~940 B of a
    /// 5 772-byte payload — 17% of the response spent restating the default.
    /// Every consumer in the tree reads it as `as? Bool == true`, so an absent
    /// key and a false one are already the same answer to them.
    ///
    /// `muted` is the ONE field that does not follow that omit-the-default
    /// rule, and it is deliberate: it has three answers, not two (see
    /// `RegionNameAnnotation`), and an absent `muted` would read as "not
    /// muted" to exactly the caller who needs to know it could not be read.
    /// It costs ~14 bytes per region — ~750 B on the reference project's
    /// 54-region, 5.8 kB map — which is the price of the field that stopped
    /// the mute state leaking into the NAME.
    func parseRegion(_ element: AXUIElement) -> [String: Any] {
        // The region's live state is written INTO its description — `Crash`
        // becomes `Crash, muted` the moment it is muted or some other track is
        // soloed — and this used to report that whole string as the name. One
        // soloed track therefore renamed 53 of the reference project's 54
        // regions and every region tool refused the names its own reader had
        // just published (measured 2026-09-03; see `RegionNameAnnotation`).
        let annotated = RegionNameAnnotation.parse(
            stringAttribute(element, kAXDescriptionAttribute as String)
        )
        var entry: [String: Any] = [
            "name": annotated.name,
            RegionNameAnnotation.mutedKey: RegionNameAnnotation.mutedVerdict(annotated)
        ]
        // Any OTHER annotation the table grows is reported the way `selected`
        // is — present only when true — because those have two answers.
        for key in annotated.annotations where key != RegionNameAnnotation.mutedKey {
            entry[key] = true
        }
        if stringAttribute(element, "AXSelected") == "1" { entry["selected"] = true }
        let help = stringAttribute(element, kAXHelpAttribute as String)
        // "Region starts at 9 bars 2 beats and ends at 11 bars , MIDI region."
        // Two independent regexes keep the optional beats simple.
        func capture(_ pattern: String) -> (bar: Int, beat: Int)? {
            guard let range = help.range(of: pattern, options: .regularExpression) else { return nil }
            let segment = String(help[range])
            let parts = segment.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let bar = parts.first else { return nil }
            return (bar, parts.count > 1 ? parts[1] : 1)
        }
        if let start = capture(LogicUIStrings.Format.RegionHelp.startPattern) {
            entry["start_bar"] = start.bar
            if start.beat != 1 { entry["start_beat"] = start.beat }
        }
        if let end = capture(LogicUIStrings.Format.RegionHelp.endPattern) {
            entry["end_bar"] = end.bar
            if end.beat != 1 { entry["end_beat"] = end.beat }
        }
        if let typeRange = help.range(
            of: LogicUIStrings.Format.RegionHelp.typePattern, options: .regularExpression
        ) {
            let segment = String(help[typeRange])
            entry["type"] = segment
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: LogicUIStrings.Format.RegionHelp.typeNoun, with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return entry
    }

    /// Fills in the `type` Logic did not publish, from the one it did.
    ///
    /// WHAT THE HELP SENTENCE ACTUALLY DOES, measured 2026-09-02 with an AXHelp
    /// dump of all 54 regions on the reference project while exactly 2 were
    /// selected: **all 54 carried the `, MIDI region` / `, Audio region` tail**,
    /// and a selected and an unselected region published the same attribute set
    /// and the same help shape. The profile's reading — that Logic gates the
    /// tail on selection, because the 2 typed regions were exactly the 2
    /// selected ones — is therefore DISPROVED; that correlation was a
    /// coincidence of one sample.
    ///
    /// What is NOT disproved is that the field goes missing: the same tool on
    /// the same project hours earlier the same day returned `type` on 2 of 54,
    /// with `start_bar`/`end_bar` parsing on all of them, so Logic can be caught
    /// publishing the position half of that sentence without the type half. No
    /// other attribute on the region says what kind it is (`AXSubrole` is
    /// absent, `AXRoleDescription` is the flat word `Region`, the children are a
    /// text field and three drag handles), and the only selection-independent
    /// source left is the inspector channel strip at ~0.7 s PER TRACK — six
    /// times the whole call. So the repair is the free one below, plus a
    /// description that stops promising a type for every region.
    ///
    /// A track row holds ONE kind of region — an audio track cannot hold a MIDI
    /// region and a software instrument cannot hold an audio one — so a single
    /// typed region names the type of every region on its row, at no extra AX
    /// read. Rows where Logic published no type at all still carry none, and
    /// `regionMapNote` says what that absence means rather than letting it read
    /// as "not a MIDI region".
    ///
    /// A row that somehow reports two different types is left exactly as it was:
    /// a guess that contradicts the evidence is worse than no answer.
    static func typedRowRegions(_ regions: [[String: Any]]) -> [[String: Any]] {
        let observed = Set(regions.compactMap { $0["type"] as? String })
        guard observed.count == 1, let rowType = observed.first else { return regions }
        return regions.map { region in
            guard region["type"] == nil else { return region }
            var filled = region
            filled["type"] = rowType
            // Say where it came from. The row's OWN help sentence is Logic's
            // word; this one is an inference off a sibling, and a caller about
            // to refuse a destructive edit on the strength of it should be able
            // to tell the two apart.
            filled["type_from"] = "track_row"
            return filled
        }
    }

    /// What a walk that found NO track rows actually means. Pure, so all three
    /// outcomes can be pinned by tests: the previous code returned
    /// `{"tracks": []}` for every one of them, and on a French Logic (R4,
    /// measured 2026-08-30) a 26-track project read as an empty arrangement —
    /// a silently wrong answer with the same shape as a correct one, which is
    /// the one failure mode this server exists to prevent.
    ///
    /// The discriminator is the track HEADER column, read independently of the
    /// row walk: headers that cannot be found mean the whole Tracks area is
    /// unreadable (a localized `AXDescription`, or no project window), and
    /// headers that exist while the walk saw nothing mean the walk itself is
    /// blind. Only a header column that answers "zero tracks" proves empty.
    enum EmptyArrangementVerdict: Equatable {
        /// The header column answered and holds no tracks: genuinely empty.
        case genuinelyEmpty
        /// The header column could not be read at all — empty vs unreadable
        /// cannot be told apart, so nothing may be reported as empty.
        case headerUnreadable
        /// Track headers exist, so the arrangement is NOT empty; the row walk
        /// found none of them.
        case rowsUnreadable(headerCount: Int)
    }

    static func emptyArrangementVerdict(headerItemCount: Int?) -> EmptyArrangementVerdict {
        guard let headerItemCount else { return .headerUnreadable }
        return headerItemCount == 0 ? .genuinelyEmpty : .rowsUnreadable(headerCount: headerItemCount)
    }

    /// How much of the project the arrangement map is, said in fields rather
    /// than in a footnote.
    ///
    /// `logic_list_regions` used to return `project_document`, `tracks` and a
    /// 165-byte static `note` — while `logic_list_tracks`, called seconds later
    /// on the same 19 rendered rows, reported `partial: true` and
    /// `missing_track_numbers: [10…19]`. The two tools agreed exactly on the
    /// rows and only one of them said the other ten existed: the COVERAGE U1
    /// honesty failure `TrackListCompleteness` was written to end, still
    /// standing on the region path.
    ///
    /// The numbering rule costs NOTHING — `regionRows()` already returns the
    /// row numbers — so it runs on every call. The other two signals (collapsed
    /// stacks, a scrollable Tracks area) need the track HEADER column, measured
    /// 2026-09-02 at +40–50 ms on a 95–120 ms warm call, so they are opt-in
    /// (`check_hidden_rows`) and the result says which of the two it paid for.
    ///
    /// Pure, so both branches can be pinned without Logic running.
    struct RegionMapCoverage: Equatable {
        /// True only on POSITIVE evidence that rows exist which this map does
        /// not describe.
        let partial: Bool
        /// `"partial"` or `"unknown"`, never `"complete"` — same rule, and same
        /// reason, as `TrackListCompleteness`.
        var completeness: String { partial ? "partial" : "unknown" }
        /// One sentence per signal.
        let evidence: [String]
        /// Track numbers that provably exist and whose regions are not here.
        let missingTrackNumbers: [Int]
        /// What was actually READ to reach this verdict, so a caller can tell a
        /// cheap verdict from a thorough one.
        let checked: String
    }

    /// - Parameters:
    ///   - rowNumbers: the track numbers of the rendered region rows.
    ///   - headerColumn: the track-header column's own coverage verdict, or nil
    ///     when this call did not pay the +40–50 ms to read it.
    static func regionMapCoverage(
        rowNumbers: [Int], headerColumn: RegionEditGuard.Coverage?
    ) -> RegionMapCoverage {
        let numbering = TrackListCompleteness.numbering(
            rowNumbers: rowNumbers, rowNoun: "region row"
        )
        guard let headerColumn else {
            return RegionMapCoverage(
                partial: numbering.partial,
                evidence: numbering.evidence,
                missingTrackNumbers: numbering.missingTrackNumbers,
                checked: "row_numbering"
            )
        }
        var evidence = numbering.evidence
        for reason in headerColumn.reasons where !evidence.contains(reason) {
            evidence.append(reason)
        }
        return RegionMapCoverage(
            partial: numbering.partial || headerColumn.partial,
            evidence: evidence,
            missingTrackNumbers: Array(
                Set(numbering.missingTrackNumbers).union(headerColumn.unseenTrackNumbers)
            ).sorted(),
            checked: "row_numbering+track_header_column"
        )
    }

    /// The sentence the arrangement map always carries. It has to say three
    /// things an agent must not forget: what `partial` does and does not mean,
    /// which fields are omitted at their default rather than absent, and — when
    /// the header column was not read — that the cheap verdict is the weaker of
    /// the two.
    static func regionMapNote(headerColumnChecked: Bool) -> String {
        var note =
            "Only regions on track rows Logic has RENDERED are listed. partial: true means rows"
            + " are provably missing (partial_evidence, missing_track_numbers); partial: false"
            + " means nothing proved any missing — never a census, because an unrendered row"
            + " publishes nothing at all."
        if !headerColumnChecked {
            note += " coverage_checked here is the row NUMBERING alone; collapsed stacks and a"
                + " scrolled Tracks area hide rows without leaving a gap in it — pass"
                + " check_hidden_rows: true to read the track header column too (+40–50 ms)."
        }
        note += " name is the region's OWN name: Logic writes its live state into the same"
            + " string (a muted region, or ANY region while another track is soloed, publishes"
            + " '<name>, muted'), and that state is reported beside it as muted rather than left"
            + " in the name. muted: true covers both causes - the element does not say which -"
            + " and \"unavailable\" means the name ends in a ', …' this build cannot read as a"
            + " state word (a localized Logic, or a region genuinely named with a comma), never"
            + " that it is unmuted. Both spellings of a name are still accepted as region_name."
            + " Bars/beats are Logic's own help text; start_beat/end_beat are omitted on the"
            + " barline, selected when false. type comes from that same help text and is NOT"
            + " guaranteed (all 54 regions of the reference project on 2026-09-02, 2 of the same"
            + " 54 hours earlier): one typed region types its row (type_from: \"track_row\"), and"
            + " an absent type means UNKNOWN, never 'not audio' — logic_select_regions or"
            + " logic_describe_tracks answers it."
        return note
    }

    /// The arrangement map: every region on every visible track, with bar
    /// positions and type parsed from the element's help text.
    ///
    /// `checkHiddenRows` buys the second half of the completeness verdict — see
    /// `regionMapCoverage`. The first half is always paid for because it is
    /// free.
    func listRegions(trackName: String?, checkHiddenRows: Bool = false) throws -> [String: Any] {
        // One window resolution for the walk AND the document path, instead of
        // the two `projectWindow()`/`projectDocumentPath()` each did.
        let window = try projectWindow()
        let rows = regionRows(in: window)
        if rows.isEmpty {
            let headerCount = (try? trackHeaderItems())?.count
            switch LogicAccessibility.emptyArrangementVerdict(headerItemCount: headerCount) {
            case .genuinelyEmpty:
                break // zero tracks is a real answer, reported below as such
            case .headerUnreadable:
                throw LogicianError.trackNotExposed(
                    requested: "the arrangement's track rows",
                    exposed: "no 'Track N' layout areas AND the Tracks header group could not be"
                        + " found — the Tracks area is UNREADABLE, not empty (a non-English Logic"
                        + " UI localizes both descriptions; logic_health reports the UI language)."
                        + " Refusing to report an unreadable arrangement as an empty one"
                )
            case .rowsUnreadable(let headerCount):
                throw LogicianError.trackNotExposed(
                    requested: "the arrangement's track rows",
                    exposed: "\(headerCount) track header(s) are visible but the arrangement walk"
                        + " found no track rows — the region map is unreadable, not empty"
                )
            }
        }
        var tracks: [[String: Any]] = []
        for row in rows {
            if let filter = trackName,
               row.track.caseInsensitiveCompare(filter) != .orderedSame { continue }
            tracks.append([
                "track_number": row.number,
                "track_name": row.track,
                "regions": LogicAccessibility.typedRowRegions(row.regions.map(parseRegion))
            ])
        }
        if let filter = trackName, tracks.isEmpty {
            throw LogicianError.trackNotExposed(
                requested: "regions on '\(filter)'",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        // The completeness verdict is computed over ALL rendered rows, never
        // over the filtered slice: "which rows can this walk not see" is a
        // question about the arrangement, not about what the caller asked for.
        let coverage = LogicAccessibility.regionMapCoverage(
            rowNumbers: rows.map(\.number),
            headerColumn: checkHiddenRows
                ? regionRowCoverage(regionRowNumbers: rows.map(\.number))
                : nil
        )
        var result: [String: Any] = [
            "project_document": documentPath(of: window) ?? NSNull(),
            "tracks": tracks,
            "partial": coverage.partial,
            "completeness": coverage.completeness,
            "partial_evidence": coverage.evidence,
            "coverage_checked": coverage.checked,
            "note": LogicAccessibility.regionMapNote(headerColumnChecked: checkHiddenRows)
        ]
        if !coverage.missingTrackNumbers.isEmpty {
            result["missing_track_numbers"] = coverage.missingTrackNumbers
        }
        return result
    }

    /// The arrangement row a region call is addressed to.
    ///
    /// One resolution for every region tool, applying the SAME rule
    /// `resolveTrack` applies to the track-header column
    /// (`TrackRowAddressing`): a `track_number` given together with a
    /// `track_name` is cross-checked and a pair that disagrees refuses before
    /// anything is written, and a name that matches several rendered rows is
    /// ambiguous rather than answered by the first one.
    ///
    /// That last part is a behaviour CHANGE, and a deliberate one. These tools
    /// took `rows.first(where:)` on the name, which is a silent guess exactly
    /// where the project makes duplicate names normal: `logic_import_midi`
    /// leaves a row called `Studio Grand` behind for every unrouted track it
    /// imports, and a delete addressed by name alone would have picked
    /// whichever of them Logic rendered first.
    func resolveRegionRow(
        _ rows: [(number: Int, track: String, regions: [AXUIElement])],
        trackName: String, trackNumber: Int?
    ) throws -> (number: Int, track: String, regions: [AXUIElement]) {
        let summary = TrackRowAddressing.rowSummary(
            rows.map { TrackRowAddressing.Row(number: $0.number, name: $0.track) }
        )
        let verdict = TrackRowAddressing.resolve(
            rows: rows.map { TrackRowAddressing.Row(number: $0.number, name: $0.track) },
            name: trackName, number: trackNumber, caseInsensitive: true
        )
        switch verdict {
        case .resolved(let number):
            guard let row = rows.first(where: { $0.number == number }) else {
                throw LogicianError.trackNotExposed(
                    requested: "track row \(number) ('\(trackName)')",
                    exposed: "visible track rows: " + summary
                )
            }
            return row
        case .numberNotFound(let missing):
            throw LogicianError.trackNotExposed(
                requested: "track row \(missing) ('\(trackName)')",
                exposed: "visible track rows: " + summary
                    + ". A row Logic has not rendered publishes no regions at all"
            )
        case .nameNotFound:
            throw LogicianError.trackNotExposed(
                requested: "track '\(trackName)'",
                exposed: "visible track rows: " + summary
            )
        case .ambiguous(let numbers):
            throw LogicianError.trackAmbiguous(trackName, numbers: numbers)
        case .mismatch(let number, let expected, let actual):
            throw LogicianError.trackMismatch(number: number, expected: expected, actual: actual)
        }
    }

    /// Selects one region, identified by track + name and/or start bar.
    /// exclusive (default) first clears every other selected region so the
    /// following edit operation (cut/copy/nudge…) touches ONLY this one.
    ///
    /// `trackNumber`, when given, addresses the ROW rather than the name. Two
    /// tracks can share a name — and a MIDI import makes that likely, because
    /// Logic names the tracks it creates after whichever default patch it
    /// loaded and a project can already hold a `Studio Grand`. Addressing the
    /// row by number is what keeps `logic_import_midi`'s routing cutting from
    /// the track it just created rather than from a namesake.
    ///
    /// `forKeyCommand` is the one-word difference between "select this region"
    /// and "select this region because a key command is about to act on it":
    /// it establishes Logic's Tracks-area keyboard focus first (see
    /// `TracksAreaFocus`, measured 2026-09-01 — without it Cut/Copy/Paste/
    /// Nudge/Delete/Select-All fire and do nothing at all, silently). It is
    /// off by default because the repair WRITES to the track header column,
    /// which the read-only region paths (the Region inspector, the Event List)
    /// have no reason to pay for.
    ///
    /// A region that is ALREADY selected is a verified no-op: nothing is
    /// written to it, `state` reads `already_selected`, and the `exclusive:`
    /// contract is still honoured (the siblings are cleared either way). See
    /// `regionSelectionPlan` for why that read has to come first.
    ///
    /// `exclusive: false` ADDS the region to the selection and says so with
    /// `selected_before`/`selected_count` counted off the rendered rows. It
    /// only works because the keyboard-focus write is skipped on that path —
    /// see `regionSelectionPlan` for the measurement — and it is verified,
    /// not assumed: a selection that came back SHORT is a `warning` naming
    /// what was lost and pointing at `logic_select_regions`.
    /// `alreadyWalkedRows` reuses an arrangement walk the caller has just
    /// taken (`arrangementCensus().rows`) instead of taking a second one — worth
    /// 55-60 ms of the 386 ms `logic_move_region` spent walking one tree six
    /// times, and sound ONLY while nothing has been written since that walk: a
    /// write republishes the layout items, which is the staleness the
    /// read-before-write fix in this file was dodging. Default nil = walk fresh.
    func selectRegion(
        trackName: String, regionName: String?, startBar: Int?, exclusive: Bool,
        trackNumber: Int? = nil, forKeyCommand: Bool = false,
        alreadyWalkedRows: [(number: Int, track: String, regions: [AXUIElement])]? = nil
    ) throws -> [String: Any] {
        guard regionName != nil || startBar != nil else {
            throw LogicianError.invalidArguments("pass region_name and/or start_bar")
        }
        let rows = try alreadyWalkedRows ?? regionRows()
        let row = try resolveRegionRow(rows, trackName: trackName, trackNumber: trackNumber)
        let annotated = row.regions.map { ($0, parseRegion($0)) }
        let hits = annotated.filter { _, info in
            // BOTH spellings of the name, the clean one and the `, muted` one
            // this server used to publish — see `RegionNameAnnotation.matches`.
            if let name = regionName,
               !RegionNameAnnotation.matches(
                   name: (info["name"] as? String) ?? "", request: name
               ) {
                return false
            }
            if let bar = startBar, info["start_bar"] as? Int != bar { return false }
            return true
        }
        // Two different answers, and they used to be one: NO region matching
        // the request is a not-found, and SEVERAL is an ambiguity. The single
        // `parameterAmbiguous` that covered both said "Accessible plugin
        // parameter is ambiguous: … matched 0 controls" at an agent that had
        // named a region on a track.
        guard let hit = hits.first else {
            throw LogicianError.trackNotExposed(
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar)
                    + " on track row \(row.number) ('\(row.track)')",
                exposed: "that row holds: "
                    + (row.regions.isEmpty
                        ? "no regions"
                        : RegionAddressing.candidates(annotated.map { $0.1 })
                            .joined(separator: ", "))
                    + ". A region's start_bar changes with every edit, so re-read"
                    + " logic_list_regions rather than reusing an earlier one"
            )
        }
        guard hits.count == 1 else {
            throw LogicianError.regionAmbiguous(
                track: row.track,
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar),
                candidates: RegionAddressing.candidates(hits.map { $0.1 })
            )
        }
        // Focus BEFORE the region selection, never after: the repair writes to
        // the track header column, and the region's own AXSelected has to be
        // the last write standing when the command fires. Same doctrine as
        // `splitRegion`'s park-first-select-last ordering, for the same
        // reason.
        let keyFocus = forKeyCommand
            ? ensureTracksAreaKeyFocus(trackName: row.track, trackNumber: row.number)
            : nil
        // ONE read of the selection, taken BEFORE anything is written: the
        // target's own state and the other selected regions come out of the
        // same sweep the exclusive clear used to do on its own. Both
        // exclusivity settings need the sweep, for opposite reasons —
        // `exclusive: true` clears those regions, `exclusive: false` has to
        // prove they are STILL selected when it returns.
        var targetSelected = false
        var selectedSiblings: [AXUIElement] = []
        for otherRow in rows {
            for region in otherRow.regions {
                let isTarget = CFEqual(region, hit.0)
                guard stringAttribute(region, "AXSelected") == "1" else { continue }
                if isTarget { targetSelected = true } else { selectedSiblings.append(region) }
            }
        }
        let plan = LogicAccessibility.regionSelectionPlan(
            targetSelected: targetSelected, exclusive: exclusive,
            otherSelectedCount: selectedSiblings.count
        )
        for sibling in selectedSiblings where plan.clearSiblings {
            _ = AXUIElementSetAttributeValue(sibling, "AXSelected" as CFString, kCFBooleanFalse)
        }
        var stuck = !plan.writeTarget
        if stuck && plan.reproveAfterClear {
            // The clear just wrote to this row; the skip may only stand on a
            // read taken after it, never on the one taken before. Polled, not
            // read once: a write to a sibling republishes the same layout
            // area, which is the very staleness this fix is dodging — and a
            // stale "not selected" here would put the 1.1 s retry straight
            // back. Look-first, so the honest case still costs one read.
            stuck = pollRegionSelected(hit.0, budget: 0.1)
        }
        let wroteSelection = !stuck
        if wroteSelection {
            for attempt in 0..<2 {
                let status = AXUIElementSetAttributeValue(
                    hit.0, "AXSelected" as CFString, kCFBooleanTrue
                )
                guard status == .success else {
                    throw LogicianError.writeFailed(
                        "AXSelected write returned AXError \(status.rawValue)"
                    )
                }
                // Look before sleeping. The AX write is synchronous — a genuine
                // change read back as selected inside 300 ms in every measured
                // sample (8/8, 2026-09-02) and the sibling paths read
                // `AXSelected` back at 0 ms — so the 0.3 s stays as a BUDGET
                // for a slower Logic instead of a flat charge on every write.
                if pollRegionSelected(hit.0, budget: 0.3) { stuck = true; break }
                if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) } // stale-element transient
            }
        }
        guard stuck else {
            throw LogicianError.verificationFailed(
                requested: "region selected",
                actual: "the region's AXSelected did not read back as selected within 0.3 s of "
                    + "the write, and did not stick after a rewrite either",
                restored: false
            )
        }
        // Hand the region keyboard focus. On the EXCLUSIVE path only, and that
        // is the whole of D2: measured 2026-09-02, writing `kAXFocused = true`
        // onto a region COLLAPSES Logic's region selection onto that one
        // region — four selected regions on four tracks went to one, with no
        // `AXSelected` write of any kind in the same call. It is Logic reading
        // focus as a plain click. On the exclusive path that is aligned with
        // the contract (the siblings were just cleared anyway) and it is not
        // removed; what it is NOT is the thing that makes key commands work —
        // measured 2026-09-01, it ran on all three copies that fired
        // Copy/Paste and changed nothing there, so `forKeyCommand` above stays
        // the real guard.
        if plan.focusTarget {
            _ = AXUIElementSetAttributeValue(hit.0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // The additive path owes the caller the thing it claims to have done.
        // Counted off a FRESH walk, never off the sibling elements read before
        // the write: a write republishes the layout items, so a re-read of a
        // held element can say "not selected" about a region that is — the
        // same staleness the read-before-write fix was dodging. Polled and
        // look-first, so the honest case costs one walk.
        var additive: LogicAccessibility.AdditiveSelectionOutcome?
        if !exclusive {
            let expected = selectedSiblings.count + 1
            var observed = expected
            if plan.provePriorSelection {
                observed = (try? pollSelectedRegionCount(reaching: expected, budget: 0.3))
                    ?? expected
            }
            additive = LogicAccessibility.additiveSelectionOutcome(
                expected: expected, observed: observed
            )
        }
        var result = parseRegion(hit.0)
        result["success"] = true
        result["verified"] = true
        result["state"] = wroteSelection ? "selected" : "already_selected"
        result["track"] = row.track
        result["track_name"] = row.track
        // The ROW, not just the name: on a project where several rows carry
        // one name it is the only unambiguous handle, and every region tool
        // now takes it back as `track_number`.
        result["track_number"] = row.number
        result["exclusive"] = exclusive
        if exclusive { result["deselected"] = plan.siblingsToClear }
        if let additive {
            result["selected_before"] = selectedSiblings.count + (targetSelected ? 1 : 0)
            result["selected_count"] = additive.selectedCount
            result["note"] = "exclusive: false ADDED this region to the selection; the counts see "
                + "VISIBLE track rows only (logic_list_regions has the same limit) while the "
                + "selection itself is project-wide. For a whole track, everything after a point, "
                + "or the whole project, logic_select_regions does it in one Logic command."
            if let warning = additive.warning { result["warning"] = warning }
        }
        if let keyFocus { result["key_focus"] = keyFocus.dictionary }
        return result
    }

    /// Re-reads a region's `AXSelected` until it says selected, looking BEFORE
    /// it sleeps. Returns false when the budget runs out.
    func pollRegionSelected(
        _ region: AXUIElement, budget: TimeInterval, interval: TimeInterval = 0.01
    ) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if stringAttribute(region, "AXSelected") == "1" { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Re-walks the arrangement until it counts `reaching` selected regions,
    /// looking BEFORE it sleeps. Returns the last count it read when the
    /// budget runs out, so the caller can report what Logic actually
    /// published rather than what it hoped for.
    func pollSelectedRegionCount(reaching target: Int, budget: TimeInterval,
                                 interval: TimeInterval = 0.02) throws -> Int {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            let count = try selectedRegionCount()
            if count >= target || Date() >= deadline { return count }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// What `selectRegion` does about a selection it has READ but not yet
    /// written.
    struct RegionSelectionPlan: Equatable {
        /// Whether the other selected regions must be deselected. The
        /// `exclusive:` contract, and nothing else, decides this — an
        /// already-selected target does NOT excuse leaving a sibling selected,
        /// because the caller's next key command would take it too.
        let clearSiblings: Bool
        /// How many other regions were found selected and will be cleared.
        let siblingsToClear: Int
        /// Whether `AXSelected = true` has to be written to the target at all.
        let writeTarget: Bool
        /// Whether the skipped write has to be re-proved: the sibling clear
        /// writes to the same rendered rows, so a "already selected" verdict
        /// taken before it may only stand on a second read taken after it.
        let reproveAfterClear: Bool
        /// Whether `kAXFocused = true` may be written to the target. NOT on the
        /// additive path: measured 2026-09-02, that write on its own collapses
        /// Logic's whole region selection onto the focused region.
        let focusTarget: Bool
        /// Whether the regions that were selected BEFORE this call have to be
        /// counted again afterwards. Only the additive path owes that proof,
        /// and only when it actually wrote something that could have taken
        /// them away.
        let provePriorSelection: Bool
    }

    /// What an `exclusive: false` call is worth reporting once the arrangement
    /// has been counted again.
    ///
    /// `expected` is the regions that were selected before plus this one;
    /// `observed` is what a fresh walk of the rendered rows found. A count that
    /// came up SHORT is the defect this contract exists to catch — the caller
    /// asked to add a region and Logic replaced the selection instead — and it
    /// is a warning on a call that did select its target, never a silent
    /// success and never a throw.
    struct AdditiveSelectionOutcome: Equatable {
        let selectedCount: Int
        let warning: String?
    }

    static func additiveSelectionOutcome(expected: Int, observed: Int) -> AdditiveSelectionOutcome {
        guard observed < expected else {
            return AdditiveSelectionOutcome(selectedCount: observed, warning: nil)
        }
        return AdditiveSelectionOutcome(
            selectedCount: observed,
            warning: "This region IS selected, but the selection did not GROW: \(expected) "
                + "region(s) should be selected across the rendered rows and Logic published "
                + "\(observed) — \(expected - observed) that were selected before this call are "
                + "not any more. Treat the selection as this region alone, and use "
                + "logic_select_regions (mode 'track'/'following'/'following_same_track'/'all') "
                + "for a multi-region selection Logic makes with its own command."
        )
    }

    /// Read `AXSelected` before writing it — the whole of D1.
    ///
    /// Measured 2026-09-02 (`logic_get_region_params` profile, 8/8 perfect
    /// correlation): writing `AXSelected = true` onto a region that is ALREADY
    /// selected makes Logic republish the layout item, so the readback lands on
    /// a stale element and reports NOT selected for longer than 300 ms — the
    /// "stale-element transient" retry then fires every single time, at
    /// 1116–1125 ms against the 305–306 ms a genuine change costs. The
    /// idempotent case is the common one (read a region then read it again,
    /// read then write), so all eight `selectRegion` callers — get/set/rename
    /// region params, move, copy, delete, split, edit_event, bounce_in_place —
    /// paid **+812 ms** for a selection that was already correct.
    ///
    /// This also corrects the older `logic_delete_region` note that the retry
    /// "fires on freshly-created regions": the discriminator is *already
    /// selected*, not *freshly created*.
    ///
    /// Measured after the fix, same project, same day: `logic_get_region_params`
    /// on an already-selected region 1990–1997 → 866–873 ms (1943 → 805 ms with
    /// two siblings still selected), on a region that was NOT selected
    /// 1158–1174 → 857–866 ms, and `logic_select_region` itself 402–465 →
    /// 90–163 ms.
    /// The second half is D2, measured 2026-09-02 on the same project: the
    /// unconditional `kAXFocused = true` at the end of the write made
    /// `exclusive: false` a LIE. The schema advertised an additive selection
    /// and three sequential non-exclusive selects left exactly one region
    /// selected, the last, on MIDI and audio regions alike — each call
    /// reporting `success: true, verified: true`, because the only thing
    /// verified was the target. Isolated: `AXFocused = true` written ALONE,
    /// with no `AXSelected` write in the call at all, took a four-region
    /// selection spread over four tracks down to the one focused region.
    /// `AXSelected = true` written alone is genuinely additive — 1 → 2 → 3 → 4
    /// over four consecutive writes. So the focus write is the whole defect,
    /// and dropping it on the additive path is the whole cure; the exclusive
    /// path keeps it, where a collapse onto the target is what the contract
    /// asked for anyway.
    ///
    /// (`AXSelectedChildren` is published on the track row's layout area and on
    /// the `Tracks contents` group, and is NOT settable on either — read-only
    /// mirrors, not a second write route.)
    static func regionSelectionPlan(
        targetSelected: Bool, exclusive: Bool, otherSelectedCount: Int
    ) -> RegionSelectionPlan {
        let clearing = exclusive && otherSelectedCount > 0
        return RegionSelectionPlan(
            clearSiblings: exclusive,
            siblingsToClear: exclusive ? otherSelectedCount : 0,
            writeTarget: !targetSelected,
            reproveAfterClear: targetSelected && clearing,
            focusTarget: exclusive,
            provePriorSelection: !exclusive && !targetSelected && otherSelectedCount > 0
        )
    }

    /// The channel strip's pan value (the strip's pan AXSlider), always
    /// readable regardless of which MCU view is active.
    func stripPanValue(trackName: String) -> Double? {
        guard let strip = try? inspectorStrip(named: trackName) else { return nil }
        for child in children(of: strip)
        where stringAttribute(child, kAXDescriptionAttribute as String) == LogicUIStrings.Element.pan {
            return Double(stringAttribute(child, kAXValueAttribute as String))
        }
        return nil
    }

    // `pluginPresetLabel` used to live here and took "the rightmost pop-up
    // that has a value", which picked PARAMETER pop-ups on several stock
    // plugins. It now lives in `AXPresets.swift` and identifies the setting
    // pop-up by its action set; see `presetPopUpButton`.

    /// Renames a track by writing the channel strip's name field.
    ///
    /// Read before write, and the reads answer three questions no key command
    /// should fire before: WHICH row (by name and number, so one of two
    /// same-named rows can be addressed at all), is this a no-op, and would it
    /// leave two rows sharing a name. The waits are gone — see
    /// `TrackChange.renameEditorDeadline` for the probes that proved all three
    /// blind sleeps dead, 1 455 ms → 271 ms measured 2026-09-02.
    func renameTrack(
        trackName: String,
        trackNumber: Int?,
        newName: String
    ) throws -> [String: Any] {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LogicianError.invalidArguments("new_name must be non-empty")
        }
        let beforeHeaders = try parsedTrackHeaders()
        let target = try resolveTrack(beforeHeaders, name: trackName, number: trackNumber)

        // A rename to the name the row already carries, character for
        // character. The old shape fired the key command, opened the editor,
        // wrote the same string and charged 1 441 ms for it — and then
        // reported `state: "renamed"`, which is the one thing that did not
        // happen. Case matters: `{Inst 2 → INST 2}` IS a rename (measured),
        // and `resolveTrack` addresses rows case-sensitively, so the caller
        // has to be told which of the two it got.
        if target.name == newName {
            return [
                "success": true, "verified": true, "state": "already_named",
                "from": target.name, "to": newName, "previous_name": target.name,
                "renamed_track": ["track_number": target.number, "track_name": target.name],
                "note": "Track \(target.number) is already named '\(newName)'. Nothing was"
                    + " selected, no key command fired and nothing was written. A rename that"
                    + " differs only in CASE is a real rename and is performed."
            ]
        }
        // Refuse to manufacture an unaddressable pair. `logic_duplicate_track`
        // already makes them — a copy that keeps the source's name leaves two
        // rows answering to it, and `logic_delete_track` then refuses
        // "ambiguous; it matches track numbers 26, 27" (measured 2026-09-01).
        // Rename is the only way OUT of that state, so it must not be a way
        // into it: two rows sharing a name can only be addressed by number,
        // and every tool that resolves by name alone refuses them.
        //
        // It is a refusal only for a call that did not pass `track_number`.
        // A caller addressing rows by number has shown it can address the pair
        // it is asking for — and restoring a project's own duplicate pair
        // (this reference project ships one) is a legitimate move that a flat
        // refusal would make impossible. That call goes through, and the
        // result says what it made.
        let beforeRows = TrackChange.rows(
            headers: beforeHeaders.map { (number: $0.number, name: $0.name, selected: $0.selected) }
        )
        let clash = TrackChange.nameCollision(
            rows: beforeRows, renaming: target.number, to: newName
        )
        if let clash, trackNumber == nil {
            throw LogicianError.preconditionUnmet(
                "Track \(clash.number) is already named '\(newName)', so renaming track"
                    + " \(target.number) to it would leave two rows answering to one name —"
                    + " the state logic_duplicate_track produces and which every track tool"
                    + " refuses as ambiguous unless it is given a track_number. Nothing was"
                    + " selected and no key command fired. Pick a name no other row carries,"
                    + " or pass track_number: \(target.number) to make the pair deliberately."
            )
        }
        // By NUMBER as well as name: the row was resolved out of these very
        // rows, and passing the number through is what keeps the selection
        // unambiguous when a duplicate pair is what is being repaired.
        _ = try selectTrack(
            trackName: target.name, trackNumber: target.number, expectedProjectPath: nil
        )
        // The header/strip name fields ignore direct AXValue writes; the
        // Rename Track key command opens an inline editor whose focused
        // element IS settable.
        let command = try MCUController.resolveKeyCommand(
            named: KeyCommandRegistry.Name.renameTrack, logic: self
        )
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
        var editor: AXUIElement?
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw LogicianError.logicNotRunning
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        // Look BEFORE sleeping: the editor is focused and settable within ~1 ms
        // of the key command returning (6 of 6 probed runs), and the loop that
        // slept first paid 200 ms of every call to find it on the first look
        // anyway.
        let editorDeadline = Date().addingTimeInterval(TrackChange.renameEditorDeadline)
        while true {
            // A focused "element" that is not one keeps polling (the editor
            // may not exist yet) rather than trapping mid-rename.
            if let element = elementAttribute(appElement, "AXFocusedUIElement") {
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                if settable.boolValue { editor = element; break }
            }
            if Date() >= editorDeadline { break }
            Thread.sleep(forTimeInterval: TrackChange.renameEditorInterval)
        }
        guard let field = editor else {
            throw LogicianError.trackNotExposed(
                requested: "the inline rename editor",
                exposed: "no settable focused element appeared after Rename Track"
            )
        }
        // The editor comes up pre-filled with the OLD name (6 of 6 probed
        // runs), so the row's identity can be cross-checked for free at the
        // one moment it matters: immediately before typing into the field.
        let prefill = stringAttribute(field, kAXValueAttribute as String)
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, newName as CFString
        )
        guard status == .success else {
            throw LogicianError.writeFailed("name write returned AXError \(status.rawValue)")
        }
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)

        // ONE poll, over the thing this tool verifies, looking before it
        // sleeps — and the popover close rides on the MISS path. Both blind
        // sleeps that used to stand here (0.6 s + 0.3 s) were proven dead by
        // reads taken at 0 ms after the confirm; see
        // `TrackChange.renameEditorDeadline`.
        var closedPopover = false
        var afterRows: [TrackChange.Row] = []
        var partial = false
        var outcome = TrackChange.RenameOutcome.unchanged
        var deadline = Date().addingTimeInterval(TrackChange.renamePollDeadline)
        while true {
            let payload = (try? listTracks()) ?? [:]
            afterRows = TrackChange.rows((payload["tracks"] as? [[String: Any]]) ?? [])
            partial = payload["partial"] as? Bool == true
            outcome = TrackChange.renameVerdict(
                after: afterRows, number: target.number, to: newName, partial: partial
            )
            if outcome == .renamed { break }
            if !closedPopover, closeRenamePopover(titled: newName) {
                // Something WAS standing in the way; the name lands after it
                // is closed, so the clock starts again from there.
                closedPopover = true
                deadline = Date().addingTimeInterval(TrackChange.renamePollDeadline)
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: TrackChange.renamePollInterval)
        }

        var result: [String: Any] = [
            "success": outcome == .renamed,
            "verified": outcome == .renamed,
            "from": target.name, "to": newName,
            "previous_name": target.name,
            "renamed_track": ["track_number": target.number, "track_name": newName],
            "tracks_before": beforeRows.count,
            "tracks_after": afterRows.count,
            "tracks_partial": partial,
            "dialogs_closed": closedPopover
        ]
        if !prefill.isEmpty, prefill != target.name {
            result["warning"] = "The inline editor came up holding '\(prefill)' where the header"
                + " row reads '\(target.name)'. The write went into the focused field either"
                + " way; re-read logic_list_tracks before trusting `renamed_track`."
        } else if let clash, outcome != .unchanged {
            result["warning"] = "Track \(clash.number) is also named '\(newName)' now, because"
                + " track_number was passed. Both rows answer to that one name and every track"
                + " tool refuses it as ambiguous — address either of them by track_number from"
                + " here on."
        }
        switch outcome {
        case .renamed:
            result["state"] = "renamed"
            result["note"] = "Renamed; `renamed_track` addresses the row by number and by its new"
                + " name. Logic leaves the left inspector strip painted with the OLD name until"
                + " the selection moves, which is handled here — no selection bounce is needed"
                + " before the next call on the new name."
            // Logic will keep painting the old name in the inspector for as
            // long as this track stays selected; recording it is what stops
            // the next `selectTrack`-routed call refusing this very row.
            LogicAccessibility.noteRenamedInPlace(was: target.name, now: newName)
        case .notVisible:
            result["state"] = "renamed_not_visible"
            result["warning"] = "This project renders only part of its track list"
                + " (`partial: true`) and track \(target.number) is not among the rendered rows,"
                + " so the rename NOT being visible does not mean it did not land."
            result["note"] = "The name was written into the focused editor and confirmed. Scroll"
                + " the Tracks area and re-read logic_list_tracks before firing this again — a"
                + " retry addressed to '\(target.name)' will not find the row if the rename"
                + " worked, and Undo is a blind instrument."
            LogicAccessibility.noteRenamedInPlace(was: target.name, now: newName)
        case .unchanged:
            let seen = afterRows.first(where: { $0.number == target.number })?.name ?? "nothing"
            throw LogicianError.verificationFailed(
                requested: "track \(target.number) '\(target.name)' renamed to '\(newName)'",
                actual: "that row still reads '\(seen)' after"
                    + " \(Int(TrackChange.renamePollDeadline)) s of looking; nothing was"
                    + " restored and nothing else was touched",
                restored: false
            )
        }
        return result
    }

    /// Closes a rename popover, if Logic 12.3.1 ever raises one.
    ///
    /// It did not once in nine profiled renames across four name shapes
    /// (2026-09-02: no window with subrole `AXDialog` existed at all at that
    /// moment, 6/6 instrumented runs, `dialogs_closed=0` on 9/9) — but the
    /// scan costs 4.3 ms and it is asked on the verification poll's miss path,
    /// so a version that DOES prompt is answered within milliseconds and a
    /// version that does not pays nothing for the question.
    func closeRenamePopover(titled newName: String) -> Bool {
        guard let windows = try? logicWindows() else { return false }
        var closed = false
        for window in windows
        where stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog"
            && stringAttribute(window, kAXTitleAttribute as String) == newName {
            // Skip a close button that is not an element, as if the
            // attribute were absent; `as!` here would trap.
            if let close = elementAttribute(window, kAXCloseButtonAttribute as String) {
                closed = AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
            }
        }
        return closed
    }

    /// Rapid-fire stepwise write toward a pan target on the strip's pan
    /// knob, bounded by a time budget (one step per ~15 ms write).
    func stripPanWrite(trackName: String, target: Double, budget: TimeInterval) throws {
        guard let strip = try? inspectorStrip(named: trackName) else {
            throw LogicianError.windowNotFound("channel strip for '\(trackName)'")
        }
        guard let knob = children(of: strip).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.pan
        }) else {
            throw LogicianError.windowNotFound("pan knob on '\(trackName)'")
        }
        let goal = Int(target.rounded())
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            guard let current = Int(stringAttribute(knob, kAXValueAttribute as String)) else { break }
            if current == goal { return }
            _ = AXUIElementSetAttributeValue(knob, kAXValueAttribute as CFString, goal as CFNumber)
            usleep(15000)
        }
    }

    /// The channel strip's automation-mode label, e.g. "Latch" from
    /// "Latch, automation enabled". nil when the strip is not visible.
    func automationModeLabel(trackName: String) -> String? {
        guard let strip = try? inspectorStrip(named: trackName) else { return nil }
        for child in children(of: strip) {
            let description = stringAttribute(child, kAXDescriptionAttribute as String)
            if description.contains(LogicUIStrings.Element.automation) {
                return description.split(separator: ",").first.map(String.init)
            }
        }
        return nil
    }

    // MARK: - Region editing (exclusive selection + learned key commands)

    func fireKeyCommand(
        _ name: String, learnIfMissing: Bool = false, source: String = "logic_setup_key_commands"
    ) throws {
        let command = try MCUController.resolveKeyCommand(
            named: name, logic: self, learnIfMissing: learnIfMissing, source: source
        )
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
    }

    /// Every region on one track row.
    ///
    /// `trackNumber` addresses the row by number, for the same duplicate-name
    /// reason as `selectRegion`: `listRegions(trackName:)` filters by NAME and
    /// would fold two namesake rows into one snapshot, which is exactly the
    /// shape that makes a paste look verified on the wrong track.
    ///
    /// `alreadyWalkedRows` reuses a walk the caller has just taken, exactly as
    /// `selectRegion`'s does and under the same condition — the walk must be
    /// newer than the last write, because a write republishes the layout
    /// items. It is what lets a tool that has to snapshot the row AND select
    /// the region in it pay for one walk instead of two (64–74 ms each,
    /// measured 2026-09-02). Default nil = walk fresh.
    func regionSnapshot(
        trackName: String, trackNumber: Int? = nil,
        alreadyWalkedRows: [(number: Int, track: String, regions: [AXUIElement])]? = nil
    ) throws -> [[String: Any]] {
        let rows = try alreadyWalkedRows ?? regionRows()
        if rows.isEmpty {
            // Whether an arrangement with no rendered rows is EMPTY or merely
            // unreadable is `listRegions`' verdict, and it refuses on both —
            // asking it here keeps that judgement in one place instead of
            // reporting "no track of that name" about a Tracks area this walk
            // could not read at all. It throws; the resolution below is what
            // the compiler needs, not a second answer.
            _ = try listRegions(trackName: trackName)
        }
        let row = try resolveRegionRow(rows, trackName: trackName, trackNumber: trackNumber)
        // Typed the way `listRegions` types them: a row holds one KIND of
        // region, so where one region publishes its help sentence the rest of
        // the row is filled in from it. The by-number path used to skip this
        // and answer with `type` missing on regions whose neighbours had it.
        return LogicAccessibility.typedRowRegions(row.regions.map(parseRegion))
    }

    /// Counts selected regions across ALL RENDERED rows.
    ///
    /// Read what this cannot do: `regionRows()` publishes the track rows Logic
    /// has rendered and nothing about the ones it has not, so a region selected
    /// on a scrolled-out or folder-stacked row is not in this number. It is a
    /// necessary condition for exclusivity, never a project-wide proof — see
    /// `RegionEditGuard` for the receipt that is, and for the four tools that
    /// used to advertise this count as one.
    func selectedRegionCount() throws -> Int {
        try regionRows().reduce(0) { sum, row in
            sum + row.regions.filter { stringAttribute($0, "AXSelected") == "1" }.count
        }
    }

    /// The whole arrangement in ONE walk: which rows are rendered, how many
    /// regions they hold between them, how many of those are selected, and the
    /// parsed regions of one target row.
    ///
    /// It exists because the destructive region path used to take three walks to
    /// learn these (`regionSnapshot` + `selectedRegionCount` + a second snapshot)
    /// and STILL could not answer the only question that mattered — whether the
    /// count it had was the project's. The totals are the after-check's real
    /// yardstick for all four destructive region tools: the target track's own
    /// count is satisfied by a Delete that also emptied three other rows, by a
    /// Split that cut four regions, and by a Paste that put four down.
    ///
    /// `parseRegion` runs on the target row only. The totals need no help text,
    /// so they cost one `AXSelected` read per region and no regex at all.
    struct ArrangementCensus {
        let rowNumbers: [Int]
        let totalRegions: Int
        let selectedRegions: Int
        let targetRegions: [[String: Any]]
        /// The walk itself, kept so the next reader does not have to repeat it.
        /// `logic_move_region` hands these to `selectRegion`'s anchor pass,
        /// which used to walk the same tree 53 ms later with nothing but two
        /// reads in between (measured 2026-09-02: six walks of one tree,
        /// 386 ms, 34% of the call). Only safe until something is WRITTEN — a
        /// write republishes the layout items and a held element then answers
        /// for a region that has moved on.
        let rows: [(number: Int, track: String, regions: [AXUIElement])]
    }

    func arrangementCensus(trackName: String, trackNumber: Int? = nil) throws -> ArrangementCensus {
        let rows = try regionRows()
        let target = try resolveRegionRow(rows, trackName: trackName, trackNumber: trackNumber)
        var total = 0
        var selected = 0
        for row in rows {
            total += row.regions.count
            selected += row.regions.filter { stringAttribute($0, "AXSelected") == "1" }.count
        }
        return ArrangementCensus(
            rowNumbers: rows.map(\.number),
            totalRegions: total,
            selectedRegions: selected,
            targetRegions: target.regions.map(parseRegion),
            rows: rows
        )
    }

    /// Can this walk see every row a selection-based command would act on? Reads
    /// the track HEADER column and Logic's scroll bar, because the region walk
    /// publishes neither a collapsed stack nor a viewport.
    func regionRowCoverage(regionRowNumbers: [Int]) -> RegionEditGuard.Coverage {
        let headers = (try? parsedTrackHeaders()) ?? []
        let verdict = TrackListCompleteness.evaluate(
            rows: headers.map {
                TrackListCompleteness.Row(
                    number: $0.number, name: $0.name,
                    isStack: $0.disclosure != nil, expanded: $0.expanded
                )
            },
            scrollable: tracksAreaScrollable().scrollable
        )
        return RegionEditGuard.coverage(
            trackVerdict: verdict,
            headerNumbers: headers.map(\.number),
            regionRowNumbers: regionRowNumbers
        )
    }

    /// Clears the region selection ACROSS THE WHOLE PROJECT with Logic's own
    /// `Deselect All`, and returns the rendered selection count it left behind.
    ///
    /// The receipt is the transition, not the command: the caller has just made
    /// exactly one region selected, so a rendered count that falls to 0 proves
    /// the command reached Logic, is bound to something real, and had effect —
    /// which is also, incidentally, a live proof that the Tracks area holds the
    /// keyboard focus these commands need. Logic's semantics carry that effect
    /// to the rows the walk cannot see; the proof carries the claim that it
    /// fired at all.
    ///
    /// Positive check first, then 50 ms polling: the same shape as every other
    /// key-command wait here, and for the same measured reason (2026-09-01 — a
    /// region key command's effect is readable on the FIRST look in 3 of 3).
    func clearProjectWideRegionSelection(
        budget: TimeInterval = 1.5
    ) throws -> Int {
        try fireKeyCommand(KeyCommandRegistry.Name.deselectAll)
        let deadline = Date().addingTimeInterval(budget)
        var remaining = try selectedRegionCount()
        while remaining != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            remaining = try selectedRegionCount()
        }
        return remaining
    }

    /// The pre-write decision every selection-based region command shares.
    ///
    /// Reads how far the arrangement walk can see, asks `RegionEditGuard` what
    /// this call may promise, and THROWS the refusal from here — before the
    /// caller has written anything, which is what makes `restored: true` on that
    /// path a fact rather than a claim. Callers that write something else first
    /// (`splitRegion` parks the playhead) must still call this BEFORE that write.
    func regionEditPlan(
        _ command: RegionEditGuard.Command, regionRowNumbers: [Int]
    ) throws -> (coverage: RegionEditGuard.Coverage, plan: RegionEditGuard.Plan) {
        let coverage = regionRowCoverage(regionRowNumbers: regionRowNumbers)
        let plan = RegionEditGuard.plan(
            coverage: coverage,
            deselectAllRegistered: KeyCommandRegistry.note(
                named: KeyCommandRegistry.Name.deselectAll
            ) != nil,
            command: command
        )
        if case .refuse(let reason) = plan {
            throw LogicianError.verificationFailed(
                requested: "exactly one region selected across the WHOLE project before "
                    + command.name,
                actual: reason,
                restored: true // nothing has been written at this point
            )
        }
        return (coverage, plan)
    }

    /// One region selected, and an honest statement of how far that claim
    /// reaches — the step all four destructive region tools take immediately
    /// before their key command.
    struct ExclusiveRegionSelection {
        /// The selection the command will act on. After a project-wide clear
        /// this is the SECOND pass's result, so it describes the region that is
        /// actually selected on screen right now.
        let region: [String: Any]
        /// The FIRST pass's result, which is the one carrying `key_focus` — what
        /// state the call inherited, and the evidence a "nothing happened"
        /// failure leads with.
        let anchor: [String: Any]
        /// `"project"` when Logic's own `Deselect All` established it,
        /// `"rendered_rows"` when only the arrangement walk could be counted.
        let scope: String
        /// The receipt for the clear, or nil when there was none.
        let clearReceipt: [String: Any]?
        /// The `renderedRowsOnly` warning, or nil.
        let warning: String?

        /// Everything the result should carry about the selection, merged in by
        /// the caller so all four tools report it the same way.
        ///
        /// The warning is APPENDED, never assigned: `logic_split_region` and
        /// `logic_copy_region` both have their own honest complaints to make
        /// about the playhead, and a scope caveat must not silently replace one.
        func decorate(_ result: inout [String: Any]) {
            result["selection_scope"] = scope
            if let clearReceipt { result["project_wide_clear"] = clearReceipt }
            appendWarning(warning, to: &result)
        }
    }

    /// Makes exactly one region selected, project-wide where Logic lets it.
    ///
    /// Select the target (which establishes the Tracks-area keyboard focus these
    /// commands need), fire Logic's own project-wide `Deselect All`, PROVE it
    /// landed by watching the rendered selection fall from one to zero, select
    /// the target back by the identity the first pass resolved, and count again.
    /// The `renderedRowsOnly` plan skips the clear and counts once, and says so.
    ///
    /// The clear costs ~0.8 s (measured 2026-09-01 on `logic_delete_region`:
    /// 1.98 s → 2.78 s) and there is no path that may skip it as provably
    /// unnecessary — see `RegionEditGuard.plan` for why that fast path cannot
    /// exist.
    /// `alreadyWalkedRows` is passed to the ANCHOR pass only, and only by a
    /// caller that has walked the arrangement and written nothing since. The
    /// reselect below always walks fresh: `Deselect All` has written to every
    /// rendered row by then, and a held element after a write is exactly what
    /// this family got burned by.
    func establishExclusiveRegionSelection(
        _ command: RegionEditGuard.Command, plan: RegionEditGuard.Plan,
        trackName: String, regionName: String?, startBar: Int?, trackNumber: Int? = nil,
        alreadyWalkedRows: [(number: Int, track: String, regions: [AXUIElement])]? = nil
    ) throws -> ExclusiveRegionSelection {
        let anchor = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
            trackNumber: trackNumber, forKeyCommand: true, alreadyWalkedRows: alreadyWalkedRows
        )
        guard case .projectWideClear = plan else {
            // ONE count, not two. The value the guard TESTED is the value the
            // refusal quotes: reading it a second time to interpolate a string
            // cost a fifth full tree walk (~110 ms measured 2026-09-01) and
            // could legitimately print a number that never refused anything.
            let selectedCount = try selectedRegionCount()
            guard selectedCount == 1 else {
                throw LogicianError.verificationFailed(
                    requested: "exactly one selected region before \(command.name)",
                    actual: "\(selectedCount) regions selected; refusing to fire \(command.name). "
                        + command.nothingHappened + " - but the SELECTION was not put back "
                        + "either: this call had already selected "
                        + "'\(anchor["name"] ?? "?")' exclusively, which cleared every other "
                        + "region's selection",
                    // `restored: true` here was a fiction: selectRegion has by
                    // now changed the region selection and written AXFocused.
                    // The arrangement is untouched; the selection is not.
                    restored: false
                )
            }
            var warning: String?
            if case .renderedRowsOnly(let text) = plan { warning = text }
            return ExclusiveRegionSelection(
                region: anchor, anchor: anchor, scope: "rendered_rows",
                clearReceipt: nil, warning: warning
            )
        }
        let remaining = try clearProjectWideRegionSelection()
        guard remaining == 0 else {
            throw LogicianError.verificationFailed(
                requested: "the project-wide region selection cleared before \(command.name)",
                actual: "'\(KeyCommandRegistry.Name.deselectAll)' fired and \(remaining) "
                    + "region(s) are still selected, so it did not reach Logic or is bound to "
                    + "something else - and without it the selection cannot be proven "
                    + "exclusive beyond the rendered rows. Refusing to fire \(command.name). "
                    + command.nothingHappened + "; the SELECTION was changed (this call selected "
                    + "'\(anchor["name"] ?? "?")' exclusively across the rendered rows). "
                    + TracksAreaFocus.summary(inSelectionResult: anchor) + " "
                    + TracksAreaFocus.dialogSentence(modalWindowTitles())
                    + " Relearn the key commands with logic_setup_key_commands "
                    + "{relearn: true} if the binding is stale.",
                restored: false
            )
        }
        // Select the target BACK, by the identity the first selection resolved -
        // not by the caller's possibly looser arguments, so the second pass
        // cannot land on a different region than the first.
        let reselected = try selectRegion(
            trackName: trackName,
            regionName: anchor["name"] as? String,
            startBar: anchor["start_bar"] as? Int,
            exclusive: true,
            trackNumber: trackNumber,
            // The focus was established above, and `Deselect All` landing just
            // proved it is live. A second header write buys nothing.
            forKeyCommand: false
        )
        let selectedNow = try selectedRegionCount()
        guard selectedNow == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before \(command.name)",
                actual: "\(selectedNow) regions selected after a proven project-wide clear; "
                    + "refusing to fire \(command.name). " + command.nothingHappened
                    + "; the selection was cleared and then reselected",
                restored: false
            )
        }
        return ExclusiveRegionSelection(
            region: reselected, anchor: anchor, scope: "project",
            clearReceipt: [
                "command": KeyCommandRegistry.Name.deselectAll,
                "selected_after_clear": 0,
                "selected_before_command": selectedNow,
                "verified": true,
                "means": "Logic's own Deselect All is project-wide; the rendered selection was"
                    + " watched falling to zero, which proves the command landed."
            ],
            warning: nil
        )
    }

    /// The sentence a result carries about how far its exclusivity claim reaches.
    static func exclusivityNote(scope: String, command: RegionEditGuard.Command) -> String {
        scope == "project"
            ? "Before the target was selected back, the selection was cleared with Logic's own "
                + "Deselect All - a project-wide command, proven to have landed by the rendered "
                + "selection falling to zero - so nothing on an unrendered row was still selected "
                + "when \(command.name) fired. "
            : "Exclusivity was checked across the RENDERED rows only. "
    }

    /// The rows this call could not see, named in the result rather than only in
    /// a refusal — a success on a partial arrangement is still a success taken
    /// with one eye shut, and the caller is entitled to know which eye.
    func annotateCoverage(_ coverage: RegionEditGuard.Coverage, in result: inout [String: Any]) {
        guard coverage.partial else { return }
        result["rows_not_rendered"] = coverage.unseenTrackNumbers
        result["coverage_evidence"] = coverage.reasons
    }

    /// Deletes ONE region — and is allowed to say so.
    ///
    /// Logic's `Delete` takes every selected region in the project. This tool
    /// used to promise "exactly ONE region selected project-wide" on the
    /// strength of a count taken over `regionRows()`, which sees only RENDERED
    /// track rows; `selectRegion(exclusive:)` cleared the same rendered-only
    /// set, and the after-check compared region counts on the TARGET TRACK
    /// alone. On the sandbox project — ten hidden subtracks under a collapsed
    /// stack, `logic_list_tracks` saying `partial: true` — a Delete that also
    /// removed regions from those rows passed every one of those tests and came
    /// back `success: true, verified: true`.
    ///
    /// So the exclusivity is now ESTABLISHED rather than inferred: Logic's own
    /// project-wide `Deselect All` fires first and is proven by the rendered
    /// selection collapsing to zero, then the one target region is selected
    /// back. Where that command is missing from the registry, the tool refuses
    /// if rows are provably hidden and says what it checked if they are not —
    /// see `RegionEditGuard`. The after-check compares the region total across
    /// EVERY rendered row, so collateral damage on a rendered row is a loud
    /// failure instead of an invisible one.
    ///
    /// - Parameter trackNumber: addresses the ROW by number instead of trusting
    ///   the name to be unique (see `resolveRegionRow`).
    func deleteRegion(
        trackName: String, regionName: String?, startBar: Int?, trackNumber: Int? = nil
    ) throws -> [String: Any] {
        // The census and the coverage read come BEFORE any write, so a refusal
        // can honestly say the project is untouched — selection included. The
        // census doubles as the before-picture: selecting a region changes no
        // region counts.
        let before = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
        let (coverage, plan) = try regionEditPlan(.delete, regionRowNumbers: before.rowNumbers)
        let exclusive = try establishExclusiveRegionSelection(
            .delete, plan: plan,
            trackName: trackName, regionName: regionName, startBar: startBar,
            trackNumber: trackNumber
        )
        let targetName = exclusive.region["name"] as? String
        let targetBar = exclusive.region["start_bar"] as? Int
        try fireKeyCommand(KeyCommandRegistry.Name.delete)
        // Look BEFORE sleeping: measured 2026-09-01, the region was already
        // gone from the arrangement map on the FIRST read in 3 of 3 successful
        // deletes, so the old loop's opening 0.4 s sleep was pure waiting on
        // every success and its ten iterations cost 5.2 s to say "it is still
        // there" - the answer a focus-dead Logic gives every time.
        var verdict = RegionEditGuard.Verification.unchanged
        var after = before
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            after = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
            verdict = RegionEditGuard.verify(
                targetStillPresent: after.targetRegions.contains {
                    ($0["start_bar"] as? Int) == targetBar && ($0["name"] as? String) == targetName
                },
                regionsBefore: before.totalRegions,
                regionsAfter: after.totalRegions
            )
            if verdict != .unchanged { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        switch verdict {
        case .deleted:
            break
        case .unchanged:
            throw LogicianError.verificationFailed(
                requested: "region '\(targetName ?? "?")' deleted",
                actual: "the region is still in the arrangement map (undo history unaffected). "
                    + TracksAreaFocus.summary(inSelectionResult: exclusive.anchor) + " "
                    + TracksAreaFocus.dialogSentence(modalWindowTitles()),
                restored: false
            )
        case .wrongRegion(let removed):
            throw LogicianError.verificationFailed(
                requested: "region '\(targetName ?? "?")' deleted",
                actual: "it is STILL in the arrangement map while \(removed) other region(s) left "
                    + "it - Delete took something else. Undo restores them; check the arrangement "
                    + "with logic_list_regions before doing anything else",
                restored: false
            )
        case .collateral(let alsoRemoved):
            throw LogicianError.verificationFailed(
                requested: "exactly one region deleted",
                actual: "'\(targetName ?? "?")' is gone AND so are \(alsoRemoved) other region(s) "
                    + "on rendered rows - Delete acted on a selection wider than this call made. "
                    + "Undo restores them; check the arrangement with logic_list_regions",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "deleted",
            "track": trackName, "track_name": trackName,
            "region": targetName ?? "?",
            "start_bar": targetBar ?? NSNull(),
            "regions_before": before.totalRegions,
            "regions_after": after.totalRegions,
            "note": "Exactly one region left the arrangement: the region totals across every "
                + "rendered row fell by exactly 1, not just the target track's. "
                + Self.exclusivityNote(scope: exclusive.scope, command: .delete)
                + "Removable mistake? Undo restores it."
        ]
        exclusive.decorate(&result)
        annotateCoverage(coverage, in: &result)
        if let keyFocus = exclusive.anchor["key_focus"] { result["key_focus"] = keyFocus }
        return result
    }

    // MARK: - The split confirmation modal

    /// Logic's `Notes Crossing Split Point` window, if it is up.
    ///
    /// Splitting a MIDI region whose notes cross the split point raises this
    /// modal (observed 2026-08-28) and NOTHING else in Logic responds until it
    /// is answered — key commands over the MIDI port included, which is how a
    /// forgotten one looks: every later tool reports "the command fired and
    /// nothing happened". It is an `AXFloatingWindow` titled `Notes Crossing
    /// Split Point`, holding three radio buttons (`Keep`, `Shorten`, `Split`,
    /// with `Split` pre-selected) plus `OK` and `Cancel`.
    ///
    /// STILL TITLE-GATED. The window publishes no identifier, and its shape
    /// (three radios, OK, Cancel) is not unique enough to press blind — and
    /// this is a modal that BLOCKS everything, so a wrong match would be
    /// answered and the answer applied to some other dialog. A translated
    /// title means the modal is not found, `answerNotesCrossingSplit` returns
    /// nil, and `logic_split_region` reports the split unverified with the
    /// modal still up. Checklist item, and the highest-priority one: the cost
    /// of missing THIS dialog is a stalled Logic.
    func notesCrossingSplitDialog() -> AXUIElement? {
        (try? logicWindows())?.first {
            stringAttribute($0, kAXTitleAttribute as String)
                == LogicUIStrings.Window.notesCrossingSplitPoint
        }
    }

    /// What each choice does to a note that straddles the cut.
    static let notesCrossingChoices = [
        "keep": "the note stays whole and belongs to the first region",
        "shorten": "the note is truncated at the split point",
        "split": "the note is cut in two, one half in each region (Logic's own default)"
    ]

    /// What answering the "Notes Crossing Split Point" modal actually did.
    /// Reported rather than assumed: the caller prints this into its result,
    /// and the previous version returned the REQUESTED choice unconditionally
    /// — including when the radio button carrying that choice was never found
    /// (Logic then applies its OWN default and the notes are cut the other
    /// way) or when OK was never pressed at all.
    static let notesCrossingLogicDefault = "logic_default"
    static let notesCrossingUnanswered = "unanswered_cancelled"

    /// The sentence `logic_split_region` carries about the notes modal. Pure,
    /// so the four outcomes — never asked, answered as requested, answered by
    /// Logic's own default, not answered at all — can be pinned by tests
    /// instead of being re-derived at a call site that only ever saw one.
    static func notesCrossingNote(_ answer: String?, requested: String) -> String {
        let tail = "Undo restores the single region. The two halves are new regions:"
            + " their names and start bars are what logic_list_regions reports now, so re-read"
            + " the map before addressing either of them."
        switch answer {
        case nil:
            return "No 'Notes Crossing Split Point' dialog appeared - either no note straddles"
                + " the cut, or this is an audio region. " + tail
        case notesCrossingLogicDefault:
            return "Logic asked what to do with the notes crossing the cut, but the dialog"
                + " published no '\(requested)' option — so it was confirmed with whatever"
                + " Logic had already selected, and WHICH treatment the crossing notes got is"
                + " unknown. Check the two halves (logic_list_events) before relying on them. "
                + tail
        case notesCrossingUnanswered:
            return "Logic asked what to do with the notes crossing the cut and the dialog could"
                + " not be confirmed (no OK button); it was cancelled instead, so the split was"
                + " abandoned. Nothing about the notes was changed."
        default:
            let meaning = notesCrossingChoices[answer ?? ""] ?? ""
            return "Logic asked what to do with the notes crossing the cut and this answered"
                + " '\(answer ?? "?")': \(meaning). " + tail
        }
    }

    /// Answers the modal. `choice` nil presses Cancel, which abandons the
    /// split — the safe answer when a caller cannot say what it wants.
    /// Returns what it pressed, or nil when no dialog was up.
    @discardableResult
    func answerNotesCrossingSplit(choice: String?) -> String? {
        guard let dialog = notesCrossingSplitDialog() else { return nil }
        let buttons = children(of: dialog)
        func button(_ role: String, _ title: String) -> AXUIElement? {
            buttons.first {
                stringAttribute($0, kAXRoleAttribute as String) == role
                    && stringAttribute($0, kAXTitleAttribute as String)
                        .caseInsensitiveCompare(title) == .orderedSame
            }
        }
        // The two universal answers are addressed structurally
        // (`AXDefaultButton` / `AXCancelButton`) with the English titles as
        // fallback; the three RADIOS keep their English titles, because
        // `keep` / `shorten` / `split` are also this tool's own argument
        // values and pressing the wrong one silently cuts the notes the other
        // way — there is no structural way to tell them apart, and order is
        // not a guarantee worth a musical result.
        let cancelAnswer = cancelButton(of: dialog) ?? button("AXButton", LogicUIStrings.Button.cancel)
        guard let choice else {
            if let cancel = cancelAnswer {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.4)
            }
            return "cancel"
        }
        var radioPressed = false
        if let radio = button("AXRadioButton", choice) {
            radioPressed = AXUIElementPerformAction(radio, kAXPressAction as CFString) == .success
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let ok = defaultButton(of: dialog) ?? button("AXButton", LogicUIStrings.Button.ok) else {
            // No OK to press: the modal is still up and would block every
            // later tool. Cancel it (abandoning the split, which the region
            // count below then reports as a failure) rather than walking away
            // from an open dialog and calling it an answer.
            if let cancel = cancelAnswer {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.4)
            }
            return LogicAccessibility.notesCrossingUnanswered
        }
        _ = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.4)
        // Only a radio this code actually pressed may be reported as the
        // answer; otherwise Logic decided, and the result has to say so.
        return radioPressed ? choice.lowercased() : LogicAccessibility.notesCrossingLogicDefault
    }

    /// G24 / U3: the documented three-call split recipe as ONE verified call.
    ///
    /// The recipe was `logic_select_region` → `logic_set_playhead` →
    /// `logic_trigger_key_command {name: "Split Regions/Events at Playhead
    /// Position"}`, with three independent failure modes and no combined
    /// verification — so an agent could select the right region, park the
    /// playhead somewhere else, fire the command and be told three times that
    /// everything worked. Here the three steps share one verdict, and the
    /// arrangement map is the proof: two regions where one was.
    ///
    /// Since 2026-09-02 that proof is taken across EVERY rendered row rather
    /// than the target track's alone, and the exclusivity in front of Split is
    /// established rather than inferred. `Split Regions/Events at Playhead
    /// Position` cuts every SELECTED region at the playhead, project-wide, while
    /// the count this tool guarded on saw only the rows Logic had rendered — the
    /// blind spot `logic_delete_region` closed one door over, and on the same
    /// reference project (ten subtracks under a collapsed stack) a Split that
    /// also cut four regions off screen passed the guard and the after-check
    /// both. See `RegionEditGuard`.
    /// - Parameter trackNumber: addresses the ROW by number instead of
    ///   trusting the name to be unique (see `resolveRegionRow`).
    func splitRegion(
        trackName: String, regionName: String?, startBar: Int?,
        atBar: Int, atBeat: Int, notesCrossing: String, trackNumber: Int? = nil
    ) throws -> [String: Any] {
        guard LogicAccessibility.notesCrossingChoices[notesCrossing.lowercased()] != nil else {
            throw LogicianError.invalidArguments(
                "notes_crossing must be one of: "
                    + LogicAccessibility.notesCrossingChoices.keys.sorted().joined(separator: ", ")
            )
        }
        // A modal this call raised must never outlive it: an unanswered
        // "Notes Crossing Split Point" freezes every later tool, key commands
        // included, and the symptom is a string of "the command fired and
        // nothing happened" results with no hint of the cause.
        defer {
            if notesCrossingSplitDialog() != nil {
                _ = answerNotesCrossingSplit(choice: nil)
            }
        }
        // ONE walk for the target row's regions AND the project's rendered
        // region total, because the after-check needs both and the second one
        // is what makes "two regions where one was" a claim about the project
        // instead of about one track.
        let census = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
        let before = census.targetRegions
        // Identify the region WITHOUT selecting it yet: the playhead has to be
        // parked first (see below), and parking touches the control bar, which
        // takes the keyboard focus away from the Tracks area — a Split fired
        // in that state does nothing at all (measured 2026-08-28: select,
        // park, split left the arrangement map unchanged). The selection stays
        // LAST for that reason, and since 2026-09-01 it also carries
        // `forKeyCommand: true`, which PROVES the Tracks area holds the focus
        // instead of hoping the ordering implied it (see `TracksAreaFocus`).
        let candidates = before.filter { entry in
            if let regionName,
               !RegionNameAnnotation.matches(
                   name: (entry["name"] as? String) ?? "", request: regionName
               ) {
                return false
            }
            if let startBar, entry["start_bar"] as? Int != startBar { return false }
            return true
        }
        guard let selection = candidates.first else {
            throw LogicianError.trackNotExposed(
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar)
                    + " on '\(trackName)'",
                exposed: "that row holds: "
                    + (before.isEmpty
                        ? "no regions"
                        : RegionAddressing.candidates(before).joined(separator: ", "))
                    + ". Nothing was split. A region's start_bar changes with every edit, so"
                    + " re-read logic_list_regions rather than reusing an earlier one"
            )
        }
        guard candidates.count == 1 else {
            throw LogicianError.regionAmbiguous(
                track: trackName,
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar),
                candidates: RegionAddressing.candidates(candidates)
            )
        }
        // FAILURE MODE 1: a split point outside the region. Logic would
        // silently do nothing (or split a neighbour, if one is selected too),
        // and the arrangement map would look untouched — so it is refused
        // BEFORE the playhead moves and before anything fires.
        let regionStart = selection["start_bar"] as? Int
        let regionEnd = selection["end_bar"] as? Int
        if let regionStart, let regionEnd, !(atBar >= regionStart && atBar < regionEnd) {
            throw LogicianError.currentValueMismatch(
                expected: "a split point inside '\(selection["name"] ?? "?")' (bars \(regionStart)-\(regionEnd))",
                actual: "bar \(atBar), which is outside it. Nothing was moved, nothing was split."
            )
        }
        if let regionStart, atBar == regionStart, atBeat <= 1 {
            throw LogicianError.currentValueMismatch(
                expected: "a split point after the region's first beat",
                actual: "bar \(atBar) beat \(atBeat) is the region's own start; splitting there produces nothing. Nothing was moved."
            )
        }
        // FAILURE MODE 0, and it is checked LAST of the pre-write three because
        // it costs a track-header walk the cheap argument refusals above do not:
        // whether this call can honestly claim the selection it is about to make
        // is the project's. It still comes before the park, which is the first
        // thing here that changes anything at all.
        let (coverage, plan) = try regionEditPlan(.split, regionRowNumbers: census.rowNumbers)
        // FAILURE MODE 2: the playhead not landing where it was asked to.
        // `setPlayhead` verifies bar and beat and stops there; the sub-beat
        // fields it never touched can leave the playhead most of a beat late,
        // which for a split is a wrong cut rather than a rounding error.
        let parked = try parkPlayheadOnGrid(bar: atBar, beat: atBeat)
        guard (parked["bar"] as? Int) == atBar, (parked["beat"] as? Int) == atBeat else {
            throw LogicianError.verificationFailed(
                requested: "the playhead at bar \(atBar) beat \(atBeat)",
                actual: "bar \(parked["bar"] ?? "?") beat \(parked["beat"] ?? "?"); nothing was split",
                restored: false
            )
        }
        // Selection LAST, for the focus reason above, and exclusive PROJECT-WIDE
        // where Logic's own Deselect All is available: Split cuts every selected
        // region, and the count this used to guard on could not see the rows
        // Logic had not rendered. The clear also re-proves the Tracks-area
        // keyboard focus the park just spent, which is the failure mode the
        // ordering comment above exists for.
        let exclusive = try establishExclusiveRegionSelection(
            .split, plan: plan,
            trackName: trackName, regionName: selection["name"] as? String,
            startBar: selection["start_bar"] as? Int, trackNumber: trackNumber
        )
        let anchor = exclusive.anchor
        try fireKeyCommand(KeyCommandRegistry.Name.splitRegionsAtPlayhead)

        // A MIDI region whose notes cross the cut raises a modal before
        // anything is split. Answer it deterministically with the caller's
        // choice; an AUDIO region (or a cut that no note crosses) raises
        // nothing, and the result says which happened.
        var dialogAnswer: String?
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.2)
            if notesCrossingSplitDialog() != nil {
                dialogAnswer = answerNotesCrossingSplit(choice: notesCrossing.lowercased())
                break
            }
            if (try? regionSnapshot(trackName: trackName, trackNumber: trackNumber))?
                .count ?? 0 > before.count { break }
        }

        // FAILURE MODE 3: the command fired and nothing happened. The
        // arrangement map is the only evidence that counts — and it is read
        // across EVERY rendered row, not the target track's, because a Split
        // that also cut three regions on other rows leaves the target track
        // showing exactly the two this check used to ask for.
        var afterCensus = census
        var verdict = RegionEditGuard.DeltaVerdict.pending
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.35)
            afterCensus = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
            verdict = RegionEditGuard.delta(
                expected: 1, before: census.totalRegions, after: afterCensus.totalRegions
            )
            if verdict != .pending { break }
        }
        let after = afterCensus.targetRegions
        switch verdict {
        case .asExpected:
            break
        case .pending:
            throw LogicianError.verificationFailed(
                requested: "two regions where '\(selection["name"] ?? "?")' was",
                actual: "the track still shows \(after.count) region(s) and the project's rendered "
                    + "total is unchanged at \(afterCensus.totalRegions). Nothing was undone - "
                    + "if the split DID happen and only the map is stale, re-read logic_list_regions "
                    + "before firing Undo. "
                    + TracksAreaFocus.summary(inSelectionResult: anchor) + " "
                    + TracksAreaFocus.dialogSentence(modalWindowTitles()),
                restored: false
            )
        case .unexpected:
            throw LogicianError.verificationFailed(
                requested: "exactly one region split in two",
                actual: RegionEditGuard.unexpectedTotalSentence(
                    command: .split, expectedDelta: 1,
                    before: census.totalRegions, after: afterCensus.totalRegions
                ),
                restored: false
            )
        }
        let leftHalf = after.first { $0["start_bar"] as? Int == regionStart }
        let rightHalf = after.first { $0["start_bar"] as? Int == atBar && !isSame($0, leftHalf) }
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "split",
            "track": trackName, "track_name": trackName,
            "region": selection["name"] ?? "?",
            "at_bar": atBar, "at_beat": atBeat,
            "notes_crossing": dialogAnswer ?? "not_asked",
            "regions_before": before.count,
            "regions_after": after.count,
            "project_regions_before": census.totalRegions,
            "project_regions_after": afterCensus.totalRegions,
            "left": leftHalf ?? NSNull(),
            "right": rightHalf ?? NSNull(),
            "playhead_left_at": ["bar": atBar, "beat": atBeat],
            // `notesCrossingNote` already ends on the Undo-and-re-read tail, and
            // this note used to append a second copy of it verbatim - two
            // identical sentences in every successful split, which only became
            // visible once anything was written between them.
            "note": "Exactly one region became two: the region total across every rendered row "
                + "rose by exactly 1, not just the target track's. "
                + Self.exclusivityNote(scope: exclusive.scope, command: .split)
                + Self.notesCrossingNote(dialogAnswer, requested: notesCrossing.lowercased())
        ]
        result["playhead"] = parked
        annotateCoverage(coverage, in: &result)
        if let keyFocus = anchor["key_focus"] { result["key_focus"] = keyFocus }
        // An honest caveat rather than a silent wrong cut. Every one of these
        // APPENDS: this result can legitimately carry a scope caveat, an
        // off-grid cut and a missing right half at once, and the first
        // complaint written must not be the only one the agent reads.
        switch parked["on_grid"] as? Bool {
        case true:
            break
        case false:
            appendWarning(
                "The playhead did NOT land exactly on bar \(atBar) beat \(atBeat) "
                    + "(the MCU position display still shows division \(parked["timecode_division"] ?? "?"), "
                    + "tick \(parked["timecode_ticks"] ?? "?")), so the cut sits inside the beat. "
                    + "Listen across the seam, or Undo and try again.",
                to: &result
            )
            result["verified"] = false
        default:
            appendWarning(
                "Whether the cut landed exactly on the beat is UNVERIFIED: the MCU "
                    + "position display could not be read, and the control bar publishes bars and beats "
                    + "only — it cannot see a sub-beat offset. The playhead was rewound to the project "
                    + "start before stepping, which is what makes the position exact; that it is exact "
                    + "was not observed.",
                to: &result
            )
        }
        if rightHalf == nil {
            appendWarning(
                "A region count of \(after.count) proves the split happened, but no region starts "
                    + "at bar \(atBar) in the map — Logic reports whole bars and beats only, so a split "
                    + "inside a bar shows up on the bar it falls in. Read logic_list_regions for the truth.",
                to: &result
            )
        }
        if dialogAnswer == LogicAccessibility.notesCrossingLogicDefault {
            appendWarning(
                "NOTES_CROSSING NOT APPLIED: the split happened, but the dialog published no"
                    + " '\(notesCrossing.lowercased())' option, so it was confirmed with Logic's"
                    + " own selection and the crossing notes may have been treated differently"
                    + " from what you asked. Read the two halves back with logic_list_events.",
                to: &result
            )
        }
        exclusive.decorate(&result)
        return result
    }

    // MARK: - Multi-region selection (G26)

    /// The learned command behind each selection mode, with what it means.
    /// The names are Logic 12.3.1's own, read out of the Key Commands window
    /// on 2026-08-28 — `Select All Following of Same Track/Pitch` and
    /// `Select All Regions/Cells of Same Track` are not what anyone would
    /// guess, which is exactly why `logic_learn_key_command`'s not_found lists
    /// the real rows.
    static let regionSelectionCommands: [String: (command: String, meaning: String)] = [
        "track": (
            KeyCommandRegistry.Name.selectAllRegionsOfSameTrack,
            "every region on the same track as the anchor region"
        ),
        "following": (
            KeyCommandRegistry.Name.selectAllFollowing,
            "the anchor region and everything that starts after it, on EVERY track"
        ),
        "following_same_track": (
            KeyCommandRegistry.Name.selectAllFollowingOfSameTrack,
            "the anchor region and everything after it on that track only"
        ),
        "all": (
            KeyCommandRegistry.Name.selectAll,
            "every region in the project"
        ),
        "none": (
            KeyCommandRegistry.Name.deselectAll,
            "nothing - clears the selection"
        )
    ]

    /// What a selection command's own goal was, and how the result says it
    /// landed.
    ///
    /// Pure, so the contract is pinned by tests rather than by a live Logic —
    /// and because the poll's break condition and the reported `state` have to
    /// be ONE judgement. They were not: the poll broke on "the count moved at
    /// all" while `state` was written `expectedChange ? "selected" :
    /// "unchanged"` for every mode, so a `mode: "none"` that correctly cleared
    /// three regions came back `state: "selected"` with `selected_count: 0`
    /// (measured 2026-09-02, 6 of 6 live calls) and a caller branching on
    /// `state` read a clean deselection as a selection.
    struct MultiRegionSelectionVerdict: Equatable {
        let success: Bool
        let state: String
    }

    static func multiRegionSelectionVerdict(
        mode: String, before: Int, after: Int
    ) -> MultiRegionSelectionVerdict {
        guard mode == "none" else {
            // More than there were, or more than one: the anchor pass leaves
            // exactly one selected, so "still 1" is the shape of a command
            // that did nothing.
            let selected = after > before || after > 1
            return MultiRegionSelectionVerdict(
                success: selected, state: selected ? "selected" : "unchanged"
            )
        }
        guard after == 0 else {
            return MultiRegionSelectionVerdict(success: false, state: "unchanged")
        }
        // A selection that was empty before the command is a verified no-op,
        // not a clear that happened — `already_clear` says so the way every
        // other no-op in this server does.
        return MultiRegionSelectionVerdict(
            success: true, state: before == 0 ? "already_clear" : "cleared"
        )
    }

    /// Why a selection command changed nothing, in the direction the mode was
    /// actually asked to move. "Nothing more to select" was said to a
    /// `mode: "none"` call as well, which had asked for the opposite.
    static func multiRegionSelectionFailure(
        mode: String, before: Int, after: Int, focusSentence: String?
    ) -> String {
        let lead = mode == "none"
            ? "The selection did not clear (\(before) -> \(after) still selected on the rendered "
                + "rows). Either 'Deselect All' is not bound in this Logic (check "
                + "logic_list_key_commands), or it fired at a part of Logic other than the "
                + "Tracks area."
            : "The selection count did not move (\(before) -> \(after)). Either the command is "
                + "not bound in this Logic (check logic_list_key_commands), or there genuinely "
                + "was nothing more to select."
        return lead + (focusSentence.map { " " + $0 } ?? "") + " Nothing was edited."
    }

    /// Selects MORE than one region, by anchoring on one and firing a learned
    /// Logic selection command. The count is the proof: `selectedRegionCount()`
    /// is read before and after, and a mode that changed nothing is reported
    /// as `success: false` rather than as a selection that silently stayed at
    /// one region.
    ///
    /// The anchor matters and is not optional for the relative modes: Logic's
    /// selection commands all act on what is currently selected, so this
    /// selects the anchor exclusively first — the same primitive the region
    /// edits already guard on.
    ///
    /// `all` and `none` have no anchor, and until 2026-09-02 that also meant no
    /// Tracks-area focus probe at all — the only two paths in the region family
    /// without one, and the two that could not even NAME the missing focus in
    /// their failure, because the sentence hung off the anchor. They now take
    /// the anchorless probe (`ensureTracksAreaKeyFocus()`, which repairs
    /// against whatever track is already selected) and carry `key_focus` like
    /// every other mode.
    ///
    /// The after-count looks BEFORE it waits: measured 2026-09-02, the old
    /// loop's blind 0.25 s sleep preceded a count that had already moved in 8
    /// of 8 samples — 250 ms of dead time on every call, and 2.0 s on a mode
    /// with nothing to do.
    /// - Parameter trackNumber: addresses the anchor's ROW by number instead
    ///   of trusting the name to be unique (see `resolveRegionRow`).
    func selectRegions(
        mode: String, trackName: String?, regionName: String?, startBar: Int?,
        trackNumber: Int? = nil
    ) throws -> [String: Any] {
        guard let entry = LogicAccessibility.regionSelectionCommands[mode] else {
            throw LogicianError.invalidArguments(
                "unknown mode '\(mode)'; use one of: "
                    + LogicAccessibility.regionSelectionCommands.keys.sorted().joined(separator: ", ")
            )
        }
        var anchor: [String: Any]?
        var anchorlessFocus: TracksAreaFocus.Outcome?
        if mode != "all" && mode != "none" {
            guard let trackName else {
                throw LogicianError.invalidArguments(
                    "mode '\(mode)' needs an anchor: pass track_name (and region_name and/or "
                        + "start_bar when the track holds more than one region)"
                )
            }
            // ONE walk, handed to both readers of it. `regionSnapshot` used to
            // walk the arrangement and `selectRegion` walk the same tree again
            // 60 ms later with nothing written in between — the fold
            // `logic_move_region` and `logic_rename_region` already took, worth
            // 55-60 ms on every anchored call (measured 2026-09-02).
            let rows = try regionRows()
            let regions = try regionSnapshot(
                trackName: trackName, trackNumber: trackNumber, alreadyWalkedRows: rows
            )
            // One region on the track needs no further identification; more
            // than one and the caller has to say which, exactly as
            // mode 'region' requires.
            if regionName == nil && startBar == nil && regions.count == 1 {
                anchor = try selectRegion(
                    trackName: trackName, regionName: regions[0]["name"] as? String,
                    startBar: regions[0]["start_bar"] as? Int, exclusive: true,
                    trackNumber: trackNumber, forKeyCommand: true, alreadyWalkedRows: rows
                )
            } else {
                anchor = try selectRegion(
                    trackName: trackName, regionName: regionName,
                    startBar: startBar, exclusive: true,
                    trackNumber: trackNumber, forKeyCommand: true, alreadyWalkedRows: rows
                )
            }
        } else {
            // `all` and `none` have no anchor to carry the focus probe, and
            // used to fire with the one precondition every sibling command
            // checks neither established nor reported. See
            // `ensureTracksAreaKeyFocus()`.
            anchorlessFocus = ensureTracksAreaKeyFocus()
        }
        let before = try selectedRegionCount()
        let wasRegistered = KeyCommandRegistry.note(named: entry.command) != nil
        try fireKeyCommand(
            entry.command, learnIfMissing: true, source: "logic_select_regions"
        )
        // LOOK FIRST. The loop this replaces slept 0.25 s before it ever
        // counted, and the count had already moved on the first look in 8 of 8
        // live samples, every mode (measured 2026-09-02) — 250 ms of dead time
        // on every successful call, 55% of a `mode: "none"`. The key command is
        // a synchronous MCU-note trigger (40-50 ms), so the budget is here for
        // the genuinely slow case and nothing else, and a mode whose goal is
        // ALREADY met — `none` on an empty selection, `all` on a fully selected
        // project — now costs one count instead of the old 8 x 0.25 s = 2.0 s.
        var after = try selectedRegionCount()
        let deadline = Date().addingTimeInterval(0.4)
        while !LogicAccessibility.multiRegionSelectionVerdict(
            mode: mode, before: before, after: after
        ).success, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
            after = try selectedRegionCount()
        }
        let verdict = LogicAccessibility.multiRegionSelectionVerdict(
            mode: mode, before: before, after: after
        )
        let expectedChange = verdict.success
        var result: [String: Any] = [
            "success": expectedChange,
            "verified": expectedChange,
            "state": verdict.state,
            "mode": mode,
            "command": entry.command,
            "means": entry.meaning,
            "selected_before": before,
            "selected_count": after,
            "note": "The count is read off the arrangement map's own selection state, and it counts "
                + "regions on VISIBLE track rows only - a scrolled-out track's regions can be "
                + "selected and uncounted (logic_list_regions has the same limit). A following edit "
                + "command acts on ALL of them."
        ]
        if !wasRegistered {
            result["learned_key_command"] = entry.command
            result["learned_note"] = KeyCommandRegistry.note(named: entry.command)?.note ?? NSNull()
            result["consent_note"] = "'\(entry.command)' was not in the key command registry, so it "
                + "was LEARNED into the user's own Logic key command set to run this call (additive, "
                + "removable in the Key Commands window; logic_list_key_commands shows it)."
        }
        if let anchor {
            result["anchor"] = [
                "track_name": anchor["track_name"] ?? NSNull(),
                "region": anchor["name"] ?? NSNull(),
                "start_bar": anchor["start_bar"] ?? NSNull()
            ]
        }
        if let anchor, let keyFocus = anchor["key_focus"] {
            result["key_focus"] = keyFocus
        } else if let anchorlessFocus {
            result["key_focus"] = anchorlessFocus.dictionary
        }
        if !expectedChange {
            // The focus sentence, whichever way this call came by one — the
            // anchored modes carry it inside the selection they took, `all` and
            // `none` in their own probe. It used to be attached only when an
            // anchor existed, which is never for the two modes that cannot
            // establish the focus in the first place.
            let focusSentence = anchor.map { TracksAreaFocus.summary(inSelectionResult: $0) }
                ?? anchorlessFocus?.summary
            result["note"] = LogicAccessibility.multiRegionSelectionFailure(
                mode: mode, before: before, after: after, focusSentence: focusSentence
            )
        }
        return result
    }

    /// Same region entry? Compared on the two fields the map guarantees;
    /// regions have no stable identity (COVERAGE U8), so this is deliberately
    /// only used to keep the two halves apart from each other.
    private func isSame(_ lhs: [String: Any], _ rhs: [String: Any]?) -> Bool {
        guard let rhs else { return false }
        return (lhs["name"] as? String) == (rhs["name"] as? String)
            && (lhs["start_bar"] as? Int) == (rhs["start_bar"] as? Int)
    }

    /// Nudges ONE region — and the "one" is established, not hoped for.
    ///
    /// Logic's `Nudge Region/Event Position …` moves every SELECTED region,
    /// project-wide. This guarded on a count over `regionRows()`, which sees
    /// only the rows Logic has RENDERED, and then claimed `restored: true` on a
    /// refusal taken AFTER `selectRegion` had already cleared every other
    /// region's selection — both the same fictions `logic_delete_region` gave
    /// up on 2026-09-01. Exclusivity now comes from Logic's own project-wide
    /// `Deselect All`, proven to have landed; see `RegionEditGuard`.
    /// WHAT IT VERIFIES, since 2026-09-02: the region's bar AND its beat
    /// against the arrangement map, every time — the old check was gated on
    /// `byBeats == 0` and there was no beat check anywhere, so a beat nudge
    /// that did nothing came back `verified: true` and one beat switched the
    /// bar comparison off as well. Plus the target row's other regions, span
    /// for span, because Logic TRIMS whatever a nudged region is laid over and
    /// a trim leaves the region total untouched. Both checks read evidence this
    /// call already holds; see `RegionEditGuard.nudgeVerdict` and
    /// `neighbourVerdict`.
    ///
    /// - Parameter trackNumber: addresses the ROW by number instead of
    ///   trusting the name to be unique (see `resolveRegionRow`).
    func moveRegion(
        trackName: String, regionName: String?, startBar: Int?,
        byBars: Int, byBeats: Int, trackNumber: Int? = nil
    ) throws -> [String: Any] {
        guard byBars != 0 || byBeats != 0 else {
            throw LogicianError.invalidArguments("pass a non-zero by_bars and/or by_beats")
        }
        // Before any write, so the refusal can say the project is untouched.
        let before = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
        let (coverage, plan) = try regionEditPlan(.nudge, regionRowNumbers: before.rowNumbers)
        let exclusive = try establishExclusiveRegionSelection(
            .nudge, plan: plan,
            trackName: trackName, regionName: regionName, startBar: startBar,
            trackNumber: trackNumber,
            // The census above walked the arrangement 53 ms ago and NOTHING has
            // been written since (`regionEditPlan` is two reads), so the anchor
            // pass gets those rows instead of walking the same tree again:
            // -55 to -60 ms of the 386 ms this call used to spend on six walks
            // of one tree. The reselect pass inside deliberately walks fresh —
            // it comes after `Deselect All` has written to every rendered row,
            // which is exactly the staleness this family got burned by.
            alreadyWalkedRows: before.rows
        )
        let selection = exclusive.region
        let movedName = selection["name"] as? String
        let oldStart = selection["start_bar"] as? Int ?? 0
        // Beat 1 when the map published none: `parseRegion` omits `start_beat`
        // on the bar line, and reading absent as "unknown" is what left the
        // beat unverified in the first place.
        let oldBeat = selection["start_beat"] as? Int ?? 1
        func targetRegion(in census: ArrangementCensus) -> [String: Any]? {
            census.targetRegions.first {
                ($0["name"] as? String) == movedName && ($0["selected"] as? Bool) == true
            }
        }
        func position(of region: [String: Any]) -> (bar: Int, beat: Int)? {
            guard let bar = region["start_bar"] as? Int else { return nil }
            return (bar, region["start_beat"] as? Int ?? 1)
        }
        let commands =
            Array(
                repeating: byBars > 0
                    ? KeyCommandRegistry.Name.nudgeRightByBar
                    : KeyCommandRegistry.Name.nudgeLeftByBar,
                count: abs(byBars)
            )
            + Array(
                repeating: byBeats > 0
                    ? KeyCommandRegistry.Name.nudgeRightByBeat
                    : KeyCommandRegistry.Name.nudgeLeftByBeat,
                count: abs(byBeats)
            )
        // PACE BY THE EFFECT, not by the clock. This loop used to sleep 0.15 s
        // blind after every step: profiled 2026-09-02, that was 72% of the
        // distance term (209 ms a step, of which 50 ms is the key command) and
        // 2.4 s of a 4.3 s sixteen-bar move. A census costs 60-105 ms and it is
        // VERIFICATION rather than waiting — every step is watched landing, and
        // the next one fires the moment it has. Measured the same day, the two
        // loops back to back on one region: 201 ms -> 154 ms a step, with the
        // effect readable on the FIRST look in 15 of 15 steps (1, 3, 4 and 7
        // step moves). The 0.15 s stays as the BUDGET for a step whose effect
        // is not readable — a nudge Logic clamps at the project start moves
        // nothing at all — so the worst case is about what every step used to
        // cost.
        var latest = before
        var lastSeen = (bar: oldStart, beat: oldBeat)
        var stepsConfirmed = 0
        for command in commands {
            try fireKeyCommand(command)
            let stepDeadline = Date().addingTimeInterval(0.15)
            step: while true {
                latest = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
                if let here = targetRegion(in: latest).flatMap(position), here != lastSeen {
                    lastSeen = here
                    stepsConfirmed += 1
                    break step
                }
                if Date() >= stepDeadline { break step }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        // No blind sleep here either. The 0.4 s that used to sit between the
        // last Nudge and the census below was 411 ms — 36% of a short move —
        // and it was pure waiting on every success: measured 2026-09-02 with a
        // probe taken immediately after the last Nudge, the region was already
        // at its new bar and still selected on the FIRST census in 8 of 8
        // runs. Same fix as `copyRegion`'s paste wait and `deleteRegion`'s
        // delete wait. The last step's own census IS the look, so the poll
        // below only runs when the move has not been proven yet.
        //
        // BOTH TERMS ARE CHECKED, always. This used to gate its only positional
        // check on `byBeats == 0`, so a beat nudge was verified by nothing but
        // "the region exists and is still selected" and a mixed bar+beat nudge
        // switched the exact bar comparison off as well — see
        // `RegionEditGuard.nudgeVerdict`, which also explains why the project's
        // meter is not read to do it.
        var verdict = RegionEditGuard.NudgeVerdict.unmoved
        var found: [String: Any]?
        let deadline = Date().addingTimeInterval(2.0)
        poll: while true {
            found = targetRegion(in: latest)
            if let here = found, let at = position(of: here) {
                verdict = RegionEditGuard.nudgeVerdict(
                    byBars: byBars, byBeats: byBeats,
                    fromBar: oldStart, fromBeat: oldBeat, toBar: at.bar, toBeat: at.beat
                )
                switch verdict {
                case .exact, .carried: break poll
                case .unmoved, .wrongPosition: break
                }
            }
            if Date() >= deadline { break poll }
            Thread.sleep(forTimeInterval: 0.05)
            latest = try arrangementCensus(trackName: trackName, trackNumber: trackNumber)
        }
        let after = latest
        guard let moved = found else {
            throw LogicianError.verificationFailed(
                requested: "the moved region still selected at its new position",
                actual: "could not find it in the arrangement map",
                restored: false
            )
        }
        guard let landed = position(of: moved) else {
            throw LogicianError.verificationFailed(
                requested: "where the nudge left '\(movedName ?? "?")'",
                actual: "the region is there and still selected, but Logic published no start bar "
                    + "for it, so where it ended up cannot be proven. Read logic_list_regions",
                restored: false
            )
        }
        let requested = "'\(movedName ?? "?")' "
            + RegionEditGuard.nudgeRequestSentence(byBars: byBars, byBeats: byBeats)
            + " from bar \(oldStart) beat \(oldBeat)"
        switch verdict {
        case .exact, .carried:
            break
        case .unmoved:
            throw LogicianError.verificationFailed(
                requested: requested,
                actual: RegionEditGuard.nudgeSentence(
                    verdict: verdict, byBars: byBars, byBeats: byBeats,
                    fromBar: oldStart, fromBeat: oldBeat, toBar: landed.bar, toBeat: landed.beat
                )
                    // What a Nudge fired without Tracks-area keyboard focus
                    // looks like every time (measured 2026-09-01: by_bars: 1
                    // reported "requested bar 42, found bar 41" three times in
                    // a row while the focus sat on the control bar).
                    + " " + TracksAreaFocus.summary(inSelectionResult: selection)
                    + " " + TracksAreaFocus.dialogSentence(modalWindowTitles()),
                restored: false
            )
        case .wrongPosition:
            throw LogicianError.verificationFailed(
                requested: requested,
                actual: RegionEditGuard.nudgeSentence(
                    verdict: verdict, byBars: byBars, byBeats: byBeats,
                    fromBar: oldStart, fromBeat: oldBeat, toBar: landed.bar, toBeat: landed.beat
                ),
                restored: false
            )
        }
        // A Nudge moves regions; it never creates or destroys one. A rendered
        // total that moved therefore means either that the Nudge reached a
        // region this call never named, or that the move overlaid a neighbour
        // completely and Logic swallowed it — the second of which this tool's
        // own description warns about, and neither of which may come back as a
        // clean success. What the count CANNOT see is a second selected region
        // that moved without landing on anything; the project-wide clear above
        // is what covers that, and this is the backstop under it.
        if case .unexpected = RegionEditGuard.delta(
            expected: 0, before: before.totalRegions, after: after.totalRegions
        ) {
            throw LogicianError.verificationFailed(
                requested: "one region moved and no region gained or lost",
                actual: RegionEditGuard.unexpectedTotalSentence(
                    command: .nudge, expectedDelta: 0,
                    before: before.totalRegions, after: after.totalRegions
                ),
                restored: false
            )
        }
        // And what the count cannot see AT ALL is the likelier damage: Logic
        // TRIMS whatever a nudged region is laid over, so the neighbour that
        // was there loses the overlapped part — its start or end moves and the
        // region total does not budge. Both snapshots of the row are already in
        // hand, so comparing the SPANS either side of the nudge costs no AX
        // work whatever, and it is the change being verified rather than the
        // container it happened in.
        var trimWarning: String?
        switch RegionEditGuard.neighbourVerdict(
            before: before.targetRegions, after: after.targetRegions,
            movedBefore: selection, movedAfter: moved
        ) {
        case .untouched:
            break
        case .changed(let lost, let gained):
            throw LogicianError.verificationFailed(
                requested: "'\(movedName ?? "?")' moved and every other region on the row left "
                    + "exactly where it was",
                actual: RegionEditGuard.neighbourSentence(lost: lost, gained: gained),
                restored: false
            )
        case .unreadable(let unreadableBefore, let unreadableAfter):
            trimWarning = "Whether the nudge trimmed a neighbour could not be checked: "
                + "\(unreadableBefore) region(s) on this row published no position before the "
                + "nudge and \(unreadableAfter) afterwards, so the two span lists are not "
                + "comparable. The region total is unchanged, which rules out a neighbour "
                + "swallowed whole but not one trimmed. Read logic_list_regions."
        }
        // The moved region's OWN length, from the same free evidence: whatever
        // the nudge did to its start it must have done to its end. Only when
        // Logic actually published an end either side — `end_bar` defaulted to
        // the start bar would make every beat nudge look like a trim.
        if selection["end_bar"] != nil, moved["end_bar"] != nil,
           let spanBefore = RegionEditGuard.Span(selection),
           let spanAfter = RegionEditGuard.Span(moved),
           !RegionEditGuard.nudgeLengthKept(before: spanBefore, after: spanAfter) {
            throw LogicianError.verificationFailed(
                requested: "'\(movedName ?? "?")' moved at the length it had",
                actual: "it went from \(spanBefore.sentence) to \(spanAfter.sentence): its end did "
                    + "not travel with its start, so the region itself was trimmed by what it "
                    + "landed on. Undo puts it back one nudge at a time; read logic_list_regions "
                    + "before anything else",
                restored: false
            )
        }
        var note = "Verified against the arrangement map in BOTH terms: "
        note += "'\(movedName ?? "?")' is at bar \(landed.bar) beat \(landed.beat), which is "
        note += RegionEditGuard.nudgeRequestSentence(byBars: byBars, byBeats: byBeats)
        note += " from bar \(oldStart) beat \(oldBeat)"
        note += verdict == .exact ? ". " : ", carrying across the bar line. "
        if trimWarning == nil {
            note += "Every other region on the row is where it was, span for span - a nudged "
            note += "region TRIMS what it overlays, and that is checked here, not just the region "
            note += "total (unchanged at \(after.totalRegions) across every rendered row). "
        }
        note += Self.exclusivityNote(scope: exclusive.scope, command: .nudge)
        note += "Relative: a repeat moves again. Undo puts it back."
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "moved",
            "track": trackName, "track_name": trackName,
            "region": selection["name"] ?? "?",
            "from_bar": oldStart,
            // Published beside `from_bar` because a caller could not check a
            // beat move without it — the whole reason a beat nudge that did
            // nothing used to read as a success.
            "from_beat": oldBeat,
            "to_bar": landed.bar,
            "to_beat": landed.beat,
            "nudges_fired": commands.count,
            // How many steps were watched landing rather than waited out. Each
            // one is a positional read taken between key commands, so a number
            // short of `nudges_fired` on a call that verified means the map was
            // slow, not that a nudge went missing.
            "nudges_confirmed": stepsConfirmed,
            "project_regions_before": before.totalRegions,
            "project_regions_after": after.totalRegions,
            "note": note
        ]
        if case .carried(let beatsPerBar) = verdict {
            // Named as INFERRED, because it is: the meter that makes this move
            // add up, not one read from Logic. See `nudgeVerdict`.
            result["bar_line_carry"] = ["beats_per_bar_inferred": beatsPerBar]
        }
        exclusive.decorate(&result)
        if let trimWarning { appendWarning(trimWarning, to: &result) }
        annotateCoverage(coverage, in: &result)
        if let keyFocus = exclusive.anchor["key_focus"] { result["key_focus"] = keyFocus }
        return result
    }

    /// Copies (or, with `move`, Cuts and Pastes) ONE region — and the "one" is
    /// established, not hoped for.
    ///
    /// Logic's `Cut` removes every SELECTED region project-wide and `Copy` puts
    /// every one of them on the clipboard for `Paste` to put back down. This
    /// guarded on a count over `regionRows()`, which sees only the rows Logic
    /// has RENDERED, and then claimed `restored: true` on a refusal taken AFTER
    /// `selectRegion` had already cleared every other region's selection — both
    /// the same fictions `logic_delete_region` gave up on 2026-09-01. `move:
    /// true` made it the more dangerous of the two, because a Cut that reached
    /// a hidden row removed a region the Paste never put back. Exclusivity now
    /// comes from Logic's own project-wide `Deselect All`, proven to have
    /// landed; see `RegionEditGuard`.
    ///
    /// - Parameters:
    ///   - fromTrackNumber: addresses the SOURCE row by number instead of by
    ///     name (duplicate track names; see `selectRegion`).
    ///   - toTrackNumber: the same for the DESTINATION row.
    func copyRegion(
        trackName: String, regionName: String?, startBar: Int?,
        toBar: Int, toTrack: String?, move: Bool,
        fromTrackNumber: Int? = nil, toTrackNumber: Int? = nil
    ) throws -> [String: Any] {
        let command: RegionEditGuard.Command = move ? .cut : .copy
        // The count baseline is taken BEFORE the Cut, and before any write at
        // all, so the refusal below can honestly say the project is untouched.
        let before = try arrangementCensus(
            trackName: trackName, trackNumber: fromTrackNumber
        )
        let (coverage, plan) = try regionEditPlan(command, regionRowNumbers: before.rowNumbers)
        let exclusive = try establishExclusiveRegionSelection(
            command, plan: plan,
            trackName: trackName, regionName: regionName, startBar: startBar,
            trackNumber: fromTrackNumber
        )
        let selection = exclusive.region
        try fireKeyCommand(move ? KeyCommandRegistry.Name.cut : KeyCommandRegistry.Name.copy)
        // No sleep here. The clipboard is not readable, so a wait for it can
        // never be verified — but it does not need one either: measured
        // 2026-09-01, between this command and the Paste below there is ALWAYS
        // 0.9-5 s of unrelated Accessibility work (the destination track
        // selection 205-294 ms, the playhead park 251-4 901 ms, the pre-Paste
        // snapshot 103-683 ms). The 0.4 s blind sleep that used to sit here
        // was 16% of every call and bought nothing the park does not already
        // buy.
        let destinationTrack = toTrack ?? trackName
        let destinationNumber = toTrack == nil ? fromTrackNumber : toTrackNumber
        // ALWAYS select the destination — including the same-track case.
        // Paste lands on the SELECTED TRACK, and selecting a REGION does not
        // select its track: measured 2026-08-28, a copy of 'Crash' (track
        // "Crash") to bar 60 with no to_track landed on "Bas", the track that
        // happened to be selected, and the verification then reported
        // "nothing appeared there" while a region had in fact been created on
        // someone else's track. A wrong-track write that reports failure is
        // the worst shape a bug can have.
        _ = try selectTrack(
            trackName: destinationTrack, trackNumber: destinationNumber, expectedProjectPath: nil
        )
        // beat 1 explicitly, and `parkPlayheadOnGrid` rather than
        // `setPlayhead`, because PASTE LANDS AT THE PLAYHEAD EXACTLY and
        // `setPlayhead` only ever verifies whole bars and beats. Measured
        // 2026-09-01: after eight `setPlayhead(bar: N, beat: 1)` calls that
        // all reported `verified: true`, the MCU's own position display read
        // `N 1 3 81` every single time — bar N beat 1 division 3 tick 81,
        // roughly half a beat past the bar line — and a marker created at that
        // playhead landed at bar N BEAT 2. The region map reports whole bars,
        // so an off-grid paste read back as `verified: true` at the requested
        // bar: exactly the displaced-copy failure this tool's own note warns
        // agents about. `parkPlayheadOnGrid` rewinds to `1 1 1 1` first and
        // reads the sub-beat fields off the control surface afterwards, the
        // same mechanism `logic_split_region` and `logic_import_midi` already
        // use. It costs bar stepping from the project start (~126 ms per bar
        // until `convergeSlider` stops sleeping between writes) and it buys a
        // copy that lands where it says it does.
        let parked = try parkPlayheadOnGrid(bar: toBar, beat: 1)
        guard (parked["bar"] as? Int) == toBar, (parked["beat"] as? Int) == 1 else {
            throw LogicianError.verificationFailed(
                requested: "the playhead at bar \(toBar) beat 1",
                actual: "bar \(parked["bar"] ?? "?") beat \(parked["beat"] ?? "?"); nothing was "
                    + "pasted and the clipboard still holds the region",
                restored: false
            )
        }
        // REFUSE rather than paste off the grid. Nothing has been written to
        // the arrangement yet, so this costs the caller a retry; a paste half
        // a beat late costs them a displaced region they have to find first.
        if parked["on_grid"] as? Bool == false {
            throw LogicianError.verificationFailed(
                requested: "the playhead exactly on bar \(toBar) beat 1 before Paste",
                actual: "the position display still reads division "
                    + "\(parked["timecode_division"] ?? "?"), tick \(parked["timecode_ticks"] ?? "?"), "
                    + "so Paste would land inside the beat and the region map — which reports whole "
                    + "bars only — would call it bar \(toBar) anyway. Nothing was pasted",
                restored: false
            )
        }
        // The destination as it stands the instant BEFORE Paste — taken after
        // the Cut, so a same-track move already shows the source gone.
        //
        // "A region starts at toBar" is NOT evidence that this call put it
        // there: pasting onto a bar that was already occupied matched the very
        // first look and reported verified: true even if Paste never fired.
        // That is the exact shape of the failure the guide warns about — a
        // modal swallows the key command and nothing happens — so the proof
        // has to be that the destination gained a region, not that one is
        // present.
        //
        // The park just drove the control bar, so the keyboard focus is asked
        // for a SECOND time here, on the destination track: Paste acts on the
        // focused area exactly like Copy does. The probe costs a handful of
        // attribute reads when the focus is already right, and its verdict is
        // what the refusal below leads with when nothing lands.
        let pasteFocus = ensureTracksAreaKeyFocus(
            trackName: destinationTrack, trackNumber: destinationNumber
        )
        let destinationBefore = (try? arrangementCensus(
            trackName: destinationTrack, trackNumber: destinationNumber
        ))?.targetRegions ?? []
        let atBarBefore = destinationBefore.filter { $0["start_bar"] as? Int == toBar }
        try fireKeyCommand(KeyCommandRegistry.Name.paste)
        // Look BEFORE sleeping. Measured 2026-09-01 with a probe taken
        // immediately after the key command: the pasted region was already in
        // the arrangement map on the FIRST read in 5 of 5 successful calls,
        // i.e. the old loop's opening 0.4 s sleep was pure waiting on every
        // success. Polling at 50 ms after that keeps the failure path honest
        // and short: ten 0.4 s iterations cost 5.7 s to say "it did not land",
        // and nine of them only ever ran when the answer was already no.
        var pasted: [String: Any]?
        var afterCensus = before
        let deadline = Date().addingTimeInterval(2.0)
        repeat {
            afterCensus = try arrangementCensus(
                trackName: destinationTrack, trackNumber: destinationNumber
            )
            let after = afterCensus.targetRegions
            let atBar = after.filter { $0["start_bar"] as? Int == toBar }
            if after.count > destinationBefore.count || atBar.count > atBarBefore.count {
                // Prefer a region at toBar that was not there before; fall
                // back to any region at toBar once the count has proven
                // something landed.
                pasted = atBar.first { hit in !atBarBefore.contains { isSame($0, hit) } }
                    ?? atBar.first
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        guard let landed = pasted else {
            throw LogicianError.verificationFailed(
                requested: "a NEW region at bar \(toBar) on '\(destinationTrack)'",
                actual: TracksAreaFocus.pasteFailedReason(
                    toBar: toBar,
                    barAlreadyOccupied: destinationBefore.count == atBarBefore.count
                        && !atBarBefore.isEmpty,
                    focus: pasteFocus,
                    dialogTitles: modalWindowTitles()
                ),
                restored: false
            )
        }
        // A Copy+Paste adds exactly one region to the project; a Cut+Paste adds
        // none, because the one it removed is the one it put back. Any other
        // movement of the RENDERED total means either that Cut/Copy reached a
        // region this call never named, or that the Paste landed on top of one
        // and Logic swallowed it whole - the second of which this tool's own
        // description warns about, and neither of which may come back as a
        // clean success. The check is one subtraction on a walk the poll above
        // already paid for.
        let expectedDelta = move ? 0 : 1
        if RegionEditGuard.delta(
            expected: expectedDelta,
            before: before.totalRegions, after: afterCensus.totalRegions
        ) != .asExpected {
            throw LogicianError.verificationFailed(
                requested: move
                    ? "one region cut from '\(trackName)' and pasted onto '\(destinationTrack)'"
                    : "exactly one new region on '\(destinationTrack)'",
                actual: RegionEditGuard.unexpectedTotalSentence(
                    command: command, expectedDelta: expectedDelta,
                    before: before.totalRegions, after: afterCensus.totalRegions
                ) + " The region DID land at bar \(toBar).",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true, "verified": true,
            "state": move ? "moved_via_clipboard" : "copied",
            "region": selection["name"] ?? "?",
            "from": ["track": trackName, "track_name": trackName, "start_bar": selection["start_bar"] ?? NSNull()],
            "to": ["track": destinationTrack, "start_bar": landed["start_bar"] ?? toBar],
            "playhead": parked,
            "key_focus": pasteFocus.dictionary,
            "project_regions_before": before.totalRegions,
            "project_regions_after": afterCensus.totalRegions,
            "note": "Paste lands at the playhead on the selected track, and the playhead was parked on bar \(toBar) beat 1 with its sub-beat fields zeroed as well - `playhead.on_grid` is the control surface's own confirmation of that, and a false one refuses before Paste rather than pasting inside the beat. "
                + "The region total across every rendered row moved by exactly the amount this "
                + "call can produce ("
                + (move ? "+0: the one Cut took is the one Paste put back" : "+1")
                + "), so nothing else was " + (move ? "cut" : "copied")
                + " and nothing was overlaid out of existence. "
                + Self.exclusivityNote(scope: exclusive.scope, command: command)
        ]
        // BOTH focus verdicts, because they answer different questions: the
        // first says what state the call INHERITED (and whether the caller's
        // previous tool left the Tracks area focused), the second what Paste
        // actually fired into after the park had driven the control bar.
        if let focusAtCopy = exclusive.anchor["key_focus"] { result["key_focus_at_copy"] = focusAtCopy }
        if parked["on_grid"] as? Bool == nil {
            appendWarning(
                "Whether the paste landed exactly on the bar line is UNVERIFIED: "
                    + "the MCU position display could not be read, and the control bar publishes bars "
                    + "and beats only - it cannot see a sub-beat offset, and neither can the region "
                    + "map this result was verified against. "
                    + ((parked["on_grid_note"] as? String) ?? ""),
                to: &result
            )
        }
        exclusive.decorate(&result)
        annotateCoverage(coverage, in: &result)
        return result
    }

}
