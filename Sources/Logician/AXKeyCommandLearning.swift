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

/// The three decisions that decide how many times the Key Commands panel gets
/// WALKED, lifted out of the driver so they can be pinned without Logic.
///
/// Why they are worth pinning. The install round was measured at 223 s for 22
/// commands (live, 2026-09-02) while the literal sleeps on that path account
/// for 3.3-4.1 s each — and the review that sized the gap
/// (`Logician-archive/KEY-COMMANDS-REVIEW.md` §2.1) put the missing ~6 s a
/// command on AX WALKS, not waits: `rowMatching` re-reading every visible row
/// up to six times per target, and a depth-6 walk over every Logic window per
/// candidate note to prove no conflict alert was up. A walk count is not
/// visible in any result and no unit test catches it by accident, so the
/// decisions are pure and the tests COUNT THE CALLS — the shape
/// `resolveTrackStackTarget` uses for the same reason.
enum KeyCommandPanelLook {

    /// What ONE target costs the panel in full looks.
    ///
    /// The rule: **one look per target.** A second happens only on the path
    /// that has nothing to show for the first — a miss whose filter left the
    /// panel EMPTY, where a broader search on the name's first word is the
    /// difference between a bare `not_found` and a list of real spellings the
    /// caller can pick from. Everything after this (the select, the arm, the
    /// verify, the registry write) reads the row this returns.
    struct Look<Row> {
        let match: Row?
        let candidates: [Row]
    }

    static func resolve<Row>(
        look: () -> [Row],
        match: ([Row]) -> Row?,
        widen: (() -> [Row])?
    ) -> Look<Row> {
        let rows = look()
        if let hit = match(rows) { return Look(match: hit, candidates: []) }
        guard rows.isEmpty, let widen else { return Look(match: nil, candidates: rows) }
        return Look(match: nil, candidates: widen())
    }

    /// The verify loop's read of the row it is watching.
    ///
    /// `live` is the row reference this target already holds — one row's
    /// texts, not a walk. `refind` runs ONLY when that reference publishes
    /// nothing, which is what an element inertised by a re-render looks like.
    /// The old loop ran a full `rowMatching` walk on every one of up to four
    /// iterations to answer the same question.
    static func rowText(live: () -> [String], refind: () -> [String]?) -> String? {
        let texts = live()
        if !texts.isEmpty { return texts.joined(separator: " ") }
        guard let fresh = refind(), !fresh.isEmpty else { return nil }
        return fresh.joined(separator: " ")
    }

    /// Whether Logic's window layer has moved enough that a conflict alert
    /// COULD be standing — the gate that keeps the deep alert search off the
    /// common path (no collision, which is nearly every note).
    ///
    /// An alert is a window that was not there, or a sheet on one that was, so
    /// the count of each plus the identity of the windows is a complete
    /// witness of "something could have appeared". Generic over the window
    /// type and its identity test so it can be exercised with plain values.
    static func windowLayerMoved<Window>(
        now: [Window], nowSheets: Int,
        baseline: [Window], baselineSheets: Int,
        sameElement: (Window, Window) -> Bool
    ) -> Bool {
        if now.count != baseline.count { return true }
        if nowSheets != baselineSheets { return true }
        return now.contains { candidate in
            !baseline.contains { sameElement($0, candidate) }
        }
    }
}

/// Logic's own name for "the sheets attached to this window". Not exported by
/// ApplicationServices as a constant, so it is spelled once here rather than
/// twice inline. STRUCTURE, not text: it does not translate.
let keyCommandsSheetsAttribute = "AXSheets"

/// What the Key Commands panel looks like from outside, cheaply. Compared
/// before and after a filter write to know that Logic has re-filtered without
/// reading every row to find out.
struct KeyCommandsFilterFingerprint: Equatable {
    let childCount: Int
    let firstRowName: String
}

/// One row of Logic's Key Commands panel, read once: the element to select,
/// the command's own name (Logic's spelling, which is what gets registered)
/// and every static text the row paints — the assignment columns included,
/// because "what is this command already bound to" and "did the learn land"
/// are both answered from them.
struct KeyCommandsRow {
    let element: AXUIElement
    let name: String
    let texts: [String]

    /// Everything but the command's own name. The name is dropped on purpose:
    /// Logic has commands with the word "Note" in their titles, and only the
    /// ASSIGNMENT columns say what a row already answers to.
    var assignment: String {
        texts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var joined: String { texts.joined(separator: " ") }
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
        // `pressLikelyInert` says so to the poll as well: waiting the full
        // 12 × 0.15 s for an outcome measured never to arrive was 1.8 s of
        // every window open, once per install round (candidate N1).
        try ensureLogicFrontmost(for: "the Key Commands window")
        try pressMenuItem(
            containing: LogicUIStrings.Menu.editAssignments,
            underMenu: LogicUIStrings.Menu.keyCommands,
            pressLikelyInert: true,
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

    /// Look first, then sleep — the shipped poll shape (`lookFirstShouldSleep`).
    /// `timeout` is the CAP, not the cost, and the first look is free, so a
    /// result that has already landed costs nothing.
    @discardableResult
    func pollKeyCommands(
        timeout: TimeInterval, interval: TimeInterval = 0.02, settled: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while true {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: interval) }
            attempt += 1
            if settled() { return true }
            if Date() >= deadline { return false }
        }
    }

    /// Waits for an attribute to read back the value a write or a press was
    /// supposed to produce, and returns the moment it does. `timeout` is the
    /// CAP, not the cost: an AX write is synchronous and its effect is
    /// readable in single-digit milliseconds, so what used to be a flat sleep
    /// is now paid only when Logic is actually slow.
    @discardableResult
    func pollKeyCommandsValue(
        _ element: AXUIElement, _ attribute: String, equals expected: String,
        timeout: TimeInterval, interval: TimeInterval = 0.02
    ) -> Bool {
        pollKeyCommands(timeout: timeout, interval: interval) {
            stringAttribute(element, attribute) == expected
        }
    }

    /// How many rows one look at the Key Commands panel reads.
    ///
    /// The panel this driver looks at is always FILTERED — a search term is
    /// written before every look — and a real term leaves a handful of rows.
    /// The cap is what makes a look SAFE when it is not: between writing a
    /// term and Logic finishing the re-filter, the outline still publishes the
    /// ~1400-row unfiltered list, and reading every one of those rows' static
    /// texts is exactly the timeout `keyCommandsWindow`'s header warns about.
    static let keyCommandsRowScanCap = 120

    /// A filtered look at the Key Commands panel: every row it is showing, in
    /// order, paired with the row's own name text.
    ///
    /// ONE walk, and one place. `rowMatching`, `visibleRowNames` and
    /// `preLearnText` were three separate versions of this walk and the verify
    /// loop ran a fourth, so a single target re-read every visible row up to
    /// SIX times (candidate N6 in profiles/logic_learn_key_command.md): each
    /// one a depth-4 walk to find the outline, then a depth-3 collect of
    /// static texts for every row on screen. That is the most plausible home
    /// of the install round's unexplained ~6 s per command — 223 s measured
    /// live for 22 commands (2026-09-02) against 3.3-4.1 s of literal sleeps.
    /// The row's `texts` travel with it because every caller wants them and
    /// re-reading them is the walk this exists to stop.
    func keyCommandsVisibleRows(
        in outline: AXUIElement, limit: Int = LogicAccessibility.keyCommandsRowScanCap
    ) -> [KeyCommandsRow] {
        var rows: [KeyCommandsRow] = []
        for child in children(of: outline) {
            guard stringAttribute(child, kAXRoleAttribute as String) == "AXRow" else { continue }
            let texts = keyCommandsRowTexts(child)
            guard let text = texts.first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " *")), !text.isEmpty
            else { continue }
            rows.append(KeyCommandsRow(element: child, name: text, texts: texts))
            if rows.count >= limit { break }
        }
        return rows
    }

    /// A CHEAP witness that Logic has re-filtered the command list: how many
    /// children the outline publishes, plus the first row's own name.
    ///
    /// It costs the same on the unfiltered ~1400-row panel as on a five-row
    /// one — one `AXChildren` fetch, a few role reads and one row's texts —
    /// which is the whole point, because the unfiltered panel is exactly what
    /// is on screen while the poll is waiting for the re-filter.
    func keyCommandsFilterFingerprint(in outline: AXUIElement) -> KeyCommandsFilterFingerprint {
        let kids = children(of: outline)
        let firstRow = kids.first { stringAttribute($0, kAXRoleAttribute as String) == "AXRow" }
        return KeyCommandsFilterFingerprint(
            childCount: kids.count,
            firstRowName: firstRow.flatMap { keyCommandsRowTexts($0).first } ?? ""
        )
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
        // The outline is resolved BEFORE the term is written so the re-filter
        // has a witness to be measured against (see `keyCommandsFilter
        // Fingerprint`). Logic re-renders the outline's rows, never the
        // outline itself, so one depth-4 walk serves the whole call.
        let outline = keyCommandsOutline(in: window)
        let before = outline.map { keyCommandsFilterFingerprint(in: $0) }
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, term as CFString)
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        // Was a flat `sleep(1.0)`. Same second, now the CAP on a positive
        // check: Logic re-filtering ~1400 rows is app work (so this is a poll
        // and not a deletion), but it is not a second's worth on every call.
        if let outline, let before {
            pollKeyCommands(timeout: 1.0) {
                keyCommandsFilterFingerprint(in: outline) != before
            }
        }
        defer {
            _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
            _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        }
        guard let outline else { return [] }
        return keyCommandsVisibleRows(in: outline, limit: limit).map { row in
            var entry: [String: Any] = ["name": row.name]
            if !row.assignment.isEmpty { entry["assignment"] = row.assignment }
            return entry
        }
    }

    /// Learns MIDI-note assignments for the given commands via the Key
    /// Commands window (search → select row → Learn New Assignment → note on
    /// the Commands port → verify "Note N" in the row). Handles collision
    /// alerts by retrying with alternate notes. Writes successes into the
    /// registry. This MODIFIES the user's active key command set — additive
    /// only, removable via the same window's Delete Assignment.
    ///
    /// # Where the time goes, and where it went (2026-09-03)
    ///
    /// The install round was measured live once, 2026-09-02: `logic_setup_key
    /// _commands {relearn: true}`, 22 commands, **223 s — 10.1 s each**, while
    /// the literal `Thread.sleep` constants on that path account for only
    /// 3.3-4.1 s. Six seconds a command were unexplained by the waits, and the
    /// review that sized it (`Logician-archive/KEY-COMMANDS-REVIEW.md` §2.1)
    /// put them on the two unsized AX WALKS: `rowMatching` re-reading every
    /// visible row up to six times per target, and a depth-6 `collect` over
    /// every Logic window — the project window included — run once per
    /// candidate note to prove that no conflict alert was up.
    ///
    /// So this driver now takes **one full look at the panel per target** and
    /// carries the row it found (`KeyCommandsRow`) through the select, the
    /// arm, the verify and the registry write; every remaining wait is a
    /// look-first poll whose constant is the CAP, not the cost; and the
    /// conflict alert is looked for only where an alert can be — by window
    /// IDENTITY, skipping row trees, stopping at the button.
    ///
    /// Nothing here deletes a wait that was insurance. The MIDI-plane second
    /// after the note is FOLDED into the poll that was always going to look
    /// (pattern #11), not removed: the note really does travel daemon →
    /// CoreMIDI → Logic's learn capture, and no AX write settles that.
    ///
    /// **Not re-measured live.** These two tools rewrite the user's persisted
    /// key command set — outside the project file, outside Undo, outside the
    /// sandbox protocol — so they are the campaign's only code-triage-only
    /// pair and the round is re-clocked on a second macOS user account, not
    /// here.
    func setupKeyCommands(
        _ requested: [(search: String, name: String, preferredNote: Int)],
        forceRelearn: Bool = false,
        source: String = "logic_setup_key_commands"
    ) throws -> [[String: Any]] {
        // The locale gate comes first — before the window is opened and long
        // before anything is written into the user's key command set. On a
        // Logic drawing in a language nobody has captured, every English row
        // name matches nothing, and the round's honest answer is one refusal
        // naming the language rather than nineteen `not_found`s several
        // seconds apart. See `KeyCommandLocalePlan`.
        let uiLanguage = LogicUILanguage.report(
            LogicUILanguage.evidence(bundleIdentifier: bundleIdentifier, runningBundleURL: nil)
        )
        let localeWarning: String?
        let targets: [(search: String, name: String, preferredNote: Int)]
        switch KeyCommandLocalePlan.plan(
            targets: requested.map {
                KeyCommandLocalePlan.Target(
                    search: $0.search, name: $0.name, preferredNote: $0.preferredNote
                )
            },
            language: uiLanguage.language,
            isEnglish: uiLanguage.isEnglish,
            ownNames: Set(KeyCommandRegistry.Name.all)
        ) {
        case .refuse(let reason):
            throw LogicianError.preconditionUnmet(reason)
        case .proceed(let planned, let warning):
            localeWarning = warning
            targets = planned.map {
                (search: $0.search, name: $0.name, preferredNote: $0.preferredNote)
            }
        }

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

        /// The command list element, found ONCE per call. Logic re-renders the
        /// outline's ROWS when the filter changes; it does not replace the
        /// outline, so the depth-4 walk that finds it has no business inside a
        /// poll that runs tens of times.
        var outlineCache: AXUIElement?
        func outline() -> AXUIElement? {
            if let outlineCache { return outlineCache }
            outlineCache = keyCommandsOutline(in: window)
            return outlineCache
        }
        /// One look at the panel. Re-finds the outline once if the cached
        /// element has gone inert under a re-render (the wipe loop does that),
        /// which is cheap and rare; an honestly empty filter result costs the
        /// same one extra walk and nothing else.
        func look() -> [KeyCommandsRow] {
            guard let list = outline() else { return [] }
            let rows = keyCommandsVisibleRows(in: list)
            if rows.isEmpty {
                outlineCache = nil
                guard let fresh = outline(), !CFEqual(fresh, list) else { return [] }
                return keyCommandsVisibleRows(in: fresh)
            }
            return rows
        }
        /// Exact first, then case-insensitively: Logic's own capitalisation is
        /// what the row publishes, and a caller who typed the name from
        /// memory should not get `not_found` over one letter's case. The row's
        /// OWN text is what gets registered, so the registry always holds the
        /// name Logic uses.
        func match(_ name: String, in rows: [KeyCommandsRow]) -> KeyCommandsRow? {
            rows.first { $0.name == name }
                ?? rows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// Writes a search term and waits for Logic to re-filter, look-first.
        ///
        /// K1. What sat here was a flat `Thread.sleep(1.0)` per command — 22 s
        /// of the measured 223 s round, paid in full whether Logic took 40 ms
        /// or 900. It is a POLL and not a deletion because the re-filter is
        /// Logic's own work over ~1400 rows rather than an AX write settling;
        /// the same second is now the cap. The fingerprint is what makes the
        /// wait positive: until Logic re-filters, the panel still shows the
        /// PREVIOUS term's rows, and looking at those would either match the
        /// wrong row or walk the whole unfiltered list.
        func applyFilter(_ term: String, timeout: TimeInterval = 1.0) {
            let before = outline().map { keyCommandsFilterFingerprint(in: $0) }
            _ = AXUIElementSetAttributeValue(
                search, kAXValueAttribute as CFString, term as CFString
            )
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)
            guard let before else {
                // No outline to fingerprint yet, so the outline APPEARING is
                // the settle. Never return without a wait here: that would
                // hand the look below a panel Logic has not drawn.
                pollKeyCommands(timeout: timeout) { outline() != nil }
                return
            }
            pollKeyCommands(timeout: timeout) {
                guard let list = outline() else { return false }
                return keyCommandsFilterFingerprint(in: list) != before
            }
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

        /// Logic's window layer, cheaply: the window elements themselves plus
        /// how many sheets hang off them. A modal alert cannot appear without
        /// changing one of the two, so this is the gate that keeps the deep
        /// search below off the common path (no collision, which is most
        /// notes).
        func windowLayer() -> (windows: [AXUIElement], sheets: Int) {
            let windows = (try? logicWindows()) ?? []
            let sheets = windows.reduce(0) { total, candidate in
                total + ((attribute(candidate, keyCommandsSheetsAttribute)
                    as? [AXUIElement])?.count ?? 0)
            }
            return (windows, sheets)
        }
        func layerDiffers(
            _ now: (windows: [AXUIElement], sheets: Int),
            from baseline: (windows: [AXUIElement], sheets: Int)
        ) -> Bool {
            KeyCommandPanelLook.windowLayerMoved(
                now: now.windows, nowSheets: now.sheets,
                baseline: baseline.windows, baselineSheets: baseline.sheets,
                sameElement: { CFEqual($0, $1) }
            )
        }

        /// The Cancel button of Logic's "already assigned" alert, if that
        /// alert is standing.
        ///
        /// N2. This used to `collect` to depth 6 over EVERY Logic window with
        /// no early exit and no `.stop`, once per candidate note, to prove a
        /// NEGATIVE — and the negative is the common case, because a collision
        /// is rare. That walk entered the project window's whole subtree and
        /// the Key Commands window's ~1400 rows to find nothing. It now looks
        /// only where an alert can be: a window that was not there before the
        /// note went out (by ELEMENT IDENTITY — the same shape the region-focus
        /// fix uses to tell Logic's windows apart without reading a title), a
        /// window whose subrole says dialog or sheet, a sheet attached to any
        /// window, and the Key Commands window itself. Row trees are skipped
        /// (an alert is never inside the command list, and they are the whole
        /// cost) and the walk stops at the button.
        ///
        /// `newSince` is the window list as it stood before the note went out.
        /// Pass nil to treat every window as new — nothing does today, because
        /// the pre-note list is always available and it keeps the project
        /// window's subtree (the thing N2 was actually about) out of the walk.
        func conflictCancelButton(newSince baseline: [AXUIElement]?) -> AXUIElement? {
            var candidates: [AXUIElement] = []
            for candidate in (try? logicWindows()) ?? [] {
                let subrole = stringAttribute(candidate, kAXSubroleAttribute as String)
                let isNew = baseline.map { known in
                    !known.contains { CFEqual($0, candidate) }
                } ?? true
                if isNew || CFEqual(candidate, window)
                    || ["AXDialog", "AXSystemDialog", "AXSheet"].contains(subrole) {
                    candidates.append(candidate)
                }
                if let sheets = attribute(candidate, keyCommandsSheetsAttribute)
                    as? [AXUIElement] {
                    candidates.append(contentsOf: sheets)
                }
            }
            for candidate in candidates {
                var isConflict = false
                var cancel: AXUIElement?
                walk(from: candidate, maximumDepth: AXDepth.keyCommandsConflictAlert) { element in
                    let role = stringAttribute(element, kAXRoleAttribute as String)
                    if role == "AXOutline" || role == "AXTable" { return .skipChildren }
                    if role == "AXStaticText",
                       stringAttribute(element, kAXValueAttribute as String)
                           .contains(LogicUIStrings.AlertMarker.alreadyAssigned) {
                        isConflict = true
                    }
                    if role == "AXButton",
                       stringAttribute(element, kAXTitleAttribute as String)
                           == LogicUIStrings.Button.cancel {
                        cancel = element
                    }
                    return isConflict && cancel != nil ? .stop : .descend
                }
                if isConflict, let cancel { return cancel }
            }
            return nil
        }
        /// Cancels the alert if it is up, and waits for it to GO — the flat
        /// `sleep(0.5)` that followed the press is that poll's cap now.
        func dismissConflictAlert(newSince baseline: [AXUIElement]?) -> Bool {
            guard let cancel = conflictCancelButton(newSince: baseline) else { return false }
            _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            pollKeyCommands(timeout: 0.5, interval: 0.03) {
                conflictCancelButton(newSince: baseline) == nil
            }
            return true
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
            applyFilter(target.search)
            // THE one full look at the panel for this target (N6). Everything
            // below reads the row it returns rather than walking for it again.
            // The second look exists only for the near-miss list on a miss
            // whose filter showed nothing — see `KeyCommandPanelLook.resolve`.
            let firstWord = target.name.split(separator: " ")
                .first.map { String($0).lowercased() }
            let widen: (() -> [KeyCommandsRow])? = firstWord
                .flatMap { word in
                    word == target.search.lowercased() ? nil : { applyFilter(word); return look() }
                }
            let resolved = KeyCommandPanelLook.resolve(
                look: look, match: { match(target.name, in: $0) }, widen: widen
            )
            guard var current = resolved.match else {
                var entry: [String: Any] = [
                    "name": target.name, "status": "not_found",
                    "searched": target.search,
                    "note": "no Key Commands row matches; localized Logic UI or renamed command? Command names drift between Logic versions - pick one of `candidates` (the rows the panel is showing) and call again with that exact name."
                ]
                // The near misses turn COVERAGE's open question 7 ("a wrong
                // search string is a silent not_found") into a list the caller
                // can pick from.
                let candidates = resolved.candidates.map(\.name)
                if !candidates.isEmpty { entry["candidates"] = Array(candidates.prefix(25)) }
                results.append(entry)
                continue
            }
            let resolvedName = current.name
            let existing = KeyCommandRegistry.rowAssignment(
                current.assignment, preferredNote: target.preferredNote
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
                    "existing_assignment": current.assignment,
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
            _ = AXUIElementSetAttributeValue(
                current.element, kAXSelectedAttribute as CFString, kCFBooleanTrue
            )
            // Pattern #9 + #2: the AX write is synchronous and the selection
            // reads back, so the flat 0.5 s that sat here was charged to every
            // learn. Same 0.5 s, now the CAP on a positive check instead.
            pollKeyCommandsValue(
                current.element, kAXSelectedAttribute as String, equals: "1", timeout: 0.5
            )
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
                    guard let list = outline() else { return nil }
                    return CFEqual(list, table) ? nil : table
                }
                let commandList = outline()
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
                    let before = assignmentRows()
                    guard let staleRow = before.first else { break }
                    _ = AXUIElementSetAttributeValue(
                        staleRow, kAXSelectedAttribute as CFString, kCFBooleanTrue
                    )
                    // Was `sleep(0.2)` + `sleep(0.4)` per deleted row — 0.6 s
                    // charged to every wipe iteration of every command on the
                    // relearn path. Both are now caps on what they were
                    // waiting for: the selection reading back, and the row
                    // COUNT dropping. The count is the honest witness that the
                    // press landed; the old code just assumed it after 0.4 s.
                    pollKeyCommandsValue(
                        staleRow, kAXSelectedAttribute as String, equals: "1", timeout: 0.2
                    )
                    guard let deleteButton = findIn(window, {
                        stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                            && stringAttribute($0, kAXTitleAttribute as String)
                            == LogicUIStrings.Button.deleteAssignment
                    }) else { break }
                    _ = AXUIElementPerformAction(deleteButton, kAXPressAction as CFString)
                    let wanted = before.count - 1
                    pollKeyCommands(timeout: 0.4, interval: 0.03) {
                        assignmentRows().count <= wanted
                    }
                }
                deletedStale = max(0, initialCount - assignmentRows().count)
                if deletedStale > 0 {
                    // The deletions re-render the whole panel and DROP the
                    // command row's selection — re-select it or the learn
                    // assigns to nothing and silently fails. This is the one
                    // place a second look at the panel is genuinely earned,
                    // and the row it returns replaces the stale reference
                    // everything below would otherwise keep reading.
                    outlineCache = nil
                    if let freshRow = match(resolvedName, in: look()) {
                        current = freshRow
                        _ = AXUIElementSetAttributeValue(
                            freshRow.element, kAXSelectedAttribute as CFString, kCFBooleanTrue
                        )
                        // Was a flat `sleep(0.5)`; the selection reads back.
                        pollKeyCommandsValue(
                            freshRow.element, kAXSelectedAttribute as String,
                            equals: "1", timeout: 0.5
                        )
                    }
                }
            }
            var learned: Int?
            var bridgeFailure: LogicianError?
            // Only the wipe and a dismissed conflict alert re-render the
            // panel; on the ordinary path nothing does, so the Learn checkbox
            // is found ONCE (pattern #10) instead of on every attempt.
            var panelReRendered = deletedStale > 0
            // The row's text BEFORE the note. Read from the row this target
            // already holds — the second `rowMatching` walk that used to
            // produce it (N6) was reading the same row a third time.
            var preLearnText = current.joined
            /// The row as it reads NOW. Uses the live element; a panel that
            /// re-rendered under it publishes no texts, which is itself the
            /// signal to look once more.
            func currentRowText() -> String? {
                KeyCommandPanelLook.rowText(
                    live: { keyCommandsRowTexts(current.element) },
                    refind: {
                        outlineCache = nil
                        guard let fresh = match(resolvedName, in: look()) else { return nil }
                        current = fresh
                        return fresh.texts
                    }
                )
            }
            for candidate in KeyCommandRegistry.candidateNotes(
                preferred: target.preferredNote, taken: KeyCommandRegistry.takenNotes()
            ) {
                if panelReRendered {
                    // the wipe re-renders the panel and makes earlier element
                    // references silently inert
                    learn = findIn(window, isLearnCheckBox) ?? learn
                    preLearnText = currentRowText() ?? preLearnText
                    panelReRendered = false
                }
                if stringAttribute(learn, kAXValueAttribute as String) != "1" {
                    _ = AXUIElementPerformAction(learn, kAXPressAction as CFString)
                    // The checkbox's own AXValue is the positive witness, and
                    // the line below already tests it — so the flat 0.4 s here
                    // was a wait for something the code reads. 0.4 s is now
                    // the cap on the poll, not the price of the press.
                    pollKeyCommandsValue(
                        learn, kAXValueAttribute as String, equals: "1", timeout: 0.4
                    )
                }
                // Both witnesses of what the note did are read from here on:
                // the row's assignment text (it landed) and Logic's "already
                // assigned" alert (it collided). The window layer is sampled
                // BEFORE the send so the alert can be recognised by identity.
                var layer = windowLayer()
                let baselineWindows = layer.windows
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
                // K2 + pattern #11. What sat here was `sleep(1.0)` — the
                // note's travel time down the MIDI plane — then a one-shot
                // conflict walk, then a look-then-sleep verify loop with up to
                // 4 × 0.5 s in it: 1.2-3.0 s per candidate note, all of it
                // blind. The MIDI-plane wait is not deleted (the note really
                // does travel daemon → CoreMIDI → Logic's learn capture, and
                // no AX write settles that) — it is FOLDED into the poll that
                // was always going to look, and the collision is looked for in
                // the same pass. A learn Logic captures in 80 ms now costs
                // 80 ms; the same 3.0 s remains the cap on one that does not.
                var collided = false
                let landed = pollKeyCommands(timeout: 3.0, interval: 0.05) {
                    if let text = currentRowText() {
                        // Logic displays some notes symbolically (e.g. note 109
                        // on the MCU device shows as "F2 (Modifiers ...)"), so
                        // "Note N" is not always present — any change in the
                        // row's assignment display counts as the learn landing.
                        if text.contains(
                            LogicUIStrings.Format.keyCommandNotePrefix + "\(candidate)"
                        ) || text != preLearnText { return true }
                    }
                    // The cheap gate: no window and no sheet has appeared or
                    // gone, so no alert can be standing, so the deep search
                    // does not run. When the layer HAS moved it is searched
                    // once and the new layer becomes the baseline, so an
                    // unrelated window cannot make this walk on every tick.
                    let now = windowLayer()
                    guard layerDiffers(now, from: layer) else { return false }
                    layer = now
                    if dismissConflictAlert(newSince: baselineWindows) {
                        collided = true
                        return true
                    }
                    return false
                }
                // One last look with the layer gate OFF, so a sampling miss —
                // an alert that came up and settled between two polls — can
                // never walk away leaving a modal standing in the user's
                // Logic. Same bounded search, just not conditional this time.
                if !landed, dismissConflictAlert(newSince: baselineWindows) { collided = true }
                if collided {
                    panelReRendered = true
                    continue // collision: next candidate
                }
                if landed { learned = candidate; break }
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
        var mirrored = results.map { entry -> [String: Any] in
            guard entry["state"] == nil, let status = entry["status"] else { return entry }
            var copy = entry
            copy["state"] = status
            return copy
        }
        // Said once, on the first entry, rather than on all nineteen: how the
        // row names were chosen when that was not simply "English".
        if let localeWarning, !mirrored.isEmpty {
            let existing = mirrored[0]["warning"] as? String
            mirrored[0]["warning"] = [existing, localeWarning]
                .compactMap { $0 }.joined(separator: " ")
        }
        return mirrored
    }

}
