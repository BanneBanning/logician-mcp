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
        guard let window = try logicWindows().first(where: {
            stringAttribute($0, kAXSubroleAttribute as String) == "AXStandardWindow"
        }) else {
            throw LogicianError.windowNotFound("project window")
        }
        var rows: [(Int, String, [AXUIElement])] = []
        walk(from: window, maximumDepth: AXDepth.trackRegionRow) { element in
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea",
               description.hasPrefix("Track "), description.contains("“") {
                let digits = description.dropFirst(6).prefix { $0.isNumber }
                let name = description.split(separator: "“").last.map {
                    String($0).replacingOccurrences(of: "”", with: "")
                } ?? description
                let regions = children(of: element).filter {
                    stringAttribute($0, "AXRoleDescription") == "Region"
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
        if let start = capture(#"starts at \d+ bars?\s*(\d+ beats?)?"#) {
            entry["start_bar"] = start.bar
            if start.beat != 1 { entry["start_beat"] = start.beat }
        }
        if let end = capture(#"ends at \d+ bars?\s*(\d+ beats?)?"#) {
            entry["end_bar"] = end.bar
            if end.beat != 1 { entry["end_beat"] = end.beat }
        }
        if let typeRange = help.range(of: #",\s*([A-Za-z]+) region"#, options: .regularExpression) {
            let segment = String(help[typeRange])
            entry["type"] = segment
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "region", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return entry
    }

    /// The arrangement map: every region on every visible track, with bar
    /// positions and type parsed from the element's help text.
    func listRegions(trackName: String?) throws -> [String: Any] {
        let rows = try regionRows()
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
    func selectRegion(
        trackName: String, regionName: String?, startBar: Int?, exclusive: Bool
    ) throws -> [String: Any] {
        guard regionName != nil || startBar != nil else {
            throw LogicianError.invalidArguments("pass region_name and/or start_bar")
        }
        let rows = try regionRows()
        guard let row = rows.first(where: {
            $0.track.caseInsensitiveCompare(trackName) == .orderedSame
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "track '\(trackName)'",
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
        result["exclusive"] = exclusive
        return result
    }

    /// The channel strip's pan value (the strip's pan AXSlider), always
    /// readable regardless of which MCU view is active.
    func stripPanValue(trackName: String) -> Double? {
        guard let strip = try? inspectorStrip(named: trackName) else { return nil }
        for child in children(of: strip)
        where stringAttribute(child, kAXDescriptionAttribute as String) == "pan" {
            return Double(stringAttribute(child, kAXValueAttribute as String))
        }
        return nil
    }

    /// The preset label from a plugin window's header (the rightmost popup).
    func pluginPresetLabel(windowTitle: String) -> String? {
        guard let windows = try? logicWindows() else { return nil }
        for window in windows
        where stringAttribute(window, kAXTitleAttribute as String) == windowTitle
            && stringAttribute(window, kAXSubroleAttribute as String) != "AXStandardWindow" {
            var popups: [String] = []
            collect(from: window, maximumDepth: AXDepth.pluginWindowHeader) { element in
                if stringAttribute(element, kAXRoleAttribute as String) == "AXPopUpButton" {
                    popups.append(stringAttribute(element, kAXValueAttribute as String))
                }
            }
            return popups.last { !$0.isEmpty }
        }
        return nil
    }

    /// Renames a track by writing the channel strip's name field.
    func renameTrack(trackName: String, newName: String) throws -> [String: Any] {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LogicianError.invalidArguments("new_name must be non-empty")
        }
        _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
        // The header/strip name fields ignore direct AXValue writes; the
        // Rename Track key command opens an inline editor whose focused
        // element IS settable.
        let command = try MCUController.resolveKeyCommand(named: "Rename Track", logic: self)
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
            stringAttribute($0, kAXDescriptionAttribute as String) == "pan"
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
            if description.contains("automation") {
                return description.split(separator: ",").first.map(String.init)
            }
        }
        return nil
    }

    // MARK: - Region editing (exclusive selection + learned key commands)

    func fireKeyCommand(_ name: String) throws {
        let command = try MCUController.resolveKeyCommand(named: name, logic: self)
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
    }

    func regionSnapshot(trackName: String) throws -> [[String: Any]] {
        let map = try listRegions(trackName: trackName)
        return ((map["tracks"] as? [[String: Any]])?.first?["regions"] as? [[String: Any]]) ?? []
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
        try fireKeyCommand("Delete")
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
                ? "Nudge Region/Event Position Right by Bar"
                : "Nudge Region/Event Position Left by Bar")
            Thread.sleep(forTimeInterval: 0.15)
        }
        for _ in 0..<abs(byBeats) {
            try fireKeyCommand(byBeats > 0
                ? "Nudge Region/Event Position Right by Beat"
                : "Nudge Region/Event Position Left by Beat")
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

    func copyRegion(
        trackName: String, regionName: String?, startBar: Int?,
        toBar: Int, toTrack: String?, move: Bool
    ) throws -> [String: Any] {
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw LogicianError.verificationFailed(
                requested: "exactly one selected region before \(move ? "Cut" : "Copy")",
                actual: "selection drifted; refusing", restored: true
            )
        }
        try fireKeyCommand(move ? "Cut" : "Copy")
        Thread.sleep(forTimeInterval: 0.4)
        let destinationTrack = toTrack ?? trackName
        if let target = toTrack {
            _ = try selectTrack(trackName: target, trackNumber: nil, expectedProjectPath: nil)
        }
        // beat 1 explicitly: the bar converge alone leaves the beat wherever
        // the playhead last stood, and Paste lands at the playhead exactly.
        _ = try setPlayhead(barNumber: toBar, beat: 1)
        try fireKeyCommand("Paste")
        var pasted: [String: Any]?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.4)
            let after = try regionSnapshot(trackName: destinationTrack)
            if let hit = after.first(where: { $0["start_bar"] as? Int == toBar }) {
                pasted = hit
                break
            }
        }
        guard let landed = pasted else {
            throw LogicianError.verificationFailed(
                requested: "a region at bar \(toBar) on '\(destinationTrack)'",
                actual: "nothing appeared there after Paste (clipboard state uncertain)",
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
