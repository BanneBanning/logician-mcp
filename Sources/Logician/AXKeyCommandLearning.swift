import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Key command learning (Key Commands window automation)

    /// Finds or opens the Key Commands window. NEVER walk its full row tree
    /// (~1400 rows times out) — always filter through the search field.
    func keyCommandsWindow() throws -> AXUIElement {
        func existing() throws -> AXUIElement? {
            try logicWindows().first {
                stringAttribute($0, kAXTitleAttribute as String).contains("Key Command")
            }
        }
        if let window = try existing() { return window }
        try pressMenuItem(containing: "Edit", underMenu: "Key Commands")
        Thread.sleep(forTimeInterval: 1.5)
        guard let window = try existing() else {
            throw LogicianError.windowNotFound("Key Commands window after menu press")
        }
        return window
    }

    func closeKeyCommandsWindow() {
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
        _ targets: [(search: String, name: String, preferredNote: Int)],
        forceRelearn: Bool = false
    ) throws -> [[String: Any]] {
        let window = try keyCommandsWindow()
        defer { closeKeyCommandsWindow() }
        guard let search = children(of: window).first(where: { field in
            stringAttribute(field, kAXRoleAttribute as String) == "AXTextField"
                && children(of: field).contains {
                    stringAttribute($0, kAXDescriptionAttribute as String) == "search"
                }
        }) else { throw LogicianError.windowNotFound("Key Commands search field") }

        func findOutline(_ element: AXUIElement) -> AXUIElement? {
            firstDescendant(of: element, maximumDepth: AXDepth.keyCommandsOutline) {
                let role = stringAttribute($0, kAXRoleAttribute as String)
                return role == "AXOutline" || role == "AXTable"
            }
        }
        func rowTexts(_ row: AXUIElement) -> [String] {
            var texts: [String] = []
            collect(from: row, maximumDepth: AXDepth.keyCommandsRowText) { element in
                if stringAttribute(element, kAXRoleAttribute as String) == "AXStaticText" {
                    let value = stringAttribute(element, kAXValueAttribute as String)
                    if !value.isEmpty { texts.append(value) }
                }
            }
            return texts
        }
        /// Searches the window but never descends INTO the command list: the
        /// outline holds thousands of rows and nothing that is looked for
        /// here. The outline/table itself is still returned when it matches.
        func findIn(_ root: AXUIElement,
                    _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
            var match: AXUIElement?
            walk(from: root, maximumDepth: AXDepth.keyCommandsControl) { element in
                if predicate(element) { match = element; return .stop }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXOutline" || role == "AXTable" { return .skipChildren }
                return .descend
            }
            return match
        }
        func dismissConflictAlert() -> Bool {
            guard let windows = try? logicWindows() else { return false }
            for candidate in windows {
                var isConflict = false
                var cancel: AXUIElement?
                collect(from: candidate, maximumDepth: AXDepth.keyCommandsConflictAlert) { element in
                    let role = stringAttribute(element, kAXRoleAttribute as String)
                    if role == "AXStaticText",
                       stringAttribute(element, kAXValueAttribute as String)
                           .contains("already assigned") { isConflict = true }
                    if role == "AXButton",
                       stringAttribute(element, kAXTitleAttribute as String) == "Cancel" {
                        cancel = element
                    }
                }
                if isConflict, let button = cancel {
                    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.5)
                    return true
                }
            }
            return false
        }
        func rowMatching(_ name: String) -> AXUIElement? {
            guard let outline = findOutline(window) else { return nil }
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
            if !forceRelearn, pre.contains("Note \(target.preferredNote)") {
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
            guard let learn = findIn(window, {
                stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                    && stringAttribute($0, kAXTitleAttribute as String) == "Learn New Assignment"
            }) else {
                results.append(["name": target.name, "status": "no_learn_checkbox"])
                continue
            }
            var deletedStale = 0
            if forceRelearn {
                // Wipe the command's existing controller assignments first —
                // repeated learning otherwise stacks duplicates, and bindings
                // referencing removed control-surface devices never fire. The
                // keyboard shortcut is untouched (separate Key section).
                // Every delete re-renders the panel, so the table AND its rows
                // must be re-found fresh on every iteration.
                func assignmentRows() -> [AXUIElement] {
                    guard let table = findIn(window, {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXTable"
                    }) else { return [] }
                    return children(of: table).filter {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXRow"
                    }
                }
                let initialCount = assignmentRows().count
                for _ in 0..<24 {
                    guard let staleRow = assignmentRows().first else { break }
                    _ = AXUIElementSetAttributeValue(
                        staleRow, kAXSelectedAttribute as CFString, kCFBooleanTrue
                    )
                    Thread.sleep(forTimeInterval: 0.2)
                    guard let deleteButton = findIn(window, {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                            && stringAttribute($0, kAXTitleAttribute as String) == "Delete Assignment"
                    }) else { break }
                    _ = AXUIElementPerformAction(deleteButton, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                deletedStale = max(0, initialCount - assignmentRows().count)
                if deletedStale > 0 {
                    // The deletions re-render the whole panel and DROP the
                    // command row's selection — re-select it or the learn
                    // assigns to nothing and silently fails.
                    if let freshRow = rowMatching(target.name) {
                        _ = AXUIElementSetAttributeValue(
                            freshRow, kAXSelectedAttribute as CFString, kCFBooleanTrue
                        )
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            var learned: Int?
            let preLearnText = rowMatching(target.name).map { rowTexts($0).joined(separator: " ") } ?? pre
            for candidate in [target.preferredNote, (target.preferredNote + 20) % 128,
                              (target.preferredNote + 40) % 128] {
                // re-find on every attempt: the wipe re-renders the panel and
                // makes earlier element references silently inert
                let freshLearn = findIn(window, {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                        && stringAttribute($0, kAXTitleAttribute as String) == "Learn New Assignment"
                }) ?? learn
                if stringAttribute(freshLearn, kAXValueAttribute as String) != "1" {
                    _ = AXUIElementPerformAction(freshLearn, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                _ = try? MCUBridge.send(.keycmd(note: candidate, channel: 16))
                Thread.sleep(forTimeInterval: 1.0)
                if dismissConflictAlert() { continue } // collision: next candidate
                var verified = false
                for _ in 0..<4 {
                    if let fresh = rowMatching(target.name) {
                        let text = rowTexts(fresh).joined(separator: " ")
                        // Logic displays some notes symbolically (e.g. note 109
                        // on the MCU device shows as "F2 (Modifiers ...)"), so
                        // "Note N" is not always present — any change in the
                        // row's assignment display counts as the learn landing.
                        if text.contains("Note \(candidate)") || text != preLearnText {
                            verified = true
                            break
                        }
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
                var entry: [String: Any] = ["name": target.name, "status": "learned", "midi_note": note]
                if deletedStale > 0 { entry["stale_assignments_deleted"] = deletedStale }
                results.append(entry)
            } else {
                results.append(["name": target.name, "status": "failed",
                                "note": "all candidate notes collided or verification failed"])
            }
            if let finalLearn = findIn(window, {
                stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                    && stringAttribute($0, kAXTitleAttribute as String) == "Learn New Assignment"
            }) ?? Optional(learn),
               stringAttribute(finalLearn, kAXValueAttribute as String) == "1" {
                _ = AXUIElementPerformAction(finalLearn, kAXPressAction as CFString)
            }
        }
        _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, "" as CFString)
        _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
        return results
    }

}
