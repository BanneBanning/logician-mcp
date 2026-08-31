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
        let window = try projectWindow()
        var rows: [(Int, String, [AXUIElement])] = []
        walk(from: window, maximumDepth: AXDepth.trackRegionRow) { element in
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea",
               description.hasPrefix(LogicUIStrings.Format.trackDescriptionPrefix),
               description.contains(LogicUIStrings.Format.openQuote) {
                let digits = description
                    .dropFirst(LogicUIStrings.Format.trackDescriptionPrefix.count)
                    .prefix { $0.isNumber }
                let name = description.split(separator: LogicUIStrings.Format.openQuote).last.map {
                    String($0).replacingOccurrences(
                        of: String(LogicUIStrings.Format.closeQuote), with: ""
                    )
                } ?? description
                let regions = children(of: element).filter {
                    stringAttribute($0, "AXRoleDescription")
                        == LogicUIStrings.Element.regionRoleDescription
                }
                rows.append((Int(digits) ?? 0, name, regions))
                return .skipChildren // region items have no nested rows
            }
            return .descend
        }
        return rows
    }

    func parseRegion(_ element: AXUIElement) -> [String: Any] {
        var entry: [String: Any] = [
            "name": stringAttribute(element, kAXDescriptionAttribute as String),
            "selected": stringAttribute(element, "AXSelected") == "1"
        ]
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

    /// The arrangement map: every region on every visible track, with bar
    /// positions and type parsed from the element's help text.
    func listRegions(trackName: String?) throws -> [String: Any] {
        let rows = try regionRows()
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
                "regions": row.regions.map(parseRegion)
            ])
        }
        if let filter = trackName, tracks.isEmpty {
            throw LogicianError.trackNotExposed(
                requested: "regions on '\(filter)'",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "tracks": tracks,
            "note": "Only regions on currently rendered track rows are listed (scrolled-out tracks are not exposed). Positions are whole bars/beats as Logic's own help text reports them."
        ]
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
    func selectRegion(
        trackName: String, regionName: String?, startBar: Int?, exclusive: Bool,
        trackNumber: Int? = nil
    ) throws -> [String: Any] {
        guard regionName != nil || startBar != nil else {
            throw LogicianError.invalidArguments("pass region_name and/or start_bar")
        }
        let rows = try regionRows()
        guard let row = rows.first(where: {
            if let trackNumber { return $0.number == trackNumber }
            return $0.track.caseInsensitiveCompare(trackName) == .orderedSame
        }) else {
            throw LogicianError.trackNotExposed(
                requested: trackNumber.map { "track row \($0) ('\(trackName)')" }
                    ?? "track '\(trackName)'",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        let annotated = row.regions.map { ($0, parseRegion($0)) }
        let hits = annotated.filter { _, info in
            if let name = regionName,
               (info["name"] as? String)?.caseInsensitiveCompare(name) != .orderedSame {
                return false
            }
            if let bar = startBar, info["start_bar"] as? Int != bar { return false }
            return true
        }
        guard hits.count == 1, let hit = hits.first else {
            throw LogicianError.parameterAmbiguous(
                "region on '\(trackName)' (candidates: " + annotated.map { _, info in
                    "\(info["name"] ?? "?")@bar\(info["start_bar"] ?? 0)"
                }.joined(separator: ", ") + ")",
                hits.count
            )
        }
        if exclusive {
            for otherRow in rows {
                for region in otherRow.regions
                where stringAttribute(region, "AXSelected") == "1" && !CFEqual(region, hit.0) {
                    _ = AXUIElementSetAttributeValue(region, "AXSelected" as CFString, kCFBooleanFalse)
                }
            }
        }
        var stuck = false
        for attempt in 0..<2 {
            let status = AXUIElementSetAttributeValue(
                hit.0, "AXSelected" as CFString, kCFBooleanTrue
            )
            guard status == .success else {
                throw LogicianError.writeFailed("AXSelected write returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.3)
            if stringAttribute(hit.0, "AXSelected") == "1" { stuck = true; break }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) } // stale-element transient
        }
        guard stuck else {
            throw LogicianError.verificationFailed(
                requested: "region selected",
                actual: "the region's AXSelected did not stick after a retry",
                restored: false
            )
        }
        // Key commands like Delete act on the FOCUSED area's selection —
        // hand the region keyboard focus so they cannot miss (best effort).
        _ = AXUIElementSetAttributeValue(hit.0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var result = parseRegion(hit.0)
        result["success"] = true
        result["verified"] = true
        result["track"] = row.track
        result["track_name"] = row.track
        result["exclusive"] = exclusive
        return result
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
    func renameTrack(trackName: String, newName: String) throws -> [String: Any] {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LogicianError.invalidArguments("new_name must be non-empty")
        }
        _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
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
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.2)
            // A focused "element" that is not one keeps polling (the editor
            // may not exist yet) rather than trapping mid-rename.
            if let element = elementAttribute(appElement, "AXFocusedUIElement") {
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                if settable.boolValue { editor = element; break }
            }
        }
        guard let field = editor else {
            throw LogicianError.trackNotExposed(
                requested: "the inline rename editor",
                exposed: "no settable focused element appeared after Rename Track"
            )
        }
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, newName as CFString
        )
        guard status == .success else {
            throw LogicianError.writeFailed("name write returned AXError \(status.rawValue)")
        }
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        Thread.sleep(forTimeInterval: 0.6)
        // The rename popover can linger after confirmation and blocks
        // subsequent commands — close any dialog carrying the new name.
        if let windows = try? logicWindows() {
            for window in windows
            where stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog"
                && stringAttribute(window, kAXTitleAttribute as String) == newName {
                // Skip a close button that is not an element, as if the
                // attribute were absent; `as!` here would trap.
                if let close = elementAttribute(window, kAXCloseButtonAttribute as String) {
                    _ = AXUIElementPerformAction(close, kAXPressAction as CFString)
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let tracks = ((try? listTracks())?["tracks"] as? [[String: Any]]) ?? []
        guard tracks.contains(where: {
            ($0["track_name"] as? String)?.caseInsensitiveCompare(newName) == .orderedSame
        }) else {
            throw LogicianError.verificationFailed(
                requested: "track renamed to '\(newName)'",
                actual: "no track header shows the new name",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "renamed",
            "from": trackName, "to": newName
        ]
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
    func regionSnapshot(trackName: String, trackNumber: Int? = nil) throws -> [[String: Any]] {
        guard let trackNumber else {
            let map = try listRegions(trackName: trackName)
            return ((map["tracks"] as? [[String: Any]])?.first?["regions"] as? [[String: Any]]) ?? []
        }
        let rows = try regionRows()
        guard let row = rows.first(where: { $0.number == trackNumber }) else {
            throw LogicianError.trackNotExposed(
                requested: "track row \(trackNumber) ('\(trackName)')",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        return row.regions.map(parseRegion)
    }

    /// Counts selected regions across ALL visible rows — the guard that must
    /// pass (exactly 1) immediately before any destructive key command fires.
    func selectedRegionCount() throws -> Int {
        try regionRows().reduce(0) { sum, row in
            sum + row.regions.filter { stringAttribute($0, "AXSelected") == "1" }.count
        }
    }

    func deleteRegion(
        trackName: String, regionName: String?, startBar: Int?
    ) throws -> [String: Any] {
        let before = try regionSnapshot(trackName: trackName)
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before Delete",
                actual: "\(try selectedRegionCount()) regions selected; refusing to fire Delete",
                restored: true
            )
        }
        try fireKeyCommand(KeyCommandRegistry.Name.delete)
        var gone = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.4)
            let after = try regionSnapshot(trackName: trackName)
            let stillThere = after.contains {
                $0["start_bar"] as? Int == selection["start_bar"] as? Int
                    && ($0["name"] as? String) == (selection["name"] as? String)
            }
            if after.count == before.count - 1 && !stillThere { gone = true; break }
        }
        guard gone else {
            throw LogicianError.verificationFailed(
                requested: "region '\(selection["name"] ?? "?")' deleted",
                actual: "the region is still in the arrangement map (undo history unaffected)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "deleted",
            "track": trackName, "track_name": trackName,
            "region": selection["name"] ?? "?",
            "start_bar": selection["start_bar"] ?? NSNull(),
            "note": "Removable mistake? Undo restores it."
        ]
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
    func splitRegion(
        trackName: String, regionName: String?, startBar: Int?,
        atBar: Int, atBeat: Int, notesCrossing: String
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
        let before = try regionSnapshot(trackName: trackName)
        // Identify the region WITHOUT selecting it yet: the playhead has to be
        // parked first (see below), and parking touches the control bar, which
        // takes the keyboard focus away from the Tracks area — a Split fired
        // in that state does nothing at all (measured 2026-08-28: select,
        // park, split left the arrangement map unchanged). `selectRegion`
        // hands the region the focus, so it has to be the LAST thing before
        // the command fires.
        let candidates = before.filter { entry in
            if let regionName,
               (entry["name"] as? String)?.caseInsensitiveCompare(regionName) != .orderedSame {
                return false
            }
            if let startBar, entry["start_bar"] as? Int != startBar { return false }
            return true
        }
        guard candidates.count == 1, let selection = candidates.first else {
            throw LogicianError.parameterAmbiguous(
                "region on '\(trackName)' (candidates: " + before.map {
                    "\($0["name"] ?? "?")@bar\($0["start_bar"] ?? 0)"
                }.joined(separator: ", ") + ")",
                candidates.count
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
        // Selection LAST, for the focus reason above, and exclusive so Split
        // cannot cut a region the caller never named.
        _ = try selectRegion(
            trackName: trackName, regionName: selection["name"] as? String,
            startBar: selection["start_bar"] as? Int, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before Split",
                actual: "\(try selectedRegionCount()) regions selected; refusing to fire Split "
                    + "(it would cut every one of them at the playhead)",
                restored: false
            )
        }
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
            if (try? regionSnapshot(trackName: trackName))?.count ?? 0 > before.count { break }
        }

        // FAILURE MODE 3: the command fired and nothing happened. The
        // arrangement map is the only evidence that counts.
        var after: [[String: Any]] = []
        var split = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.35)
            after = try regionSnapshot(trackName: trackName)
            if after.count == before.count + 1 { split = true; break }
        }
        guard split else {
            throw LogicianError.verificationFailed(
                requested: "two regions where '\(selection["name"] ?? "?")' was",
                actual: "the track still shows \(after.count) region(s). Nothing was undone - "
                    + "if the split DID happen and only the map is stale, re-read logic_list_regions "
                    + "before firing Undo",
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
            "left": leftHalf ?? NSNull(),
            "right": rightHalf ?? NSNull(),
            "playhead_left_at": ["bar": atBar, "beat": atBeat],
            "note": Self.notesCrossingNote(dialogAnswer, requested: notesCrossing.lowercased())
                + "Undo restores the single region. The two halves are new regions: their names and start bars are what logic_list_regions reports now, so re-read the map before addressing either of them."
        ]
        result["playhead"] = parked
        // An honest caveat rather than a silent wrong cut.
        switch parked["on_grid"] as? Bool {
        case true:
            break
        case false:
            result["warning"] = "The playhead did NOT land exactly on bar \(atBar) beat \(atBeat) "
                + "(the MCU position display still shows division \(parked["timecode_division"] ?? "?"), "
                + "tick \(parked["timecode_ticks"] ?? "?")), so the cut sits inside the beat. "
                + "Listen across the seam, or Undo and try again."
            result["verified"] = false
        default:
            result["warning"] = "Whether the cut landed exactly on the beat is UNVERIFIED: the MCU "
                + "position display could not be read, and the control bar publishes bars and beats "
                + "only — it cannot see a sub-beat offset. The playhead was rewound to the project "
                + "start before stepping, which is what makes the position exact; that it is exact "
                + "was not observed."
        }
        if rightHalf == nil {
            result["warning"] = ((result["warning"] as? String).map { $0 + " ALSO: " } ?? "")
                + "A region count of \(after.count) proves the split happened, but no region starts "
                + "at bar \(atBar) in the map — Logic reports whole bars and beats only, so a split "
                + "inside a bar shows up on the bar it falls in. Read logic_list_regions for the truth."
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
    func selectRegions(
        mode: String, trackName: String?, regionName: String?, startBar: Int?
    ) throws -> [String: Any] {
        guard let entry = LogicAccessibility.regionSelectionCommands[mode] else {
            throw LogicianError.invalidArguments(
                "unknown mode '\(mode)'; use one of: "
                    + LogicAccessibility.regionSelectionCommands.keys.sorted().joined(separator: ", ")
            )
        }
        var anchor: [String: Any]?
        if mode != "all" && mode != "none" {
            guard let trackName else {
                throw LogicianError.invalidArguments(
                    "mode '\(mode)' needs an anchor: pass track_name (and region_name and/or "
                        + "start_bar when the track holds more than one region)"
                )
            }
            let regions = try regionSnapshot(trackName: trackName)
            // One region on the track needs no further identification; more
            // than one and the caller has to say which, exactly as
            // logic_select_region requires.
            if regionName == nil && startBar == nil && regions.count == 1 {
                anchor = try selectRegion(
                    trackName: trackName, regionName: regions[0]["name"] as? String,
                    startBar: regions[0]["start_bar"] as? Int, exclusive: true
                )
            } else {
                anchor = try selectRegion(
                    trackName: trackName, regionName: regionName,
                    startBar: startBar, exclusive: true
                )
            }
        }
        let before = try selectedRegionCount()
        let wasRegistered = KeyCommandRegistry.note(named: entry.command) != nil
        try fireKeyCommand(
            entry.command, learnIfMissing: true, source: "logic_select_regions"
        )
        var after = before
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            after = try selectedRegionCount()
            if after != before { break }
        }
        let expectedChange = mode == "none" ? (after == 0) : (after > before || after > 1)
        var result: [String: Any] = [
            "success": expectedChange,
            "verified": expectedChange,
            "state": expectedChange ? "selected" : "unchanged",
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
        if !expectedChange {
            result["note"] = "The selection count did not move (\(before) -> \(after)). Either the "
                + "command is not bound in this Logic (check logic_list_key_commands), or it needs a "
                + "focus this call did not have, or there genuinely was nothing more to select. "
                + "Nothing was edited."
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

    func moveRegion(
        trackName: String, regionName: String?, startBar: Int?,
        byBars: Int, byBeats: Int
    ) throws -> [String: Any] {
        guard byBars != 0 || byBeats != 0 else {
            throw LogicianError.invalidArguments("pass a non-zero by_bars and/or by_beats")
        }
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before nudging",
                actual: "selection drifted; refusing", restored: true
            )
        }
        let oldStart = selection["start_bar"] as? Int ?? 0
        for _ in 0..<abs(byBars) {
            try fireKeyCommand(byBars > 0
                ? KeyCommandRegistry.Name.nudgeRightByBar
                : KeyCommandRegistry.Name.nudgeLeftByBar)
            Thread.sleep(forTimeInterval: 0.15)
        }
        for _ in 0..<abs(byBeats) {
            try fireKeyCommand(byBeats > 0
                ? KeyCommandRegistry.Name.nudgeRightByBeat
                : KeyCommandRegistry.Name.nudgeLeftByBeat)
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.4)
        // Whole-bar moves verify exactly; beat moves verify that the region
        // left its old slot (Logic's help text rounds to bars+beats).
        let after = try regionSnapshot(trackName: trackName)
        let target = after.first {
            ($0["name"] as? String) == (selection["name"] as? String)
                && ($0["selected"] as? Bool) == true
        }
        guard let moved = target else {
            throw LogicianError.verificationFailed(
                requested: "the moved region still selected at its new position",
                actual: "could not find it in the arrangement map",
                restored: false
            )
        }
        if byBeats == 0, let newBar = moved["start_bar"] as? Int, newBar != oldStart + byBars {
            throw LogicianError.verificationFailed(
                requested: "region at bar \(oldStart + byBars)",
                actual: "region at bar \(newBar)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "moved",
            "track": trackName, "track_name": trackName,
            "region": selection["name"] ?? "?",
            "from_bar": oldStart,
            "to_bar": moved["start_bar"] ?? NSNull(),
            "to_beat": moved["start_beat"] ?? 1
        ]
    }

    /// - Parameters:
    ///   - fromTrackNumber: addresses the SOURCE row by number instead of by
    ///     name (duplicate track names; see `selectRegion`).
    ///   - toTrackNumber: the same for the DESTINATION row.
    func copyRegion(
        trackName: String, regionName: String?, startBar: Int?,
        toBar: Int, toTrack: String?, move: Bool,
        fromTrackNumber: Int? = nil, toTrackNumber: Int? = nil
    ) throws -> [String: Any] {
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
            trackNumber: fromTrackNumber
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before \(move ? "Cut" : "Copy")",
                actual: "selection drifted; refusing", restored: true
            )
        }
        try fireKeyCommand(move ? KeyCommandRegistry.Name.cut : KeyCommandRegistry.Name.copy)
        Thread.sleep(forTimeInterval: 0.4)
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
        // beat 1 explicitly: the bar converge alone leaves the beat wherever
        // the playhead last stood, and Paste lands at the playhead exactly.
        _ = try setPlayhead(barNumber: toBar, beat: 1)
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
        let destinationBefore = (try? regionSnapshot(
            trackName: destinationTrack, trackNumber: destinationNumber
        )) ?? []
        let atBarBefore = destinationBefore.filter { $0["start_bar"] as? Int == toBar }
        try fireKeyCommand(KeyCommandRegistry.Name.paste)
        var pasted: [String: Any]?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.4)
            let after = try regionSnapshot(
                trackName: destinationTrack, trackNumber: destinationNumber
            )
            let atBar = after.filter { $0["start_bar"] as? Int == toBar }
            guard after.count > destinationBefore.count || atBar.count > atBarBefore.count
            else { continue }
            // Prefer a region at toBar that was not there before; fall back to
            // any region at toBar once the count has proven something landed.
            pasted = atBar.first { hit in !atBarBefore.contains { isSame($0, hit) } } ?? atBar.first
            break
        }
        guard let landed = pasted else {
            throw LogicianError.verificationFailed(
                requested: "a NEW region at bar \(toBar) on '\(destinationTrack)'",
                actual: destinationBefore.count == atBarBefore.count && !atBarBefore.isEmpty
                    ? "bar \(toBar) already held a region before this call and the track gained"
                        + " none, so Paste did nothing (a modal dialog swallows key commands —"
                        + " check Logic for one). Clipboard state uncertain"
                    : "the track gained no region after Paste (clipboard state uncertain)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": move ? "moved_via_clipboard" : "copied",
            "region": selection["name"] ?? "?",
            "from": ["track": trackName, "track_name": trackName, "start_bar": selection["start_bar"] ?? NSNull()],
            "to": ["track": destinationTrack, "start_bar": landed["start_bar"] ?? toBar],
            "note": "Paste lands at the playhead on the selected track."
        ]
    }

}
