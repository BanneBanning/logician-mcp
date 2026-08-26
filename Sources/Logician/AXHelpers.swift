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
        var match: AXUIElement?
        collect(from: mainWindow, maximumDepth: 12) { element in
            guard match == nil,
                  stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem",
                  stringAttribute(element, kAXHelpAttribute as String)
                      .localizedCaseInsensitiveContains("inspector channel strip"),
                  stringAttribute(element, kAXDescriptionAttribute as String) == name else { return }
            match = element
        }
        guard let strip = match else {
            throw DemoError.trackNotExposed(
                requested: name,
                exposed: "no inspector strip with that name is visible"
            )
        }
        return strip
    }

    func inspectorStrip(named trackName: String) throws -> AXUIElement {
        let mainWindow = try projectWindow()
        var strips: [(name: String, help: String, element: AXUIElement)] = []
        collect(from: mainWindow, maximumDepth: 12) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutItem" else { return }
            let help = stringAttribute(element, kAXHelpAttribute as String)
            guard help.localizedCaseInsensitiveContains("inspector channel strip") else { return }
            strips.append((
                name: stringAttribute(element, kAXDescriptionAttribute as String),
                help: help,
                element: element
            ))
        }
        guard let left = strips.first(where: { $0.help.hasPrefix("Left inspector") }) ?? strips.first else {
            throw DemoError.windowNotFound("left inspector channel strip")
        }
        if left.name == trackName {
            return left.element
        }
        // Output/aux strips ("Stereo Out") live in the right inspector strip
        // and are addressable by exact name without being selectable tracks.
        if let other = strips.first(where: { $0.name == trackName }) {
            return other.element
        }
        throw DemoError.trackNotExposed(requested: trackName, exposed: left.name)
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
                if role == "AXCheckBox", description == "bypass" { bypass = grandchild }
                if role == "AXButton", description == "open" { open = grandchild }
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
                throw DemoError.insertNotFound(
                    track: track,
                    plugin: "slot \(index)",
                    available: slots.map { "\($0.index): \($0.name)" }
                )
            }
            guard pluginNamesMatch(slot.name, plugin) else {
                throw DemoError.insertMismatch(slot: index, expected: plugin, actual: slot.name)
            }
            return slot
        }
        let matches = slots.filter { pluginNamesMatch($0.name, plugin) }
        guard !matches.isEmpty else {
            throw DemoError.insertNotFound(
                track: track,
                plugin: plugin,
                available: slots.map { "\($0.index): \($0.name)" }
            )
        }
        guard matches.count == 1, let slot = matches.first else {
            throw DemoError.insertAmbiguous(track: track, plugin: plugin, slots: matches.map(\.index))
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
        guard description.hasPrefix("Track "),
              let openQuote = description.firstIndex(of: "\u{201C}"),
              let closeQuote = description.lastIndex(of: "\u{201D}") else {
            return nil
        }
        let numberText = description[description.index(description.startIndex, offsetBy: 6)..<openQuote]
            .trimmingCharacters(in: .whitespaces)
        guard let number = Int(numberText) else { return nil }
        let name = String(description[description.index(after: openQuote)..<closeQuote])
        return (number, name)
    }

    func trackHeaderGroup() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        var headerGroup: AXUIElement?
        collect(from: mainWindow, maximumDepth: 12) { element in
            guard headerGroup == nil,
                  stringAttribute(element, kAXRoleAttribute as String) == "AXGroup",
                  stringAttribute(element, kAXDescriptionAttribute as String) == "Tracks header" else { return }
            headerGroup = element
        }
        guard let group = headerGroup else {
            throw DemoError.windowNotFound("Tracks header group")
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
        if let standard = windows.first(where: {
            documentPath(of: $0) != nil
                && stringAttribute($0, kAXSubroleAttribute as String) == "AXStandardWindow"
        }) {
            return standard
        }
        guard let fallback = windows.first(where: { documentPath(of: $0) != nil }) else {
            throw DemoError.windowNotFound("project window with AXDocument")
        }
        return fallback
    }

    func logicWindows() throws -> [AXUIElement] {
        guard AXIsProcessTrusted() else {
            throw DemoError.accessibilityNotTrusted
        }
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            throw DemoError.logicNotRunning
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
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
            guard let value = attribute(appElement, name) else { continue }
            let window = value as! AXUIElement
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

    func pollWindowDisappeared(before: Set<WindowKey>) throws -> Bool {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let currentKeys = Set(try logicWindows().map(WindowKey.init))
            if before.subtracting(currentKeys).isEmpty == false {
                return true
            }
        }
        return false
    }

    func closeWindowElement(_ window: AXUIElement) -> Bool {
        if let closeButton = attribute(window, kAXCloseButtonAttribute as String) {
            let button = closeButton as! AXUIElement
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return true
            }
        }
        // Windows like Drum Machine Designer expose no AXCloseButton attribute
        // but have a child button described as "close".
        if let childClose = children(of: window).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "close"
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

    func collect(
        from root: AXUIElement,
        maximumDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumDepth else { return }
            visit(element)
            for child in children(of: element) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
    }

    func listParameters(windowTitle: String) throws -> [[String: Any]] {
        let window = try logicWindow(title: windowTitle)
        return descendants(of: window)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == kAXSliderRole as String }
            .compactMap(parameter(from:))
            .map(\.dictionary)
    }

    func setParameter(
        windowTitle: String,
        parameterName: String,
        expectedCurrentValue: String,
        targetValue: String
    ) throws -> [String: Any] {
        let window = try logicWindow(title: windowTitle)
        let candidates = descendants(of: window).filter { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == kAXTextFieldRole as String else {
                return false
            }
            return extractedParameterName(fromHelp: stringAttribute(element, kAXHelpAttribute as String))
                .localizedCaseInsensitiveCompare(parameterName) == .orderedSame
        }

        guard !candidates.isEmpty else {
            throw DemoError.parameterNotFound(parameterName)
        }
        guard candidates.count == 1, let field = candidates.first else {
            throw DemoError.parameterAmbiguous(parameterName, candidates.count)
        }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw DemoError.valueNotWritable(parameterName)
        }

        let before = try revealFormattedValue(of: field, fallbackName: parameterName)
        guard equivalentFormattedValues(before, expectedCurrentValue) else {
            throw DemoError.currentValueMismatch(expected: expectedCurrentValue, actual: before)
        }

        let writeStatus = AXUIElementSetAttributeValue(
            field,
            kAXValueAttribute as CFString,
            targetValue as CFString
        )
        guard writeStatus == .success else {
            throw DemoError.writeFailed("AXError \(writeStatus.rawValue)")
        }

        let confirmStatus = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        guard confirmStatus == .success else {
            let restored = restore(field: field, value: before)
            throw DemoError.confirmationFailed("AXError \(confirmStatus.rawValue); restored=\(restored)")
        }

        Thread.sleep(forTimeInterval: 0.35)
        let after = try revealFormattedValue(of: field, fallbackName: parameterName)
        guard equivalentFormattedValues(after, targetValue) else {
            let restored = restore(field: field, value: before)
            throw DemoError.verificationFailed(requested: targetValue, actual: after, restored: restored)
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
            throw DemoError.windowNotFound(title)
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
        let suffixes = [" knob and field", " knob"]
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
            throw DemoError.writeFailed("Could not focus \(fallbackName); AXError \(focusStatus.rawValue)")
        }
        Thread.sleep(forTimeInterval: 0.20)
        let value = stringAttribute(field, kAXValueAttribute as String)
        guard !value.isEmpty, value.localizedCaseInsensitiveCompare(fallbackName) != .orderedSame else {
            throw DemoError.writeFailed("Could not reveal formatted value for \(fallbackName)")
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

    func descendants(of root: AXUIElement, maximumDepth: Int = 20) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumDepth else { return }
            for child in children(of: element) {
                result.append(child)
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
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
}
