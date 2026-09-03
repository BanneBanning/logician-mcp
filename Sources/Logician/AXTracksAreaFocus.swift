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

    /// Another Logic window holds the key focus, and no rung of the repair
    /// ladder can take it away from there.
    ///
    /// MEASURED 2026-09-01 and re-measured 2026-09-03 (sandbox `Testlåt
    /// Copy`, both binaries in one session): with a plug-in window
    /// (`AXWindow 'dialog'`), or Logic's Mixer (a channel strip,
    /// `AXLayoutItem 'Acke Vocals'`), holding the key window, `selectTrack`,
    /// the raw `AXSelectedChildren` rewrite and the `Has Focus` press all wrote
    /// successfully and Logic's focused element did not move — an Accessibility
    /// write into one window cannot make another window stop being the key
    /// window. The ladder paid two 8 × 50 ms polls and a button press for the
    /// privilege, and returned the SAME `unverified` a single window read
    /// returns:
    ///
    /// | state | tool | old | new |
    /// |---|---|---|---|
    /// | plug-in window | `select_regions {mode: none}` | 1 565 ms | **214 ms** |
    /// | plug-in window | `select_regions {mode: track}` | 3 274 ms | **499 ms** |
    /// | plug-in window | `copy_region` (4 bars) | 6 547 ms | **2 173 ms** |
    /// | plug-in window | `delete_region` | 2 567 ms | **969 ms** |
    /// | Mixer window | `select_regions {mode: none}` | 1 916 ms | **742 ms** |
    ///
    /// The states this deliberately does NOT cover, because a rung wins them:
    /// anything inside the project window. Measured the same session, right
    /// after a List Editors read the focus is outside the Tracks area and
    /// `ax_selected_children` puts it back, 2/2, in 320–327 ms.
    ///
    /// So this is not a refusal and not a new verdict — it is the same
    /// `unverified` reached without the ~1.2 s, plus the one thing the old
    /// report could not say: which window has the focus and which tool call
    /// gives it back.
    struct ForeignKeyWindow: Equatable {
        /// `LogicWindowKind`'s vocabulary — the same word `logic_list_windows`
        /// publishes for this window, so an agent can find it in that list.
        let kind: String
        let title: String
        /// The way out, named as a tool call, the way the region refusals name
        /// theirs.
        let wayOut: String

        var label: String {
            title.isEmpty ? kind : "\(kind) '\(title)'"
        }

        var dictionary: [String: Any] {
            [
                "window_kind": kind,
                "window_title": title.isEmpty ? NSNull() : title,
                "way_out": wayOut
            ]
        }
    }

    /// Which Logic window the focus sits in, relative to the project window.
    /// `unknown` is not `isNotProjectWindow`: a window list that cannot be read
    /// keeps the ladder, because "cannot see" and "the focus is in another
    /// window" lead to opposite actions.
    enum ProjectWindowIdentity: Equatable {
        case isProjectWindow
        case isNotProjectWindow
        case unknown
    }

    /// The tool call that hands the Tracks area its focus back, by window kind.
    static func wayOut(fromWindowKind kind: String) -> String {
        switch kind {
        case LogicWindowKind.pluginOrAuxiliary:
            return "close it with logic_close_plugin_window"
        case LogicWindowKind.mixer:
            return "close it with logic_set_mixer {open: false}"
        default:
            return "bring Logic's project (Tracks) window to the front"
        }
    }

    /// Is the focused window one the repair ladder provably cannot win from?
    /// `nil` means "run the ladder" — the answer for the project window itself
    /// (where every measured repair DID win: the focus on a control-bar button,
    /// the inspector, a List Editors pane) and for a window that cannot be
    /// identified at all.
    ///
    /// Pure, so the table of shapes is pinned by tests rather than by whichever
    /// windows happened to be open during a live pass.
    static func foreignKeyWindow(
        identity: ProjectWindowIdentity, subrole: String, title: String, hasDocument: Bool
    ) -> ForeignKeyWindow? {
        if identity == .isProjectWindow { return nil }
        let kind = LogicWindowKind.classify(
            subrole: subrole, title: title, hasDocument: hasDocument
        )
        // Identity could not be established (no project window in Logic's
        // window list): believe the classification rather than guessing, and
        // keep the ladder for anything that reads as the project window.
        if identity == .unknown, kind == LogicWindowKind.project { return nil }
        return ForeignKeyWindow(kind: kind, title: title, wayOut: wayOut(fromWindowKind: kind))
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
        /// The same verdict as `unverified`, reached in one read because the
        /// key window belongs to somebody else. Reports `state: "unverified"`
        /// deliberately: nothing about the answer changed, only its price.
        case foreignKeyWindow(element: String?, window: ForeignKeyWindow)

        var state: String {
            switch self {
            case .alreadyFocused: return "already_focused"
            case .restored: return "restored"
            case .unverified, .foreignKeyWindow: return "unverified"
            }
        }

        var route: String {
            switch self {
            case .alreadyFocused: return "none"
            case .restored(let route, _): return route
            case .unverified, .foreignKeyWindow: return "none"
            }
        }

        var focusedElement: String? {
            switch self {
            case .alreadyFocused(let element): return element
            case .restored(_, let element): return element
            case .unverified(let element): return element
            case .foreignKeyWindow(let element, _): return element
            }
        }

        var dictionary: [String: Any] {
            var payload: [String: Any] = [
                "state": state,
                "write_route": route,
                "focused_element": focusedElement ?? NSNull(),
                "note": summary
            ]
            if case .foreignKeyWindow(_, let window) = self {
                payload["blocked_by"] = window.dictionary
            }
            return payload
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
            case .foreignKeyWindow(let element, let window):
                return "Whether Logic's keyboard focus is in the Tracks area is UNVERIFIED:"
                    + " the key window is ANOTHER Logic window (\(window.label))"
                    + (element.map { ", focused on \($0)" } ?? "")
                    + ". No Accessibility write can take the key window away from another"
                    + " window — measured 2026-09-03, no rung of the focus repair ladder has"
                    + " ever won from here — so none was attempted and no time was spent"
                    + " trying. Cut/Copy/Paste/Nudge/Delete act on the focused area; to rule"
                    + " focus out entirely, \(window.wayOut) and repeat the call."
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
        case .unverified, .foreignKeyWindow:
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

/// Which header row a focus repair may write into. Two cases, because the two
/// kinds of caller know different things: an anchored region command names its
/// track, and an anchorless one (`logic_select_regions` mode `all`/`none`)
/// knows only that SOME track is selected and that changing which one is not
/// its business.
private enum FocusRepairTarget {
    case named(String, Int?)
    case whicheverIsSelected
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

    /// The window the focused element lives in.
    ///
    /// Three routes, because MEASURED 2026-09-03 the cheap ones are not
    /// enough: with Logic's Mixer focused, the focused element is a channel
    /// strip (`AXLayoutItem 'Bas'`) sitting deeper than the focus chain's
    /// 8-level depth limit, and the chain search alone found no window at all
    /// — the short circuit silently did not fire and the tool paid the full
    /// 2.0 s ladder. So: the two standard pointers first (one attribute read
    /// each, exact at any depth), then the chain the caller already holds,
    /// then a deeper walk of its own.
    func windowOfFocusedElement(_ chain: [AXUIElement]?) -> AXUIElement? {
        guard let focused = chain?.first else { return nil }
        for name in ["AXTopLevelUIElement", kAXWindowAttribute as String] {
            if let candidate = elementAttribute(focused, name), isWindow(candidate) {
                return candidate
            }
        }
        if let inChain = chain?.first(where: isWindow) { return inChain }
        return ancestry(of: focused, maximumDepth: 24, stoppingAtWindow: false).first(where: isWindow)
    }

    private func isWindow(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute as String) == kAXWindowRole as String
    }

    /// Is the key focus in a Logic window the repair ladder cannot win from?
    ///
    /// Identity, not vocabulary, decides the common case: the window either IS
    /// the element `projectWindow()` returns or it is not, which needs no
    /// window title and survives every UI language. The kind is read only to
    /// NAME the way out — `logic_close_plugin_window` for a plug-in window,
    /// `logic_set_mixer {open: false}` for the Mixer — and to keep the ladder
    /// when the project window cannot be resolved at all.
    ///
    /// Cost: one window walk (0.87–0.92 ms warm, 33.6 ms cold — measured
    /// 2026-09-02) plus three attribute reads, paid ONLY when the Tracks area
    /// does not already hold the focus, i.e. never on the healthy path.
    func foreignKeyWindow(_ chain: [AXUIElement]?) -> TracksAreaFocus.ForeignKeyWindow? {
        guard let window = windowOfFocusedElement(chain) else { return nil }
        let identity: TracksAreaFocus.ProjectWindowIdentity
        if let project = try? projectWindow() {
            identity = CFEqual(project, window) ? .isProjectWindow : .isNotProjectWindow
        } else {
            identity = .unknown
        }
        return TracksAreaFocus.foreignKeyWindow(
            identity: identity,
            subrole: stringAttribute(window, kAXSubroleAttribute as String),
            title: stringAttribute(window, kAXTitleAttribute as String),
            hasDocument: documentPath(of: window) != nil
        )
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
    /// 1b. the key window is another Logic window (a plug-in window, the
    ///    Mixer): there is no rung to climb, so the ladder is skipped and the
    ///    `unverified` verdict names the window and the tool call that closes
    ///    it — see `TracksAreaFocus.ForeignKeyWindow` for the measurements;
    /// 2. the target track is not selected: `selectTrack`, which is the
    ///    measured cure verbatim (and carries the surface-debt settle and the
    ///    channel-focus bookkeeping a real selection change owes);
    /// 3. the target track IS selected (the `already_selected` hole): rewrite
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
    ///
    /// RE-MEASURED 2026-09-03, which is why rung 1b exists: that state is the
    /// one the ladder is WORST at. It cannot win it, and it took ~1.2–1.4 s to
    /// find out (two 8 × 50 ms polls plus the `Has Focus` press, plus the
    /// header walks around them) before returning the same sentence rung 1b
    /// returns after one window read.
    @discardableResult
    func ensureTracksAreaKeyFocus(
        trackName: String, trackNumber: Int? = nil
    ) -> TracksAreaFocus.Outcome {
        ensureTracksAreaKeyFocus(repairingWith: .named(trackName, trackNumber))
    }

    /// The same probe and the same repair for a command that names NO track.
    ///
    /// `logic_select_regions` modes `all` and `none` were the only two paths in
    /// the region family with no focus probe at all — measured 2026-09-02, all
    /// six `none` results and both `all` results in that profile carried no
    /// `key_focus` key, while every anchored mode carried one — because the
    /// probe used to be reachable only through an anchor region, and these two
    /// modes have none. They are also the two that most need it: with the focus
    /// elsewhere their command lands on another Logic view, the honest
    /// after-check correctly says nothing moved, and the failure could name
    /// everything EXCEPT the likeliest cause.
    ///
    /// The repair writes into whatever track Logic ALREADY has selected, so it
    /// changes nothing an agent can observe except the focus — inventing a
    /// track here would move the track selection a `mode: "none"` call never
    /// asked about. With no header reading selected there is nothing to write
    /// that is not a change of state, so the verdict is `unverified` and the
    /// call goes ahead and says so, exactly as the anchored path does when the
    /// headers cannot be read.
    @discardableResult
    func ensureTracksAreaKeyFocus() -> TracksAreaFocus.Outcome {
        ensureTracksAreaKeyFocus(repairingWith: .whicheverIsSelected)
    }

    @discardableResult
    private func ensureTracksAreaKeyFocus(
        repairingWith target: FocusRepairTarget
    ) -> TracksAreaFocus.Outcome {
        let chain = focusedElementChain()
        let label = chain?.first.map { TracksAreaFocus.label(elementFacts($0)) }
        if tracksAreaHoldsKeyFocus(chain) == true {
            return .alreadyFocused(element: label ?? "unreadable")
        }
        let before = label
        // Rung 0: is there anything to climb? A key window that is not the
        // project window cannot be talked out of it from here (see
        // `ForeignKeyWindow`), and the ladder's price for finding that out is
        // ~1.2 s of polling for a verdict identical to this one.
        if let foreign = foreignKeyWindow(chain) {
            return .foreignKeyWindow(element: before, window: foreign)
        }
        guard let group = try? trackHeaderGroup() else { return .unverified(element: before) }
        let headers = parsedTrackHeaders(in: group)
        let resolved: TrackHeader?
        switch target {
        case .named(let trackName, let trackNumber):
            resolved = try? resolveTrack(headers, name: trackName, number: trackNumber)
        case .whicheverIsSelected:
            resolved = headers.first { $0.selected }
        }
        guard let target = resolved else {
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
