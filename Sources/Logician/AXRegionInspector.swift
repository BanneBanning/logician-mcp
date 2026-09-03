import AppKit
import ApplicationServices
import Foundation

// The Accessibility half of the Region inspector: finding the panel, opening
// it, reading its rows and writing them. What the rows MEAN is
// `RegionInspector.swift`.
//
// The shape, measured live against Logic Pro 12.3.1 on 2026-08-28:
//
//     AXGroup desc='Inspector'
//       AXList
//         AXGroup                      <- the Region panel
//           AXDisclosureTriangle       <- collapsed by default
//           AXTextField  'Crash'       <- the region NAME, and it is writable
//           AXStaticText 'Region:'
//           AXScrollArea               <- only while the triangle is open
//             AXOutline
//               AXRow [label cell, value cell]   x 12, or 22 with "More" open
//         AXGroup                      <- the Track panel
//         AXGroup                      <- the channel strips
//
// Every row is a label cell and a value cell. The value cell is an AXCheckBox
// (AXPress toggles), an AXSlider (AXValue takes an ABSOLUTE write) or an
// AXPopUpButton (AXPress opens a menu whose item is pressed).
extension LogicAccessibility {

    // MARK: - The panel

    struct RegionInspectorPanel {
        let group: AXUIElement
        let disclosure: AXUIElement
        /// The region NAME field — writable, and Logic's own rename route.
        /// Nil when no region is selected: the panel then shows the track's
        /// region defaults and publishes the title as static text, because
        /// there is nothing to rename.
        let nameField: AXUIElement?
        var subject: RegionInspector.PanelSubject
        var panelName: String
    }

    /// One published row of the parameter outline.
    struct RegionInspectorRow {
        let index: Int
        let rawLabel: String
        let label: String
        let value: AXUIElement?
        let control: RegionInspector.Control
        let raw: String
        let display: String?
        let enabled: Bool
        let settable: Bool
        let minimum: Int?
        let maximum: Int?
        let isMoreRow: Bool

        var dictionary: [String: Any] {
            var entry: [String: Any] = [
                "index": index,
                "label": label,
                "control": control.rawValue,
                "enabled": enabled,
                "settable": settable
            ]
            if control == .slider, let number = Int(raw) {
                entry["value"] = number
            } else if control == .checkbox {
                entry["value"] = RegionInspector.checkboxState(raw) as Any? ?? NSNull()
                if RegionInspector.checkboxState(raw) == nil { entry["mixed"] = true }
            } else if !raw.isEmpty {
                entry["value"] = raw
                if raw == RegionInspector.mixedPopupValue { entry["mixed"] = true }
            }
            if let display { entry["display"] = display }
            if let minimum, let maximum { entry["range"] = [minimum, maximum] }
            return entry
        }
    }

    func regionInspectorPanel() throws -> RegionInspectorPanel {
        let window = try projectWindow()
        guard let inspector = firstDescendant(of: window, maximumDepth: AXDepth.inspectorPanel, where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.inspector
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the left inspector is not showing — open it in Logic (View > Show Inspector, or the I key)"
            )
        }
        guard let list = children(of: inspector).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXList"
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the Inspector group published no panel list"
            )
        }
        // The Region panel is the one carrying the static text "Region:";
        // its sibling carries "Track:".
        guard let group = children(of: list).first(where: { panel in
            children(of: panel).contains {
                stringAttribute($0, kAXRoleAttribute as String) == "AXStaticText"
                    && stringAttribute($0, kAXValueAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.regionPanelPrefix)
            }
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "no panel in the left inspector is labelled 'Region:'"
            )
        }
        guard let disclosure = children(of: group).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
        }) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector",
                exposed: "the Region panel published no disclosure triangle"
            )
        }
        // With a region selected the title is an editable AXTextField (that
        // field IS Logic's rename route). With NOTHING selected the panel
        // shows the track's region defaults and the title is static text —
        // measured 2026-08-28, and the reason this is not a hard requirement.
        let nameField = children(of: group).first {
            stringAttribute($0, kAXRoleAttribute as String) == "AXTextField"
        }
        let name = nameField.map { stringAttribute($0, kAXValueAttribute as String) }
            ?? children(of: group).first {
                stringAttribute($0, kAXRoleAttribute as String) == "AXStaticText"
                    && !stringAttribute($0, kAXValueAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.regionPanelPrefix)
            }.map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
        return RegionInspectorPanel(
            group: group, disclosure: disclosure, nameField: nameField,
            subject: RegionInspector.panelSubject(nameField: name), panelName: name
        )
    }

    // MARK: - Waiting for the panel to catch up with a selection

    /// How a Region-inspector call that has just written an exclusive
    /// selection waits for the panel to say so. Pure, so the schedule can be
    /// asserted without an Accessibility tree.
    ///
    /// MEASURED 2026-09-02 (Logic Pro 12.3.1, "Testlåt Copy"): with three
    /// regions selected on another row, the panel read taken ~15 ms after an
    /// exclusive `selectRegion` came back "MIDI Defaults" — Logic had
    /// processed the DESELECTION of the three and not yet the selection of the
    /// target. `renameRegion` refused a perfectly addressed rename on 2 of 4
    /// calls that way once the 72 ms `selectedRegionCount()` walk that had been
    /// hiding the race by accident was removed.
    ///
    /// The budget is 0.3 s and it is a BUDGET: the look comes first, so a
    /// panel that has already caught up costs one 7 ms read and nothing else.
    enum PanelSettlePoll {
        static let budget: TimeInterval = 0.3
        static let interval: TimeInterval = 0.01
    }

    /// The settle poll's stop condition. Pure, so what the poll is waiting for
    /// can be asserted without an Accessibility tree.
    ///
    /// A caller that knows the arrangement map's name for the region it just
    /// selected waits for THAT NAME, not merely for "some region": measured
    /// 2026-09-02, the stale panel a read inherited was not the defaults but
    /// the PREVIOUS region — a perfectly well-formed `.region` subject, and
    /// the wrong one. Waiting on `isRegion` alone would have let it straight
    /// through. Comparing the name also stops the poll instantly for a region
    /// NAMED like one of Logic's own strings, whose subject will never satisfy
    /// `isRegion` and is settled by `SelectionEvidence` instead.
    static func panelHasCaughtUp(
        subject: RegionInspector.PanelSubject, panelName: String, wanted: String?
    ) -> Bool {
        guard let wanted else { return subject.isRegion }
        return RegionInspector.canonicalPanelName(panelName) == wanted
    }

    /// The Region inspector panel, waited for and then cross-examined — the
    /// one route every tool that addresses ONE region takes to the question
    /// "whose parameters are on screen?".
    ///
    /// Two things happen here, and they used to happen only inside
    /// `renameRegion` while `logic_get_region_params` and
    /// `logic_set_region_params` did neither:
    ///
    /// 1. **The settle poll.** The panel can still be showing the selection
    ///    this call REPLACED (see `PanelSettlePoll` for the measurement), so
    ///    the cheap 7 ms read is looked at first and then repeated only while
    ///    it disagrees. A selection that genuinely did not take spends the
    ///    budget and is refused; the honest call pays one read.
    /// 2. **The evidence.** The name field is USER-WRITABLE, so classifying
    ///    the panel by sniffing it alone reads Logic's grammar out of a string
    ///    a user chose: a region called "2 selected" or "MIDI Defaults" would
    ///    report itself as a selection state to every Region-inspector tool
    ///    for ever. Only when the string looks reserved is the 72 ms
    ///    `selectedRegionCount()` walk worth taking, and only it plus the
    ///    arrangement map's name for the region just selected can overrule the
    ///    panel — see `RegionInspector.SelectionEvidence`.
    ///
    /// - Parameter addressedRegionName: the arrangement map's own name for the
    ///   region the caller selected, from `selectRegion`'s result. Without it
    ///   the panel string stands on its own, which is right for a call that
    ///   addressed no region.
    func settledRegionInspectorPanel(addressedRegionName: String?) throws -> RegionInspectorPanel {
        let wanted = addressedRegionName.map(RegionInspector.canonicalPanelName)
        var panel = try regionInspectorPanel()
        let deadline = Date().addingTimeInterval(PanelSettlePoll.budget)
        while !Self.panelHasCaughtUp(
            subject: panel.subject, panelName: panel.panelName, wanted: wanted
        ), Date() < deadline {
            Thread.sleep(forTimeInterval: PanelSettlePoll.interval)
            panel = try regionInspectorPanel()
        }
        guard !panel.subject.isRegion else { return panel }
        panel.subject = RegionInspector.panelSubject(
            nameField: panel.panelName,
            evidence: .init(
                selectedCount: try? selectedRegionCount(),
                addressedRegionName: addressedRegionName
            )
        )
        return panel
    }

    // MARK: - Disclosure triangles

    /// How a disclosure poll is spent. Pure, so the schedule can be asserted
    /// without an Accessibility tree.
    ///
    /// MEASURED 2026-09-02 (Logic Pro 12.3.1, "Testlåt Copy"): every one
    /// of the 8 disclosure toggles in a profiling matrix had already settled
    /// by the loop's FIRST look — and the loop slept 0.1 s *before* looking,
    /// so 100 ms of every toggle was this floor rather than Logic's repaint.
    /// Four toggles per `logic_get_region_params` call made that 400 ms of the
    /// 630 ms a collapsed Region panel cost the tool.
    ///
    /// The PATIENCE is unchanged: 1.2 s, exactly what the old 12 × 0.1 s loop
    /// gave a triangle before calling it stuck. Only the granularity moved.
    enum DisclosurePoll {
        static let interval: TimeInterval = 0.015
        /// Includes the free look that happens before the first sleep, so the
        /// waiting is `(attempts - 1) × interval`.
        static let attempts = 81
        static var budget: TimeInterval { Double(attempts - 1) * interval }
    }

    /// Presses a disclosure triangle until it reads `open`, and says whether
    /// it had to. Returns nil when the triangle would not move.
    ///
    /// LOOK BEFORE SLEEPING, twice over: once before the press (a triangle
    /// already in the wanted state is a verified no-op and costs one read),
    /// and once immediately after it, with no sleep at all. See
    /// `DisclosurePoll` for why the old loop's first look was 100 ms late.
    private func setDisclosure(_ triangle: AXUIElement, open: Bool) -> Bool? {
        let want = open ? "1" : "0"
        if stringAttribute(triangle, kAXValueAttribute as String) == want { return false }
        _ = AXUIElementPerformAction(triangle, kAXPressAction as CFString)
        for attempt in 0..<DisclosurePoll.attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: DisclosurePoll.interval) }
            if stringAttribute(triangle, kAXValueAttribute as String) == want { return true }
        }
        return nil
    }

    private func regionInspectorOutline(_ panel: RegionInspectorPanel) -> AXUIElement? {
        firstDescendant(of: panel.group, maximumDepth: AXDepth.regionInspectorOutline) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXOutline"
        }
    }

    /// The outline's one "More" triangle — the row that carries a disclosure.
    private func moreDisclosure(in outline: AXUIElement) -> AXUIElement? {
        guard let row = regionInspectorRawRows(outline).first(where: { hasDisclosure($0) })
        else { return nil }
        return firstDescendant(of: row, maximumDepth: 2) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
        }
    }

    // MARK: - The disclosure debt

    /// A Region-inspector disclosure this server OPENED and has not closed
    /// again.
    ///
    /// WHY THE CLOSE IS DEFERRED. Measured 2026-09-02: with the Region panel
    /// and its "More" section collapsed — Logic's default, and how the sandbox
    /// sat at rest — `withRegionInspector` cost **681–712 ms** against
    /// **51–63 ms** with both already open, for a byte-identical answer. Half
    /// of that gap was the poll floor `DisclosurePoll` now removes; the other
    /// ~310 ms was the closing pair, paid by a READ-ONLY tool purely as UI
    /// courtesy — and immediately undone by the next region call, which opened
    /// both again. An agent chaining `logic_get_region_params` →
    /// `logic_set_region_params` → `logic_get_region_params` paid it three
    /// times to end where it started.
    ///
    /// WHY IT IS SAFE HERE, which is the part that had to be argued rather
    /// than assumed — the surface debt this borrows from guards a real hazard
    /// (a leaked plugin view makes Logic auto-open windows), and a UI panel
    /// deserves the same interrogation:
    ///
    /// 1. **Nothing in this server needs the panel shut.** Every path through
    ///    `withRegionInspector` already handles "already open" — that is the
    ///    state the profile measured as both correct and 13× cheaper. Open is
    ///    not a hazard state, it is the fast one. There is therefore no tool
    ///    whose correctness a standing debt can damage, and no "settle before
    ///    X" rule anyone has to remember.
    /// 2. **The settle cannot fight the user.** It goes through
    ///    `setDisclosure`, which looks before it presses: a triangle the user
    ///    has already closed reads "0" and is left alone.
    /// 3. **The debt is scoped to the document it was incurred in**, the same
    ///    discipline `ScopedCache` applies to a file. A debt whose project is
    ///    no longer the open one names a panel that is gone, so it is dropped
    ///    rather than paid back into a stranger's window.
    /// 4. **The residue is the least surprising one available.** What is left
    ///    on screen is the Region inspector showing the parameters the agent
    ///    was just asked about, in a panel Logic itself remembers between
    ///    sessions because users toggle it constantly.
    ///
    /// What it costs, stated plainly: a session killed outright (SIGKILL, a
    /// crash) never reaches `MCPServer.shutdown()` and leaves the panel open;
    /// and a user who closes the panel and then deliberately reopens it during
    /// a session will have it closed once at shutdown. Both are cosmetic, and
    /// the second is indistinguishable from the first without asking Logic a
    /// question it does not answer.
    struct InspectorDebt: Equatable {
        /// The Region panel's own triangle was opened by us.
        let regionPanel: Bool
        /// The outline's "More" triangle was opened by us.
        let more: Bool
        /// The project document the panel belonged to.
        let projectDocument: String

        var isEmpty: Bool { !regionPanel && !more }
    }

    // Single-threaded server loop, like `MCUController.surfaceDebt`.
    nonisolated(unsafe) static var inspectorDebt: InspectorDebt?

    /// What a call that opened `openedRegionPanel` / `openedMore` should do on
    /// the way out. Pure: the decision is tested without a panel.
    struct InspectorRestorePlan: Equatable {
        let closeMoreNow: Bool
        let closeRegionPanelNow: Bool
        /// The debt left standing afterwards; nil means nothing is owed.
        let debt: InspectorDebt?
    }

    static func planInspectorRestore(
        standing: InspectorDebt?,
        openedRegionPanel: Bool,
        openedMore: Bool,
        projectDocument: String?
    ) -> InspectorRestorePlan {
        // No readable document, no deferral. A restore that cannot be scoped
        // to the project it belongs to could be paid back into a DIFFERENT
        // song later, so it is paid now instead — the same rule an unscopable
        // `ScopedCache` follows: absent beats guessed. Any standing debt keeps
        // standing; it carries its own document and is checked again at settle
        // time.
        guard let projectDocument else {
            return InspectorRestorePlan(
                closeMoreNow: openedMore,
                closeRegionPanelNow: openedRegionPanel,
                debt: standing
            )
        }
        // A debt for another document names a panel that is no longer on
        // screen. It can never be verified again, so it is retired rather than
        // carried.
        let carried = standing?.projectDocument == projectDocument ? standing : nil
        let debt = InspectorDebt(
            regionPanel: (carried?.regionPanel ?? false) || openedRegionPanel,
            more: (carried?.more ?? false) || openedMore,
            projectDocument: projectDocument
        )
        return InspectorRestorePlan(
            closeMoreNow: false, closeRegionPanelNow: false, debt: debt.isEmpty ? nil : debt
        )
    }

    /// Closes whatever this server left open, and says whether it had
    /// anything to do. Called from `MCPServer.shutdown()` when stdin closes;
    /// safe to call with no debt, with the project changed, or with the panel
    /// already back the way the debt wants it.
    @discardableResult
    func settleInspectorDebt() -> Bool {
        guard let debt = Self.inspectorDebt else { return false }
        Self.inspectorDebt = nil
        guard let document = try? projectDocumentPath(), document == debt.projectDocument else {
            return false
        }
        guard let panel = try? regionInspectorPanel() else { return false }
        // "More" first: it lives inside the outline, which is only published
        // while the panel is open.
        if debt.more, let outline = regionInspectorOutline(panel),
           let triangle = moreDisclosure(in: outline) {
            _ = setDisclosure(triangle, open: false)
        }
        if debt.regionPanel { _ = setDisclosure(panel.disclosure, open: false) }
        return true
    }

    /// Opens the panel (and, when asked, the "More" section), runs `body`, and
    /// then either closes what it opened or records it as a debt — see
    /// `InspectorDebt` for the measurement and the argument. Either way the
    /// panel's state is REPORTED rather than assumed: `panelState` says what
    /// was found, what was opened and whether the close was deferred.
    ///
    /// `startingFrom` hands in a panel the caller has ALREADY walked — the one
    /// `settledRegionInspectorPanel` waited for and cross-examined. It saves
    /// the second walk of the same tree (4–27 ms, measured 2026-09-02) and,
    /// more importantly, it carries that verdict into the body: a subject
    /// recomputed here would be back to sniffing the name field with no
    /// evidence, which is the defect this parameter exists to close.
    func withRegionInspector<Result>(
        needMore: Bool,
        startingFrom settled: RegionInspectorPanel? = nil,
        _ body: (RegionInspectorPanel, [RegionInspectorRow]) throws -> Result
    ) throws -> (result: Result, panelState: [String: Any]) {
        var panel = try settled ?? regionInspectorPanel()
        let settledSubject = settled?.subject
        var state: [String: Any] = [:]

        // These two drive the exit and are re-pointed at the plan once it is
        // known. Until then they carry the OLD behaviour, so a throw between
        // here and the plan still leaves the panel as it was found.
        var closePanelOnExit = false
        var closeMoreOnExit = false
        var moreTriangle: AXUIElement?
        defer { if closePanelOnExit { _ = setDisclosure(panel.disclosure, open: false) } }
        defer {
            if closeMoreOnExit, let triangle = moreTriangle {
                _ = setDisclosure(triangle, open: false)
            }
        }

        let panelWasClosed = stringAttribute(panel.disclosure, kAXValueAttribute as String) != "1"
        if panelWasClosed {
            guard setDisclosure(panel.disclosure, open: true) != nil else {
                throw LogicianError.trackNotExposed(
                    requested: "the Region inspector's parameters",
                    exposed: "the panel's disclosure triangle did not open"
                )
            }
            closePanelOnExit = true
            // Re-read: the name field is the same element, but the panel's own
            // children change when it OPENS — the scroll area and its outline
            // appear with it. Found already open, the first walk is already
            // the right one, and re-walking it was 7–12 ms of nothing
            // (measured 2026-09-02).
            panel = try regionInspectorPanel()
            // That re-read classifies the name field again, with no evidence
            // and no settle behind it. A caller that already did that work
            // keeps its verdict.
            if let settledSubject { panel.subject = settledSubject }
        }
        guard let outline = regionInspectorOutline(panel) else {
            throw LogicianError.trackNotExposed(
                requested: "the Region inspector's parameter rows",
                exposed: "the open panel published no outline"
            )
        }

        var openedMore = false
        var moreWasClosed = false
        if let triangle = moreDisclosure(in: outline) {
            moreTriangle = triangle
            moreWasClosed = stringAttribute(triangle, kAXValueAttribute as String) != "1"
            if needMore, moreWasClosed {
                guard setDisclosure(triangle, open: true) != nil else {
                    throw LogicianError.trackNotExposed(
                        requested: "the Region inspector's 'More' rows",
                        exposed: "the More disclosure did not open"
                    )
                }
                openedMore = true
                closeMoreOnExit = true
            }
        }

        let plan = Self.planInspectorRestore(
            standing: Self.inspectorDebt,
            openedRegionPanel: panelWasClosed,
            openedMore: openedMore,
            projectDocument: try? projectDocumentPath()
        )
        Self.inspectorDebt = plan.debt
        closePanelOnExit = plan.closeRegionPanelNow
        closeMoreOnExit = plan.closeMoreNow

        state["region_panel"] = panelWasClosed
            ? (plan.closeRegionPanelNow ? "opened and restored" : "opened and left open")
            : "already open"
        if openedMore {
            state["more"] = plan.closeMoreNow ? "opened and restored" : "opened and left open"
        } else if moreTriangle != nil {
            state["more"] = moreWasClosed ? "closed" : "already open"
        }
        if plan.debt != nil {
            state["restore"] = "deferred"
            state["restore_note"] = "The disclosures this server opened are left OPEN so the next "
                + "region-inspector call does not spend ~0.6 s re-opening them; this server closes "
                + "them again when the session ends. Closing them yourself in Logic is safe — the "
                + "deferred close reads the triangle before it presses it."
        }

        let rows = regionInspectorRows(outline)
        return (try body(panel, rows), state)
    }

    private func hasDisclosure(_ row: AXUIElement) -> Bool {
        firstDescendant(of: row, maximumDepth: 2) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXDisclosureTriangle"
        } != nil
    }

    private func regionInspectorRawRows(_ outline: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(outline, "AXRows") as? [AXUIElement] else { return [] }
        return value
    }

    func regionInspectorRows(_ outline: AXUIElement) -> [RegionInspectorRow] {
        regionInspectorRawRows(outline).enumerated().map { index, row in
            let cells = children(of: row)
            let more = hasDisclosure(row)
            let rawLabel = cells.first.map { cell -> String in
                if stringAttribute(cell, kAXRoleAttribute as String) == "AXGroup" {
                    return children(of: cell)
                        .first { stringAttribute($0, kAXRoleAttribute as String) == "AXTextField" }
                        .map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
                }
                return stringAttribute(cell, kAXValueAttribute as String)
            } ?? ""
            let valueCell = cells.count > 1 ? cells[1] : nil
            let role = valueCell.map { stringAttribute($0, kAXRoleAttribute as String) } ?? ""
            var control: RegionInspector.Control
            switch role {
            case "AXCheckBox": control = .checkbox
            case "AXSlider": control = .slider
            case "AXPopUpButton": control = .popup
            default: control = .other
            }
            // Logic parks the rows a region type does not use at "-", disabled
            // in both cells. Reported as placeholders, never written.
            if RegionInspector.normalizedLabel(rawLabel) == "-" { control = .placeholder }
            // The audio "File Tempo" row is three segment sliders rather than
            // one control; it is read as `other` and not written.
            if cells.count > 2, !more { control = .other }
            let raw = valueCell.map { stringAttribute($0, kAXValueAttribute as String) } ?? ""
            let published = valueCell
                .map { stringAttribute($0, kAXValueDescriptionAttribute as String) } ?? ""
            return RegionInspectorRow(
                index: index,
                rawLabel: rawLabel,
                label: RegionInspector.normalizedLabel(rawLabel),
                value: valueCell,
                control: control,
                raw: raw,
                display: RegionInspector.displayText(published),
                enabled: valueCell.map { stringAttribute($0, kAXEnabledAttribute as String) == "1" } ?? false,
                settable: valueCell.map { isSettable($0, kAXValueAttribute as String) } ?? false,
                minimum: valueCell.flatMap { Int(stringAttribute($0, kAXMinValueAttribute as String)) },
                maximum: valueCell.flatMap { Int(stringAttribute($0, kAXMaxValueAttribute as String)) },
                isMoreRow: more
            )
        }
    }

    func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success else {
            return false
        }
        return flag.boolValue
    }

    /// The region type the panel itself is showing, read off the rows Logic
    /// published rather than off the arrangement map — an independent second
    /// source, and the only one available when several regions are selected.
    func inferredRegionType(_ rows: [RegionInspectorRow]) -> String? {
        let labels = Set(rows.map(\.label))
        if labels.contains("Velocity Offset") || labels.contains("Dynamics") { return RegionInspector.midi }
        if labels.contains("Gain") || labels.contains("Fine Tune") { return RegionInspector.audio }
        return nil
    }

    // MARK: - Pop-up menus

    /// How the pop-up menu polls are spent. Same shape and the same total
    /// patience as the blind sleeps they replaced (1.2 s per press attempt,
    /// 3.0 s on the last, 0.3 s for the dismissal), looking first and looking
    /// often instead of sleeping first.
    ///
    /// The interval is 0.03 rather than the disclosure's 0.015 because each
    /// look here is a walk of Logic's whole menu tree, not one attribute read:
    /// polling faster would spend the saving on the probe.
    enum MenuPoll {
        static let interval: TimeInterval = 0.03
        static let attempts = 41
        static let patientAttempts = 101
        static let dismissAttempts = 11
        static var budget: TimeInterval { Double(attempts - 1) * interval }
        static var patientBudget: TimeInterval { Double(patientAttempts - 1) * interval }
        static var dismissBudget: TimeInterval { Double(dismissAttempts - 1) * interval }
    }

    /// The Region inspector's pop-up menus are parented deeper than
    /// `popupMenus()` looks, so this walk has its own cap. See
    /// `AXDepth.regionInspectorMenu`.
    private func inspectorMenus() -> [AXUIElement] {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menus: [AXUIElement] = []
        walk(from: appElement, maximumDepth: AXDepth.regionInspectorMenu) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXMenuBar" { return .skipChildren }
            if role == "AXMenu" { menus.append(element); return .skipChildren }
            return .descend
        }
        return menus
    }

    private func dismissInspectorMenus() {
        for menu in inspectorMenus() {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    /// Opens one pop-up's menu, hands it to `body`, and ALWAYS dismisses it —
    /// a menu left standing swallows Logic's keyboard and with it every key
    /// command the next tool fires.
    ///
    /// `AXPress` reports AXError -25205 here even when the menu opens, exactly
    /// as it does in the insert slot's plugin chooser and the plugin setting
    /// menu, so the press is verified by finding the menu and never by the
    /// status code.
    private func withInspectorMenu<Result>(
        _ popup: AXUIElement,
        _ body: (AXUIElement) throws -> Result
    ) throws -> Result {
        try ensureLogicFrontmost(for: "the Region inspector's pop-up")
        dismissInspectorMenus()
        var opened: AXUIElement?
        pressing: for attempt in 0..<3 {
            _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
            let attempts = attempt == 2 ? MenuPoll.patientAttempts : MenuPoll.attempts
            for poll in 0..<attempts {
                if poll > 0 { Thread.sleep(forTimeInterval: MenuPoll.interval) }
                if let menu = inspectorMenus().first { opened = menu; break pressing }
            }
            dismissInspectorMenus()
        }
        guard let menu = opened else {
            dismissInspectorMenus()
            throw LogicianError.openVerificationFailed(
                "the Region inspector pop-up's menu did not open"
            )
        }
        defer {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            dismissInspectorMenus()
            // What the 0.3 s that used to sit here was standing in for: the
            // menu actually being GONE. A menu left standing swallows Logic's
            // keyboard, so the wait stays — it is now a positive check for the
            // thing itself rather than a guess at how long it takes, and it
            // gives up after the same 0.3 s.
            for attempt in 0..<MenuPoll.dismissAttempts {
                if attempt > 0 { Thread.sleep(forTimeInterval: MenuPoll.interval) }
                if inspectorMenus().isEmpty { break }
            }
        }
        return try body(menu)
    }

    private func menuTitles(_ menu: AXUIElement) -> [String] {
        children(of: menu)
            .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
            .map { stringAttribute($0, kAXTitleAttribute as String) }
            .filter { !$0.isEmpty }
    }

    /// Reads a pop-up's whole menu without changing anything.
    func regionInspectorMenuOptions(_ popup: AXUIElement) throws -> [String] {
        try withInspectorMenu(popup) { menu in menuTitles(menu) }
    }

    // MARK: - The quantize vocabulary, learned once

    /// Logic's quantize menu, from the cache when this install has already
    /// published it and from the pop-up otherwise. The second element says
    /// which, because "where did this list come from" is exactly the question
    /// a cached answer has to answer for itself.
    ///
    /// WHY IT IS CACHEABLE AT ALL. The menu is 36 items and byte-identical for
    /// every region in every project: it is a function of Logic's version and
    /// the language its UI is drawn in, not of the session (measured
    /// 2026-09-02 across MIDI and audio regions in "Testlåt Copy" — the
    /// same 36 strings, and 715 ms to re-derive them every single time).
    /// `logic_set_region_params` sends callers here to learn the vocabulary it
    /// accepts, so it is a list agents read repeatedly and Logic changes only
    /// when it is updated or relaunched in another language.
    func quantizeMenuOptions(_ popup: AXUIElement) throws -> (values: [String], source: String) {
        if let cached = cachedQuantizeValues() { return (cached, "cache") }
        let values = try regionInspectorMenuOptions(popup)
        rememberQuantizeValues(values)
        return (values, "logic_menu")
    }

    static var quantizeValuesCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("region-quantize-values.json")
    }

    /// Identity the quantize list is valid for. Pure, so the scoping rule is
    /// tested without Logic running.
    ///
    /// The list is the INSTALL's, not the project's — opening another song
    /// does not rename `1/16 Swing F` — so the project path that scopes the
    /// tempo and bank maps would be exactly the wrong key here. What DOES
    /// change it is a Logic update and the language Logic draws its menus in,
    /// and both are in the token. A `nil` language (Logic not installed, the
    /// bundle unreadable) is spelled out rather than dropped, so an install
    /// whose language cannot be inferred never shares a scope with one whose
    /// language is known.
    static func quantizeValuesScope(
        logicVersion: String, logicBuild: String, uiLanguage: String?
    ) -> String {
        "v\(cacheSchemaVersion)|logic \(logicVersion) (\(logicBuild))|ui \(uiLanguage ?? "unknown")"
    }

    /// The token for the Logic that is running now, or nil when there is no
    /// Logic to ask — and an unscopable cache is treated as absent, never
    /// guessed at.
    func quantizeValuesScope() -> String? {
        guard let logic = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let bundleURL = logic.bundleURL,
              let info = Bundle(url: bundleURL)?.infoDictionary else { return nil }
        let language = LogicUILanguage.report(
            LogicUILanguage.evidence(bundleIdentifier: bundleIdentifier, runningBundleURL: bundleURL)
        ).language
        return Self.quantizeValuesScope(
            logicVersion: (info["CFBundleShortVersionString"] as? String) ?? "?",
            logicBuild: (info["CFBundleVersion"] as? String) ?? "?",
            uiLanguage: language
        )
    }

    /// The list for this install, or nil when there is not a usable one. A
    /// file stamped for another Logic or another language can never become
    /// useful again, so it is retired rather than re-read and re-rejected.
    func cachedQuantizeValues() -> [String]? {
        loadScopedCache(
            Self.quantizeValuesCacheURL, scope: quantizeValuesScope(),
            as: [String].self, deleteOnMismatch: true
        )
    }

    /// Every path that computes the list populates the cache — the read
    /// tool's `include_quantize_values`, and the WRITE path, which has the
    /// whole menu open in front of it every time it sets `quantize` and used
    /// to throw it away.
    func rememberQuantizeValues(_ values: [String]) {
        guard !values.isEmpty else { return }
        saveScopedCache(values, to: Self.quantizeValuesCacheURL, scope: quantizeValuesScope())
    }

    /// Presses one item by exact (case-insensitive) title. Never fuzzy: a near
    /// miss is refused with the real list, because picking the wrong quantize
    /// grid is a musical change nobody asked for.
    private func pickInspectorMenuItem(
        _ popup: AXUIElement, title: String, parameter: String
    ) throws {
        try withInspectorMenu(popup) { menu in
            let items = children(of: menu)
                .filter { stringAttribute($0, kAXRoleAttribute as String) == "AXMenuItem" }
            // The write path has the quantize menu open in front of it, which
            // is the same 715 ms walk the read path pays for
            // `include_quantize_values`. Every path that computes cacheable
            // data populates the cache, so it is banked here too rather than
            // read and dropped.
            if parameter == "quantize" { rememberQuantizeValues(menuTitles(menu)) }
            func titleOf(_ item: AXUIElement) -> String {
                stringAttribute(item, kAXTitleAttribute as String)
            }
            var chosen = items.first {
                titleOf($0).compare(title, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            }
            if chosen == nil {
                // The fade Type pop-up DISPLAYS "X" for the item spelled
                // "X (Crossfade)", so the value read off Logic is not a legal
                // argument unless the short form is accepted too. Ambiguity is
                // still refused: two items with the same head is no answer.
                let heads = items.filter {
                    RegionInspector.popupValuesMatch(titleOf($0), title)
                }
                if heads.count == 1 { chosen = heads[0] }
            }
            guard let item = chosen else {
                throw LogicianError.presetNotFound(
                    plugin: "the Region inspector's \(parameter) pop-up",
                    requested: title,
                    available: menuTitles(menu)
                )
            }
            guard stringAttribute(item, kAXEnabledAttribute as String) == "1" else {
                throw LogicianError.valueNotWritable(
                    "'\(title)' is disabled in the \(parameter) menu"
                )
            }
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    // MARK: - Read

    /// Reads the Region inspector's rows, for one addressed region or for
    /// whatever is selected.
    ///
    /// WHOSE ROWS THESE ARE is decided before they are read, and only on the
    /// addressed path. `track_name` selects the region EXCLUSIVELY first, and
    /// the panel can still be showing the selection that replaced — measured
    /// 2026-09-02, ~15 ms after the write it read "MIDI Defaults" — so the
    /// panel is polled until it names a region (`settledRegionInspectorPanel`)
    /// and the rows are refused if it never does. This tool used to report
    /// that stale subject and hand back the TRACK's region defaults under a
    /// `region` key naming the region it had asked for: an honest-looking
    /// wrong answer, and the reason the refusal is worth a read tool throwing.
    ///
    /// With NO track_name nothing is selected and nothing is polled: the panel
    /// is whatever the user left on screen, "3 selected" and "MIDI Defaults"
    /// are then true answers, and they are reported as `subject`.
    func readRegionParameters(
        trackName: String?, regionName: String?, startBar: Int?, includeQuantizeValues: Bool,
        trackNumber: Int? = nil
    ) throws -> [String: Any] {
        var addressed: [String: Any]?
        var settled: RegionInspectorPanel?
        if let trackName {
            addressed = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
                trackNumber: trackNumber
            )
            let panel = try settledRegionInspectorPanel(
                addressedRegionName: addressed?["name"] as? String
            )
            if let refusal = RegionInspector.addressedPanelRefusal(
                panel.subject, addressedRegionName: addressed?["name"] as? String,
                outcome: "nothing was read"
            ) {
                throw LogicianError.preconditionUnmet(
                    refusal + " Call this tool with no track_name to read whatever the panel IS "
                        + "showing, or select the region with logic_select_region first."
                )
            }
            settled = panel
        }
        let (payload, panelState) = try withRegionInspector(
            needMore: true, startingFrom: settled
        ) { panel, rows in
            var result: [String: Any] = [
                "project_document": (try? projectDocumentPath()) ?? NSNull(),
                "panel_name": panel.panelName,
                "subject": self.subjectDictionary(panel.subject),
                "rows": rows.filter { !$0.isMoreRow }.map(\.dictionary)
            ]
            if let type = self.inferredRegionType(rows) { result["region_type"] = type }
            result["parameters"] = self.namedParameters(rows)
            if includeQuantizeValues {
                if let quantize = rows.first(where: {
                    RegionInspector.parameter(forLabel: $0.label)?.key == "quantize"
                }), let popup = quantize.value {
                    let menu = try self.quantizeMenuOptions(popup)
                    result["quantize_values"] = menu.values
                    result["quantize_values_source"] = menu.source
                    result["quantize_values_note"] = "Logic's own quantize menu, verbatim — the "
                        + "vocabulary logic_set_region_params accepts for `quantize`. Separator rows "
                        + "are omitted; 'Make Groove Template' and 'Remove Groove Template from List' "
                        + "are commands rather than values and this server does not press them. "
                        + "`quantize_values_source` says whether the list was read off the menu just "
                        + "now ('logic_menu', ~0.7 s) or came from this Logic install's cached copy "
                        + "('cache'), which is retired the moment Logic's version or UI language "
                        + "changes."
                }
            }
            return result
        }
        var result = payload
        result["panel_state"] = panelState
        if let addressed {
            result["region"] = [
                "track_name": addressed["track_name"] ?? "",
                "name": addressed["name"] ?? "",
                "start_bar": addressed["start_bar"] ?? NSNull(),
                "end_bar": addressed["end_bar"] ?? NSNull(),
                "type": addressed["type"] ?? NSNull()
            ]
        }
        result["note"] = "Every row the Region inspector publishes, in Logic's own order, plus the "
            + "named parameters logic_set_region_params can write. A row that is disabled is one "
            + "the region type does not use, or one Logic gates behind another setting (every Q-row "
            + "is dead while Quantize is Off). 'display' is Logic's own text and is ABSENT at a "
            + "parameter's default, which Logic prints blank."
        return result
    }

    private func subjectDictionary(_ subject: RegionInspector.PanelSubject) -> [String: Any] {
        switch subject {
        case .region(let name): return ["kind": "region", "name": name]
        case .multiple(let count): return ["kind": "multiple", "count": count]
        case .defaults(let kind): return ["kind": "defaults", "defaults_for": kind]
        }
    }

    /// Resolves every shipped parameter to the ROW it is, by position in
    /// Logic's own order — never by label alone, because the audio panel
    /// publishes two rows called `Curve`.
    func regionParameterRows(
        _ rows: [RegionInspectorRow]
    ) -> [String: RegionInspectorRow] {
        let indexes = RegionInspector.rowIndexes(labels: rows.map(\.label))
        var resolved: [String: RegionInspectorRow] = [:]
        for (key, index) in indexes where rows.indices.contains(index) {
            resolved[key] = rows[index]
        }
        return resolved
    }

    private func namedParameters(_ rows: [RegionInspectorRow]) -> [String: Any] {
        var named: [String: Any] = [:]
        for (key, row) in regionParameterRows(rows) {
            guard let parameter = RegionInspector.parameter(key: key) else { continue }
            // `writable` is what an agent needs, and it is NOT the AXValue
            // settable flag: a checkbox and a pop-up publish an unsettable
            // AXValue and are written by pressing them. Only a slider is
            // written through AXValue, and only while its row is enabled.
            var entry: [String: Any] = [
                "enabled": row.enabled,
                "writable": row.enabled && (row.control == .slider ? row.settable : true),
                // Which ROW this is, in Logic's own order. It is the address
                // the write path uses, and the only thing that tells the two
                // `Curve` rows apart.
                "row": row.index
            ]
            // A row whose LABEL is a pop-up can be in another mode, and then
            // the value is another quantity: `Speed Up` rather than `Fade-In`.
            if row.label.caseInsensitiveCompare(parameter.labels[0]) != .orderedSame {
                entry["row_label"] = row.label
            }
            switch row.control {
            case .checkbox:
                if let state = RegionInspector.checkboxState(row.raw) {
                    entry["value"] = state
                } else {
                    entry["value"] = NSNull()
                    entry["mixed"] = true
                }
            case .slider:
                guard let raw = Int(row.raw) else { continue }
                for (field, value) in RegionInspector.report(
                    key: parameter.key, raw: raw, published: row.display ?? ""
                ) { entry[field] = value }
            case .popup:
                entry["value"] = row.raw
                if row.raw == RegionInspector.mixedPopupValue { entry["mixed"] = true }
            default:
                continue
            }
            named[parameter.key] = entry
        }
        return named
    }

    // MARK: - Write

    /// One requested change, already validated against the catalogue.
    private struct PlannedWrite {
        let parameter: RegionInspector.Parameter
        let sliderValue: Int?
        let popupValue: String?
        let checkboxValue: Bool?
        let expected: Any?
    }

    func setRegionParameters(
        trackName: String?, regionName: String?, startBar: Int?,
        scope: String, arguments: [String: Any], expected: [String: Any],
        trackNumber: Int? = nil
    ) throws -> [String: Any] {
        // 1. What was asked for, checked before anything is touched.
        var planned: [PlannedWrite] = []
        for key in RegionInspector.writeOrder {
            guard let argument = arguments[key] else { continue }
            guard let parameter = RegionInspector.parameter(key: key) else { continue }
            switch parameter.control {
            case .checkbox:
                guard let flag = argument as? Bool else {
                    throw LogicianError.invalidArguments("\(key) takes true or false")
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: nil, popupValue: nil,
                    checkboxValue: flag, expected: expected[key]
                ))
            case .popup:
                guard let text = argument as? String else {
                    throw LogicianError.invalidArguments("\(key) takes a string, as the menu spells it")
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: nil, popupValue: text,
                    checkboxValue: nil, expected: expected[key]
                ))
            default:
                let value: Int
                do {
                    value = try RegionInspector.sliderValue(key: key, argument: argument)
                } catch let error as RegionInspector.ValueError {
                    throw LogicianError.invalidArguments(Self.describe(error))
                }
                planned.append(PlannedWrite(
                    parameter: parameter, sliderValue: value, popupValue: nil,
                    checkboxValue: nil, expected: expected[key]
                ))
            }
        }
        guard !planned.isEmpty else {
            throw LogicianError.invalidArguments(
                "nothing to set: pass at least one of "
                    + RegionInspector.writeOrder.joined(separator: ", ")
            )
        }
        let unknown = Set(expected.keys).subtracting(planned.map(\.parameter.key))
        guard unknown.isEmpty else {
            throw LogicianError.invalidArguments(
                "expected_current names parameters that are not being set: "
                    + unknown.sorted().joined(separator: ", ")
            )
        }

        // 2. A MULTI-SELECTION MAKES EVERY SLIDER RELATIVE. Measured
        //    2026-08-28: with two regions selected, a slider reads its own
        //    DEFAULT (Q-Strength 100, Q-Swing 50) whatever the regions hold,
        //    an AXValue write applies the DELTA from that default to each
        //    region separately (50 and 90 both moved by -10 when 90 was
        //    written), and the control snaps straight back to the default — so
        //    the write is neither absolute nor verifiable. Pop-ups and
        //    checkboxes are absolute over a selection and read back correctly,
        //    so those are what `selection` ships with.
        if scope == "selection" {
            let relative = planned
                .filter { $0.parameter.control != .popup && $0.parameter.control != .checkbox }
                .map(\.parameter.key)
            guard relative.isEmpty else {
                throw LogicianError.preconditionUnmet(
                    "scope 'selection' cannot set \(relative.joined(separator: ", ")): over a "
                        + "multi-selection Logic turns every numeric region control into a RELATIVE "
                        + "one — it shows the parameter's default, applies the difference to each "
                        + "region, and springs back, so the value cannot be set or verified "
                        + "(measured 2026-08-28). Nothing was written. The pop-up and checkbox "
                        + "parameters ARE absolute over a selection ("
                        + RegionInspector.writable
                            .filter { $0.control == .popup || $0.control == .checkbox }
                            .map(\.key).sorted().joined(separator: ", ")
                        + "); for the numeric ones address the regions one at a time with "
                        + "scope 'region'."
                )
            }
        }

        // 3. Address the region, and settle the question of WHOSE parameters
        //    are on screen before a single control is touched — a write into
        //    "MIDI Defaults" would change what every future region on the
        //    track inherits, silently. `selection` deliberately leaves the
        //    selection alone: writing through a multi-selection is how one
        //    call reaches a whole track (measured: both selected regions took
        //    the write).
        var addressed: [String: Any]?
        var selectedCount: Int?
        let panel: RegionInspectorPanel
        if scope == "selection" {
            selectedCount = try? selectedRegionCount()
            // This call selected nothing, so there is nothing to wait for and
            // no addressed region to check a reserved-looking panel string
            // against: "3 selected" here is the state the caller set up on
            // purpose, and it is the whole point of the scope.
            panel = try regionInspectorPanel()
            if case .defaults(let kind) = panel.subject {
                throw LogicianError.preconditionUnmet(
                    "No region is selected: the Region inspector is showing the track's \(kind) "
                        + "region DEFAULTS, which decide what every future region on that track "
                        + "inherits. Nothing was written. Select the regions first with "
                        + "logic_select_regions, or address one region with track_name and "
                        + "scope 'region'."
                )
            }
        } else {
            guard let trackName else {
                throw LogicianError.invalidArguments("scope 'region' needs track_name")
            }
            addressed = try selectRegion(
                trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
                trackNumber: trackNumber
            )
            // The `selectedRegionCount() == 1` walk that used to stand here
            // cost 72 ms to answer a question the panel answers 7 ms later for
            // free and project-wide (the count sees RENDERED rows only, so on
            // a project with a collapsed folder stack it was blind to the very
            // regions it claimed to cover). What it was ALSO doing, unmeasured,
            // was giving Logic 72 ms to repaint the inspector after the
            // selection write — so the wait is now an explicit look-first poll
            // of that 7 ms read instead. A walk used as a delay is a delay
            // nobody can find; see `PanelSettlePoll` for the race it hid.
            panel = try settledRegionInspectorPanel(
                addressedRegionName: addressed?["name"] as? String
            )
            if let refusal = RegionInspector.addressedPanelRefusal(
                panel.subject, addressedRegionName: addressed?["name"] as? String,
                outcome: "nothing was written"
            ) {
                throw LogicianError.preconditionUnmet(
                    refusal + " Pass scope: 'selection' to write to everything selected on "
                        + "purpose, or re-address the region — a region's start_bar changes with "
                        + "every edit, so re-read logic_list_regions."
                )
            }
        }

        let needMore = planned.contains { $0.parameter.underMore }
        let (payload, panelState) = try withRegionInspector(
            needMore: needMore, startingFrom: panel
        ) { panel, rows in
            try self.applyRegionWrites(
                panel: panel, rows: rows, planned: planned, scope: scope,
                addressed: addressed, selectedCount: selectedCount
            )
        }
        var result = payload
        result["panel_state"] = panelState
        return result
    }

    private static func describe(_ error: RegionInspector.ValueError) -> String {
        switch error {
        case .notANumber(let key, let given, let unit):
            return "\(key) takes a whole number\(unit.isEmpty ? "" : " in \(unit)"); got '\(given)'"
        case .outOfRange(let key, let given, let range, let unit):
            return "\(key) = \(given) is outside Logic's own range "
                + "\(range.lowerBound)…\(range.upperBound)\(unit.isEmpty ? "" : " \(unit)")"
        case .outOfDecibelRange(let key, let given, let limit):
            return "\(key) = \(given) dB is outside Logic's own region-gain range "
                + "-\(limit)…+\(limit) dB"
        case .unknownName(let key, let given, let available):
            return "\(key) does not take '\(given)'; Logic's values are "
                + available.joined(separator: ", ")
        case .outOfRangeForRegionType(let key, let given, let range, let unit, let regionType):
            return "\(key) = \(given) is outside the range Logic gives \(regionType) regions, "
                + "\(range.lowerBound)…\(range.upperBound)\(unit.isEmpty ? "" : " \(unit)")"
        }
    }

    private func applyRegionWrites(
        panel: LogicAccessibility.RegionInspectorPanel,
        rows: [RegionInspectorRow],
        planned: [PlannedWrite],
        scope: String,
        addressed: [String: Any]?,
        selectedCount: Int?
    ) throws -> [String: Any] {
        // Whose parameters are on screen was settled by the caller, before the
        // panel was even unfolded — `setRegionParameters` polls for it and
        // refuses there, because a refusal that arrives after the disclosures
        // have been opened is a refusal that moved the UI to say no.
        let regionType = inferredRegionType(rows)

        // EVERY argument is checked against the region type BEFORE the first
        // write, not as its turn comes: a call that names one audio parameter
        // and one MIDI one must write neither, rather than write the first and
        // then refuse. Same for the ranges that depend on the type — audio
        // Transpose caps at ±36 where MIDI runs to ±96.
        var addressedRows = regionParameterRows(rows)
        for write in planned {
            let parameter = write.parameter
            if let regionType, !parameter.regionTypes.contains(regionType) {
                throw LogicianError.valueNotWritable(
                    "\(parameter.key) is a \(parameter.regionTypes.sorted().joined(separator: "/"))"
                        + "-region parameter and this is \(regionType == RegionInspector.midi ? "a MIDI" : "an audio")"
                        + " region — the inspector does not show it. Nothing was written."
                )
            }
            if let value = write.sliderValue {
                do {
                    try RegionInspector.checkRange(
                        key: parameter.key, value: value, regionType: regionType
                    )
                } catch let error as RegionInspector.ValueError {
                    throw LogicianError.invalidArguments(Self.describe(error) + "; nothing was written")
                }
            }
            // Compare-and-set is checked here too, for the same reason: "any
            // mismatch writes nothing" has to mean nothing, including the
            // parameters that come before the one that mismatched.
            if write.expected != nil, let row = addressedRows[parameter.key] {
                try enforceExpectation(write, row: row)
            }
        }

        var changed: [[String: Any]] = []
        var unchanged: [[String: Any]] = []
        var currentRows = rows

        for write in planned {
            let parameter = write.parameter
            guard let row = addressedRows[parameter.key], let control = row.value else {
                // Reverse is the row that actually goes missing in practice:
                // Logic replaces it with a placeholder while FLEX is on, and
                // transposing or fine-tuning an audio region switches Flex on
                // by itself (measured 2026-08-28 — transpose 12 made row 18
                // read "-", transpose 0 brought Reverse back, still ticked).
                let flexIsOn = currentRows.first { $0.label == "Flex" }?.raw == "1"
                throw LogicianError.parameterNotFound(
                    "the Region inspector published no '\(parameter.labels[0])' row"
                        + (parameter.underMore ? " (it lives under 'More')" : "")
                        + (parameter.after.isEmpty
                            ? ""
                            : " that follows the '\(parameter.after[0])' row — the panel has two rows "
                                + "called '\(parameter.labels[0])' and this one is addressed by position")
                        + (parameter.key == "reverse" && flexIsOn
                            ? ". Flex is ON for this region, and Logic hides Reverse entirely while "
                                + "it is: transposing or fine-tuning an audio region switches Flex on "
                                + "by itself, so set transpose and fine_tune back to 0 to get Reverse "
                                + "back (the setting survives — it is the row that disappears)"
                            : "")
                )
            }
            // The two fade rows carry a MODE pop-up as their label: the same
            // control is a fade length or a `Speed Up`/`Slow Down` ramp length,
            // and writing 400 ms of "fade" into a speed-up ramp would be a
            // silent wrong answer rather than an error.
            if parameter.refuseAlternateMode,
               row.label.caseInsensitiveCompare(parameter.labels[0]) != .orderedSame {
                throw LogicianError.preconditionUnmet(
                    "the row \(parameter.key) writes is switched to '\(row.label)' mode in Logic "
                        + "(its label is a pop-up: '\(parameter.labels.joined(separator: "' / '"))'), "
                        + "so its value is a \(row.label.lowercased()) length and not a fade length. "
                        + "Nothing was written. Switch the row back to '\(parameter.labels[0])' in "
                        + "Logic's Region inspector first."
                )
            }
            guard row.enabled else {
                throw LogicianError.valueNotWritable(
                    "the '\(row.label)' row is disabled"
                        + (parameter.key.hasPrefix("q_")
                            ? " — Logic greys every Q-row out while Quantize is Off; set quantize in the same call"
                            : "")
                )
            }

            let before = describeRow(row, parameter: parameter)
            var route = ""
            switch parameter.control {
            case .checkbox:
                guard let target = write.checkboxValue else { continue }
                let state = RegionInspector.checkboxState(row.raw)
                if state == target {
                    unchanged.append(["parameter": parameter.key, "value": target])
                    continue
                }
                // The control publishes only AXPress, so this is a converge
                // rather than a write — and over a multi-selection whose
                // regions DISAGREE it starts from Logic's mixed state (AXValue
                // 2), where one press turns them all ON. Reaching OFF from
                // there therefore takes two presses; the loop is capped at two
                // and the read-back below is what decides.
                for _ in 0..<2 {
                    _ = AXUIElementPerformAction(control, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.35)
                    if RegionInspector.checkboxState(
                        stringAttribute(control, kAXValueAttribute as String)
                    ) == target { break }
                }
                route = state == nil ? "ax_checkbox_press_from_mixed" : "ax_checkbox_press"
            case .popup:
                guard let target = write.popupValue else { continue }
                if RegionInspector.popupValuesMatch(row.raw, target) {
                    unchanged.append(["parameter": parameter.key, "value": row.raw])
                    continue
                }
                try pickInspectorMenuItem(control, title: target, parameter: parameter.key)
                route = "ax_popup_menu_press"
            default:
                guard let target = write.sliderValue else { continue }
                if Int(row.raw) == target {
                    unchanged.append([
                        "parameter": parameter.key,
                        "value": RegionInspector.report(
                            key: parameter.key, raw: target, published: row.display ?? ""
                        )
                    ])
                    continue
                }
                let status = AXUIElementSetAttributeValue(
                    control, kAXValueAttribute as CFString, NSNumber(value: target)
                )
                guard status == .success else {
                    throw LogicianError.writeFailed(
                        "the AXValue write on '\(row.label)' returned AXError \(status.rawValue)"
                    )
                }
                route = "ax_value_absolute"
            }
            Thread.sleep(forTimeInterval: 0.35)

            // Read back off Logic, then re-read the whole outline: setting
            // Quantize ENABLES six other rows, so the rows a later write in
            // this same call needs are not the ones read at the top.
            guard let outline = firstDescendant(
                of: panel.group, maximumDepth: AXDepth.regionInspectorOutline, where: {
                    stringAttribute($0, kAXRoleAttribute as String) == "AXOutline"
                }
            ) else {
                throw LogicianError.verificationFailed(
                    requested: "a read-back of '\(row.label)'",
                    actual: "the parameter outline vanished after the write", restored: false
                )
            }
            currentRows = regionInspectorRows(outline)
            addressedRows = regionParameterRows(currentRows)
            guard let after = addressedRows[parameter.key] else {
                throw LogicianError.verificationFailed(
                    requested: "a read-back of '\(row.label)'",
                    actual: "the row vanished after the write", restored: false
                )
            }
            try verify(write, row: after, parameter: parameter)
            changed.append([
                "parameter": parameter.key,
                "row": after.index,
                "before": before,
                "after": describeRow(after, parameter: parameter),
                "write_route": route
            ])
        }

        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": changed.isEmpty ? "already_set" : "region_params_set",
            "scope": scope,
            "changed": changed,
            "unchanged": unchanged,
            "panel_name": panel.panelName,
            "subject": subjectDictionary(panel.subject)
        ]
        if let regionType { result["region_type"] = regionType }
        if let addressed {
            result["region"] = [
                "track_name": addressed["track_name"] ?? "",
                "name": addressed["name"] ?? "",
                "start_bar": addressed["start_bar"] ?? NSNull(),
                "type": addressed["type"] ?? NSNull()
            ]
        }
        if scope == "selection" {
            result["regions_affected"] = selectedCount ?? NSNull()
            result["selection_note"] = "Every SELECTED region took these values — measured, not "
                + "assumed. The count is the arrangement map's, which sees visible track rows only, "
                + "so the write can have reached more regions than the number shown."
        }
        result["note"] = "Region parameters are Logic's own non-destructive playback settings: the "
            + "recorded notes and the audio file on disk are untouched, so quantize, transpose, "
            + "gain, the fades and reverse are all reversible by setting them back. They do change "
            + "how the region SOUNDS."
        return result
    }

    private func describeRow(
        _ row: RegionInspectorRow, parameter: RegionInspector.Parameter
    ) -> Any {
        switch parameter.control {
        case .checkbox:
            return RegionInspector.checkboxState(row.raw) as Any? ?? "mixed"
        case .popup:
            return row.raw
        default:
            guard let raw = Int(row.raw) else { return row.raw }
            return RegionInspector.report(
                key: parameter.key, raw: raw, published: row.display ?? ""
            )
        }
    }

    /// Compare-and-set. A parameter reading as MIXED across a multi-selection
    /// cannot be compared to one expected value, and is refused rather than
    /// guessed at.
    private func enforceExpectation(_ write: PlannedWrite, row: RegionInspectorRow) throws {
        guard let expected = write.expected else { return }
        let key = write.parameter.key
        switch write.parameter.control {
        case .checkbox:
            guard let wanted = expected as? Bool else {
                throw LogicianError.invalidArguments("expected_current.\(key) takes true or false")
            }
            guard let actual = RegionInspector.checkboxState(row.raw) else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)",
                    actual: "\(key) differs between the selected regions (Logic's mixed state)"
                )
            }
            guard actual == wanted else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)", actual: "\(key) = \(actual)"
                )
            }
        case .popup:
            guard let wanted = expected as? String else {
                throw LogicianError.invalidArguments("expected_current.\(key) takes a string")
            }
            guard RegionInspector.popupValuesMatch(row.raw, wanted) else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = '\(wanted)'", actual: "\(key) = '\(row.raw)'"
                )
            }
        default:
            let wanted: Int
            do {
                wanted = try RegionInspector.sliderValue(key: key, argument: expected)
            } catch let error as RegionInspector.ValueError {
                throw LogicianError.invalidArguments("expected_current." + Self.describe(error))
            }
            guard Int(row.raw) == wanted else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(key) = \(wanted)", actual: "\(key) = \(row.raw)"
                )
            }
        }
    }

    // MARK: - Rename

    /// Renames one region by writing the Region inspector's own name field.
    ///
    /// There is no rename DIALOG and no key command in this path: the panel's
    /// title is an `AXTextField` whose `AXValue` is settable (measured
    /// 2026-08-28), so the rename is one write and one confirm. The field is a
    /// direct child of the panel group and is published whether the panel's
    /// disclosure triangle is open or shut, so nothing is unfolded here and
    /// the inspector is left exactly as it was found.
    ///
    /// Verified in BOTH channels, and case is part of the name: the panel
    /// reads the new name back AND the arrangement map shows it on the region
    /// at that position, each compared EXACTLY. The panel alone would only
    /// prove that a text field accepted text; the map alone reads a parsed
    /// `AXHelp` sentence rather than Logic's own live view of the selected
    /// region, and the two disagreeing is the staleness class this family has
    /// been fixing all week — so a disagreement is a `verification_failed`
    /// naming both values. The compare used to be case-INSENSITIVE while the
    /// already-set short-circuit was case-sensitive, which left a case-only
    /// rename ("Crash" → "CRASH") taking the write path and then unverifiable
    /// by the only check present.
    ///
    /// ONE arrangement walk before the write, not three (measured 2026-09-02:
    /// a walk is 64–74 ms and this tool took four of them, 34% of an 816 ms
    /// call). `selectRegion` is handed the walk instead of taking its own, the
    /// before-snapshot is parsed out of the same rows, and the
    /// `selectedRegionCount() == 1` walk is gone: it cost 72 ms to answer a
    /// question the panel's own subject answers 7 ms later for free, and
    /// answers project-wide — the count sees rendered rows only, so on this
    /// project it was blind to the collapsed folder stack it claimed to cover.
    /// What that walk was ALSO doing, unmeasured, was giving Logic's inspector
    /// 72 ms to repaint after the selection write; that is now an explicit
    /// look-first poll of the 7 ms panel read (`settledRegionInspectorPanel`,
    /// shared with the two `region_params` tools), because a walk used as a
    /// delay is a delay nobody can find.
    ///
    /// No blind sleep after the confirm either: measured 2026-09-02, BOTH the
    /// panel and the arrangement map already carried the new name on the first
    /// look, 7 of 7, 1.2–3.0 ms after `kAXConfirmAction`. The readbacks ARE
    /// the wait, and the 0.4 s budget below is only spent by a channel that
    /// disagrees.
    /// - Parameter trackNumber: addresses the ROW by number instead of
    ///   trusting the name to be unique (see `resolveRegionRow`).
    func renameRegion(
        trackName: String, regionName: String?, startBar: Int?,
        newName: String, expectedCurrentName: String?, trackNumber: Int? = nil
    ) throws -> [String: Any] {
        let wanted = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw LogicianError.invalidArguments("new_name must be non-empty")
        }
        guard !newName.contains(where: \.isNewline) else {
            throw LogicianError.invalidArguments("new_name must be a single line")
        }
        // Logic's own two panel strings are refused as NAMES, before anything
        // is written: the name field is where Logic says whose parameters are
        // on screen, so a region called "2 selected" or "MIDI Defaults" reads
        // as a selection state to every Region-inspector tool — this one
        // included, which is why the write would be one this server could not
        // undo.
        if let reason = RegionInspector.reservedPanelNameReason(wanted) {
            throw LogicianError.invalidArguments(
                "new_name refused: \(reason). A region carrying it reads as a selection state "
                    + "rather than a name, so this tool could not rename it back and "
                    + "logic_set_region_params could not write its parameters. Nothing was "
                    + "written. Use '\(RegionInspector.unreservedAlternative(to: wanted))' or any "
                    + "other name Logic does not print for itself."
            )
        }

        // ONE walk, shared: `selectRegion` is handed these rows, and the
        // before-snapshot is parsed out of them. Parsed BEFORE the selection
        // write, never after — a write republishes the layout items, and a
        // held element re-read past one can answer stale.
        let rows = try regionRows()
        let before = try regionSnapshot(
            trackName: trackName, trackNumber: trackNumber, alreadyWalkedRows: rows
        )
        let addressed = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true,
            trackNumber: trackNumber, alreadyWalkedRows: rows
        )

        // The panel can still be showing the selection this call REPLACED, and
        // the name field it is about to write is also the field it classifies
        // the panel by. Both are `settledRegionInspectorPanel`'s job now — the
        // same poll and the same cross-examination `logic_get_region_params`
        // and `logic_set_region_params` take, in one place rather than three.
        let panel = try settledRegionInspectorPanel(
            addressedRegionName: addressed["name"] as? String
        )
        if let refusal = RegionInspector.addressedPanelRefusal(
            panel.subject, addressedRegionName: addressed["name"] as? String,
            outcome: "nothing was renamed"
        ) {
            throw LogicianError.preconditionUnmet(refusal)
        }
        guard let field = panel.nameField else {
            throw LogicianError.valueNotWritable(
                "the Region inspector published its title as static text, not as a name field"
            )
        }
        let currentName = Self.comparableName(panel.panelName)
        if let expectedCurrentName,
           currentName.compare(expectedCurrentName, options: .caseInsensitive) != .orderedSame {
            throw LogicianError.currentValueMismatch(
                expected: "the region is named '\(expectedCurrentName)'",
                actual: "the Region inspector shows '\(currentName)'"
            )
        }
        if currentName == wanted {
            return [
                "success": true, "verified": true, "state": "already_set",
                "from": currentName, "to": wanted,
                "region": Self.addressedRegion(addressed),
                "note": "the region already carries that name; nothing was written"
            ]
        }
        guard isSettable(field, kAXValueAttribute as String) else {
            throw LogicianError.valueNotWritable(
                "the Region inspector's name field is not settable right now"
            )
        }
        let status = AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, wanted as CFString
        )
        guard status == .success else {
            throw LogicianError.writeFailed(
                "the name write returned AXError \(status.rawValue)"
            )
        }
        _ = AXUIElementPerformAction(field, kAXConfirmAction as CFString)

        // Look before sleeping, in both channels, and give a channel that
        // disagrees a budget rather than charging every call for one. The
        // panel is polled first because it is the cheap read (7–15 ms against
        // the map's 68 ms arrangement walk) and it is Logic's own live view.
        let position = addressed["start_bar"] as? Int
        let beat = addressed["start_beat"] as? Int
        let deadline = Date().addingTimeInterval(0.4)
        var panelName = Self.comparableName(try regionInspectorPanel().panelName)
        while panelName != wanted, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.015)
            panelName = Self.comparableName(try regionInspectorPanel().panelName)
        }
        var after = try regionSnapshot(trackName: trackName, trackNumber: trackNumber)
        var mapName = Self.mapName(in: after, startBar: position, startBeat: beat)
        while mapName != wanted, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.015)
            after = try regionSnapshot(trackName: trackName, trackNumber: trackNumber)
            mapName = Self.mapName(in: after, startBar: position, startBeat: beat)
        }
        let verdict = Self.renameVerification(
            wanted: wanted, panelName: panelName, mapName: mapName
        )
        if let mismatch = verdict.mismatch {
            throw LogicianError.verificationFailed(
                requested: "the region at bar \(position.map(String.init) ?? "?") renamed to '\(wanted)'",
                actual: mismatch, restored: false
            )
        }

        // Logic RENUMBERS default marker names by position when a marker is
        // added; regions are the neighbouring question, so the other regions
        // on the track are compared before and after and any that moved are
        // reported rather than assumed absent.
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "renamed",
            "from": currentName, "to": wanted,
            "panel_name": panelName,
            "region": Self.addressedRegion(addressed),
            "write_route": "ax_value_on_the_inspector_name_field"
        ]
        let sideEffects = Self.otherRegionsThatChangedName(
            before: before, after: after, atStartBar: position, startBeat: beat
        )
        if !sideEffects.isEmpty {
            result["also_renamed"] = sideEffects
            result["also_renamed_note"] = "Logic renamed OTHER regions on this track as a side "
                + "effect of this rename — the same positional renumbering markers do. Nothing "
                + "else was written by this server."
        }
        result["note"] = "The region's name in the arrangement, not the audio file's name and not "
            + "the track's: renaming a region never touches the file on disk. Undo restores the "
            + "old name."
        return result
    }

    /// The region the call actually wrote, in every dimension it was addressed
    /// by. `track_number` and `start_beat` are the two that used to be
    /// resolved and then dropped: on a project with two rows of one name — this
    /// one has two `Ivan Vocals` rows, and `logic_import_midi` manufactures
    /// namesakes — a payload without the row number cannot say which of them
    /// was renamed, and the region is addressed internally by bar AND beat.
    private static func addressedRegion(_ addressed: [String: Any]) -> [String: Any] {
        [
            "track_name": addressed["track_name"] ?? "",
            "track_number": addressed["track_number"] ?? NSNull(),
            "start_bar": addressed["start_bar"] ?? NSNull(),
            "start_beat": addressed["start_beat"] ?? NSNull(),
            "end_bar": addressed["end_bar"] ?? NSNull(),
            "type": addressed["type"] ?? NSNull()
        ]
    }

    /// What the two readbacks add up to. Pure, so the rename's verdict can be
    /// asserted without an Accessibility tree — and one place where "verified"
    /// is defined, rather than a compare in the middle of a 100-line function.
    enum RenameVerification: Equatable {
        case verified
        /// Nothing is at the addressed bar+beat any more: a different failure
        /// from a region with the wrong name, and worth its own sentence.
        case noRegionAtThatPosition(panelName: String)
        case mapDisagrees(mapName: String, panelName: String)
        /// The map carries the new name and Logic's own live view of the
        /// region does not. This is the class the region family has been
        /// fixing all week (the stale LCD mirror, the republished layout
        /// item), and the old code read the panel and threw the answer away.
        case channelsDisagree(mapName: String, panelName: String)

        /// What the channels actually read, for the refusal — nil when the
        /// rename is proven.
        var mismatch: String? {
            switch self {
            case .verified:
                return nil
            case .noRegionAtThatPosition(let panel):
                return "the arrangement map shows no region there, and the Region inspector "
                    + "reads '\(panel)'"
            case .mapDisagrees(let map, let panel):
                return "the arrangement map shows '\(map)' and the Region inspector reads "
                    + "'\(panel)'"
            case .channelsDisagree(let map, let panel):
                return "the arrangement map shows '\(map)' but the Region inspector reads "
                    + "'\(panel)' — the two channels disagree, so the rename is not proven"
            }
        }
    }

    /// Both channels, compared EXACTLY. Case is part of a name: a
    /// case-insensitive compare would report a case-only rename as verified
    /// whether or not Logic had taken it.
    static func renameVerification(
        wanted: String, panelName: String, mapName: String?
    ) -> RenameVerification {
        guard let mapName else { return .noRegionAtThatPosition(panelName: panelName) }
        guard mapName == wanted else {
            return .mapDisagrees(mapName: mapName, panelName: panelName)
        }
        guard panelName == wanted else {
            return .channelsDisagree(mapName: mapName, panelName: panelName)
        }
        return .verified
    }

    /// The name two channels are compared BY: the muted suffix off (the
    /// arrangement map prints "<name>, muted" where the inspector shows the
    /// bare name) and the edge whitespace off (the write is trimmed, so a
    /// readback that is not would differ by nothing). Case is deliberately
    /// left alone — it is part of a name, and this comparison is the whole of
    /// what "verified" means here.
    static func comparableName(_ raw: String) -> String {
        RegionInspector.canonicalPanelName(raw)
    }

    /// What the arrangement map calls the region at one bar+beat, or nil when
    /// there is no region there at all — a real answer, and a different
    /// failure from "a region with the wrong name".
    static func mapName(in snapshot: [[String: Any]], startBar: Int?, startBeat: Int?) -> String? {
        snapshot.first {
            ($0["start_bar"] as? Int) == startBar && ($0["start_beat"] as? Int) == startBeat
        }
        .flatMap { $0["name"] as? String }
        .map(comparableName)
    }

    /// Regions on the same track, other than the renamed one, whose name is
    /// not what it was before the write.
    static func otherRegionsThatChangedName(
        before: [[String: Any]], after: [[String: Any]], atStartBar: Int?, startBeat: Int?
    ) -> [[String: Any]] {
        var moved: [[String: Any]] = []
        for old in before {
            let bar = old["start_bar"] as? Int
            let beat = old["start_beat"] as? Int
            if bar == atStartBar, beat == startBeat { continue }
            guard let fresh = after.first(where: {
                ($0["start_bar"] as? Int) == bar && ($0["start_beat"] as? Int) == beat
            }) else { continue }
            let was = PrintedRegion.canonicalName(old["name"] as? String ?? "")
            let now = PrintedRegion.canonicalName(fresh["name"] as? String ?? "")
            if was != now {
                moved.append(["start_bar": bar ?? NSNull(), "from": was, "to": now])
            }
        }
        return moved
    }

    private func verify(
        _ write: PlannedWrite, row: RegionInspectorRow, parameter: RegionInspector.Parameter
    ) throws {
        switch parameter.control {
        case .checkbox:
            guard RegionInspector.checkboxState(row.raw) == write.checkboxValue else {
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = \(write.checkboxValue.map(String.init) ?? "?")",
                    actual: "the checkbox reads '\(row.raw)'", restored: false
                )
            }
        case .popup:
            guard let target = write.popupValue,
                  RegionInspector.popupValuesMatch(row.raw, target) else {
                // Logic ACCEPTS the menu press and then springs the control
                // back where the value does not apply: a crossfade type on a
                // region with no neighbour to cross into reverted to 'Out'
                // every time, and took as 'X' the moment an adjacent region
                // existed (measured 2026-08-28).
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = '\(write.popupValue ?? "")'",
                    actual: "the pop-up reads '\(row.raw)'"
                        + (parameter.key == "fade_type"
                            ? " — Logic keeps a crossfade type only where there is an adjacent "
                                + "region to cross into; with none it springs back to 'Out'"
                            : ""),
                    restored: false
                )
            }
        default:
            guard Int(row.raw) == write.sliderValue else {
                throw LogicianError.verificationFailed(
                    requested: "\(parameter.key) = \(write.sliderValue.map(String.init) ?? "?")",
                    actual: "the control reads '\(row.raw)'", restored: false
                )
            }
        }
    }

}
