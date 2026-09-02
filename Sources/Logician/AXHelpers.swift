import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// One element's children, indexed by their `AXDescription`, plus the children
/// themselves for the lookups that key on something else (role, help). Built by
/// `LogicAccessibility.describedChildren(of:)` — see there for what it costs
/// and why.
struct DescribedChildren {
    let all: [AXUIElement]
    let byDescription: [String: AXUIElement]

    subscript(description: String) -> AXUIElement? { byDescription[description] }
}

extension LogicAccessibility {
    // MARK: - Channel strip helpers

    /// Any inspector strip (left or right) whose name matches, for output and
    /// aux strips that are not selectable track headers.
    func anyInspectorStrip(named name: String) throws -> AXUIElement {
        let mainWindow = try projectWindow()
        let match = firstDescendant(of: mainWindow, maximumDepth: AXDepth.inspectorStrip) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem"
                && stringAttribute(element, kAXHelpAttribute as String)
                    .localizedCaseInsensitiveContains(LogicUIStrings.Element.inspectorChannelStrip)
                && stringAttribute(element, kAXDescriptionAttribute as String) == name
        }
        guard let strip = match else {
            throw LogicianError.trackNotExposed(
                requested: "an inspector channel strip named '\(name)'",
                exposed: "no strip with that name is visible. Accessibility only reaches"
                    + " a strip an inspector is showing — select the track in Logic, or"
                    + " for an output/aux/bus strip select a track routed to it."
            )
        }
        return strip
    }

    func inspectorStrip(named trackName: String) throws -> AXUIElement {
        let mainWindow = try projectWindow()
        var strips: [(name: String, help: String, element: AXUIElement)] = []
        collect(from: mainWindow, maximumDepth: AXDepth.inspectorStrip) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem" else { return }
            let help = stringAttribute(element, kAXHelpAttribute as String)
            guard help.localizedCaseInsensitiveContains(
                LogicUIStrings.Element.inspectorChannelStrip
            ) else { return }
            strips.append((
                name: stringAttribute(element, kAXDescriptionAttribute as String),
                help: help,
                element: element
            ))
        }
        guard let left = strips.first(where: {
            $0.help.hasPrefix(LogicUIStrings.Element.leftInspectorPrefix)
        }) ?? strips.first else {
            throw LogicianError.windowNotFound("left inspector channel strip")
        }
        if left.name == trackName {
            return left.element
        }
        // Output/aux strips ("Stereo Out") live in the right inspector strip
        // and are addressable by exact name without being selectable tracks.
        if let other = strips.first(where: { $0.name == trackName }) {
            return other.element
        }
        throw LogicianError.trackNotExposed(
            requested: "the channel strip for track '\(trackName)'",
            exposed: "the inspector currently shows '\(left.name)'. Select the track in Logic first."
        )
    }

    func insertSlots(of strip: AXUIElement) -> [InsertSlot] {
        var slots: [InsertSlot] = []
        for child in children(of: strip) {
            guard stringAttribute(child, kAXRoleAttribute as String) == "AXGroup" else { continue }
            var bypass: AXUIElement?
            var open: AXUIElement?
            for grandchild in children(of: child) {
                let role = stringAttribute(grandchild, kAXRoleAttribute as String)
                let description = stringAttribute(grandchild, kAXDescriptionAttribute as String)
                if role == "AXCheckBox", description == LogicUIStrings.Element.bypass {
                    bypass = grandchild
                }
                if role == "AXButton", description == LogicUIStrings.Element.open {
                    open = grandchild
                }
            }
            guard let bypassBox = bypass, open != nil else { continue }
            slots.append(InsertSlot(
                index: slots.count + 1,
                name: stringAttribute(child, kAXDescriptionAttribute as String),
                bypassed: stringAttribute(bypassBox, kAXValueAttribute as String) == "1",
                group: child,
                openButton: open
            ))
        }
        return slots
    }

    func resolveSlot(
        _ slots: [InsertSlot],
        track: String,
        plugin: String,
        index: Int?
    ) throws -> InsertSlot {
        if let index = index {
            guard let slot = slots.first(where: { $0.index == index }) else {
                throw LogicianError.insertNotFound(
                    track: track,
                    plugin: "slot \(index)",
                    available: slots.map { "\($0.index): \($0.name)" }
                )
            }
            guard pluginNamesMatch(slot.name, plugin) else {
                throw LogicianError.insertMismatch(slot: index, expected: plugin, actual: slot.name)
            }
            return slot
        }
        let matches = slots.filter { pluginNamesMatch($0.name, plugin) }
        guard !matches.isEmpty else {
            throw LogicianError.insertNotFound(
                track: track,
                plugin: plugin,
                available: slots.map { "\($0.index): \($0.name)" }
            )
        }
        guard matches.count == 1, let slot = matches.first else {
            throw LogicianError.insertAmbiguous(
                track: track, plugin: plugin, slots: matches.map(\.index), parameter: "insert_index"
            )
        }
        return slot
    }

    func parseTrackDescription(_ description: String) -> (number: Int, name: String)? {
        let prefix = LogicUIStrings.Format.trackDescriptionPrefix
        guard description.hasPrefix(prefix),
              let openQuote = description.firstIndex(of: LogicUIStrings.Format.openQuote),
              let closeQuote = description.lastIndex(of: LogicUIStrings.Format.closeQuote) else {
            return nil
        }
        let numberText = description[
            description.index(description.startIndex, offsetBy: prefix.count)..<openQuote
        ]
            .trimmingCharacters(in: .whitespaces)
        guard let number = Int(numberText) else { return nil }
        let name = String(description[description.index(after: openQuote)..<closeQuote])
        return (number, name)
    }

    /// The `windowNotFound` reason `trackHeaderGroup()` reports, verbatim.
    /// `isHeaderlessStripCandidate` matches it to reroute the request to the
    /// control surface, so the throw and the match must never drift apart —
    /// this exact signature is what every track name dies with on a
    /// non-English Logic (measured 2026-08-30, French).
    static let tracksHeaderGroupMissing = "Tracks header group"

    func trackHeaderGroup() throws -> AXUIElement {
        try trackHeaderGroup(in: projectWindow())
    }

    /// The same search against a project window the caller ALREADY resolved.
    ///
    /// This walk is the most expensive read on the Accessibility plane and it
    /// is paid per resolution, not per call: measured 2026-09-02 on the
    /// reference project it is a depth-12 descent over ~172 nodes costing
    /// **22–37 ms warm (96–118 ms while Logic is busy) and 379 of the 1 002
    /// attribute reads** a `logic_list_tracks` call used to make. Any caller
    /// that needs the group twice — headers and then the scroll probe — must
    /// resolve it once and pass it down; nothing between two resolutions can
    /// change the answer.
    func trackHeaderGroup(in window: AXUIElement) throws -> AXUIElement {
        let headerGroup = firstDescendant(of: window, maximumDepth: AXDepth.trackHeaderGroup) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute(element, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.tracksHeader
        }
        guard let group = headerGroup else {
            throw LogicianError.windowNotFound(Self.tracksHeaderGroupMissing)
        }
        return group
    }

    func trackHeaderItems() throws -> [AXUIElement] {
        trackHeaderItems(in: try trackHeaderGroup())
    }

    /// The header rows of a group the caller already holds. One `AXChildren`
    /// read and a role filter — 1.5 ms of the walk above, which is why the
    /// group, not this list, is the thing worth passing around.
    func trackHeaderItems(in group: AXUIElement) -> [AXUIElement] {
        children(of: group).filter {
            stringAttribute($0, kAXRoleAttribute as String) == "AXLayoutItem"
        }
    }

    // MARK: - Window helpers

    func projectWindow() throws -> AXUIElement {
        let windows = try logicWindows()
        // Some plugin windows (e.g. Drum Machine Designer) are dialogs that
        // also carry the project document; the real project window is the
        // standard window.
        //
        // And Logic's MIXER window is a standard window that carries the same
        // document (measured 2026-08-28: "<project> - Mixer: Tracks", subrole
        // AXStandardWindow, same AXDocument as the Tracks window). Taking it
        // for the project window pointed EVERY Accessibility-plane read at a
        // window with no track headers, no inspector and no control bar — the
        // whole plane failed with "Tracks header group" while Logic was
        // perfectly healthy. It is excluded here, at the one place that
        // decides what "the project window" means.
        let carriers = windows.filter { documentPath(of: $0) != nil }
        let candidates = carriers.filter { !isMixerWindow($0) }
        if let standard = candidates.first(where: {
            stringAttribute($0, kAXSubroleAttribute as String) == "AXStandardWindow"
        }) {
            return standard
        }
        if let fallback = candidates.first {
            return fallback
        }
        // Say WHY, when the reason is a Mixer that pushed the Tracks window
        // out of reach: Logic publishes only its main/focused window while it
        // is in the background, so an open Mixer can be the only document
        // window Accessibility sees at all.
        guard carriers.isEmpty else {
            throw LogicianError.windowNotFound(
                "the project (Tracks) window — the only document window Accessibility can see is"
                    + " Logic's Mixer. Close it with logic_set_mixer {open: false}, or bring the"
                    + " Tracks window to the front"
            )
        }
        throw LogicianError.windowNotFound("project window with AXDocument")
    }

    func logicWindows() throws -> [AXUIElement] {
        guard AXIsProcessTrusted() else {
            throw LogicianError.accessibilityNotTrusted
        }
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            throw LogicianError.logicNotRunning
        }
        return windows(ofProcess: application.processIdentifier)
    }

    /// The same walk against a Logic process the caller ALREADY resolved.
    ///
    /// `runningApplications(withBundleIdentifier:)` is 0.22 ms warm and
    /// 0.71 ms cold (measured 2026-09-02), and `logic_health` was paying it
    /// three times in one call — once for its own `logic_pid`, once in here,
    /// once inside the UI-language inference. Find it once, pass it down.
    /// The trust check stays with the CALLER on this path so it is not paid
    /// twice either; `logicWindows()` above is the checked entry point.
    func windows(ofProcess pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var collected = attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        if collected.isEmpty {
            // Logic's AXWindows list is sometimes empty while Logic is not the
            // frontmost application; the application element's children still
            // contain the windows.
            collected = children(of: appElement).filter {
                stringAttribute($0, kAXRoleAttribute as String) == kAXWindowRole as String
            }
        }
        // ALWAYS append AXMainWindow/AXFocusedWindow: with a floating window
        // open (e.g. Key Commands), AXWindows can list ONLY the float while
        // the project window still resolves through these attributes — a
        // non-empty list is no guarantee the document window is in it.
        for name in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
            // A non-element answer here is skipped like a missing attribute
            // instead of trapping (`as!`) on the way to the window list.
            guard let window = elementAttribute(appElement, name) else { continue }
            if !collected.contains(where: { CFEqual($0, window) }) {
                collected.append(window)
            }
        }
        return collected
    }

    func documentPath(of window: AXUIElement) -> String? {
        let document = stringAttribute(window, kAXDocumentAttribute as String)
        guard !document.isEmpty else { return nil }
        return normalizedPath(document)
    }

    func normalizedPath(_ raw: String) -> String {
        let candidate: String
        if let url = URL(string: raw), url.isFileURL {
            candidate = url.path
        } else {
            candidate = raw
        }
        var path = candidate.precomposedStringWithCanonicalMapping
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// How long we are willing to wait for a reply to a press that opens a
    /// TRACKING menu — a menu Logic runs its own runloop for.
    ///
    /// MEASURED 2026-09-02 (`logic_plugin_preset` §4.1): `AXUIElementPerformAction`
    /// on the setting pop-up returned `-25204 kAXErrorCannotComplete` after
    /// **1 500–1 510 ms on 8 of 8 presses**, while a look taken the instant
    /// that call returned found the menu **already open, 8 of 8, at ~30 ms**,
    /// on the first poll iteration every time. Logic's menu-tracking runloop
    /// does not answer Accessibility while a menu is up, so the press cannot
    /// be replied to at all: it sits out the whole default messaging timeout
    /// and then reports failure on an action that worked. That was 1.5 s per
    /// menu cycle, 24% of a `select` and 45% of a `list`.
    ///
    /// The press itself is delivered when it is sent, not when it is
    /// answered, so waiting for the reply buys nothing — and the code never
    /// read the status anyway: presence of the menu is, and stays, the only
    /// judge.
    static let trackingMenuPressTimeout: TimeInterval = 0.2
    static let trackingMenuPressInterval: TimeInterval = 0.025

    /// Press a control that opens a tracking menu, without paying the
    /// messaging timeout for the reply that will never come.
    ///
    /// The status is deliberately discarded (see `trackingMenuPressTimeout`);
    /// every caller verifies by finding the menu. The timeout is set on THIS
    /// element only and put back to 0 afterwards, which is the documented
    /// "use the global/default value" — nothing in this server ever sets a
    /// global one, so the element ends the call exactly as it started it.
    func pressOpeningTrackingMenu(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, Float(Self.trackingMenuPressTimeout))
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        AXUIElementSetMessagingTimeout(element, 0)
    }

    /// How long a window-close poll waits in total, and how long it waits
    /// between looks.
    ///
    /// MEASURED 2026-09-01 (`logic_close_plugin_window` §3.1,
    /// `logic_close_plugin` §3.1): `AXUIElementPerformAction` on a close
    /// button BLOCKS until Logic has torn the window down, so the window is
    /// already missing from the list by the time the press returns — a look
    /// taken with no wait at all found it gone on 3/3 runs of one profile and
    /// 4/4 of the other, and the loop answered on its first look 7/7. The old
    /// shape slept 0.1 s BEFORE that first look and so paid ~100 ms of a
    /// 125 ms call for a state that was already true. Look first, sleep only
    /// after a miss, and make the retry 25 ms so a genuine miss costs a tick
    /// instead of a tenth of a second. The 2 s deadline is unchanged.
    ///
    /// The honest floor is not zero: the FIRST window enumeration after a
    /// teardown costs 12–15 ms where a steady-state one costs 0–1 ms. That
    /// read is the verification, and it is the part that is never cut.
    static let windowPollDeadline: TimeInterval = 2.0
    static let windowPollInterval: TimeInterval = 0.025

    /// Look FIRST, then re-look every `windowPollInterval` until
    /// `windowPollDeadline`. `verdict` returns nil to keep waiting, and nil
    /// comes back when the deadline passed without an answer.
    func pollWindowList<Verdict>(_ verdict: ([AXUIElement]) throws -> Verdict?) throws -> Verdict? {
        let deadline = Date().addingTimeInterval(Self.windowPollDeadline)
        while true {
            if let answer = try verdict(try logicWindows()) { return answer }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: Self.windowPollInterval)
        }
    }

    /// Has the window we pressed gone away — that window, not merely some
    /// window? Identity and title both, see `pressedWindowIsGone`.
    func pollPressedWindowGone(_ window: AXUIElement, title: String) throws -> Bool {
        let target = WindowKey(element: window)
        let gone: Bool? = try pollWindowList { windows in
            let current = windows.map {
                (key: WindowKey(element: $0), title: stringAttribute($0, kAXTitleAttribute as String))
            }
            return pressedWindowIsGone(target: target, title: title, current: current) ? true : nil
        }
        return gone ?? false
    }

    /// Both outcomes of a toggle press, polled together — see
    /// `windowToggleVerdict`. `targets` are the windows the press was aimed
    /// at; `before` is the whole window list it was pressed against, which is
    /// what makes an appearance recognisable. nil means neither happened
    /// inside the deadline.
    func pollWindowToggle(
        targets: Set<WindowKey>,
        before: Set<WindowKey>
    ) throws -> WindowToggleVerdict<WindowKey>? {
        try pollWindowList { windows in
            windowToggleVerdict(targets: targets, before: before, current: windows.map(WindowKey.init))
        }
    }

    /// The first window that was not open before the press — looked for
    /// FIRST, then re-looked every `windowPollInterval` until
    /// `windowPollDeadline`.
    ///
    /// MEASURED 2026-09-02 (`logic_open_plugin` §3.1): `AXUIElementPerformAction`
    /// on an insert's open button BLOCKS while Logic builds the plugin UI, so
    /// a look taken with no wait at all found the new window ALREADY THERE on
    /// 6 of 6 opens — 3 warm audio-insert, 1 cold, 2 instrument — and the loop
    /// answered on its first look every time. The shape this replaces slept
    /// 0.1 s in FRONT of that first look and so paid 100 ms of a 307 ms call,
    /// 30% of the warm total, for a state that was already true. It is the
    /// same conversion the two close tools got on 2026-09-01, on the one
    /// helper that fix did not reach.
    func pollNewWindow(before: Set<WindowKey>) throws -> AXUIElement? {
        try pollWindowList { windows in
            windows.first { !before.contains(WindowKey(element: $0)) }
        }
    }

    /// The channel's own plugin windows — the ones titled after the track —
    /// and what each of them says it is showing. See `PluginWindowShowing`
    /// for why the CONTENT and not the window list is the thing to read.
    ///
    /// Cheap enough to poll: one `AXChildren` read per window plus a role and
    /// a value per direct child, which is 8–14 children on the two plugins
    /// measured 2026-09-02 (Decapitator 8, Channel EQ 14). Nothing descends
    /// into the plugin's own controls.
    ///
    /// The subrole filter is the same one `AXPresets` applies for the same
    /// reason: a track named like the open document would otherwise let the
    /// PROJECT window pass for a plugin window.
    func pluginWindowsShowing(
        trackName: String, in windows: [AXUIElement]
    ) -> [PluginWindowShowing<WindowKey>] {
        windows.compactMap { window in
            guard stringAttribute(window, kAXTitleAttribute as String) == trackName,
                  stringAttribute(window, kAXSubroleAttribute as String) != "AXStandardWindow"
            else { return nil }
            // The size is part of the shape because two plugins that both
            // publish a custom canvas have the SAME handful of header
            // children and differ by almost nothing else Accessibility can
            // see; their windows are different sizes (Decapitator 192×177,
            // Channel EQ 516×331, measured 2026-09-02).
            let size = (try? frame(of: window)).map { "size:\(Int($0.width))×\(Int($0.height))" }
            var shape: [String] = [size ?? "size:unknown"]
            var staticTexts: [String] = []
            for child in children(of: window) {
                let role = stringAttribute(child, kAXRoleAttribute as String)
                shape.append(role + "|" + stringAttribute(child, kAXDescriptionAttribute as String))
                if role == kAXStaticTextRole as String {
                    staticTexts.append(stringAttribute(child, kAXValueAttribute as String))
                }
            }
            return PluginWindowShowing(
                key: WindowKey(element: window),
                shows: pluginNameFromHeader(staticTexts: staticTexts, trackName: trackName),
                shape: shape
            )
        }
    }

    func closeWindowElement(_ window: AXUIElement) -> Bool {
        // A close-button attribute that is not an element falls through to the
        // child-button path below rather than trapping (`as!`).
        if let button = elementAttribute(window, kAXCloseButtonAttribute as String) {
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return true
            }
        }
        // Windows like Drum Machine Designer expose no AXCloseButton attribute
        // but have a child button described as "close".
        if let childClose = children(of: window).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.close
        }) {
            return AXUIElementPerformAction(childClose, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// The answer `openPlugin` gives when the plugin's window is up.
    ///
    /// `window_title` is the TRACK's name — Logic titles plugin windows after
    /// the channel, and `openPlugin` refuses any window that is titled
    /// otherwise — so the field every caller actually wants is `window_shows`,
    /// the plugin name the window's own header publishes. `verified_by` says
    /// which proof was taken, because the three are not equally strong.
    func openResult(
        state: String,
        track: String,
        slot: InsertSlot,
        shows: String,
        replacing: String?,
        verifiedBy: String
    ) -> [String: Any] {
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": state,
            "track": track,
            "insert_index": slot.index,
            "plugin_display_name": slot.name,
            "window_title": track,
            "window_shows": shows.isEmpty
                ? "unavailable: this window publishes no plugin name of its own"
                : shows,
            "verified_by": verifiedBy,
            "note": "Logic titles a plugin window after the TRACK, not the plugin, and reuses ONE"
                + " window per channel: opening a second plugin on the same track swaps this"
                + " window's contents instead of opening another. logic_list_plugin_parameters"
                + " {window_title} reads what is in it."
        ]
        if let replaced = replacing, !replaced.isEmpty {
            result["replaced_plugin"] = replaced
        }
        return result
    }

    /// Visits `root` and every descendant down to `maximumDepth` (inclusive,
    /// root counted as 0) in pre-order.
    func collect(
        from root: AXUIElement,
        maximumDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        walk(from: root, maximumDepth: maximumDepth) { element in
            visit(element)
            return .descend
        }
    }

    func listParameters(windowTitle: String) throws -> [[String: Any]] {
        let window = try logicWindow(title: windowTitle)
        // A plugin window is READ through its sliders and WRITTEN through its
        // editable fields, and the two sets are not the same. Logic's "knob
        // and field" controls (Compressor, and the rest of the older Apple
        // effects) publish both; a knob-only plugin publishes sliders and NO
        // text field at all — `Channel EQ` 26 sliders / 0 fields, `Limiter`
        // 4 / 0, `Sensor` 0 / 0, measured 2026-08-28. Reporting the slider's
        // own settability as `writable` therefore promised a write that
        // `setParameter` cannot perform, so each parameter now says which of
        // the two it is.
        let fieldNames = writableParameterNames(in: window)
        return descendants(of: window)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXSliderRole as String }
            .compactMap(parameter(from:))
            .map { parameter in
                var entry = parameter.dictionary
                entry["ax_writable"] = fieldNames.contains {
                    $0.localizedCaseInsensitiveCompare(parameter.name) == .orderedSame
                }
                return entry
            }
    }

    /// Every parameter name this window can be WRITTEN by through
    /// Accessibility — one per editable "knob and field" control. Empty means
    /// the plugin is read-only from this plane, and the control surface is
    /// the only way in.
    func writableParameterNames(in window: AXUIElement) -> [String] {
        descendants(of: window)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXTextFieldRole as String }
            .map { extractedParameterName(fromHelp: stringAttribute($0, kAXHelpAttribute as String)) }
            .filter { !$0.isEmpty }
    }

    /// Resolves the field a write would go through, or throws the reason it
    /// cannot — WITHOUT writing anything. `evaluateChangeBounced` calls this
    /// before its first bounce so an unwritable parameter costs a lookup
    /// instead of a full master render.
    @discardableResult
    func parameterField(
        in window: AXUIElement, named parameterName: String, windowTitle: String
    ) throws -> AXUIElement {
        let candidates = descendants(of: window).filter { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == kAXTextFieldRole as String else {
                return false
            }
            return extractedParameterName(fromHelp: stringAttribute(element, kAXHelpAttribute as String))
                .localizedCaseInsensitiveCompare(parameterName) == .orderedSame
        }
        if candidates.isEmpty {
            let available = writableParameterNames(in: window)
            // Told apart because the fixes are different: a plugin with NO
            // editable fields cannot be written from this plane at all, and
            // saying "parameter not found" sends the agent hunting for a
            // better name that does not exist.
            guard !available.isEmpty else {
                throw LogicianError.trackNotExposed(
                    requested: "an Accessibility write of '\(parameterName)'",
                    exposed: "the plugin in window '\(windowTitle)' publishes no editable parameter fields"
                        + " — its controls are knobs only, so Accessibility can READ every value"
                        + " (logic_list_plugin_parameters) but write none of them."
                        + " Call logic_set_plugin_parameter again with track_name + insert_slot"
                        + " (logic_list_inserts route 'mcu') and it takes the control surface,"
                        + " which reaches every plugin; logic_evaluate_change method"
                        + " 'render'/'solo_bounce' writes through that same surface"
                )
            }
            throw LogicianError.parameterNotFound(
                "\(parameterName) (writable in this window: \(available.joined(separator: ", ")))"
            )
        }
        guard candidates.count == 1, let field = candidates.first else {
            throw LogicianError.parameterAmbiguous(parameterName, candidates.count)
        }
        return field
    }

    func setParameter(
        windowTitle: String,
        parameterName: String,
        expectedCurrentValue: String,
        targetValue: String
    ) throws -> [String: Any] {
        let window = try logicWindow(title: windowTitle)
        let field = try parameterField(in: window, named: parameterName, windowTitle: windowTitle)

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw LogicianError.valueNotWritable(parameterName)
        }

        let before = try revealFormattedValue(of: field, fallbackName: parameterName)
        guard equivalentFormattedValues(before, expectedCurrentValue) else {
            throw LogicianError.currentValueMismatch(expected: expectedCurrentValue, actual: before)
        }

        let writeStatus = AXUIElementSetAttributeValue(
            field,
            kAXValueAttribute as CFString,
            targetValue as CFString
        )
        guard writeStatus == .success else {
            throw LogicianError.writeFailed("AXError \(writeStatus.rawValue)")
        }

        let confirmStatus = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        guard confirmStatus == .success else {
            let restored = restore(field: field, value: before)
            throw LogicianError.confirmationFailed("AXError \(confirmStatus.rawValue); restored=\(restored)")
        }

        // No blind wait for the confirm to land: poll the field for the value
        // this line was going to read anyway, and stop the moment it says what
        // was asked for. The old `Thread.sleep(0.35)` here plus the 0.20 s
        // inside each `revealFormattedValue` were 750 ms of the 775–792 ms an
        // AX parameter write measured on 2026-09-01 (`logic_evaluate_change`
        // profile §5, phases B05/B07) — 96% of the phase, asleep. The
        // verification itself is unchanged: the same compare against the same
        // readback, only reached as soon as it is true instead of at a fixed
        // deadline. A field that really does take the old 0.55 s still gets it.
        // Whole-tool effect, measured 2026-09-02 on the sandbox: one
        // `logic_evaluate_change` method `bounce` (two of these writes) went
        // 6 316 ms → 4 687 ms.
        let after = try revealFormattedValue(
            of: field, fallbackName: parameterName,
            timeout: 0.55, settlingOn: { self.equivalentFormattedValues($0, targetValue) }
        )
        guard equivalentFormattedValues(after, targetValue) else {
            let restored = restore(field: field, value: before)
            throw LogicianError.verificationFailed(requested: targetValue, actual: after, restored: restored)
        }

        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "window": windowTitle,
            "parameter": parameterName,
            "before": before,
            "requested": targetValue,
            "after": after,
            "write_route": "accessibility_text_field",
            "readback_route": "accessibility_text_field",
            "rollback_value": before
        ]
    }

    func logicWindow(title: String) throws -> AXUIElement {
        guard let window = try logicWindows().first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == title
        }) else {
            throw LogicianError.windowNotFound(title)
        }
        return window
    }

    func parameter(from element: AXUIElement) -> AccessibleParameter? {
        let identifier = stringAttribute(element, kAXIdentifierAttribute as String)
        let help = stringAttribute(element, kAXHelpAttribute as String)
        let description = stringAttribute(element, kAXDescriptionAttribute as String)
        // Compressor-style sliders carry identifier+help; other plugins (e.g.
        // Channel EQ's band controls) expose description instead. Require some
        // semantic handle, not all of them.
        guard !identifier.isEmpty || !help.isEmpty || !description.isEmpty else {
            return nil
        }

        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )

        return AccessibleParameter(
            name: !help.isEmpty ? extractedParameterName(fromHelp: help)
                : (!description.isEmpty ? description : identifier),
            help: help,
            identifier: identifier,
            rawValue: stringAttribute(element, kAXValueAttribute as String),
            minimum: stringAttribute(element, kAXMinValueAttribute as String),
            maximum: stringAttribute(element, kAXMaxValueAttribute as String),
            valueDescription: stringAttribute(element, kAXValueDescriptionAttribute as String),
            valueSettable: settableStatus == .success && settable.boolValue
        )
    }

    func extractedParameterName(fromHelp help: String) -> String {
        let suffixes = LogicUIStrings.Element.parameterHelpSuffixes
        let firstSentence = help.split(separator: ".", maxSplits: 1).first.map(String.init) ?? help
        for suffix in suffixes {
            if let range = firstSentence.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                return String(firstSentence[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plugin parameter's value as Logic formats it, revealed by focusing
    /// the field (unfocused, many of these fields publish the parameter's NAME
    /// where its value belongs) and then reading it back.
    ///
    /// The read used to sit behind a blind `Thread.sleep(0.20)`. Measured
    /// 2026-09-01 (`logic_evaluate_change` profile §5): an AX text-field write
    /// is synchronous and the focused value is readable 0–6 ms later, so that
    /// sleep — and the 0.35 s `setParameter` slept after `kAXConfirmAction` —
    /// was 750 ms of a 775 ms write, on the helper EVERY AX plugin-parameter
    /// write in the server goes through. It is now a bounded poll on the very
    /// value the caller is about to compare: nothing is verified less, the
    /// answer just arrives when it is ready.
    ///
    /// `settlingOn` is what keeps the verification honest after a write. The
    /// field publishes its OLD value for a few ms after the confirm, so a poll
    /// that stopped at "something readable" would compare the pre-write value
    /// against the target and call a good write a failure. The default accepts
    /// any revealed value (right for a plain read, where nothing was written);
    /// a post-write caller passes the target test and gets today's semantics.
    /// On timeout the LAST revealed value is returned rather than thrown away,
    /// so the caller's own compare still produces the same `verificationFailed`
    /// naming the actual value it does today.
    func revealFormattedValue(
        of field: AXUIElement,
        fallbackName: String,
        timeout: TimeInterval = 0.20,
        settlingOn accept: (String) -> Bool = { _ in true }
    ) throws -> String {
        let focusStatus = AXUIElementSetAttributeValue(
            field,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard focusStatus == .success else {
            throw LogicianError.writeFailed("Could not focus \(fallbackName); AXError \(focusStatus.rawValue)")
        }
        var revealed: String?
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = stringAttribute(field, kAXValueAttribute as String)
            if !value.isEmpty, value.localizedCaseInsensitiveCompare(fallbackName) != .orderedSame {
                revealed = value
                if accept(value) { return value }
            }
            Thread.sleep(forTimeInterval: 0.004)
        } while Date() < deadline
        // Never revealed at all is the old failure, unchanged. Revealed but
        // never settling is the caller's compare to report, with the value.
        guard let revealed else {
            throw LogicianError.writeFailed("Could not reveal formatted value for \(fallbackName)")
        }
        return revealed
    }

    func restore(field: AXUIElement, value: String) -> Bool {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success,
              AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success else {
            return false
        }
        // Same bounded poll as the write's own verification, with the same
        // budget the two blind sleeps used to spend (0.25 + 0.20 s): a restore
        // that lands in 4 ms is not worth a quarter-second of sleep, and a
        // restore that never lands still fails after the full grace period.
        guard let restoredValue = try? revealFormattedValue(
            of: field, fallbackName: "parameter",
            timeout: 0.45, settlingOn: { self.equivalentFormattedValues($0, value) }
        ) else {
            return false
        }
        return equivalentFormattedValues(restoredValue, value)
    }

    func equivalentFormattedValues(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedFormattedValue(lhs)
        let right = normalizedFormattedValue(rhs)
        if left.text == right.text {
            return true
        }
        if let leftNumber = left.number, let rightNumber = right.number {
            return abs(leftNumber - rightNumber) < 0.0001
        }
        return false
    }

    func normalizedFormattedValue(_ value: String) -> (text: String, number: Double?) {
        // The comma-to-point map is LOCALE handling, not cosmetics: Logic
        // formats plugin readouts in the system's locale, so the same
        // Compressor ratio reads `4.0` on one Mac and `4,0` on the next.
        // See `LogicUIStrings.Format` for the other places this bites.
        var text = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
        if text.hasSuffix(":1") {
            text.removeLast(2)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numericPrefix = text.prefix { character in
            character.isNumber || character == "." || character == "-" || character == "+"
        }
        return (text, Double(numericPrefix))
    }

    /// Every descendant of `root` in pre-order, root itself EXCLUDED.
    /// The cap is measured from each child of the root rather than from the
    /// root — that is how the hand-rolled version counted, and changing it
    /// would silently shorten every plugin-window walk — so this reaches one
    /// level deeper than `collect(from:maximumDepth:)` with the same number.
    func descendants(of root: AXUIElement, maximumDepth: Int = AXDepth.wholeWindow) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in children(of: root) {
            walk(from: child, maximumDepth: maximumDepth) { element in
                result.append(element)
                return .descend
            }
        }
        return result
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    /// One enumeration of `element`'s children with ONE `AXDescription` read
    /// each, so a group that is asked for several named controls pays for the
    /// walk once instead of once per name.
    ///
    /// WHY. `children(of:).first { description == … }` re-fetches the sibling
    /// array and re-reads `AXDescription` on every child ahead of its target,
    /// which is invisible until the same group is asked six times. MEASURED
    /// 2026-09-02 on `logic_get_transport`: the control bar was enumerated
    /// eight times and its inner group five, **98 of the call's 129 AX reads**
    /// (~4.3 ms of ~8 ms), to read fourteen values. The metronome checkbox
    /// alone scanned thirteen descriptions, and the next lookup started over.
    ///
    /// First match wins, exactly as `first(where:)` did, so swapping a chain of
    /// lookups onto one index changes nothing about which element is found.
    func describedChildren(of element: AXUIElement) -> DescribedChildren {
        let all = children(of: element)
        var index: [String: AXUIElement] = [:]
        index.reserveCapacity(all.count)
        for child in all {
            let description = stringAttribute(child, kAXDescriptionAttribute as String)
            guard !description.isEmpty, index[description] == nil else { continue }
            index[description] = child
        }
        return DescribedChildren(all: all, byDescription: index)
    }

    func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        return String(describing: value)
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }

    /// An attribute that should hold another element. Attribute values arrive
    /// untyped (CFTypeRef) and Logic does answer with the wrong CF type on
    /// stale or half-built UI; forcing that with `as!` TRAPS, and a Swift trap
    /// kills the whole MCP server, so this degrades to nil exactly like a
    /// missing attribute — the path every caller already handles.
    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Swift refuses `as?` on CoreFoundation types ("will always
        // succeed"), so the type ID above IS the check; the force-cast that
        // follows it can no longer fail.
        return (value as! AXUIElement)
    }

    /// The CGRect inside an AXValue-typed attribute value, nil when the reply
    /// is not an AXValue or does not carry a rect — same reason: an `as!` to
    /// AXValue on a non-AXValue reply traps the process.
    func rectValue(_ value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }
}
