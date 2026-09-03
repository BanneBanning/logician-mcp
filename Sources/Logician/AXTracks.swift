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
        try parsedTrackHeaders(in: trackHeaderGroup())
    }

    /// The same parse against a header group the caller already resolved, so a
    /// caller that also needs the scroll probe pays `trackHeaderGroup()` once
    /// instead of twice (see `tracksAreaScrollable(from:)`).
    func parsedTrackHeaders(in group: AXUIElement) -> [TrackHeader] {
        trackHeaderItems(in: group).compactMap { item in
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

    /// Does the Tracks area hold more rows than it is showing?
    ///
    /// Three answers, and the third is the point: `true` (Logic's own scroll bar
    /// says there is content outside the viewport), `false` (it says there is
    /// not) and `nil` (the question could not be asked — no scroll area, no
    /// scroll bar, no readable value). A scroll bar this code cannot find must
    /// never be reported as "everything fits", which is the failure
    /// `logic_list_tracks` shipped with; see `TrackListCompleteness`.
    ///
    /// The signal is the scroll bar's own visibility and range. A scroll area
    /// whose content fits either publishes no vertical scroll bar at all or
    /// publishes a disabled one; a scrolled or scrollable one publishes an
    /// enabled bar, and its `AXValue` (0…1) additionally says whether the top of
    /// the list is even on screen.
    ///
    /// **The probe itself is free; resolving the group for it was not.**
    /// Measured 2026-09-02: the parent walk plus the `AXVerticalScrollBar` read
    /// is **0.17 ms and 2 attribute reads**, while the `trackHeaderGroup()` this
    /// used to open with cost **25.2 of its 25.4 ms** — a second copy of the
    /// walk the caller had just finished. Callers that already hold the group
    /// use `tracksAreaScrollable(from:)`.
    func tracksAreaScrollable() -> (scrollable: Bool?, position: Double?) {
        guard let group = try? trackHeaderGroup() else { return (nil, nil) }
        return tracksAreaScrollable(from: group)
    }

    /// The scroll question asked of a header group the caller already resolved.
    func tracksAreaScrollable(from group: AXUIElement) -> (scrollable: Bool?, position: Double?) {
        // Walk UP to the enclosing scroll area: the header column sits under
        // several split/layout wrappers whose depth is not worth hardcoding.
        var current: AXUIElement? = group
        var scrollArea: AXUIElement?
        for _ in 0..<AXDepth.trackHeaderGroup {
            guard let element = current else { break }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXScrollArea" {
                scrollArea = element
                break
            }
            current = elementAttribute(element, kAXParentAttribute as String)
        }
        guard let area = scrollArea else { return (nil, nil) }
        guard let bar = elementAttribute(area, kAXVerticalScrollBarAttribute as String) else {
            // No bar published. That USUALLY means the content fits — but this
            // is exactly the inference that would turn "I cannot see" into "there
            // is nothing", so it stays unknown.
            //
            // And it is not the rare branch: measured 2026-09-02 on the
            // reference project, Logic publishes NO vertical scroll bar on the
            // Tracks scroll area at all, so this is the answer every call gets
            // and the one completeness signal that catches rows below the
            // viewport never fires. `TrackListCompleteness` reports that
            // silence as `scroll_signal: unavailable` rather than letting it
            // read as "everything fits".
            return (nil, nil)
        }
        let enabled = stringAttribute(bar, kAXEnabledAttribute as String)
        let position = Double(stringAttribute(bar, kAXValueAttribute as String))
        if enabled == "0" { return (false, position) }
        if enabled == "1" { return (true, position) }
        return (nil, position)
    }

    /// The header row a `(track_name, track_number)` pair names.
    ///
    /// The decision itself is `TrackRowAddressing.resolve`, shared with the
    /// arrangement's region rows since 2026-09-02 — this function's rule was
    /// the good one and the region tools had no equivalent, so the rule moved
    /// rather than being copied. Behaviour here is unchanged: exact name
    /// comparison, and a number that names a differently-named row refuses
    /// before anything is written.
    func resolveTrack(
        _ headers: [TrackHeader],
        name: String,
        number: Int?
    ) throws -> TrackHeader {
        let available = headers.map { "\($0.number): \($0.name)" }
        // The rows this refusal is about are the rows that can say whether
        // they are all of them — and they are already in hand, so the
        // completeness verdict is free (no AX read: the numbering gap and the
        // collapsed-stack flags come off `headers`; the scroll bar is not
        // asked, and its silence adds no evidence anyway). Computed only on
        // the failing branches, so the resolving call pays nothing.
        func missing(_ requested: String) -> LogicianError {
            let verdict = TrackListCompleteness.evaluate(
                rows: headers.map {
                    TrackListCompleteness.Row(
                        number: $0.number,
                        name: $0.name,
                        isStack: $0.disclosure != nil,
                        expanded: $0.expanded
                    )
                },
                scrollable: nil
            )
            guard let hint = TrackListCompleteness.hiddenRowsHint(verdict) else {
                return .trackNotFound(requested, available: available)
            }
            return .trackNotRendered(requested, available: available, hint: hint)
        }
        let verdict = TrackRowAddressing.resolve(
            rows: headers.map { TrackRowAddressing.Row(number: $0.number, name: $0.name) },
            name: name, number: number, caseInsensitive: false
        )
        switch verdict {
        case .resolved(let resolved):
            guard let header = headers.first(where: { $0.number == resolved }) else {
                throw LogicianError.trackNotFound(name, available: available)
            }
            return header
        case .numberNotFound(let missingNumber):
            throw missing("track \(missingNumber)")
        case .nameNotFound:
            throw missing(name)
        case .ambiguous(let numbers):
            throw LogicianError.trackAmbiguous(name, numbers: numbers)
        case .mismatch(let number, let expected, let actual):
            throw LogicianError.trackMismatch(number: number, expected: expected, actual: actual)
        }
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
        try selectTrackReportingRows(
            trackName: trackName,
            trackNumber: trackNumber,
            expectedProjectPath: expectedProjectPath
        ).result
    }

    /// `selectTrack`, plus the header rows it walked to resolve the target.
    ///
    /// A tool that selects a track and then CHANGES the track list —
    /// `logic_duplicate_track` — needs a "before" listing to tell the new row
    /// from the rows that were already there, and this walk is exactly that
    /// listing, one line before it was thrown away. Re-reading it cost 53–88 ms
    /// of an 807 ms call (measured 2026-09-01, `logic_duplicate_track` profile
    /// §3, candidate #2). The rows are read BEFORE the selection is written,
    /// which is sound for that use: a selection creates and removes no rows,
    /// and the target was resolved OUT of these very rows, so it is already
    /// rendered and there is nothing for Logic to scroll into view. Only the
    /// `selected` flags may be stale afterwards, and the "before" side of a
    /// create/duplicate verdict does not read them.
    func selectTrackReportingRows(
        trackName: String,
        trackNumber: Int?,
        expectedProjectPath: String?
    ) throws -> (result: [String: Any], rows: [TrackChange.Row]) {
        try verifyProjectPath(expectedProjectPath)

        let group = try trackHeaderGroup()
        // The group is already resolved, so parse THAT one: the no-argument
        // overload walks `trackHeaderGroup()` again, and that walk is 25.2 ms
        // of the 25.4 ms it costs (measured 2026-09-02, `logic_select_track`
        // profile).
        let parsed = parsedTrackHeaders(in: group)
        let rows = TrackChange.rows(
            headers: parsed.map { (number: $0.number, name: $0.name, selected: $0.selected) }
        )
        let target = try resolveTrack(parsed, name: trackName, number: trackNumber)
        let previous = parsed.first(where: \.selected)
        let previousDescription = previous.map { "\($0.number): \($0.name)" } ?? "unknown"

        if target.selected, trackSelectionVerified(target.item, name: target.name) {
            return (selectionResult(
                state: "already_selected",
                target: target,
                previous: previousDescription,
                writeRoute: "none"
            ), rows)
        }

        // The selection is about to MOVE. That is the one moment a deferred
        // control-surface restore has to be paid before anything else happens:
        // a plugin-edit view left standing on the surface makes Logic auto-open
        // plugin windows on the next track selection (the hazard recorded on
        // MCUController.hotEditView). Unconditional rather than
        // strip-matched, because "which strip the leaked view belongs to" is
        // not what decides whether Logic opens the windows — that a selection
        // changed at all is. Free on the path this deferral exists for: a
        // plugin tool re-addressing the strip it just wrote returns
        // `already_selected` above and never reaches this line.
        MCUController.settleSurfaceDebt(before: nil)
        // The selection is moving, so the inspector is about to be repainted
        // and any rename staleness recorded for the old one is spent.
        LogicAccessibility.forgetRenamedInPlace()
        // Focus is about to move; until the move is verified below, the only
        // honest focus record is none (a failed or half-restored selection
        // must not leave the previous strip's name standing).
        MCUController.forgetChannelFocus()

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
                    && stringAttribute($0, kAXDescriptionAttribute as String)
                        == LogicUIStrings.Element.hasFocus
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

        // A track selection that actually MOVED carries Logic's focused
        // channel with it (the observed realignment for a diverged surface is
        // exactly this: a real selection change). The `already_selected` fast
        // path above deliberately records nothing — a still-selected header
        // proves nothing about the focused channel, which is the silent
        // wrong-strip bug of 2026-08-31.
        MCUController.noteChannelFocus(target.name, projectPath: try? projectDocumentPath())
        return (selectionResult(
            state: "selected",
            target: target,
            previous: previousDescription,
            writeRoute: writeRoute
        ), rows)
    }

    /// Waits for the selection write to be readable on both planes.
    ///
    /// This one sleeps BEFORE it looks, and stays that way: the
    /// `logic_select_track` profile of 2026-09-02 ran a zero-wait probe here
    /// and it MISSED on 4 of 4 — Logic's inspector-strip repaint genuinely
    /// lags the `AXSelectedChildren` write — while every real move converged
    /// on the first look 100 ms later. The settle is somewhere in (0, 100] ms
    /// and shortening the tick needs a distribution experiment, not a guess.
    func pollTrackSelected(_ item: AXUIElement, name: String) -> Bool {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if trackSelectionVerified(item, name: name) {
                return true
            }
        }
        return false
    }

    /// Is the track the caller named really the selected one, on two
    /// independent planes?
    ///
    /// The header's `AXSelected` is the first. The second is the left
    /// inspector channel strip, which must show the same track — that is what
    /// catches a header claiming a selection the rest of the UI never
    /// followed.
    ///
    /// The inspector's name can be STALE rather than wrong, though, and
    /// exactly once: Logic does not repaint it when the selected track is
    /// renamed. `InspectorReadback` decides which of the two it is, and
    /// carries the measurement (a rename used to make its own follow-up call
    /// refuse after 8.9 s). Everything the old comparison rejected, it still
    /// rejects.
    func trackSelectionVerified(_ item: AXUIElement, name: String) -> Bool {
        guard stringAttribute(item, kAXSelectedAttribute as String) == "1" else {
            return false
        }
        if (try? inspectorStrip(named: name)) != nil { return true }
        // Only reached when the header says selected and the inspector does
        // not agree — which is either the rename staleness or the wrong-strip
        // state, and the extra reads are priced against the 8.9 s the first
        // case used to cost.
        let verdict = InspectorReadback.verdict(
            requested: name,
            selectedHeaderName: parseTrackDescription(
                stringAttribute(item, kAXDescriptionAttribute as String)
            )?.name,
            inspectorName: leftInspectorStripName(),
            renderedNames: ((try? parsedTrackHeaders()) ?? []).map(\.name),
            renamedInPlace: LogicAccessibility.renamedInPlace
        )
        if case .staleAfterRename = verdict { return true }
        return false
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

    /// Resolves `setTrackStack`'s target header, calling the scroll-insurance
    /// `selectAndRetry` closure only when the plain header walk (`resolve`)
    /// does not already have the row.
    ///
    /// `selectTrack` auto-scrolls its target into view for the click that
    /// follows, but it used to run UNCONDITIONALLY, before this decision even
    /// existed — 142-304 ms live, 73-74% of a no-op call (measured
    /// 2026-09-03, profiles/logic_set_track_stack.md §5). Every one of the 8
    /// live toggles in that profile found the stack's header inside the
    /// always-rendered range, so `resolve()` always answered there and
    /// `selectAndRetry` never had to run; it exists for a stack further down
    /// an unscrolled list, not the common case. Pure and closure-driven —
    /// mirrors `MCUController.resolveMetronomeState` — so the ORDER is
    /// unit-tested without a live AX walk: `selectAndRetry` must not run at
    /// all when `resolve` already answers.
    static func resolveTrackStackTarget<T>(
        resolve: () -> T?,
        selectAndRetry: () -> T?
    ) -> T? {
        if let found = resolve() { return found }
        return selectAndRetry()
    }

    func setTrackStack(
        trackName: String,
        trackNumber: Int?,
        expanded: Bool,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)

        let group = try trackHeaderGroup()
        var before = parsedTrackHeaders(in: group)
        let preSelection = before.first(where: \.selected)

        let target: TrackHeader
        if let resolved = LogicAccessibility.resolveTrackStackTarget(
            resolve: { try? resolveTrack(before, name: trackName, number: trackNumber) },
            selectAndRetry: {
                _ = try? selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
                before = parsedTrackHeaders(in: group)
                return try? resolveTrack(before, name: trackName, number: trackNumber)
            }
        ) {
            target = resolved
        } else {
            // Neither the plain walk nor the scroll-insurance retry found the
            // row; let `resolveTrack`'s own error (unknown name/number,
            // ambiguous, hidden behind a collapsed ancestor stack, ...)
            // surface with its real message rather than a generic failure.
            target = try resolveTrack(before, name: trackName, number: trackNumber)
        }
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

        // AXPress, AXShowMenu and writing AXValue are all silent no-ops on
        // Logic's track header controls (verified 2026-08-24). This used to
        // try AXPress first anyway, polling 5 times (100 ms sleep + a full
        // header walk each) before falling back to the click below — 730-786
        // ms, 55-57% of every real toggle, spent on a write that can never
        // succeed. Removed 2026-09-03 (profiles/logic_set_track_stack.md §5):
        // go straight to the route that worked 8/8 live.
        let writeRoute = "cg_click_on_ax_frame"
        try clickElement(disclosure, describedAs: "disclosure triangle of '\(target.name)'")
        let verified = pollStackState(trackNumber: target.number, expanded: expanded, attempts: 20)
        guard verified else {
            throw LogicianError.openVerificationFailed(
                "The disclosure triangle of '\(target.name)' did not reach expanded=\(expanded)."
            )
        }
        var after = parsedTrackHeaders(in: group)

        // The click route also selects the stack's main track; restore the
        // previous selection when that track is still visible.
        var selectionRestored = "unchanged"
        if let previouslySelected = preSelection {
            let selectionMoved = after.first(where: \.selected)?.number != previouslySelected.number
            if selectionMoved {
                if let stillVisible = after.first(where: { $0.number == previouslySelected.number }),
                   AXUIElementSetAttributeValue(
                       group,
                       "AXSelectedChildren" as CFString,
                       [stillVisible.item] as CFArray
                   ) == .success,
                   pollTrackSelected(stillVisible.item, name: stillVisible.name) {
                    selectionRestored = "restored"
                    after = parsedTrackHeaders(in: group)
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

    /// Waits for the disclosure triangle's expansion state to reach
    /// `expanded` after the click that changes it.
    ///
    /// Look-first (`lookFirstShouldSleep`): the click is a synchronous
    /// `CGEvent`, and this is now the only route (the dead `AXPress` attempt
    /// that used to precede it was removed 2026-09-03 — see `setTrackStack`).
    /// Every one of the 8 live toggles measured that day converged within
    /// ~2-3 attempts (profiles/logic_set_track_stack.md §5), so sleeping
    /// before the very first look was waste on the common case.
    func pollStackState(trackNumber: Int, expanded: Bool, attempts: Int) -> Bool {
        for attempt in 0..<attempts {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.1) }
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

    /// The named control on the strip a mixing tool is about to touch.
    ///
    /// Resolution is delegated to `stripForControls`: tracks are selected first
    /// (unchanged), and output/aux/bus strips — which have no track header and
    /// used to throw `trackNotFound` right here — are addressed by name in the
    /// inspector instead.
    func selectedStripChild(
        trackName: String,
        trackNumber: Int?,
        description: String
    ) throws -> AXUIElement {
        let strip = try stripForControls(trackName: trackName, trackNumber: trackNumber).strip
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
        enabled: Bool,
        expectedCurrent: Bool? = nil
    ) throws -> [String: Any] {
        let button = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber, description: control
        )
        let current = stringAttribute(button, kAXValueAttribute as String) == LogicUIStrings.Value.on
        // Compare-and-set, from the same read that decides whether to press.
        if let expectedCurrent, current != expectedCurrent {
            throw LogicianError.currentValueMismatch(
                expected: "\(control)=\(expectedCurrent)", actual: "\(control)=\(current)"
            )
        }
        if current == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "track": trackName, "track_name": trackName, "control": control, control: enabled
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
            ), (stringAttribute(refreshed, kAXValueAttribute as String)
                == LogicUIStrings.Value.on) == enabled {
                return [
                    "success": true, "verified": true,
                    "state": enabled ? "on" : "off",
                    "track": trackName, "track_name": trackName, "control": control, control: enabled,
                    "write_route": "ax_press_inspector_strip"
                ]
            }
        }
        throw LogicianError.verificationFailed(
            requested: "\(control)=\(enabled)", actual: "\(control)=\(current)", restored: false
        )
    }

    func decibelValue(of element: AXUIElement) -> Double? {
        Double(LogicUIStrings.Format.normalizedDecibelText(
            stringAttribute(element, kAXValueDescriptionAttribute as String)
        ))
    }

    func setTrackVolume(
        trackName: String,
        trackNumber: Int?,
        request: VolumeWrite,
        toleranceDb: Double
    ) throws -> [String: Any] {
        let fader = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber,
            description: LogicUIStrings.Element.volumeFader
        )
        guard let beforeDb = decibelValue(of: fader) else {
            throw LogicianError.valueNotWritable("the volume fader exposes no readable dB value")
        }
        // Compare-and-set and relative_db, resolved against the dB this route
        // has already read, before the first AXValue write.
        let targetDb = try request.target(currentDb: beforeDb)
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
            "track": trackName, "track_name": trackName,
            "before_db": round(beforeDb * 10) / 10,
            "after_db": round(achievedDb * 10) / 10,
            "requested_db": targetDb,
            "write_route": "ax_value_stepwise_db_converge"
        ]
    }

    func setTrackPan(
        trackName: String,
        trackNumber: Int?,
        position: Int,
        expectedCurrentPosition: Int? = nil
    ) throws -> [String: Any] {
        let knob = try selectedStripChild(
            trackName: trackName, trackNumber: trackNumber,
            description: LogicUIStrings.Element.pan
        )
        guard let minRaw = Int(stringAttribute(knob, kAXMinValueAttribute as String)),
              let maxRaw = Int(stringAttribute(knob, kAXMaxValueAttribute as String)),
              position >= minRaw, position <= maxRaw else {
            throw LogicianError.invalidArguments("pan position must be within the knob's range")
        }
        let before = Int(stringAttribute(knob, kAXValueAttribute as String)) ?? 0
        // Compare-and-set: the knob's position was read anyway to report
        // `before`, so refusing on a stale idea of it costs nothing.
        if let expectedCurrentPosition, before != expectedCurrentPosition {
            throw LogicianError.currentValueMismatch(
                expected: "pan \(expectedCurrentPosition)", actual: "pan \(before)"
            )
        }
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
            "track": trackName, "track_name": trackName, "before": before, "after": position,
            "write_route": "ax_value_stepwise"
        ]
    }

}

// MARK: - The confirmation Logic raises when a track still holds regions

/// `Delete Track` is not always silent. Measured 2026-08-28: deleting a track
/// that still has REGIONS on it raises a critical alert —
///
/// ```
/// AXWindow (AXDialog), no title
///   AXImage      'Logic Pro critical alert'
///   AXStaticText 'Delete Track and Regions?'
///   AXStaticText 'Deleting this track also deletes the regions on the track.'
///   AXButton     'Cancel' | 'Delete'   (Delete is the default)
/// ```
///
/// — and it is MODAL: the key-command plane is swallowed while it stands, so
/// the tool that fired the command reported "the track is still listed; a
/// dialog may need attention" and everything after it stalled until a human
/// pressed a button. Earlier sessions deleted only EMPTY tracks, which is why
/// nobody had seen it.
///
/// STILL STRING-GATED for RECOGNITION, and this is the one place where that
/// is a decision rather than a gap. The alert's shape — two buttons, two
/// static texts, one image, no identifiers — describes half of Logic's
/// alerts, so shape cannot tell this one from any other two-button
/// confirmation. Widening the gate to "any two-button alert" would let an
/// unattended tool press `Delete` on something it never measured, and
/// deleting the wrong track is unrecoverable in practice. So a translated
/// heading means the alert is NOT recognised, the answer falls to Cancel, the
/// delete is abandoned and the tool says so — the safe direction.
///
/// The ANSWER, once recognised, is structural: `Delete` is the alert's
/// default button and `Cancel` its cancel button, both addressed through
/// `AXDefaultButton`/`AXCancelButton` with the English titles as fallback.
enum TrackDeletionAlert {
    static let heading = LogicUIStrings.AlertMarker.deleteTrackAndRegions

    enum Answer: String {
        case delete
        case cancel
    }

    /// Which button to press. `Delete` requires BOTH that the alert is the one
    /// we know AND that the selection still names the track the caller asked
    /// for — an unrecognised alert, or a selection that moved, is cancelled.
    /// Deleting the wrong track is unrecoverable in practice (Undo is a blind
    /// instrument, see the guide's cautions), so the doubt goes to Cancel.
    static func answer(texts: [String], selectionMatches: Bool) -> Answer {
        let recognised = texts.contains {
            $0.localizedCaseInsensitiveContains(heading)
        }
        return recognised && selectionMatches ? .delete : .cancel
    }
}

extension LogicAccessibility {

    /// The delete-track confirmation if one is up RIGHT NOW — one look, no
    /// waiting.
    ///
    /// This is the shape callers want, because "no alert" is a negative proof
    /// and a negative proof is never worth a timeout of its own: measured
    /// 2026-09-01, `logic_delete_track` spent 2.57–2.64 s of a 3.3 s call
    /// waiting out the full timeout below for an alert that never comes on a
    /// track with no regions (7 of 7 runs). `handleDeleteTrack` asks this
    /// question inside the loop that is already watching for the row to go, so
    /// the wait ends when the deletion lands rather than when the alert gives
    /// up.
    func trackDeletionAlertNow() -> AXUIElement? {
        for window in (try? logicWindows()) ?? []
        where stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog" {
            if alertTexts(window).contains(where: {
                $0.localizedCaseInsensitiveContains(TrackDeletionAlert.heading)
            }) {
                return window
            }
        }
        return nil
    }

    /// The delete-track confirmation, waited for. Look first, sleep only after
    /// a miss.
    func trackDeletionAlert(timeout: Double = 2.5) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let alert = trackDeletionAlertNow() { return alert }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// The static texts of an alert, in order — the evidence the answer is
    /// decided on, and what the result reports.
    func alertTexts(_ alert: AXUIElement) -> [String] {
        children(of: alert)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXStaticText" }
            .map { stringAttribute($0, kAXValueAttribute as String) }
            .filter { !$0.isEmpty }
    }

    /// Presses one of the alert's buttons and waits for it to go away.
    @discardableResult
    func answerTrackDeletionAlert(_ alert: AXUIElement, _ answer: TrackDeletionAlert.Answer) -> Bool {
        // `Delete` is this alert's DEFAULT button and `Cancel` its cancel
        // button (measured 2026-08-28, see the tree above), so both are
        // addressed structurally first and by English title only if the alert
        // publishes neither attribute.
        let structural = answer == .delete ? defaultButton(of: alert) : cancelButton(of: alert)
        let title = answer == .delete ? LogicUIStrings.Button.delete : LogicUIStrings.Button.cancel
        guard let button = structural ?? children(of: alert).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == title
        }) else { return false }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // Look before sleeping here too: the press usually tears the alert
        // down before it returns, and a miss should cost a tick rather than a
        // seventh of a second.
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            if trackDeletionAlertNow() == nil { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: TrackChange.deletePollInterval)
        }
    }

    /// The selected track's name, or nil when the list cannot be read (a modal
    /// can make that happen, and "cannot read" must never look like "matches").
    func selectedTrackName() -> String? {
        guard let listing = try? listTracks(),
              let rows = listing["tracks"] as? [[String: Any]],
              let selected = rows.first(where: { $0["selected"] as? Bool == true })
        else { return nil }
        return selected["track_name"] as? String
    }
}
