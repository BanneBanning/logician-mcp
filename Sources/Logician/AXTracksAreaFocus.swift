import AppKit
import ApplicationServices
import Foundation

/// Logic's Tracks-area KEYBOARD FOCUS — the precondition every region key
/// command has, and that none of them used to establish or check.
///
/// MEASURED 2026-09-01 (the `logic_copy_region` profile, sandbox project
/// `Testlåt Copy`): with Logic's key focus somewhere other than the Tracks
/// area, three copies in a row — one cold, two warm, across two server
/// processes — fired `Copy` and `Paste`, changed NOTHING, and refused after
/// 5.7 s of waiting with a message that told the agent to go looking for a
/// modal dialog, while `logic_list_windows` showed exactly one window and no
/// modal. In that same state `logic_move_region`'s Nudge did nothing and
/// `logic_select_regions` reported `1 -> 1` on a three-region track, but
/// `logic_markers`, whose `Create Marker` is a GLOBAL command, worked first
/// try. That is the whole split: Cut/Copy/Paste/Nudge/Select-All-of-Same-Track
/// /Delete act on the FOCUSED area, and a global command does not care.
///
/// The cure, measured: ONE `logic_select_track` that really wrote the
/// selection (`state: "selected"`, `write_route: "ax_selected_children"`).
/// Every copy after it landed — 5 of 5, including the cross-track one, the
/// cold one and the 39-bar-travel one. `selectRegion`'s best-effort
/// `AXFocused` write on the region element does NOT do it (it ran on every one
/// of the three failures), and `selectTrack` returns `already_selected`
/// WITHOUT writing whenever the destination track is already selected — which
/// is the common case for a same-track copy and was the case on all three
/// failures.
///
/// So the repair is a WRITE into the track header column, and the probe comes
/// first because that write costs ~85 ms plus verification and is only needed
/// when the focus is genuinely elsewhere.
enum TracksAreaFocus {

    /// The three attributes that decide whether an element belongs to the
    /// Tracks area. Pure input, so every signature below is pinned by tests
    /// rather than by a live Logic.
    struct ElementFacts: Equatable {
        let role: String
        let description: String
        let roleDescription: String

        init(role: String, description: String, roleDescription: String) {
            self.role = role
            self.description = description
            self.roleDescription = roleDescription
        }
    }

    /// Is this one element part of the Tracks area?
    ///
    /// POSITIVE signatures only — the question is asked of the focused element
    /// and of its ancestors, and a wrong "yes" would let a silent no-op copy
    /// through, so nothing is inferred from the absence of a marker. The four
    /// shapes are the ones the arrangement plane already reads elsewhere:
    /// a region item (`AXRoleDescription` "Region", `regionRows()`), a region
    /// ROW or a track HEADER row (`Track N “Name”`, `parseTrackDescription`),
    /// and the header column group itself (`trackHeaderGroup()`).
    ///
    /// The ancestor walk is what makes it work after a repair: pressing a
    /// header's `Has Focus` radio button leaves the BUTTON focused, and its
    /// parent is the `Track N “Name”` header item.
    static func isTracksArea(
        _ facts: ElementFacts,
        trackPrefix: String = LogicUIStrings.Format.trackDescriptionPrefix,
        openQuote: Character = LogicUIStrings.Format.openQuote,
        tracksHeader: String = LogicUIStrings.Element.tracksHeader,
        regionRoleDescription: String = LogicUIStrings.Element.regionRoleDescription
    ) -> Bool {
        if facts.roleDescription == regionRoleDescription { return true }
        if facts.role == "AXGroup", facts.description == tracksHeader { return true }
        if facts.role == "AXLayoutArea" || facts.role == "AXLayoutItem" {
            if facts.description.hasPrefix(trackPrefix),
               facts.description.contains(openQuote) { return true }
        }
        return false
    }

    /// The focused element plus its ancestors, nearest first.
    static func chainIsTracksArea(_ chain: [ElementFacts]) -> Bool {
        chain.contains { isTracksArea($0) }
    }

    /// How an element reads in a result or a refusal: role first, then
    /// whichever name it publishes. Never empty — an element with no name at
    /// all is still evidence of WHERE the focus sat.
    static func label(_ facts: ElementFacts?) -> String {
        guard let facts else { return "unreadable" }
        let name = facts.description.isEmpty ? facts.roleDescription : facts.description
        let role = facts.role.isEmpty ? "unnamed element" : facts.role
        return name.isEmpty ? role : "\(role) '\(name)'"
    }

    /// What the probe found and what, if anything, was done about it.
    enum Outcome: Equatable {
        /// The Tracks area already held the focus; nothing was written.
        case alreadyFocused(element: String)
        /// The focus was elsewhere and a write brought it back, proven by a
        /// second read of Logic's focused element.
        case restored(route: String, element: String)
        /// The focus could not be proven to be in the Tracks area. The call
        /// goes ahead anyway — the probe is younger than the tools it guards
        /// and must never be the thing that refuses a copy that would have
        /// worked — but the result says so, and a command that then does
        /// nothing has its first suspect named.
        case unverified(element: String?)

        var state: String {
            switch self {
            case .alreadyFocused: return "already_focused"
            case .restored: return "restored"
            case .unverified: return "unverified"
            }
        }

        var route: String {
            switch self {
            case .alreadyFocused: return "none"
            case .restored(let route, _): return route
            case .unverified: return "none"
            }
        }

        var focusedElement: String? {
            switch self {
            case .alreadyFocused(let element): return element
            case .restored(_, let element): return element
            case .unverified(let element): return element
            }
        }

        var dictionary: [String: Any] {
            [
                "state": state,
                "write_route": route,
                "focused_element": focusedElement ?? NSNull(),
                "note": summary
            ]
        }

        /// One sentence, reusable inside a refusal.
        var summary: String {
            switch self {
            case .alreadyFocused(let element):
                return "Logic's keyboard focus was already in the Tracks area (\(element)),"
                    + " where Cut/Copy/Paste/Nudge/Delete act."
            case .restored(let route, let element):
                return "Logic's keyboard focus was NOT in the Tracks area, where"
                    + " Cut/Copy/Paste/Nudge/Delete act; a track header write (\(route)) put it"
                    + " there (\(element)) before the command fired."
            case .unverified(let element):
                return "Whether Logic's keyboard focus is in the Tracks area is UNVERIFIED"
                    + (element.map { " (the focused element reads as \($0))" } ?? "")
                    + " — Cut/Copy/Paste/Nudge/Delete act on the focused area, and a command"
                    + " fired without it does nothing at all, silently."
            }
        }
    }

    /// The focus sentence out of a `selectRegion(forKeyCommand: true)` result,
    /// for the tools that carry the selection dictionary around rather than
    /// the `Outcome` (nudge, split, multi-select). A selection taken WITHOUT
    /// `forKeyCommand` carries no record, and says so rather than implying the
    /// focus was fine.
    static func summary(inSelectionResult selection: [String: Any]) -> String {
        guard let record = selection["key_focus"] as? [String: Any],
              let note = record["note"] as? String else {
            return "Logic's Tracks-area keyboard focus was not checked for this call, and"
                + " Cut/Copy/Paste/Nudge/Delete act on the focused area — a command fired"
                + " without it does nothing at all, silently."
        }
        return note
    }

    /// Why a Paste changed nothing — with the two real suspects reported as
    /// they were OBSERVED, not as a guess.
    ///
    /// The message this replaces named a modal dialog and nothing else, which
    /// sent the profiling agent looking for a window that was not there while
    /// the actual cause (no Tracks-area focus) went unnamed for three calls.
    /// Both suspects are now read at failure time: the focus outcome above,
    /// and Logic's own window list.
    static func pasteFailedReason(
        toBar: Int,
        barAlreadyOccupied: Bool,
        focus: Outcome,
        dialogTitles: [String]
    ) -> String {
        var reason = barAlreadyOccupied
            ? "bar \(toBar) already held a region before this call and the track gained none,"
                + " so Paste did nothing"
            : "the track gained no region after Paste"
        switch focus {
        case .alreadyFocused, .restored:
            reason += ". Keyboard focus is not the cause: " + focus.summary.lowercasedFirst
        case .unverified:
            reason += ". FIRST SUSPECT: " + focus.summary.lowercasedFirst
        }
        return reason + " " + dialogSentence(dialogTitles) + " Clipboard state uncertain"
    }

    /// The OTHER suspect, reported from Logic's own window list rather than
    /// from a hunch — a key command that vanishes into an unanswered modal
    /// looks exactly like one fired without focus, and the two are told apart
    /// by looking.
    static func dialogSentence(_ dialogTitles: [String]) -> String {
        guard !dialogTitles.isEmpty else {
            return "No dialog or floating window is open either — Logic's window list was read at"
                + " the moment of failure and holds only the project window(s)."
        }
        return "A dialog or floating window IS open and can be swallowing the key command: "
            + dialogTitles.map { "'\($0)'" }.joined(separator: ", ") + "."
    }
}

private extension String {
    /// Lowercases only the first character, so a standalone sentence can be
    /// spliced into a longer one without shouting mid-clause. File-private:
    /// the module has no business growing a general `String` vocabulary for
    /// one refusal message.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

extension LogicAccessibility {

    /// Logic's focused element and its ancestors, nearest first. `nil` when
    /// the application element or the focused element cannot be read at all —
    /// which is NOT the same as "the focus is elsewhere" and is reported
    /// separately everywhere it matters.
    func focusedElementChain(maximumDepth: Int = 8) -> [AXUIElement]? {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = elementAttribute(appElement, "AXFocusedUIElement") else { return nil }
        return ancestry(of: element, maximumDepth: maximumDepth, stoppingAtWindow: false)
    }

    /// An element and its ancestors, nearest first.
    func ancestry(
        of element: AXUIElement, maximumDepth: Int = 12, stoppingAtWindow: Bool = true
    ) -> [AXUIElement] {
        var chain = [element]
        var current = element
        for _ in 0..<maximumDepth {
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else { break }
            if stoppingAtWindow,
               stringAttribute(parent, kAXRoleAttribute as String) == "AXWindow" { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The Tracks area BY IDENTITY: the track header column plus every
    /// ancestor of it that the control bar does not also sit under.
    ///
    /// The described signatures above cover the leaves an agent-driven focus
    /// lands on, but Logic focuses the arrangement CONTAINER too — measured
    /// 2026-09-01, a healthy Tracks area reads `AXGroup 'Tracks'`, a
    /// description this server has no constant for and would have to invent
    /// one per locale. Identity needs no vocabulary: that group is an ancestor
    /// of the header column and the control bar is not underneath it, which is
    /// exactly what "inside the Tracks area" means. Subtracting the control
    /// bar's own ancestry is what keeps the shared split-view wrappers — which
    /// hold the transport as well — from counting as the Tracks area.
    func tracksAreaElements() -> [AXUIElement] {
        guard let header = try? trackHeaderGroup() else { return [] }
        let inside = ancestry(of: header)
        guard let controlBar = try? controlBarGroup() else { return [header] }
        let shared = ancestry(of: controlBar)
        return inside.filter { candidate in
            !shared.contains { CFEqual($0, candidate) }
        }
    }

    func elementFacts(_ element: AXUIElement) -> TracksAreaFocus.ElementFacts {
        TracksAreaFocus.ElementFacts(
            role: stringAttribute(element, kAXRoleAttribute as String),
            description: stringAttribute(element, kAXDescriptionAttribute as String),
            roleDescription: stringAttribute(element, "AXRoleDescription")
        )
    }

    /// Does the Tracks area hold Logic's keyboard focus? `nil` when the focus
    /// cannot be read at all — never guessed at, because "cannot see" and "the
    /// focus is elsewhere" lead to different actions.
    ///
    /// Described signatures first (free — the attributes are already being
    /// read for the report), identity second (a header-column walk, paid only
    /// when the cheap answer was no and the alternative is writing to Logic).
    func tracksAreaHoldsKeyFocus(_ chain: [AXUIElement]?) -> Bool? {
        guard let chain, !chain.isEmpty else { return nil }
        if TracksAreaFocus.chainIsTracksArea(chain.map(elementFacts)) { return true }
        let anchors = tracksAreaElements()
        guard !anchors.isEmpty else { return nil }
        return chain.contains { element in anchors.contains { CFEqual($0, element) } }
    }

    /// Establishes Logic's keyboard focus in the Tracks area before a region
    /// key command fires, and reports how.
    ///
    /// Never throws and never refuses: it is a best-effort repair in front of
    /// tools that already verify their own effect, and a probe that got the
    /// signature wrong must not become the reason a working copy is turned
    /// away. What it guarantees is the REPORT — `unverified` is what the
    /// refusal text then leads with.
    ///
    /// The ladder, cheapest first, each rung proven by re-reading Logic's
    /// focused element:
    /// 1. the Tracks area already holds the focus — no write at all;
    /// 2. the anchor track is not selected: `selectTrack`, which is the
    ///    measured cure verbatim (and carries the surface-debt settle and the
    ///    channel-focus bookkeeping a real selection change owes);
    /// 3. the anchor track IS selected (the `already_selected` hole): rewrite
    ///    `AXSelectedChildren` with it anyway — the write `selectTrack` skips;
    /// 4. press the header's `Has Focus` radio button.
    ///
    /// MEASURED 2026-09-01, and it is why this never refuses: with a plugin
    /// window open and focused (`AXWindow 'dialog'`), no rung moves the focus
    /// back — an Accessibility selection write cannot take the key window away
    /// from another window — and the key commands WORKED anyway, because they
    /// arrive as learned MIDI notes rather than as keystrokes. So an
    /// `unverified` verdict is a genuine "cannot tell", the tools go ahead, and
    /// the report is what changes: the copy, the nudge and the delete taken in
    /// that state all landed and all said `key_focus: unverified` rather than
    /// claiming a focus they did not have.
    @discardableResult
    func ensureTracksAreaKeyFocus(
        trackName: String, trackNumber: Int? = nil
    ) -> TracksAreaFocus.Outcome {
        let chain = focusedElementChain()
        let label = chain?.first.map { TracksAreaFocus.label(elementFacts($0)) }
        if tracksAreaHoldsKeyFocus(chain) == true {
            return .alreadyFocused(element: label ?? "unreadable")
        }
        let before = label
        guard let group = try? trackHeaderGroup(),
              let headers = try? parsedTrackHeaders(),
              let target = try? resolveTrack(headers, name: trackName, number: trackNumber) else {
            return .unverified(element: before)
        }
        if !target.selected {
            _ = try? selectTrack(
                trackName: target.name, trackNumber: target.number, expectedProjectPath: nil
            )
            if let element = pollTracksAreaKeyFocus() {
                return .restored(route: "select_track", element: element)
            }
        }
        // The write `selectTrack`'s `already_selected` fast path skips. A
        // still-selected header proves nothing about Logic's key focus, and
        // this is the case the three measured failures were in.
        _ = MCUController.settleSurfaceDebt(before: nil)
        _ = AXUIElementSetAttributeValue(
            group, "AXSelectedChildren" as CFString, [target.item] as CFArray
        )
        if let element = pollTracksAreaKeyFocus() {
            return .restored(route: "ax_selected_children", element: element)
        }
        if let focusButton = children(of: target.item).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXRadioButton"
                && stringAttribute($0, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.hasFocus
        }) {
            _ = AXUIElementPerformAction(focusButton, kAXPressAction as CFString)
            if let element = pollTracksAreaKeyFocus() {
                return .restored(route: "has_focus_press", element: element)
            }
        }
        return .unverified(
            element: focusedElementChain()?.first.map { TracksAreaFocus.label(elementFacts($0)) }
                ?? before
        )
    }

    /// Re-reads the focus until it lands in the Tracks area. Positive check
    /// FIRST: a write that took effect immediately costs one read, not a
    /// sleep.
    func pollTracksAreaKeyFocus(attempts: Int = 8, interval: TimeInterval = 0.05) -> String? {
        for attempt in 0..<attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: interval) }
            let chain = focusedElementChain()
            if tracksAreaHoldsKeyFocus(chain) == true {
                return chain?.first.map { TracksAreaFocus.label(elementFacts($0)) } ?? "unreadable"
            }
        }
        return nil
    }

    /// The titles of every Logic window that could be swallowing a key
    /// command: dialogs, sheets and floating windows (the `Notes Crossing
    /// Split Point` modal is an `AXFloatingWindow`). Empty means the refusal
    /// can say so as an OBSERVATION rather than sending the agent hunting for
    /// a window that is not there.
    func modalWindowTitles() -> [String] {
        modalWindowTitles(in: (try? logicWindows()) ?? [])
    }

    /// The same reading of a window list the caller ALREADY walked. The walk
    /// is 0.87-0.92 ms warm and 33.6 ms cold (measured 2026-09-02) and is the
    /// single most expensive thing on `logic_health`'s path, so the doctor
    /// takes one and reads both the project document and this out of it.
    func modalWindowTitles(in windows: [AXUIElement]) -> [String] {
        windows.compactMap { window in
            let subrole = stringAttribute(window, kAXSubroleAttribute as String)
            guard subrole == "AXDialog" || subrole == "AXSheet"
                    || subrole == "AXSystemDialog" || subrole == "AXFloatingWindow" else {
                return nil
            }
            let title = stringAttribute(window, kAXTitleAttribute as String)
            return title.isEmpty ? subrole : title
        }
    }
}
