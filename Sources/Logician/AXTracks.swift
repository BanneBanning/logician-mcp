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

    /// Walks UP from the header column to the scroll area that clips it: the
    /// headers sit under several split/layout wrappers whose depth is not
    /// worth hardcoding. nil when the walk runs out.
    func enclosingScrollArea(of group: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = group
        for _ in 0..<AXDepth.trackHeaderGroup {
            guard let element = current else { return nil }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXScrollArea" {
                return element
            }
            current = elementAttribute(element, kAXParentAttribute as String)
        }
        return nil
    }

    /// One element's published frame in screen coordinates, or nil when it
    /// publishes none this code can decode.
    func elementFrame(_ element: AXUIElement) -> CGRect? {
        attribute(element, "AXFrame").flatMap { rectValue($0) }
    }

    /// The rectangle the Tracks area actually DRAWS its header rows in — the
    /// enclosing scroll area's frame. Rows scrolled out of it are still
    /// published, with coordinates outside it (see `stackHeaderIsReachable`).
    func tracksAreaViewport(from group: AXUIElement) -> CGRect? {
        enclosingScrollArea(of: group).flatMap { elementFrame($0) }
    }

    /// The scroll question asked of a header group the caller already resolved.
    func tracksAreaScrollable(from group: AXUIElement) -> (scrollable: Bool?, position: Double?) {
        guard let area = enclosingScrollArea(of: group) else { return (nil, nil) }
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
    ///
    /// - Parameter caseInsensitive: `logic_track_info` has always matched its
    ///   `track_name`/`track_names` case-insensitively and keeps doing so; the
    ///   writing paths compare exactly, as they always have. Only the
    ///   comparison changes — the refusals, and which rows count as ambiguous,
    ///   are the shared rule either way.
    func resolveTrack(
        _ headers: [TrackHeader],
        name: String,
        number: Int?,
        caseInsensitive: Bool = false
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
            name: name, number: number, caseInsensitive: caseInsensitive
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
    ///
    /// It also hands back the inspector channel strip its own verification
    /// walked to — see `SelectionVerification`. `nil` when the verification
    /// landed on the rename-staleness branch, where no strip of that name
    /// exists to hand back, or on the header-only branch, where no strip
    /// exists at all — `inspector` tells the caller which, so a caller that
    /// wanted the strip knows whether to go looking for one.
    func selectTrackReportingRows(
        trackName: String,
        trackNumber: Int?,
        expectedProjectPath: String?
    ) throws -> (
        result: [String: Any],
        rows: [TrackChange.Row],
        strip: AXUIElement?,
        inspector: InspectorPresence?
    ) {
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

        let standing = target.selected
            ? verifySelection(target.item, name: target.name)
            : .headerNotSelected
        if standing.isVerified {
            return (selectionResult(
                state: "already_selected",
                target: target,
                previous: previousDescription,
                writeRoute: "none",
                readbackRoute: standing.verification.readbackRoute
            ), rows, standing.strip, standing.inspector)
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
        var landed = SelectionEvidence.headerNotSelected
        let setStatus = AXUIElementSetAttributeValue(
            group,
            "AXSelectedChildren" as CFString,
            [target.item] as CFArray
        )
        if setStatus == .success {
            landed = pollSelectionVerified(target.item, name: target.name)
        }
        if !landed.isVerified {
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
            landed = pollSelectionVerified(target.item, name: target.name)
            guard landed.isVerified else {
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
            writeRoute: writeRoute,
            readbackRoute: landed.verification.readbackRoute
        ), rows, landed.strip, landed.inspector)
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
        pollSelectionVerified(item, name: name).isVerified
    }

    /// `pollTrackSelected`, keeping the inspector strip its last look walked
    /// to. Same polling, same verification, same cost — the strip element is
    /// simply not thrown away, so a caller that is about to READ that strip
    /// does not walk the depth-12 tree a second time for the element the
    /// verification already held (`trackInfo` paid that twice per track:
    /// 143 ms of a 1 149 ms single-track call, ≈2.8 s of a 19-track read;
    /// profiles/logic_track_info.md §6).
    func pollSelectionVerified(_ item: AXUIElement, name: String) -> SelectionEvidence {
        var lastKnown: InspectorPresence?
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let evidence = verifySelection(item, name: name)
            if let presence = evidence.inspector { lastKnown = presence }
            if evidence.isVerified {
                return evidence
            }
        }
        return SelectionEvidence(verification: .notSelected, inspector: lastKnown)
    }

    /// What `trackSelectionVerified` decided, and — when the inspector itself
    /// was the witness — the strip element that witnessed it.
    enum SelectionVerification {
        /// The two planes do not agree that this track is selected.
        case notSelected
        /// The inspector publishes this track's channel strip. This element.
        case verified(strip: AXUIElement)
        /// The header says selected and the inspector's name lags because the
        /// track was renamed in place — a verified selection with no strip of
        /// that name to hand back (see `InspectorReadback`).
        case verifiedStaleName
        /// The header says selected and there is no inspector plane to ask:
        /// Logic's Inspector is hidden, so it publishes no channel strip for
        /// any track (see `InspectorPresence`). Verified on the one plane that
        /// exists — the same header row `InspectorReadback` already trusts
        /// when the two planes disagree — and with no strip to hand back.
        case verifiedHeaderOnly

        var isVerified: Bool {
            if case .notSelected = self { return false }
            return true
        }

        /// The witnessing strip, or `nil` when the witness was not one — a
        /// caller that wants to read the strip must resolve it itself rather
        /// than be handed a guess.
        var strip: AXUIElement? {
            if case .verified(let strip) = self { return strip }
            return nil
        }

        /// What the result publishes as `readback_route`. A header-only
        /// verification must not claim the inspector confirmed anything.
        var readbackRoute: String {
            if case .verifiedHeaderOnly = self { return "ax_selected_header_row" }
            return "ax_selected_and_inspector_strip"
        }
    }

    /// One look at the selection: what it decided, and what the inspector
    /// plane was able to say while deciding it.
    ///
    /// The presence rides along because it is FREE here — the look walks the
    /// inspector strips anyway — and because it is the fact the caller's
    /// result has to publish. `nil` means this look never had to ask: the
    /// header row said "not selected" and there was nothing to cross-check,
    /// which is not the same as an inspector that was asked and said nothing.
    struct SelectionEvidence {
        let verification: SelectionVerification
        let inspector: InspectorPresence?

        var isVerified: Bool { verification.isVerified }
        var strip: AXUIElement? { verification.strip }

        /// The cheap early out: the header row itself is not selected, so no
        /// inspector walk was taken.
        static var headerNotSelected: SelectionEvidence {
            SelectionEvidence(verification: .notSelected, inspector: nil)
        }
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
    ///
    /// And the inspector plane can be ABSENT rather than disagreeing: with
    /// Logic's Inspector hidden there is no channel strip for any track, which
    /// is not evidence against a selection and must not be read as any. See
    /// `InspectorPresence` for what that cost before 2026-09-03 (a 15.7 s
    /// refusal naming the row it had just selected).
    func trackSelectionVerified(_ item: AXUIElement, name: String) -> Bool {
        verifySelection(item, name: name).isVerified
    }

    /// The verification itself, keeping the strip it proved the selection with
    /// — `trackSelectionVerified`'s answer plus the element it found on the
    /// way to it. Nothing about the decision changed when this grew a return
    /// value: every state the boolean rejected, this rejects.
    ///
    /// ONE inspector walk, whatever it decides. It used to take up to three —
    /// `inspectorStrip(named:)`, then `leftInspectorStripName()`, then the
    /// header column — and the disagreement path took all three on every one
    /// of `pollSelectionVerified`'s twenty looks, which is where the 15.7 s
    /// hidden-Inspector refusal actually went. The strips list is walked here
    /// and every question is asked of THAT list.
    func verifySelection(_ item: AXUIElement, name: String) -> SelectionEvidence {
        guard stringAttribute(item, kAXSelectedAttribute as String) == "1" else {
            return .headerNotSelected
        }
        guard let strips = try? inspectorStrips() else {
            // No project window: the cross-check was not refused, it was
            // impossible, and an impossible cross-check verifies nothing.
            return SelectionEvidence(verification: .notSelected, inspector: .unavailable)
        }
        guard !strips.isEmpty else {
            // Logic's Inspector is hidden. There is no second plane, so the
            // header row is the whole of the evidence — and it is the same
            // evidence `InspectorReadback` already trusts to overrule a strip
            // that disagrees.
            return SelectionEvidence(verification: .verifiedHeaderOnly, inspector: .hidden)
        }
        if let strip = matchInspectorStrip(strips, named: name) {
            return SelectionEvidence(verification: .verified(strip: strip), inspector: .shown)
        }
        // Only reached when the header says selected and the inspector does
        // not agree — which is either the rename staleness or the wrong-strip
        // state, and the extra reads are priced against the 8.9 s the first
        // case used to cost.
        let verdict = InspectorReadback.verdict(
            requested: name,
            selectedHeaderName: parseTrackDescription(
                stringAttribute(item, kAXDescriptionAttribute as String)
            )?.name,
            inspectorName: leftInspectorStrip(of: strips)?.name,
            renderedNames: ((try? parsedTrackHeaders()) ?? []).map(\.name),
            renamedInPlace: LogicAccessibility.renamedInPlace
        )
        if case .staleAfterRename = verdict {
            return SelectionEvidence(verification: .verifiedStaleName, inspector: .shown)
        }
        return SelectionEvidence(verification: .notSelected, inspector: .shown)
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

    /// `readbackRoute` is passed in rather than hardcoded: a selection proved
    /// off the header row alone, because Logic's Inspector is hidden, must not
    /// publish `ax_selected_and_inspector_strip` — the whole point of the
    /// field is that an agent can see which planes agreed.
    func selectionResult(
        state: String,
        target: TrackHeader,
        previous: String,
        writeRoute: String,
        readbackRoute: String
    ) -> [String: Any] {
        [
            "success": true,
            "verified": true,
            "state": state,
            "track_number": target.number,
            "track_name": target.name,
            "previous_selection": previous,
            "write_route": writeRoute,
            "readback_route": readbackRoute
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

    /// What `setTrackStack` may do after the Accessibility press did not move
    /// the disclosure triangle: take the pointer, or refuse and say how to
    /// let it.
    ///
    /// Pure, because the sentence is the product here — the caller has to be
    /// told which route was tried, that it is the mouse-free one, and that the
    /// alternative is opt-in.
    enum StackFoldFallback: Equatable {
        case mouse
        case refuse(String)
    }

    /// A press Logic really carries out takes 42-54 ms to return (measured
    /// 2026-09-03, 4/4). One that comes back in a fraction of a millisecond
    /// with `.success` and moves nothing is the signature of this machine's
    /// AX-ACTION degradation, where reads and attribute writes keep working
    /// and `AXUIElementPerformAction` becomes a no-op app-wide — measured
    /// again the same session on the disclosure triangles of all three
    /// stacks AND on a header's `Has Focus` button, 0.0-0.1 ms each, while
    /// `logic_select_track`'s `AXSelectedChildren` write kept landing.
    static let inertActionMilliseconds = 5.0

    static func stackFoldFallback(
        allowMouse: Bool, trackName: String, expanded: Bool, pressMilliseconds: Double
    ) -> StackFoldFallback {
        guard !allowMouse else { return .mouse }
        var reason = "the Accessibility press on the disclosure triangle of '\(trackName)' did not"
            + " \(expanded ? "open" : "close") the stack. That press is the mouse-free route"
            + " and it is the only one Logic leaves: the triangle's AXValue is not settable,"
            + " the header row publishes no AXDisclosing, and Logic 12.3.1 would not learn a MIDI"
            + " note for its own Open/Close Track Stack row, or for the directional Open Track"
            + " Stack (measured 2026-09-03, five attempts across both)."
        if pressMilliseconds < inertActionMilliseconds {
            reason += " The press returned success in"
                + " \(String(format: "%.1f", pressMilliseconds)) ms, where one Logic actually"
                + " carries out takes 42-54 ms — the signature of Logic's Accessibility ACTIONS"
                + " having gone inert app-wide (reads and selection writes keep working; measured"
                + " 2026-09-03). Nothing this server can write will fold the stack while that"
                + " lasts, EXCEPT the click below, which is not an Accessibility action."
        }
        reason += " The remaining route is a synthetic mouse click on the triangle's published"
            + " frame, which this tool does NOT take unless you ask: call again with"
            + " allow_mouse: true. Nothing was changed."
        return .refuse(reason)
    }

    /// Can a write reach this disclosure triangle where it is drawn?
    ///
    /// MEASURED 2026-09-03, and it is the explanation for the six consecutive
    /// "hit test at the position of disclosure triangle … did not resolve to
    /// that element" refusals recorded that day: after an expand scrolled the
    /// Tracks area, stack 9's own triangle was published at **y = -284** —
    /// above the top of the screen — so the hit test resolved to nothing
    /// (`kAXErrorIllegalArgument`) and the guard correctly refused to click at
    /// a point no window covers. One `logic_select_track` on the stack's main
    /// track brought it back to y = 206 and the hit test resolved again.
    ///
    /// UNKNOWN IS REACHABLE. A viewport this code could not read must never
    /// become the reason a working write is turned away — the same rule
    /// `TracksAreaFocus` follows for its own probe.
    static func stackHeaderIsReachable(disclosure: CGRect?, visible: CGRect?) -> Bool {
        guard let disclosure, !disclosure.isEmpty, let visible, !visible.isEmpty else { return true }
        return visible.contains(CGPoint(x: disclosure.midX, y: disclosure.midY))
    }

    func setTrackStack(
        trackName: String,
        trackNumber: Int?,
        expanded: Bool,
        allowMouse: Bool = false,
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
        guard var disclosure = target.disclosure, let currentlyExpanded = target.expanded else {
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

        // A row Logic PUBLISHES is not necessarily a row Logic DRAWS. The
        // header column keeps its scrolled-out rows in the Accessibility tree
        // with off-screen coordinates, so the walk above can hand back a stack
        // whose triangle is at y = -284 — and then the click route's hit test
        // resolves to nothing at all (the six refusals of 2026-09-03) and the
        // press has nothing on screen to press. One `selectTrack` on the
        // stack's own main track scrolls it back (measured: -284 → 206), which
        // is the same insurance this tool used to buy UNCONDITIONALLY on every
        // call; now it is bought only when the geometry says it is needed.
        var scrolledIntoView = false
        if !LogicAccessibility.stackHeaderIsReachable(
            disclosure: elementFrame(disclosure), visible: tracksAreaViewport(from: group)
        ) {
            _ = try? selectTrack(
                trackName: target.name, trackNumber: target.number, expectedProjectPath: nil
            )
            // Logic scrolls with an animation, so the frame is polled rather
            // than read once — and re-read off a fresh walk, because the
            // scroll republishes the header items.
            for attempt in 0..<6 {
                if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.06) }
                guard let refreshed = parsedTrackHeaders(in: group)
                    .first(where: { $0.number == target.number })?.disclosure else { continue }
                disclosure = refreshed
                if LogicAccessibility.stackHeaderIsReachable(
                    disclosure: elementFrame(refreshed), visible: tracksAreaViewport(from: group)
                ) {
                    scrolledIntoView = true
                    break
                }
            }
        }

        // THE FOLD IS MOUSE-FREE: `AXPress` on the disclosure triangle is the
        // route, and it is the whole route.
        //
        // This file said the opposite for ten days — "AXPress, AXShowMenu and
        // writing AXValue are all silent no-ops on Logic's track header
        // controls (verified 2026-08-24)" — and the 2026-09-03 profile agreed,
        // measuring the press falling through to the click 8/8. RE-MEASURED
        // 2026-09-03, same Logic 12.3.1, same sandbox project, same stack 9
        // `Drum Synth Kit`: the press lands, 4/4, both directions, in
        // 22-40 ms — and it lands with Logic in the BACKGROUND (tested with
        // Finder frontmost), so this route does not take the user's focus
        // either. What the earlier reading was of is not recoverable and is
        // not guessed at here; what IS recorded is how it is now checked, so
        // the claim can never go stale silently again: the press is followed
        // by `pollStackState`, and if the triangle does not move the tool says
        // so instead of assuming the route.
        //
        // The two attribute routes were re-read the same session and are
        // genuinely closed: the triangle's `AXValue` is NOT settable (Logic
        // publishes it 0/1 with an `AXMaxValue` of 127 and refuses the write —
        // the fold state did not change in 2 s), and the header row publishes
        // no `AXDisclosing` at all. Its only action is `AXPress`.
        //
        // AND THE KEY COMMAND STILL CANNOT REPLACE IT. Logic 12.3.1 ships the
        // rows (`Open Track Stack`, `Close Track Stack`, `Open/Close Track
        // Stack`, `Open/Close All Track Stacks` — read off the Key Commands
        // window 2026-09-03 under `Main Window Tracks and Various Editors`,
        // all four carrying no assignment of any kind), Logic refused four
        // rounds' worth of attempts to learn the TOGGLE, and the DIRECTIONAL
        // `Open Track Stack` was attempted once with the user's explicit
        // permission the same day (search term `track stack`, which is what
        // finds the row — the default `open track` scrolls past it): 10.98 s,
        // three candidate notes, `all candidate notes collided or verification
        // failed`, registry unchanged at 20. That last attempt ran while
        // Logic's Accessibility ACTIONS were inert (see the refusal text
        // below), and arming Logic's own Learn checkbox is itself an
        // `AXPress`, so it is recorded as a failure and NOT as proof that the
        // directional rows are unbindable. A learned note would also be the
        // worse route on the healthy path: a Tracks-scoped key command acts on
        // the SELECTED track, so it would make this call move the user's
        // selection first, where the press addresses the element itself.
        //
        // The mouse click stays as an `allow_mouse: true` fallback only, and
        // it is worth knowing why it cannot be the default: on 2026-09-03 six
        // consecutive folds refused with "hit test at the position of
        // disclosure triangle of 'Drum Synth Kit' did not resolve to that
        // element" while every Accessibility read around them worked. (It was
        // working again when this shipped — 474 ms expand / 212 ms collapse,
        // 2/2 — so that failure is transient and invisible, exactly the reason
        // a coordinate route is not something to depend on.)
        var writeRoute = "ax_press"
        var pressWasInert = false
        let pressStarted = Date()
        let pressStatus = AXUIElementPerformAction(disclosure, kAXPressAction as CFString)
        let pressMilliseconds = Date().timeIntervalSince(pressStarted) * 1000
        // 50 ms ticks over 5 attempts, not the click route's 100 over 20: the
        // press settles in 22-40 ms measured, so this is already ten times the
        // observed wait, and a look comes first. A press that is going to be
        // inert should say so quickly — that refusal is what the caller acts
        // on.
        var verified = pressStatus == .success
            && pollStackState(
                trackNumber: target.number, expanded: expanded, attempts: 5, interval: 0.05
            )
        if !verified {
            pressWasInert = true
            switch LogicAccessibility.stackFoldFallback(
                allowMouse: allowMouse, trackName: target.name, expanded: expanded,
                pressMilliseconds: pressMilliseconds
            ) {
            case .refuse(let reason):
                throw LogicianError.trackNotExposed(
                    requested: "\(expanded ? "expanding" : "collapsing") the track stack"
                        + " '\(target.name)' without the pointer",
                    exposed: reason
                )
            case .mouse:
                writeRoute = "cg_click_on_ax_frame"
                // Re-read the triangle: the press may have republished the
                // header items under the element resolved above, and a click
                // on a stale frame is the one mistake this route cannot
                // survive.
                let refreshed = parsedTrackHeaders(in: group)
                    .first { $0.number == target.number }?.disclosure ?? disclosure
                try clickElement(refreshed, describedAs: "disclosure triangle of '\(target.name)'")
                verified = pollStackState(
                    trackNumber: target.number, expanded: expanded, attempts: 20
                )
            }
        }
        guard verified else {
            throw LogicianError.openVerificationFailed(
                "The disclosure triangle of '\(target.name)' did not reach expanded=\(expanded)."
            )
        }
        var after = parsedTrackHeaders(in: group)

        // The click route also selects the stack's main track; restore the
        // previous selection when that track is still visible. (The press
        // route leaves the selection alone, and then this block costs one
        // comparison.)
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

        var payload: [String: Any] = [
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
        if pressWasInert {
            // The pointer was taken, and the caller only knows that if this
            // says it: `write_route` names the click, and this names WHY the
            // mouse-free route was not enough this time.
            payload["ax_press_inert"] = true
            payload["ax_press_ms"] = Int(pressMilliseconds.rounded())
            payload["warning"] = "the mouse-free Accessibility press did not move the disclosure"
                + " triangle, so the allow_mouse click route was used and the pointer moved"
                + " briefly. The press is the normal route (measured 22-40 ms, 2026-09-03);"
                + " a press that returns in under a millisecond, as ax_press_ms will show, means"
                + " Logic's Accessibility actions have gone inert app-wide and every other"
                + " element-addressed write is affected too."
        }
        if scrolledIntoView {
            // The row was drawn off-screen and had to be scrolled back before
            // anything could be written to it. Worth saying: it means the
            // selection moved, and it is the state in which the mouse route
            // fails its own hit test.
            payload["scrolled_into_view"] = true
        }
        return payload
    }

    /// Waits for the disclosure triangle's expansion state to reach
    /// `expanded` after the write that changes it.
    ///
    /// Look-first (`lookFirstShouldSleep`): both write routes are synchronous
    /// — an `AXPress` and, behind `allow_mouse`, a `CGEvent` click — so the
    /// state is often already there on the first look. The press settles in
    /// 22-40 ms (measured 2026-09-03, 4/4), which is why its caller passes a
    /// 50 ms `interval` rather than the 100 ms the click route converged
    /// under in ~2-3 attempts (profiles/logic_set_track_stack.md §5).
    func pollStackState(
        trackNumber: Int, expanded: Bool, attempts: Int, interval: TimeInterval = 0.1
    ) -> Bool {
        for attempt in 0..<attempts {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: interval) }
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
    ///
    /// TWO CALL SITES, AND BOTH ARE NOW OPT-IN: the empty audio insert slot
    /// (`AXPlugins.swift`) and `setTrackStack`'s disclosure triangle both
    /// need `allow_mouse: true` from the caller. The stack fold was the
    /// exception until 2026-09-03, when the `AXPress` this file had written
    /// off as a no-op turned out to fold the stack in 22-40 ms, 4/4, with
    /// Logic in the background (see `setTrackStack`) — so nothing in this
    /// server takes the pointer without being asked any more.
    ///
    /// Do not add a third site. The route is coordinate-driven, and
    /// coordinates are the one thing this server's own reads cannot check:
    /// on the same day, six consecutive folds refused because the hit test at
    /// the element's OWN published frame did not resolve to the element, with
    /// every Accessibility read around it working normally.
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
        func readKnob() -> Int? { Int(stringAttribute(knob, kAXValueAttribute as String)) }
        let before = readKnob() ?? 0
        // Compare-and-set: the knob's position was read anyway to report
        // `before`, so refusing on a stale idea of it costs nothing.
        if let expectedCurrentPosition, before != expectedCurrentPosition {
            throw LogicianError.currentValueMismatch(
                expected: "pan \(expectedCurrentPosition)", actual: "pan \(before)"
            )
        }
        // The verified no-op, named the way its siblings name theirs
        // (the mute/solo sections report `already_on`/`already_off`):
        // the knob is where the caller asked for it and nothing was written.
        if before == position {
            return [
                "success": true, "verified": true, "state": "already_set",
                "track": trackName, "track_name": trackName, "before": before, "after": before,
                "readback_route": "ax_value"
            ]
        }
        var last = before
        for _ in 0..<(maxRaw - minRaw + 8) {
            guard let current = readKnob() else { break }
            if current == position { break }
            let status = AXUIElementSetAttributeValue(knob, kAXValueAttribute as CFString, position as CFNumber)
            guard status == .success else {
                throw LogicianError.writeFailed("AXValue write on the pan knob returned AXError \(status.rawValue)")
            }
            let after = settledStep(after: current, reading: readKnob) ?? current
            if after == last && after != position {
                throw LogicianError.verificationFailed(
                    requested: "pan \(position)", actual: "stuck at \(after)", restored: false
                )
            }
            last = after
        }
        guard readKnob() == position else {
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

    /// The knob's value after ONE write, read by LOOKING FIRST.
    ///
    /// PATTERN #9, and pattern #8 answered NEGATIVE first. The knob's own
    /// attribute list was read live (2026-09-03, `Crash`): nineteen
    /// attributes, `AXValue` settable, range -64…63, `AXValueDescription`
    /// "0" — and **no text path at all** (no `AXSelectedTextRange`, no
    /// `AXNumberOfCharacters`), with exactly two actions, `AXIncrement` and
    /// `AXDecrement`. So it is a genuine stepper, not a text field in
    /// disguise and not a jump-capable control being mis-driven: there is no
    /// typed-absolute cure to reach for, and the per-step COST is the only
    /// thing there was to fix.
    ///
    /// This loop used to `Thread.sleep(0.03)` after every write,
    /// unconditionally — writing the absolute target to `AXValue` advances the
    /// knob exactly ONE raw unit — so that blind wait was paid once per raw
    /// unit of distance: 40–42 ms per step,
    /// flat, measured 2026-09-03 across seven step counts from 6 to 63
    /// (a 63-step move: 2 654 ms of write loop; a full -64→63 sweep
    /// extrapolated to ~5.4 s). `AXUIElementSetAttributeValue` is synchronous
    /// and the effect has been readable 0–6 ms later everywhere this plane has
    /// been measured, so the read is taken IMMEDIATELY and only a knob that
    /// has not moved yet is waited for — by re-reading, which is its own
    /// pacing (an AX read costs 1–4 ms). Measured live the same day: the
    /// 63-step move fell from 2 812 ms to 442 ms and the 5-step move from
    /// 522 ms to 384 ms, which puts the loop at roughly 2 ms a step against
    /// the 41 ms it used to be.
    ///
    /// `axStepperSettleBudget` is therefore not a per-step cost: it is the
    /// ceiling paid ONCE, by a knob that has genuinely stopped moving, on the
    /// way to the `stuck` verdict the caller raises.
    private func settledStep(after previous: Int, reading read: () -> Int?) -> Int? {
        let deadline = Date().addingTimeInterval(LogicAccessibility.axStepperSettleBudget)
        var seen = read()
        while seen == previous, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
            seen = read()
        }
        return seen
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
