import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Track headers and selection

    struct TrackHeader {
        let item: AXUIElement
        let number: Int
        let name: String
        let selected: Bool
        let disclosure: AXUIElement?
        let expanded: Bool?
    }

    func parsedTrackHeaders() throws -> [TrackHeader] {
        try trackHeaderItems().compactMap { item in
            guard let track = parseTrackDescription(stringAttribute(item, kAXDescriptionAttribute as String)) else {
                return nil
            }
            let disclosure = children(of: item).first {
                stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
            }
            return TrackHeader(
                item: item,
                number: track.number,
                name: track.name,
                selected: stringAttribute(item, kAXSelectedAttribute as String) == "1",
                disclosure: disclosure,
                expanded: disclosure.map { stringAttribute($0, kAXValueAttribute as String) == "1" }
            )
        }
    }

    func resolveTrack(
        _ headers: [TrackHeader],
        name: String,
        number: Int?
    ) throws -> TrackHeader {
        if let number = number {
            guard let byNumber = headers.first(where: { $0.number == number }) else {
                throw LogicianError.trackNotFound(
                    "track \(number)",
                    available: headers.map { "\($0.number): \($0.name)" }
                )
            }
            guard byNumber.name == name else {
                throw LogicianError.trackMismatch(number: number, expected: name, actual: byNumber.name)
            }
            return byNumber
        }
        let matches = headers.filter { $0.name == name }
        guard !matches.isEmpty else {
            throw LogicianError.trackNotFound(
                name,
                available: headers.map { "\($0.number): \($0.name)" }
            )
        }
        guard matches.count == 1, let match = matches.first else {
            throw LogicianError.trackAmbiguous(name, numbers: matches.map(\.number))
        }
        return match
    }

    func verifyProjectPath(_ expected: String?) throws {
        guard let expected = expected else { return }
        let actual = try projectDocumentPath()
        guard normalizedPath(expected) == normalizedPath(actual) else {
            throw LogicianError.projectMismatch(expected: expected, actual: actual)
        }
    }

    func selectTrack(
        trackName: String,
        trackNumber: Int?,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)

        let group = try trackHeaderGroup()
        let parsed = try parsedTrackHeaders()
        let target = try resolveTrack(parsed, name: trackName, number: trackNumber)
        let previous = parsed.first(where: \.selected)
        let previousDescription = previous.map { "\($0.number): \($0.name)" } ?? "unknown"

        if target.selected, trackSelectionVerified(target.item, name: target.name) {
            return selectionResult(
                state: "already_selected",
                target: target,
                previous: previousDescription,
                writeRoute: "none"
            )
        }

        var writeRoute = "ax_selected_children"
        let setStatus = AXUIElementSetAttributeValue(
            group,
            "AXSelectedChildren" as CFString,
            [target.item] as CFArray
        )
        if setStatus != .success || !pollTrackSelected(target.item, name: target.name) {
            // Fallback: press the header's "Has Focus" radio button.
            writeRoute = "has_focus_press"
            guard let focusButton = children(of: target.item).first(where: {
                stringAttribute($0, kAXRoleAttribute as String) == "AXRadioButton"
                    && stringAttribute($0, kAXDescriptionAttribute as String) == "Has Focus"
            }) else {
                throw LogicianError.writeFailed(
                    "AXSelectedChildren returned AXError \(setStatus.rawValue) and no Has Focus button was found"
                )
            }
            let pressStatus = AXUIElementPerformAction(focusButton, kAXPressAction as CFString)
            guard pressStatus == .success else {
                throw LogicianError.writeFailed("AXPress on Has Focus returned AXError \(pressStatus.rawValue)")
            }
            guard pollTrackSelected(target.item, name: target.name) else {
                let restored = restoreSelection(previous?.item, in: group)
                let actual = currentSelectionDescription()
                throw LogicianError.selectionFailed(requested: target.name, actual: actual, restored: restored)
            }
        }

        return selectionResult(
            state: "selected",
            target: target,
            previous: previousDescription,
            writeRoute: writeRoute
        )
    }

    func pollTrackSelected(_ item: AXUIElement, name: String) -> Bool {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if trackSelectionVerified(item, name: name) {
                return true
            }
        }
        return false
    }

    func trackSelectionVerified(_ item: AXUIElement, name: String) -> Bool {
        guard stringAttribute(item, kAXSelectedAttribute as String) == "1" else {
            return false
        }
        // Independent readback: the left inspector strip must show the same track.
        return (try? inspectorStrip(named: name)) != nil
    }

    func restoreSelection(_ previousItem: AXUIElement?, in group: AXUIElement) -> Bool {
        guard let item = previousItem else { return false }
        guard AXUIElementSetAttributeValue(
            group,
            "AXSelectedChildren" as CFString,
            [item] as CFArray
        ) == .success else { return false }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            if stringAttribute(item, kAXSelectedAttribute as String) == "1" {
                return true
            }
        }
        return false
    }

    func currentSelectionDescription() -> String {
        guard let items = try? trackHeaderItems() else { return "unknown" }
        let selected = items.filter { stringAttribute($0, kAXSelectedAttribute as String) == "1" }
        guard !selected.isEmpty else { return "none" }
        return selected
            .map { stringAttribute($0, kAXDescriptionAttribute as String) }
            .joined(separator: ", ")
    }

    func selectionResult(
        state: String,
        target: TrackHeader,
        previous: String,
        writeRoute: String
    ) -> [String: Any] {
        [
            "success": true,
            "verified": true,
            "state": state,
            "track_number": target.number,
            "track_name": target.name,
            "previous_selection": previous,
            "write_route": writeRoute,
            "readback_route": "ax_selected_and_inspector_strip"
        ]
    }

    // MARK: - Track stacks

    func setTrackStack(
        trackName: String,
        trackNumber: Int?,
        expanded: Bool,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)

        // Selecting the track first auto-scrolls its header into view; the
        // disclosure click needs the triangle on screen (hit-test guarded).
        let preSelection = try parsedTrackHeaders().first(where: \.selected)
        _ = try? selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let before = try parsedTrackHeaders()
        let target = try resolveTrack(before, name: trackName, number: trackNumber)
        guard let disclosure = target.disclosure, let currentlyExpanded = target.expanded else {
            throw LogicianError.trackNotStack(target.name)
        }

        if currentlyExpanded == expanded {
            return [
                "success": true,
                "verified": true,
                "state": expanded ? "already_expanded" : "already_collapsed",
                "track_number": target.number,
                "track_name": target.name
            ]
        }

        // AXPress, AXShowMenu and writing AXValue are all silent no-ops on Logic's
        // track header controls (verified 2026-08-24), so try AXPress briefly and
        // then fall back to a real click on the triangle's own AX frame.
        var writeRoute = "ax_press"
        _ = AXUIElementPerformAction(disclosure, kAXPressAction as CFString)
        var verified = pollStackState(trackNumber: target.number, expanded: expanded, attempts: 5)
        if !verified {
            writeRoute = "cg_click_on_ax_frame"
            try clickElement(disclosure, describedAs: "disclosure triangle of '\(target.name)'")
            verified = pollStackState(trackNumber: target.number, expanded: expanded, attempts: 20)
        }
        guard verified else {
            throw LogicianError.openVerificationFailed(
                "The disclosure triangle of '\(target.name)' did not reach expanded=\(expanded)."
            )
        }
        var after = (try? parsedTrackHeaders()) ?? []

        // The click route also selects the stack's main track; restore the
        // previous selection when that track is still visible.
        var selectionRestored = "unchanged"
        if let previouslySelected = preSelection {
            let selectionMoved = after.first(where: \.selected)?.number != previouslySelected.number
            if selectionMoved {
                if let stillVisible = after.first(where: { $0.number == previouslySelected.number }),
                   let group = try? trackHeaderGroup(),
                   AXUIElementSetAttributeValue(
                       group,
                       "AXSelectedChildren" as CFString,
                       [stillVisible.item] as CFArray
                   ) == .success,
                   pollTrackSelected(stillVisible.item, name: stillVisible.name) {
                    selectionRestored = "restored"
                    after = (try? parsedTrackHeaders()) ?? after
                } else {
                    selectionRestored = "lost"
                }
            }
        }

        let beforeNumbers = Set(before.map(\.number))
        let afterNumbers = Set(after.map(\.number))
        let revealed = after
            .filter { !beforeNumbers.contains($0.number) }
            .map { ["track_number": $0.number, "track_name": $0.name] }
        let hidden = before
            .filter { !afterNumbers.contains($0.number) }
            .map { ["track_number": $0.number, "track_name": $0.name] }

        return [
            "success": true,
            "verified": true,
            "state": expanded ? "expanded" : "collapsed",
            "track_number": target.number,
            "track_name": target.name,
            "write_route": writeRoute,
            "selection_restored": selectionRestored,
            "revealed_tracks": revealed,
            "hidden_tracks": hidden,
            "note": "Revealed/hidden tracks are the stack's subtracks as far as they fit in the rendered Tracks area."
        ]
    }

    func pollStackState(trackNumber: Int, expanded: Bool, attempts: Int) -> Bool {
        for _ in 0..<attempts {
            Thread.sleep(forTimeInterval: 0.1)
            guard let headers = try? parsedTrackHeaders(),
                  let refreshed = headers.first(where: { $0.number == trackNumber }) else { continue }
            if refreshed.expanded == expanded {
                return true
            }
        }
        return false
    }

    /// Clicks the center of an AX element's frame with a synthetic mouse event.
    /// Used only where Logic's semantic actions are verified no-ops. Refuses to
    /// click unless a hit test at that position resolves to the same element.
    func clickElement(_ element: AXUIElement, describedAs label: String) throws {
        guard let frameValue = attribute(element, "AXFrame") else {
            throw LogicianError.writeFailed("could not read the frame of \(label)")
        }
        // rectValue, not `as! AXValue`: a frame attribute that comes back as
        // some other CF type reports "could not decode" instead of trapping
        // and taking the server down with it.
        guard let frame = rectValue(frameValue), !frame.isEmpty else {
            throw LogicianError.writeFailed("could not decode the frame of \(label)")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)

        try ensureLogicFrontmost(for: label)

        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard hitStatus == .success, let hitElement = hit, elementCoversTarget(hitElement, target: element) else {
            throw LogicianError.writeFailed(
                "hit test at the position of \(label) did not resolve to that element; refusing to click"
            )
        }

        let previousLocation = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else {
            throw LogicianError.writeFailed("could not create mouse events for \(label)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        if let restore = previousLocation,
           let move = CGEvent(
               mouseEventSource: source,
               mouseType: .mouseMoved,
               mouseCursorPosition: restore,
               mouseButton: .left
           ) {
            Thread.sleep(forTimeInterval: 0.05)
            move.post(tap: .cghidEventTap)
        }
    }

    func elementCoversTarget(_ hit: AXUIElement, target: AXUIElement) -> Bool {
        var current: AXUIElement? = hit
        for _ in 0..<4 {
            guard let element = current else { return false }
            if CFEqual(element, target) {
                return true
            }
            // A parent that is not an element ends the walk (returns false,
            // "does not cover the target") instead of trapping.
            current = elementAttribute(element, kAXParentAttribute as String)
        }
        return false
    }

    // MARK: - Strip controls (mute/solo/volume/pan)

    func selectedStripChild(
        trackName: String,
        trackNumber: Int?,
        description: String
    ) throws -> AXUIElement {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        guard let control = children(of: strip).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "\(description) control on '\(trackName)'",
                exposed: "the inspector strip has no such control"
            )
        }
        return control
    }

    func setStripToggle(
        trackName: String,
        trackNumber: Int?,
        control: String, // "mute" or "solo"
        enabled: Bool
    ) throws -> [String: Any] {
        let button = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber, description: control
        )
        let current = stringAttribute(button, kAXValueAttribute as String) == "on"
        if current == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "track": trackName, "control": control, control: enabled
            ]
        }
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed("AXPress on \(control) returned AXError \(status.rawValue)")
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if let refreshed = try? selectedStripChild(
                trackName: trackName, trackNumber: trackNumber, description: control
            ), (stringAttribute(refreshed, kAXValueAttribute as String) == "on") == enabled {
                return [
                    "success": true, "verified": true,
                    "state": enabled ? "on" : "off",
                    "track": trackName, "control": control, control: enabled,
                    "write_route": "ax_press_inspector_strip"
                ]
            }
        }
        throw LogicianError.verificationFailed(
            requested: "\(control)=\(enabled)", actual: "\(control)=\(current)", restored: false
        )
    }

    func decibelValue(of element: AXUIElement) -> Double? {
        let text = stringAttribute(element, kAXValueDescriptionAttribute as String)
            .replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(text)
    }

    func setTrackVolume(
        trackName: String,
        trackNumber: Int?,
        targetDb: Double,
        toleranceDb: Double
    ) throws -> [String: Any] {
        let fader = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber, description: "volume fader"
        )
        guard let beforeDb = decibelValue(of: fader) else {
            throw LogicianError.valueNotWritable("the volume fader exposes no readable dB value")
        }
        guard let minRaw = Int(stringAttribute(fader, kAXMinValueAttribute as String)),
              let maxRaw = Int(stringAttribute(fader, kAXMaxValueAttribute as String)) else {
            throw LogicianError.valueNotWritable("the volume fader exposes no raw range")
        }

        // Each AXValue write moves the fader one raw step toward the written
        // value; converge on the dB readout, stopping at the closest step.
        var previousDb = beforeDb
        var achievedDb = beforeDb
        for _ in 0..<(maxRaw - minRaw + 8) {
            guard let raw = Int(stringAttribute(fader, kAXValueAttribute as String)),
                  let currentDb = decibelValue(of: fader) else { break }
            achievedDb = currentDb
            if abs(currentDb - targetDb) <= toleranceDb { break }
            if (previousDb - targetDb) * (currentDb - targetDb) < 0 {
                // Crossed the target between steps: keep whichever step is closer.
                if abs(previousDb - targetDb) < abs(currentDb - targetDb) {
                    let backTarget = currentDb > targetDb ? minRaw : maxRaw
                    _ = AXUIElementSetAttributeValue(fader, kAXValueAttribute as CFString, backTarget as CFNumber)
                    Thread.sleep(forTimeInterval: 0.05)
                    achievedDb = decibelValue(of: fader) ?? previousDb
                }
                break
            }
            if (currentDb < targetDb && raw >= maxRaw) || (currentDb > targetDb && raw <= minRaw) {
                break // at the end stop
            }
            previousDb = currentDb
            let stepTarget = currentDb < targetDb ? maxRaw : minRaw
            let status = AXUIElementSetAttributeValue(fader, kAXValueAttribute as CFString, stepTarget as CFNumber)
            guard status == .success else {
                throw LogicianError.writeFailed("AXValue write on the volume fader returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard abs(achievedDb - targetDb) <= max(toleranceDb, 0.25) else {
            throw LogicianError.verificationFailed(
                requested: String(format: "%.1f dB", targetDb),
                actual: String(format: "%.1f dB", achievedDb),
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "volume_set",
            "track": trackName,
            "before_db": round(beforeDb * 10) / 10,
            "after_db": round(achievedDb * 10) / 10,
            "requested_db": targetDb,
            "write_route": "ax_value_stepwise_db_converge"
        ]
    }

    func setTrackPan(
        trackName: String,
        trackNumber: Int?,
        position: Int
    ) throws -> [String: Any] {
        let knob = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber, description: "pan"
        )
        guard let minRaw = Int(stringAttribute(knob, kAXMinValueAttribute as String)),
              let maxRaw = Int(stringAttribute(knob, kAXMaxValueAttribute as String)),
              position >= minRaw, position <= maxRaw else {
            throw LogicianError.invalidArguments("pan position must be within the knob's range")
        }
        let before = Int(stringAttribute(knob, kAXValueAttribute as String)) ?? 0
        var last = before
        for _ in 0..<(maxRaw - minRaw + 8) {
            guard let current = Int(stringAttribute(knob, kAXValueAttribute as String)) else { break }
            if current == position { break }
            let status = AXUIElementSetAttributeValue(knob, kAXValueAttribute as CFString, position as CFNumber)
            guard status == .success else {
                throw LogicianError.writeFailed("AXValue write on the pan knob returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.03)
            let after = Int(stringAttribute(knob, kAXValueAttribute as String)) ?? current
            if after == last && after != position {
                throw LogicianError.verificationFailed(
                    requested: "pan \(position)", actual: "stuck at \(after)", restored: false
                )
            }
            last = after
        }
        guard Int(stringAttribute(knob, kAXValueAttribute as String)) == position else {
            throw LogicianError.verificationFailed(
                requested: "pan \(position)",
                actual: stringAttribute(knob, kAXValueAttribute as String),
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "pan_set",
            "track": trackName, "before": before, "after": position,
            "write_route": "ax_value_stepwise"
        ]
    }

}
