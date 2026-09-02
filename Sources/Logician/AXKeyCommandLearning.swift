import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// Whether `relearn`'s Delete-Assignment loop may run at all.
///
/// The loop presses Delete Assignment on the rows of the first `AXTable` the
/// Key Commands window publishes. That is meant to be the small assignments
/// table for the selected command — but `keyCommandsOutline` accepts
/// `AXOutline` OR `AXTable` for the ~1400-row COMMAND list, i.e. nothing in
/// this codebase knows which role Logic gives that list. If it is a table, the
/// first table found is the command list, and the loop would delete the user's
/// real key assignments up to 24 times over, on the path whose whole purpose
/// is repair. Persisted key commands are outside every project, so no Undo and
/// no sandbox protocol reaches them.
///
/// Pure so the policy is testable without Logic.
enum KeyCommandRelearnGuard {
    static func refusal(commandListRole: String?, assignmentTableIsCommandList: Bool) -> String? {
        guard let commandListRole else {
            return "relearn refused: the Key Commands window's command list could not be "
                + "identified, so the assignments table cannot be proven to be a different "
                + "element. NOTHING WAS DELETED and nothing was bound - the delete loop is only "
                + "safe when the two are known to be distinct. Learn without relearn: true (that "
                + "adds an assignment and deletes none), or remove the old assignment by hand in "
                + "Logic's Key Commands window (select the command, Delete Assignment)."
        }
        guard assignmentTableIsCommandList else { return nil }
        return "relearn refused: Logic publishes this window's command list as an "
            + "\(commandListRole), and it is the SAME element the assignments table would be "
            + "found as - so the Delete Assignment loop would delete the user's own key "
            + "commands, not this command's controller assignments. NOTHING WAS DELETED and "
            + "nothing was bound. Learn without relearn: true (that adds an assignment and "
            + "deletes none), or remove the old assignment by hand in Logic's Key Commands "
            + "window (select the command, Delete Assignment)."
    }
}

extension LogicAccessibility {
    // MARK: - Key command learning (Key Commands window automation)

    /// Finds or opens the Key Commands window. NEVER walk its full row tree
    /// (~1400 rows times out) — always filter through the search field.
    func keyCommandsWindow() throws -> AXUIElement {
        func existing() throws -> AXUIElement? {
            try logicWindows().first {
                stringAttribute($0, kAXTitleAttribute as String)
                    .contains(LogicUIStrings.Window.keyCommandsFragment)
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
            containing: LogicUIStrings.Menu.editAssignments,
            underMenu: LogicUIStrings.Menu.keyCommands,
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
            stringAttribute($0, kAXTitleAttribute as String)
                    .contains(LogicUIStrings.Window.keyCommandsFragment)
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
                .localizedCaseInsensitiveContains(LogicUIStrings.Element.search) { return true }
            return children(of: candidate).contains {
                stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.search
            }
        }) else { throw LogicianError.windowNotFound("Key Commands search field") }
        return field
    }

    /// Waits for an attribute to read back the value a write or a press was
    /// supposed to produce, and returns the moment it does. `timeout` is the
    /// CAP, not the cost: an AX write is synchronous and its effect is
    /// readable in single-digit milliseconds, so what used to be a flat sleep
    /// is now paid only when Logic is actually slow.
    private func pollKeyCommandsValue(
        _ element: AXUIElement, _ attribute: String, equals expected: String,
        timeout: TimeInterval, interval: TimeInterval = 0.02
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if stringAttribute(element, attribute) == expected { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: interval)
        }
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
        // Leave the user's filter field as it was found, on the way out of a
        // refusal or a bridge failure as much as on the way out of a success.
        // Registered after the close so it runs BEFORE it.
        defer {
            _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, "" as CFString)
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
        }

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
                           .contains(LogicUIStrings.AlertMarker.alreadyAssigned) { isConflict = true }
                    if role == "AXButton",
                       stringAttribute(element, kAXTitleAttribute as String)
                           == LogicUIStrings.Button.cancel {
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

        func isLearnCheckBox(_ element: AXUIElement) -> Bool {
            stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox"
                && stringAttribute(element, kAXTitleAttribute as String)
                    == LogicUIStrings.Button.learnNewAssignment
        }

        // The note Logic is armed to capture goes out over the MCU bridge, and
        // that send is often this PROCESS's first bridge contact: nothing
        // starts the daemon at launch, and only `logic_health` calls
        // `ensureRunning` otherwise. Starting it inside the send hid up to 3 s
        // of daemon start-up (30 × 100 ms) inside a phase the profile prices
        // at 1-5 ms. Do it here, once, on the first note actually sent, and
        // report what it cost.
        var bridgeStartMs: Int?
        var bridgeCostReported = false
        func sendLearnNote(_ note: Int) throws {
            if bridgeStartMs == nil {
                let clock = Date()
                MCUBridge.ensureRunning()
                bridgeStartMs = Int((Date().timeIntervalSince(clock) * 1000).rounded())
            }
            func failure(_ detail: String) -> LogicianError {
                .writeFailed(
                    "the MCU bridge did not send key-command note \(note) on channel 16: \(detail). "
                        + "NOTHING WAS LEARNED - Logic was armed for a note that never arrived, so "
                        + "this is a fault in this server's own MIDI plane, not in Logic's key "
                        + "command set. Run logic_health (it starts and audits the bridge daemon), "
                        + "then call again."
                )
            }
            let response: BridgeResponse
            do {
                response = try MCUBridge.send(.keycmd(note: note, channel: 16))
            } catch {
                throw failure(error.localizedDescription)
            }
            // `try?` used to swallow this. A daemon that answers `ok: false`
            // is not a dead socket, so `transact`'s self-heal never fired and
            // the flow waited 1.0 s for a note nobody sent, failed
            // verification, tried two more the same way and reported "all
            // candidate notes collided" — pointing the agent at Logic.
            guard response.ok else {
                throw failure(response.error ?? "the daemon answered ok: false without a reason")
            }
        }
        func annotateBridgeCost(_ entry: inout [String: Any]) {
            guard !bridgeCostReported, let ms = bridgeStartMs, ms >= 100 else { return }
            entry["bridge_start_ms"] = ms
            entry["bridge_start_note"] = "the MCU bridge daemon was not running and had to be "
                + "started; that start is most of this call's cost."
            bridgeCostReported = true
        }

        // Logic scopes an assignment to the ENDPOINT's unique ID and the row
        // text carries no port identity, so this is the one moment the
        // identity can be recorded. Read once per call (0.8 ms warm).
        let portUniqueID = sourceUniqueID(named: commandsPortName).map(Int.init)

        var results: [[String: Any]] = []
        for target in targets {
            _ = AXUIElementSetAttributeValue(
                search, kAXValueAttribute as CFString, target.search as CFString
            )
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
            // KEPT deliberately: this write makes Logic re-filter ~1400 rows,
            // which is app work rather than an AX write settling, and no
            // positive witness of the re-filter has been measured. Turning it
            // into a poll on `visibleRowNames()` is the right transform and
            // needs a live measurement this change did not take.
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
            let texts = rowTexts(row)
            let pre = texts.joined(separator: " ")
            // The command's own name is dropped: Logic has commands with the
            // word "Note" in their titles, and only the ASSIGNMENT columns say
            // what this row already answers to.
            let assignment = texts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let existing = KeyCommandRegistry.rowAssignment(
                assignment, preferredNote: target.preferredNote
            )
            if !forceRelearn, case .preferred = existing {
                var already: [String: Any] = ["name": resolvedName, "status": "already_learned",
                                              "midi_note": target.preferredNote]
                if resolvedName != target.name { already["requested_name"] = target.name }
                let registration = KeyCommandRegistry.register(
                    note: target.preferredNote, channel: 16, name: resolvedName,
                    notes: "verified present in the Key Commands window",
                    source: source, search: target.search, portUniqueID: portUniqueID
                )
                if let refusal = registration.refusal {
                    already["warning"] = "The assignment is in Logic but was NOT recorded: "
                        + refusal
                }
                results.append(already)
                continue
            }
            // A command that already carries a DIFFERENT note is the silent
            // duplicate-stacking case: the old check only recognised the note
            // this call had just picked, so a first learn whose registry entry
            // was lost — or a note picked differently, or the user's own
            // controller assignment — was answered by adding a SECOND
            // assignment. Additive and removable, but silent, and the second
            // one is what `relearn` exists to clean up.
            if !forceRelearn, case .other(let notes) = existing {
                let spelled = notes.map(String.init).joined(separator: ", ")
                results.append([
                    "name": resolvedName, "status": "already_assigned",
                    "existing_notes": notes,
                    "existing_assignment": assignment,
                    "note": "NOTHING WAS BOUND. '\(resolvedName)' already carries a MIDI-note "
                        + "assignment (note \(spelled)) in the user's key command set, and "
                        + "learning again would STACK a second one rather than replace it. If "
                        + "that assignment is this server's, fire it with "
                        + "logic_trigger_key_command {note: \(notes[0]), channel: 16} (add it to "
                        + "the registry first if logic_list_key_commands does not show it). To "
                        + "replace it, call again with relearn: true - that deletes the existing "
                        + "controller assignments first. The keyboard shortcut is untouched "
                        + "either way."
                ])
                continue
            }
            _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            // Pattern #9 + #2: the AX write is synchronous and the selection
            // reads back, so the flat 0.5 s that sat here was charged to every
            // learn. Same 0.5 s, now the CAP on a positive check instead.
            _ = pollKeyCommandsValue(row, kAXSelectedAttribute as String, equals: "1", timeout: 0.5)
            guard var learn = findIn(window, isLearnCheckBox) else {
                results.append(["name": resolvedName, "status": "no_learn_checkbox"])
                continue
            }
            var deletedStale = 0
            var commandListRole: String?
            var wipeTableFound = false
            if forceRelearn {
                // Wipe the command's existing controller assignments first —
                // repeated learning otherwise stacks duplicates, and bindings
                // referencing removed control-surface devices never fire. The
                // keyboard shortcut is untouched (separate Key section).
                // Every delete re-renders the panel, so the table AND its rows
                // must be re-found fresh on every iteration.
                //
                // SAFETY. The table is found as "the first AXTable a depth-7
                // walk meets", and `keyCommandsOutline` matches AXOutline OR
                // AXTable — i.e. this codebase does not know which role Logic
                // gives the ~1400-row COMMAND list. If that list is published
                // as a table, the first table found IS the command list, and
                // this loop would press Delete Assignment on the user's real
                // key commands up to 24 times, on the path whose whole purpose
                // is repair. So the assignment table must be provably a
                // DIFFERENT element than the command list, and every re-find
                // re-proves it rather than trusting the first look.
                func assignmentTable() -> AXUIElement? {
                    guard let table = findIn(window, {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXTable"
                    }) else { return nil }
                    guard let list = keyCommandsOutline(in: window) else { return nil }
                    return CFEqual(list, table) ? nil : table
                }
                let commandList = keyCommandsOutline(in: window)
                commandListRole = commandList.map {
                    stringAttribute($0, kAXRoleAttribute as String)
                }
                let firstTable = findIn(window, {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXTable"
                })
                let coincides = firstTable.map { table in
                    commandList.map { CFEqual($0, table) } ?? true
                } ?? false
                if let refusal = KeyCommandRelearnGuard.refusal(
                    commandListRole: commandListRole, assignmentTableIsCommandList: coincides
                ) {
                    var entry: [String: Any] = [
                        "name": resolvedName, "status": "relearn_refused", "note": refusal
                    ]
                    if let commandListRole { entry["command_list_role"] = commandListRole }
                    results.append(entry)
                    continue
                }
                func assignmentRows() -> [AXUIElement] {
                    guard let table = assignmentTable() else { return [] }
                    return children(of: table).filter {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXRow"
                    }
                }
                wipeTableFound = assignmentTable() != nil
                let initialCount = wipeTableFound ? assignmentRows().count : 0
                for _ in 0..<24 {
                    guard let staleRow = assignmentRows().first else { break }
                    _ = AXUIElementSetAttributeValue(
                        staleRow, kAXSelectedAttribute as CFString, kCFBooleanTrue
                    )
                    Thread.sleep(forTimeInterval: 0.2)
                    guard let deleteButton = findIn(window, {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                            && stringAttribute($0, kAXTitleAttribute as String)
                            == LogicUIStrings.Button.deleteAssignment
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
            var bridgeFailure: LogicianError?
            // Only the wipe and a dismissed conflict alert re-render the
            // panel; on the ordinary path nothing does, so the Learn checkbox
            // is found ONCE (pattern #10) instead of on every attempt.
            var panelReRendered = deletedStale > 0
            let preLearnText = rowMatching(resolvedName).map { rowTexts($0.row).joined(separator: " ") } ?? pre
            for candidate in KeyCommandRegistry.candidateNotes(
                preferred: target.preferredNote, taken: KeyCommandRegistry.takenNotes()
            ) {
                if panelReRendered {
                    // the wipe re-renders the panel and makes earlier element
                    // references silently inert
                    learn = findIn(window, isLearnCheckBox) ?? learn
                    panelReRendered = false
                }
                if stringAttribute(learn, kAXValueAttribute as String) != "1" {
                    _ = AXUIElementPerformAction(learn, kAXPressAction as CFString)
                    // The checkbox's own AXValue is the positive witness, and
                    // the line below already tests it — so the flat 0.4 s here
                    // was a wait for something the code reads. 0.4 s is now
                    // the cap on the poll, not the price of the press.
                    _ = pollKeyCommandsValue(
                        learn, kAXValueAttribute as String, equals: "1", timeout: 0.4
                    )
                }
                do {
                    try sendLearnNote(candidate)
                } catch {
                    // Never leave this loop by throwing: the disarm below has
                    // to run first or Logic stays in Learn New Assignment,
                    // capturing whatever MIDI arrives next.
                    bridgeFailure = (error as? LogicianError)
                        ?? LogicianError.writeFailed(error.localizedDescription)
                    break
                }
                // KEPT deliberately: this one is on the MIDI plane. The note
                // travels to the daemon, out through CoreMIDI and into Logic's
                // learn capture, and none of that is an AX write settling.
                Thread.sleep(forTimeInterval: 1.0)
                if dismissConflictAlert() {
                    panelReRendered = true
                    continue // collision: next candidate
                }
                var verified = false
                for _ in 0..<4 {
                    if let fresh = rowMatching(resolvedName)?.row {
                        let text = rowTexts(fresh).joined(separator: " ")
                        // Logic displays some notes symbolically (e.g. note 109
                        // on the MCU device shows as "F2 (Modifiers ...)"), so
                        // "Note N" is not always present — any change in the
                        // row's assignment display counts as the learn landing.
                        if text.contains(LogicUIStrings.Format.keyCommandNotePrefix + "\(candidate)") || text != preLearnText {
                            verified = true
                            break
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if verified { learned = candidate; break }
            }
            // Disarm BEFORE anything else can leave this iteration: a bridge
            // failure must not walk out of here with Logic still armed and
            // capturing whatever MIDI arrives. The reference found above is
            // reused unless the panel re-rendered under it (an inert element
            // reads neither "0" nor "1", which is itself the signal to
            // re-find) — pattern #10, one find on the ordinary path.
            let armState = stringAttribute(learn, kAXValueAttribute as String)
            if armState != "0" {
                if armState != "1", let fresh = findIn(window, isLearnCheckBox) { learn = fresh }
                if stringAttribute(learn, kAXValueAttribute as String) == "1" {
                    _ = AXUIElementPerformAction(learn, kAXPressAction as CFString)
                }
            }
            if let bridgeFailure { throw bridgeFailure }
            if let note = learned {
                let registration = KeyCommandRegistry.register(
                    note: note, channel: 16, name: resolvedName,
                    notes: "learned automatically by \(source)",
                    source: source, search: target.search, portUniqueID: portUniqueID
                )
                var entry: [String: Any] = ["name": resolvedName, "status": "learned", "midi_note": note]
                // The registry holds the row's OWN spelling; say so when the
                // caller's differed, or a later trigger by the requested name
                // looks like it reached a command nobody registered.
                if resolvedName != target.name { entry["requested_name"] = target.name }
                if deletedStale > 0 { entry["stale_assignments_deleted"] = deletedStale }
                if let commandListRole { entry["command_list_role"] = commandListRole }
                var warnings: [String] = []
                if forceRelearn, !wipeTableFound {
                    warnings.append("relearn found no assignments table for this command, so "
                        + "NOTHING was deleted before the new assignment was made; if the command "
                        + "already answered to a controller assignment it now has two. Remove the "
                        + "extra one in Logic's Key Commands window (select the command, Delete "
                        + "Assignment).")
                }
                if let refusal = registration.refusal {
                    warnings.append("The assignment was made in Logic but was NOT recorded: "
                        + refusal)
                }
                if !warnings.isEmpty { entry["warning"] = warnings.joined(separator: " ") }
                annotateBridgeCost(&entry)
                results.append(entry)
            } else {
                var entry: [String: Any] = [
                    "name": resolvedName, "status": "failed",
                    "note": "all candidate notes collided or verification failed"
                ]
                annotateBridgeCost(&entry)
                results.append(entry)
            }
        }
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
