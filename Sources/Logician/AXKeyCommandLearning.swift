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
        // The menu press alone is NOT enough here: measured 2026-08-28, both
        // AXPress and AXPick on `Logic Pro > Key Commands > Edit Assignments…`
        // report `.success` and open nothing. `settled:` makes the press
        // verified and falls back to the shortcut the item advertises (⌥K on
        // this machine), which does open it — every time, within 0.5 s.
        try ensureLogicFrontmost(for: "the Key Commands window")
        try pressMenuItem(
            containing: "Edit Assignments", underMenu: "Key Commands",
            settled: { ((try? existing()) ?? nil) != nil }
        )
        guard let window = try existing() else {
            throw LogicianError.windowNotFound("Key Commands window after menu press")
        }
        return window
    }

    func closeKeyCommandsWindow() {
        // A close button that is not an element leaves the window open (same
        // as no close button) instead of trapping the server.
        guard let window = try? logicWindows().first(where: {
            stringAttribute($0, kAXTitleAttribute as String).contains("Key Command")
        }), let close = elementAttribute(window, kAXCloseButtonAttribute as String) else { return }
        _ = AXUIElementPerformAction(close, kAXPressAction as CFString)
    }

    /// The window's filter field. Everything in this file goes through it:
    /// the command outline holds ~1400 rows and walking it unfiltered times
    /// out (see `keyCommandsWindow`).
    /// Three ways to recognise it, because Logic has changed which one is
    /// true: in 12.3.1 the field is an `AXTextField` with **subrole
    /// `AXSearchField`** and NO children at all, while the rule this code
    /// shipped with looked for a child described `search` (measured
    /// 2026-08-28 — the old rule matched nothing, which made every learn
    /// attempt fail with "Key Commands search field"). The help text is the
    /// third witness. Any one of them is enough.
    func keyCommandsSearchField(in window: AXUIElement) throws -> AXUIElement {
        guard let field = children(of: window).first(where: { candidate in
            guard stringAttribute(candidate, kAXRoleAttribute as String) == "AXTextField" else {
                return false
            }
            if stringAttribute(candidate, kAXSubroleAttribute as String) == "AXSearchField" {
                return true
            }
            if stringAttribute(candidate, kAXHelpAttribute as String)
                .localizedCaseInsensitiveContains("search") { return true }
            return children(of: candidate).contains {
                stringAttribute($0, kAXDescriptionAttribute as String) == "search"
            }
        }) else { throw LogicianError.windowNotFound("Key Commands search field") }
        return field
    }

    func keyCommandsOutline(in element: AXUIElement) -> AXUIElement? {
        firstDescendant(of: element, maximumDepth: AXDepth.keyCommandsOutline) {
            let role = stringAttribute($0, kAXRoleAttribute as String)
            return role == "AXOutline" || role == "AXTable"
        }
    }

    /// A command row's texts: the name first, then whatever assignment
    /// columns Logic paints (a key equivalent, "Note N", or a symbolic note
    /// name like "F2 (Modifiers ...)").
    func keyCommandsRowTexts(_ row: AXUIElement) -> [String] {
        var texts: [String] = []
        collect(from: row, maximumDepth: AXDepth.keyCommandsRowText) { element in
            if stringAttribute(element, kAXRoleAttribute as String) == "AXStaticText" {
                let value = stringAttribute(element, kAXValueAttribute as String)
                if !value.isEmpty { texts.append(value) }
            }
        }
        return texts
    }

    /// READ-ONLY: which commands Logic's Key Commands window shows for a
    /// search term, with whatever assignment each row already carries.
    /// Nothing is selected, nothing is learned, no assignment is touched - the
    /// window is opened if it was closed, the filter is written, the rows are
    /// read, the filter is cleared and the window closed again.
    ///
    /// This is the answer to "names drift between Logic versions": an agent
    /// can look up the real spelling before asking for a binding.
    func searchKeyCommands(_ term: String, limit: Int = 40) throws -> [[String: Any]] {
        let window = try keyCommandsWindow()
        defer { closeKeyCommandsWindow() }
        let field = try keyCommandsSearchField(in: window)
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, term as CFString)
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        Thread.sleep(forTimeInterval: 1.0)
        defer {
            _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
            _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        }
        guard let outline = keyCommandsOutline(in: window) else { return [] }
        var rows: [[String: Any]] = []
        for row in children(of: outline)
        where stringAttribute(row, kAXRoleAttribute as String) == "AXRow" {
            let texts = keyCommandsRowTexts(row)
            guard let name = texts.first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " *")), !name.isEmpty else { continue }
            var entry: [String: Any] = ["name": name]
            let assignment = texts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !assignment.isEmpty { entry["assignment"] = assignment }
            rows.append(entry)
            if rows.count >= limit { break }
        }
        return rows
    }

    /// Learns MIDI-note assignments for the given commands via the Key
    /// Commands window (search → select row → Learn New Assignment → note on
    /// the Commands port → verify "Note N" in the row). Handles collision
    /// alerts by retrying with alternate notes. Writes successes into the
    /// registry. This MODIFIES the user's active key command set — additive
    /// only, removable via the same window's Delete Assignment.
    func setupKeyCommands(
        _ targets: [(search: String, name: String, preferredNote: Int)],
        forceRelearn: Bool = false,
        source: String = "logic_setup_key_commands"
    ) throws -> [[String: Any]] {
        let window = try keyCommandsWindow()
        defer { closeKeyCommandsWindow() }
        let search = try keyCommandsSearchField(in: window)

        func findOutline(_ element: AXUIElement) -> AXUIElement? { keyCommandsOutline(in: element) }
        func rowTexts(_ row: AXUIElement) -> [String] { keyCommandsRowTexts(row) }
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
        /// Every command name the outline is CURRENTLY showing, in order.
        /// Only ever called on a filtered panel (the search field is written
        /// before every read), so this never walks the ~1400-row unfiltered
        /// tree the header comment warns about.
        func visibleRowNames() -> [String] {
            guard let outline = findOutline(window) else { return [] }
            return children(of: outline)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXRow" }
                .compactMap { row in
                    rowTexts(row).first?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " *"))
                }
                .filter { !$0.isEmpty }
        }
        /// Exact first, then case-insensitively: Logic's own capitalisation is
        /// what the row publishes, and a caller who typed the name from
        /// memory should not get `not_found` over one letter's case. The row's
        /// OWN text is what gets registered, so the registry always holds the
        /// name Logic uses.
        func rowMatching(_ name: String) -> (row: AXUIElement, name: String)? {
            guard let outline = findOutline(window) else { return nil }
            let rows = children(of: outline)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXRow" }
                .compactMap { row -> (AXUIElement, String)? in
                    guard let text = rowTexts(row).first?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " *")),
                        !text.isEmpty else { return nil }
                    return (row, text)
                }
            if let exact = rows.first(where: { $0.1 == name }) { return exact }
            return rows.first { $0.1.caseInsensitiveCompare(name) == .orderedSame }
        }
        /// The near misses for a name that matched no row: whatever the
        /// current filter shows, and — when that is empty — whatever a
        /// broader search on the name's FIRST word shows. Costs one extra
        /// search on a panel that is already open, and turns COVERAGE's open
        /// question 7 ("a wrong search string is a silent not_found") into a
        /// list the caller can pick from.
        func nearMisses(for target: (search: String, name: String, preferredNote: Int)) -> [String] {
            var names = visibleRowNames()
            let firstWord = target.name.split(separator: " ").first.map(String.init)?.lowercased()
            if names.isEmpty, let firstWord, firstWord != target.search.lowercased() {
                _ = AXUIElementSetAttributeValue(
                    search, kAXValueAttribute as CFString, firstWord as CFString
                )
                _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
                Thread.sleep(forTimeInterval: 1.0)
                names = visibleRowNames()
            }
            return Array(names.prefix(25))
        }

        var results: [[String: Any]] = []
        for target in targets {
            _ = AXUIElementSetAttributeValue(
                search, kAXValueAttribute as CFString, target.search as CFString
            )
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
            Thread.sleep(forTimeInterval: 1.0)
            guard let match = rowMatching(target.name) else {
                var entry: [String: Any] = [
                    "name": target.name, "status": "not_found",
                    "searched": target.search,
                    "note": "no Key Commands row matches; localized Logic UI or renamed command? Command names drift between Logic versions - pick one of `candidates` (the rows the panel is showing) and call again with that exact name."
                ]
                let candidates = nearMisses(for: target)
                if !candidates.isEmpty { entry["candidates"] = candidates }
                results.append(entry)
                continue
            }
            let row = match.row
            let resolvedName = match.name
            let pre = rowTexts(row).joined(separator: " ")
            if !forceRelearn, pre.contains("Note \(target.preferredNote)") {
                var already: [String: Any] = ["name": resolvedName, "status": "already_learned",
                                              "midi_note": target.preferredNote]
                if resolvedName != target.name { already["requested_name"] = target.name }
                results.append(already)
                KeyCommandRegistry.register(
                    note: target.preferredNote, channel: 16, name: resolvedName,
                    notes: "verified present in the Key Commands window",
                    source: source, search: target.search
                )
                continue
            }
            _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.5)
            guard let learn = findIn(window, {
                stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                    && stringAttribute($0, kAXTitleAttribute as String) == "Learn New Assignment"
            }) else {
                results.append(["name": resolvedName, "status": "no_learn_checkbox"])
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
                    if let freshRow = rowMatching(resolvedName)?.row {
                        _ = AXUIElementSetAttributeValue(
                            freshRow, kAXSelectedAttribute as CFString, kCFBooleanTrue
                        )
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            var learned: Int?
            let preLearnText = rowMatching(resolvedName).map { rowTexts($0.row).joined(separator: " ") } ?? pre
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
                    if let fresh = rowMatching(resolvedName)?.row {
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
                    note: note, channel: 16, name: resolvedName,
                    notes: "learned automatically by \(source)",
                    source: source, search: target.search
                )
                var entry: [String: Any] = ["name": resolvedName, "status": "learned", "midi_note": note]
                // The registry holds the row's OWN spelling; say so when the
                // caller's differed, or a later trigger by the requested name
                // looks like it reached a command nobody registered.
                if resolvedName != target.name { entry["requested_name"] = target.name }
                if deletedStale > 0 { entry["stale_assignments_deleted"] = deletedStale }
                results.append(entry)
            } else {
                results.append(["name": resolvedName, "status": "failed",
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
        // Every other outcome token in this server is called `state`; these
        // per-command entries have always called it `status`, which made the
        // key-command results the one place an agent had to branch on a
        // different key name — `already_learned` in particular, the only
        // member of the `already_*` no-op family living outside `state`.
        // BOTH keys are emitted for one release: `state` is the one to read,
        // and `status` stays so nothing already reading it breaks (the
        // promotion in `handleLearnKeyCommand` does).
        return results.map { entry in
            guard entry["state"] == nil, let status = entry["status"] else { return entry }
            var mirrored = entry
            mirrored["state"] = status
            return mirrored
        }
    }

}
