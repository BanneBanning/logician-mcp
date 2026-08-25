import AppKit
import ApplicationServices
import LogicMCUBridge
import Foundation

private let protocolVersion = "2025-06-18"
private let serverName = "logician"
private let serverVersion = "0.40.0"

private enum DemoError: LocalizedError {
    case accessibilityNotTrusted
    case logicNotRunning
    case windowNotFound(String)
    case parameterNotFound(String)
    case parameterAmbiguous(String, Int)
    case valueNotWritable(String)
    case currentValueMismatch(expected: String, actual: String)
    case writeFailed(String)
    case confirmationFailed(String)
    case verificationFailed(requested: String, actual: String, restored: Bool)
    case invalidArguments(String)
    case projectMismatch(expected: String, actual: String)
    case trackNotExposed(requested: String, exposed: String)
    case insertNotFound(track: String, plugin: String, available: [String])
    case insertAmbiguous(track: String, plugin: String, slots: [Int])
    case insertMismatch(slot: Int, expected: String, actual: String)
    case openVerificationFailed(String)
    case windowNotClosable(String)
    case windowAmbiguous(String, Int)
    case pluginNotOpen(String)
    case trackNotFound(String, available: [String])
    case trackAmbiguous(String, numbers: [Int])
    case trackMismatch(number: Int, expected: String, actual: String)
    case selectionFailed(requested: String, actual: String, restored: Bool)
    case trackNotStack(String)

    var code: String {
        switch self {
        case .accessibilityNotTrusted: return "not_trusted"
        case .logicNotRunning: return "not_running"
        case .windowNotFound, .parameterNotFound, .insertNotFound, .trackNotFound: return "not_found"
        case .parameterAmbiguous, .insertAmbiguous, .windowAmbiguous, .trackAmbiguous: return "ambiguous"
        case .valueNotWritable, .trackNotExposed, .windowNotClosable, .trackNotStack: return "not_exposed"
        case .currentValueMismatch, .projectMismatch, .insertMismatch, .pluginNotOpen, .trackMismatch: return "precondition_failed"
        case .writeFailed, .confirmationFailed: return "write_failed"
        case .verificationFailed, .openVerificationFailed, .selectionFailed: return "verification_failed"
        case .invalidArguments: return "invalid_arguments"
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is not granted to the MCP process."
        case .logicNotRunning:
            return "Logic Pro is not running."
        case .windowNotFound(let title):
            return "Logic window not found: \(title)"
        case .parameterNotFound(let name):
            return "Accessible plugin parameter not found: \(name)"
        case .parameterAmbiguous(let name, let count):
            return "Accessible plugin parameter is ambiguous: \(name) matched \(count) controls."
        case .valueNotWritable(let name):
            return "The accessible value is not writable: \(name)"
        case .currentValueMismatch(let expected, let actual):
            return "Current value mismatch. Expected \(expected), found \(actual). No write was attempted."
        case .writeFailed(let detail):
            return "Accessibility write failed: \(detail)"
        case .confirmationFailed(let detail):
            return "Accessibility confirmation failed: \(detail)"
        case .verificationFailed(let requested, let actual, let restored):
            return "Readback mismatch. Requested \(requested), found \(actual). Restored: \(restored)."
        case .invalidArguments(let detail):
            return "Invalid arguments: \(detail)"
        case .projectMismatch(let expected, let actual):
            return "Open project mismatch. Expected \(expected), found \(actual). No action was taken."
        case .trackNotExposed(let requested, let exposed):
            return "Channel strip for track '\(requested)' is not exposed. The inspector currently shows '\(exposed)'. Select the track in Logic first."
        case .insertNotFound(let track, let plugin, let available):
            return "No insert matching '\(plugin)' on track '\(track)'. Available inserts: \(available.joined(separator: ", "))."
        case .insertAmbiguous(let track, let plugin, let slots):
            return "Insert '\(plugin)' on track '\(track)' is ambiguous; it occupies slots \(slots.map(String.init).joined(separator: ", ")). Pass insert_index to disambiguate."
        case .insertMismatch(let slot, let expected, let actual):
            return "Insert slot \(slot) holds '\(actual)', not '\(expected)'. No action was taken."
        case .openVerificationFailed(let detail):
            return "Could not verify that the plugin window state changed as requested: \(detail)"
        case .windowNotClosable(let title):
            return "Refusing to close window '\(title)': only plugin windows (dialogs without a document) may be closed."
        case .windowAmbiguous(let title, let count):
            return "\(count) windows share the title '\(title)'. Use logic_close_plugin with track, plugin and insert index instead."
        case .pluginNotOpen(let detail):
            return "The plugin window was not open: \(detail)"
        case .trackNotFound(let name, let available):
            return "No visible track header matches '\(name)'. Visible tracks: \(available.joined(separator: ", ")). Scrolled-out tracks are not exposed."
        case .trackAmbiguous(let name, let numbers):
            return "Track name '\(name)' is ambiguous; it matches track numbers \(numbers.map(String.init).joined(separator: ", ")). Pass track_number to disambiguate."
        case .trackMismatch(let number, let expected, let actual):
            return "Track \(number) is named '\(actual)', not '\(expected)'. No action was taken."
        case .selectionFailed(let requested, let actual, let restored):
            return "Track selection could not be verified. Requested '\(requested)', selection is '\(actual)'. Restored previous selection: \(restored)."
        case .trackNotStack(let name):
            return "Track '\(name)' exposes no track stack disclosure arrow; it is not a track stack."
        }
    }
}

private struct AccessibleParameter {
    let name: String
    let help: String
    let identifier: String
    let rawValue: String
    let minimum: String
    let maximum: String
    let valueDescription: String
    let valueSettable: Bool

    var dictionary: [String: Any] {
        [
            "name": name,
            "help": help,
            "ax_identifier": identifier,
            "raw_value": rawValue,
            "raw_min": minimum,
            "raw_max": maximum,
            "value_description": valueDescription,
            "writable": valueSettable
        ]
    }
}

private struct InsertSlot {
    let index: Int
    let name: String
    let bypassed: Bool
    let group: AXUIElement
    let openButton: AXUIElement?

    var dictionary: [String: Any] {
        [
            "insert_index": index,
            "plugin_display_name": name,
            "bypassed": bypassed,
            "can_open": openButton != nil
        ]
    }
}

private struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

private final class LogicAccessibility {
    private let bundleIdentifier = "com.apple.logic10"

    func health() -> [String: Any] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        var result: [String: Any] = [
            "accessibility_trusted": AXIsProcessTrusted(),
            "logic_running": !applications.isEmpty,
            "logic_pid": applications.first.map { Int($0.processIdentifier) } ?? NSNull(),
            "bundle_identifier": bundleIdentifier
        ]
        result["project_document"] = (try? projectDocumentPath()) ?? NSNull()
        return result
    }

    // MARK: - Read-only discovery

    func listWindows() throws -> [[String: Any]] {
        try logicWindows().map { window in
            [
                "title": stringAttribute(window, kAXTitleAttribute as String),
                "subrole": stringAttribute(window, kAXSubroleAttribute as String),
                "is_main": stringAttribute(window, kAXMainAttribute as String) == "1",
                "document": documentPath(of: window) ?? NSNull(),
                "kind": documentPath(of: window) != nil ? "project" : "plugin_or_auxiliary"
            ]
        }
    }

    func projectDocumentPath() throws -> String {
        for window in try logicWindows() {
            if let path = documentPath(of: window) {
                return path
            }
        }
        throw DemoError.windowNotFound("project window with AXDocument")
    }

    func listTracks() throws -> [String: Any] {
        let tracks: [[String: Any]] = try parsedTrackHeaders().map { header in
            var entry: [String: Any] = [
                "track_number": header.number,
                "track_name": header.name,
                "selected": header.selected,
                "is_stack": header.disclosure != nil
            ]
            if let expanded = header.expanded {
                entry["expanded"] = expanded
            }
            return entry
        }
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "tracks": tracks,
            "note": "Only track headers currently rendered in the Tracks area are exposed through Accessibility. Subtracks of collapsed track stacks and scrolled-out tracks are not listed; use logic_set_track_stack to expand a stack."
        ]
    }

    func listInserts(trackName: String) throws -> [String: Any] {
        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "track": trackName,
            "strip_source": "left_inspector_channel_strip",
            "inserts": slots.map(\.dictionary)
        ]
    }

    // MARK: - Offline bounce

    /// Presses a menu bar item found by title path fragment, e.g. Bounce >
    /// "Project or Section…".
    private func pressMenuItem(containing fragment: String, underMenu parent: String) throws {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else { throw DemoError.logicNotRunning }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar = attribute(appElement, kAXMenuBarAttribute as String) else {
            throw DemoError.windowNotFound("menu bar")
        }
        var target: AXUIElement?
        func walk(_ element: AXUIElement, depth: Int, path: [String]) {
            guard depth < 6, target == nil else { return }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            if stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem",
               title.contains(fragment), path.contains(parent) {
                target = element
                return
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1, path: title.isEmpty ? path : path + [title])
            }
        }
        walk(menuBar as! AXUIElement, depth: 0, path: [])
        guard let item = target else {
            throw DemoError.windowNotFound("menu item '\(fragment)' under '\(parent)'")
        }
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            throw DemoError.writeFailed("menu press returned AXError \(status.rawValue)")
        }
    }

    private func bounceDialog(timeout: Double = 4.0) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dialog = (try? logicWindows())?.first(where: {
                stringAttribute($0, kAXTitleAttribute as String).hasPrefix("Bounce")
            }) {
                return dialog
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// The bounce dialog's Start/End fields step one unit toward a written
    /// value per write (verified 2026-08-25); converge on the computed tick
    /// position: value(bar) = min + (bar-1) * ticksPerBar.
    private func setBouncePosition(group: AXUIElement, bar: Int) throws {
        guard let segment = children(of: group).first else {
            throw DemoError.valueNotWritable("bounce position group has no segments")
        }
        guard let minimum = Int64(stringAttribute(segment, kAXMinValueAttribute as String)) else {
            throw DemoError.valueNotWritable("bounce position minimum unreadable")
        }
        let ticksPerBar: Int64 = 16_492_674_416_640
        let target = minimum + Int64(bar - 1) * ticksPerBar
        if Int64(stringAttribute(segment, kAXValueAttribute as String)) == target { return }
        var last: Int64 = -1
        for _ in 0..<128 {
            guard let current = Int64(stringAttribute(segment, kAXValueAttribute as String)) else { break }
            if current == target { return }
            if current == last, current != target {
                throw DemoError.verificationFailed(
                    requested: "bounce position bar \(bar)",
                    actual: "stuck at raw \(current)",
                    restored: false
                )
            }
            last = current
            _ = AXUIElementSetAttributeValue(segment, kAXValueAttribute as CFString, NSNumber(value: target))
            Thread.sleep(forTimeInterval: 0.06)
        }
        guard Int64(stringAttribute(segment, kAXValueAttribute as String)) == target else {
            throw DemoError.verificationFailed(
                requested: "bounce position bar \(bar)",
                actual: stringAttribute(group, kAXValueAttribute as String),
                restored: false
            )
        }
    }

    private func destinationRows(in dialog: AXUIElement) -> [(name: String, checkbox: AXUIElement)] {
        guard let scroll = children(of: dialog).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXScrollArea"
        }) else { return [] }
        var rows: [(String, AXUIElement)] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox" {
                rows.append((stringAttribute(element, kAXDescriptionAttribute as String), element))
            }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(scroll, depth: 0)
        return rows
    }

    private func savePanelApplication() -> AXUIElement? {
        for process in NSWorkspace.shared.runningApplications
        where (process.bundleIdentifier ?? "").contains("openAndSavePanelService") {
            let element = AXUIElementCreateApplication(process.processIdentifier)
            var windows = attribute(element, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            if windows.isEmpty {
                windows = children(of: element).filter {
                    stringAttribute($0, kAXRoleAttribute as String) == kAXWindowRole as String
                }
            }
            if !windows.isEmpty { return element }
        }
        return nil
    }

    private func findDescendant(
        of root: AXUIElement,
        maximumDepth: Int = 10,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var result: AXUIElement?
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < maximumDepth, result == nil else { return }
            if predicate(element) { result = element; return }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return result
    }

    func bounceRange(
        startBar: Int,
        endBar: Int,
        label: String,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)
        guard endBar > startBar else {
            throw DemoError.invalidArguments("end_bar must be greater than start_bar")
        }
        try ensureLogicFrontmost(for: "the bounce dialog") // dialogs need key focus

        try pressMenuItem(containing: "Project or Section", underMenu: "Bounce")
        guard let dialog = bounceDialog() else {
            throw DemoError.windowNotFound("bounce dialog")
        }

        // Destinations: ensure exactly Uncompressed. Settings persist between
        // bounces, so this is usually zero presses.
        for (name, checkbox) in destinationRows(in: dialog) {
            let checked = stringAttribute(checkbox, kAXValueAttribute as String) == "1"
            let wanted = name == "Uncompressed"
            if checked != wanted {
                _ = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.12)
            }
        }

        // Positions: start and end groups (tab-separated bar values).
        let groups = children(of: dialog).filter {
            stringAttribute($0, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute($0, kAXValueAttribute as String).contains("\t")
        }
        guard groups.count == 2 else {
            _ = children(of: dialog).first { stringAttribute($0, kAXTitleAttribute as String) == "Cancel" }
                .map { AXUIElementPerformAction($0, kAXPressAction as CFString) }
            throw DemoError.windowNotFound("start/end position fields in the bounce dialog")
        }
        try setBouncePosition(group: groups[1], bar: endBar) // end first avoids clamping
        try setBouncePosition(group: groups[0], bar: startBar)

        guard let okButton = children(of: dialog).first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == "OK"
        }) else {
            throw DemoError.windowNotFound("OK button in the bounce dialog")
        }
        _ = AXUIElementPerformAction(okButton, kAXPressAction as CFString)

        // The save panel is hosted either inside Logic's own window (same
        // title as the dialog) or in an AppKit XPC service process; find it in
        // both places by its Bounce button.
        let bounceStart = Date()
        var panelRoot: AXUIElement?
        let panelDeadline = Date().addingTimeInterval(8)
        while Date() < panelDeadline && panelRoot == nil {
            Thread.sleep(forTimeInterval: 0.08)
            if let hosted = (try? logicWindows())?.first(where: { window in
                self.findDescendant(of: window, where: {
                    self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                        && self.stringAttribute($0, kAXTitleAttribute as String) == "Bounce"
                }) != nil
            }) {
                panelRoot = hosted
            } else if let xpc = savePanelApplication() {
                panelRoot = xpc
            }
        }
        guard let panel = panelRoot else {
            throw DemoError.openVerificationFailed("the save panel did not appear")
        }

        // The panel keeps its default name regardless of AXValue writes, so we
        // accept the default and move the rendered file to the label name after.
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "logicmcp-\(label)-\(timestamp)"
        guard let bounceButton = findDescendant(of: panel, where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == "Bounce"
        }) else {
            throw DemoError.openVerificationFailed("no Bounce button in the save panel")
        }
        guard AXUIElementPerformAction(bounceButton, kAXPressAction as CFString) == .success else {
            throw DemoError.writeFailed("pressing Bounce failed")
        }
        // A possible "already exists" sheet: press Replace.
        Thread.sleep(forTimeInterval: 0.25)
        if let replace = (try? logicWindows())?.lazy.compactMap({ window in
            self.findDescendant(of: window, where: {
                self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                    && self.stringAttribute($0, kAXTitleAttribute as String) == "Replace"
            })
        }).first {
            _ = AXUIElementPerformAction(replace, kAXPressAction as CFString)
        }

        // Wait for the rendered file: the unique name, or (when the panel kept
        // the default name) any audio file created after the bounce started.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Music/Logic/Bounces"),
            home.appendingPathComponent("Music/Logic"),
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads")
        ]
        func findResult() -> String? {
            for directory in candidates {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.creationDateKey]
                ) else { continue }
                for entry in entries {
                    let name = entry.lastPathComponent
                    if name.hasPrefix(filename) { return entry.path }
                    // The panel can claim the custom name stuck yet still save
                    // under the default name — always accept fresh audio files.
                    if ["aif", "aiff", "wav"].contains(entry.pathExtension.lowercased()),
                       let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                       created > bounceStart {
                        return entry.path
                    }
                }
            }
            return nil
        }
        var resultPath: String?
        var lastSize: UInt64 = 0
        let renderDeadline = Date().addingTimeInterval(60)
        while Date() < renderDeadline {
            Thread.sleep(forTimeInterval: 0.1)
            if resultPath == nil { resultPath = findResult() }
            if let path = resultPath {
                let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64) ?? 0
                if size > 0, size == lastSize {
                    break // size stable = render finished
                }
                lastSize = size
            }
        }
        guard let renderedPath = resultPath else {
            throw DemoError.openVerificationFailed(
                "no bounced file appeared within 60 s"
            )
        }
        // Move the render into the captures directory under the label name.
        let capturesDirectory = home.appendingPathComponent(
            "Library/Application Support/LogicMCPSensor/captures"
        )
        try? FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        let destination = capturesDirectory.appendingPathComponent(
            "\(filename).\(URL(fileURLWithPath: renderedPath).pathExtension)"
        )
        let finalPath: String
        if (try? FileManager.default.moveItem(
            at: URL(fileURLWithPath: renderedPath), to: destination
        )) != nil {
            finalPath = destination.path
        } else {
            finalPath = renderedPath
        }

        return [
            "success": true,
            "verified": true,
            "state": "bounced",
            "path": finalPath,
            "start_bar": startBar,
            "end_bar": endBar,
            "bytes": Int(lastSize),
            "write_route": "bounce_dialog_offline",
            "note": "Offline render of the master output; destination settings restored to the user's previous selection."
        ]
    }

    /// RMS/peak per channel from a bounced AIFF (big-endian PCM) or WAV file —
    /// the objective numbers for bounce-based A/B, computed straight from disk.
    static func audioFileMetrics(path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 64 else {
            return nil
        }
        func beUInt32(_ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset+1]) << 16)
                | (UInt32(data[offset+2]) << 8) | UInt32(data[offset+3])
        }
        func beUInt16(_ offset: Int) -> UInt16 {
            (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
        }
        let formType = String(data: data[8..<12], encoding: .ascii) ?? ""
        guard String(data: data[0..<4], encoding: .ascii) == "FORM",
              formType == "AIFF" || formType == "AIFC" else {
            return nil // AIFF/AIFC only (Logic's bounce and freeze formats here)
        }
        var offset = 12
        var channels = 0, bits = 0
        var isFloat = false
        var soundStart = 0, soundBytes = 0
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(beUInt32(offset + 4))
            if chunkID == "COMM", offset + 8 + 8 <= data.count {
                channels = Int(beUInt16(offset + 8))
                bits = Int(beUInt16(offset + 14))
                // AIFC carries a compression type after the PCM fields;
                // Logic's freeze files are 'fl32' (32-bit big-endian float).
                if size >= 22, offset + 30 <= data.count {
                    let compression = String(
                        data: data[offset+26..<offset+30], encoding: .ascii
                    ) ?? ""
                    isFloat = compression.lowercased() == "fl32"
                }
            }
            if chunkID == "SSND" {
                let dataOffset = Int(beUInt32(offset + 8))
                soundStart = offset + 16 + dataOffset
                soundBytes = size - 8 - dataOffset
            }
            offset += 8 + size + (size % 2)
        }
        guard channels > 0, bits == 24 || bits == 16 || (bits == 32 && isFloat),
              soundStart > 0, soundBytes > 0,
              soundStart + soundBytes <= data.count else { return nil }
        let bytesPerSample = bits / 8
        let frames = soundBytes / (bytesPerSample * channels)
        var sumSquares = [Double](repeating: 0, count: min(channels, 2))
        var peaks = [Double](repeating: 0, count: min(channels, 2))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: soundStart).assumingMemoryBound(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<min(channels, 2) {
                    let sampleOffset = (frame * channels + channel) * bytesPerSample
                    let normalized: Double
                    if bits == 32 {
                        let pattern = (UInt32(base[sampleOffset]) << 24)
                            | (UInt32(base[sampleOffset+1]) << 16)
                            | (UInt32(base[sampleOffset+2]) << 8)
                            | UInt32(base[sampleOffset+3])
                        normalized = Double(Float(bitPattern: pattern))
                    } else {
                        var value: Int32
                        if bits == 24 {
                            value = (Int32(base[sampleOffset]) << 16)
                                | (Int32(base[sampleOffset+1]) << 8)
                                | Int32(base[sampleOffset+2])
                            if value >= 0x800000 { value -= 0x1000000 }
                        } else {
                            value = (Int32(base[sampleOffset]) << 8) | Int32(base[sampleOffset+1])
                            if value >= 0x8000 { value -= 0x10000 }
                        }
                        normalized = Double(value) / Double(1 << (bits - 1))
                    }
                    sumSquares[channel] += normalized * normalized
                    peaks[channel] = max(peaks[channel], abs(normalized))
                }
            }
        }
        func decibels(_ linear: Double) -> Double {
            linear > 1e-7 ? (20 * log10(linear) * 100).rounded() / 100 : -140
        }
        return [
            "rms_db": sumSquares.map { decibels(($0 / Double(max(frames, 1))).squareRoot()) },
            "peak_db": peaks.map(decibels),
            "channels": channels,
            "bits": bits,
            "frames": frames
        ]
    }

    /// Cuts a time range out of an AIFF/AIFC render (16/24-bit PCM or fl32)
    /// and writes it as a 32-bit float WAV, computing RMS/peak on the slice
    /// in the same pass. Freeze files start at project start (bar 1), so
    /// bar positions convert directly to seconds via tempo.
    static func sliceAudioFile(
        path: String, startSeconds: Double, endSeconds: Double, destinationPath: String
    ) -> [String: Any]? {
        guard endSeconds > startSeconds,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 64 else {
            return nil
        }
        func beUInt32(_ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset+1]) << 16)
                | (UInt32(data[offset+2]) << 8) | UInt32(data[offset+3])
        }
        func beUInt16(_ offset: Int) -> UInt16 {
            (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
        }
        let formType = String(data: data[8..<12], encoding: .ascii) ?? ""
        guard String(data: data[0..<4], encoding: .ascii) == "FORM",
              formType == "AIFF" || formType == "AIFC" else { return nil }
        var offset = 12
        var channels = 0, bits = 0
        var isFloat = false
        var sampleRate = 0.0
        var soundStart = 0, soundBytes = 0
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = Int(beUInt32(offset + 4))
            if chunkID == "COMM", offset + 34 <= data.count {
                channels = Int(beUInt16(offset + 8))
                bits = Int(beUInt16(offset + 14))
                // 80-bit extended float sample rate
                let exponent = Int(beUInt16(offset + 16)) & 0x7FFF
                var mantissa: UInt64 = 0
                for i in 0..<8 { mantissa = (mantissa << 8) | UInt64(data[offset + 18 + i]) }
                sampleRate = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
                if size >= 22, offset + 30 <= data.count {
                    let compression = String(
                        data: data[offset+26..<offset+30], encoding: .ascii
                    ) ?? ""
                    isFloat = compression.lowercased() == "fl32"
                }
            }
            if chunkID == "SSND" {
                let dataOffset = Int(beUInt32(offset + 8))
                soundStart = offset + 16 + dataOffset
                soundBytes = size - 8 - dataOffset
            }
            offset += 8 + size + (size % 2)
        }
        guard channels > 0, sampleRate > 1000,
              bits == 24 || bits == 16 || (bits == 32 && isFloat),
              soundStart > 0, soundBytes > 0,
              soundStart + soundBytes <= data.count else { return nil }
        let bytesPerSample = bits / 8
        let totalFrames = soundBytes / (bytesPerSample * channels)
        let firstFrame = min(Int(startSeconds * sampleRate), totalFrames)
        let lastFrame = min(Int(endSeconds * sampleRate), totalFrames)
        let sliceFrames = lastFrame - firstFrame
        guard sliceFrames > 0 else { return nil }

        var payload = Data(capacity: sliceFrames * channels * 4)
        var sumSquares = [Double](repeating: 0, count: min(channels, 2))
        var peaks = [Double](repeating: 0, count: min(channels, 2))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: soundStart).assumingMemoryBound(to: UInt8.self)
            for frame in firstFrame..<lastFrame {
                for channel in 0..<channels {
                    let sampleOffset = (frame * channels + channel) * bytesPerSample
                    let value: Float
                    if bits == 32 {
                        let pattern = (UInt32(base[sampleOffset]) << 24)
                            | (UInt32(base[sampleOffset+1]) << 16)
                            | (UInt32(base[sampleOffset+2]) << 8)
                            | UInt32(base[sampleOffset+3])
                        value = Float(bitPattern: pattern)
                    } else if bits == 24 {
                        var integer = (Int32(base[sampleOffset]) << 16)
                            | (Int32(base[sampleOffset+1]) << 8)
                            | Int32(base[sampleOffset+2])
                        if integer >= 0x800000 { integer -= 0x1000000 }
                        value = Float(integer) / Float(1 << 23)
                    } else {
                        var integer = (Int32(base[sampleOffset]) << 8) | Int32(base[sampleOffset+1])
                        if integer >= 0x8000 { integer -= 0x10000 }
                        value = Float(integer) / Float(1 << 15)
                    }
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
                    if channel < 2 {
                        let normalized = Double(value)
                        sumSquares[channel] += normalized * normalized
                        peaks[channel] = max(peaks[channel], abs(normalized))
                    }
                }
            }
        }

        // 32-bit float WAV (RIFF fmt 3 + fact)
        var wav = Data()
        func appendLE32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func appendLE16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(4 + 24 + 12 + 8 + payload.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)
        appendLE16(3) // IEEE float
        appendLE16(UInt16(channels))
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate) * UInt32(channels) * 4)
        appendLE16(UInt16(channels * 4))
        appendLE16(32)
        wav.append(contentsOf: Array("fact".utf8))
        appendLE32(4)
        appendLE32(UInt32(sliceFrames))
        wav.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(payload.count))
        wav.append(payload)
        guard (try? wav.write(to: URL(fileURLWithPath: destinationPath))) != nil else { return nil }

        func decibels(_ linear: Double) -> Double {
            linear > 1e-7 ? (20 * log10(linear) * 100).rounded() / 100 : -140
        }
        return [
            "path": destinationPath,
            "start_seconds": (startSeconds * 1000).rounded() / 1000,
            "end_seconds": (endSeconds * 1000).rounded() / 1000,
            "frames": sliceFrames,
            "sample_rate": sampleRate,
            "channels": channels,
            "metrics": [
                "rms_db": sumSquares.map { decibels(($0 / Double(sliceFrames)).squareRoot()) },
                "peak_db": peaks.map(decibels)
            ]
        ]
    }

    /// Bounce-based A/B evaluation: no playback, no sensor — two offline
    /// renders around one verified parameter change, metrics from the files.
    func evaluateChangeBounced(
        trackName: String,
        pluginName: String,
        insertIndex: Int?,
        parameter: String,
        expectedCurrentValue: String,
        targetValue: String,
        startBar: Int,
        endBar: Int,
        keepChange: Bool,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)
        _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
        let openResult = try openPlugin(
            trackName: trackName, pluginName: pluginName,
            insertIndex: insertIndex, expectedProjectPath: nil
        )
        let openedByUs = (openResult["state"] as? String) == "opened"
        defer {
            if openedByUs {
                _ = try? closePlugin(trackName: trackName, pluginName: pluginName, insertIndex: insertIndex)
            }
        }

        let bounceA = try bounceRange(
            startBar: startBar, endBar: endBar, label: "A", expectedProjectPath: nil
        )
        let change = try setParameter(
            windowTitle: trackName, parameterName: parameter,
            expectedCurrentValue: expectedCurrentValue, targetValue: targetValue
        )
        let bounceB = try bounceRange(
            startBar: startBar, endBar: endBar, label: "B", expectedProjectPath: nil
        )
        var decision = "kept"
        if !keepChange {
            _ = try setParameter(
                windowTitle: trackName, parameterName: parameter,
                expectedCurrentValue: targetValue, targetValue: expectedCurrentValue
            )
            decision = "rolled_back"
        }

        let pathA = bounceA["path"] as? String ?? ""
        let pathB = bounceB["path"] as? String ?? ""
        let metricsA = LogicAccessibility.audioFileMetrics(path: pathA)
        let metricsB = LogicAccessibility.audioFileMetrics(path: pathB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        return [
            "success": true,
            "verified": true,
            "state": "evaluated",
            "method": "bounce",
            "decision": decision,
            "change": [
                "track": trackName, "plugin": pluginName, "parameter": parameter,
                "before": change["before"] ?? expectedCurrentValue,
                "applied": change["after"] ?? targetValue
            ],
            "loop": ["start_bar": startBar, "end_bar": endBar],
            "baseline_audio": pathA,
            "after_audio": pathB,
            "baseline_metrics": metricsA ?? NSNull(),
            "after_metrics": metricsB ?? NSNull(),
            "deltas": deltas,
            "note": "Offline 24-bit master renders; no playback occurred. Metrics computed from the files."
        ]
    }

    // MARK: - Regions (Tracks-area layout items)

    /// Region elements grouped per track row. Each row is an AXLayoutArea
    /// described 'Track N “Name”'; its AXLayoutItem children are the regions,
    /// with name in AXDescription and musical position in AXHelp
    /// ("Region starts at X bars ... and ends at Y bars ..., MIDI region.").
    private func regionRows() throws -> [(number: Int, track: String, regions: [AXUIElement])] {
        guard let window = try logicWindows().first(where: {
            stringAttribute($0, kAXSubroleAttribute as String) == "AXStandardWindow"
        }) else {
            throw DemoError.windowNotFound("project window")
        }
        var rows: [(Int, String, [AXUIElement])] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 10 else { return }
            let description = stringAttribute(element, kAXDescriptionAttribute as String)
            if stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea",
               description.hasPrefix("Track "), description.contains("“") {
                let digits = description.dropFirst(6).prefix { $0.isNumber }
                let name = description.split(separator: "“").last.map {
                    String($0).replacingOccurrences(of: "”", with: "")
                } ?? description
                let regions = children(of: element).filter {
                    stringAttribute($0, "AXRoleDescription") == "Region"
                }
                rows.append((Int(digits) ?? 0, name, regions))
                return // region items have no nested rows
            }
            for child in children(of: element) { walk(child, depth + 1) }
        }
        walk(window, 0)
        return rows
    }

    private func parseRegion(_ element: AXUIElement) -> [String: Any] {
        var entry: [String: Any] = [
            "name": stringAttribute(element, kAXDescriptionAttribute as String),
            "selected": stringAttribute(element, "AXSelected") == "1"
        ]
        let help = stringAttribute(element, kAXHelpAttribute as String)
        // "Region starts at 9 bars 2 beats and ends at 11 bars , MIDI region."
        // Two independent regexes keep the optional beats simple.
        func capture(_ pattern: String) -> (bar: Int, beat: Int)? {
            guard let range = help.range(of: pattern, options: .regularExpression) else { return nil }
            let segment = String(help[range])
            let parts = segment.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let bar = parts.first else { return nil }
            return (bar, parts.count > 1 ? parts[1] : 1)
        }
        if let start = capture(#"starts at \d+ bars?\s*(\d+ beats?)?"#) {
            entry["start_bar"] = start.bar
            if start.beat != 1 { entry["start_beat"] = start.beat }
        }
        if let end = capture(#"ends at \d+ bars?\s*(\d+ beats?)?"#) {
            entry["end_bar"] = end.bar
            if end.beat != 1 { entry["end_beat"] = end.beat }
        }
        if let typeRange = help.range(of: #",\s*([A-Za-z]+) region"#, options: .regularExpression) {
            let segment = String(help[typeRange])
            entry["type"] = segment
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "region", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return entry
    }

    /// The arrangement map: every region on every visible track, with bar
    /// positions and type parsed from the element's help text.
    func listRegions(trackName: String?) throws -> [String: Any] {
        let rows = try regionRows()
        var tracks: [[String: Any]] = []
        for row in rows {
            if let filter = trackName,
               row.track.caseInsensitiveCompare(filter) != .orderedSame { continue }
            tracks.append([
                "track_number": row.number,
                "track_name": row.track,
                "regions": row.regions.map(parseRegion)
            ])
        }
        if let filter = trackName, tracks.isEmpty {
            throw DemoError.trackNotExposed(
                requested: "regions on '\(filter)'",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "tracks": tracks,
            "note": "Only regions on currently rendered track rows are listed (scrolled-out tracks are not exposed). Positions are whole bars/beats as Logic's own help text reports them."
        ]
    }

    /// Selects one region, identified by track + name and/or start bar.
    /// exclusive (default) first clears every other selected region so the
    /// following edit operation (cut/copy/nudge…) touches ONLY this one.
    func selectRegion(
        trackName: String, regionName: String?, startBar: Int?, exclusive: Bool
    ) throws -> [String: Any] {
        guard regionName != nil || startBar != nil else {
            throw DemoError.invalidArguments("pass region_name and/or start_bar")
        }
        let rows = try regionRows()
        guard let row = rows.first(where: {
            $0.track.caseInsensitiveCompare(trackName) == .orderedSame
        }) else {
            throw DemoError.trackNotExposed(
                requested: "track '\(trackName)'",
                exposed: "visible track rows: " + rows.map(\.track).joined(separator: ", ")
            )
        }
        let annotated = row.regions.map { ($0, parseRegion($0)) }
        let hits = annotated.filter { _, info in
            if let name = regionName,
               (info["name"] as? String)?.caseInsensitiveCompare(name) != .orderedSame {
                return false
            }
            if let bar = startBar, info["start_bar"] as? Int != bar { return false }
            return true
        }
        guard hits.count == 1, let hit = hits.first else {
            throw DemoError.parameterAmbiguous(
                "region on '\(trackName)' (candidates: " + annotated.map { _, info in
                    "\(info["name"] ?? "?")@bar\(info["start_bar"] ?? 0)"
                }.joined(separator: ", ") + ")",
                hits.count
            )
        }
        if exclusive {
            for otherRow in rows {
                for region in otherRow.regions
                where stringAttribute(region, "AXSelected") == "1" && !CFEqual(region, hit.0) {
                    _ = AXUIElementSetAttributeValue(region, "AXSelected" as CFString, kCFBooleanFalse)
                }
            }
        }
        var stuck = false
        for attempt in 0..<2 {
            let status = AXUIElementSetAttributeValue(
                hit.0, "AXSelected" as CFString, kCFBooleanTrue
            )
            guard status == .success else {
                throw DemoError.writeFailed("AXSelected write returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.3)
            if stringAttribute(hit.0, "AXSelected") == "1" { stuck = true; break }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) } // stale-element transient
        }
        guard stuck else {
            throw DemoError.verificationFailed(
                requested: "region selected",
                actual: "the region's AXSelected did not stick after a retry",
                restored: false
            )
        }
        // Key commands like Delete act on the FOCUSED area's selection —
        // hand the region keyboard focus so they cannot miss (best effort).
        _ = AXUIElementSetAttributeValue(hit.0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var result = parseRegion(hit.0)
        result["success"] = true
        result["verified"] = true
        result["track"] = row.track
        result["exclusive"] = exclusive
        return result
    }

    /// The channel strip's pan value (the strip's pan AXSlider), always
    /// readable regardless of which MCU view is active.
    func stripPanValue(trackName: String) -> Double? {
        guard let strip = try? inspectorStrip(named: trackName) else { return nil }
        for child in children(of: strip)
        where stringAttribute(child, kAXDescriptionAttribute as String) == "pan" {
            return Double(stringAttribute(child, kAXValueAttribute as String))
        }
        return nil
    }

    /// Rapid-fire stepwise write toward a pan target on the strip's pan
    /// knob, bounded by a time budget (one step per ~15 ms write).
    func stripPanWrite(trackName: String, target: Double, budget: TimeInterval) throws {
        guard let strip = try? inspectorStrip(named: trackName) else {
            throw DemoError.windowNotFound("channel strip for '\(trackName)'")
        }
        guard let knob = children(of: strip).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "pan"
        }) else {
            throw DemoError.windowNotFound("pan knob on '\(trackName)'")
        }
        let goal = Int(target.rounded())
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            guard let current = Int(stringAttribute(knob, kAXValueAttribute as String)) else { break }
            if current == goal { return }
            _ = AXUIElementSetAttributeValue(knob, kAXValueAttribute as CFString, goal as CFNumber)
            usleep(15000)
        }
    }

    /// The channel strip's automation-mode label, e.g. "Latch" from
    /// "Latch, automation enabled". nil when the strip is not visible.
    func automationModeLabel(trackName: String) -> String? {
        guard let strip = try? inspectorStrip(named: trackName) else { return nil }
        for child in children(of: strip) {
            let description = stringAttribute(child, kAXDescriptionAttribute as String)
            if description.contains("automation") {
                return description.split(separator: ",").first.map(String.init)
            }
        }
        return nil
    }

    // MARK: - Region editing (exclusive selection + learned key commands)

    private func fireKeyCommand(_ name: String) throws {
        let command = try MCUController.resolveKeyCommand(named: name, logic: self)
        _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
    }

    private func regionSnapshot(trackName: String) throws -> [[String: Any]] {
        let map = try listRegions(trackName: trackName)
        return ((map["tracks"] as? [[String: Any]])?.first?["regions"] as? [[String: Any]]) ?? []
    }

    /// Counts selected regions across ALL visible rows — the guard that must
    /// pass (exactly 1) immediately before any destructive key command fires.
    private func selectedRegionCount() throws -> Int {
        try regionRows().reduce(0) { sum, row in
            sum + row.regions.filter { stringAttribute($0, "AXSelected") == "1" }.count
        }
    }

    func deleteRegion(
        trackName: String, regionName: String?, startBar: Int?
    ) throws -> [String: Any] {
        let before = try regionSnapshot(trackName: trackName)
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw DemoError.verificationFailed(
                requested: "exactly one selected region before Delete",
                actual: "\(try selectedRegionCount()) regions selected; refusing to fire Delete",
                restored: true
            )
        }
        try fireKeyCommand("Delete")
        var gone = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.4)
            let after = try regionSnapshot(trackName: trackName)
            let stillThere = after.contains {
                $0["start_bar"] as? Int == selection["start_bar"] as? Int
                    && ($0["name"] as? String) == (selection["name"] as? String)
            }
            if after.count == before.count - 1 && !stillThere { gone = true; break }
        }
        guard gone else {
            throw DemoError.verificationFailed(
                requested: "region '\(selection["name"] ?? "?")' deleted",
                actual: "the region is still in the arrangement map (undo history unaffected)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "deleted",
            "track": trackName,
            "region": selection["name"] ?? "?",
            "start_bar": selection["start_bar"] ?? NSNull(),
            "note": "Removable mistake? Undo restores it."
        ]
    }

    func moveRegion(
        trackName: String, regionName: String?, startBar: Int?,
        byBars: Int, byBeats: Int
    ) throws -> [String: Any] {
        guard byBars != 0 || byBeats != 0 else {
            throw DemoError.invalidArguments("pass a non-zero by_bars and/or by_beats")
        }
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw DemoError.verificationFailed(
                requested: "exactly one selected region before nudging",
                actual: "selection drifted; refusing", restored: true
            )
        }
        let oldStart = selection["start_bar"] as? Int ?? 0
        for _ in 0..<abs(byBars) {
            try fireKeyCommand(byBars > 0
                ? "Nudge Region/Event Position Right by Bar"
                : "Nudge Region/Event Position Left by Bar")
            Thread.sleep(forTimeInterval: 0.15)
        }
        for _ in 0..<abs(byBeats) {
            try fireKeyCommand(byBeats > 0
                ? "Nudge Region/Event Position Right by Beat"
                : "Nudge Region/Event Position Left by Beat")
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.4)
        // Whole-bar moves verify exactly; beat moves verify that the region
        // left its old slot (Logic's help text rounds to bars+beats).
        let after = try regionSnapshot(trackName: trackName)
        let target = after.first {
            ($0["name"] as? String) == (selection["name"] as? String)
                && ($0["selected"] as? Bool) == true
        }
        guard let moved = target else {
            throw DemoError.verificationFailed(
                requested: "the moved region still selected at its new position",
                actual: "could not find it in the arrangement map",
                restored: false
            )
        }
        if byBeats == 0, let newBar = moved["start_bar"] as? Int, newBar != oldStart + byBars {
            throw DemoError.verificationFailed(
                requested: "region at bar \(oldStart + byBars)",
                actual: "region at bar \(newBar)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "moved",
            "track": trackName,
            "region": selection["name"] ?? "?",
            "from_bar": oldStart,
            "to_bar": moved["start_bar"] ?? NSNull(),
            "to_beat": moved["start_beat"] ?? 1
        ]
    }

    func copyRegion(
        trackName: String, regionName: String?, startBar: Int?,
        toBar: Int, toTrack: String?, move: Bool
    ) throws -> [String: Any] {
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        guard try selectedRegionCount() == 1 else {
            throw DemoError.verificationFailed(
                requested: "exactly one selected region before \(move ? "Cut" : "Copy")",
                actual: "selection drifted; refusing", restored: true
            )
        }
        try fireKeyCommand(move ? "Cut" : "Copy")
        Thread.sleep(forTimeInterval: 0.4)
        let destinationTrack = toTrack ?? trackName
        if let target = toTrack {
            _ = try selectTrack(trackName: target, trackNumber: nil, expectedProjectPath: nil)
        }
        // beat 1 explicitly: the bar converge alone leaves the beat wherever
        // the playhead last stood, and Paste lands at the playhead exactly.
        _ = try setPlayhead(barNumber: toBar, beat: 1)
        try fireKeyCommand("Paste")
        var pasted: [String: Any]?
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.4)
            let after = try regionSnapshot(trackName: destinationTrack)
            if let hit = after.first(where: { $0["start_bar"] as? Int == toBar }) {
                pasted = hit
                break
            }
        }
        guard let landed = pasted else {
            throw DemoError.verificationFailed(
                requested: "a region at bar \(toBar) on '\(destinationTrack)'",
                actual: "nothing appeared there after Paste (clipboard state uncertain)",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": move ? "moved_via_clipboard" : "copied",
            "region": selection["name"] ?? "?",
            "from": ["track": trackName, "start_bar": selection["start_bar"] ?? NSNull()],
            "to": ["track": destinationTrack, "start_bar": landed["start_bar"] ?? toBar],
            "note": "Paste lands at the playhead on the selected track."
        ]
    }

    // MARK: - Tempo write (control bar slider, rapid-fire stepwise)

    /// Sets the project tempo by converging the control bar's Tempo slider.
    /// The slider steps ±1 BPM per AXValue write regardless of the target,
    /// but accepts writes every ~8 ms, so even a doubling converges in ~1.3 s.
    func setTempo(_ target: Double) throws -> Double {
        guard target >= 5, target <= 990 else {
            throw DemoError.invalidArguments("tempo must be 5-990 BPM")
        }
        let bar = try controlBarGroup()
        guard let inner = children(of: bar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }), let slider = children(of: inner).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Tempo"
        }) else {
            throw DemoError.windowNotFound("Tempo slider in the control bar")
        }
        let goal = Double(Int(target.rounded()))
        let deadline = Date().addingTimeInterval(25)
        var lastValue = Double(stringAttribute(slider, kAXValueAttribute as String)) ?? -1
        var stuckCount = 0
        while Date() < deadline {
            guard let current = Double(stringAttribute(slider, kAXValueAttribute as String)) else {
                break
            }
            if abs(current - goal) < 0.5 { return current }
            _ = AXUIElementSetAttributeValue(
                slider, kAXValueAttribute as CFString, Int(goal) as CFNumber
            )
            usleep(8000)
            if current == lastValue {
                stuckCount += 1
                if stuckCount > 40 { break }
            } else {
                stuckCount = 0
            }
            lastValue = current
        }
        let final = Double(stringAttribute(slider, kAXValueAttribute as String)) ?? -1
        guard abs(final - goal) < 0.5 else {
            throw DemoError.verificationFailed(
                requested: "tempo \(Int(goal)) BPM",
                actual: "tempo stuck at \(final)",
                restored: false
            )
        }
        return final
    }

    // MARK: - Project lifecycle (AppleScript standard suite + template)

    /// Logic's standard AppleScript suite is partially real: documents with
    /// name/path/modified and `close saving yes/no` work; `save` is a stub
    /// (event timeout) and `make new document` creates a windowless ghost.
    /// Saving therefore goes through the Save key command, and new projects
    /// through a bundled empty template.
    private func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open documents as (name, path?, modified) via the standard suite.
    func openDocuments() -> [(name: String, path: String?, modified: Bool)] {
        guard let raw = runAppleScript("""
        set out to ""
        tell application "Logic Pro"
            repeat with d in documents
                try
                    set p to path of d
                on error
                    set p to ""
                end try
                set out to out & (name of d) & "\u{1F}" & p & "\u{1F}" & (modified of d) & "\u{1E}"
            end repeat
        end tell
        return out
        """) else { return [] }
        return raw.split(separator: "\u{1E}").compactMap { entry in
            let parts = entry.components(separatedBy: "\u{1F}")
            guard parts.count == 3 else { return nil }
            return (parts[0], parts[1].isEmpty ? nil : parts[1], parts[2] == "true")
        }
    }

    /// Answers the "Create New Track" dialog's Create button.
    func answerCreateTrackDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var isPrompt = false
            var create: AXUIElement?
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 8 else { return }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains("Create New Track") { isPrompt = true }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == "Create" {
                    create = element
                }
                for child in children(of: element) { walk(child, depth + 1) }
            }
            walk(window, 0)
            if isPrompt, let button = create {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Answers Logic's "open the auto-saved version or the last saved?"
    /// recovery prompt with Saved. Returns false when not visible.
    func answerRecoveryDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var isPrompt = false
            var savedButton: AXUIElement?
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 8 else { return }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains("auto-saved") { isPrompt = true }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == "Saved" {
                    savedButton = element
                }
                for child in children(of: element) { walk(child, depth + 1) }
            }
            walk(window, 0)
            if isPrompt, let button = savedButton {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Answers Logic's "Do you want to save the changes…?" prompt.
    /// Returns false when no such prompt is visible.
    func answerSaveChangesDialog(save: Bool) -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var isPrompt = false
            var target: AXUIElement?
            let wanted = save ? "Save" : "Don’t Save"
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 8 else { return }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String)
                       .contains("save the changes") { isPrompt = true }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == wanted {
                    target = element
                }
                for child in children(of: element) { walk(child, depth + 1) }
            }
            walk(window, 0)
            if isPrompt, let button = target {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// Saves the open project via the Save key command, verified through the
    /// AppleScript modified flag and the ProjectData mtime. Refuses when the
    /// open document does not match expectedProjectPath (when given) or has
    /// no path yet.
    func saveProject(expectedProjectPath: String?) throws -> [String: Any] {
        let documents = openDocuments()
        guard documents.count == 1, let document = documents.first else {
            throw DemoError.trackNotExposed(
                requested: "exactly one open project to save",
                exposed: "open documents: \(documents.map(\.name).joined(separator: ", "))"
            )
        }
        guard let path = document.path else {
            throw DemoError.trackNotExposed(
                requested: "a project with a file path",
                exposed: "'\(document.name)' has never been saved; use logic_new_project to create pathed projects"
            )
        }
        if let expected = expectedProjectPath {
            guard normalizedPath(path) == normalizedPath(expected) else {
                throw DemoError.currentValueMismatch(expected: expected, actual: path)
            }
        }
        if !document.modified {
            return [
                "success": true, "verified": true, "state": "already_saved",
                "project": document.name, "path": path
            ]
        }
        let save = try MCUController.resolveKeyCommand(named: "Save", logic: self)
        _ = try MCUController.triggerKeyCommand(note: save.note, channel: save.channel)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let fresh = openDocuments().first, !fresh.modified {
                return [
                    "success": true, "verified": true, "state": "saved",
                    "project": document.name, "path": path,
                    "write_route": "midi_key_command_save"
                ]
            }
        }
        throw DemoError.verificationFailed(
            requested: "save of '\(document.name)'",
            actual: "the modified flag never cleared within 10 s",
            restored: false
        )
    }

    /// Opens a project (or creates one from the bundled empty template when
    /// creating). Logic runs single-project: an open modified project blocks
    /// unless the caller explicitly chose to save or discard it.
    func openProject(
        path: String, createFromTemplate: Bool, ifCurrentModified: String
    ) throws -> [String: Any] {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if createFromTemplate {
            guard target.pathExtension == "logicx" else {
                throw DemoError.invalidArguments("path must end in .logicx")
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw DemoError.invalidArguments("'\(target.path)' already exists; use logic_open_project")
            }
            guard let template = Bundle.module.url(
                forResource: "EmptyProject", withExtension: "logicx"
            ) else {
                throw DemoError.trackNotExposed(
                    requested: "the bundled empty project template",
                    exposed: "EmptyProject.logicx missing from the resource bundle"
                )
            }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: template, to: target)
        } else {
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw DemoError.trackNotExposed(
                    requested: "project at '\(target.path)'", exposed: "no such file"
                )
            }
        }
        // Single-project guard: a modified current project needs an explicit decision.
        let current = openDocuments()
        if let open = current.first, open.modified, normalizedPath(open.path ?? "") != normalizedPath(target.path) {
            switch ifCurrentModified {
            case "save", "dont_save":
                break // answered below once Logic asks
            default:
                throw DemoError.trackNotExposed(
                    requested: "opening '\(target.lastPathComponent)'",
                    exposed: "'\(open.name)' has unsaved changes; pass if_current_modified: 'save' or 'dont_save' (explicit decision required), or call logic_save_project first"
                )
            }
        }
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Logic Pro", target.path]
        try openProcess.run()
        openProcess.waitUntilExit()
        // Answer the save-changes prompt per the caller's explicit choice.
        let expectedName = target.deletingPathExtension().lastPathComponent
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if ifCurrentModified == "save" || ifCurrentModified == "dont_save" {
                _ = answerSaveChangesDialog(save: ifCurrentModified == "save")
            }
            // Auto-save recovery prompt: always prefer the canonical saved
            // version (the auto-saved one is what a crash would recover).
            _ = answerRecoveryDialog()
            let docs = openDocuments()
            if docs.contains(where: { $0.name == expectedName }) {
                return [
                    "success": true, "verified": true,
                    "state": createFromTemplate ? "created" : "opened",
                    "project": expectedName, "path": target.path,
                    "note": createFromTemplate
                        ? "Created from the bundled empty template and opened; already saved on disk."
                        : "Opened."
                ]
            }
        }
        throw DemoError.verificationFailed(
            requested: "'\(expectedName)' appearing in Logic's document list",
            actual: "not there within 30 s (a dialog may need attention)",
            restored: false
        )
    }

    /// Closes the open project. `saving` must be an explicit 'yes' or 'no'.
    func closeProject(saving: String, expectedProjectPath: String?) throws -> [String: Any] {
        guard saving == "yes" || saving == "no" else {
            throw DemoError.invalidArguments("saving must be 'yes' or 'no' (explicit decision)")
        }
        let documents = openDocuments()
        guard documents.count == 1, let document = documents.first else {
            throw DemoError.trackNotExposed(
                requested: "exactly one open project",
                exposed: "open documents: \(documents.map(\.name).joined(separator: ", "))"
            )
        }
        if let expected = expectedProjectPath, let path = document.path {
            guard normalizedPath(path) == normalizedPath(expected) else {
                throw DemoError.currentValueMismatch(expected: expected, actual: path)
            }
        }
        guard runAppleScript(
            "tell application \"Logic Pro\" to close document \"\(document.name)\" saving \(saving)"
        ) != nil else {
            throw DemoError.writeFailed("AppleScript close failed")
        }
        Thread.sleep(forTimeInterval: 1.0)
        let remaining = openDocuments()
        return [
            "success": true,
            "verified": !remaining.contains(where: { $0.name == document.name }),
            "state": "closed",
            "project": document.name,
            "saved": saving == "yes",
            "remaining_documents": remaining.map(\.name)
        ]
    }

    // MARK: - Key command learning (Key Commands window automation)

    /// Finds or opens the Key Commands window. NEVER walk its full row tree
    /// (~1400 rows times out) — always filter through the search field.
    private func keyCommandsWindow() throws -> AXUIElement {
        func existing() throws -> AXUIElement? {
            try logicWindows().first {
                stringAttribute($0, kAXTitleAttribute as String).contains("Key Command")
            }
        }
        if let window = try existing() { return window }
        try pressMenuItem(containing: "Edit", underMenu: "Key Commands")
        Thread.sleep(forTimeInterval: 1.5)
        guard let window = try existing() else {
            throw DemoError.windowNotFound("Key Commands window after menu press")
        }
        return window
    }

    private func closeKeyCommandsWindow() {
        guard let window = try? logicWindows().first(where: {
            stringAttribute($0, kAXTitleAttribute as String).contains("Key Command")
        }), let close = attribute(window, kAXCloseButtonAttribute as String) else { return }
        _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
    }

    /// Learns MIDI-note assignments for the given commands via the Key
    /// Commands window (search → select row → Learn New Assignment → note on
    /// the Commands port → verify "Note N" in the row). Handles collision
    /// alerts by retrying with alternate notes. Writes successes into the
    /// registry. This MODIFIES the user's active key command set — additive
    /// only, removable via the same window's Delete Assignment.
    func setupKeyCommands(
        _ targets: [(search: String, name: String, preferredNote: Int)]
    ) throws -> [[String: Any]] {
        let window = try keyCommandsWindow()
        defer { closeKeyCommandsWindow() }
        guard let search = children(of: window).first(where: { field in
            stringAttribute(field, kAXRoleAttribute as String) == "AXTextField"
                && children(of: field).contains {
                    stringAttribute($0, kAXDescriptionAttribute as String) == "search"
                }
        }) else { throw DemoError.windowNotFound("Key Commands search field") }

        func findOutline(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXOutline" || role == "AXTable" { return element }
            for child in children(of: element) {
                if let found = findOutline(child, depth + 1) { return found }
            }
            return nil
        }
        func rowTexts(_ row: AXUIElement) -> [String] {
            var texts: [String] = []
            func collect(_ element: AXUIElement, _ depth: Int) {
                guard depth < 4 else { return }
                if stringAttribute(element, kAXRoleAttribute as String) == "AXStaticText" {
                    let value = stringAttribute(element, kAXValueAttribute as String)
                    if !value.isEmpty { texts.append(value) }
                }
                for child in children(of: element) { collect(child, depth + 1) }
            }
            collect(row, 0)
            return texts
        }
        func findIn(_ root: AXUIElement, _ depth: Int,
                    _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
            guard depth < 8 else { return nil }
            if predicate(root) { return root }
            let role = stringAttribute(root, kAXRoleAttribute as String)
            if role == "AXOutline" || role == "AXTable" { return nil }
            for child in children(of: root) {
                if let found = findIn(child, depth + 1, predicate) { return found }
            }
            return nil
        }
        func dismissConflictAlert() -> Bool {
            guard let windows = try? logicWindows() else { return false }
            for candidate in windows {
                var isConflict = false
                var cancel: AXUIElement?
                func walk(_ element: AXUIElement, _ depth: Int) {
                    guard depth < 7 else { return }
                    let role = stringAttribute(element, kAXRoleAttribute as String)
                    if role == "AXStaticText",
                       stringAttribute(element, kAXValueAttribute as String)
                           .contains("already assigned") { isConflict = true }
                    if role == "AXButton",
                       stringAttribute(element, kAXTitleAttribute as String) == "Cancel" {
                        cancel = element
                    }
                    for child in children(of: element) { walk(child, depth + 1) }
                }
                walk(candidate, 0)
                if isConflict, let button = cancel {
                    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.5)
                    return true
                }
            }
            return false
        }
        func rowMatching(_ name: String) -> AXUIElement? {
            guard let outline = findOutline(window, 0) else { return nil }
            for row in children(of: outline)
            where stringAttribute(row, kAXRoleAttribute as String) == "AXRow" {
                if let first = rowTexts(row).first,
                   first.trimmingCharacters(in: CharacterSet(charactersIn: " *")) == name {
                    return row
                }
            }
            return nil
        }

        var results: [[String: Any]] = []
        for target in targets {
            _ = AXUIElementSetAttributeValue(
                search, kAXValueAttribute as CFString, target.search as CFString
            )
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
            Thread.sleep(forTimeInterval: 1.0)
            guard let row = rowMatching(target.name) else {
                results.append([
                    "name": target.name, "status": "not_found",
                    "note": "no Key Commands row matches; localized Logic UI or renamed command?"
                ])
                continue
            }
            let pre = rowTexts(row).joined(separator: " ")
            if pre.contains("Note \(target.preferredNote)") {
                results.append(["name": target.name, "status": "already_learned",
                                "midi_note": target.preferredNote])
                KeyCommandRegistry.register(
                    note: target.preferredNote, channel: 16, name: target.name,
                    notes: "verified present in the Key Commands window"
                )
                continue
            }
            _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.5)
            guard let learn = findIn(window, 0, {
                stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                    && stringAttribute($0, kAXTitleAttribute as String) == "Learn New Assignment"
            }) else {
                results.append(["name": target.name, "status": "no_learn_checkbox"])
                continue
            }
            var learned: Int?
            for candidate in [target.preferredNote, target.preferredNote + 20,
                              (target.preferredNote + 40) % 128] {
                if stringAttribute(learn, kAXValueAttribute as String) != "1" {
                    _ = AXUIElementPerformAction(learn, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                _ = try? MCUBridge.send(["cmd": "keycmd", "note": candidate, "channel": 16])
                Thread.sleep(forTimeInterval: 1.0)
                if dismissConflictAlert() { continue } // collision: next candidate
                var verified = false
                for _ in 0..<4 {
                    if let fresh = rowMatching(target.name),
                       rowTexts(fresh).joined(separator: " ").contains("Note \(candidate)") {
                        verified = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if verified { learned = candidate; break }
            }
            if let note = learned {
                KeyCommandRegistry.register(
                    note: note, channel: 16, name: target.name,
                    notes: "learned automatically by logic_setup_key_commands"
                )
                results.append(["name": target.name, "status": "learned", "midi_note": note])
            } else {
                results.append(["name": target.name, "status": "failed",
                                "note": "all candidate notes collided or verification failed"])
            }
            if stringAttribute(learn, kAXValueAttribute as String) == "1" {
                _ = AXUIElementPerformAction(learn, kAXPressAction as CFString)
            }
        }
        _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, "" as CFString)
        _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
        return results
    }

    // MARK: - Freeze state (track header checkbox + confirm dialog)

    /// Reads the track header's Freeze checkbox: true = frozen, false = not,
    /// nil = state not readable (header scrolled out or freeze column hidden).
    func trackFreezeState(trackName: String) -> Bool? {
        guard let headers = try? parsedTrackHeaders(),
              let header = headers.first(where: {
                  $0.name.caseInsensitiveCompare(trackName) == .orderedSame
              }) else { return nil }
        var freezeBox: AXUIElement?
        func findFreeze(_ element: AXUIElement, _ depth: Int) {
            guard depth < 4, freezeBox == nil else { return }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox",
               stringAttribute(element, kAXDescriptionAttribute as String) == "Freeze" {
                freezeBox = element
                return
            }
            for child in children(of: element) { findFreeze(child, depth + 1) }
        }
        findFreeze(header.item, 0)
        guard let box = freezeBox else { return nil }
        return stringAttribute(box, kAXValueAttribute as String) == "1"
    }

    /// Answers Logic's "Track X is frozen. Do you want to unfreeze it?"
    /// confirmation with Unfreeze. Returns false when no such dialog is up.
    func answerFreezeDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var hasFrozenText = false
            var unfreezeButton: AXUIElement?
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 8 else { return }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String).contains("frozen") {
                    hasFrozenText = true
                }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == "Unfreeze" {
                    unfreezeButton = element
                }
                for child in children(of: element) { walk(child, depth + 1) }
            }
            walk(window, 0)
            if hasFrozenText, let button = unfreezeButton {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    // MARK: - Track headers and selection

    private struct TrackHeader {
        let item: AXUIElement
        let number: Int
        let name: String
        let selected: Bool
        let disclosure: AXUIElement?
        let expanded: Bool?
    }

    private func parsedTrackHeaders() throws -> [TrackHeader] {
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

    private func resolveTrack(
        _ headers: [TrackHeader],
        name: String,
        number: Int?
    ) throws -> TrackHeader {
        if let number = number {
            guard let byNumber = headers.first(where: { $0.number == number }) else {
                throw DemoError.trackNotFound(
                    "track \(number)",
                    available: headers.map { "\($0.number): \($0.name)" }
                )
            }
            guard byNumber.name == name else {
                throw DemoError.trackMismatch(number: number, expected: name, actual: byNumber.name)
            }
            return byNumber
        }
        let matches = headers.filter { $0.name == name }
        guard !matches.isEmpty else {
            throw DemoError.trackNotFound(
                name,
                available: headers.map { "\($0.number): \($0.name)" }
            )
        }
        guard matches.count == 1, let match = matches.first else {
            throw DemoError.trackAmbiguous(name, numbers: matches.map(\.number))
        }
        return match
    }

    private func verifyProjectPath(_ expected: String?) throws {
        guard let expected = expected else { return }
        let actual = try projectDocumentPath()
        guard normalizedPath(expected) == normalizedPath(actual) else {
            throw DemoError.projectMismatch(expected: expected, actual: actual)
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
                throw DemoError.writeFailed(
                    "AXSelectedChildren returned AXError \(setStatus.rawValue) and no Has Focus button was found"
                )
            }
            let pressStatus = AXUIElementPerformAction(focusButton, kAXPressAction as CFString)
            guard pressStatus == .success else {
                throw DemoError.writeFailed("AXPress on Has Focus returned AXError \(pressStatus.rawValue)")
            }
            guard pollTrackSelected(target.item, name: target.name) else {
                let restored = restoreSelection(previous?.item, in: group)
                let actual = currentSelectionDescription()
                throw DemoError.selectionFailed(requested: target.name, actual: actual, restored: restored)
            }
        }

        return selectionResult(
            state: "selected",
            target: target,
            previous: previousDescription,
            writeRoute: writeRoute
        )
    }

    private func pollTrackSelected(_ item: AXUIElement, name: String) -> Bool {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if trackSelectionVerified(item, name: name) {
                return true
            }
        }
        return false
    }

    private func trackSelectionVerified(_ item: AXUIElement, name: String) -> Bool {
        guard stringAttribute(item, kAXSelectedAttribute as String) == "1" else {
            return false
        }
        // Independent readback: the left inspector strip must show the same track.
        return (try? inspectorStrip(named: name)) != nil
    }

    private func restoreSelection(_ previousItem: AXUIElement?, in group: AXUIElement) -> Bool {
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

    private func currentSelectionDescription() -> String {
        guard let items = try? trackHeaderItems() else { return "unknown" }
        let selected = items.filter { stringAttribute($0, kAXSelectedAttribute as String) == "1" }
        guard !selected.isEmpty else { return "none" }
        return selected
            .map { stringAttribute($0, kAXDescriptionAttribute as String) }
            .joined(separator: ", ")
    }

    private func selectionResult(
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

    // MARK: - Transport

    func getTransport() throws -> [String: Any] {
        let bar = try controlBarGroup()
        var result: [String: Any] = [
            "project_document": (try? projectDocumentPath()) ?? NSNull()
        ]
        let checkboxes = [
            ("playing", "Play"), ("recording", "Record"), ("cycle", "Cycle"),
            ("metronome", "Metronome Click"), ("count_in", "Count In"), ("solo_mode", "Solo")
        ]
        for (key, description) in checkboxes {
            result[key] = controlBarChild(bar, description).map {
                stringAttribute($0, kAXValueAttribute as String) == "1"
            } ?? NSNull()
        }
        if result["cycle"] is NSNull, let rulerCycle = cycleStateFromRuler() {
            // Narrow windows collapse the Cycle button; the ruler still knows.
            result["cycle"] = rulerCycle
            result["cycle_source"] = "ruler_cycle_region"
        }
        if let lcd = playheadGroup(in: bar) {
            result["playhead_bar"] = sliderValue(lcd, "bar") ?? NSNull()
            result["playhead_beat"] = sliderValue(lcd, "beat") ?? NSNull()
        }
        if let inner = children(of: bar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }) {
            result["tempo"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Tempo" }
                .flatMap { Double(stringAttribute($0, kAXValueAttribute as String)) } ?? NSNull()
            result["time_signature"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Time Signature" }
                .map { stringAttribute($0, kAXValueAttribute as String) } ?? NSNull()
            result["key_signature"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Key Signature" }
                .map { stringAttribute($0, kAXValueAttribute as String) } ?? NSNull()
        }
        return result
    }

    func setCycle(enabled: Bool) throws -> [String: Any] {
        if controlBarChild(try controlBarGroup(), "Cycle") != nil {
            return try setTransportCheckbox(
                description: "Cycle",
                key: "cycle",
                desired: enabled,
                onState: "cycle_on",
                offState: "cycle_off"
            )
        }
        // Narrow windows collapse the Cycle button out of the control bar;
        // fall back to the C key command, verified via the ruler's cycle region.
        guard let current = cycleStateFromRuler() else {
            throw DemoError.windowNotFound("Cycle button in the control bar and cycle region in the ruler")
        }
        if current == enabled {
            return [
                "success": true,
                "verified": true,
                "state": "already_" + (enabled ? "cycle_on" : "cycle_off"),
                "cycle": enabled
            ]
        }
        try sendKeystrokeToFrontmostLogic(virtualKey: 8, label: "C (cycle)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if cycleStateFromRuler() == enabled {
                return [
                    "success": true,
                    "verified": true,
                    "state": enabled ? "cycle_on" : "cycle_off",
                    "cycle": enabled,
                    "write_route": "key_command_c_frontmost",
                    "readback_route": "ruler_cycle_region"
                ]
            }
        }
        throw DemoError.verificationFailed(requested: "cycle=\(enabled)", actual: "cycle=\(current)", restored: false)
    }

    private func cycleStateFromRuler() -> Bool? {
        guard let ruler = try? rulerArea(),
              let region = rulerChild(ruler, "cycle region") else { return nil }
        switch stringAttribute(region, kAXValueDescriptionAttribute as String)
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    func setPlaying(playing: Bool) throws -> [String: Any] {
        if playing {
            // Pressing the Play checkbox starts playback, but pressing it again
            // does NOT stop (verified 2026-08-24), so only the start path uses it.
            return try setTransportCheckbox(
                description: "Play",
                key: "playing",
                desired: true,
                onState: "playing",
                offState: "stopped"
            )
        }

        let bar = try controlBarGroup()
        guard let play = controlBarChild(bar, "Play") else {
            throw DemoError.windowNotFound("Play button in the control bar")
        }
        guard stringAttribute(play, kAXValueAttribute as String) == "1" else {
            return [
                "success": true,
                "verified": true,
                "state": "already_stopped",
                "playing": false
            ]
        }

        // Stop has no control bar button in this layout and no plain menu item;
        // the working route is the space key command, sent only after verifying
        // that Logic is the frontmost application.
        try sendKeystrokeToFrontmostLogic(virtualKey: 49, label: "space (play/stop)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if let refreshed = controlBarChild(try controlBarGroup(), "Play"),
               stringAttribute(refreshed, kAXValueAttribute as String) == "0" {
                return [
                    "success": true,
                    "verified": true,
                    "state": "stopped",
                    "playing": false,
                    "write_route": "key_command_space_frontmost"
                ]
            }
        }
        throw DemoError.verificationFailed(requested: "playing=false", actual: "playing=true", restored: false)
    }

    private func sendKeystrokeToFrontmostLogic(virtualKey: CGKeyCode, label: String) throws {
        try ensureLogicFrontmost(for: label)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw DemoError.writeFailed("could not create keyboard events for \(label)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
    }

    func setPlayhead(barNumber: Int, beat: Int?) throws -> [String: Any] {
        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar) else {
            throw DemoError.windowNotFound("Playhead Position display in the control bar")
        }
        let beforeBar = sliderValue(lcd, "bar")
        let beforeBeat = sliderValue(lcd, "beat")

        try convergeSlider(in: controlBar, sliderName: "bar", target: barNumber)
        if let beat = beat {
            try convergeSlider(in: controlBar, sliderName: "beat", target: beat)
        }

        guard let refreshed = playheadGroup(in: try controlBarGroup()),
              let afterBar = sliderValue(refreshed, "bar"),
              afterBar == barNumber,
              beat == nil || sliderValue(refreshed, "beat") == beat else {
            throw DemoError.verificationFailed(
                requested: "bar \(barNumber)\(beat.map { ", beat \($0)" } ?? "")",
                actual: "bar \(sliderValue(lcd, "bar").map(String.init) ?? "?"), beat \(sliderValue(lcd, "beat").map(String.init) ?? "?")",
                restored: false
            )
        }

        return [
            "success": true,
            "verified": true,
            "state": "moved",
            "before": ["bar": beforeBar ?? -1, "beat": beforeBeat ?? -1],
            "after": ["bar": barNumber, "beat": beat ?? sliderValue(refreshed, "beat") ?? -1],
            "write_route": "ax_value_stepwise"
        ]
    }

    private func setTransportCheckbox(
        description: String,
        key: String,
        desired: Bool,
        onState: String,
        offState: String
    ) throws -> [String: Any] {
        let bar = try controlBarGroup()
        guard let checkbox = controlBarChild(bar, description) else {
            throw DemoError.windowNotFound("\(description) button in the control bar")
        }
        let current = stringAttribute(checkbox, kAXValueAttribute as String) == "1"
        if current == desired {
            return [
                "success": true,
                "verified": true,
                "state": "already_" + (desired ? onState : offState),
                key: desired
            ]
        }
        let status = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        guard status == .success else {
            throw DemoError.writeFailed("AXPress on \(description) returned AXError \(status.rawValue)")
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let refreshed = controlBarChild(try controlBarGroup(), description) else { continue }
            if (stringAttribute(refreshed, kAXValueAttribute as String) == "1") == desired {
                return [
                    "success": true,
                    "verified": true,
                    "state": desired ? onState : offState,
                    key: desired,
                    "write_route": "ax_press"
                ]
            }
        }
        throw DemoError.verificationFailed(
            requested: "\(description)=\(desired)",
            actual: "\(description)=\(current)",
            restored: false
        )
    }

    /// Logic's LCD sliders move exactly one step toward the requested value per
    /// AXValue write (verified 2026-08-24), so write repeatedly until convergence.
    private func convergeSlider(in controlBar: AXUIElement, sliderName: String, target: Int) throws {
        guard let lcd = playheadGroup(in: controlBar),
              let slider = children(of: lcd).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == sliderName
              }),
              let start = Int(stringAttribute(slider, kAXValueAttribute as String)) else {
            throw DemoError.windowNotFound("playhead \(sliderName) slider")
        }
        let maximumSteps = min(abs(target - start) + 4, 512)
        var last = start
        for _ in 0..<maximumSteps {
            guard let current = Int(stringAttribute(slider, kAXValueAttribute as String)) else { break }
            if current == target { return }
            let status = AXUIElementSetAttributeValue(
                slider,
                kAXValueAttribute as CFString,
                target as CFNumber
            )
            guard status == .success else {
                throw DemoError.writeFailed("AXValue write on \(sliderName) returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.12)
            let after = Int(stringAttribute(slider, kAXValueAttribute as String)) ?? current
            if after == last && after != target {
                throw DemoError.verificationFailed(
                    requested: "\(sliderName) \(target)",
                    actual: "\(sliderName) stuck at \(after)",
                    restored: false
                )
            }
            last = after
        }
        guard Int(stringAttribute(slider, kAXValueAttribute as String)) == target else {
            throw DemoError.verificationFailed(
                requested: "\(sliderName) \(target)",
                actual: "\(sliderName) \(stringAttribute(slider, kAXValueAttribute as String))",
                restored: false
            )
        }
    }

    // MARK: - Cycle range (locators)

    func setCycleRange(startBar: Int, endBar: Int, enabled: Bool?) throws -> [String: Any] {
        guard startBar >= 1, endBar > startBar else {
            throw DemoError.invalidArguments("start_bar must be >= 1 and end_bar > start_bar")
        }
        let targetLength = endBar - startBar

        let ruler = try rulerArea()
        guard let region = rulerChild(ruler, "cycle region") else {
            throw DemoError.trackNotExposed(requested: "cycle region", exposed: "no cycle region in the ruler")
        }
        let originalLength = cycleLengthBars(region)

        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar),
              let savedBar = sliderValue(lcd, "bar"),
              let savedBeat = sliderValue(lcd, "beat") else {
            throw DemoError.windowNotFound("Playhead Position display in the control bar")
        }
        defer {
            try? convergeSlider(in: controlBar, sliderName: "bar", target: savedBar)
            try? convergeSlider(in: controlBar, sliderName: "beat", target: savedBeat)
        }

        // Snapshot helper: Logic auto-scrolls the view when the playhead moves,
        // so the thumb and the region must always be read in the same instant
        // and never compared across playhead moves.
        func snapshot() throws -> (regionX: CGFloat, regionY: CGFloat, thumbX: CGFloat, slope: CGFloat, rulerFrame: CGRect) {
            let freshRuler = try rulerArea()
            guard let freshRegion = rulerChild(freshRuler, "cycle region"),
                  let thumb = rulerChild(freshRuler, "Playhead thumb") else {
                throw DemoError.windowNotFound("cycle region or playhead thumb in the ruler")
            }
            let regionFrame = try frame(of: freshRegion)
            return (
                regionX: regionFrame.origin.x,
                regionY: regionFrame.origin.y,
                thumbX: try frame(of: thumb).origin.x,
                slope: try pixelsPerBar(in: freshRuler),
                rulerFrame: try frame(of: freshRuler)
            )
        }

        // Anchor calibration: park the playhead on the region's bar line so the
        // thumb identifies which bar the (grid-snapped) region sits on, and
        // measure the constant thumb-to-bar-line pixel offset.
        let initial = try snapshot()
        let approximateBar = try approximateBarAt(x: initial.regionX, in: try rulerArea())
        var anchor: (bar: Int, thumbOffset: CGFloat, regionX: CGFloat, slope: CGFloat)?
        for candidate in [approximateBar, approximateBar - 1, approximateBar + 1] where candidate >= 1 {
            try convergeSlider(in: controlBar, sliderName: "bar", target: candidate)
            try convergeSlider(in: controlBar, sliderName: "beat", target: 1)
            Thread.sleep(forTimeInterval: 0.15)
            let snap = try snapshot()
            if abs(snap.regionX - snap.thumbX) <= snap.slope * 0.55 {
                anchor = (
                    bar: candidate,
                    thumbOffset: snap.regionX - snap.thumbX,
                    regionX: snap.regionX,
                    slope: snap.slope
                )
                break
            }
        }
        guard let anchored = anchor else {
            throw DemoError.openVerificationFailed(
                "Could not anchor the cycle region to a bar line via the playhead thumb."
            )
        }

        // Verified drag semantics in the cycle strip (2026-08-24): a drag that
        // STARTS on empty strip creates a new grid-snapped range from start to
        // end; a drag that starts inside the existing region MOVES it instead.
        // A pure AXPosition write moves the region start exactly one grid-snapped
        // bar landing. Combine them so the drag start never touches the region.
        let preDrag = try snapshot()
        let originBarX = preDrag.thumbX + anchored.thumbOffset // playhead is on the anchor bar
        func xForBar(_ bar: Int) -> CGFloat {
            originBarX + preDrag.slope * CGFloat(bar - anchored.bar)
        }
        let startX = xForBar(startBar)
        let endX = xForBar(endBar)
        guard startX >= preDrag.rulerFrame.minX, endX <= preDrag.rulerFrame.maxX else {
            throw DemoError.trackNotExposed(
                requested: "bars \(startBar)-\(endBar)",
                exposed: "the target range is outside the visible ruler; scroll or zoom Logic so it is visible"
            )
        }
        let stripY = preDrag.regionY + 10
        let writeRoute: String

        func regionFrameNow() throws -> CGRect {
            guard let current = rulerChild(try rulerArea(), "cycle region") else {
                throw DemoError.windowNotFound("cycle region in the ruler")
            }
            return try frame(of: current)
        }
        func setRegionPosition(x: CGFloat) throws {
            guard let current = rulerChild(try rulerArea(), "cycle region") else {
                throw DemoError.windowNotFound("cycle region in the ruler")
            }
            var origin = CGPoint(x: x, y: preDrag.regionY)
            guard let value = AXValueCreate(.cgPoint, &origin) else {
                throw DemoError.writeFailed("could not create the AXPosition value")
            }
            let status = AXUIElementSetAttributeValue(current, kAXPositionAttribute as CFString, value)
            guard status == .success else {
                throw DemoError.writeFailed("AXPosition write on the cycle region returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        func covers(_ frame: CGRect, _ x: CGFloat) -> Bool {
            x >= frame.minX - 3 && x <= frame.maxX + 3
        }

        if originalLength == targetLength {
            // Same length: the grid-snapped position write is enough.
            writeRoute = "ax_position_grid_snap"
            try setRegionPosition(x: startX)
        } else {
            writeRoute = "cg_drag_create"
            var dragFrom = CGPoint(x: startX, y: stripY)
            var dragTo = CGPoint(x: endX, y: stripY)
            var currentFrame = try regionFrameNow()
            if covers(currentFrame, startX) {
                if !covers(currentFrame, endX) {
                    // Drag backwards; only the start point must avoid the region.
                    swap(&dragFrom, &dragTo)
                } else {
                    // The region covers both locator targets: move it aside first.
                    try setRegionPosition(x: min(startX + preDrag.slope, preDrag.rulerFrame.maxX - 2))
                    currentFrame = try regionFrameNow()
                    guard !covers(currentFrame, startX) else {
                        throw DemoError.openVerificationFailed(
                            "Could not move the existing cycle region away from the drag start point."
                        )
                    }
                }
            }
            try dragBetween(
                from: dragFrom,
                to: dragTo,
                requireHitOn: try rulerArea(),
                label: "cycle strip of the ruler"
            )
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Semantic verification: with the playhead on the start bar, the thumb
        // (plus the measured constant offset) must line up with the region edge,
        // and the region's size description must report the requested bar count.
        try convergeSlider(in: controlBar, sliderName: "bar", target: startBar)
        try convergeSlider(in: controlBar, sliderName: "beat", target: 1)
        Thread.sleep(forTimeInterval: 0.15)
        let verifySnap = try snapshot()
        let startError = (verifySnap.regionX - verifySnap.thumbX - anchored.thumbOffset) / verifySnap.slope
        guard let resized = rulerChild(try rulerArea(), "cycle region"),
              abs(startError) <= 0.3,
              cycleLengthBars(resized) == targetLength else {
            let actualLength = rulerChild((try? rulerArea()) ?? ruler, "cycle region")
                .map { stringAttribute($0, "AXSizeDescription") } ?? "?"
            throw DemoError.verificationFailed(
                requested: "cycle bars \(startBar)-\(endBar) (\(targetLength) bars)",
                actual: "start is \(String(format: "%.2f", startError)) bars off, size is '\(actualLength)'",
                restored: false
            )
        }

        if let enabled = enabled {
            _ = try MCUController.setCycle(enabled) ?? setCycle(enabled: enabled)
        }
        let finalCycle = controlBarChild(try controlBarGroup(), "Cycle")
            .map { stringAttribute($0, kAXValueAttribute as String) == "1" }

        return [
            "success": true,
            "verified": true,
            "state": "cycle_range_set",
            "start_bar": startBar,
            "end_bar": endBar,
            "length_bars": targetLength,
            "anchor_bar": anchored.bar,
            "previous": [
                "start_bar": anchored.bar,
                "length_bars": originalLength ?? -1
            ],
            "write_route": writeRoute,
            "cycle_enabled": finalCycle ?? NSNull(),
            "verification": "playhead-thumb alignment at the start bar and AXSizeDescription reporting \(targetLength) bars"
        ]
    }

    private func rulerArea() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        var ruler: AXUIElement?
        collect(from: mainWindow, maximumDepth: 10) { element in
            guard ruler == nil,
                  stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea",
                  stringAttribute(element, kAXDescriptionAttribute as String) == "Tracks time ruler" else { return }
            ruler = element
        }
        guard let area = ruler else {
            throw DemoError.windowNotFound("Tracks time ruler")
        }
        return area
    }

    private func rulerChild(_ ruler: AXUIElement, _ description: String) -> AXUIElement? {
        children(of: ruler).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }
    }

    private func frame(of element: AXUIElement) throws -> CGRect {
        guard let value = attribute(element, "AXFrame") else {
            throw DemoError.writeFailed("could not read an element frame")
        }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else {
            throw DemoError.writeFailed("could not decode an element frame")
        }
        return rect
    }

    /// Pixels per bar, from the ruler's project Start/End markers whose
    /// AXValueDescription names their bar ("1 bar ", "82 bars ").
    private func pixelsPerBar(in ruler: AXUIElement) throws -> CGFloat {
        guard let start = rulerChild(ruler, "Start Marker"),
              let end = rulerChild(ruler, "End Marker"),
              let startBar = leadingInt(stringAttribute(start, kAXValueDescriptionAttribute as String)),
              let endBar = leadingInt(stringAttribute(end, kAXValueDescriptionAttribute as String)),
              endBar > startBar else {
            throw DemoError.windowNotFound("Start/End markers in the ruler")
        }
        let startX = try frame(of: start).origin.x
        let endX = try frame(of: end).origin.x
        let slope = (endX - startX) / CGFloat(endBar - startBar)
        guard slope > 1 else {
            throw DemoError.openVerificationFailed("Ruler scale too small (\(slope) px/bar); zoom in horizontally.")
        }
        return slope
    }

    private func approximateBarAt(x: CGFloat, in ruler: AXUIElement) throws -> Int {
        guard let start = rulerChild(ruler, "Start Marker"),
              let startBar = leadingInt(stringAttribute(start, kAXValueDescriptionAttribute as String)) else {
            throw DemoError.windowNotFound("Start marker in the ruler")
        }
        let startX = try frame(of: start).origin.x
        let slope = try pixelsPerBar(in: ruler)
        return max(1, Int((CGFloat(startBar) + (x - startX) / slope).rounded()))
    }

    private func cycleLengthBars(_ region: AXUIElement) -> Int? {
        let description = stringAttribute(region, "AXSizeDescription")
        guard let bars = leadingInt(description),
              description.range(of: "beat", options: .caseInsensitive) == nil,
              description.range(of: "division", options: .caseInsensitive) == nil else {
            return nil
        }
        return bars
    }

    private func leadingInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    private func restoreRegionPosition(to x: CGFloat, y: CGFloat) {
        guard let ruler = try? rulerArea(),
              let region = rulerChild(ruler, "cycle region") else { return }
        var origin = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        _ = AXUIElementSetAttributeValue(region, kAXPositionAttribute as CFString, value)
    }

    private func dragBetween(
        from: CGPoint,
        to: CGPoint,
        requireHitOn target: AXUIElement,
        label: String
    ) throws {
        try ensureLogicFrontmost(for: label)
        // Floating plugin windows can cover the target; raise the project window
        // so screen-position hit tests and drags reach it.
        if let projectWindow = try? projectWindow() {
            _ = AXUIElementPerformAction(projectWindow, "AXRaise" as CFString)
            Thread.sleep(forTimeInterval: 0.2)
        }
        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(from.x),
            Float(from.y),
            &hit
        )
        guard hitStatus == .success, let hitElement = hit, elementCoversTarget(hitElement, target: target) else {
            let hitDescription = hit.map {
                stringAttribute($0, kAXRoleAttribute as String) + " '"
                    + stringAttribute($0, kAXDescriptionAttribute as String) + "'"
            } ?? "nothing"
            throw DemoError.writeFailed(
                "hit test at the \(label) resolved to \(hitDescription); refusing to drag. Another window may cover the ruler."
            )
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let previousLocation = CGEvent(source: nil)?.location
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else {
            throw DemoError.writeFailed("could not create mouse events for \(label)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        let steps = 12
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress
            )
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.08)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        if let restore = previousLocation {
            Thread.sleep(forTimeInterval: 0.05)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: restore, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private func ensureLogicFrontmost(for label: String) throws {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            throw DemoError.logicNotRunning
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        func frontmost() -> Bool {
            stringAttribute(appElement, "AXFrontmost") == "1"
        }
        if !frontmost() {
            application.activate()
            for _ in 0..<10 where !frontmost() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if !frontmost() {
            // macOS can deny cooperative activation while the user is active in
            // another app; the accessibility route is more forceful.
            AXUIElementSetAttributeValue(
                AXUIElementCreateSystemWide(),
                "AXFocusedApplication" as CFString,
                appElement
            )
            for _ in 0..<10 where !frontmost() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard frontmost() else {
            throw DemoError.writeFailed("Logic could not be brought frontmost; refusing to interact with \(label)")
        }
    }

    private func controlBarGroup() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        var bar: AXUIElement?
        collect(from: mainWindow, maximumDepth: 6) { element in
            guard bar == nil,
                  stringAttribute(element, kAXRoleAttribute as String) == "AXGroup",
                  stringAttribute(element, kAXDescriptionAttribute as String) == "Control Bar",
                  stringAttribute(element, kAXHelpAttribute as String).hasPrefix("Control bar") else { return }
            bar = element
        }
        guard let group = bar else {
            throw DemoError.windowNotFound("Control Bar group")
        }
        return group
    }

    private func controlBarChild(_ bar: AXUIElement, _ description: String) -> AXUIElement? {
        children(of: bar).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }
    }

    private func playheadGroup(in controlBar: AXUIElement) -> AXUIElement? {
        guard let inner = children(of: controlBar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }) else { return nil }
        return children(of: inner).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Playhead Position"
        }
    }

    private func sliderValue(_ group: AXUIElement, _ description: String) -> Int? {
        children(of: group)
            .first { stringAttribute($0, kAXDescriptionAttribute as String) == description }
            .flatMap { Int(stringAttribute($0, kAXValueAttribute as String)) }
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
            throw DemoError.trackNotStack(target.name)
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
            throw DemoError.openVerificationFailed(
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

    private func pollStackState(trackNumber: Int, expanded: Bool, attempts: Int) -> Bool {
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
    private func clickElement(_ element: AXUIElement, describedAs label: String) throws {
        guard let frameValue = attribute(element, "AXFrame") else {
            throw DemoError.writeFailed("could not read the frame of \(label)")
        }
        var frame = CGRect.zero
        guard AXValueGetValue((frameValue as! AXValue), .cgRect, &frame), !frame.isEmpty else {
            throw DemoError.writeFailed("could not decode the frame of \(label)")
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
            throw DemoError.writeFailed(
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
            throw DemoError.writeFailed("could not create mouse events for \(label)")
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

    private func elementCoversTarget(_ hit: AXUIElement, target: AXUIElement) -> Bool {
        var current: AXUIElement? = hit
        for _ in 0..<4 {
            guard let element = current else { return false }
            if CFEqual(element, target) {
                return true
            }
            current = attribute(element, kAXParentAttribute as String).map { ($0 as! AXUIElement) }
        }
        return false
    }

    // MARK: - Strip controls (mute/solo/volume/pan)

    private func selectedStripChild(
        trackName: String,
        trackNumber: Int?,
        description: String
    ) throws -> AXUIElement {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        guard let control = children(of: strip).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }) else {
            throw DemoError.trackNotExposed(
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
            throw DemoError.writeFailed("AXPress on \(control) returned AXError \(status.rawValue)")
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
        throw DemoError.verificationFailed(
            requested: "\(control)=\(enabled)", actual: "\(control)=\(current)", restored: false
        )
    }

    private func decibelValue(of element: AXUIElement) -> Double? {
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
            throw DemoError.valueNotWritable("the volume fader exposes no readable dB value")
        }
        guard let minRaw = Int(stringAttribute(fader, kAXMinValueAttribute as String)),
              let maxRaw = Int(stringAttribute(fader, kAXMaxValueAttribute as String)) else {
            throw DemoError.valueNotWritable("the volume fader exposes no raw range")
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
                throw DemoError.writeFailed("AXValue write on the volume fader returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard abs(achievedDb - targetDb) <= max(toleranceDb, 0.25) else {
            throw DemoError.verificationFailed(
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
            throw DemoError.invalidArguments("pan position must be within the knob's range")
        }
        let before = Int(stringAttribute(knob, kAXValueAttribute as String)) ?? 0
        var last = before
        for _ in 0..<(maxRaw - minRaw + 8) {
            guard let current = Int(stringAttribute(knob, kAXValueAttribute as String)) else { break }
            if current == position { break }
            let status = AXUIElementSetAttributeValue(knob, kAXValueAttribute as CFString, position as CFNumber)
            guard status == .success else {
                throw DemoError.writeFailed("AXValue write on the pan knob returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.03)
            let after = Int(stringAttribute(knob, kAXValueAttribute as String)) ?? current
            if after == last && after != position {
                throw DemoError.verificationFailed(
                    requested: "pan \(position)", actual: "stuck at \(after)", restored: false
                )
            }
            last = after
        }
        guard Int(stringAttribute(knob, kAXValueAttribute as String)) == position else {
            throw DemoError.verificationFailed(
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

    // MARK: - Plugin insertion and removal

    /// Popup menus that are not part of the menu bar (e.g. the insert slot's
    /// plugin chooser). Logic's press action reports an error even though the
    /// menu opens, so presence is verified by finding the menu itself.
    private func popupMenus() -> [AXUIElement] {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menus: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXMenuBar" { return }
            if role == "AXMenu" { menus.append(element); return }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(appElement, depth: 0)
        return menus
    }

    private func pluginChooserMenu() -> AXUIElement? {
        popupMenus().first { menu in
            children(of: menu).contains {
                stringAttribute($0, kAXTitleAttribute as String) == "Audio Units"
            } || children(of: menu).contains {
                stringAttribute($0, kAXTitleAttribute as String) == "No Plug-in"
            }
        }
    }

    private func dismissPopupMenus() {
        for menu in popupMenus() {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    private func findMenuItem(
        in menu: AXUIElement,
        titled title: String,
        maximumDepth: Int = 5
    ) -> AXUIElement? {
        var result: AXUIElement?
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < maximumDepth, result == nil else { return }
            for item in children(of: element) {
                let role = stringAttribute(item, kAXRoleAttribute as String)
                if role == "AXMenuItem",
                   stringAttribute(item, kAXTitleAttribute as String)
                       .localizedCaseInsensitiveCompare(title) == .orderedSame {
                    result = item
                    return
                }
                walk(item, depth: depth + 1)
            }
        }
        walk(menu, depth: 0)
        return result
    }

    @discardableResult
    private func chooseFromPluginMenu(pluginName: String, format: String) throws -> String {
        var menu: AXUIElement?
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if let found = pluginChooserMenu() { menu = found; break }
        }
        guard let chooser = menu else {
            throw DemoError.openVerificationFailed("the plugin chooser menu did not open")
        }
        guard let item = findMenuItem(in: chooser, titled: pluginName) else {
            dismissPopupMenus()
            let topLevel = children(of: chooser)
                .map { stringAttribute($0, kAXTitleAttribute as String) }
                .filter { !$0.isEmpty }
            throw DemoError.insertNotFound(track: "plugin menu", plugin: pluginName, available: topLevel)
        }
        // Plugins with channel-format submenus need a leaf item chosen; take
        // the requested format when offered, otherwise whatever the channel
        // supports (a mono track only offers "Mono").
        var target = item
        var chosenFormat = ""
        if let submenu = children(of: item).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
        }) {
            let options = children(of: submenu).filter {
                !stringAttribute($0, kAXTitleAttribute as String).isEmpty
            }
            if let requested = options.first(where: {
                stringAttribute($0, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveCompare(format) == .orderedSame
            }) {
                target = requested
            } else if let fallback = options.first {
                target = fallback
            }
            chosenFormat = stringAttribute(target, kAXTitleAttribute as String)
        }
        // AXPress on items inside closed submenus is a silent no-op in Logic's
        // custom chooser (verified 2026-08-25); drive the menu like a mouse
        // user instead: hover each ancestor open, then click the final item.
        do {
            try navigateMenu(chooser, along: titlePath(to: target, within: chooser))
        } catch {
            dismissPopupMenus()
            throw error
        }
        return chosenFormat
    }

    private func titlePath(to item: AXUIElement, within chooser: AXUIElement) -> [String] {
        var titles: [String] = []
        var current: AXUIElement? = item
        for _ in 0..<12 {
            guard let element = current else { break }
            if CFEqual(element, chooser) { break }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" {
                titles.append(stringAttribute(element, kAXTitleAttribute as String))
            }
            current = attribute(element, kAXParentAttribute as String).map { ($0 as! AXUIElement) }
        }
        return titles.reversed()
    }

    private func navigateMenu(_ chooser: AXUIElement, along titles: [String]) throws {
        guard !titles.isEmpty else {
            throw DemoError.openVerificationFailed("empty menu path")
        }
        // Logic must already be frontmost here: activating it now would
        // dismiss the open menu (verified 2026-08-25).
        let source = CGEventSource(stateID: .hidSystemState)
        let previousLocation = CGEvent(source: nil)?.location
        var menu = chooser
        for (index, title) in titles.enumerated() {
            guard let item = children(of: menu).first(where: {
                stringAttribute($0, kAXTitleAttribute as String)
                    .localizedCaseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw DemoError.openVerificationFailed("menu item '\(title)' vanished during navigation")
            }
            let itemFrame = try frame(of: item)
            let point = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.35)
            if index == titles.count - 1 {
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            } else {
                guard let submenu = children(of: item).first(where: {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
                }) else {
                    throw DemoError.openVerificationFailed("submenu under '\(title)' did not open")
                }
                menu = submenu
            }
        }
        if let restore = previousLocation {
            Thread.sleep(forTimeInterval: 0.05)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: restore, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func addPlugin(
        trackName: String,
        trackNumber: Int?,
        pluginName: String,
        format: String
    ) throws -> [String: Any] {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        let before = insertSlots(of: strip)
        let bars = children(of: strip).filter {
            stringAttribute($0, kAXDescriptionAttribute as String) == "insert bar"
        }
        // A pristine strip (no inserts yet) renders no "insert bar" elements;
        // its first empty slot is the "audio plug-in" button instead.
        let pristineSlot = children(of: strip).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == "audio plug-in"
        }
        guard let appendSlot = bars.last ?? pristineSlot else {
            throw DemoError.trackNotExposed(
                requested: "an empty insert slot on '\(trackName)'",
                exposed: "neither an insert bar nor the audio plug-in button was found in the strip"
            )
        }
        let windowsBefore = Set(try logicWindows().map(WindowKey.init))
        try ensureLogicFrontmost(for: "the plugin chooser") // activating later would close the menu
        if bars.isEmpty {
            // The pristine "audio plug-in" button is AXPress-dead (like the
            // track-header controls) — a hit-test-guarded click opens it.
            try clickElement(appendSlot, describedAs: "the empty audio plug-in slot")
        } else {
            _ = AXUIElementPerformAction(appendSlot, kAXPressAction as CFString) // opens the chooser
        }
        let chosenFormat = try chooseFromPluginMenu(pluginName: pluginName, format: format)

        // The new insert lands in the first empty slot, which is not
        // necessarily last (e.g. instrument-adjacent slots follow it), so
        // diff the slot lists positionally to find the addition.
        var added: InsertSlot?
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let refreshed = try? inspectorStrip(named: trackName) else { continue }
            let slots = insertSlots(of: refreshed)
            guard slots.count == before.count + 1 else { continue }
            for (position, slot) in slots.enumerated() {
                if position >= before.count || slot.name != before[position].name {
                    if pluginNamesMatch(slot.name, pluginName) {
                        added = slot
                    }
                    break
                }
            }
            if added != nil { break }
        }
        guard let slot = added else {
            dismissPopupMenus()
            throw DemoError.openVerificationFailed(
                "no new insert matching '\(pluginName)' appeared on '\(trackName)'"
            )
        }
        let newWindow = try pollWindowDiff(before: windowsBefore, expectAppear: true)
        return [
            "success": true,
            "verified": true,
            "state": "plugin_added",
            "track": trackName,
            "plugin_display_name": slot.name,
            "insert_index": slot.index,
            "format": chosenFormat.isEmpty ? format : chosenFormat,
            "plugin_window": newWindow != nil
                ? stringAttribute(newWindow!, kAXTitleAttribute as String) : "none_opened",
            "write_route": "insert_menu_navigation",
            "note": "Logic may open the plugin window automatically; close it with logic_close_plugin if unwanted."
        ]
    }

    func removePlugin(
        trackName: String,
        trackNumber: Int?,
        pluginName: String,
        insertIndex: Int?
    ) throws -> [String: Any] {
        _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        let strip = try inspectorStrip(named: trackName)
        let before = insertSlots(of: strip)
        let slot = try resolveSlot(before, track: trackName, plugin: pluginName, index: insertIndex)
        guard let listButton = children(of: slot.group).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "list"
        }) else {
            throw DemoError.trackNotExposed(
                requested: "plugin menu button on slot \(slot.index)",
                exposed: "the insert group has no list button"
            )
        }
        try ensureLogicFrontmost(for: "the plugin chooser") // activating later would close the menu
        _ = AXUIElementPerformAction(listButton, kAXPressAction as CFString)
        try chooseFromPluginMenu(pluginName: "No Plug-in", format: "")

        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            guard let refreshed = try? inspectorStrip(named: trackName) else { continue }
            if insertSlots(of: refreshed).count == before.count - 1 {
                return [
                    "success": true,
                    "verified": true,
                    "state": "plugin_removed",
                    "track": trackName,
                    "removed_plugin": slot.name,
                    "was_insert_index": slot.index,
                    "write_route": "insert_menu_navigation"
                ]
            }
        }
        dismissPopupMenus()
        throw DemoError.openVerificationFailed(
            "the insert count on '\(trackName)' did not decrease after choosing No Plug-in"
        )
    }

    func controlCensus(windowTitle: String) throws -> [String: Int] {
        let window = try logicWindow(title: windowTitle)
        var census: [String: Int] = [:]
        let interesting: Set<String> = [
            "AXSlider", "AXTextField", "AXCheckBox", "AXButton",
            "AXPopUpButton", "AXMenuButton", "AXValueIndicator",
            "AXLayoutArea", "AXLayoutItem", "AXIncrementor", "AXImage"
        ]
        for element in descendants(of: window) {
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if interesting.contains(role) {
                census[role, default: 0] += 1
            }
        }
        return census
    }

    // MARK: - Plugin survey

    func surveyPlugins(trackName: String, trackNumber: Int?) throws -> [String: Any] {
        // Output/aux strips (e.g. "Stereo Out") live in the right inspector
        // strip and are not track headers; fall back to any strip whose name
        // matches when track selection cannot resolve the name.
        do {
            _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
        } catch let error as DemoError {
            guard case .trackNotFound = error, (try? anyInspectorStrip(named: trackName)) != nil else {
                throw error
            }
        }
        let strip = try anyInspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        var surveyed: [[String: Any]] = []
        for slot in slots {
            var entry: [String: Any] = [
                "insert_index": slot.index,
                "plugin_display_name": slot.name,
                "bypassed": slot.bypassed
            ]
            do {
                let openResult = try openPlugin(
                    trackName: trackName,
                    pluginName: slot.name,
                    insertIndex: slot.index,
                    expectedProjectPath: nil
                )
                let openedByUs = (openResult["state"] as? String) == "opened"
                Thread.sleep(forTimeInterval: 0.3)
                let parameters = (try? listParameters(windowTitle: trackName)) ?? []
                entry["accessible_parameters"] = parameters.count
                entry["parameters"] = parameters.map { parameter -> [String: Any] in
                    [
                        "name": parameter["name"] ?? "",
                        "raw_value": parameter["raw_value"] ?? "",
                        "raw_min": parameter["raw_min"] ?? "",
                        "raw_max": parameter["raw_max"] ?? "",
                        "writable": parameter["writable"] ?? false
                    ]
                }
                entry["classification"] = parameters.isEmpty
                    ? "no_semantic_sliders"
                    : (parameters.allSatisfy { ($0["writable"] as? Bool) == true }
                        ? "read_write_candidate" : "partially_writable")
                if parameters.isEmpty {
                    // Distinguish "custom canvas with nothing" from "controls
                    // exposed with other roles than the Compressor-style sliders".
                    entry["control_census"] = (try? controlCensus(windowTitle: trackName)) ?? [:]
                }
                if openedByUs {
                    _ = try? closePlugin(
                        trackName: trackName, pluginName: slot.name, insertIndex: slot.index
                    )
                }
            } catch {
                entry["classification"] = "survey_failed"
                entry["error"] = error.localizedDescription
            }
            surveyed.append(entry)
        }
        return [
            "success": true,
            "track": trackName,
            "surveyed_inserts": surveyed.count,
            "plugins": surveyed,
            "note": "classification reflects AX slider exposure only; verified write/readback per parameter still requires a live compare-and-set test"
        ]
    }

    // MARK: - Plugin window lifecycle

    func openPlugin(
        trackName: String,
        pluginName: String,
        insertIndex: Int?,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        if let expected = expectedProjectPath {
            let actual = try projectDocumentPath()
            guard normalizedPath(expected) == normalizedPath(actual) else {
                throw DemoError.projectMismatch(expected: expected, actual: actual)
            }
        }

        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        let slot = try resolveSlot(slots, track: trackName, plugin: pluginName, index: insertIndex)
        guard let openButton = slot.openButton else {
            throw DemoError.valueNotWritable("insert slot \(slot.index) (\(slot.name)) exposes no open button")
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw DemoError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        if let appeared = try pollWindowDiff(before: before, expectAppear: true) {
            let title = stringAttribute(appeared, kAXTitleAttribute as String)
            guard title == trackName else {
                _ = closeWindowElement(appeared)
                throw DemoError.openVerificationFailed(
                    "A window titled '\(title)' appeared, expected '\(trackName)'. It was closed again."
                )
            }
            return openResult(state: "opened", track: trackName, slot: slot, windowTitle: title)
        }

        if firstMissingWindow(from: before) != nil {
            // The plugin window was already open; the open button toggled it closed.
            // Press again to restore it and report the identified window.
            let beforeRestore = Set(try logicWindows().map(WindowKey.init))
            let restoreStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
            guard restoreStatus == .success,
                  let reopened = try pollWindowDiff(before: beforeRestore, expectAppear: true) else {
                throw DemoError.openVerificationFailed(
                    "The open button toggled an already-open window closed and it could not be reopened."
                )
            }
            let title = stringAttribute(reopened, kAXTitleAttribute as String)
            return openResult(state: "already_open", track: trackName, slot: slot, windowTitle: title)
        }

        throw DemoError.openVerificationFailed("No window appeared or disappeared after pressing the open button.")
    }

    func closePlugin(
        trackName: String,
        pluginName: String,
        insertIndex: Int?
    ) throws -> [String: Any] {
        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        let slot = try resolveSlot(slots, track: trackName, plugin: pluginName, index: insertIndex)
        guard let openButton = slot.openButton else {
            throw DemoError.valueNotWritable("insert slot \(slot.index) (\(slot.name)) exposes no open button")
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        let pressStatus = AXUIElementPerformAction(openButton, kAXPressAction as CFString)
        guard pressStatus == .success else {
            throw DemoError.writeFailed("AXPress on open button returned AXError \(pressStatus.rawValue)")
        }

        if try pollWindowDisappeared(before: before) {
            return [
                "success": true,
                "verified": true,
                "state": "closed",
                "track": trackName,
                "insert_index": slot.index,
                "plugin_display_name": slot.name
            ]
        }

        if let appeared = try pollWindowDiff(before: before, expectAppear: true) {
            // The plugin window was closed already; the toggle opened it. Close it again.
            _ = closeWindowElement(appeared)
            throw DemoError.pluginNotOpen(
                "the open button opened a new window, which was closed again to restore the UI"
            )
        }
        throw DemoError.openVerificationFailed("No window disappeared after pressing the open button.")
    }

    func closePluginWindow(title: String) throws -> [String: Any] {
        let windows = try logicWindows()
        let matches = windows.filter { stringAttribute($0, kAXTitleAttribute as String) == title }
        guard let window = matches.first else {
            throw DemoError.windowNotFound(title)
        }
        guard matches.count == 1 else {
            throw DemoError.windowAmbiguous(title, matches.count)
        }
        // Dialogs are plugin/auxiliary windows even when they carry the project
        // document (Drum Machine Designer does); never close standard windows.
        guard stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog" else {
            throw DemoError.windowNotClosable(title)
        }

        let before = Set(try logicWindows().map(WindowKey.init))
        guard closeWindowElement(window) else {
            throw DemoError.writeFailed("AXPress on the window close button failed")
        }
        guard try pollWindowDisappeared(before: before) else {
            throw DemoError.openVerificationFailed("The window '\(title)' did not disappear after pressing close.")
        }
        return [
            "success": true,
            "verified": true,
            "state": "closed",
            "window": title
        ]
    }

    // MARK: - Closed-loop change evaluation

    // swiftlint:disable:next function_body_length
    func evaluateChange(
        trackName: String,
        pluginName: String,
        insertIndex: Int?,
        parameter: String,
        expectedCurrentValue: String,
        targetValue: String,
        startBar: Int,
        endBar: Int,
        keepChange: Bool,
        verifyRollback: Bool,
        settleSeconds: Double,
        expectedProjectPath: String?
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)

        // Preconditions: a live sensor and a readable transport.
        let probe = SensorReader.readSensors(windowSeconds: 2)
            .filter { ($0["frames_published"] as? UInt64 ?? 0) > 0 || ($0["frames_published"] as? Int ?? 0) > 0 }
            .filter { !(($0["stale"] as? Bool) ?? true) }
        guard !probe.isEmpty else {
            throw DemoError.trackNotExposed(
                requested: "an active LogicMCPSensor instance",
                exposed: "no fresh sensor ring found; insert Audio Units > LMcp > LogicMCP: Sensor in Logic"
            )
        }
        let transport = try getTransport()
        let tempo = transport["tempo"] as? Double ?? 120
        let beatsPerBar = Double((transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
        let passSeconds = Double(endBar - startBar) * beatsPerBar * 60.0 / tempo
        let savedBar = transport["playhead_bar"] as? Int
        let savedBeat = transport["playhead_beat"] as? Int
        let savedCycle = transport["cycle"] as? Bool ?? false

        // Setup: selected track, open plugin window, loop range, playback.
        _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
        let openResult = try openPlugin(
            trackName: trackName,
            pluginName: pluginName,
            insertIndex: insertIndex,
            expectedProjectPath: nil
        )
        let openedByUs = (openResult["state"] as? String) == "opened"

        var cleanupStatus: [String: Any] = [:]
        func cleanUp() {
            var stopped = false
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.6) }
                let result = (try? MCUController.setPlaying(false) ?? setPlaying(playing: false)) ?? nil
                if (result?["state"] as? String)?.contains("stopped") == true {
                    stopped = true
                    break
                }
            }
            cleanupStatus["transport"] = stopped ? "stopped" : "STILL_PLAYING_stop_failed"
            let cycleResult = (try? MCUController.setCycle(savedCycle) ?? setCycle(enabled: savedCycle)) ?? nil
            cleanupStatus["cycle"] = cycleResult != nil ? (savedCycle ? "on" : "off") : "restore_failed"
            if let bar = savedBar {
                cleanupStatus["playhead"] = (try? setPlayhead(barNumber: bar, beat: savedBeat)) != nil
                    ? "bar \(bar)" : "restore_failed"
            }
            if openedByUs {
                cleanupStatus["plugin_window"] = (try? closePlugin(
                    trackName: trackName, pluginName: pluginName, insertIndex: insertIndex
                )) != nil ? "closed" : "close_failed"
            } else {
                cleanupStatus["plugin_window"] = "left_as_found"
            }
        }

        do {
            _ = try setCycleRange(startBar: startBar, endBar: endBar, enabled: true)
            _ = try setPlayhead(barNumber: startBar, beat: 1)
            _ = try MCUController.setPlaying(true) ?? setPlaying(playing: true)

            // Baseline over one full loop pass.
            Thread.sleep(forTimeInterval: passSeconds + settleSeconds)
            let baseline = try measurementWindows(passSeconds: passSeconds, label: "baseline")

            // Apply exactly one bounded, verified change while the loop plays.
            let change = try setParameter(
                windowTitle: trackName,
                parameterName: parameter,
                expectedCurrentValue: expectedCurrentValue,
                targetValue: targetValue
            )

            // After-window: every sample after the (persistent) change is
            // post-change, and any window of exactly one pass length covers the
            // same musical material once, so no loop-phase alignment is needed.
            Thread.sleep(forTimeInterval: passSeconds + settleSeconds)
            let after = try measurementWindows(passSeconds: passSeconds, label: "after")

            var decision = "kept"
            var control: [[String: Any]]?
            if !keepChange {
                _ = try setParameter(
                    windowTitle: trackName,
                    parameterName: parameter,
                    expectedCurrentValue: targetValue,
                    targetValue: expectedCurrentValue
                )
                decision = "rolled_back"
                if verifyRollback {
                    Thread.sleep(forTimeInterval: passSeconds + settleSeconds)
                    control = try measurementWindows(passSeconds: passSeconds, label: "control")
                }
            }

            cleanUp()

            var report: [String: Any] = [
                "success": true,
                "verified": true,
                "state": "evaluated",
                "decision": decision,
                "change": [
                    "track": trackName,
                    "plugin": pluginName,
                    "parameter": parameter,
                    "before": change["before"] ?? expectedCurrentValue,
                    "applied": change["after"] ?? targetValue
                ],
                "loop": [
                    "start_bar": startBar,
                    "end_bar": endBar,
                    "pass_seconds": round(passSeconds * 100) / 100,
                    "tempo": tempo,
                    "beats_per_bar": Int(beatsPerBar)
                ],
                "baseline": baseline,
                "after": after,
                "deltas": measurementDeltas(from: baseline, to: after)
            ]
            if let control = control {
                report["control"] = control
                report["rollback_residual"] = measurementDeltas(from: baseline, to: control)
            }
            cleanupStatus["parameter"] = decision == "rolled_back" ? "restored" : "kept_at_target"
            report["restored"] = cleanupStatus
            return report
        } catch {
            cleanUp()
            throw error
        }
    }

    private func measurementWindows(passSeconds: Double, label: String) throws -> [[String: Any]] {
        let sensors = SensorReader.readSensors(windowSeconds: passSeconds)
            .filter { !(($0["stale"] as? Bool) ?? true) }
        guard !sensors.isEmpty else {
            throw DemoError.openVerificationFailed("no fresh sensor data for the \(label) window")
        }
        let playing = sensors.contains {
            (($0["latest"] as? [String: Any])?["transport"] as? String) == "playing"
        }
        guard playing else {
            throw DemoError.openVerificationFailed(
                "the sensor reports that the transport is not rolling during the \(label) window"
            )
        }
        return sensors.map { sensor in
            let window = sensor["window"] as? [String: Any] ?? [:]
            let latest = sensor["latest"] as? [String: Any] ?? [:]
            var entry: [String: Any] = [
                "sensor": sensor["instance_id"] ?? "unknown",
                "frames": window["frames"] ?? 0,
                "rms_db": window["rms_db"] ?? [],
                "max_peak_db": window["max_peak_db"] ?? [],
                "beat": latest["beat"] ?? NSNull(),
                "transport": latest["transport"] ?? "unknown"
            ]
            // Capture the just-measured window as listenable audio: the last
            // pass-length of the rolling ring IS the measured window.
            if let ringPath = sensor["ring_path"] as? String,
               let capture = SensorReader.captureAudio(
                   ringPath: ringPath, seconds: passSeconds, label: label
               ) {
                entry["audio"] = capture
            }
            return entry
        }
    }

    private func measurementDeltas(
        from reference: [[String: Any]],
        to measurement: [[String: Any]]
    ) -> [[String: Any]] {
        measurement.compactMap { entry in
            guard let id = entry["sensor"] as? String,
                  let referenceEntry = reference.first(where: { ($0["sensor"] as? String) == id }),
                  let referenceRMS = referenceEntry["rms_db"] as? [Double],
                  let measuredRMS = entry["rms_db"] as? [Double],
                  let referencePeak = referenceEntry["max_peak_db"] as? [Double],
                  let measuredPeak = entry["max_peak_db"] as? [Double] else {
                return nil
            }
            func delta(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
                zip(rhs, lhs).map { round(($0 - $1) * 100) / 100 }
            }
            return [
                "sensor": id,
                "rms_delta_db": delta(referenceRMS, measuredRMS),
                "peak_delta_db": delta(referencePeak, measuredPeak)
            ]
        }
    }

    // MARK: - Channel strip helpers

    /// Any inspector strip (left or right) whose name matches, for output and
    /// aux strips that are not selectable track headers.
    private func anyInspectorStrip(named name: String) throws -> AXUIElement {
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

    private func inspectorStrip(named trackName: String) throws -> AXUIElement {
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

    private func insertSlots(of strip: AXUIElement) -> [InsertSlot] {
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

    private func resolveSlot(
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

    private func pluginNamesMatch(_ displayed: String, _ requested: String) -> Bool {
        let lhs = displayed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        // Logic truncates displayed insert names (for example "Space D" for "Space Designer"),
        // so accept a prefix relationship in either direction.
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private func parseTrackDescription(_ description: String) -> (number: Int, name: String)? {
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

    private func trackHeaderGroup() throws -> AXUIElement {
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

    private func trackHeaderItems() throws -> [AXUIElement] {
        try children(of: trackHeaderGroup()).filter {
            stringAttribute($0, kAXRoleAttribute as String) == "AXLayoutItem"
        }
    }

    // MARK: - Window helpers

    private func projectWindow() throws -> AXUIElement {
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

    private func logicWindows() throws -> [AXUIElement] {
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

    private func documentPath(of window: AXUIElement) -> String? {
        let document = stringAttribute(window, kAXDocumentAttribute as String)
        guard !document.isEmpty else { return nil }
        return normalizedPath(document)
    }

    private func normalizedPath(_ raw: String) -> String {
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

    private func pollWindowDiff(before: Set<WindowKey>, expectAppear: Bool) throws -> AXUIElement? {
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

    private func firstMissingWindow(from before: Set<WindowKey>) -> WindowKey? {
        guard let current = try? logicWindows() else { return nil }
        let currentKeys = Set(current.map(WindowKey.init))
        return before.first { !currentKeys.contains($0) }
    }

    private func pollWindowDisappeared(before: Set<WindowKey>) throws -> Bool {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let currentKeys = Set(try logicWindows().map(WindowKey.init))
            if before.subtracting(currentKeys).isEmpty == false {
                return true
            }
        }
        return false
    }

    private func closeWindowElement(_ window: AXUIElement) -> Bool {
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

    private func openResult(
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

    private func collect(
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

    private func logicWindow(title: String) throws -> AXUIElement {
        guard let window = try logicWindows().first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == title
        }) else {
            throw DemoError.windowNotFound(title)
        }
        return window
    }

    private func parameter(from element: AXUIElement) -> AccessibleParameter? {
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

    private func extractedParameterName(fromHelp help: String) -> String {
        let suffixes = [" knob and field", " knob"]
        let firstSentence = help.split(separator: ".", maxSplits: 1).first.map(String.init) ?? help
        for suffix in suffixes {
            if let range = firstSentence.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                return String(firstSentence[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func revealFormattedValue(of field: AXUIElement, fallbackName: String) throws -> String {
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

    private func restore(field: AXUIElement, value: String) -> Bool {
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

    private func equivalentFormattedValues(_ lhs: String, _ rhs: String) -> Bool {
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

    private func normalizedFormattedValue(_ value: String) -> (text: String, number: Double?) {
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

    private func descendants(of root: AXUIElement, maximumDepth: Int = 20) -> [AXUIElement] {
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

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        return String(describing: value)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }
}

/// Reads feature frames published by the LogicMCPSensor Audio Unit.
/// Binary layout is locked by _Static_asserts in Sensor/LogicMCPSensor.c.
private enum SensorReader {
    private static let headerBytes = 128
    private static let frameBytes = 80
    private static let magic = "LMCPSNS1"
    private static let audioMagic = "LMCPAUD1"

    static func candidateDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/com.apple.logic10/Data/Library/Application Support/LogicMCPSensor"),
            home.appendingPathComponent("Library/Application Support/LogicMCPSensor")
        ]
    }

    static func readSensors(windowSeconds: Double) -> [[String: Any]] {
        var sensors: [[String: Any]] = []
        for directory in candidateDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for file in entries where file.pathExtension == "ring" {
                if let sensor = readRing(at: file, windowSeconds: windowSeconds) {
                    sensors.append(sensor)
                }
            }
        }
        return sensors
    }

    private static func readRing(at url: URL, windowSeconds: Double) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count >= headerBytes else { return nil }
        guard String(data: data.prefix(8), encoding: .ascii) == magic else { return nil }
        let frameSize = Int(load(data, 12, UInt32.self))
        let capacity = Int(load(data, 16, UInt32.self))
        guard frameSize == frameBytes, capacity > 0,
              data.count >= headerBytes + frameSize * capacity else { return nil }
        let instanceID = String(
            data: data.subdata(in: 24..<64), encoding: .ascii
        )?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? "unknown"
        let cursor = Int(load(data, 64, UInt64.self))
        guard cursor > 0 else {
            return [
                "instance_id": instanceID,
                "ring_path": url.path,
                "frames_published": 0,
                "note": "sensor is instantiated but has published no frames yet"
            ]
        }

        let now = Date().timeIntervalSince1970
        let available = min(cursor, capacity)
        var latest: [String: Any] = [:]
        var sumRMS = [Double](repeating: 0, count: 2)
        var maxPeak = [Float](repeating: 0, count: 2)
        var counted = 0

        for back in 0..<available {
            let index = (cursor - 1 - back) % capacity
            let offset = headerBytes + index * frameSize
            let unixTime = load(data, offset + 8, Double.self)
            if back > 0, now - unixTime > windowSeconds { break }
            let channels = min(Int(load(data, offset + 24, UInt32.self)), 2)
            var peaks: [Float] = []
            var rmsValues: [Float] = []
            for channel in 0..<channels {
                peaks.append(load(data, offset + 32 + channel * 4, Float.self))
                rmsValues.append(load(data, offset + 40 + channel * 4, Float.self))
            }
            if back == 0 {
                let beat = load(data, offset + 48, Double.self)
                let tempo = load(data, offset + 56, Double.self)
                let transport = load(data, offset + 64, UInt32.self)
                latest = [
                    "age_seconds": round((now - unixTime) * 100) / 100,
                    "sample_rate": load(data, offset + 16, Double.self),
                    "channels": channels,
                    "peak_db": peaks.map(decibels),
                    "rms_db": rmsValues.map(decibels),
                    "beat": beat < 0 ? NSNull() : beat,
                    "tempo": tempo < 0 ? NSNull() : tempo,
                    "transport": transport == 1 ? "playing" : (transport == 0 ? "stopped" : "unknown"),
                    "bypassed": load(data, offset + 68, UInt32.self) == 1
                ]
            }
            for channel in 0..<channels {
                sumRMS[channel] += Double(rmsValues[channel]) * Double(rmsValues[channel])
                maxPeak[channel] = max(maxPeak[channel], peaks[channel])
            }
            counted += 1
        }

        let channels = latest["channels"] as? Int ?? 2
        let lastAge = latest["age_seconds"] as? Double ?? .infinity
        return [
            "instance_id": instanceID,
            "ring_path": url.path,
            "frames_published": cursor,
            "stale": lastAge > 10,
            "latest": latest,
            "window": [
                "seconds": windowSeconds,
                "frames": counted,
                "rms_db": (0..<channels).map { decibels(Float((sumRMS[$0] / Double(max(counted, 1))).squareRoot())) },
                "max_peak_db": (0..<channels).map { decibels(maxPeak[$0]) }
            ]
        ]
    }

    /// Extracts the last `seconds` of audio from a sensor's rolling audio ring
    /// and writes a 16-bit PCM WAV that a human or an audio-capable model can
    /// listen to. Returns capture metadata, or nil when no audio is available.
    static func captureAudio(ringPath: String, seconds: Double, label: String) -> [String: Any]? {
        let audioPath = ringPath.replacingOccurrences(of: ".ring", with: ".audio")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: audioPath)), data.count > 64,
              String(data: data.prefix(8), encoding: .ascii) == audioMagic else { return nil }
        let channels = Int(load(data, 12, UInt32.self))
        let sampleRate = load(data, 16, Double.self)
        let capacity = Int(load(data, 24, UInt64.self))
        let cursor = Int(load(data, 32, UInt64.self))
        guard channels > 0, channels <= 2, sampleRate > 0, capacity > 0, cursor > 0,
              data.count >= 64 + capacity * channels * 4 else { return nil }

        let requested = Int(seconds * sampleRate)
        let frames = min(requested, capacity, cursor)
        guard frames > Int(sampleRate / 10) else { return nil }
        let start = cursor - frames

        var samples = [Int16](repeating: 0, count: frames * channels)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: 64)
            for frame in 0..<frames {
                let slot = (start + frame) % capacity
                for channel in 0..<channels {
                    let value = base.loadUnaligned(
                        fromByteOffset: (slot * channels + channel) * 4, as: Float.self
                    )
                    let clamped = max(-1, min(1, value))
                    samples[frame * channels + channel] = Int16(clamped * 32767)
                }
            }
        }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicMCPSensor/captures")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let shortID = String(ringPath.split(separator: "-").last?.prefix(8) ?? "sensor")
        let fileURL = directory.appendingPathComponent(
            "\(formatter.string(from: Date()))-\(label)-\(shortID).wav"
        )
        do {
            try writeWAV(samples: samples, channels: channels, sampleRate: Int(sampleRate), to: fileURL)
        } catch {
            return nil
        }
        return [
            "label": label,
            "path": fileURL.path,
            "seconds": round(Double(frames) / sampleRate * 100) / 100,
            "sample_rate": sampleRate,
            "channels": channels,
            "format": "wav_pcm16",
            "clipped_to_available": frames < requested
        ]
    }

    private static func writeWAV(samples: [Int16], channels: Int, sampleRate: Int, to url: URL) throws {
        var out = Data()
        let dataBytes = samples.count * 2
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataBytes))
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        append(16)
        append16(1) // PCM
        append16(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append16(UInt16(channels * 2))
        append16(16)
        out.append("data".data(using: .ascii)!)
        append(UInt32(dataBytes))
        samples.withUnsafeBytes { out.append(contentsOf: $0) }
        try out.write(to: url)
    }

    private static func decibels(_ linear: Float) -> Double {
        guard linear > 1e-6 else { return -120 }
        return round(20 * log10(Double(linear)) * 100) / 100
    }

    private static func load<T>(_ data: Data, _ offset: Int, _ type: T.Type) -> T {
        data.subdata(in: offset..<(offset + MemoryLayout<T>.size)).withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
}

/// Talks to the logic-mcu-bridge daemon: reads its mirrored Mackie Control
/// state file and sends commands over its unix socket.
private enum MCUBridge {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicMCPMCU")
    }

    static func status() -> [String: Any] {
        let stateURL = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "bridge_running": false,
                "note": "no state file; start the bridge with .build/release/logic-mcu-bridge"
            ]
        }
        let updated = object["updated"] as? Double ?? 0
        object["bridge_running"] = Date().timeIntervalSince1970 - updated < 15
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.sock").path)
        return object
    }

    /// Starts the bridge daemon when its socket is dead: standard MCP
    /// practice is that the server manages its own sidecars. Looks for the
    /// logic-mcu-bridge binary next to this executable.
    static func ensureRunning() {
        if (try? send(["cmd": "ping"]))?["ok"] as? Bool == true { return }
        // The bridge daemon is this same binary launched with --bridge —
        // one distributable artifact, no sibling files to install.
        let serverURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = serverURL
        process.arguments = ["--bridge"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        for _ in 0..<30 {
            usleep(100_000)
            if (try? send(["cmd": "ping"]))?["ok"] as? Bool == true {
                FileHandle.standardError.write(Data("[logician] started bridge daemon\n".utf8))
                return
            }
        }
    }

    static func send(_ command: [String: Any]) throws -> [String: Any] {
        let path = directory.appendingPathComponent("command.sock").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DemoError.writeFailed("could not create a socket")
        }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: UnsafeRawBufferPointer(
                    start: source, count: min(strlen(source) + 1, raw.count)
                ))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            throw DemoError.writeFailed(
                "could not reach the MCU bridge socket; is logic-mcu-bridge running?"
            )
        }
        let payload = try JSONSerialization.data(withJSONObject: command)
        _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, payload.count) }
        Darwin.shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0,
              let response = try? JSONSerialization.jsonObject(
                  with: Data(buffer[0..<count])
              ) as? [String: Any] else {
            throw DemoError.openVerificationFailed("no response from the MCU bridge")
        }
        return response
    }
}

/// Key commands learned onto the dedicated "Logic MCP Commands" MIDI port
/// (Key Commands window > Learn New Assignment). The registry file is the
/// consent record: only notes listed there may be triggered, because an
/// unlisted note could be bound to anything in the user's key command set.
private enum KeyCommandRegistry {
    static var url: URL {
        MCUBridge.directory.appendingPathComponent("keycmd-registry.json")
    }

    static func commands() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]] else { return [] }
        return commands
    }

    static func entry(note: Int, channel: Int) -> [String: Any]? {
        commands().first {
            ($0["note"] as? Int) == note && (($0["channel"] as? Int) ?? 16) == channel
        }
    }

    static func note(named name: String) -> (note: Int, channel: Int)? {
        guard let hit = commands().first(where: {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }), let note = hit["note"] as? Int else { return nil }
        return (note, (hit["channel"] as? Int) ?? 16)
    }

    static func register(note: Int, channel: Int, name: String, notes: String) {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["port": "Logic MCP Commands"]
        var commands = root["commands"] as? [[String: Any]] ?? []
        commands.removeAll {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        let formatter = ISO8601DateFormatter()
        commands.append([
            "note": note, "channel": channel, "name": name,
            "learned": String(formatter.string(from: Date()).prefix(10)),
            "notes": notes
        ])
        root["commands"] = commands
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    /// The commands the product's tools rely on, with search terms for the
    /// Key Commands window and preferred (not guaranteed) note numbers —
    /// collisions on a user's machine get an alternate note automatically.
    static let standardCommands: [(search: String, name: String, preferredNote: Int)] = [
        ("save", "Save", 105),
        ("new software instrument", "New Software Instrument Track", 106),
        ("new audio track", "New Audio Track", 107),
        ("toggle track freeze", "Toggle Track Freeze", 117),
        ("undo", "Undo", 100),
        ("redo", "Redo", 101),
        ("flashback", "Flashback Capture as Recording", 102),
        ("split regions/events", "Split Regions/Events at Playhead Position", 103),
        ("cut", "Cut", 108),
        ("copy", "Copy", 109),
        ("paste", "Paste", 110),
        ("delete", "Delete", 111),
        ("nudge region", "Nudge Region/Event Position Right by Bar", 112),
        ("nudge region", "Nudge Region/Event Position Left by Bar", 113),
        ("nudge region", "Nudge Region/Event Position Right by Beat", 114),
        ("nudge region", "Nudge Region/Event Position Left by Beat", 115),
        ("create marker", "Create Marker", 104)
    ]
}

/// MCU-first implementations of the high-level controls. Each function returns
/// nil when the MCU route is unavailable or cannot safely resolve the target
/// (nothing was written — callers fall back to Accessibility), returns a result
/// on verified success, and throws when a write happened but verification
/// failed (never silently fall back after a partial write).
private enum MCUController {
    static func freshStatus() -> [String: Any]? {
        // In-memory status straight from the bridge socket (no file throttle);
        // fall back to the state file if the socket round trip fails.
        let status = (try? MCUBridge.send(["cmd": "status"])) ?? MCUBridge.status()
        guard status["ok"] as? Bool == true || status["bridge_running"] as? Bool == true else { return nil }
        // A silent Logic sends nothing, so do not require recent traffic —
        // only that Logic has ever talked this session. Every write verifies
        // itself through LED/LCD feedback, which is the real liveness check.
        guard (status["received_events"] as? Int ?? 0) > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - (status["last_receive"] as? Double ?? 0)
        guard age < 600 else { return nil }
        return status
    }

    /// Event-driven wait: blocks in the bridge until new MIDI arrived from
    /// Logic (or timeout), then returns the fresh in-memory status.
    static func awaitEvents(since: Int, timeoutMs: Int) -> [String: Any]? {
        try? MCUBridge.send(["cmd": "await", "since": since, "timeout_ms": timeoutMs])
    }

    /// Waits until `check` passes, driven by actual MIDI events rather than
    /// fixed sleeps. Returns the passing status, or nil on deadline.
    static func waitFor(
        seconds: Double = 2.5,
        _ check: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        guard var status = freshStatus() else { return nil }
        while true {
            if check(status) { return status }
            if Date() >= deadline { return nil }
            let since = status["received_events"] as? Int ?? -1
            guard let next = awaitEvents(since: since, timeoutMs: 350) else { return nil }
            status = next
        }
    }

    /// True when 150 ms pass without new MIDI from Logic (display quiescent).
    static func quiescentStatus() -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let since = status["received_events"] as? Int ?? -1
        guard let after = awaitEvents(since: since, timeoutMs: 150) else { return status }
        if after["timed_out"] as? Bool == true { return after }
        return nil // more data arrived; caller should re-check content first
    }

    private static func press(_ button: String) throws {
        let response = try MCUBridge.send(["cmd": "press", "button": button])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU press \(button) failed: \(response["error"] ?? "?")")
        }
    }

    private static func ledLit(_ note: Int, in status: [String: Any]) -> Bool {
        (status["leds_lit"] as? [Int])?.contains(note) ?? false
    }

    private static func pollStatus(
        until check: ([String: Any]) -> Bool,
        attempts: Int = 15
    ) -> [String: Any]? {
        waitFor(seconds: Double(attempts) * 0.15, check)
    }

    // MARK: Transport

    static func setPlaying(_ playing: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let playLED = 0x5E
        if ledLit(playLED, in: status) == playing {
            return [
                "success": true, "verified": true,
                "state": playing ? "already_playing" : "already_stopped",
                "playing": playing, "route": "mcu"
            ]
        }
        try press(playing ? "play" : "stop")
        guard pollStatus(until: { ledLit(playLED, in: $0) == playing }) != nil else {
            throw DemoError.verificationFailed(
                requested: "playing=\(playing)",
                actual: "MCU play LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": playing ? "playing" : "stopped",
            "playing": playing,
            "route": "mcu",
            "readback_route": "mcu_transport_led"
        ]
    }

    static func setCycle(_ enabled: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let cycleLED = 0x56
        if ledLit(cycleLED, in: status) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "cycle_on" : "cycle_off"),
                "cycle": enabled, "route": "mcu"
            ]
        }
        try press("cycle")
        guard pollStatus(until: { ledLit(cycleLED, in: $0) == enabled }) != nil else {
            throw DemoError.verificationFailed(
                requested: "cycle=\(enabled)",
                actual: "MCU cycle LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "cycle_on" : "cycle_off",
            "cycle": enabled, "route": "mcu",
            "readback_route": "mcu_cycle_led"
        ]
    }

    // MARK: LCD helpers

    static func lcdFields(_ row: String) -> [String] {
        var fields: [String] = []
        let characters = Array(row.padding(toLength: 56, withPad: " ", startingAt: 0))
        for channel in 0..<8 {
            let slice = characters[(channel * 7)..<(channel * 7 + 7)]
            fields.append(String(slice).trimmingCharacters(in: .whitespaces))
        }
        return fields
    }

    /// Logic abbreviates track names on the MCU LCD by dropping characters
    /// ("Lofi Pad" -> "LofPad"); an ordered subsequence match recovers them.
    static func lcdNameMatches(track: String, lcd: String) -> Bool {
        guard !lcd.isEmpty else { return false }
        let target = track.replacingOccurrences(of: " ", with: "").lowercased()
        let shown = lcd.replacingOccurrences(of: " ", with: "").lowercased()
        guard let first = shown.first, target.first == first else { return false }
        var iterator = target.makeIterator()
        var pending = shown[...]
        while let character = pending.first {
            var found = false
            while let candidate = iterator.next() {
                if candidate == character { found = true; break }
            }
            if !found { return false }
            pending = pending.dropFirst()
        }
        return true
    }

    /// The assign_pan button TOGGLES between the multi-channel pan view (track
    /// names on top) and a single-channel view ("Pan    -      -   ..."), and
    /// the assignment display reads "PN" in both — so the mode must be verified
    /// by LCD content, never by blind presses.
    static func ensurePanNames() throws -> Bool {
        for _ in 0..<5 {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return false }
            let assignment = status["assignment"] as? String
            let fields = lcdFields(top)
            let dashes = fields.filter { $0 == "-" }.count
            if assignment == "PN" && dashes < 4 { return true }
            try press("assign_pan")
            if waitFor(seconds: 1.2, { status in
                guard let top = status["lcd_top"] as? String else { return false }
                return (status["assignment"] as? String) == "PN"
                    && lcdFields(top).filter({ $0 == "-" }).count < 4
            }) != nil { return true }
        }
        return false
    }

    private static func ensureAssignment(_ code: String, button: String) throws -> [String: Any]? {
        for _ in 0..<3 {
            guard let status = freshStatus() else { return nil }
            if (status["assignment"] as? String) == code { return status }
            try press(button)
            if let reached = waitFor(seconds: 1.2, { ($0["assignment"] as? String) == code }) {
                return reached
            }
        }
        return freshStatus().flatMap { ($0["assignment"] as? String) == code ? $0 : nil }
    }

    static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[mcu] \(message)\n".utf8))
    }

    /// Banks to the leftmost position, scans right for a channel whose LCD
    /// name matches, and leaves the surface banked at the match. Returns nil
    /// (nothing written that matters) when not found or ambiguous.
    private static var bankCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("bank-cache.json")
    }

    private static func loadBankCache() -> [String]? {
        guard let data = try? Data(contentsOf: bankCacheURL),
              let tops = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return tops
    }

    private static func resetToLeftmostBank() throws {
        for _ in 0..<8 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_left")
            _ = awaitEvents(since: before, timeoutMs: 150)
        }
    }

    /// Navigates to a bank by index (from leftmost) and verifies the expected
    /// LCD content. Returns false on mismatch (stale cache).
    private static func navigateToBank(_ index: Int, expecting expectedTop: String) throws -> Bool {
        try resetToLeftmostBank()
        for _ in 0..<index {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_right")
            _ = awaitEvents(since: before, timeoutMs: 250)
        }
        return waitFor(seconds: 1.5, { ($0["lcd_top"] as? String) == expectedTop }) != nil
    }

    static func findChannel(trackName: String, retryOnEmpty: Bool = true) throws -> Int? {
        guard try ensurePanNames() else { debugLog("pan multi-channel view failed"); return nil }

        // Fastest path: the track is unique on the bank already showing.
        if let status = freshStatus(), let top = status["lcd_top"] as? String,
           let cachedTops = loadBankCache(), cachedTops.contains(top) {
            let allMatches = cachedTops.flatMap { cachedTop in
                lcdFields(cachedTop).enumerated().filter {
                    lcdNameMatches(track: trackName, lcd: $0.element)
                }
            }
            if allMatches.count == 1 {
                let current = lcdFields(top).enumerated().filter {
                    lcdNameMatches(track: trackName, lcd: $0.element)
                }
                if current.count == 1, let hit = current.first {
                    return hit.offset
                }
            }
        }

        // Fast path: the cached bank map from the previous full scan.
        if let cachedTops = loadBankCache() {
            var cachedMatches: [(bank: Int, channel: Int)] = []
            for (bank, cachedTop) in cachedTops.enumerated() {
                for (channel, name) in lcdFields(cachedTop).enumerated()
                where lcdNameMatches(track: trackName, lcd: name) {
                    cachedMatches.append((bank, channel))
                }
            }
            if cachedMatches.count == 1, let match = cachedMatches.first,
               try navigateToBank(match.bank, expecting: cachedTops[match.bank]) {
                return match.channel
            }
            // stale or ambiguous cache: fall through to a full rescan
            try? FileManager.default.removeItem(at: bankCacheURL)
        }

        try resetToLeftmostBank()
        guard var top = try settledTop() else { debugLog("no settled top after reset"); return nil }
        var bankTops: [String] = []
        var matches: [(bank: Int, channel: Int)] = []
        for bank in 0..<10 {
            if bankTops.last == top { break }
            bankTops.append(top)
            for (channel, name) in lcdFields(top).enumerated()
            where lcdNameMatches(track: trackName, lcd: name) {
                matches.append((bank, channel))
            }
            try press("bank_right")
            guard let next = try settledTop(previous: top) else { debugLog("no settled top in scan"); return nil }
            top = next
        }
        if let encoded = try? JSONEncoder().encode(bankTops) {
            try? encoded.write(to: bankCacheURL)
        }
        // Right after a project switch Logic rebuilds the control surface for
        // a few seconds and a full scan can come up empty — settle and rescan
        // once before giving up.
        if matches.isEmpty, retryOnEmpty {
            debugLog("empty bank scan; settling and rescanning once")
            Thread.sleep(forTimeInterval: 2.5)
            try? FileManager.default.removeItem(at: bankCacheURL)
            return try findChannel(trackName: trackName, retryOnEmpty: false)
        }
        guard matches.count == 1, let match = matches.first else { debugLog("match count \(matches.count)"); return nil }
        // Navigate back: we are at bank bankTops.count-1 (or the repeat point).
        let currentBank = bankTops.count - 1
        for _ in 0..<(currentBank - match.bank) {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_left")
            _ = awaitEvents(since: before, timeoutMs: 250)
        }
        if waitFor(seconds: 2.0, { ($0["lcd_top"] as? String) == bankTops[match.bank] }) != nil {
            return match.channel
        }
        debugLog("navigate-back verify failed")
        return nil
    }

    /// Waits until the LCD top row holds stable, non-transient channel content
    /// (two consecutive identical reads that are not a "-      " banner), and
    /// differs from `previous` when given (returns previous content on timeout,
    /// which scan loops interpret as "rightmost bank reached").
    private static func settledTop(previous: String? = nil) throws -> String? {
        let deadline = Date().addingTimeInterval(3.0)
        var quietRepeats = 0
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            let events = status["received_events"] as? Int ?? -1
            let transient = lcdFields(top).filter { $0 == "-" }.count >= 4
            if !transient {
                if previous == nil || top != previous {
                    // stable = 120 ms without new MIDI from Logic
                    if let after = awaitEvents(since: events, timeoutMs: 120),
                       after["timed_out"] as? Bool == true {
                        return top
                    }
                    continue
                }
                // same as previous: two quiet rounds means the display will not
                // change (e.g. rightmost bank reached)
                if let after = awaitEvents(since: events, timeoutMs: 200),
                   after["timed_out"] as? Bool == true {
                    quietRepeats += 1
                    if quietRepeats >= 2 { return previous }
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return previous
    }

    // MARK: Mute / solo

    static func setToggle(
        trackName: String,
        control: String, // "mute" | "solo"
        enabled: Bool
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        let ledBase = control == "mute" ? 0x10 : 0x08
        let note = ledBase + channel
        guard let before = freshStatus() else { return nil }
        if ledLit(note, in: before) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "track": trackName, "control": control, control: enabled, "route": "mcu"
            ]
        }
        let response = try MCUBridge.send(["cmd": control, "channel": channel])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU \(control) failed: \(response["error"] ?? "?")")
        }
        guard pollStatus(until: { ledLit(note, in: $0) == enabled }) != nil else {
            throw DemoError.verificationFailed(
                requested: "\(control)=\(enabled)",
                actual: "MCU \(control) LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "on" : "off",
            "track": trackName, "control": control, control: enabled,
            "route": "mcu", "readback_route": "mcu_channel_led"
        ]
    }

    // MARK: Volume (vpot converge against the LCD dB readout)

    static func parseDb(_ text: String) -> Double? {
        // LCD cells are 7 characters; the "dB" suffix may be cut mid-way
        // ("-10,0 d"), so keep only the leading numeric run.
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("-oo") { return -70.0 } // Logic's minus infinity
        let numeric = normalized.prefix { "+-0123456789.".contains($0) }
        return Double(numeric)
    }

    static func setVolume(
        trackName: String,
        targetDb: Double,
        toleranceDb: Double
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard let modeStatus = try ensureAssignment("CS", button: "assign_track"),
              (modeStatus["lcd_top"] as? String)?.contains("Volume") == true else {
            _ = try? ensurePanNames()
            return nil
        }
        defer { _ = try? ensurePanNames() }

        func currentDb() -> Double? {
            guard let status = freshStatus(), let bottom = status["lcd_bottom"] as? String else {
                return nil
            }
            return parseDb(lcdFields(bottom)[channel])
        }
        guard let startDb = currentDb() else { return nil }
        var db = startDb
        var ticksPerDb = 2.5
        var stuck = 0
        for _ in 0..<30 {
            let difference = targetDb - db
            if abs(difference) <= toleranceDb { break }
            let ticks = max(1, min(60, Int((abs(difference) * ticksPerDb).rounded())))
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send([
                "cmd": "vpot", "index": channel, "delta": difference > 0 ? ticks : -ticks
            ])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("MCU vpot failed: \(response["error"] ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 300)
            guard let updated = currentDb() else { break }
            if abs(updated - db) < 0.01 {
                stuck += 1
                if stuck >= 3 {
                    throw DemoError.verificationFailed(
                        requested: String(format: "%.1f dB", targetDb),
                        actual: String(format: "volume stuck at %.1f dB", updated),
                        restored: false
                    )
                }
            } else {
                stuck = 0
                ticksPerDb = min(30, max(0.5, Double(ticks) / abs(updated - db)))
            }
            db = updated
        }
        guard abs(db - targetDb) <= max(toleranceDb, 0.25) else {
            throw DemoError.verificationFailed(
                requested: String(format: "%.1f dB", targetDb),
                actual: String(format: "%.1f dB", db),
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "volume_set",
            "track": trackName,
            "before_db": round(startDb * 10) / 10,
            "after_db": round(db * 10) / 10,
            "requested_db": targetDb,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_db"
        ]
    }
}

extension MCUController {
    /// Presses assign_plugin until the selected track's insert list ("Ins1Pl…")
    /// is showing. The button cycles PL <-> per-insert bank views, so content
    /// must be verified, never press-counted.
    static func ensurePluginList() throws -> [String: Any]? {
        for _ in 0..<5 {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            if top.hasPrefix("Ins1Pl") { return status }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_plugin")
            _ = awaitEvents(since: before, timeoutMs: 350)
            _ = quiescentStatus() // let the redraw finish before re-checking
        }
        return nil
    }

    static func exitToPan() {
        _ = try? ensurePanNames()
    }

    // MARK: Key commands over the dedicated MIDI port

    /// Fires a key command learned onto the "Logic MCP Commands" port. Only
    /// registry-listed notes are sent — an unlisted note could be bound to
    /// anything in the user's key command set.
    static func triggerKeyCommand(note: Int, channel: Int) throws -> [String: Any] {
        guard let entry = KeyCommandRegistry.entry(note: note, channel: channel) else {
            throw DemoError.trackNotExposed(
                requested: "key command note \(note) channel \(channel)",
                exposed: "registered commands: "
                    + KeyCommandRegistry.commands().map {
                        "\($0["name"] ?? "?") (note \($0["note"] ?? "?"))"
                    }.joined(separator: ", ")
            )
        }
        let response = try MCUBridge.send([
            "cmd": "keycmd", "note": note, "channel": channel
        ])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("keycmd failed: \(response["error"] ?? "?")")
        }
        return [
            "success": true,
            "command": entry["name"] ?? "?",
            "note": note,
            "channel": channel,
            "route": "midi_key_command"
        ]
    }

    /// Selects the MCU channel found by findChannel and confirms via the
    /// select-echo Logic paints into that channel's LCD field.
    static func selectFoundChannel(_ channel: Int) throws -> Bool {
        let before = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(["cmd": "select", "channel": channel])
        guard response["ok"] as? Bool == true else { return false }
        _ = awaitEvents(since: before, timeoutMs: 400)
        return true
    }

    // MARK: Track rendering via Freeze (dialog-free offline export)

    /// Renders the SELECTED track offline by toggling Track Freeze and
    /// pressing play: Logic writes a 32-bit float AIFF into the project's
    /// Media/Freeze Files with no dialogs. The file is copied out before the
    /// freeze is toggled back off (Logic deletes it on unfreeze).
    /// Resolves a key command to its learned MIDI note; when missing and the
    /// command is one of the standard set, learns it automatically on the
    /// spot (lazy onboarding — the registry records what was added).
    /// Set when the most recent resolve had to learn the command on the
    /// spot (the Key Commands window flashes briefly) — surfaced in tool
    /// results so users understand what they just saw.
    nonisolated(unsafe) static var lastResolveLearned = false // single-threaded server loop

    static func resolveKeyCommand(
        named name: String, logic: LogicAccessibility?
    ) throws -> (note: Int, channel: Int) {
        lastResolveLearned = false
        if let found = KeyCommandRegistry.note(named: name) { return found }
        if let logic, let standard = KeyCommandRegistry.standardCommands.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            _ = try? logic.setupKeyCommands([standard])
            if let found = KeyCommandRegistry.note(named: name) {
                lastResolveLearned = true
                return found
            }
        }
        throw DemoError.trackNotExposed(
            requested: "key command '\(name)'",
            exposed: "not in the registry and automatic learning did not succeed; run logic_setup_key_commands with Logic frontmost"
        )
    }

    /// Ensures a track is NOT frozen before a freeze-render cycle starts:
    /// reads the header checkbox, and if frozen sends the toggle and answers
    /// Logic's unfreeze confirmation dialog.
    static func ensureUnfrozen(logic: LogicAccessibility, trackName: String) throws {
        guard logic.trackFreezeState(trackName: trackName) == true else { return }
        guard let freeze = try? resolveKeyCommand(named: "Toggle Track Freeze", logic: logic) else { return }
        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)
        var answered = false
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.2)
            if logic.answerFreezeDialog() { answered = true; break }
            if logic.trackFreezeState(trackName: trackName) == false { return }
        }
        _ = answered
        for _ in 0..<20 {
            if logic.trackFreezeState(trackName: trackName) == false { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw DemoError.verificationFailed(
            requested: "unfreeze of '\(trackName)' before rendering",
            actual: "the track header's freeze button is still lit",
            restored: false
        )
    }

    static func renderSelectedTrack(
        projectPath: String, label: String,
        sliceStartSeconds: Double? = nil, sliceEndSeconds: Double? = nil,
        logic: LogicAccessibility? = nil, trackName: String? = nil
    ) throws -> [String: Any] {
        let freeze = try resolveKeyCommand(named: "Toggle Track Freeze", logic: logic)
        // A rolling transport queues freeze dialogs invisibly and swallows
        // toggles — make sure we start from silence. And a track that is
        // ALREADY frozen must be thawed first, or the toggle inverts.
        _ = try? setPlaying(false)
        // Play does NOTHING when the playhead sits at/past the project end,
        // so the freeze render would never start. Stop-when-stopped jumps
        // to the project start — pure MCU, position-safe.
        _ = try? MCUBridge.send(["cmd": "press", "button": "stop"])
        Thread.sleep(forTimeInterval: 0.4)
        if let logic, let trackName {
            try ensureUnfrozen(logic: logic, trackName: trackName)
        }
        let freezeDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("Media/Freeze Files")
        let manager = FileManager.default
        func freezeFiles() -> Set<String> {
            Set((try? manager.contentsOfDirectory(atPath: freezeDir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
        }
        let baseline = freezeFiles()

        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)
        _ = try? setPlaying(true)

        // The render announces itself with FreezeInProgress.lock plus the
        // growing .aif; completion is the lock disappearing.
        var newAudio: String?
        var renderStarted = false
        let startDeadline = Date().addingTimeInterval(10)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let fresh = freezeFiles().subtracting(baseline)
            if !fresh.isEmpty { renderStarted = true }
            if let audio = fresh.first(where: { $0.hasSuffix(".aif") || $0.hasSuffix(".wav") }),
               !fresh.contains("FreezeInProgress.lock") {
                newAudio = audio
                break
            }
            // A modal alert freezes the whole flow — the MCU timecode
            // mirrors it as 'ALERT'. And if no freeze activity showed up
            // within seconds of play, the toggle never engaged (track
            // stacks and buses cannot be frozen) — Logic is just playing.
            if let timecode = freshStatus()?["timecode"] as? String,
               timecode.contains("ALERT") {
                _ = try? setPlaying(false)
                _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
                throw DemoError.openVerificationFailed(
                    "Logic is showing a modal alert (MCU timecode reads ALERT); dismiss it and retry"
                )
            }
            if !renderStarted && Date() > startDeadline { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        _ = try? setPlaying(false)

        guard let rendered = newAudio else {
            // Restore state: only toggle back when the track actually shows
            // as frozen (a blind re-toggle would freeze a never-frozen track).
            if let logic, let trackName {
                if logic.trackFreezeState(trackName: trackName) == true {
                    _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
                    Thread.sleep(forTimeInterval: 0.5)
                    _ = logic.answerFreezeDialog()
                }
            } else {
                _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
            }
            throw DemoError.openVerificationFailed(
                renderStarted
                    ? "freeze render started but no finished file appeared within 180 s"
                    : "freeze never engaged within 10 s of play — the track is likely a track stack or bus (not freezable), or has nothing to render"
            )
        }

        // The lock can vanish before Logic finishes writing the file (a
        // 4 KB header-only snapshot copies otherwise): wait until the size
        // covers the FORM chunk and has stopped growing.
        let renderedURL = freezeDir.appendingPathComponent(rendered)
        var stableSize: UInt64 = 0
        var stableRounds = 0
        let flushDeadline = Date().addingTimeInterval(30)
        while Date() < flushDeadline, stableRounds < 3 {
            let size = (try? manager.attributesOfItem(atPath: renderedURL.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0
            var formComplete = false
            if let handle = try? FileHandle(forReadingFrom: renderedURL),
               let header = try? handle.read(upToCount: 8), header.count == 8 {
                let formSize = (UInt64(header[4]) << 24) | (UInt64(header[5]) << 16)
                    | (UInt64(header[6]) << 8) | UInt64(header[7])
                formComplete = size >= formSize + 8 && formSize > 8
                try? handle.close()
            }
            if size > 0, size == stableSize, formComplete {
                stableRounds += 1
            } else {
                stableRounds = 0
            }
            stableSize = size
            if stableRounds < 3 { Thread.sleep(forTimeInterval: 0.3) }
        }

        // Copy out before unfreezing (unfreeze deletes the file).
        let captures = manager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/LogicMCPSensor/captures"
        )
        try? manager.createDirectory(at: captures, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = captures.appendingPathComponent(
            "render-\(label)-\(stamp).\(URL(fileURLWithPath: rendered).pathExtension)"
        )
        try manager.copyItem(
            at: freezeDir.appendingPathComponent(rendered), to: destination
        )

        // Unfreeze and verify Logic removed the freeze file again; answer the
        // confirm dialog if the toggle raises one, and double-check via the
        // header checkbox when we can.
        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)
        var unfroze = false
        for attempt in 0..<40 {
            if !freezeFiles().contains(rendered) { unfroze = true; break }
            if attempt % 4 == 3, let logic { _ = logic.answerFreezeDialog() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if let logic, let trackName, logic.trackFreezeState(trackName: trackName) == true {
            unfroze = false
        }

        var result: [String: Any] = [
            "success": true,
            "verified": unfroze,
            "path": destination.path,
            "write_route": "freeze_render_headless",
            "unfrozen": unfroze,
            "note": unfroze
                ? "Track rendered offline via Freeze (no dialogs) and unfrozen again; the file is the full track from project start, mono/stereo as the track."
                : "Rendered file copied out, but the freeze file is still present — the track may still be frozen; toggle freeze manually or rerun."
        ]
        if let metrics = LogicAccessibility.audioFileMetrics(path: destination.path),
           (metrics["frames"] as? Int ?? 0) > 0 {
            result["metrics"] = metrics
        } else {
            result["warning"] =
                "the rendered file contains no audio — does the track have any regions?"
        }
        if let start = sliceStartSeconds, let end = sliceEndSeconds {
            let slicePath = captures.appendingPathComponent(
                "render-\(label)-\(stamp)-slice.wav"
            ).path
            if let slice = LogicAccessibility.sliceAudioFile(
                path: destination.path, startSeconds: start, endSeconds: end,
                destinationPath: slicePath
            ) {
                result["slice"] = slice
            } else {
                result["slice_warning"] =
                    "slicing failed — the requested range may lie beyond the rendered audio"
            }
        }
        return result
    }

    // MARK: Plugin insertion via the MCU plugin browser (mouse-free)

    /// Adds a plugin to the selected track's first empty insert slot by
    /// driving Logic's control-surface plugin browser: vpot turn on an empty
    /// slot steps through the plugin list (full names on the LCD), vpot
    /// press instantiates. Leaving to the pan view cancels a browse safely.
    /// Returns nil when the MCU route is unavailable.
    static func addPluginViaBrowser(
        pluginName: String, logic: LogicAccessibility, trackName: String
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        // The PL channel view shows the MCU-SELECTED track's inserts without
        // naming it — and MCU selection can diverge from the AX selection
        // (this once put plugins on Stereo Out). Bind the MCU selection to
        // the target track explicitly before entering the view.
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard let inserts = try pluginInsertNames() else { return nil }
        guard let emptyIndex = inserts.firstIndex(where: { $0.isEmpty || $0 == "--" }) else {
            throw DemoError.trackNotExposed(
                requested: "an empty insert slot",
                exposed: "all 8 MCU insert slots are occupied"
            )
        }
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            let start = bottom.index(bottom.startIndex, offsetBy: min(emptyIndex * 7, bottom.count))
            // The name spills over several LCD fields; cut at the first long
            // gap so trailing slot fields do not leak into it.
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return cut.trimmingCharacters(in: .whitespaces)
        }
        func matches(_ shown: String) -> Bool {
            // LCD shows e.g. "Compressor (s/s)"; strip the channel suffix and
            // compare prefixes both ways (either side may be truncated).
            let cleaned = shown.replacingOccurrences(
                of: #"\s*\([sm]/[sm]\)\s*$"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return false }
            let target = pluginName.trimmingCharacters(in: .whitespaces)
            return cleaned.lowercased() == target.lowercased()
                || cleaned.lowercased().hasPrefix(target.lowercased())
                || target.lowercased().hasPrefix(cleaned.lowercased())
        }
        func abortBrowse() {
            exitToPan()
        }
        // The LCD advances only every other vpot tick, so consecutive
        // duplicate names mean "not moved yet", not a wrap. A wrap is the
        // FIRST entry reappearing after real progress.
        var entries: [String] = []
        var found = false
        for step in 0..<500 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            // The list advances one entry per TWO vpot ticks — send both at once.
            let response = try MCUBridge.send(["cmd": "vpot", "index": emptyIndex, "delta": 2])
            guard response["ok"] as? Bool == true else { abortBrowse(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            guard let name = browseName(), !name.isEmpty, name != "--" else { continue }
            if matches(name) { found = true; break }
            if name == entries.last { continue }
            if let first = entries.first, name == first, entries.count > 2 {
                abortBrowse()
                throw DemoError.trackNotExposed(
                    requested: "plugin '\(pluginName)' in the control-surface browser",
                    exposed: "the browser wrapped around without a match; entries seen: \(entries.joined(separator: ", "))"
                )
            }
            entries.append(name)
        }
        guard found else {
            abortBrowse()
            throw DemoError.openVerificationFailed(
                "the plugin browser never showed '\(pluginName)' within 250 steps"
            )
        }
        // The display can advance one more entry after the matching read
        // (trailing sysex from the double-tick) — settle and re-verify that
        // the shown entry is STILL the target before confirming anything.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.3)
        // The double-tick stepping tends to drift one entry past the match —
        // correct by stepping back until the target is shown again.
        var settledName = browseName()
        var corrections = 0
        while let drifted = settledName, !matches(drifted), corrections < 4 {
            _ = try? MCUBridge.send(["cmd": "vpot", "index": emptyIndex, "delta": -2])
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            settledName = browseName()
            corrections += 1
        }
        guard let settled = settledName, matches(settled) else {
            abortBrowse()
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' shown at confirmation time",
                actual: "the browser entry drifted to '\(browseName() ?? "?")' and back-stepping could not recover it; aborted without instantiating",
                restored: true
            )
        }
        let shownName = settled
        // Confirm: vpot press instantiates and drops into the edit view.
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": emptyIndex])
        guard response["ok"] as? Bool == true else { abortBrowse(); return nil }
        Thread.sleep(forTimeInterval: 1.0)
        _ = quiescentStatus()
        // Verify: back in the plugin list the slot is occupied.
        guard let after = try pluginInsertNames() else { return nil }
        let slotName = after.indices.contains(emptyIndex)
            ? after[emptyIndex].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            : ""
        exitToPan()
        guard !slotName.isEmpty, slotName != "--" else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' instantiated in slot \(emptyIndex + 1)",
                actual: "the slot still shows empty after confirmation",
                restored: false
            )
        }
        // Cross-verify through Accessibility — an independent source that
        // names the track, so a wrong-channel insertion cannot pass silently.
        var axConfirmed = false
        for _ in 0..<10 {
            if let axInserts = (try? logic.listInserts(trackName: trackName))?["inserts"]
                as? [[String: Any]] {
                let names = axInserts.compactMap { $0["plugin_display_name"] as? String }
                if names.contains(where: {
                    $0.lowercased().hasPrefix(pluginName.lowercased())
                        || pluginName.lowercased().hasPrefix(
                            $0.trimmingCharacters(in: .whitespaces).lowercased())
                }) {
                    axConfirmed = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard axConfirmed else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' on track '\(trackName)' (AX cross-check)",
                actual: "the LCD claimed success but the track's AX insert list never showed the plugin — it may have landed on another channel; check the mixer",
                restored: false
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "added",
            "plugin": pluginName,
            "browser_entry": shownName,
            "mcu_slot": emptyIndex + 1,
            "write_route": "mcu_plugin_browser",
            "note": "Added via the control-surface plugin browser — no mouse, no menus."
        ]
    }

    /// Removes a plugin mouse-free: browse the occupied slot to the "--"
    /// (No Plug-in) entry at the list boundary and confirm. The boundary can
    /// be up to a full list away (~100 entries), so this takes up to ~60 s —
    /// still no pointer, no menus. Returns nil when MCU is unavailable.
    static func removePluginViaBrowser(
        pluginName: String, logic: LogicAccessibility, trackName: String
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard let inserts = try pluginInsertNames() else { return nil }
        // Match the target slot by LCD name (truncated) against the request.
        let matches = inserts.enumerated().filter { _, name in
            let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !cleaned.isEmpty, cleaned != "--" else { return false }
            return lcdNameMatches(track: pluginName, lcd: cleaned)
                || pluginName.lowercased().hasPrefix(cleaned.lowercased())
        }
        guard matches.count == 1, let target = matches.first else {
            exitToPan()
            throw DemoError.trackNotExposed(
                requested: "exactly one insert matching '\(pluginName)'",
                exposed: "MCU slots: " + inserts.enumerated()
                    .map { "\($0 + 1): \($1.isEmpty ? "--" : $1)" }.joined(separator: ", ")
            )
        }
        let slotIndex = target.offset
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            let start = bottom.index(bottom.startIndex, offsetBy: min(slotIndex * 7, bottom.count))
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return cut.trimmingCharacters(in: .whitespaces)
        }
        // Browse backward toward the "--" boundary entry.
        var reached = false
        for step in 0..<400 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(["cmd": "vpot", "index": slotIndex, "delta": -2])
            guard response["ok"] as? Bool == true else { exitToPan(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            if browseName() == "--" { reached = true; break }
        }
        guard reached else {
            exitToPan()
            throw DemoError.openVerificationFailed(
                "the browser never reached the No Plug-in entry within 400 steps; nothing was changed (browse abandoned)"
            )
        }
        // Settle and re-verify "--" is still shown before confirming.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.3)
        var corrections = 0
        while browseName() != "--", corrections < 4 {
            _ = try? MCUBridge.send(["cmd": "vpot", "index": slotIndex, "delta": 2])
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            corrections += 1
        }
        guard browseName() == "--" else {
            exitToPan()
            throw DemoError.verificationFailed(
                requested: "the No Plug-in entry shown at confirmation time",
                actual: "the entry drifted to '\(browseName() ?? "?")'; aborted without removing",
                restored: true
            )
        }
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": slotIndex])
        guard response["ok"] as? Bool == true else { exitToPan(); return nil }
        Thread.sleep(forTimeInterval: 1.0)
        _ = quiescentStatus()
        guard let after = try pluginInsertNames() else { return nil }
        exitToPan()
        let nowEmpty = !after.indices.contains(slotIndex)
            || after[slotIndex].isEmpty || after[slotIndex] == "--"
        // AX cross-check: the plugin must be gone from the track's inserts.
        var axGone = false
        for _ in 0..<10 {
            if let axInserts = (try? logic.listInserts(trackName: trackName))?["inserts"]
                as? [[String: Any]] {
                let names = axInserts.compactMap { $0["plugin_display_name"] as? String }
                if !names.contains(where: {
                    $0.lowercased().hasPrefix(pluginName.lowercased())
                        || pluginName.lowercased().hasPrefix(
                            $0.trimmingCharacters(in: .whitespaces).lowercased())
                }) {
                    axGone = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard nowEmpty, axGone else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' removed from '\(trackName)'",
                actual: nowEmpty
                    ? "the LCD slot cleared but AX still lists the plugin"
                    : "the LCD slot still shows '\(after[slotIndex])'",
                restored: false
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "removed",
            "plugin": pluginName,
            "mcu_slot": slotIndex + 1,
            "write_route": "mcu_plugin_browser",
            "note": "Removed via the control-surface plugin browser's No Plug-in entry — no mouse, no menus."
        ]
    }

    // MARK: Sends (assign_send channel view, assignment code "SE")

    /// The selected track's sends laid out as 4 fields per send, 2 sends per
    /// page: SenNIn (destination), Send N (level), SenNPo (position),
    /// SenNMu (status). NOTE: the multi-channel send view (code "S1") puts
    /// DESTINATION on the vpots — never turn vpots there.
    static func ensureSendView() throws -> Bool {
        for _ in 0..<4 {
            guard let status = freshStatus(),
                  let assignment = status["assignment"] as? String else { return false }
            if assignment == "SE" { return true }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_send")
            _ = awaitEvents(since: before, timeoutMs: 400)
            _ = quiescentStatus()
        }
        return (freshStatus()?["assignment"] as? String) == "SE"
    }

    private static func sendViewLeftmost() throws {
        for _ in 0..<4 {
            try pressNote(0x62)
            Thread.sleep(forTimeInterval: 0.15)
        }
        _ = quiescentStatus()
    }

    /// Pages the send channel view to the page holding the given send slot.
    static func sendViewToPage(forSend send: Int) throws {
        try sendViewLeftmost()
        for _ in 0..<((send - 1) / 2) {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
    }

    /// Walks the plugin-edit parameter pages until the named parameter is on
    /// screen; returns its vpot index and LEAVES the view on that page.
    static func locateParameter(named name: String) throws -> Int? {
        let total = try normalizeToPageOne()
        for page in 1...max(total, 1) {
            if let entries = settledParameterPage() {
                for (index, entry) in entries.enumerated() where !entry.name.isEmpty {
                    if entry.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                        || lcdNameMatches(track: name, lcd: entry.name) {
                        return index
                    }
                }
            }
            if page < max(total, 1) { try pageRight() }
        }
        return nil
    }

    /// Reads all sends of the selected track. Returns nil when the MCU route
    /// is unavailable; an empty array when the track simply has no sends.
    static func readSends() throws -> [[String: Any]]? {
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        var sends: [[String: Any]] = []
        for page in 0..<4 {
            guard let fields = parameterPage() else { break }
            var pageHadSend = false
            for half in 0..<2 {
                let base = half * 4
                let number = page * 2 + half + 1
                guard fields[base].name.hasPrefix("Sen") else { continue }
                let destination = fields[base].value
                guard !destination.isEmpty, destination != "--" else { continue }
                pageHadSend = true
                sends.append([
                    "send": number,
                    "destination": destination,
                    "level": fields[base + 1].value,
                    "position": fields[base + 2].value,
                    "status": fields[base + 3].value
                ])
            }
            if !pageHadSend { break }
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        return sends
    }

    /// Sets one send's level in dB by converging its vpot against the LCD
    /// echo, with the same compare-and-set/readback discipline as the plugin
    /// parameters. Touches ONLY the level vpot, never the destination.
    static func setSendLevel(
        sendNumber: Int, targetDb: Double, expectedCurrentValue: String?
    ) throws -> [String: Any]? {
        guard (1...8).contains(sendNumber) else {
            throw DemoError.invalidArguments("send must be 1-8")
        }
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        let page = (sendNumber - 1) / 2
        for _ in 0..<page {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        guard let fields = parameterPage() else { return nil }
        let base = ((sendNumber - 1) % 2) * 4
        let levelIndex = base + 1
        let destination = fields[base].value
        guard fields[base].name.hasPrefix("Sen"), !destination.isEmpty, destination != "--" else {
            throw DemoError.trackNotExposed(
                requested: "send \(sendNumber)",
                exposed: "the selected track has no send in slot \(sendNumber)"
            )
        }
        guard fields[levelIndex].name == "Send \(sendNumber)" else {
            return nil // unexpected layout: refuse rather than turn a stranger's vpot
        }
        let originalText = fields[levelIndex].value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw DemoError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }
        func currentText() -> String? {
            parameterPage().map { $0[levelIndex].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(["cmd": "vpot", "index": levelIndex, "delta": ticks])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("MCU vpot failed: \(response["error"] ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }
        let finalText = try convergeNumeric(
            target: targetDb,
            tolerance: nil,
            read: { currentText().flatMap(parseNumber) },
            readText: { currentText() },
            turn: turn
        )
        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "send": sendNumber,
            "destination": destination,
            "before": originalText,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

    // MARK: Automation recording (Latch mode + timed absolute fader writes)

    /// Standard Mackie automation-mode buttons; they act on the selected track.
    static func automationModeNote(_ mode: String) -> Int? {
        switch mode.lowercased() {
        case "read": return 0x4A
        case "write": return 0x4B
        case "trim": return 0x4C
        case "touch": return 0x4D
        case "latch": return 0x4E
        default: return nil
        }
    }

    /// Sets the selected track's automation mode via the MCU button and
    /// verifies through the channel strip's mode label ("Latch, automation
    /// enabled") — surface write, Accessibility readback.
    static func setAutomationMode(
        _ mode: String, logic: LogicAccessibility, trackName: String
    ) throws {
        guard let note = automationModeNote(mode) else {
            throw DemoError.invalidArguments("mode must be read/touch/latch/write/trim")
        }
        let response = try MCUBridge.send(["cmd": "press", "note": note])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("automation mode press failed")
        }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.25)
            if let label = logic.automationModeLabel(trackName: trackName),
               label.lowercased().hasPrefix(mode.lowercased()) {
                return
            }
        }
        throw DemoError.verificationFailed(
            requested: "automation mode '\(mode)' on '\(trackName)'",
            actual: "the strip still shows '\(logic.automationModeLabel(trackName: trackName) ?? "?")'",
            restored: false
        )
    }

    private static func currentFader14(_ channel: Int) -> Int? {
        guard let faders = freshStatus()?["faders_14bit"] as? [Int],
              faders.indices.contains(channel), faders[channel] >= 0 else { return nil }
        return faders[channel]
    }

    /// Records a volume automation curve: calibrate each target dB to an
    /// absolute 14-bit fader position (via LCD-converged writes + Logic's own
    /// motorized-fader echo), switch the track to Latch, roll playback and
    /// place the fader at each point's moment, then return to Read and
    /// verify by REPLAYING the range while sampling the fader echo.
    static func recordVolumeAutomation(
        logic: LogicAccessibility,
        trackName: String,
        points: [(bar: Int, beat: Double, db: Double)],
        ramp: Bool,
        verify: Bool
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw DemoError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let beatsPerBar = Double((transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
        let sorted = points.sorted {
            ($0.bar, $0.beat) < ($1.bar, $1.beat)
        }
        guard let first = sorted.first, first.bar >= 2 else {
            throw DemoError.invalidArguments("points need bar >= 2 (one bar of pre-roll)")
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw DemoError.trackNotExposed(
                requested: "MCU channel for '\(trackName)'",
                exposed: "not found in the bank view"
            )
        }
        guard try selectFoundChannel(channel) else {
            throw DemoError.writeFailed("MCU select failed")
        }
        guard let originalFader = currentFader14(channel) else {
            throw DemoError.trackNotExposed(
                requested: "the track's fader echo",
                exposed: "Logic has not reported fader positions for this bank yet"
            )
        }

        // Calibrate: unique dB targets -> absolute fader values, then restore.
        var calibration: [Double: Int] = [:]
        for db in Set(sorted.map(\.db)) {
            guard try setVolume(trackName: trackName, targetDb: db, toleranceDb: 0.15) != nil,
                  let position = currentFader14(channel) else {
                _ = try? MCUBridge.send(["cmd": "fader", "channel": channel, "value": originalFader])
                throw DemoError.verificationFailed(
                    requested: "calibration of \(db) dB",
                    actual: "volume converge or fader echo failed; original volume restored",
                    restored: true
                )
            }
            calibration[db] = position
        }
        _ = try? MCUBridge.send(["cmd": "fader", "channel": channel, "value": originalFader])
        Thread.sleep(forTimeInterval: 0.3)

        // Timed schedule relative to the crossing into the first point's bar.
        let msPerBeat = 60000.0 / tempo
        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            (Double(bar - first.bar) * beatsPerBar + (beat - 1)) * msPerBeat
        }
        var schedule: [(ms: Double, value: Int)] = sorted.map {
            (offsetMs($0.bar, $0.beat), calibration[$0.db] ?? originalFader)
        }
        if ramp && sorted.count > 1 {
            var expanded: [(Double, Int)] = []
            for index in 0..<(sorted.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                let steps = max(Int((b.ms - a.ms) / (msPerBeat / 2)), 1)
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Double(s) / Double(steps)
                        expanded.append((a.ms + (b.ms - a.ms) * t,
                                         Int(Double(a.value) + Double(b.value - a.value) * t)))
                    }
                }
            }
            expanded.append(schedule[schedule.count - 1])
            schedule = expanded
        }

        try setAutomationMode("latch", logic: logic, trackName: trackName)
        var report: [String: Any] = [:]
        do {
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.5)
            guard (try? setPlaying(true)) != nil else {
                throw DemoError.writeFailed("play failed")
            }
            // Sync: the timecode crossing into the first bar.
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let bar = timecodeBar(), bar >= first.bar { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw DemoError.verificationFailed(
                    requested: "playback reaching bar \(first.bar)",
                    actual: "the timecode never got there", restored: false
                )
            }
            for entry in schedule {
                let wait = entry.ms / 1000 - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                _ = try MCUBridge.send(["cmd": "fader", "channel": channel, "value": entry.value])
            }
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? setPlaying(false)
            try setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? MCUBridge.send(["cmd": "fader", "channel": channel, "value": originalFader])
        } catch {
            _ = try? setPlaying(false)
            _ = try? setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? MCUBridge.send(["cmd": "fader", "channel": channel, "value": originalFader])
            throw error
        }

        report["success"] = true
        report["state"] = "recorded"
        report["points"] = sorted.map { ["bar": $0.bar, "beat": $0.beat, "db": $0.db] }
        report["ramp"] = ramp
        report["write_route"] = "mcu_fader_latch"

        if verify {
            // Replay in Read and sample Logic's own fader echo at each point.
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.4)
            _ = try? setPlaying(true)
            var samples: [[String: Any]] = []
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let bar = timecodeBar(), bar >= first.bar { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let start = anchor {
                for point in sorted {
                    let sampleAt = offsetMs(point.bar, point.beat) / 1000 + 0.25
                    let wait = sampleAt - Date().timeIntervalSince(start)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    let observed = currentFader14(channel) ?? -1
                    let expected = calibration[point.db] ?? -1
                    samples.append([
                        "bar": point.bar, "beat": point.beat, "db": point.db,
                        "expected_fader": expected,
                        "observed_fader": observed,
                        "pass": observed >= 0 && abs(observed - expected) <= 500
                    ])
                }
            }
            _ = try? setPlaying(false)
            _ = try? MCUBridge.send(["cmd": "fader", "channel": channel, "value": originalFader])
            let allPass = !samples.isEmpty && samples.allSatisfy { $0["pass"] as? Bool == true }
            report["verified"] = allPass
            report["verification"] = [
                "samples": samples,
                "note": "The range was replayed in Read mode and Logic's own motorized-fader echo sampled at each point (14-bit positions; tolerance 500 ≈ 1.5 dB near unity)."
            ]
        } else {
            report["verified"] = false
        }
        return report
    }

    // MARK: Vpot automation (pan / send / plugin parameters)

    /// Sends a relative vpot move of any size (the wire format caps one
    /// message at 63 ticks).
    private static func turnVpot(_ index: Int, by delta: Int) throws {
        var remaining = delta
        while remaining != 0 {
            let chunk = max(-63, min(63, remaining))
            let response = try MCUBridge.send(["cmd": "vpot", "index": index, "delta": chunk])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("vpot failed mid-automation")
            }
            remaining -= chunk
        }
    }

    /// One quick "land on target" pass for a relative encoder during
    /// playback: a calibrated blind jump followed by up to two echo-checked
    /// corrections, all inside a small time budget so the point does not
    /// smear across the timeline.
    private static func vpotJump(
        index: Int, target: Double, ticksPerUnit: Double,
        read: () -> Double?, budget: TimeInterval
    ) throws {
        // ADAPTIVE ratio: encoder scales are nonlinear (a dB near -inf is a
        // fraction of a tick; near unity several ticks), so the seed ratio
        // from the initial probe is only a starting guess — every turn's
        // observed movement refines it.
        let deadline = Date().addingTimeInterval(budget)
        var ratio = ticksPerUnit
        guard var current = read() else { return }
        while true {
            let step = abs(0.5 / max(abs(ratio), 0.01))
            if abs(current - target) <= step { return }
            var ticks = Int(((target - current) * ratio).rounded())
            if ticks == 0 {
                ticks = (target - current) * ratio > 0 ? 1 : -1
            }
            try turnVpot(index, by: ticks)
            guard Date() < deadline else { return }
            Thread.sleep(forTimeInterval: 0.12)
            guard let now = read() else { return }
            let change = now - current
            if abs(change) > 0.0001, ticks != 0 {
                let observedRatio = Double(ticks) / change
                if observedRatio.isFinite, abs(observedRatio) < 1000 {
                    ratio = 0.5 * ratio + 0.5 * observedRatio
                }
            }
            current = now
        }
    }

    /// Builds a write closure for a vpot-controlled value: probes the
    /// encoder's ticks-per-unit once, then lands on targets with a blind
    /// calibrated jump plus up to two echo-checked corrections.
    static func makeVpotWriter(
        index: Int, read: @escaping () -> Double?
    ) throws -> (Double, TimeInterval) throws -> Void {
        var current: Double?
        for _ in 0..<12 {
            if let value = read() { current = value; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let origin = current else {
            throw DemoError.trackNotExposed(requested: "a readable vpot echo", exposed: "none")
        }
        try turnVpot(index, by: 4)
        Thread.sleep(forTimeInterval: 0.35)
        guard let probed = read(), abs(probed - origin) > 0.0001 else {
            throw DemoError.verificationFailed(
                requested: "a vpot probe response",
                actual: "the value did not move on a 4-tick probe",
                restored: false
            )
        }
        let ticksPerUnit = 4.0 / (probed - origin)
        try turnVpot(index, by: -4) // undo the probe
        Thread.sleep(forTimeInterval: 0.2)
        return { target, budget in
            try vpotJump(index: index, target: target, ticksPerUnit: ticksPerUnit,
                         read: read, budget: budget)
        }
    }

    /// Records an automation curve for a vpot-controlled value (pan, a send
    /// level, or a plugin parameter): measure the encoder's ticks-per-unit
    /// near the working range, converge to the first point, switch to Latch,
    /// roll playback placing calibrated jumps at each musical moment, return
    /// to Read, restore the original value, and verify by replaying while
    /// sampling the LCD echo.
    static func recordVpotAutomation(
        logic: LogicAccessibility,
        trackName: String,
        kindLabel: String,
        points: [(bar: Int, beat: Double, value: Double)],
        ramp: Bool,
        verify: Bool,
        tolerance: Double,
        enterView: (Int) throws -> (read: () -> Double?, write: (Double, TimeInterval) throws -> Void),
        refreshView: (() throws -> Void)? = nil,
        restoreView: @escaping () -> Void
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw DemoError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let beatsPerBar = Double((transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
        let sorted = points.sorted { ($0.bar, $0.beat) < ($1.bar, $1.beat) }
        guard let first = sorted.first, first.bar >= 2 else {
            throw DemoError.invalidArguments("points need bar >= 2 (one bar of pre-roll)")
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw DemoError.trackNotExposed(
                requested: "MCU channel for '\(trackName)'", exposed: "not in the bank view"
            )
        }
        guard try selectFoundChannel(channel) else {
            throw DemoError.writeFailed("MCU select failed")
        }
        let view = try enterView(channel)
        defer { restoreView() }
        // The control repaints for a moment after a view switch — poll patiently.
        var initial: Double?
        for _ in 0..<12 {
            if let value = view.read() { initial = value; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let original = initial else {
            throw DemoError.trackNotExposed(
                requested: "a readable \(kindLabel) value", exposed: "no echo after 3 s"
            )
        }
        // Park on the first point's value before rolling.
        try view.write(first.value, 2.0)

        let msPerBeat = 60000.0 / tempo
        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            (Double(bar - first.bar) * beatsPerBar + (beat - 1)) * msPerBeat
        }
        var schedule: [(ms: Double, value: Double)] = sorted.map {
            (offsetMs($0.bar, $0.beat), $0.value)
        }
        if ramp && schedule.count > 1 {
            var expanded: [(Double, Double)] = []
            for index in 0..<(schedule.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                let steps = max(Int((b.ms - a.ms) / msPerBeat), 1) // 1 delvärde/slag
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Double(s) / Double(steps)
                        expanded.append((a.ms + (b.ms - a.ms) * t, a.value + (b.value - a.value) * t))
                    }
                }
            }
            expanded.append(schedule[schedule.count - 1])
            schedule = expanded
        }

        try setAutomationMode("latch", logic: logic, trackName: trackName)
        do {
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.5)
            let parkedTimecode = freshStatus()?["timecode"] as? String
            guard (try? setPlaying(true)) != nil else {
                throw DemoError.writeFailed("play failed")
            }
            // Anchor at ROLL START (the parked bar), not at the first point's
            // bar crossing: the whole pre-roll bar is then usable for the
            // first point's convergence lead.
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let timecode = freshStatus()?["timecode"] as? String,
                   timecode != parkedTimecode { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw DemoError.verificationFailed(
                    requested: "playback rolling from bar \(first.bar - 1)",
                    actual: "the timecode never moved", restored: false
                )
            }
            let preRollMs = beatsPerBar * msPerBeat // one bar before the first point
            for (position, entry) in schedule.enumerated() {
                // Vpot convergence takes time — lead each write so the curve
                // centers on the musical moment instead of trailing it. The
                // FIRST point gets a long lead and a full budget: an existing
                // lane can start playback far from the target (overriding the
                // pre-parked static value), and the anchor must be converged
                // BEFORE its moment arrives.
                let isFirst = position == 0
                let isLast = position == schedule.count - 1
                let lead = isFirst ? 1.2 : 0.35
                let wait = (preRollMs + entry.ms) / 1000 - lead - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if isFirst, let current = view.read(), abs(current - entry.value) < 0.01 {
                    // Latch only writes on a TOUCH: already on target means
                    // nothing would be recorded — wiggle to anchor the curve.
                    try view.write(entry.value - 1, 0.25)
                }
                try view.write(entry.value,
                               isFirst ? 1.0 : (isLast ? 1.5 : max(0.15, min(0.6, msPerBeat / 2000))))
            }
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? setPlaying(false)
            try setAutomationMode("read", logic: logic, trackName: trackName)
            try view.write(original, 2.0)
        } catch {
            _ = try? setPlaying(false)
            _ = try? setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? view.write(original, 2.0)
            throw error
        }

        var report: [String: Any] = [
            "success": true,
            "state": "recorded",
            "parameter": kindLabel,
            "points": sorted.map { ["bar": $0.bar, "beat": $0.beat, "value": $0.value] },
            "ramp": ramp,
            "write_route": "mcu_vpot_latch"
        ]
        if verify {
            // The automation-mode button presses can knock the surface out of
            // the working view — re-enter it before reading anything.
            try refreshView?()
            // Playhead-chase verification: parked in Read mode, Logic chases
            // the automation lane to the playhead position — stationary,
            // exact reads with no live-LCD lag, and no realtime replay.
            var samples: [[String: Any]] = []
            for point in sorted {
                _ = try? logic.setPlayhead(
                    barNumber: point.bar, beat: max(Int(point.beat.rounded()), 1)
                )
                Thread.sleep(forTimeInterval: 0.8)
                let observed = view.read()
                samples.append([
                    "bar": point.bar, "beat": point.beat,
                    "expected": point.value,
                    "observed": observed.map { $0 as Any } ?? NSNull() as Any,
                    "pass": observed.map { abs($0 - point.value) <= tolerance } ?? false
                ])
            }
            _ = try? view.write(original, 2.0)
            let allPass = !samples.isEmpty && samples.allSatisfy { $0["pass"] as? Bool == true }
            report["verified"] = allPass
            report["verification"] = [
                "samples": samples,
                "tolerance": tolerance,
                "note": "Verified by parking the playhead at each point in Read mode and reading the automation-chased value."
            ]
        } else {
            report["verified"] = false
        }
        return report
    }

    // MARK: MIDI recording (composition via the "Logic MCP MIDI In" port)

    /// Current bar from the MCU timecode display (BBB bb dd ttt layout).
    static func timecodeBar() -> Int? {
        guard let timecode = freshStatus()?["timecode"] as? String, timecode.count >= 3 else {
            return nil
        }
        return Int(timecode.prefix(3).trimmingCharacters(in: .whitespaces))
    }

    static func timecodeBarBeat() -> (bar: Int, beat: Int)? {
        guard let timecode = freshStatus()?["timecode"] as? String, timecode.count >= 5 else {
            return nil
        }
        guard let bar = Int(timecode.prefix(3).trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let beat = Int(timecode.dropFirst(3).prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1
        return (bar, beat)
    }

    /// Records composed notes onto the selected track by streaming them over
    /// the plain "Logic MCP MIDI In" port while Logic records: playhead is
    /// parked one bar early, record is pressed, and the stream starts on the
    /// observed timecode crossing into start_bar — so count-in settings do
    /// not matter. Wholly data-plane: no dialogs, no files, no keypresses.
    static func recordMIDI(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        events: [(offsetMs: Double, bytes: [UInt8])],
        startBar: Int, tailMs: Double,
        tempo: Double, beatsPerBar: Double, syncCompensationMs: Double
    ) throws -> [String: Any] {
        guard startBar >= 2 else {
            throw DemoError.invalidArguments(
                "start_bar must be >= 2 (one bar of pre-roll is needed for the timecode sync)"
            )
        }
        guard freshStatus() != nil else {
            throw DemoError.trackNotExposed(
                requested: "MCU bridge for MIDI recording",
                exposed: "the bridge is not running or Logic has not connected"
            )
        }
        _ = try? setPlaying(false)
        let transport = try logic.getTransport()
        let savedBar = transport["playhead_bar"] as? Int

        var selected = false
        if let channel = ((try? findChannel(trackName: trackName)) ?? nil) {
            selected = (try? selectFoundChannel(channel)) == true
        }
        if !selected {
            _ = try logic.selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }

        _ = try logic.setPlayhead(barNumber: startBar - 1, beat: nil)
        // A record press within ~0.5 s of the playhead LCD converge gets
        // swallowed by Logic while the field is still hot — settle first.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.6)
        try press("record")
        defer {
            _ = try? MCUBridge.send(["cmd": "midi_abort"]) // stuck-note safety
            _ = try? setPlaying(false)
            if let bar = savedBar {
                _ = try? logic.setPlayhead(barNumber: bar, beat: nil)
            }
        }
        // Record LED confirms Logic is actually rolling/armed.
        guard pollStatus(until: { ledLit(0x5F, in: $0) }) != nil else {
            throw DemoError.verificationFailed(
                requested: "recording started",
                actual: "the MCU record LED never lit",
                restored: true
            )
        }
        // Sync on the timecode crossing into the LAST BEAT of the pre-roll
        // bar: from there exactly one beat remains to start_bar, so events
        // are scheduled one beat ahead minus the measured display latency
        // (~50 ms edge-detect lag when syncing on the bar line itself).
        let msPerBeat = 60000.0 / tempo
        let lastBeat = max(Int(beatsPerBar.rounded()), 1)
        let syncDeadline = Date().addingTimeInterval(20)
        var leadMs = 0.0
        var synced = false
        // The parked display can already read e.g. "beat 4" from an earlier
        // stop (setPlayhead only converges the bar), so no edge may be
        // accepted until the timecode has visibly CHANGED — proof that the
        // transport is rolling, after which beat values are trustworthy.
        let parkedTimecode = freshStatus()?["timecode"] as? String
        var rolling = false
        var recordRetried = false
        let rollDeadline = Date().addingTimeInterval(4)
        while Date() < syncDeadline {
            if !rolling {
                let current = freshStatus()?["timecode"] as? String
                if current != nil, current != parkedTimecode { rolling = true }
                else {
                    // Swallowed record press: try once more if nothing rolls.
                    if !recordRetried, Date() > rollDeadline {
                        recordRetried = true
                        try press("record")
                    }
                    Thread.sleep(forTimeInterval: 0.005); continue
                }
            }
            if let position = timecodeBarBeat() {
                if position.bar >= startBar {
                    synced = true // missed the beat edge; fall back to the bar line
                    break
                }
                if position.bar == startBar - 1, position.beat >= lastBeat {
                    synced = true
                    leadMs = msPerBeat
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard synced else {
            throw DemoError.verificationFailed(
                requested: "playhead reaching bar \(startBar)",
                actual: "the timecode never crossed into the start bar within 20 s",
                restored: true
            )
        }
        let shiftMs = max(0, leadMs - syncCompensationMs)
        let streamResponse = try MCUBridge.send([
            "cmd": "midi_stream",
            "events": events.map { event -> [Any] in
                [event.offsetMs + shiftMs] + event.bytes.map { Int($0) }
            }
        ])
        guard streamResponse["ok"] as? Bool == true,
              let durationMs = streamResponse["duration_ms"] as? Int else {
            throw DemoError.writeFailed(
                "midi_stream failed: \(streamResponse["error"] ?? "?")"
            )
        }
        Thread.sleep(forTimeInterval: (Double(durationMs) + tailMs) / 1000)
        // defer handles abort, stop and playhead restore
        return [
            "success": true,
            "events_streamed": events.count,
            "stream_duration_ms": durationMs,
            "write_route": "midi_in_record"
        ]
    }

    /// Track-level A/B: two freeze renders around one verified MCU parameter
    /// change, compared on the sliced bar range. Isolates the change to ONE
    /// track's output (no master bus in the way) and never plays back.
    static func evaluateChangeRendered(
        logic: LogicAccessibility,
        trackName: String, trackNumber: Int?,
        insertSlot: Int, parameter: String,
        expectedCurrentValue: String, targetValue: String,
        startBar: Int, endBar: Int,
        startSeconds: Double, endSeconds: Double,
        tempo: Double,
        keepChange: Bool
    ) throws -> [String: Any] {
        let projectPath = try logic.projectDocumentPath()
        if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
           let header = tracks.first(where: {
               ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
           }),
           header["is_stack"] as? Bool == true {
            throw DemoError.trackNotExposed(
                requested: "render A/B of '\(trackName)'",
                exposed: "'\(trackName)' is a track stack — Logic cannot freeze stacks; evaluate on a subtrack or use method 'bounce'"
            )
        }
        // Select once; both renders and the parameter writes act on the
        // selected track.
        var selected = false
        if let channel = ((try? findChannel(trackName: trackName)) ?? nil) {
            selected = (try? selectFoundChannel(channel)) == true
        }
        if !selected {
            _ = try logic.selectTrack(
                trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil
            )
        }

        let renderA = try renderSelectedTrack(
            projectPath: projectPath, label: "\(trackName.lowercased())-a",
            sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
            logic: logic, trackName: trackName
        )
        guard let change = try setPluginParameter(
            slot: insertSlot, parameter: parameter,
            targetValue: targetValue, expectedCurrentValue: expectedCurrentValue,
            tolerance: nil
        ) else {
            throw DemoError.trackNotExposed(
                requested: "MCU write of '\(parameter)' in slot \(insertSlot)",
                exposed: "the MCU bridge could not resolve the parameter; nothing was changed (baseline render A kept)"
            )
        }
        let appliedValue = change["after"] as? String ?? targetValue
        let beforeValue = change["before"] as? String ?? expectedCurrentValue

        // Rolling back must survive the transient MCU/plugin-reload window
        // right after an unfreeze: retry with quiescence, and drop the
        // compare-and-set on the final attempt (we verified the applied
        // value moments ago; restoring wins over re-checking).
        func rollBack() -> Bool {
            for attempt in 0..<3 {
                if attempt > 0 {
                    _ = quiescentStatus()
                    Thread.sleep(forTimeInterval: 1.0)
                }
                let expected = attempt < 2 ? appliedValue : nil
                if ((try? setPluginParameter(
                    slot: insertSlot, parameter: parameter,
                    targetValue: beforeValue, expectedCurrentValue: expected,
                    tolerance: nil
                )) ?? nil) != nil {
                    return true
                }
            }
            return false
        }

        let renderB: [String: Any]
        do {
            renderB = try renderSelectedTrack(
                projectPath: projectPath, label: "\(trackName.lowercased())-b",
                sliceStartSeconds: startSeconds, sliceEndSeconds: endSeconds,
                logic: logic, trackName: trackName
            )
        } catch {
            // Never leave the change in place after a failed B render.
            _ = rollBack()
            throw error
        }

        var decision = "kept"
        var restored = true
        if !keepChange {
            if rollBack() {
                decision = "rolled_back"
            } else {
                decision = "rollback_failed"
                restored = false
            }
        }

        func sliceMetrics(_ render: [String: Any]) -> [String: Any]? {
            (render["slice"] as? [String: Any])?["metrics"] as? [String: Any]
        }
        let metricsA = sliceMetrics(renderA)
        let metricsB = sliceMetrics(renderB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        return [
            "success": true,
            "verified": restored || keepChange,
            "state": "evaluated",
            "method": "render",
            "decision": decision,
            "change": [
                "track": trackName, "insert_slot": insertSlot, "parameter": parameter,
                "before": beforeValue, "applied": appliedValue
            ],
            "range": ["start_bar": startBar, "end_bar": endBar, "tempo": tempo],
            "baseline_audio": (renderA["slice"] as? [String: Any])?["path"] ?? renderA["path"] ?? NSNull(),
            "after_audio": (renderB["slice"] as? [String: Any])?["path"] ?? renderB["path"] ?? NSNull(),
            "baseline_full_audio": renderA["path"] ?? NSNull(),
            "after_full_audio": renderB["path"] ?? NSNull(),
            "baseline_metrics": metricsA ?? NSNull(),
            "after_metrics": metricsB ?? NSNull(),
            "deltas": deltas,
            "note": "Two dialog-free freeze renders of this single track, compared on the sliced bar range only. No playback occurred."
        ]
    }

    /// The selected track's insert slots as shown on the MCU (physical slot
    /// numbering, which can differ from the AX occupied-slot ordinals).
    static func pluginInsertNames() throws -> [String]? {
        guard let status = try ensurePluginList(),
              let bottom = status["lcd_bottom"] as? String else { return nil }
        return lcdFields(bottom)
    }

    static func enterPluginEdit(slot: Int) throws -> Bool {
        guard (1...8).contains(slot) else { return false }
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": slot - 1])
        guard response["ok"] as? Bool == true else { return false }
        return waitFor(seconds: 2.5, { status in
            guard let assignment = status["assignment"] as? String,
                  let top = status["lcd_top"] as? String else { return false }
            return assignment == "P\(slot)" && !top.hasPrefix("Ins1Pl")
        }) != nil
    }

    static func parameterPage() -> [(name: String, value: String)]? {
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return nil }
        return zip(lcdFields(top), lcdFields(bottom)).map { ($0, $1) }
    }

    // MARK: Parameter paging (cursor left/right, note 0x62/0x63)

    private static func pressNote(_ note: Int) throws {
        let response = try MCUBridge.send(["cmd": "press", "note": note])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU note press failed: \(response["error"] ?? "?")")
        }
    }

    /// Reads the transient "Page x/y" indicator the LCD shows right after a
    /// cursor press. Returns nil when no indicator is visible.
    private static func pageIndicator() -> (current: Int, total: Int)? {
        guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
        guard let range = top.range(of: #"Page +(\d+)/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = top[range].split(separator: " ").last?.split(separator: "/") ?? []
        guard digits.count == 2, let current = Int(digits[0]), let total = Int(digits[1]) else {
            return nil
        }
        return (current, total)
    }

    /// Waits for the page indicator to fade so all 8 fields hold parameters.
    private static func settledParameterPage() -> [(name: String, value: String)]? {
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            let events = status["received_events"] as? Int ?? -1
            if top.range(of: #"Page +\d+/\d+"#, options: .regularExpression) == nil {
                // quiescent = the indicator faded and Logic stopped redrawing
                if let after = awaitEvents(since: events, timeoutMs: 130),
                   after["timed_out"] as? Bool == true {
                    return parameterPage()
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 400)
        }
        return parameterPage()
    }

    /// Normalizes the edit view to page 1 and returns the page count, using a
    /// harmless cursor_left press to surface the "Page x/y" indicator
    /// (cursor_left on page 1 keeps the parameters unchanged; verified).
    private static func normalizeToPageOne() throws -> Int {
        try pressNote(0x62)
        // The "Page x/y" indicator is drawn in a later sysex than the first
        // redraw event, so wait for it explicitly rather than for any event.
        _ = waitFor(seconds: 0.9) { status in
            (status["lcd_top"] as? String)?
                .range(of: #"Page +\d+/\d+"#, options: .regularExpression) != nil
        }
        guard let indicator = pageIndicator() else {
            return 1 // single-page plugins may show no indicator at all
        }
        for _ in 0..<(indicator.current - 1) {
            let events = freshStatus()?["received_events"] as? Int ?? -1
            try pressNote(0x62)
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return indicator.total
    }

    private static func pageRight() throws {
        let before = freshStatus()?["received_events"] as? Int ?? -1
        try pressNote(0x63)
        _ = awaitEvents(since: before, timeoutMs: 250)
    }

    // MARK: Parameter name cache (names never change per plugin type; only
    // values do — and the LCD's bottom value row is complete immediately,
    // while top-row names hide behind the ~1.3 s "Page x/y" indicator fade).

    private static var nameCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("param-names-cache.json")
    }

    private static func loadNameCache() -> [String: [[String]]] {
        guard let data = try? Data(contentsOf: nameCacheURL),
              let cache = try? JSONDecoder().decode([String: [[String]]].self, from: data) else {
            return [:]
        }
        return cache
    }

    /// Raw 8-field pages read the slow way: waits out the indicator fade so
    /// every name field is visible. Positions and empty fields preserved.
    private static func rawParameterPagesSlow() throws -> [[(name: String, value: String)]]? {
        let total = try normalizeToPageOne()
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...max(total, 1) {
            guard let page = settledParameterPage() else { return nil }
            pages.append(page)
            if pageNumber < max(total, 1) {
                try pageRight()
            }
        }
        return pages
    }

    /// Cold read capped at maxPages: each page costs ~1.7 s (Logic's own
    /// "Page x/y" indicator fade), so an 80-page instrument like Augmented
    /// takes minutes uncapped — and floods the caller with hundreds of
    /// parameters it rarely needs at once. Returns the total page count so
    /// truncation is always explicit. Full (uncapped) reads still populate
    /// the name cache; capped reads do not, so later full reads stay honest.
    static func parameterPagesCapped(
        cacheKey: String?, maxPages: Int
    ) throws -> (pages: [[(name: String, value: String)]], total: Int, truncated: Bool)? {
        // A complete cached name set makes even the full read cheap — use it.
        if let key = cacheKey, let cachedNames = loadNameCache()[key] {
            let walk = min(maxPages, cachedNames.count)
            if let fast = (try? rawParameterPagesFast(cachedNames: cachedNames, limit: walk)) ?? nil {
                // End-overlap dedup only applies when the true last page was read.
                let pages = walk == cachedNames.count
                    ? dedupedPages(fast)
                    : fast.map { page in page.filter { !$0.name.isEmpty } }
                return (pages, cachedNames.count, walk < cachedNames.count)
            }
        }
        let total = try normalizeToPageOne()
        let limit = min(max(total, 1), max(maxPages, 1))
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...limit {
            guard let page = settledParameterPage() else { return nil }
            pages.append(page)
            if pageNumber < limit {
                try pageRight()
            }
        }
        if limit >= max(total, 1), let key = cacheKey {
            var cache = loadNameCache()
            cache[key] = pages.map { $0.map(\.name) }
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: nameCacheURL)
            }
        }
        return (dedupedPages(pages), max(total, 1), limit < max(total, 1))
    }

    /// Raw pages using cached name rows: waits only for the redraw burst per
    /// page, never the indicator fade. Validates the always-visible fields 0-5
    /// against the cache; nil on any mismatch (caller takes the slow path).
    private static func rawParameterPagesFast(
        cachedNames: [[String]], limit: Int? = nil
    ) throws -> [[(name: String, value: String)]]? {
        let total = try normalizeToPageOne()
        guard max(total, 1) == cachedNames.count else { return nil }
        let walkCount = min(limit ?? cachedNames.count, cachedNames.count)
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...walkCount {
            _ = quiescentStatus() // burst settle only
            guard let status = freshStatus(),
                  let top = status["lcd_top"] as? String,
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            let liveNames = lcdFields(top)
            let values = lcdFields(bottom)
            let names = cachedNames[pageNumber - 1]
            guard names.count == 8 else { return nil }
            for index in 0..<6
            where liveNames[index] != names[index]
                && liveNames[index].range(of: #"Page +\d+"#, options: .regularExpression) == nil {
                return nil // layout changed; rescan slowly
            }
            pages.append(zip(names, values).map { ($0, $1) })
            if pageNumber < walkCount {
                try pageRight()
            }
        }
        return pages
    }

    /// Empty-field filtering plus end-aligned last-page overlap dedup.
    private static func dedupedPages(_ raw: [[(name: String, value: String)]]) -> [[(name: String, value: String)]] {
        var pages: [[(name: String, value: String)]] = []
        for (index, page) in raw.enumerated() {
            var entries = page.filter { !$0.name.isEmpty }
            if index == raw.count - 1, raw.count > 1, let previous = pages.last {
                let maxOverlap = min(entries.count, previous.count)
                for candidate in stride(from: maxOverlap, through: 1, by: -1) {
                    if previous.suffix(candidate).elementsEqual(
                        entries.prefix(candidate),
                        by: { $0.name == $1.name && $0.value == $1.value }
                    ) {
                        entries.removeFirst(candidate)
                        break
                    }
                }
            }
            pages.append(entries)
        }
        return pages
    }

    /// All parameter pages, preferring the per-plugin name cache (fast, no
    /// fade waits); the slow path populates the cache for next time.
    static func parameterPages(cacheKey: String? = nil) throws -> [[(name: String, value: String)]]? {
        if let key = cacheKey {
            var cache = loadNameCache()
            if let cachedNames = cache[key],
               let pages = (try? rawParameterPagesFast(cachedNames: cachedNames)) ?? nil {
                return dedupedPages(pages)
            }
            guard let slow = try rawParameterPagesSlow() else { return nil }
            cache[key] = slow.map { $0.map(\.name) }
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: nameCacheURL)
            }
            return dedupedPages(slow)
        }
        guard let slow = try rawParameterPagesSlow() else { return nil }
        return dedupedPages(slow)
    }

    static func parseNumber(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let numeric = normalized.prefix { "+-0123456789.".contains($0) }
        guard !numeric.isEmpty, numeric != "-", numeric != "+" else { return nil }
        return Double(numeric.hasSuffix(".") ? String(numeric.dropLast()) : String(numeric))
    }

    /// Sets one plugin parameter on the selected track by converging a vpot
    /// against the LCD value echo. Handles numeric values adaptively and
    /// steps text/enum values until exact match. The track must already be
    /// selected and the caller provides the MCU (physical) insert slot.
    static func setPluginParameter(
        slot: Int,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let listStatus = try ensurePluginList() else { return nil }
        let slotName = (listStatus["lcd_bottom"] as? String).map {
            lcdFields($0)[slot - 1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        }
        guard try enterPluginEdit(slot: slot) else {
            exitToPan()
            return nil
        }
        defer { exitToPan() }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: slotName.flatMap { $0.isEmpty || $0 == "--" ? nil : $0 }
        ) else { return nil }
        result["insert_slot"] = slot
        return result
    }

    // MARK: Instrument slot (assign_instrument, assignment code "IN")

    /// Enters the instrument edit mode for a track: bank to the track's
    /// channel in the pan view, switch to the instrument bank view, then
    /// vpot-press the channel. Never turns vpots in the bank view (that is
    /// the instrument browser). Returns nil when unavailable/no instrument.
    static func enterInstrumentEdit(trackName: String) throws -> (channel: Int, name: String)? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        try press("assign_instrument")
        guard let inView = waitFor(seconds: 2.0, { ($0["assignment"] as? String) == "IN" }),
              let instrumentBankTop = inView["lcd_top"] as? String else {
            exitToPan()
            return nil
        }
        // Empty instrument slot shows "--"; entering it would be pointless.
        var instrumentName = ""
        if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String {
            instrumentName = lcdFields(bottom)[channel].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if instrumentName.isEmpty || instrumentName == "--" {
                exitToPan()
                return nil
            }
        }
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": channel])
        guard response["ok"] as? Bool == true else {
            exitToPan()
            return nil
        }
        if waitFor(seconds: 2.5, { status in
            guard (status["assignment"] as? String) == "IN",
                  let top = status["lcd_top"] as? String else { return false }
            return top != instrumentBankTop
        }) != nil {
            return (channel, instrumentName)
        }
        exitToPan()
        return nil
    }

    static func setInstrumentParameter(
        trackName: String,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?
    ) throws -> [String: Any]? {
        guard let entered = try enterInstrumentEdit(trackName: trackName) else { return nil }
        defer { exitToPan() }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: "instrument:" + entered.name
        ) else { return nil }
        result["slot_type"] = "instrument"
        return result
    }

    /// Shared core for plugin and instrument edit modes: search every
    /// parameter page for the match, navigate to its page, then converge.
    /// Page read for searching: cached names + instant value row when the
    /// cache matches this plugin, otherwise the fade-waiting settled read.
    private static func pageForSearch(
        cacheKey: String?, pageNumber: Int, totalPages: Int
    ) -> [(name: String, value: String)]? {
        if let key = cacheKey {
            let cached = loadNameCache()[key]
            if let names = cached, names.count == max(totalPages, 1),
               pageNumber <= names.count, names[pageNumber - 1].count == 8 {
                _ = quiescentStatus()
                if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String {
                    return zip(names[pageNumber - 1], lcdFields(bottom)).map { ($0, $1) }
                }
            }
        }
        return settledParameterPage()
    }

    private static func searchAndSetParameter(
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        cacheKey: String? = nil
    ) throws -> [String: Any]? {
        // Search all parameter pages; remember where the match lives.
        let totalPages = try normalizeToPageOne()
        var found: (page: Int, index: Int, name: String, value: String)?
        var duplicates = 0
        var allNames: [String] = []
        for pageNumber in 1...max(totalPages, 1) {
            guard let raw = pageForSearch(
                cacheKey: cacheKey, pageNumber: pageNumber, totalPages: totalPages
            ) else { return nil }
            for (index, entry) in raw.enumerated() where !entry.name.isEmpty {
                allNames.append(entry.name)
                let hit = entry.name.localizedCaseInsensitiveCompare(parameter) == .orderedSame
                    || lcdNameMatches(track: parameter, lcd: entry.name)
                guard hit else { continue }
                if let existing = found {
                    // The end-aligned last page repeats the previous page's tail;
                    // an identical name+value there is the same parameter.
                    if pageNumber == totalPages
                        && existing.name == entry.name && existing.value == entry.value {
                        continue
                    }
                    duplicates += 1
                } else {
                    found = (pageNumber, index, entry.name, entry.value)
                }
            }
            if pageNumber < totalPages { try pageRight() }
        }
        guard duplicates == 0, let match = found else {
            throw DemoError.parameterAmbiguous(
                "\(parameter) (MCU parameters: \(allNames.joined(separator: ", ")))",
                found == nil ? 0 : duplicates + 1
            )
        }
        // Navigate back to the match's page (we are on the last page now).
        for _ in 0..<(max(totalPages, 1) - match.page) {
            try pressNote(0x62)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let landed = pageForSearch(
                  cacheKey: cacheKey, pageNumber: match.page, totalPages: totalPages
              ),
              landed.indices.contains(match.index),
              landed[match.index].name == match.name else {
            throw DemoError.openVerificationFailed(
                "the parameter page shifted while navigating to '\(match.name)'"
            )
        }
        let index = match.index
        let entry = (name: match.name, value: landed[match.index].value)
        let originalText = entry.value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw DemoError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }

        func currentText() -> String? {
            parameterPage().map { $0[index].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(["cmd": "vpot", "index": index, "delta": ticks])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("MCU vpot failed: \(response["error"] ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }

        let finalText: String
        if let targetNumber = parseNumber(targetValue), parseNumber(originalText) != nil {
            finalText = try convergeNumeric(
                target: targetNumber,
                tolerance: tolerance,
                read: { currentText().flatMap(parseNumber) },
                readText: { currentText() },
                turn: turn
            )
        } else {
            finalText = try stepToText(
                target: targetValue,
                original: originalText,
                read: { currentText() },
                turn: turn
            )
        }

        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "parameter_field": entry.name,
            "before": originalText,
            "requested": targetValue,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

    private static func convergeNumeric(
        target: Double,
        tolerance: Double?,
        read: () -> Double?,
        readText: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        guard var current = read() else {
            throw DemoError.openVerificationFailed("the parameter value is not readable on the LCD")
        }
        let original = current
        // Probe with a single tick to learn the parameter's step size.
        var ticksPerUnit = 10.0
        var probed = false
        var effectiveTolerance = tolerance ?? 0.05
        var stuck = 0
        for _ in 0..<36 {
            let difference = target - current
            if abs(difference) <= effectiveTolerance { break }
            let ticks: Int
            if probed {
                ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            } else {
                ticks = 1
            }
            try turn(difference > 0 ? ticks : -ticks)
            guard let updated = read() else { break }
            let moved = abs(updated - current)
            if moved < 1e-9 {
                stuck += 1
                if stuck >= 3 {
                    _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
                    throw DemoError.verificationFailed(
                        requested: "\(target)",
                        actual: "parameter stuck at \(updated)",
                        restored: true
                    )
                }
            } else {
                stuck = 0
                ticksPerUnit = min(400, max(0.2, Double(ticks) / moved))
                if !probed {
                    probed = true
                    if tolerance == nil {
                        effectiveTolerance = max(moved * 0.55, 0.0001)
                    }
                }
            }
            current = updated
        }
        guard abs(current - target) <= effectiveTolerance * 2 else {
            _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
            throw DemoError.verificationFailed(
                requested: "\(target)",
                actual: "\(current)",
                restored: true
            )
        }
        return readText() ?? "\(current)"
    }

    private static func convergeBack(
        to original: Double,
        ticksPerUnit: Double,
        read: () -> Double?,
        turn: (Int) throws -> Void
    ) throws {
        for _ in 0..<24 {
            guard let current = read() else { return }
            let difference = original - current
            if abs(difference) < 0.0001 { return }
            let ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            try turn(difference > 0 ? ticks : -ticks)
        }
    }

    private static func stepToText(
        target: String,
        original: String,
        read: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        func matches(_ text: String?) -> Bool {
            text?.localizedCaseInsensitiveCompare(target) == .orderedSame
        }
        if matches(original) { return original }
        var net = 0
        // Search upward, then downward past the start. Enum boundaries can be
        // wider than one vpot tick, so escalate the step size when the display
        // does not move, and treat sustained silence at max step as the end stop.
        for direction in [1, -1] {
            var previous = read()
            var unchanged = 0
            var step = 1
            let limit = direction == 1 ? 24 : 48
            for _ in 0..<limit {
                try turn(direction * step)
                net += direction * step
                let text = read()
                if matches(text) { return text ?? target }
                if text == previous {
                    unchanged += 1
                    if unchanged >= 3 && step >= 8 { break } // end stop
                    step = min(step * 2, 8)
                } else {
                    unchanged = 0
                    step = 1
                    previous = text
                }
            }
        }
        // No match: undo the net movement.
        if net != 0 { try turn(-net) }
        throw DemoError.verificationFailed(
            requested: target,
            actual: read() ?? "unknown",
            restored: true
        )
    }
}

private final class MCPServer {
    private let logic = LogicAccessibility()

    func run() {
        log("starting \(serverName) \(serverVersion)")
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw DemoError.invalidArguments("request must be a JSON object")
                }
                if let response = try handle(request) {
                    write(response)
                }
            } catch {
                write(jsonRPCError(id: NSNull(), code: -32700, message: error.localizedDescription))
            }
        }
    }

    private func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"] ?? NSNull()

        switch method {
        case "initialize":
            return response(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": "Controls Logic Pro on this Mac through its control-surface protocol (no UI clicking). Requires: Logic running with a project open, Accessibility granted, and a Mackie Control configured with ports 'Logic MCP MCU' (one-time). Run logic_health FIRST — it starts the bridge daemon, verifies every setup step, and tells you the fix for anything missing. Run logic_setup_key_commands ONCE during onboarding — it opens Logic's Key Commands window briefly and binds all needed commands; skipping it means the same window flashes unannounced the first time a tool needs a missing command (lazy learning). Writes are compare-and-set with readback: pass expected_current_value and read values before changing them. The sensor AU is an optional add-on for realtime listening; bounce/render tools work without it. English Logic UI assumed (v1)."
            ])

        case "notifications/initialized", "initialized":
            return nil

        case "ping":
            return response(id: id, result: [:])

        case "tools/list":
            return response(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return response(id: id, result: callTool(name: toolName, arguments: arguments))

        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let payload: Any
            switch name {
            case "logic_health":
                var health = logic.health()
                // Doctor checks: every setup step as data, with the fix in text.
                MCUBridge.ensureRunning()
                let bridge = (try? MCUBridge.send(["cmd": "status"])) ?? [:]
                let bridgeUp = bridge["ok"] as? Bool == true
                health["bridge_running"] = bridgeUp
                health["mcu_connected"] = (bridge["received_events"] as? Int ?? 0) > 0
                if !bridgeUp {
                    health["bridge_fix"] = "the bridge subprocess could not be started (self-spawn with --bridge failed)"
                } else if (bridge["received_events"] as? Int ?? 0) == 0 {
                    health["mcu_fix"] = "no MIDI from Logic yet: add a Mackie Control in Logic > Control Surfaces > Setup with ports 'Logic MCP MCU', or play something"
                }
                let registered = Set(KeyCommandRegistry.commands().compactMap { $0["name"] as? String })
                health["key_commands"] = KeyCommandRegistry.standardCommands.map { command in
                    ["name": command.name, "registered": registered.contains(command.name)]
                }
                if !KeyCommandRegistry.standardCommands.allSatisfy({ registered.contains($0.name) }) {
                    health["key_commands_fix"] = "run logic_setup_key_commands (or let the first tool that needs one learn it automatically)"
                }
                if health["accessibility_trusted"] as? Bool != true {
                    health["accessibility_fix"] = "grant Accessibility in System Settings: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                }
                let sensors = SensorReader.readSensors(windowSeconds: 3)
                    .filter { !(($0["stale"] as? Bool) ?? true) }
                health["sensor"] = [
                    "active_instances": sensors.count,
                    "note": "OPTIONAL add-on for realtime listening; bounce- and render-based tools do not need it"
                ]
                payload = health

            case "logic_list_windows":
                payload = ["windows": try logic.listWindows()]

            case "logic_list_tracks":
                payload = try logic.listTracks()

            case "logic_list_inserts":
                payload = try logic.listInserts(trackName: requiredString("track_name", in: arguments))

            case "logic_bounce_range":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                payload = try logic.bounceRange(
                    startBar: startBar,
                    endBar: endBar,
                    label: (arguments["label"] as? String) ?? "bounce",
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_evaluate_change":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                if (arguments["method"] as? String) == "render" {
                    guard let slot = arguments["insert_slot"] as? Int else {
                        throw DemoError.invalidArguments(
                            "method 'render' requires insert_slot (1-8, MCU physical slot; list with logic_mcu_plugin_inserts)"
                        )
                    }
                    let range = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: endBar, arguments: arguments
                    )
                    payload = try MCUController.evaluateChangeRendered(
                        logic: logic,
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        insertSlot: slot,
                        parameter: requiredString("parameter", in: arguments),
                        expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                        targetValue: requiredString("target_value", in: arguments),
                        startBar: startBar, endBar: endBar,
                        startSeconds: range.start, endSeconds: range.end,
                        tempo: range.tempo,
                        keepChange: arguments["keep_change"] as? Bool ?? false
                    )
                    break
                }
                if (arguments["method"] as? String) == "bounce" {
                    payload = try logic.evaluateChangeBounced(
                        trackName: requiredString("track_name", in: arguments),
                        pluginName: requiredString("plugin_name", in: arguments),
                        insertIndex: arguments["insert_index"] as? Int,
                        parameter: requiredString("parameter", in: arguments),
                        expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                        targetValue: requiredString("target_value", in: arguments),
                        startBar: startBar,
                        endBar: endBar,
                        keepChange: arguments["keep_change"] as? Bool ?? false,
                        expectedProjectPath: arguments["expected_project_path"] as? String
                    )
                    break
                }
                payload = try logic.evaluateChange(
                    trackName: requiredString("track_name", in: arguments),
                    pluginName: requiredString("plugin_name", in: arguments),
                    insertIndex: arguments["insert_index"] as? Int,
                    parameter: requiredString("parameter", in: arguments),
                    expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                    targetValue: requiredString("target_value", in: arguments),
                    startBar: startBar,
                    endBar: endBar,
                    keepChange: arguments["keep_change"] as? Bool ?? false,
                    verifyRollback: arguments["verify_rollback"] as? Bool ?? false,
                    settleSeconds: arguments["settle_seconds"] as? Double ?? 2.0,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_mcu_plugin_inserts":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let inserts = try MCUController.pluginInsertNames() else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU plugin insert list",
                        exposed: "the MCU bridge is unavailable or the insert list did not appear"
                    )
                }
                MCUController.exitToPan()
                payload = [
                    "track": try requiredString("track_name", in: arguments),
                    "mcu_slots": inserts.enumerated().map { index, name in
                        ["slot": index + 1, "plugin": name.isEmpty ? "--" : name]
                    },
                    "note": "MCU slot numbers are physical insert positions and can differ from AX occupied-slot ordinals."
                ]

            case "logic_mcu_plugin_parameters":
                guard let slot = arguments["insert_slot"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
                }
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                let pluginMaxPages = arguments["max_pages"] as? Int ?? 12
                guard let listStatus = try MCUController.ensurePluginList(),
                      try MCUController.enterPluginEdit(slot: slot),
                      let capped = try MCUController.parameterPagesCapped(
                          cacheKey: (listStatus["lcd_bottom"] as? String).flatMap { bottom -> String? in
                              let name = MCUController.lcdFields(bottom)[slot - 1]
                                  .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                              return name.isEmpty || name == "--" ? nil : name
                          },
                          maxPages: pluginMaxPages
                      ) else {
                    MCUController.exitToPan()
                    throw DemoError.trackNotExposed(
                        requested: "MCU parameter pages for slot \(slot)",
                        exposed: "could not enter the plugin edit mode"
                    )
                }
                MCUController.exitToPan()
                var pluginPayload: [String: Any] = [
                    "track": try requiredString("track_name", in: arguments),
                    "insert_slot": slot,
                    "pages": capped.pages.count,
                    "pages_total": capped.total,
                    "parameters": capped.pages.enumerated().flatMap { pageIndex, page in
                        page.map { ["name": $0.name, "value": $0.value, "page": pageIndex + 1] }
                    }
                ]
                if capped.truncated {
                    pluginPayload["truncated"] = true
                    pluginPayload["note"] = "Showing \(capped.pages.count) of \(capped.total) pages (each uncached page costs ~1.7 s of LCD indicator fade). Pass max_pages for more."
                }
                payload = pluginPayload

            case "logic_mcu_set_plugin_parameter":
                guard let slot = arguments["insert_slot"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: insert_slot (1-8, MCU physical slot)")
                }
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let result = try MCUController.setPluginParameter(
                    slot: slot,
                    parameter: requiredString("parameter", in: arguments),
                    targetValue: requiredString("target_value", in: arguments),
                    expectedCurrentValue: arguments["expected_current_value"] as? String,
                    tolerance: arguments["tolerance"] as? Double
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU plugin parameter control",
                        exposed: "the MCU bridge is unavailable or the plugin edit mode could not be entered"
                    )
                }
                payload = result

            case "logic_mcu_instrument_parameters":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                let instrumentMaxPages = arguments["max_pages"] as? Int ?? 12
                guard let entered = try MCUController.enterInstrumentEdit(
                    trackName: requiredString("track_name", in: arguments)
                ), let capped = try MCUController.parameterPagesCapped(
                    cacheKey: "instrument:" + entered.name,
                    maxPages: instrumentMaxPages
                ) else {
                    MCUController.exitToPan()
                    throw DemoError.trackNotExposed(
                        requested: "MCU instrument parameters",
                        exposed: "no instrument in the slot, or the edit mode could not be entered"
                    )
                }
                MCUController.exitToPan()
                var instrumentPayload: [String: Any] = [
                    "track": try requiredString("track_name", in: arguments),
                    "slot_type": "instrument",
                    "instrument": entered.name,
                    "pages": capped.pages.count,
                    "pages_total": capped.total,
                    "parameters": capped.pages.enumerated().flatMap { pageIndex, page in
                        page.map { ["name": $0.name, "value": $0.value, "page": pageIndex + 1] }
                    }
                ]
                if capped.truncated {
                    instrumentPayload["truncated"] = true
                    instrumentPayload["note"] = "Showing \(capped.pages.count) of \(capped.total) pages (each uncached page costs ~1.7 s of LCD indicator fade). Pass max_pages for more."
                }
                payload = instrumentPayload

            case "logic_mcu_set_instrument_parameter":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: nil
                )
                guard let result = try MCUController.setInstrumentParameter(
                    trackName: requiredString("track_name", in: arguments),
                    parameter: requiredString("parameter", in: arguments),
                    targetValue: requiredString("target_value", in: arguments),
                    expectedCurrentValue: arguments["expected_current_value"] as? String,
                    tolerance: arguments["tolerance"] as? Double
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU instrument parameter control",
                        exposed: "no instrument in the slot, or the edit mode could not be entered"
                    )
                }
                payload = result

            case "logic_mcu_status":
                payload = MCUBridge.status()

            case "logic_mcu_sends":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                guard let sends = try MCUController.readSends() else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU send view",
                        exposed: "the MCU bridge is unavailable or the send view did not appear"
                    )
                }
                payload = [
                    "track": try requiredString("track_name", in: arguments),
                    "sends": sends,
                    "note": "Send slots as the Mackie Control channel view shows them; level in dB, position pre/post, status active/muted."
                ]

            case "logic_mcu_set_send":
                guard let send = arguments["send"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: send (1-8)")
                }
                let levelDb = (arguments["level_db"] as? Double)
                    ?? (arguments["level_db"] as? Int).map(Double.init)
                guard let target = levelDb else {
                    throw DemoError.invalidArguments("missing number: level_db")
                }
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                guard var sendResult = try MCUController.setSendLevel(
                    sendNumber: send,
                    targetDb: target,
                    expectedCurrentValue: arguments["expected_current_value"] as? String
                ) else {
                    throw DemoError.trackNotExposed(
                        requested: "MCU send level write",
                        exposed: "the MCU bridge is unavailable or the send view layout was unexpected"
                    )
                }
                sendResult["track"] = try requiredString("track_name", in: arguments)
                payload = sendResult

            case "logic_record_automation":
                guard let rawPoints = arguments["points"] as? [[String: Any]], rawPoints.count >= 1 else {
                    throw DemoError.invalidArguments("points required: [{bar, beat?, db}, ...]")
                }
                let parameter = (arguments["parameter"] as? String) ?? "volume"
                let automationPoints: [(bar: Int, beat: Double, value: Double)] = try rawPoints.map { raw in
                    guard let bar = raw["bar"] as? Int,
                          let value = (raw["value"] as? Double) ?? (raw["value"] as? Int).map(Double.init)
                              ?? (raw["db"] as? Double) ?? (raw["db"] as? Int).map(Double.init) else {
                        throw DemoError.invalidArguments("each point needs bar (int) and value/db (number)")
                    }
                    let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                    return (bar, beat, value)
                }
                let automationTrack = try requiredString("track_name", in: arguments)
                let ramp = arguments["ramp"] as? Bool ?? true
                let verifyCurve = arguments["verify"] as? Bool ?? true
                let toleranceArg = (arguments["tolerance"] as? Double)
                    ?? (arguments["tolerance"] as? Int).map(Double.init)
                var automationResult: [String: Any]
                switch parameter {
                case "volume":
                    automationResult = try MCUController.recordVolumeAutomation(
                        logic: logic,
                        trackName: automationTrack,
                        points: automationPoints.map { ($0.bar, $0.beat, $0.value) },
                        ramp: ramp,
                        verify: verifyCurve
                    )
                case "pan":
                    automationResult = try MCUController.recordVpotAutomation(
                        logic: logic, trackName: automationTrack, kindLabel: "pan",
                        points: automationPoints, ramp: ramp, verify: verifyCurve,
                        tolerance: toleranceArg ?? 2.0,
                        enterView: { _ in
                            // Pan reads and writes through the strip's pan
                            // knob (AX): exact echo, rapid-fire stepwise write.
                            (
                                { [logic] in logic.stripPanValue(trackName: automationTrack) },
                                { [logic] target, budget in
                                    try logic.stripPanWrite(
                                        trackName: automationTrack, target: target, budget: budget
                                    )
                                }
                            )
                        },
                        restoreView: { }
                    )
                case "send":
                    guard let sendSlot = arguments["send"] as? Int, (1...8).contains(sendSlot) else {
                        throw DemoError.invalidArguments("parameter 'send' requires send: 1-8")
                    }
                    automationResult = try MCUController.recordVpotAutomation(
                        logic: logic, trackName: automationTrack, kindLabel: "send \(sendSlot) level",
                        points: automationPoints, ramp: ramp, verify: verifyCurve,
                        tolerance: toleranceArg ?? 1.0,
                        enterView: { _ in
                            guard try MCUController.ensureSendView() else {
                                throw DemoError.trackNotExposed(
                                    requested: "the send channel view", exposed: "not reachable"
                                )
                            }
                            try MCUController.sendViewToPage(forSend: sendSlot)
                            let levelIndex = ((sendSlot - 1) % 2) * 4 + 1
                            let read: () -> Double? = {
                                guard let status = MCUController.freshStatus(),
                                      let bottom = status["lcd_bottom"] as? String else { return nil }
                                // parseDb handles "-oodB" (new sends start at -inf)
                                return MCUController.parseDb(
                                    MCUController.lcdFields(bottom)[levelIndex]
                                )
                            }
                            let write = try MCUController.makeVpotWriter(index: levelIndex, read: read)
                            return (read, write)
                        },
                        refreshView: {
                            guard try MCUController.ensureSendView() else {
                                throw DemoError.trackNotExposed(
                                    requested: "the send view for verification", exposed: "not reachable"
                                )
                            }
                            try MCUController.sendViewToPage(forSend: sendSlot)
                        },
                        restoreView: { MCUController.exitToPan() }
                    )
                case "plugin":
                    guard let slot = arguments["insert_slot"] as? Int else {
                        throw DemoError.invalidArguments("parameter 'plugin' requires insert_slot (1-8)")
                    }
                    let paramName = try requiredString("plugin_parameter", in: arguments)
                    let maxAbs = automationPoints.map { abs($0.value) }.max() ?? 1
                    automationResult = try MCUController.recordVpotAutomation(
                        logic: logic, trackName: automationTrack,
                        kindLabel: "plugin slot \(slot): \(paramName)",
                        points: automationPoints, ramp: ramp, verify: verifyCurve,
                        tolerance: toleranceArg ?? max(0.5, maxAbs * 0.05),
                        enterView: { _ in
                            guard try MCUController.ensurePluginList() != nil,
                                  try MCUController.enterPluginEdit(slot: slot) else {
                                throw DemoError.trackNotExposed(
                                    requested: "plugin edit mode for slot \(slot)",
                                    exposed: "could not enter"
                                )
                            }
                            guard let found = try MCUController.locateParameter(named: paramName) else {
                                throw DemoError.trackNotExposed(
                                    requested: "parameter '\(paramName)' in slot \(slot)",
                                    exposed: "not found on the parameter pages"
                                )
                            }
                            let read: () -> Double? = {
                                MCUController.parameterPage().flatMap {
                                    MCUController.parseNumber($0[found].value)
                                }
                            }
                            let write = try MCUController.makeVpotWriter(index: found, read: read)
                            return (read, write)
                        },
                        refreshView: {
                            guard try MCUController.ensurePluginList() != nil,
                                  try MCUController.enterPluginEdit(slot: slot),
                                  try MCUController.locateParameter(named: paramName) != nil else {
                                throw DemoError.trackNotExposed(
                                    requested: "the plugin view for verification", exposed: "not reachable"
                                )
                            }
                        },
                        restoreView: { MCUController.exitToPan() }
                    )
                default:
                    throw DemoError.invalidArguments("parameter must be volume, pan, send or plugin")
                }
                automationResult["track"] = automationTrack
                payload = automationResult

            case "logic_record_midi":
                let trackName = try requiredString("track_name", in: arguments)
                guard let rawNotes = arguments["notes"] as? [[String: Any]], !rawNotes.isEmpty else {
                    throw DemoError.invalidArguments(
                        "notes required: [{pitch, bar, beat?, duration_beats?, velocity?, channel?}, ...]"
                    )
                }
                if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
                   let header = tracks.first(where: {
                       ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
                   }),
                   header["is_stack"] as? Bool == true {
                    throw DemoError.trackNotExposed(
                        requested: "MIDI recording on '\(trackName)'",
                        exposed: "'\(trackName)' is a track stack — record on one of its subtracks"
                    )
                }
                // Note-name parsing: Logic convention, middle C (MIDI 60) = C3.
                func parsePitch(_ value: Any) throws -> Int {
                    if let number = value as? Int {
                        guard (0...127).contains(number) else {
                            throw DemoError.invalidArguments("pitch \(number) outside 0-127")
                        }
                        return number
                    }
                    guard let name = value as? String else {
                        throw DemoError.invalidArguments("pitch must be 0-127 or a name like 'C3'/'F#1'")
                    }
                    let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
                    var rest = name.uppercased()
                    guard let letter = rest.first, let base = semitones[letter] else {
                        throw DemoError.invalidArguments("unknown pitch name '\(name)'")
                    }
                    rest.removeFirst()
                    var accidental = 0
                    if rest.hasPrefix("#") { accidental = 1; rest.removeFirst() }
                    else if rest.hasPrefix("B") && rest.count > 1 { accidental = -1; rest.removeFirst() }
                    guard let octave = Int(rest) else {
                        throw DemoError.invalidArguments("unknown pitch name '\(name)' (use e.g. 'C3' = MIDI 60)")
                    }
                    let midi = 60 + (octave - 3) * 12 + base + accidental
                    guard (0...127).contains(midi) else {
                        throw DemoError.invalidArguments("pitch '\(name)' outside MIDI 0-127")
                    }
                    return midi
                }
                struct ParsedNote {
                    let pitch: Int; let bar: Int; let beat: Double
                    let durationBeats: Double; let velocity: Int; let channel: Int
                }
                var parsed: [ParsedNote] = []
                for raw in rawNotes {
                    guard let bar = raw["bar"] as? Int, bar >= 1 else {
                        throw DemoError.invalidArguments("each note needs bar >= 1")
                    }
                    let velocity = raw["velocity"] as? Int ?? 100
                    guard (1...127).contains(velocity) else {
                        throw DemoError.invalidArguments("velocity must be 1-127")
                    }
                    let channel = raw["channel"] as? Int ?? 1
                    guard (1...16).contains(channel) else {
                        throw DemoError.invalidArguments("channel must be 1-16")
                    }
                    parsed.append(ParsedNote(
                        pitch: try parsePitch(raw["pitch"] ?? ""),
                        bar: bar,
                        beat: (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0,
                        durationBeats: (raw["duration_beats"] as? Double)
                            ?? (raw["duration_beats"] as? Int).map(Double.init) ?? 1.0,
                        velocity: velocity,
                        channel: channel
                    ))
                }
                let extraBars: [Int] = ((arguments["cc_events"] as? [[String: Any]]) ?? []).compactMap { $0["bar"] as? Int }
                    + ((arguments["pitch_bends"] as? [[String: Any]]) ?? []).compactMap { $0["bar"] as? Int }
                let startBar = arguments["start_bar"] as? Int
                    ?? min(parsed.map(\.bar).min()!, extraBars.min() ?? Int.max)
                let lastExtraBeats = extraBars.map { Double($0 - startBar + 1) * 4 }.max() ?? 0
                let lastNoteEndBeats = max(parsed.map {
                    Double($0.bar - startBar) * 4 + ($0.beat - 1) + $0.durationBeats
                }.max() ?? 4, lastExtraBeats)
                let endBarGuess = startBar + Int((lastNoteEndBeats / 4).rounded(.up))
                let range = try barRangeSeconds(
                    logic: logic, startBar: startBar, endBar: max(endBarGuess, startBar + 1),
                    arguments: arguments
                )
                // speed > 1 records at a raised tempo and scales event times:
                // the region lands at identical bar positions in a fraction
                // of the wall time. Default 1 = real time (audible playback).
                let requestedSpeed = (arguments["speed"] as? Double)
                    ?? (arguments["speed"] as? Int).map(Double.init) ?? 1.0
                let effectiveSpeed = min(max(requestedSpeed, 1.0), 8.0, 960.0 / range.tempo)
                let recordingTempo = range.tempo * effectiveSpeed
                let msPerBeat = 60000.0 / recordingTempo
                var events: [(offsetMs: Double, bytes: [UInt8])] = []
                for note in parsed {
                    let offsetBeats = Double(note.bar - startBar) * range.beatsPerBar + (note.beat - 1)
                    guard offsetBeats >= 0 else {
                        throw DemoError.invalidArguments(
                            "note at bar \(note.bar) lies before start_bar \(startBar)"
                        )
                    }
                    let status = UInt8(note.channel - 1)
                    events.append((offsetBeats * msPerBeat,
                                   [0x90 | status, UInt8(note.pitch), UInt8(note.velocity)]))
                    events.append(((offsetBeats + note.durationBeats) * msPerBeat - 1,
                                   [0x80 | status, UInt8(note.pitch), 0]))
                }
                // CC and pitch-bend events ride the same timed stream.
                if let rawCC = arguments["cc_events"] as? [[String: Any]] {
                    for raw in rawCC {
                        guard let bar = raw["bar"] as? Int,
                              let cc = raw["cc"] as? Int, (0...127).contains(cc),
                              let value = raw["value"] as? Int, (0...127).contains(value) else {
                            throw DemoError.invalidArguments("each cc_event needs bar, cc (0-127) and value (0-127)")
                        }
                        let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                        let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                        let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                        guard offsetBeats >= 0 else {
                            throw DemoError.invalidArguments("cc_event at bar \(bar) lies before start_bar \(startBar)")
                        }
                        events.append((offsetBeats * msPerBeat,
                                       [0xB0 | channel, UInt8(cc), UInt8(value)]))
                    }
                }
                if let rawBends = arguments["pitch_bends"] as? [[String: Any]] {
                    for raw in rawBends {
                        guard let bar = raw["bar"] as? Int,
                              let value = raw["value"] as? Int, (-8192...8191).contains(value) else {
                            throw DemoError.invalidArguments("each pitch_bend needs bar and value (-8192..8191; 0 = center)")
                        }
                        let beat = (raw["beat"] as? Double) ?? (raw["beat"] as? Int).map(Double.init) ?? 1.0
                        let channel = UInt8(((raw["channel"] as? Int) ?? 1) - 1) & 0x0F
                        let offsetBeats = Double(bar - startBar) * range.beatsPerBar + (beat - 1)
                        guard offsetBeats >= 0 else {
                            throw DemoError.invalidArguments("pitch_bend at bar \(bar) lies before start_bar \(startBar)")
                        }
                        let fourteen = value + 8192
                        events.append((offsetBeats * msPerBeat,
                                       [0xE0 | channel, UInt8(fourteen & 0x7F), UInt8((fourteen >> 7) & 0x7F)]))
                    }
                }
                events.sort { $0.offsetMs < $1.offsetMs }
                if effectiveSpeed > 1.001 {
                    _ = try logic.setTempo(recordingTempo)
                }
                var result: [String: Any]
                do {
                    result = try MCUController.recordMIDI(
                        logic: logic,
                        trackName: trackName,
                        trackNumber: arguments["track_number"] as? Int,
                        events: events,
                        startBar: startBar,
                        tailMs: 600,
                        tempo: recordingTempo,
                        beatsPerBar: range.beatsPerBar,
                        syncCompensationMs: (arguments["sync_compensation_ms"] as? Double)
                            ?? (arguments["sync_compensation_ms"] as? Int).map(Double.init) ?? 45
                    )
                } catch {
                    if effectiveSpeed > 1.001 { _ = try? logic.setTempo(range.tempo) }
                    throw error
                }
                if effectiveSpeed > 1.001 {
                    let restored = (try? logic.setTempo(range.tempo)) ?? -1
                    result["speed"] = effectiveSpeed
                    result["recording_tempo"] = recordingTempo
                    result["tempo_restored"] = abs(restored - range.tempo) < 0.5
                    result["speed_note"] = "Recorded at \(Int(recordingTempo)) BPM and restored to \(Int(range.tempo)); timing jitter scales with speed — quantize if it matters."
                }
                result["track"] = trackName
                result["notes"] = parsed.count
                result["start_bar"] = startBar
                result["tempo"] = range.tempo
                if arguments["verify_render"] as? Bool ?? true {
                    let endBar = startBar + Int((lastNoteEndBeats / range.beatsPerBar).rounded(.up))
                    let verifyRange = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: max(endBar, startBar + 1),
                        arguments: arguments
                    )
                    if let render = try? MCUController.renderSelectedTrack(
                        projectPath: logic.projectDocumentPath(),
                        label: "midi-verify",
                        sliceStartSeconds: verifyRange.start, sliceEndSeconds: verifyRange.end,
                        logic: logic, trackName: trackName
                    ) {
                        let slice = render["slice"] as? [String: Any]
                        result["verification"] = [
                            "rendered_slice": slice?["path"] ?? NSNull(),
                            "metrics": slice?["metrics"] ?? NSNull(),
                            "note": "freeze render of bars \(startBar)-\(endBar) after recording; non-silent metrics prove the notes landed and sound"
                        ]
                        result["verified"] = (slice?["metrics"] as? [String: Any])
                            .flatMap { ($0["peak_db"] as? [Double])?.first }
                            .map { $0 > -120 } ?? false
                    } else {
                        result["verification"] = ["note": "verification render failed; the recording itself completed"]
                        result["verified"] = false
                    }
                }
                payload = result

            case "logic_save_project":
                payload = try logic.saveProject(
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_new_project":
                payload = try logic.openProject(
                    path: requiredString("path", in: arguments),
                    createFromTemplate: true,
                    ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
                )

            case "logic_open_project":
                payload = try logic.openProject(
                    path: requiredString("path", in: arguments),
                    createFromTemplate: false,
                    ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
                )

            case "logic_close_project":
                payload = try logic.closeProject(
                    saving: requiredString("saving", in: arguments),
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_create_track":
                let kind = (arguments["type"] as? String) ?? "software_instrument"
                let commandName = kind == "audio" ? "New Audio Track" : "New Software Instrument Track"
                let before = ((try? logic.listTracks())?["tracks"] as? [[String: Any]])?.count ?? 0
                let command = try MCUController.resolveKeyCommand(named: commandName, logic: logic)
                _ = try MCUController.triggerKeyCommand(note: command.note, channel: command.channel)
                // The command opens the Create New Track dialog; answer Create.
                var answered = false
                for _ in 0..<50 {
                    Thread.sleep(forTimeInterval: 0.12)
                    if logic.answerCreateTrackDialog() { answered = true; break }
                }
                var created = false
                var after: [[String: Any]] = []
                for _ in 0..<25 {
                    Thread.sleep(forTimeInterval: 0.15)
                    after = ((try? logic.listTracks())?["tracks"] as? [[String: Any]]) ?? []
                    if after.count > before { created = true; break }
                }
                payload = [
                    "success": created,
                    "verified": created,
                    "type": kind,
                    "dialog_answered": answered,
                    "tracks_before": before,
                    "tracks_after": after.count,
                    "tracks": after.map { ["track_number": $0["track_number"] ?? 0, "track_name": $0["track_name"] ?? ""] },
                    "note": created ? "Track created." : "No new track appeared; a dialog may need attention."
                ]

            case "logic_setup_key_commands":
                let results = try logic.setupKeyCommands(KeyCommandRegistry.standardCommands)
                payload = [
                    "results": results,
                    "note": "Assignments were added to the user's active key command set (additive; removable in the Key Commands window). The registry file records the final note numbers."
                ]

            case "logic_trigger_key_command":
                if let name = arguments["name"] as? String {
                    let found = try MCUController.resolveKeyCommand(named: name, logic: logic)
                    var triggered = try MCUController.triggerKeyCommand(
                        note: found.note, channel: found.channel
                    )
                    if MCUController.lastResolveLearned {
                        triggered["first_run_learning"] =
                            "This command was just learned: the Key Commands window opened briefly (one-time per machine). Run logic_setup_key_commands during onboarding to do all learning up front."
                    }
                    payload = triggered
                } else {
                    let note = arguments["note"] as? Int ?? -1
                    let channel = arguments["channel"] as? Int ?? 16
                    payload = try MCUController.triggerKeyCommand(note: note, channel: channel)
                }

            case "logic_render_track":
                let trackName = try requiredString("track_name", in: arguments)
                let label = (arguments["label"] as? String)
                    ?? trackName.lowercased().replacingOccurrences(of: " ", with: "-")
                let projectPath = try logic.projectDocumentPath()
                // Track stacks and buses cannot be frozen — refuse upfront
                // when the AX track headers can tell us.
                if let tracks = (try? logic.listTracks())?["tracks"] as? [[String: Any]],
                   let header = tracks.first(where: {
                       ($0["track_name"] as? String)?.caseInsensitiveCompare(trackName) == .orderedSame
                   }),
                   header["is_stack"] as? Bool == true {
                    throw DemoError.trackNotExposed(
                        requested: "freeze render of '\(trackName)'",
                        exposed: "'\(trackName)' is a track stack — Logic cannot freeze stacks; render its subtracks individually or use logic_bounce_range for the summed output"
                    )
                }
                // MCU-first selection; AX track headers as fallback.
                var selected = false
                if let channel = ((try? MCUController.findChannel(trackName: trackName)) ?? nil) {
                    selected = (try? MCUController.selectFoundChannel(channel)) == true
                }
                if !selected {
                    _ = try logic.selectTrack(
                        trackName: trackName,
                        trackNumber: arguments["track_number"] as? Int,
                        expectedProjectPath: arguments["expected_project_path"] as? String
                    )
                }
                var sliceRange: (start: Double, end: Double, tempo: Double, beatsPerBar: Double)?
                if let startBar = arguments["start_bar"] as? Int,
                   let endBar = arguments["end_bar"] as? Int {
                    sliceRange = try barRangeSeconds(
                        logic: logic, startBar: startBar, endBar: endBar, arguments: arguments
                    )
                }
                var render = try MCUController.renderSelectedTrack(
                    projectPath: projectPath, label: label,
                    sliceStartSeconds: sliceRange?.start, sliceEndSeconds: sliceRange?.end,
                    logic: logic, trackName: trackName
                )
                render["track"] = trackName
                if let range = sliceRange {
                    render["slice_tempo"] = range.tempo
                    render["slice_beats_per_bar"] = range.beatsPerBar
                }
                payload = render

            case "logic_mcu_command":
                var command: [String: Any] = [:]
                for (key, value) in arguments where key != "expected_project_path" {
                    command[key] = value
                }
                payload = try MCUBridge.send(command)

            case "logic_sensor_capture":
                let seconds = (arguments["seconds"] as? Double)
                    ?? (arguments["seconds"] as? Int).map(Double.init)
                    ?? 8.0
                let label = (arguments["label"] as? String) ?? "capture"
                let captures = SensorReader.readSensors(windowSeconds: 2)
                    .filter { !(($0["stale"] as? Bool) ?? true) }
                    .compactMap { sensor -> [String: Any]? in
                        guard let path = sensor["ring_path"] as? String,
                              var capture = SensorReader.captureAudio(
                                  ringPath: path, seconds: seconds, label: label
                              ) else { return nil }
                        capture["sensor"] = sensor["instance_id"]
                        return capture
                    }
                payload = [
                    "success": !captures.isEmpty,
                    "captures": captures,
                    "note": captures.isEmpty
                        ? "no fresh sensor with audio available; is LogicMCPSensor inserted and Logic rendering?"
                        : "wav files contain the most recent audio heard at each sensor's insert point"
                ]

            case "logic_sensor_read":
                let window = (arguments["window_seconds"] as? Double)
                    ?? (arguments["window_seconds"] as? Int).map(Double.init)
                    ?? 3.0
                payload = [
                    "sensors": SensorReader.readSensors(windowSeconds: window),
                    "searched_directories": SensorReader.candidateDirectories().map(\.path)
                ]

            case "logic_get_transport":
                payload = try logic.getTransport()

            case "logic_set_cycle":
                guard let enabled = arguments["enabled"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: enabled")
                }
                payload = try MCUController.setCycle(enabled) ?? logic.setCycle(enabled: enabled)

            case "logic_set_playing":
                guard let playing = arguments["playing"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: playing")
                }
                payload = try MCUController.setPlaying(playing) ?? logic.setPlaying(playing: playing)

            case "logic_set_playhead":
                guard let barNumber = arguments["bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: bar")
                }
                payload = try logic.setPlayhead(
                    barNumber: barNumber,
                    beat: arguments["beat"] as? Int
                )

            case "logic_set_cycle_range":
                guard let startBar = arguments["start_bar"] as? Int,
                      let endBar = arguments["end_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integers: start_bar, end_bar")
                }
                payload = try logic.setCycleRange(
                    startBar: startBar,
                    endBar: endBar,
                    enabled: arguments["enabled"] as? Bool
                )

            case "logic_select_track":
                payload = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_set_track_stack":
                guard let expanded = arguments["expanded"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: expanded")
                }
                payload = try logic.setTrackStack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expanded: expanded,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_survey_plugins":
                payload = try logic.surveyPlugins(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int
                )

            case "logic_add_plugin":
                // MCU plugin browser first (mouse-free); the AX chooser needs
                // the physical mouse for hover navigation, so it only runs
                // when explicitly allowed.
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                if var viaBrowser = try MCUController.addPluginViaBrowser(
                    pluginName: requiredString("plugin_name", in: arguments),
                    logic: logic,
                    trackName: requiredString("track_name", in: arguments)
                ) {
                    viaBrowser["track"] = try requiredString("track_name", in: arguments)
                    payload = viaBrowser
                } else if arguments["allow_mouse"] as? Bool == true {
                    payload = try logic.addPlugin(
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        pluginName: requiredString("plugin_name", in: arguments),
                        format: (arguments["format"] as? String) ?? "Stereo"
                    )
                } else {
                    throw DemoError.trackNotExposed(
                        requested: "mouse-free plugin insertion",
                        exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
                    )
                }

            case "logic_remove_plugin":
                _ = try logic.selectTrack(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )
                if var removed = try MCUController.removePluginViaBrowser(
                    pluginName: requiredString("plugin_name", in: arguments),
                    logic: logic,
                    trackName: requiredString("track_name", in: arguments)
                ) {
                    removed["track"] = try requiredString("track_name", in: arguments)
                    payload = removed
                } else if arguments["allow_mouse"] as? Bool == true {
                    payload = try logic.removePlugin(
                        trackName: requiredString("track_name", in: arguments),
                        trackNumber: arguments["track_number"] as? Int,
                        pluginName: requiredString("plugin_name", in: arguments),
                        insertIndex: arguments["insert_index"] as? Int
                    )
                } else {
                    throw DemoError.trackNotExposed(
                        requested: "mouse-free plugin removal",
                        exposed: "the MCU bridge is unavailable; pass allow_mouse: true to permit the AX chooser fallback (takes over the pointer briefly)"
                    )
                }

            case "logic_list_regions":
                payload = try logic.listRegions(
                    trackName: arguments["track_name"] as? String
                )

            case "logic_select_region":
                payload = try logic.selectRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    exclusive: arguments["exclusive"] as? Bool ?? true
                )

            case "logic_delete_region":
                payload = try logic.deleteRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int
                )

            case "logic_move_region":
                payload = try logic.moveRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    byBars: arguments["by_bars"] as? Int ?? 0,
                    byBeats: arguments["by_beats"] as? Int ?? 0
                )

            case "logic_copy_region":
                guard let toBar = arguments["to_bar"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: to_bar")
                }
                payload = try logic.copyRegion(
                    trackName: requiredString("track_name", in: arguments),
                    regionName: arguments["region_name"] as? String,
                    startBar: arguments["start_bar"] as? Int,
                    toBar: toBar,
                    toTrack: arguments["to_track"] as? String,
                    move: arguments["move"] as? Bool ?? false
                )

            case "logic_set_tempo":
                let bpm = (arguments["bpm"] as? Double)
                    ?? (arguments["bpm"] as? Int).map(Double.init)
                guard let targetBpm = bpm else {
                    throw DemoError.invalidArguments("missing number: bpm")
                }
                let transportBefore = try logic.getTransport()
                let currentBpm = transportBefore["tempo"] as? Double
                if let expected = (arguments["expected_current_bpm"] as? Double)
                    ?? (arguments["expected_current_bpm"] as? Int).map(Double.init) {
                    guard let current = currentBpm, abs(current - expected) < 0.5 else {
                        throw DemoError.currentValueMismatch(
                            expected: "\(expected) BPM",
                            actual: "\(currentBpm.map { "\($0)" } ?? "unreadable") BPM"
                        )
                    }
                }
                let landed = try logic.setTempo(targetBpm)
                payload = [
                    "success": true,
                    "verified": true,
                    "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
                    "bpm": landed,
                    "write_route": "control_bar_tempo_slider",
                    "note": "Whole-BPM resolution (the slider steps 1 BPM). Constant project tempo assumed; tempo-track changes are not managed."
                ]

            case "logic_set_track_mute", "logic_set_track_solo":
                let control = name == "logic_set_track_mute" ? "mute" : "solo"
                guard let enabled = arguments["enabled"] as? Bool else {
                    throw DemoError.invalidArguments("missing boolean: enabled")
                }
                let toggleTrack = try requiredString("track_name", in: arguments)
                payload = try MCUController.setToggle(
                    trackName: toggleTrack, control: control, enabled: enabled
                ) ?? logic.setStripToggle(
                    trackName: toggleTrack,
                    trackNumber: arguments["track_number"] as? Int,
                    control: control,
                    enabled: enabled
                )

            case "logic_set_track_volume":
                guard let db = (arguments["db"] as? Double) ?? (arguments["db"] as? Int).map(Double.init) else {
                    throw DemoError.invalidArguments("missing number: db")
                }
                let volumeTrack = try requiredString("track_name", in: arguments)
                let tolerance = (arguments["tolerance_db"] as? Double) ?? 0.15
                payload = try MCUController.setVolume(
                    trackName: volumeTrack, targetDb: db, toleranceDb: tolerance
                ) ?? logic.setTrackVolume(
                    trackName: volumeTrack,
                    trackNumber: arguments["track_number"] as? Int,
                    targetDb: db,
                    toleranceDb: tolerance
                )

            case "logic_set_track_pan":
                guard let position = arguments["position"] as? Int else {
                    throw DemoError.invalidArguments("missing integer: position")
                }
                payload = try logic.setTrackPan(
                    trackName: requiredString("track_name", in: arguments),
                    trackNumber: arguments["track_number"] as? Int,
                    position: position
                )

            case "logic_open_plugin":
                payload = try logic.openPlugin(
                    trackName: requiredString("track_name", in: arguments),
                    pluginName: requiredString("plugin_name", in: arguments),
                    insertIndex: arguments["insert_index"] as? Int,
                    expectedProjectPath: arguments["expected_project_path"] as? String
                )

            case "logic_close_plugin":
                payload = try logic.closePlugin(
                    trackName: requiredString("track_name", in: arguments),
                    pluginName: requiredString("plugin_name", in: arguments),
                    insertIndex: arguments["insert_index"] as? Int
                )

            case "logic_close_plugin_window":
                payload = try logic.closePluginWindow(title: requiredString("window_title", in: arguments))

            case "logic_list_plugin_parameters":
                let windowTitle = try requiredString("window_title", in: arguments)
                payload = [
                    "window": windowTitle,
                    "parameters": try logic.listParameters(windowTitle: windowTitle)
                ]

            case "logic_set_plugin_parameter":
                payload = try logic.setParameter(
                    windowTitle: requiredString("window_title", in: arguments),
                    parameterName: requiredString("parameter", in: arguments),
                    expectedCurrentValue: requiredString("expected_current_value", in: arguments),
                    targetValue: requiredString("target_value", in: arguments)
                )

            default:
                throw DemoError.invalidArguments("unknown tool: \(name)")
            }
            return toolResult(payload: payload, isError: false)
        } catch {
            return toolResult(
                payload: [
                    "success": false,
                    "verified": false,
                    "state": "failed",
                    "error_code": (error as? DemoError)?.code ?? "failed",
                    "error": error.localizedDescription
                ],
                isError: true
            )
        }
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw DemoError.invalidArguments("missing non-empty string: \(key)")
        }
        return value
    }

    /// Bar positions → seconds from project start (freeze renders begin at
    /// bar 1). Tempo and meter come from the control bar unless overridden;
    /// constant tempo is assumed (tempo-track changes are not followed).
    private func barRangeSeconds(
        logic: LogicAccessibility, startBar: Int, endBar: Int, arguments: [String: Any]
    ) throws -> (start: Double, end: Double, tempo: Double, beatsPerBar: Double) {
        guard startBar >= 1, endBar > startBar else {
            throw DemoError.invalidArguments("need start_bar >= 1 and end_bar > start_bar")
        }
        var tempo = (arguments["tempo"] as? Double)
            ?? (arguments["tempo"] as? Int).map(Double.init) ?? 0
        var beatsPerBar = (arguments["beats_per_bar"] as? Double)
            ?? (arguments["beats_per_bar"] as? Int).map(Double.init) ?? 0
        if tempo <= 0 || beatsPerBar <= 0 {
            let transport = try logic.getTransport()
            if tempo <= 0 {
                guard let read = transport["tempo"] as? Double else {
                    throw DemoError.trackNotExposed(
                        requested: "tempo from the control bar",
                        exposed: "no tempo readable; pass an explicit 'tempo' argument"
                    )
                }
                tempo = read
            }
            if beatsPerBar <= 0 {
                beatsPerBar = Double((transport["time_signature"] as? String)?
                    .split(separator: "/").first.flatMap { Int($0) } ?? 4)
            }
        }
        let secondsPerBar = beatsPerBar * 60.0 / tempo
        return (
            Double(startBar - 1) * secondsPerBar,
            Double(endBar - 1) * secondsPerBar,
            tempo, beatsPerBar
        )
    }

    private func toolResult(payload: Any, isError: Bool) -> [String: Any] {
        let text: String
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = String(describing: payload)
        }

        var result: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
        if let structured = payload as? [String: Any] {
            result["structuredContent"] = structured
        }
        return result
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "logic_health",
                "description": "Read Logic Pro process and Accessibility readiness without changing Logic.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_windows",
                "description": "List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_tracks",
                "description": "List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. Scrolled-out or hidden tracks are not exposed by Logic.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_inserts",
                "description": "List audio-effect insert slots (index, plugin display name, bypass state) of the named track's channel strip, read-only. The track must be selected so its strip is shown in the left inspector; otherwise the error not_exposed reports which track is currently shown.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_bounce_range",
                "description": "Offline-bounce a bar range of the master output to an audio file, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback, no sensor needed). Temporarily switches the bounce destination to Uncompressed and restores the user's selection afterwards. Returns the file path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer"],
                        "end_bar": ["type": "integer"],
                        "label": ["type": "string", "description": "Filename label, e.g. 'A' or 'baseline'."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_evaluate_change",
                "description": "Run one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range. Three methods: 'realtime' (default; loop playback + sensor windows, needs plugin_name + active sensor), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party). All methods roll the change back by default and return baseline/after audio paths, metrics and dB deltas.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin window title; required for methods 'realtime' and 'bounce'."],
                        "insert_index": ["type": "integer"],
                        "insert_slot": ["type": "integer", "description": "MCU physical insert slot 1-8; required for method 'render' (list with logic_mcu_plugin_inserts)."],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "end_bar": ["type": "integer", "description": "Exclusive: the range ends where this bar begins."],
                        "method": ["type": "string", "description": "'realtime' (default), 'bounce' (offline master A/B) or 'render' (dialog-free single-track freeze A/B on the sliced bar range)."],
                        "tempo": ["type": "number", "description": "Override BPM for bar math (method 'render'); default reads the control bar. Constant tempo assumed."],
                        "beats_per_bar": ["type": "number", "description": "Override meter for bar math; default reads the control bar's time signature."],
                        "keep_change": ["type": "boolean", "description": "true keeps the change after measuring; default false rolls it back."],
                        "verify_rollback": ["type": "boolean", "description": "Measure a third control window after rollback (default false; rollback accuracy has been verified at ~0.0 dB residual repeatedly)."],
                        "settle_seconds": ["type": "number", "description": "Extra settle time after each phase, default 2."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "parameter", "expected_current_value", "target_value", "start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_plugin_inserts",
                "description": "List a track's insert slots as the Mackie Control sees them (physical slot numbers 1-8 with plugin names), via the selected track's MCU plugin list. Works for ALL plugins including custom-UI third-party ones. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_plugin_parameters",
                "description": "Read ALL of a plugin's parameter names and formatted values (every MCU page) via host automation — works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...). insert_slot is the MCU physical slot from logic_mcu_plugin_inserts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer"]
                    ],
                    "required": ["track_name", "insert_slot"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_plugin_parameter",
                "description": "Set one plugin parameter through host automation (MCU vpot) with the LCD value echo as verified readback — the data-plane route that reaches every plugin. Numeric targets converge adaptively; text targets (e.g. 'On', 'B') step until exact match. Optional expected_current_value enforces compare-and-set; failed verification rolls back. Parameter is matched against the MCU's abbreviated names (e.g. 'Thrs' matches 'Threshold').",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer"],
                        "parameter": ["type": "string"],
                        "target_value": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "tolerance": ["type": "number"]
                    ],
                    "required": ["track_name", "insert_slot", "parameter", "target_value"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_instrument_parameters",
                "description": "Read the INSTRUMENT slot's parameter names and formatted values (all MCU pages) for a track via host automation — reaches software instruments whose UIs expose nothing to Accessibility (Q-Sampler, Trilian, ...).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_instrument_parameter",
                "description": "Set one INSTRUMENT parameter through host automation (MCU vpot) with LCD echo readback, same converge/step semantics and compare-and-set contract as logic_mcu_set_plugin_parameter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "parameter": ["type": "string"],
                        "target_value": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "tolerance": ["type": "number"]
                    ],
                    "required": ["track_name", "parameter", "target_value"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_status",
                "description": "Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_mcu_sends",
                "description": "List a track's sends as data via the Mackie Control channel send view: slot number, destination bus, level in dB, position (pre/post fader) and status. UI-independent; competitors' MCPs do not expose sends at all.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_send",
                "description": "Set one send's level in dB on a track, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination. List sends first with logic_mcu_sends.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "send": ["type": "integer", "description": "Send slot 1-8."],
                        "level_db": ["type": "number", "description": "Target level in dB, e.g. -9.0."],
                        "expected_current_value": ["type": "string", "description": "Abort unless the current LCD value matches (e.g. '-9.0dB' or '-9.0')."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "send", "level_db"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_record_automation",
                "description": "Write an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2. Takes real time (the automated range, twice with verify)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "parameter": ["type": "string", "description": "v1: 'volume' only."],
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number", "description": "1-based, fractions allowed. Default 1."],
                                    "db": ["type": "number", "description": "Target volume in dB, e.g. -12.0."]
                                ],
                                "required": ["bar", "db"]
                            ]
                        ],
                        "ramp": ["type": "boolean", "description": "Default true: smooth linear ramps between points."],
                        "verify": ["type": "boolean", "description": "Default true: replay the range in Read and sample the fader echo per point."]
                    ],
                    "required": ["track_name", "points"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_record_midi",
                "description": "Compose MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). Recording takes real time: bars x beats x 60/BPM seconds. The region can be removed with Undo in Logic.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Software instrument track to record onto (not a track stack)."],
                        "track_number": ["type": "integer"],
                        "notes": [
                            "type": "array",
                            "description": "The notes to record.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "pitch": ["description": "MIDI number 0-127 or a name like 'C3' (= MIDI 60, Logic convention), 'F#1', 'Bb2'."],
                                    "bar": ["type": "integer", "description": "Absolute bar position (1 = project start)."],
                                    "beat": ["type": "number", "description": "Beat within the bar, 1-based; fractions allowed (1.5 = offbeat). Default 1."],
                                    "duration_beats": ["type": "number", "description": "Length in beats. Default 1."],
                                    "velocity": ["type": "integer", "description": "1-127, default 100."],
                                    "channel": ["type": "integer", "description": "MIDI channel 1-16, default 1."]
                                ],
                                "required": ["pitch", "bar"]
                            ]
                        ],
                        "cc_events": [
                            "type": "array",
                            "description": "MIDI CC events recorded alongside the notes — e.g. mod-wheel sweeps (cc 1), expression (cc 11). Emit many points for smooth curves.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number", "description": "1-based, fractions allowed."],
                                    "cc": ["type": "integer", "description": "Controller number 0-127."],
                                    "value": ["type": "integer", "description": "0-127."],
                                    "channel": ["type": "integer", "description": "1-16, default 1."]
                                ],
                                "required": ["bar", "cc", "value"]
                            ]
                        ],
                        "pitch_bends": [
                            "type": "array",
                            "description": "Pitch-bend events: value -8192..8191 (0 = center). Emit many points for smooth bends, and return to 0 at the end.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number"],
                                    "value": ["type": "integer"],
                                    "channel": ["type": "integer"]
                                ],
                                "required": ["bar", "value"]
                            ]
                        ],
                        "start_bar": ["type": "integer", "description": "Recording start bar (>= 2); default = the earliest event's bar."],
                        "tempo": ["type": "number", "description": "Override BPM; default reads the control bar."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar."],
                        "verify_render": ["type": "boolean", "description": "Default true: freeze-render the recorded bars afterwards and return slice metrics as proof."],
                        "speed": ["type": "number", "description": "Optional fast mode: record at speed x tempo (1-8, default 1) and scale event times — same bar positions in a fraction of the wall time. Default 1 keeps real-time recording so the take is audible as it happens; higher speeds trade timing precision (jitter scales with speed) and chipmunked monitoring."],
                        "sync_compensation_ms": ["type": "number", "description": "Timecode display latency compensated in the beat-edge sync, default 45 ms (measured). Raise if notes land early, lower if late."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "notes"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_create_track",
                "description": "Create a new track (software_instrument or audio) via Logic's key command, answering the Create New Track dialog automatically. Verified by the track count increasing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "description": "'software_instrument' (default) or 'audio'."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_list_regions",
                "description": "The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Optional: only this track's regions."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_select_region",
                "description": "Select exactly one region (by track + region_name and/or start_bar; ambiguity is refused with candidates listed). exclusive (default true) clears all other region selections first, so a following edit key command (cut/copy/delete/nudge) touches only this region. Verified via the element's selection state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "exclusive": ["type": "boolean", "description": "Default true: clear other selections first."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_delete_region",
                "description": "DESTRUCTIVE: delete one region (selected exclusively first; refuses unless exactly ONE region is selected project-wide right before Delete fires). Verified against the arrangement map; Undo restores.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_move_region",
                "description": "Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). Whole-bar moves are verified exactly against the arrangement map.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer", "description": "Which region (its current start bar)."],
                        "by_bars": ["type": "integer", "description": "Positive = right, negative = left."],
                        "by_beats": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_copy_region",
                "description": "Copy (or move, with move: true = Cut) one region to a target bar, optionally onto another track: exclusive select, Copy/Cut, select destination track, park playhead, Paste. Verified by the region appearing at the target bar in the arrangement map.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "to_bar": ["type": "integer"],
                        "to_track": ["type": "string", "description": "Destination track; default same track."],
                        "move": ["type": "boolean", "description": "true uses Cut instead of Copy (moves across tracks)."]
                    ],
                    "required": ["track_name", "to_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_tempo",
                "description": "Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm. Assumes constant project tempo.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bpm": ["type": "number", "description": "Target tempo, 5-990."],
                        "expected_current_bpm": ["type": "number", "description": "Abort unless the current tempo matches."]
                    ],
                    "required": ["bpm"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_save_project",
                "description": "Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns already_saved when there is nothing to save.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "expected_project_path": ["type": "string", "description": "Recommended: absolute .logicx path that must match the open project."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_new_project",
                "description": "Create a NEW Logic project at the given .logicx path — dialog-free, from a bundled empty project template — and open it. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. The created project is already saved on disk.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute destination path ending in .logicx; must not already exist."],
                        "if_current_modified": ["type": "string", "description": "'fail' (default), 'save' or 'dont_save' — what to do with the currently open project's unsaved changes."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_open_project",
                "description": "Open an existing .logicx project. Single-project semantics as logic_new_project: unsaved changes in the current project require an explicit if_current_modified decision.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to an existing .logicx."],
                        "if_current_modified": ["type": "string", "description": "'fail' (default), 'save' or 'dont_save'."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_project",
                "description": "Close the open project via AppleScript. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "saving": ["type": "string", "description": "'yes' saves before closing; 'no' discards unsaved changes."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["saving"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_setup_key_commands",
                "description": "One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped. Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_trigger_key_command",
                "description": "Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. CAUTION with Undo: the menu shows no operation name, so only fire it right after a known edit.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Registered command name, e.g. 'Toggle Track Freeze'."],
                        "note": ["type": "integer", "description": "MIDI note of a registered command."],
                        "channel": ["type": "integer", "description": "MIDI channel, default 16."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_render_track",
                "description": "Render ONE track offline to an audio file with ZERO dialogs, via Track Freeze: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Track to render, matched against MCU LCD names or AX track headers."],
                        "track_number": ["type": "integer", "description": "Optional AX row number to disambiguate duplicates."],
                        "label": ["type": "string", "description": "Filename label; default is derived from the track name."],
                        "start_bar": ["type": "integer", "description": "With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start)."],
                        "end_bar": ["type": "integer", "description": "Exclusive: the slice ends where this bar begins."],
                        "tempo": ["type": "number", "description": "Override BPM for the bar math; default reads the control bar. Constant tempo assumed."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar's time signature."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_command",
                "description": "Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cmd": ["type": "string"],
                        "button": ["type": "string"],
                        "channel": ["type": "integer"],
                        "index": ["type": "integer"],
                        "value": ["type": "integer"],
                        "delta": ["type": "integer"],
                        "note": ["type": "integer"],
                        "bytes": ["type": "array", "items": ["type": "integer"]]
                    ],
                    "required": ["cmd"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_sensor_capture",
                "description": "OPTIONAL ADD-ON (requires the LogicMCPSensor AU; bounce/render tools do not). Bounce the most recent audio heard at each active LogicMCPSensor insert point to a 16-bit WAV file (up to 45 seconds back), so a human or an audio-capable model can LISTEN to the mix rather than only read meter values. Returns file paths. Read-only with respect to Logic.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "seconds": ["type": "number", "description": "How far back to capture, default 8, max 45."],
                        "label": ["type": "string", "description": "Filename label, e.g. 'baseline'."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_sensor_read",
                "description": "OPTIONAL ADD-ON (requires the LogicMCPSensor AU; bounce/render tools do not). Read live audio feature frames (peak/RMS in dBFS, host beat, tempo, transport state) published by LogicMCPSensor Audio Unit instances inserted in Logic. Returns the latest frame plus aggregates over window_seconds per sensor instance, with a stale flag when a sensor has stopped publishing. Read-only; requires the sensor AU to be inserted on a track, bus or output in Logic.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_seconds": ["type": "number", "description": "Aggregation window, default 3 seconds."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_get_transport",
                "description": "Read the transport state from the control bar: playing, recording, cycle, playhead bar/beat, tempo, time signature, key signature, metronome, count-in. Read-only. Fields whose control bar element is missing are null.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_set_cycle",
                "description": "Turn cycle (loop) mode on or off via the control bar Cycle button and verify the new state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_playing",
                "description": "Start or stop playback via the control bar Play button and verify the new state. Starting plays from the current playhead position (or the cycle range when cycle is on).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "playing": ["type": "boolean"]
                    ],
                    "required": ["playing"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_playhead",
                "description": "Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bar": ["type": "integer"],
                        "beat": ["type": "integer"]
                    ],
                    "required": ["bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_cycle_range",
                "description": "Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies via the region's bar-denominated size description, and restores the playhead. The target range must be visible in the ruler. Optionally turns cycle on/off afterwards via 'enabled'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer", "description": "1-based bar where the cycle starts."],
                        "end_bar": ["type": "integer", "description": "Bar where the cycle ends (exclusive right locator, as shown in Logic)."],
                        "enabled": ["type": "boolean", "description": "When given, turn cycle mode on or off after setting the range."]
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_select_track",
                "description": "Select a track by name (and optional 1-based track number) so its channel strip is exposed in the inspector. Writes AXSelectedChildren on the Tracks header group, falls back to the header's Has Focus button, and verifies through both the header's selected state and the inspector strip. Fails with ambiguous when several visible tracks share the name, and restores the previous selection if verification fails. Only tracks whose headers are currently rendered can be selected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_stack",
                "description": "Expand or collapse a track stack by pressing its disclosure triangle, verifying the new state, and reporting which subtracks were revealed or hidden. Fails with not_exposed if the track is not a stack. Subtracks of a collapsed stack are otherwise invisible to logic_list_tracks and logic_select_track.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact name of the stack's main track."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expanded": ["type": "boolean", "description": "true to show the stack's subtracks, false to hide them."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name", "expanded"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_survey_plugins",
                "description": "Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Takes a few seconds per insert. Use to map which plugins are controllable through this MCP.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_add_plugin",
                "description": "Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string", "description": "Menu title of the plugin, e.g. 'Gain', 'Channel EQ', 'Decapitator'."],
                        "format": ["type": "string", "description": "Channel format submenu item when offered, default 'Stereo'."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_remove_plugin",
                "description": "Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer"]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_mute",
                "description": "Mute or unmute a track via its inspector channel strip mute button, verified by readback. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_solo",
                "description": "Solo or unsolo a track via its inspector channel strip solo button, verified by readback. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_volume",
                "description": "Set a track's volume fader to a target dB value (e.g. -14.2, 0.0) by converging the inspector strip fader against its dB readout. Reports before/after dB. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "db": ["type": "number"],
                        "tolerance_db": ["type": "number"]
                    ],
                    "required": ["track_name", "db"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_pan",
                "description": "Set a track's pan/balance knob position (integer, typically -64..63 where 0 is center) via the inspector strip, verified by readback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "position": ["type": "integer"]
                    ],
                    "required": ["track_name", "position"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_open_plugin",
                "description": "Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify that the window appeared. If the window was already open it is identified via its toggle behaviour and restored. Fails closed on not_found, ambiguous (two inserts with the same plugin), not_exposed and verification_failed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin display name; truncated slot names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "1-based insert slot index; required when the same plugin occupies several slots."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is pressed."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_plugin",
                "description": "Close the plugin window of one insert on the named (selected) track by toggling the insert's open button, verifying that a window disappeared. Precise even when several plugin windows share the same title. If the plugin was not open, the accidentally opened window is closed again and precondition_failed is returned.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer", "description": "1-based insert slot index; required when the same plugin occupies several slots."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_plugin_window",
                "description": "Close one plugin window by pressing its close button and verifying it disappeared. Refuses to close project windows (any window with a document) and fails with ambiguous when several windows share the title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_list_plugin_parameters",
                "description": "List semantically exposed, writable parameters in an open Logic plugin window.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string", "description": "Exact Logic plugin window title, usually the track name."]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_plugin_parameter",
                "description": "Set one accessible plugin parameter through its formatted text field, then read it back. Restores the prior value on verification failure.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"]
                    ],
                    "required": ["window_title", "parameter", "expected_current_value", "target_value"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func response(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
    }

    private func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            log("failed to serialize response")
            return
        }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func log(_ message: String) {
        let line = "[\(serverName)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

if CommandLine.arguments.contains("--bridge") {
    LogicMCUBridge.bridgeMain()
}
MCUBridge.ensureRunning()
MCPServer().run()
