import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Bounce in place (G33): print a region back INTO the project

    /// Logic's bounce-in-place sheet. It is an `AXSheet` with NO title — the
    /// only thing that names it is a static text reading `Bounce Regions In
    /// Place` (measured 2026-08-28), which is also how the region and track
    /// variants are told apart.
    ///
    /// SHAPE, then words. Being an `AXSheet` is structure; carrying at least
    /// two radio buttons and a pop-up is structure too, and it is what
    /// separates this sheet from the OTHER sheet a bounce flow can raise — a
    /// save panel has pop-ups and no radios. The `Bounce` static text is kept
    /// as a second accepted witness rather than as the gate: on an English
    /// Logic both agree and the same element is returned, and on a translated
    /// one the shape alone still finds it.
    func bounceInPlaceSheet(timeout: Double = 8) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            func named(_ candidate: AXUIElement) -> Bool {
                guard stringAttribute(candidate, kAXRoleAttribute as String) == "AXSheet" else {
                    return false
                }
                if dialogShape(of: candidate, maximumDepth: 2).isBounceInPlaceSheetShape {
                    return true
                }
                return children(of: candidate).contains {
                    stringAttribute($0, kAXValueAttribute as String)
                        .localizedCaseInsensitiveContains(LogicUIStrings.AlertMarker.bounceInPlaceSheet)
                }
            }
            for window in (try? logicWindows()) ?? [] {
                if named(window) { return window }
                if let sheet = children(of: window).first(where: named) { return sheet }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    private func sheetRadio(_ sheet: AXUIElement, _ title: String) -> AXUIElement? {
        children(of: sheet).first {
            stringAttribute($0, kAXRoleAttribute as String) == "AXRadioButton"
                && stringAttribute($0, kAXTitleAttribute as String)
                    .caseInsensitiveCompare(title) == .orderedSame
        }
    }

    private func sheetButton(_ sheet: AXUIElement, _ title: String) -> AXUIElement? {
        children(of: sheet).first {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == title
        }
    }

    /// Cancels a bounce-in-place sheet if one is up. Same discipline as
    /// `cancelBounceDialog`: a modal left open freezes everything after it —
    /// so the sheet's own `AXCancelButton` is tried before its English title.
    func cancelBounceInPlaceSheet() {
        guard let sheet = bounceInPlaceSheet(timeout: 0.4),
              let cancel = cancelButton(of: sheet)
                ?? sheetButton(sheet, LogicUIStrings.Button.cancel) else { return }
        _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// The sheet's whole state, read as data. The names are the sheet's own.
    func readBounceInPlaceSheet(_ sheet: AXUIElement) -> [String: Any] {
        var state: [String: Any] = [:]
        for child in children(of: sheet) {
            let role = stringAttribute(child, kAXRoleAttribute as String)
            let title = stringAttribute(child, kAXTitleAttribute as String)
            switch role {
            case "AXCheckBox":
                state[title] = stringAttribute(child, kAXValueAttribute as String) == "1"
            case "AXRadioButton":
                if stringAttribute(child, kAXValueAttribute as String) == "1" {
                    // Two groups (Source: Mute/Leave/Delete, Destination:
                    // Selected Track/New Track) with no group element between
                    // them, so the selected member of each is reported by name.
                    let isSource = LogicUIStrings.Value.bounceInPlaceSourceModes.contains(title)
                    state[isSource ? "source" : "destination"] = title
                }
            case "AXPopUpButton":
                let value = stringAttribute(child, kAXValueAttribute as String)
                if BounceFormat.normalizeModes.contains(value) {
                    state["normalize"] = value
                } else {
                    state["file_split"] = value
                }
            case "AXTextField":
                state["name"] = stringAttribute(child, kAXValueAttribute as String)
            default:
                break
            }
        }
        return state
    }

    /// The project's audio-files folder, or nil when neither project shape is
    /// on disk. One `projectDocumentPath()` read (which is one AX window walk)
    /// and one `fileExists` per candidate; see `PrintedFile` for why the
    /// folder is needed at all.
    func printedAudioFolder() -> String? {
        guard let project = try? projectDocumentPath() else { return nil }
        return PrintedFile.audioFolderCandidates(projectPath: project).first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// The folder's visible entries. Dotfiles are dropped so a `.DS_Store`
    /// written during a render never reads as the print.
    func printedAudioFolderEntries(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    /// What the print left behind, as a result block. `namesBefore` is the
    /// listing taken immediately before the OK press; nil means the folder
    /// could not be resolved, which is reported as "not identified" rather
    /// than as an empty `files` list that would read like "nothing written".
    func printedFileReport(folder: String?, namesBefore: Set<String>?) -> [String: Any] {
        guard let folder, let namesBefore else {
            return [
                "directory": folder ?? NSNull(),
                "files": [] as [[String: Any]],
                "note": PrintedFile.folderUnreadable
            ]
        }
        let arrivals = PrintedFile.arrivals(
            before: namesBefore, after: printedAudioFolderEntries(folder)
        )
        let files: [[String: Any]] = arrivals.map { name in
            let path = (folder as NSString).appendingPathComponent(name)
            var entry: [String: Any] = ["name": name, "path": path]
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
                as? NSNumber {
                entry["bytes"] = size.intValue
            }
            return entry
        }
        return [
            "directory": folder,
            "files": files,
            "note": files.isEmpty
                ? PrintedFile.noArrival
                : PrintedFile.undoCaveat + " Delete it yourself if the print was a mistake."
        ]
    }

    /// Every region in the project's visible rows, as comparable tuples.
    func flatRegionMap() throws -> [(track: String, name: String, start: Int, end: Int)] {
        try regionRows().flatMap { row in
            row.regions.map { element -> (String, String, Int, Int) in
                let info = parseRegion(element)
                return (row.track, (info["name"] as? String) ?? "?",
                        (info["start_bar"] as? Int) ?? -1, (info["end_bar"] as? Int) ?? -1)
            }
        }
    }

    /// G33: print the selected region (or the whole track) back into the
    /// project as audio, through `File > Bounce > Regions/Tracks in Place…`.
    ///
    /// `changes` carries only the sheet controls the caller wants moved;
    /// everything else is left exactly as the user set it and reported back,
    /// because this sheet is the user's own preference sheet and Logic
    /// remembers it. The one thing that is never silent is `Bypass Effect
    /// Plug-ins`: a print made with it ON is DRY, which is almost never what
    /// "print that" means, so the result warns when it was on.
    func bounceInPlace(
        scope: String,
        trackName: String?,
        trackNumber: Int?,
        regionName: String?,
        startBar: Int?,
        name: String?,
        normalize: String?,
        destination: String?,
        source: String?,
        checkboxes: [String: Bool]
    ) throws -> [String: Any] {
        let menuItem = scope == "track"
            ? LogicUIStrings.Menu.tracksInPlace : LogicUIStrings.Menu.regionsInPlace
        var anchor: [String: Any]?
        if scope == "region" {
            guard let trackName else {
                throw LogicianError.invalidArguments("scope 'region' needs track_name")
            }
            anchor = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
                trackNumber: trackNumber
            )
            guard try selectedRegionCount() == 1 else {
                throw LogicianError.verificationFailed(
                    requested: "exactly one selected region before Bounce in Place",
                    actual: "\(try selectedRegionCount()) regions selected; refusing",
                    restored: false
                )
            }
        } else if let trackName {
            _ = try selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }
        let before = try flatRegionMap()
        // Resolved BEFORE the modal goes up, because the diff around the OK
        // press is what identifies the file this print writes - and Logic
        // leaves that file behind even when the region is undone.
        let audioFolder = printedAudioFolder()

        try ensureLogicFrontmost(for: "the bounce-in-place sheet")
        try pressMenuItem(containing: menuItem, underMenu: LogicUIStrings.Menu.bounce)
        guard let sheet = bounceInPlaceSheet() else {
            throw LogicianError.windowNotFound("the '\(menuItem)' sheet")
        }
        // The sheet is modal: never leave it up, whatever goes wrong below.
        var committed = false
        defer { if !committed { cancelBounceInPlaceSheet() } }

        var changed: [String: Any] = [:]
        if let name {
            guard let field = children(of: sheet).first(where: {
                stringAttribute($0, kAXRoleAttribute as String) == "AXTextField"
            }) else {
                throw LogicianError.windowNotFound("the Name field in the bounce-in-place sheet")
            }
            let previous = stringAttribute(field, kAXValueAttribute as String)
            _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFString)
            _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
            Thread.sleep(forTimeInterval: 0.25)
            let after = stringAttribute(field, kAXValueAttribute as String)
            guard after == name else {
                throw LogicianError.verificationFailed(
                    requested: "the bounce name '\(name)'",
                    actual: "the field shows '\(after)'", restored: false
                )
            }
            changed["name"] = ["from": previous, "to": after]
        }
        if let normalize {
            guard let mode = BounceFormat.canonical(normalize, in: BounceFormat.normalizeModes) else {
                throw LogicianError.invalidArguments(
                    BounceFormat.rejection(normalize, label: "Normalize",
                                           options: BounceFormat.normalizeModes)
                )
            }
            guard let popup = children(of: sheet).first(where: {
                stringAttribute($0, kAXRoleAttribute as String) == "AXPopUpButton"
                    && BounceFormat.normalizeModes.contains(
                        stringAttribute($0, kAXValueAttribute as String))
            }) else {
                throw LogicianError.windowNotFound("the Normalize pop-up in the bounce-in-place sheet")
            }
            changed["normalize"] = ["from": try selectPopUpItem(popup, title: mode), "to": mode]
        }
        for (argument, titles) in [
            ("destination", LogicUIStrings.Value.bounceInPlaceDestinations),
            ("source", LogicUIStrings.Value.bounceInPlaceSources)
        ] {
            let requested = argument == "destination" ? destination : source
            guard let requested else { continue }
            guard let title = titles[requested.lowercased().replacingOccurrences(of: " ", with: "_")],
                  let radio = sheetRadio(sheet, title) else {
                throw LogicianError.invalidArguments(
                    "\(argument) must be one of: " + titles.keys.sorted().joined(separator: ", ")
                )
            }
            if stringAttribute(radio, kAXValueAttribute as String) != "1" {
                _ = AXUIElementPerformAction(radio, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.2)
                guard stringAttribute(radio, kAXValueAttribute as String) == "1" else {
                    throw LogicianError.verificationFailed(
                        requested: "\(argument) = \(title)",
                        actual: "the radio button did not take", restored: false
                    )
                }
            }
            changed[argument] = title
        }
        for (title, wanted) in checkboxes {
            guard let box = checkBox(in: sheet, titled: title, maximumDepth: 2) else {
                throw LogicianError.windowNotFound("the '\(title)' checkbox in the bounce-in-place sheet")
            }
            let previous = try setCheckBox(box, to: wanted)
            if previous != wanted { changed[title] = ["from": previous, "to": wanted] }
        }
        let sheetState = readBounceInPlaceSheet(sheet)

        guard let okButton = defaultButton(of: sheet)
            ?? sheetButton(sheet, LogicUIStrings.Button.ok) else {
            throw LogicianError.windowNotFound("the OK button in the bounce-in-place sheet")
        }
        // As late as possible so the diff names only THIS print. A filesystem
        // listing, not an AX read: it costs well under a millisecond and the
        // OK press that follows blocks for Logic's whole render anyway.
        let audioNamesBefore = audioFolder.map { Set(printedAudioFolderEntries($0)) }
        _ = AXUIElementPerformAction(okButton, kAXPressAction as CFString)
        committed = true

        // The render is offline but not instant, and the arrangement map is
        // the proof: a region that was not there before.
        var after = before
        var arrived: ArrangementRegion?
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            after = (try? flatRegionMap()) ?? after
            // `PrintedRegion.find` and not "the first region that is not in
            // the before-map": muting the source RENAMES it (`Crash` ->
            // `Crash, muted`), which the naive diff reported as the print.
            arrived = PrintedRegion.find(
                before: before.map(ArrangementRegion.init),
                after: after.map(ArrangementRegion.init),
                requestedName: name
            )
            if arrived != nil { break }
        }
        guard let arrived else {
            throw LogicianError.verificationFailed(
                requested: "a new region printed into the arrangement",
                actual: "no new region appeared within 90 s. The sheet was answered with OK, so a "
                    + "render may still be running, or the print landed on a track whose row is not "
                    + "rendered (logic_list_regions only sees visible rows). Either way an audio "
                    + "FILE may already be in the project's Media/Audio Files, and Undo does not "
                    + "remove those",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "printed",
            "scope": scope,
            "printed_region": [
                "track_name": arrived.track, "name": arrived.name,
                "start_bar": arrived.start, "end_bar": arrived.end
            ],
            "regions_before": before.count,
            "regions_after": after.count,
            "sheet": sheetState,
            "changed": changed,
            "printed_file": printedFileReport(folder: audioFolder, namesBefore: audioNamesBefore),
            "note": "The audio is now a REGION in the arrangement - that is the deliverable here, "
                + "not a file you hand over (that is logic_render_track). WHAT UNDO REVERSES: the "
                + "printed region and the source region's state. WHAT IT DOES NOT: the audio FILE "
                + "this print wrote into the project's Media/Audio Files, which stays on disk - it "
                + "is named in printed_file, and deleting it is yours to do. The sheet's settings "
                + "are the user's own and Logic keeps them for next time."
        ]
        if let anchor { result["source_region"] = anchor["name"] ?? NSNull() }
        if (sheetState[LogicUIStrings.Value.bypassEffectPlugIns] as? Bool) == true {
            result["warning"] = "'Bypass Effect Plug-ins' was ON, so the printed audio is DRY - the "
                + "track's inserts were NOT rendered into it. Pass bypass_effect_plugins: false to "
                + "print the sound as you hear it."
        }
        return result
    }
}
