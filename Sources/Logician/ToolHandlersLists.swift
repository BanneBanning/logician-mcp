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
        guard let events = read.events, let census = read.census else {
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
            // The LIST'S count, not the array's: a row Logic has published and
            // not drawn yet is a real event that cannot be read, and counting
            // the readable ones would report a region one note short of itself.
            "event_count": census.count,
            "columns": read.columns,
            "scope": "the SELECTED region (or the selected track's region at the playhead) — this"
                + " is what Logic's Event List shows, never the whole project. Select with"
                + " track_name/region_name/start_bar here, or with logic_select_region first.",
            "note": "Read out of View > List Editors > Event; the pane and the previously selected"
                + " tab are restored afterwards. Values are Logic's own cell texts, plus parsed"
                + " bar/beat/pitch/velocity/length where the columns were recognised."
        ]
        if let declared = census.declared { payload["declared_count"] = declared }
        // Logic's own answer to "which region is this?", read off the Event
        // tab's Region Path label.
        if let region = read.region, !region.isEmpty { payload["region"] = region }
        appendUnreadRowWarning(census, kind: "event", to: &payload)
        if truncated {
            payload["truncated"] = true
            payload["limit"] = limit
            appendWarning(
                "The list holds \(census.count) events and only the first \(limit) are in this"
                    + " result. Raise `limit`, or narrow the selection.",
                to: &payload
            )
        }
        if census.count == 0 {
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

    /// The one place a List Editors read admits that Logic counted rows it had
    /// not drawn — the reader's half of what `EventCensus` already does on
    /// every write, in the same words.
    ///
    /// It says all three things, because any one of them alone still misleads:
    /// how many the list holds (the count Logic declares), how many are in the
    /// payload, and WHICH row numbers are missing. Before this, a 26-note
    /// region came back as 26 entries of which one was blank, a real note was
    /// gone, and both counts agreed (measured 3/3, 2026-09-02).
    func appendUnreadRowWarning(
        _ census: ListEditorCensus, kind: String, to payload: inout [String: Any]
    ) {
        guard !census.isComplete else { return }
        payload["\(kind)s_read"] = census.entries.count
        payload["unreadable_rows"] = census.unread
        payload["unreadable_row_numbers"] = census.unreadRowNumbers
        appendWarning(
            census.unreadNote
                + " The list holds \(census.count) \(kind)(s) and \(census.entries.count) of them"
                + " could be read; row(s)"
                + " \(census.unreadRowNumbers.map(String.init).joined(separator: ", "))"
                + " are missing from this result and NOT from the project. A List Editors table"
                + " only draws the rows in view, so a list longer than the pane always answers"
                + " short: scroll it (or make the pane taller) and read again before concluding"
                + " that a \(kind) is not there.",
            to: &payload
        )
    }

    // MARK: - logic_edit_event (G18)

    func handleEditEvent(_ arguments: [String: Any]) throws -> Any {
        // ARGUMENTS FIRST, all of them. `selectRegion` below clears every other
        // region's selection and moves keyboard focus, so a refusal that ran
        // after it has already changed the user's project in order to say no.
        // `EventEditRequest` cannot reach the UI, which is what keeps the order
        // right (see its doc comment).
        let request = try EventEditRequest(arguments: arguments)
        let action = request.action
        let address = request.address
        let change = request.change
        // Now point the list at a region, exactly as logic_list_events does:
        // the Event List edits what it is SHOWING, so "fix this note in that
        // region" is two steps and the tool does both.
        var selection: [String: Any]?
        if let trackName = request.trackName {
            selection = try logic.selectRegion(
                trackName: trackName,
                regionName: request.regionName,
                startBar: request.startBar,
                exclusive: true
            )
        }
        if action == "create" {
            // This one reads the SELECTED region's bounds, so it belongs after
            // the selection and nowhere earlier.
            try refuseCreateOutsideRegion(bar: address.bar)
        }
        var payload = try logic.editEvent(action: action, address: address, change: change)
        if let selection { payload["selection"] = selection }
        if var dictionary = payload as [String: Any]? {
            appendWarning(
                action == "delete"
                    ? nil
                    : "Logic's Event List RE-SORTS on every position and pitch write, so row"
                        + " numbers from an earlier logic_list_events are stale. Address events by"
                        + " position and pitch, never by row.",
                to: &dictionary
            )
            payload = dictionary
        }
        return payload
    }

    /// A note created past a region's boundary is a note nobody will ever hear.
    ///
    /// Measured 2026-08-28: with the playhead at bar 66 and the region running
    /// 62–65, `Create new Event` still added the note to the region's event
    /// list AND the region's own bounds did not grow — a silent note, verified
    /// present and permanently inaudible. That is the worst kind of success, so
    /// it is refused here rather than warned about.
    private func refuseCreateOutsideRegion(bar: Int) throws {
        guard let tracks = (try? logic.listRegions(trackName: nil))?["tracks"] as? [[String: Any]] else {
            return
        }
        let selected = tracks.compactMap { track -> [String: Any]? in
            (track["regions"] as? [[String: Any]])?.first { $0["selected"] as? Bool == true }
        }
        guard selected.count == 1, let region = selected.first,
              let start = region["start_bar"] as? Int, let end = region["end_bar"] as? Int else {
            // Not visible in the arrangement (scrolled-out tracks are not
            // published) — say nothing rather than guess at bounds.
            return
        }
        guard bar >= start, bar <= end else {
            throw LogicianError.preconditionUnmet(
                "bar \(bar) is outside the selected region, which runs bar \(start)–\(end)."
                    + " Logic WILL create the note there and the region will NOT grow to hold it,"
                    + " so it would be an event that exists and never sounds. Lengthen the region"
                    + " first (logic_set_region_params / logic_copy_region), or create inside it."
            )
        }
    }

    // MARK: - logic_markers (G46)

    func handleMarkers(_ arguments: [String: Any]) throws -> Any {
        let action = (arguments["action"] as? String) ?? "list"
        let name = arguments["name"] as? String
        let bar = arguments["bar"] as? Int
        switch action {
        case "list":
            let read = logic.readMarkerList()
            guard let markers = read.markers, let census = read.census else {
                throw LogicianError.trackNotExposed(
                    requested: "Logic's Marker List",
                    exposed: read.failure?.reason ?? "the Marker tab published no table"
                )
            }
            var payload: [String: Any] = [
                "success": true, "verified": true, "state": "listed",
                "markers": markers,
                // The list's own count, for the same reason logic_list_events
                // reports it: a marker Logic has counted and not drawn yet is a
                // marker, and reporting the readable ones would hide it.
                "marker_count": census.count,
                "columns": read.columns,
                "note": "Read out of View > List Editors > Marker; the pane and the previously"
                    + " selected tab are restored afterwards."
            ]
            appendUnreadRowWarning(census, kind: "marker", to: &payload)
            return payload
        case "create":
            return try createMarker(bar: bar, name: name)
        case "goto":
            let read = logic.readMarkerList()
            guard let markers = read.markers, let census = read.census else {
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
                // "Not in the list I could read" is not "not in the project"
                // when Logic counted a row it had not drawn, so the refusal
                // says which it is rather than leaving the caller to assume.
                throw LogicianError.trackNotFound(
                    name.map { "marker '\($0)'" } ?? "a marker at bar \(bar ?? 0)",
                    available: markers.map {
                        "\(($0["name"] as? String) ?? "(unnamed)") at bar \(($0["bar"] as? Int).map(String.init) ?? "?")"
                    } + (census.isComplete ? [] : ["(" + census.unreadNote + " Read again.)"])
                )
            }
            guard matches.count == 1 else {
                throw LogicianError.trackAmbiguous(
                    name ?? "bar \(bar ?? 0)", numbers: matches.compactMap { $0["bar"] as? Int }
                )
            }
            // The marker's BEAT, not only its bar. `setPlayhead(beat: nil)`
            // does not mean "beat 1" — it never touches the beat slider, so
            // the playhead kept whatever beat it was already on: measured
            // 2026-09-02, `goto` on a marker at `33 4 1 1` parked at bar 33
            // BEAT 1 and reported both numbers without noticing they
            // disagreed. `parkPlayheadOnGrid` is the primitive split, copy and
            // import park with, and its `on_grid` is read off the MCU's own
            // position display rather than claimed.
            let park = MarkerPark.target(bar: target, beat: marker["beat"])
            let parked = try logic.parkPlayheadOnGrid(bar: park.bar, beat: park.beat)
            guard (parked["bar"] as? Int) == park.bar,
                  (parked["beat"] as? Int) == park.beat else {
                throw LogicianError.verificationFailed(
                    requested: "the playhead at the marker, bar \(park.bar) beat \(park.beat)",
                    actual: "bar \(parked["bar"] ?? "?") beat \(parked["beat"] ?? "?")",
                    restored: false
                )
            }
            var moved: [String: Any] = [
                "success": true,
                "verified": true,
                "state": "playhead_at_marker",
                "before": parked["before"] ?? NSNull(),
                "after": ["bar": park.bar, "beat": park.beat],
                "marker": marker,
                "playhead": parked,
                "write_route": "ax_playhead_park_on_grid",
                "note": "The playhead was parked at bar \(park.bar) beat \(park.beat) — the"
                    + " marker's own position, beat included."
                    + (parked["rewound_first"] as? Bool == true
                        ? " It was rewound to the project start first, which is what makes the"
                            + " stepping land exactly on the beat rather than inside it."
                        : parked["transport_rolling"] as? Bool == true
                            ? " It was NOT rewound first, because the transport is rolling — so"
                                + " any sub-beat offset the playhead already carried is still"
                                + " there."
                            : " It already read as being exactly on the beat before the move.")
            ]
            if !park.exact {
                appendWarning(
                    "This marker sits BETWEEN beats (Logic prints its position as"
                        + " '\((marker["Position"] as? String) ?? "?")'), and the control bar"
                        + " publishes a bar slider and a beat slider and nothing below them — so"
                        + " the playhead is on beat \(park.beat), the beat line at or before the"
                        + " marker, not on the marker itself.",
                    to: &moved
                )
            }
            if parked["on_grid"] as? Bool == false {
                appendWarning(
                    "The position display still reads division"
                        + " \(parked["timecode_division"] ?? "?"), tick"
                        + " \(parked["timecode_ticks"] ?? "?"), so the playhead is inside the beat"
                        + " rather than on it — anything placed at the playhead now would inherit"
                        + " that offset.",
                    to: &moved
                )
            }
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
    /// and verifies against the Marker List — the count grew, and a marker is at
    /// the bar asked for.
    ///
    /// Two routes, button first: the Marker tab publishes its own `Create new
    /// Marker` button (observed 2026-08-28), which needs no learned assignment
    /// and sits in the same list the result is verified against. Logic's
    /// `Create Marker` KEY COMMAND — the route COVERAGE named — is the fallback,
    /// and it is second because a MIDI-note binding can be silently orphaned
    /// when Logic's ports are recreated while a button cannot.
    private func createMarker(bar: Int?, name: String?) throws -> [String: Any] {
        // REFUSED BEFORE ANYTHING IS OPENED. `name` used to be accepted, and
        // paid for: the create ran, then a second write tried the row's name
        // cell and a THIRD pane cycle (1 902 ms, measured 2026-09-02) came back
        // "not writable" — because on Logic Pro 12.3.1 no cell in a Marker List
        // row publishes a settable value, every row, every cell. An argument
        // that cannot work is refused with the route that does, not charged for.
        if let name, !name.isEmpty {
            throw LogicianError.invalidArguments(
                "action 'create' cannot name a marker on this Logic version: no cell in a Marker"
                    + " List row publishes a settable value (measured on Logic Pro 12.3.1,"
                    + " 2026-09-02), so there is no Accessibility route to a marker's name at all"
                    + " — 'rename' refuses for the same reason. Create it WITHOUT `name`: it gets"
                    + " Logic's own default ('Marker 5'), which is what every marker in the"
                    + " project already carries. Rename it by hand in Logic if the name matters"
                    + " (double-click the name in the Marker List, or the marker in the Tracks"
                    + " area's Marker track). Nothing was created."
            )
        }
        // The playhead is parked BEFORE the pane opens, and with
        // `parkPlayheadOnGrid`, not `setPlayhead`: both position sliders are
        // RELATIVE steppers, so a sub-beat offset the playhead already carries
        // is carried into the marker — the documented `9 1 4 201` landing
        // (FINDINGS 2026-08-28 fynd 10). This was the last writer in the server
        // still stepping blind; split, copy, edit_event and import_midi all
        // park on the grid and read the residue off the MCU timecode.
        var parked: [String: Any]?
        if let bar {
            let park = try logic.parkPlayheadOnGrid(bar: bar, beat: 1)
            guard (park["bar"] as? Int) == bar, (park["beat"] as? Int) == 1 else {
                throw LogicianError.verificationFailed(
                    requested: "the playhead at bar \(bar) beat 1 before the create",
                    actual: "bar \(park["bar"] ?? "?") beat \(park["beat"] ?? "?");"
                        + " no marker was created",
                    restored: false
                )
            }
            parked = park
        }
        // ONE pane cycle: the count before, the button press and the readback
        // all happen with the same pane open on the same tab. It was three
        // (four with the key-command fallback), at 1 509–2 130 ms each.
        var reading = try logic.createMarkerThroughListButton()
        var route = "list_editor_create_marker_button"
        if !reading.pressed {
            route = "midi_key_command_create_marker"
            let command = try MCUController.resolveKeyCommand(
                named: KeyCommandRegistry.Name.createMarker, logic: logic
            )
            _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
            reading = logic.readMarkerCreateFallback(
                countBefore: reading.countBefore, barsBefore: reading.barsBefore
            )
        }
        let created = reading.created
        let after = reading.markers
        // WHICH row is the new one is neither the row INDEX nor the name: Logic
        // renumbers markers by position, so creating one at bar 33 in front of
        // an existing "Marker 1" at bar 161 renamed THAT one to "Marker 2" and
        // gave the new one the old one's name (observed live 2026-08-28, and it
        // made the first version of this code report the wrong marker). The new
        // marker is identified by its BAR — the playhead's, which is where Logic
        // just put it.
        let playheadBar = (parked?["bar"] as? Int) ?? bar
        let fresh = after.first { marker in
            guard let markerBar = marker["bar"] as? Int else { return false }
            if let playheadBar { return markerBar == playheadBar }
            return !reading.barsBefore.contains(markerBar)
        }
        var payload: [String: Any] = [
            "success": created,
            "verified": created,
            "state": created ? "created" : "failed",
            "markers_before": reading.countBefore,
            "markers_after": reading.countAfter ?? reading.countBefore,
            "markers": after,
            "write_route": route,
            "readback_route": reading.pressed ? "marker_list_same_pane" : "marker_list_reread",
            "readback_polls": reading.polls,
            "note": created
                ? (parked == nil
                    ? "Created at the PLAYHEAD, wherever it stood — no bar was given, so nothing"
                        + " was parked and any sub-beat offset the playhead carried is in the"
                        + " marker. "
                    : "Created at the PLAYHEAD, parked exactly on bar \(playheadBar ?? 0) beat 1"
                        + " and checked against the control surface's own position display. ")
                    + "NOTE that Logic RENUMBERS its default marker names by position: creating"
                    + " a marker before an existing one renames that one, so address markers by"
                    + " BAR when it matters. Remove this one with action 'delete'."
                : "No new marker appeared in the Marker List after the create."
        ]
        if let parked { payload["playhead"] = parked }
        if created, parked != nil, parked?["on_grid"] as? Bool != true {
            appendWarning(
                "The playhead was parked for this create and the position display could NOT"
                    + " confirm it landed exactly on the beat"
                    + ((parked?["on_grid"] as? Bool) == false
                        ? " (it reads division \(parked?["timecode_division"] ?? "?"), tick"
                            + " \(parked?["timecode_ticks"] ?? "?"))"
                        : " (the surface could not be read)")
                    + ", so read the marker's own position back before trusting it.",
                to: &payload
            )
        }
        if let fresh {
            payload["marker"] = fresh
        } else if created, let censusAfter = reading.censusAfter, !censusAfter.isComplete {
            // The count grew, so the marker is there; the row carrying it is
            // the one Logic has not drawn, so its bar cannot be read yet. Both
            // halves are said, because "created: true" with no marker in the
            // payload is otherwise indistinguishable from a bug.
            appendWarning(
                "The marker was created — the Marker List's own count grew — but the new row is"
                    + " one Logic has NOT drawn yet, so it is missing from `markers` and its bar"
                    + " could not be read. " + censusAfter.unreadNote + " Read the list again.",
                to: &payload
            )
        }
        if let failure = reading.readbackFailure {
            appendWarning(
                "The readback could not be trusted as a full list: " + failure.reason + ".",
                to: &payload
            )
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
        var payload: [String: Any] = [
            "success": true,
            // A cached map is NOT a verified one, and this is the cache that
            // needs saying so: its cross-check can only contradict, never
            // confirm, and it has no TTL. Same rule, same words, as
            // logic_tempo_events' `tempo_list_cache`.
            "verified": !knowledge.servedFromCache,
            "state": "listed",
            "read_route": knowledge.servedFromCache ? "signature_list_cache" : "signature_list",
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
        // The Signature List holds KEY signatures in the same table, and this
        // reader counts them for the truncation cross-check and then skips
        // them. The count is reported because the description promises those
        // rows are accounted for — and because a key-row count that does not
        // match the project's key changes is how a row this server could not
        // read becomes visible.
        if let keyRows = knowledge.keySignatureRows {
            payload["key_signature_rows"] = keyRows
        }
        if knowledge.servedFromCache {
            appendWarning(MeterKnowledge.cacheWarning, to: &payload)
        }
        return payload
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
