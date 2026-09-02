import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

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

    func pluginNamesMatch(_ displayed: String, _ requested: String) -> Bool {
        let lhs = displayed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        // Logic truncates displayed insert names (for example "Space D" for "Space Designer"),
        // so accept a prefix relationship in either direction.
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
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
        let mainWindow = try projectWindow()
        let headerGroup = firstDescendant(of: mainWindow, maximumDepth: AXDepth.trackHeaderGroup) { element in
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
        try children(of: trackHeaderGroup()).filter {
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

    func pollWindowDiff(before: Set<WindowKey>, expectAppear: Bool) throws -> AXUIElement? {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let current = try logicWindows()
            let appeared = current.filter { !before.contains(WindowKey(element: $0)) }
            if expectAppear, let new = appeared.first {
                return new
            }
            if !expectAppear, current.count < before.count {
                return nil
            }
        }
        return nil
    }

    func firstMissingWindow(from before: Set<WindowKey>) -> WindowKey? {
        guard let current = try? logicWindows() else { return nil }
        let currentKeys = Set(current.map(WindowKey.init))
        return before.first { !currentKeys.contains($0) }
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

    func openResult(
        state: String,
        track: String,
        slot: InsertSlot,
        windowTitle: String
    ) -> [String: Any] {
        [
            "success": true,
            "verified": true,
            "state": state,
            "track": track,
            "insert_index": slot.index,
            "plugin_display_name": slot.name,
            "window_title": windowTitle,
            "note": "Plugin window titles in Logic are the track name, not the plugin name. Use logic_list_plugin_parameters to inspect the window contents."
        ]
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

        Thread.sleep(forTimeInterval: 0.35)
        let after = try revealFormattedValue(of: field, fallbackName: parameterName)
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

    func revealFormattedValue(of field: AXUIElement, fallbackName: String) throws -> String {
        let focusStatus = AXUIElementSetAttributeValue(
            field,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard focusStatus == .success else {
            throw LogicianError.writeFailed("Could not focus \(fallbackName); AXError \(focusStatus.rawValue)")
        }
        Thread.sleep(forTimeInterval: 0.20)
        let value = stringAttribute(field, kAXValueAttribute as String)
        guard !value.isEmpty, value.localizedCaseInsensitiveCompare(fallbackName) != .orderedSame else {
            throw LogicianError.writeFailed("Could not reveal formatted value for \(fallbackName)")
        }
        return value
    }

    func restore(field: AXUIElement, value: String) -> Bool {
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success,
              AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.25)
        guard let restoredValue = try? revealFormattedValue(of: field, fallbackName: "parameter") else {
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
