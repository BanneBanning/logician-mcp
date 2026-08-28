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
    func bounceInPlaceSheet(timeout: Double = 8) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for window in (try? logicWindows()) ?? [] {
                if stringAttribute(window, kAXRoleAttribute as String) == "AXSheet",
                   children(of: window).contains(where: {
                       stringAttribute($0, kAXValueAttribute as String)
                           .localizedCaseInsensitiveContains("Bounce")
                   }) {
                    return window
                }
                if let sheet = children(of: window).first(where: {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXSheet"
                }) {
                    return sheet
                }
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
    /// `cancelBounceDialog`: a modal left open freezes everything after it.
    func cancelBounceInPlaceSheet() {
        guard let sheet = bounceInPlaceSheet(timeout: 0.4),
              let cancel = sheetButton(sheet, "Cancel") else { return }
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
                    state[["Mute", "Leave", "Delete"].contains(title) ? "source" : "destination"] = title
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
        regionName: String?,
        startBar: Int?,
        name: String?,
        normalize: String?,
        destination: String?,
        source: String?,
        checkboxes: [String: Bool]
    ) throws -> [String: Any] {
        let menuItem = scope == "track" ? "Tracks in Place" : "Regions in Place"
        var anchor: [String: Any]?
        if scope == "region" {
            guard let trackName else {
                throw LogicianError.invalidArguments("scope 'region' needs track_name")
            }
            anchor = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
            )
            guard try selectedRegionCount() == 1 else {
                throw LogicianError.verificationFailed(
                    requested: "exactly one selected region before Bounce in Place",
                    actual: "\(try selectedRegionCount()) regions selected; refusing",
                    restored: false
                )
            }
        } else if let trackName {
            _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
        }
        let before = try flatRegionMap()

        try ensureLogicFrontmost(for: "the bounce-in-place sheet")
        try pressMenuItem(containing: menuItem, underMenu: "Bounce")
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
            ("destination", ["selected_track": "Selected Track", "new_track": "New Track"]),
            ("source", ["mute": "Mute", "leave": "Leave", "delete": "Delete"])
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

        guard let okButton = sheetButton(sheet, "OK") else {
            throw LogicianError.windowNotFound("the OK button in the bounce-in-place sheet")
        }
        _ = AXUIElementPerformAction(okButton, kAXPressAction as CFString)
        committed = true

        // The render is offline but not instant, and the arrangement map is
        // the proof: a region that was not there before.
        var after = before
        var arrived: (track: String, name: String, start: Int, end: Int)?
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            after = (try? flatRegionMap()) ?? after
            arrived = after.first { candidate in
                !before.contains {
                    $0.track == candidate.track && $0.name == candidate.name
                        && $0.start == candidate.start && $0.end == candidate.end
                }
            }
            if arrived != nil { break }
        }
        guard let arrived else {
            throw LogicianError.verificationFailed(
                requested: "a new region printed into the arrangement",
                actual: "no new region appeared within 90 s. The sheet was answered with OK, so a "
                    + "render may still be running, or the print landed on a track whose row is not "
                    + "rendered (logic_list_regions only sees visible rows)",
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
            "note": "The audio is now a REGION in the project (not a file on disk - that is "
                + "logic_render_track). Undo removes it and restores the source region's state. The "
                + "sheet's settings are the user's own and Logic keeps them for next time."
        ]
        if let anchor { result["source_region"] = anchor["name"] ?? NSNull() }
        if (sheetState["Bypass Effect Plug-ins"] as? Bool) == true {
            result["warning"] = "'Bypass Effect Plug-ins' was ON, so the printed audio is DRY - the "
                + "track's inserts were NOT rendered into it. Pass bypass_effect_plugins: false to "
                + "print the sound as you hear it."
        }
        return result
    }
}
