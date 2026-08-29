import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Offline bounce

    /// Presses a menu bar item found by title path fragment, e.g. Bounce >
    /// "Project or Section…".
    ///
    /// `settled` makes the press VERIFIED instead of merely performed: when it
    /// is given, the press is followed by polling it, and a press that
    /// returned `.success` while nothing happened falls back to the keystroke
    /// the menu item advertises for itself (see `MenuShortcut`). Callers that
    /// pass nothing get exactly the behaviour this had before — press, trust
    /// the status code, return — which is what the bounce path has always
    /// done and what it is live-verified with.
    func pressMenuItem(
        containing fragment: String,
        underMenu parent: String,
        settled: (() -> Bool)? = nil
    ) throws {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else { throw LogicianError.logicNotRunning }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        // elementAttribute, not `as!` on the raw attribute: a menu bar that
        // comes back as a non-element reports "menu bar not found" instead
        // of trapping and killing the server.
        guard let menuBar = elementAttribute(appElement, kAXMenuBarAttribute as String) else {
            throw LogicianError.windowNotFound("menu bar")
        }
        var target: AXUIElement?
        func walk(_ element: AXUIElement, depth: Int, path: [String]) {
            guard depth <= AXDepth.menuBarItem, target == nil else { return }
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
        walk(menuBar, depth: 0, path: [])
        if target == nil {
            // A submenu Logic has never opened publishes ONE untitled child
            // instead of its items — measured 2026-08-28 on `Logic Pro > Key
            // Commands`, whose only child had no title at all while `Settings`
            // and `Control Surfaces` right above it were fully populated. So
            // "not found" can mean "not built yet": press the parent, which
            // makes AppKit build the menu, and walk again. The menu is
            // cancelled unless the second walk finds the item, because an open
            // menu swallows Logic's keyboard and the next key command with it.
            var parentItem: AXUIElement?
            walk2: for candidate in descendants(of: menuBar, maximumDepth: AXDepth.menuBarItem) {
                if stringAttribute(candidate, kAXTitleAttribute as String) == parent,
                   ["AXMenuItem", "AXMenuBarItem"]
                    .contains(stringAttribute(candidate, kAXRoleAttribute as String)) {
                    parentItem = candidate
                    break walk2
                }
            }
            if let parentItem {
                _ = AXUIElementPerformAction(parentItem, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.5)
                walk(menuBar, depth: 0, path: [])
                if target == nil {
                    _ = AXUIElementPerformAction(parentItem, kAXCancelAction as CFString)
                }
            }
        }
        guard let item = target else {
            throw LogicianError.windowNotFound("menu item '\(fragment)' under '\(parent)'")
        }
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed("menu press returned AXError \(status.rawValue)")
        }
        guard let settled else { return }
        for _ in 0..<12 {
            if settled() { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        // The press said `.success` and nothing happened. Measured 2026-08-28:
        // `Logic Pro > Key Commands > Edit Assignments…` answers `.success` to
        // both AXPress and AXPick and never opens its window, while the same
        // code opens the bounce dialog every time. The item publishes its own
        // shortcut, so press THAT — never a hardcoded key, which could be
        // bound to anything in the user's set.
        let character = stringAttribute(item, "AXMenuItemCmdChar")
        let modifiers = Int(stringAttribute(item, "AXMenuItemCmdModifiers")) ?? 0
        guard !character.isEmpty,
              let shortcut = MenuShortcut.decode(character: character, modifiers: modifiers) else {
            throw LogicianError.openVerificationFailed(
                "the menu item '\(fragment)' under '\(parent)' was pressed successfully and nothing "
                    + "happened, and it advertises no keyboard shortcut this server can synthesise"
                    + (character.isEmpty ? "" : " (it shows '\(character)')")
            )
        }
        try ensureLogicFrontmost(for: "the \(fragment) keyboard shortcut")
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) else {
            throw LogicianError.writeFailed("could not create the keyboard events for \(fragment)")
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if settled() { return }
        }
        throw LogicianError.openVerificationFailed(
            "'\(fragment)' under '\(parent)' did not take effect - neither the menu press nor its own "
                + "shortcut \(MenuShortcut.describe(character: character, modifiers: modifiers))"
        )
    }

    func bounceDialog(timeout: Double = 4.0) -> AXUIElement? {
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

    /// Drives one of the bounce dialog's Start/End position fields to the START
    /// OF A BAR, and verifies it against the field's own bar/beat display.
    ///
    /// THE FIELD. Four `AXSlider` digits that all mirror one absolute tick
    /// count. Writing a value inside the range steps it by exactly ONE of
    /// Logic's bars toward that value; writing the field minimum clamps it to
    /// `1 1 1 1` and erases any sub-bar remainder with it.
    ///
    /// WHY THE DISPLAY IS THE TRUTH (measured 2026-08-28, and the bug this
    /// replaces). The old converger computed a target tick count as
    /// `minimum + (bar - 1) x oneFourFourBar` and compared the raw value
    /// against it. Logic's own bar step is METER-AWARE — inside the sandbox
    /// project's 5/4 stretch each press moved 5 beats' worth of ticks, outside
    /// it 4 — so on a project with a meter change the raw value can never equal
    /// that arithmetic, AND a position that displays as `63 3 1 1` divides
    /// evenly by the 4/4 bar, which made the sub-bar clamp think there was
    /// nothing to clear. The field walked from bar 63 down to `3 2 1 1` and
    /// stalled there, one beat off the line and one bar short, while the caller
    /// asked for bar 4. Comparing Logic's own bar/beat text instead is both
    /// meter-proof and readable in the error.
    ///
    /// GUARDS. Every path is bounded: a total write budget, a stall counter,
    /// and an overshoot check. Nothing here can spin against a clamp — the
    /// failure is an error naming what BOTH fields read, not a loop.
    func setBouncePosition(
        group: AXUIElement,
        bar: Int,
        field: String = "position",
        sibling: (() -> String)? = nil
    ) throws {
        guard let segment = children(of: group).first,
              let minimum = Int64(stringAttribute(segment, kAXMinValueAttribute as String)) else {
            throw LogicianError.valueNotWritable("bounce position group has no readable segments")
        }
        let ticksPerBar: Int64 = 16_492_674_416_640
        var budget = 400

        func display() -> BouncePosition? {
            BouncePosition.parse(stringAttribute(group, kAXValueAttribute as String))
        }
        func raw() -> Int64? { Int64(stringAttribute(segment, kAXValueAttribute as String)) }
        func write(_ value: Int64) {
            AXUIElementSetAttributeValue(
                segment, kAXValueAttribute as CFString, NSNumber(value: value)
            )
            Thread.sleep(forTimeInterval: 0.04)
        }
        func failure(_ reason: String) -> LogicianError {
            let others = sibling.map { ", the other field reads '\($0())'" } ?? ""
            return LogicianError.verificationFailed(
                requested: "the bounce \(field) position at bar \(bar)",
                actual: reason + others + ". Nothing was bounced",
                restored: false
            )
        }

        guard let start = display() else {
            throw LogicianError.valueNotWritable("bounce position value unreadable")
        }
        if start.bar == bar, start.isBarStart { return }

        // 1. Anything not exactly on a bar line, or already past the target,
        //    goes back to the field minimum first: it is the one absolute move
        //    the field offers, and it erases sub-bar remainders.
        if !start.isBarStart || start.bar > bar {
            var stall = 0
            while true {
                guard let current = display() else { throw failure("the field stopped publishing a position") }
                if current.bar == 1, current.isBarStart { break }
                guard budget > 0 else { throw failure("it stalled at '\(current.text)' on the way to bar 1") }
                let before = raw()
                write(minimum)
                budget -= 1
                if raw() == before {
                    stall += 1
                    if stall >= 3 { throw failure("it will not move below '\(current.text)'") }
                } else {
                    stall = 0
                }
            }
        }

        // 2. Step up, one of Logic's bars per write. The written value is only
        //    a DIRECTION: under a meter change it underestimates where the
        //    target bar sits, so a stall below the target bumps it one bar
        //    further rather than giving up on arithmetic that was never exact.
        var hint = minimum + Int64(bar - 1) * ticksPerBar
        var stall = 0
        while true {
            guard let current = display() else { throw failure("the field stopped publishing a position") }
            if current.bar == bar, current.isBarStart { return }
            if current.bar > bar {
                throw failure("it stepped past the target to '\(current.text)'")
            }
            guard budget > 0 else { throw failure("it stalled at '\(current.text)'") }
            let before = raw()
            write(hint)
            budget -= 1
            if raw() == before {
                stall += 1
                hint += ticksPerBar
                if stall >= 6 { throw failure("it will not move past '\(current.text)'") }
            } else {
                stall = 0
            }
        }
    }

    /// Cancels an open Bounce dialog (modal — it freezes MCU and most AX
    /// operations, so it must NEVER be left up on an error path).
    func cancelBounceDialog() {
        guard let windows = try? logicWindows() else { return }
        for window in windows
        where stringAttribute(window, kAXTitleAttribute as String).contains("Bounce")
            || stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog" {
            if let cancel = firstDescendant(of: window, maximumDepth: AXDepth.bounceDialogControl, where: {
                stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                    && stringAttribute($0, kAXTitleAttribute as String) == "Cancel"
            }) {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.4)
                return
            }
        }
    }

    func destinationRows(in dialog: AXUIElement) -> [(name: String, checkbox: AXUIElement)] {
        guard let scroll = children(of: dialog).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXScrollArea"
        }) else { return [] }
        var rows: [(String, AXUIElement)] = []
        collect(from: scroll, maximumDepth: AXDepth.bounceDestinationList) { element in
            if stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox" {
                rows.append((stringAttribute(element, kAXDescriptionAttribute as String), element))
            }
        }
        return rows
    }

    // MARK: - Bounce dialog options (G53)

    /// The element's top-left corner in screen points, nil when it publishes
    /// no position.
    func origin(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
        return point
    }

    /// The pop-up that belongs to a label, paired by GEOMETRY.
    ///
    /// Logic's bounce dialog publishes its labels as `AXStaticText` and its
    /// controls as `AXPopUpButton` **siblings**, and neither carries a
    /// description or a title that connects them — the only thing that says
    /// `Bit Depth:` goes with the `24-bit` pop-up is that they sit on the same
    /// row. Measured 2026-08-28: every label sat at x=715 and its pop-up at
    /// x=819 with the pop-up's y exactly ONE point above the label's
    /// (187/186, 217/216, 247/246, 277/276, 307/306), so "same row, to the
    /// right, nearest" is the rule, with a few points of tolerance.
    func labelledPopUp(
        in root: AXUIElement, label: String, maximumDepth: Int = 3
    ) -> AXUIElement? {
        var labels: [AXUIElement] = []
        var popups: [AXUIElement] = []
        walk(from: root, maximumDepth: maximumDepth) { element in
            switch stringAttribute(element, kAXRoleAttribute as String) {
            case "AXStaticText":
                let value = stringAttribute(element, kAXValueAttribute as String)
                if value == label || value == label + ":" { labels.append(element) }
            case "AXPopUpButton":
                popups.append(element)
            default:
                break
            }
            return .descend
        }
        for text in labels {
            guard let anchor = origin(of: text) else { continue }
            let row = popups.compactMap { popup -> (AXUIElement, CGFloat)? in
                guard let point = origin(of: popup),
                      abs(point.y - anchor.y) <= 3, point.x > anchor.x else { return nil }
                return (popup, point.x - anchor.x)
            }.sorted { $0.1 < $1.1 }
            if let nearest = row.first?.0 { return nearest }
        }
        return nil
    }

    /// Chooses one item in a pop-up by title and reads the pop-up back.
    ///
    /// The readback is the verification: pressing a menu item reports success
    /// whether or not the menu was even open (v0.31.0's lesson), so the value
    /// the pop-up shows afterwards is the only evidence that counts.
    @discardableResult
    func selectPopUpItem(_ popup: AXUIElement, title: String) throws -> String {
        let before = stringAttribute(popup, kAXValueAttribute as String)
        if before.caseInsensitiveCompare(title) == .orderedSame { return before }
        dismissPopupMenus()
        var menu: AXUIElement?
        pressing: for attempt in 0..<3 {
            _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.15)
                if let open = popupMenus().first { menu = open; break pressing }
            }
            if attempt < 2 { dismissPopupMenus() }
        }
        guard let menu else {
            throw LogicianError.openVerificationFailed(
                "the '\(before)' pop-up did not open, so '\(title)' could not be chosen"
            )
        }
        guard let item = findMenuItem(in: menu, titled: title) else {
            dismissPopupMenus()
            throw LogicianError.parameterNotFound(
                "'\(title)' in the pop-up currently showing '\(before)'"
            )
        }
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.3)
        dismissPopupMenus()
        let after = stringAttribute(popup, kAXValueAttribute as String)
        guard after.caseInsensitiveCompare(title) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "the pop-up on '\(title)'",
                actual: "it still shows '\(after)'",
                restored: false
            )
        }
        return before
    }

    /// A titled checkbox anywhere under `root`.
    func checkBox(in root: AXUIElement, titled title: String, maximumDepth: Int = 3) -> AXUIElement? {
        firstDescendant(of: root, maximumDepth: maximumDepth) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                && stringAttribute($0, kAXTitleAttribute as String) == title
        }
    }

    /// Sets a checkbox and reads it back. Returns what it was before.
    @discardableResult
    func setCheckBox(_ box: AXUIElement, to wanted: Bool) throws -> Bool {
        let before = stringAttribute(box, kAXValueAttribute as String) == "1"
        guard before != wanted else { return before }
        _ = AXUIElementPerformAction(box, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        let after = stringAttribute(box, kAXValueAttribute as String) == "1"
        guard after == wanted else {
            throw LogicianError.verificationFailed(
                requested: "the checkbox \(wanted ? "on" : "off")",
                actual: "it is \(after ? "on" : "off")",
                restored: false
            )
        }
        return before
    }

    /// Applies the caller's delivery options to an OPEN bounce dialog and
    /// reports what each control read before and after. Every value is
    /// canonicalised first (so an unknown one is refused before any press),
    /// and every write is verified by reading the control back.
    ///
    /// These settings PERSIST in Logic between bounces — the dialog is the
    /// user's own preference sheet — so nothing is restored afterwards and the
    /// result says so instead of pretending it was temporary.
    func applyBounceOptions(
        dialog: AXUIElement, options: [String: String], includeAudioTail: Bool?
    ) throws -> [String: Any] {
        var applied: [String: Any] = [:]
        let popupSpec: [(argument: String, label: String, values: [String])] = [
            ("file_type", "File Type", BounceFormat.fileTypes),
            ("bit_depth", "Bit Depth", BounceFormat.bitDepths),
            ("sample_rate", "Sample Rate", BounceFormat.sampleRates),
            ("dithering", "Dithering", BounceFormat.ditherings),
            ("normalize", "Normalize", BounceFormat.normalizeModes)
        ]
        for spec in popupSpec {
            guard let raw = options[spec.argument] else { continue }
            guard let title = BounceFormat.canonical(raw, in: spec.values) else {
                throw LogicianError.invalidArguments(
                    BounceFormat.rejection(raw, label: spec.label, options: spec.values)
                )
            }
            guard let popup = labelledPopUp(in: dialog, label: spec.label) else {
                throw LogicianError.windowNotFound(
                    "the '\(spec.label):' pop-up in the bounce dialog (it only exists while the "
                        + "Uncompressed destination is selected)"
                )
            }
            let before = try selectPopUpItem(popup, title: title)
            applied[spec.argument] = ["from": before, "to": title]
        }
        if let includeAudioTail {
            guard let box = checkBox(in: dialog, titled: "Include Audio Tail") else {
                throw LogicianError.windowNotFound("the 'Include Audio Tail' checkbox")
            }
            let before = try setCheckBox(box, to: includeAudioTail)
            applied["include_audio_tail"] = ["from": before, "to": includeAudioTail]
        }
        return applied
    }

    /// Every delivery control the dialog is currently showing, read-only —
    /// what the produced file will be if nothing is changed.
    func readBounceOptions(dialog: AXUIElement) -> [String: Any] {
        var state: [String: Any] = [:]
        for (argument, label) in [
            ("file_type", "File Type"), ("bit_depth", "Bit Depth"),
            ("sample_rate", "Sample Rate"), ("dithering", "Dithering"),
            ("normalize", "Normalize")
        ] {
            if let popup = labelledPopUp(in: dialog, label: label) {
                state[argument] = stringAttribute(popup, kAXValueAttribute as String)
            }
        }
        for (argument, title) in [
            ("include_audio_tail", "Include Audio Tail"),
            ("include_tempo_information", "Include Tempo Information"),
            ("bounce_2nd_cycle_pass", "Bounce 2nd Cycle Pass")
        ] {
            if let box = checkBox(in: dialog, titled: title) {
                state[argument] = stringAttribute(box, kAXValueAttribute as String) == "1"
            }
        }
        return state
    }

    func savePanelApplication() -> AXUIElement? {
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

    func bounceRange(
        startBar: Int,
        endBar: Int,
        label: String,
        expectedProjectPath: String?,
        options: [String: String] = [:],
        includeAudioTail: Bool? = nil
    ) throws -> [String: Any] {
        try verifyProjectPath(expectedProjectPath)
        guard endBar > startBar else {
            throw LogicianError.invalidArguments("end_bar must be greater than start_bar")
        }
        try ensureLogicFrontmost(for: "the bounce dialog") // dialogs need key focus

        // Progress runs on a 0…100 scale for this whole tool: the phases are
        // not countable units, and one scale keeps every step comparable and
        // strictly increasing, which is what the spec asks of `progress`.
        // Cancellation is checked freely up to the moment OK is pressed; after
        // that Logic owns the render and abandoning is only as clean as the
        // existing 60 s timeout is (the file Logic is writing is left where
        // Logic put it, and nothing is moved into the captures directory).
        try checkCancelled()
        try pressMenuItem(containing: "Project or Section", underMenu: "Bounce")
        guard let dialog = bounceDialog() else {
            throw LogicianError.windowNotFound("bounce dialog")
        }
        reportProgress("bounce dialog open", percent: 5)

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

        // Delivery options (G53). Applied BEFORE the positions so a refusal on
        // an unknown value costs nothing but the dialog, and read back
        // afterwards so the result can state what the file actually is.
        var appliedOptions: [String: Any] = [:]
        do {
            appliedOptions = try applyBounceOptions(
                dialog: dialog, options: options, includeAudioTail: includeAudioTail
            )
        } catch {
            dismissPopupMenus()
            cancelBounceDialog()
            throw error
        }
        let deliveredAs = readBounceOptions(dialog: dialog)
        reportProgress("delivery options applied", percent: 15)

        // Positions: start and end groups (tab-separated bar values).
        let groups = children(of: dialog).filter {
            stringAttribute($0, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute($0, kAXValueAttribute as String).contains("\t")
        }
        guard groups.count == 2 else {
            _ = children(of: dialog).first { stringAttribute($0, kAXTitleAttribute as String) == "Cancel" }
                .map { AXUIElementPerformAction($0, kAXPressAction as CFString) }
            throw LogicianError.windowNotFound("start/end position fields in the bounce dialog")
        }
        // ORDER MATTERS, and which order depends on where the range is going.
        // The two fields describe ONE range and Logic can clamp a write that
        // would invert it, so the field that cannot invert anything goes
        // first: moving the range entirely later writes the END first, every
        // other move writes the START first. (Measured 2026-08-28 with a
        // start left at bar 9 and an end at bar 63 while bars 2-4 were asked
        // for: writing the end first walked it down PAST the start, which is
        // the inversion this decides away.)
        func positionText(_ group: AXUIElement) -> String {
            stringAttribute(group, kAXValueAttribute as String)
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let currentEnd = BouncePosition.parse(
            stringAttribute(groups[1], kAXValueAttribute as String)
        )?.bar ?? endBar
        switch BounceWriteOrder.choose(currentEnd: currentEnd, targetStart: startBar) {
        case .endFirst:
            try setBouncePosition(
                group: groups[1], bar: endBar, field: "end",
                sibling: { positionText(groups[0]) }
            )
            try setBouncePosition(
                group: groups[0], bar: startBar, field: "start",
                sibling: { positionText(groups[1]) }
            )
        case .startFirst:
            try setBouncePosition(
                group: groups[0], bar: startBar, field: "start",
                sibling: { positionText(groups[1]) }
            )
            try setBouncePosition(
                group: groups[1], bar: endBar, field: "end",
                sibling: { positionText(groups[0]) }
            )
        }

        guard let okButton = children(of: dialog).first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == "OK"
        }) else {
            throw LogicianError.windowNotFound("OK button in the bounce dialog")
        }
        // Last cancellation point that costs nothing: after this the dialog is
        // gone and Logic is committed.
        try checkCancelled()
        reportProgress("bars \(startBar)–\(endBar) set; starting the render", percent: 25)
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
                self.firstDescendant(of: window, maximumDepth: AXDepth.bounceDialogControl, where: {
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
            throw LogicianError.openVerificationFailed("the save panel did not appear")
        }

        // The panel keeps its default name regardless of AXValue writes, so we
        // accept the default and move the rendered file to the label name after.
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "logicmcp-\(sanitizedFilenameComponent(label, fallback: "bounce"))-\(timestamp)"
        guard let bounceButton = firstDescendant(of: panel, maximumDepth: AXDepth.bounceDialogControl, where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == "Bounce"
        }) else {
            throw LogicianError.openVerificationFailed("no Bounce button in the save panel")
        }
        guard AXUIElementPerformAction(bounceButton, kAXPressAction as CFString) == .success else {
            throw LogicianError.writeFailed("pressing Bounce failed")
        }
        // A possible "already exists" sheet: press Replace.
        Thread.sleep(forTimeInterval: 0.25)
        if let replace = (try? logicWindows())?.lazy.compactMap({ window in
            self.firstDescendant(of: window, maximumDepth: AXDepth.bounceDialogControl, where: {
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
        var stableRounds = 0
        // Leaving this loop by `break` (the render settled) and leaving it
        // because 60 s elapsed are DIFFERENT outcomes, and only the first one
        // is evidence. `resultPath != nil` cannot tell them apart: it is set
        // the moment the file APPEARS, not when Logic has finished writing it,
        // so a render longer than the deadline used to fall straight through
        // to `success: true, verified: true` over a half-written file.
        var renderSettled = false
        let renderBudget: TimeInterval = 60
        let renderStart = Date()
        let renderDeadline = renderStart.addingTimeInterval(renderBudget)
        while Date() < renderDeadline {
            try checkCancelled()
            Thread.sleep(forTimeInterval: 0.1)
            if resultPath == nil { resultPath = findResult() }
            // The bytes on disk are the only honest progress signal Logic
            // gives: it publishes no percentage the Accessibility tree can
            // read. The NUMBER therefore tracks the 60 s budget (which is
            // bounded and monotonic) and the MESSAGE carries the byte count,
            // rather than pretending a growing file size is a fraction of a
            // total nobody knows.
            let spent = Date().timeIntervalSince(renderStart) / renderBudget
            reportProgress(
                resultPath == nil
                    ? "rendering; waiting for Logic to open the file"
                    : "rendering: \(String(format: "%.1f", Double(lastSize) / 1_048_576)) MB written",
                percent: 25 + 65 * min(spent, 0.99), throttle: 1
            )
            if let path = resultPath {
                let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64) ?? 0
                // "Same size 100 ms apart" also holds for a file Logic has
                // only paused writing, and the metric readers then walk a
                // half-written chunk table. Require the container header to
                // account for every byte as well, where it can be read.
                let header = FileHandle(forReadingAtPath: path).flatMap { handle -> Data? in
                    defer { try? handle.close() }
                    return try? handle.read(upToCount: 12)
                }
                let complete = LogicAccessibility.containerComplete(
                    header: header ?? Data(), fileSize: size
                ) ?? true
                if size > 0, size == lastSize {
                    stableRounds += 1
                    // Stable AND complete is the real finish line; the
                    // stable-round fallback keeps a container we cannot judge
                    // from blocking until the 60 s deadline.
                    if complete || stableRounds >= 20 {
                        renderSettled = true
                        break // render finished
                    }
                } else {
                    stableRounds = 0
                }
                lastSize = size
            }
        }
        guard let renderedPath = resultPath else {
            throw LogicianError.openVerificationFailed(
                "no bounced file appeared within 60 s"
            )
        }
        guard renderSettled else {
            // The file exists but Logic was still writing it when the 60 s ran
            // out. Reporting it would hand back a truncated render as a
            // verified bounce — and the metrics reader would then measure the
            // part that happened to be on disk, which is the "confidently
            // wrong" answer this server exists to prevent.
            throw LogicianError.openVerificationFailed(
                "the bounce was still being written after 60 s (\(lastSize) bytes so far, at"
                    + " '\(renderedPath)'). Logic is STILL RENDERING and the file is incomplete —"
                    + " nothing was moved into the captures directory and no metrics were taken."
                    + " Bounce a shorter bar range, or wait and read the file yourself with"
                    + " logic_get_audio_clip once Logic's progress sheet is gone."
            )
        }
        reportProgress("render finished (\(lastSize) bytes)", percent: 91)
        // Move the render into the captures directory under the label name.
        let capturesDirectory = Captures.ensureRoot()
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

        reportProgress("encoding the preview", percent: 95)
        let bouncePreview = LogicAccessibility.makeAACPreview(sourcePath: finalPath)
        let earCopy = LogicAccessibility.encodeEarCopy(path: finalPath)
        reportProgress("bounce complete", percent: 100)
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "bounced",
            "path": finalPath,
            "preview_path": bouncePreview.map { $0 as Any } ?? NSNull() as Any,
            "start_bar": startBar,
            "end_bar": endBar,
            "bytes": Int(lastSize),
            "write_route": "bounce_dialog_offline",
            // What the file IS, read off the dialog's own controls just
            // before OK was pressed - not what was asked for.
            "delivered_as": deliveredAs,
            "note": earCopy != nil
                ? "This result CARRIES the bounce as an MCP audio content block - listen to it now. If no audio block reached you, your client drops them: open preview_path with your client's FILE VIEWER instead (passes as real audio in most clients). NEVER read audio files as text/bash."
                : "Offline render of the master output. To LISTEN: open preview_path with your client's FILE VIEWER (real audio in most clients), or logic_get_audio_clip for a windowed clip. NEVER read audio files as text/bash."
        ]
        if let earCopy {
            result["_audio"] = ["data": earCopy.base64EncodedString(), "mimeType": "audio/mp4"]
        }
        if !appliedOptions.isEmpty {
            result["options_changed"] = appliedOptions
            result["options_note"] = "These are the USER'S OWN bounce settings and Logic keeps them "
                + "for the next bounce - they were changed, not borrowed, and nothing here puts them "
                + "back. Pass the same arguments explicitly next time rather than assuming a default."
        }
        // Two honesty guards, born from a session where an agent "listened"
        // to silent bounces for an hour: name any soloed tracks (a leftover
        // solo silently empties every master bounce), and measure the file.
        if let metrics = LogicAccessibility.audioFileMetrics(path: finalPath) {
            result["metrics"] = metrics
            if let rms = metrics["rms_db"] as? [Double], rms.allSatisfy({ $0 <= -65 }) {
                result["warning"] = "THE BOUNCE IS SILENT (rms \(rms) dB). A leftover solo on a quiet track, or an empty bar range, produces exactly this - fix the cause and bounce again; do not analyze this file."
            }
        }
        let soloed = soloedTrackNamesIfReadable()
        if let soloed, !soloed.isEmpty {
            result["soloed_tracks"] = soloed
            if result["warning"] == nil {
                result["warning"] = "Tracks currently SOLOED: \(soloed.joined(separator: ", ")). This bounce contains ONLY those tracks - unsolo first if you meant to bounce the full mix."
            }
        } else if soloed == nil {
            // "I could not look" is not "nothing was soloed": a leftover solo
            // is exactly what makes a master bounce silently wrong, so an
            // unreadable Tracks area has to be said out loud.
            appendWarning(
                "SOLO STATE NOT CHECKED: Logic's track headers could not be read, so this bounce"
                    + " was NOT checked for a leftover solo. If any track is soloed, this file"
                    + " contains only that track.",
                to: &result
            )
        }
        return result
    }

    /// The soloed tracks, or `nil` when the track headers could not be read at
    /// all — so `[]` means "nothing is soloed" and never "the read failed".
    ///
    /// The two used to collapse into one value at every call site
    /// (`(try? soloedTrackNames()) ?? []`), which is the difference between a
    /// pre-flight refusal and a pass: `logic_export_stems` refuses to run when
    /// anything is already soloed, because every stem would then contain that
    /// track — and an unreadable Tracks area answered that question with
    /// "nothing is soloed".
    ///
    /// Note what a NON-nil answer still does not prove: `parsedTrackHeaders`
    /// publishes only the rows Logic has RENDERED, so a soloed track scrolled
    /// out of the Tracks area is invisible here. `[]` is evidence, not proof —
    /// see `TrackListCompleteness`.
    func soloedTrackNamesIfReadable() -> [String]? {
        try? soloedTrackNames()
    }

    /// Names of all tracks whose header Solo checkbox is lit.
    func soloedTrackNames() throws -> [String] {
        let headers = try parsedTrackHeaders()
        var names: [String] = []
        for header in headers {
            for child in children(of: header.item)
            where stringAttribute(child, kAXRoleAttribute as String) == "AXCheckBox"
                && stringAttribute(child, kAXDescriptionAttribute as String) == "Solo" {
                let value = stringAttribute(child, kAXValueAttribute as String)
                if value == "1" || value == "on" { names.append(header.name) }
            }
        }
        return names
    }

    /// Encodes a file as a small mono AAC "ear copy" suitable for an MCP
    /// audio content block (nil when encoding fails or the result exceeds
    /// the safe attachment size). This is what lets bounce/render results
    /// CARRY their own sound instead of just naming a file.
    static func encodeEarCopy(path: String, maxBytes: Int = 400_000) -> Data? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-ear-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        // No "-c 1": forcing mono fails on AIFFs with an explicit stereo
        // channel layout ('cclo' -66564); stereo 64 kbps stays small enough.
        convert.arguments = [path, scratch.path, "-f", "m4af", "-d", "aac", "-b", "64000"]
        convert.standardError = FileHandle.nullDevice
        try? convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0,
              let data = try? Data(contentsOf: scratch),
              !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    /// True when a chunk body of `bodyBytes` bytes lies inside the file. The
    /// IFF walk loop only proves the 8-byte chunk HEADER is present, so every
    /// read past it needs its own check: a file truncated within 4 bytes of an
    /// SSND header used to trap on the `Data` subscript, and a Swift trap
    /// takes down the whole MCP server, not just the request.
    static func chunkBodyInBounds(offset: Int, bodyBytes: Int, count: Int) -> Bool {
        guard offset >= 0, bodyBytes >= 0, count >= 8, offset <= count - 8 else { return false }
        return count - offset - 8 >= bodyBytes
    }

    /// Whether `fileSize` covers the container declared in the first bytes of
    /// an audio file: AIFF/AIFC ("FORM", big-endian) and WAV ("RIFF",
    /// little-endian) both declare the payload size that follows their 8-byte
    /// header. Returns nil for anything else, so callers can keep whatever
    /// they did before on a format this cannot judge.
    ///
    /// Needed because "the size did not change over 100 ms" also holds for a
    /// render Logic has merely paused writing — measuring one of those is how
    /// a truncated chunk table reaches the readers above.
    static func containerComplete(header: Data, fileSize: UInt64) -> Bool? {
        guard header.count >= 8 else { return nil }
        let bytes = [UInt8](header.prefix(8))
        let declared: UInt64
        switch String(bytes: bytes[0..<4], encoding: .ascii) ?? "" {
        case "FORM":
            declared = (UInt64(bytes[4]) << 24) | (UInt64(bytes[5]) << 16)
                | (UInt64(bytes[6]) << 8) | UInt64(bytes[7])
        case "RIFF":
            declared = (UInt64(bytes[7]) << 24) | (UInt64(bytes[6]) << 16)
                | (UInt64(bytes[5]) << 8) | UInt64(bytes[4])
        default:
            return nil
        }
        guard declared > 8 else { return false }
        return fileSize >= declared + 8
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
            // The offset field lives in the chunk BODY, which the loop
            // condition does not guarantee is present: without this check a
            // file truncated inside an SSND header traps on the subscript.
            if chunkID == "SSND",
               LogicAccessibility.chunkBodyInBounds(offset: offset, bodyBytes: 4, count: data.count) {
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

    /// Writes a compressed stereo AAC (.m4a) sibling of an audio file —
    /// natively playable/attachable in agent clients (AIFF often is not).
    static func makeAACPreview(sourcePath: String) -> String? {
        let source = URL(fileURLWithPath: sourcePath)
        let destination = source.deletingPathExtension()
            .appendingPathExtension("m4a")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = [
            source.path, destination.path,
            "-f", "m4af", "-d", "aac", "-b", "128000"
        ]
        convert.standardError = FileHandle.nullDevice
        guard (try? convert.run()) != nil else { return nil }
        convert.waitUntilExit()
        guard convert.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination.path
    }

    /// Cuts a time range out of an AIFF/AIFC render (16/24-bit PCM or fl32)
    /// and writes it as a 32-bit float WAV, computing RMS/peak on the slice
    /// in the same pass. Freeze files start at project start (bar 1), so
    /// bar positions convert directly to seconds via tempo.
    /// A seconds offset as a frame index inside a file of `cap` frames,
    /// clamped at BOTH ends and never trapping.
    ///
    /// Pure and separately tested because the inputs are agent-supplied and
    /// the consumer is an unsafe pointer walk: `Int(_:)` traps on a value a
    /// Double can hold but an Int cannot, and a NEGATIVE index is not a short
    /// read but a read outside the allocation entirely. Out-of-range seconds
    /// clamp to the nearest end of the file rather than refusing, so a window
    /// that straddles the start still yields the part of it that exists;
    /// `nil` is only for a rate this cannot be measured against.
    static func audioFrameIndex(_ seconds: Double, rate: Double, cap: Int) -> Int? {
        guard seconds.isFinite, rate.isFinite, rate > 0, cap >= 0 else { return nil }
        let frames = seconds * rate
        // Also catches -infinity from the multiplication itself.
        guard frames > 0 else { return 0 }
        guard frames < Double(cap) else { return cap }
        return Int(frames)
    }

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
            // The offset field lives in the chunk BODY, which the loop
            // condition does not guarantee is present: without this check a
            // file truncated inside an SSND header traps on the subscript.
            if chunkID == "SSND",
               LogicAccessibility.chunkBodyInBounds(offset: offset, bodyBytes: 4, count: data.count) {
                let dataOffset = Int(beUInt32(offset + 8))
                soundStart = offset + 16 + dataOffset
                soundBytes = size - 8 - dataOffset
            }
            offset += 8 + size + (size % 2)
        }
        // The upper bound is not decoration: the rate comes out of an 80-bit
        // extended float in the file, and it is written back below through
        // `UInt32(sampleRate)`, which TRAPS on anything a UInt32 cannot hold.
        // 768 kHz is past every rate Logic can bounce (DXD tops out at 705.6).
        guard channels > 0, sampleRate > 1000, sampleRate <= 768_000,
              bits == 24 || bits == 16 || (bits == 32 && isFloat),
              soundStart > 0, soundBytes > 0,
              soundStart + soundBytes <= data.count else { return nil }
        let bytesPerSample = bits / 8
        let totalFrames = soundBytes / (bytesPerSample * channels)
        // `startSeconds` arrives straight from a tool argument
        // (`logic_get_audio_clip`), and JSON Schema `minimum` is advisory here
        // — this server validates only `additionalProperties`. So the window
        // is clamped at BOTH ends before it is trusted:
        //
        //  - A negative start used to survive `min(_, totalFrames)` and give a
        //    negative `firstFrame` with a positive `sliceFrames`, and the
        //    sample loop below reads through an UNSAFE pointer — `-100`
        //    seconds walked ~26 MB off the front of the buffer (SIGBUS, which
        //    takes the whole MCP server down rather than the one request).
        //  - A non-finite or astronomically large second count traps in
        //    `Int(_:)` itself, before any clamp can run, so it is refused
        //    rather than converted.
        guard startSeconds.isFinite, endSeconds.isFinite,
              let firstFrame = LogicAccessibility.audioFrameIndex(
                  startSeconds, rate: sampleRate, cap: totalFrames
              ),
              let lastFrame = LogicAccessibility.audioFrameIndex(
                  endSeconds, rate: sampleRate, cap: totalFrames
              )
        else { return nil }
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

    /// Bounce-based A/B evaluation: no playback — two offline
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
        // The master A/B is the one evaluation that needs no track: it bounces
        // the whole mix. So a headerless strip (Stereo Out, an aux, a bus) must
        // reach it — selection is only here to put the strip in the inspector,
        // and a strip already showing there needs no selecting. Same fallback
        // as surveyPlugins; the plugin window below is addressed by strip name.
        do {
            _ = try selectTrack(trackName: trackName, trackNumber: nil, expectedProjectPath: nil)
        } catch let error as LogicianError
        where isHeaderlessStripCandidate(error, trackNumberGiven: false) {
            guard (try? anyInspectorStrip(named: trackName)) != nil else { throw error }
        }
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

        // Prove the parameter can be written BEFORE the baseline bounce.
        // The write sits between the two bounces, so a plugin that publishes
        // no editable field (knob-only: Channel EQ, Limiter — the whole
        // master chain of the reference project) used to fail here after a
        // full offline master render had already run and left its A file on
        // disk. This costs one lookup and the refusal names the surface route
        // that does work.
        let window = try logicWindow(title: trackName)
        try parameterField(in: window, named: parameter, windowTitle: trackName)

        reportProgress("bouncing the BASELINE", percent: 4)
        let bounceA = try withProgressScope(5...45) {
            try bounceRange(
                startBar: startBar, endBar: endBar, label: "A", expectedProjectPath: nil
            )
        }
        reportProgress("applying the change", percent: 46)
        let change = try setParameter(
            windowTitle: trackName, parameterName: parameter,
            expectedCurrentValue: expectedCurrentValue, targetValue: targetValue
        )
        func rollBack() -> Bool {
            ((try? setParameter(
                windowTitle: trackName, parameterName: parameter,
                expectedCurrentValue: targetValue, targetValue: expectedCurrentValue
            )) != nil)
        }
        let bounceB: [String: Any]
        do {
            reportProgress("bouncing AFTER the change", percent: 50)
            bounceB = try withProgressScope(50...92) {
                try bounceRange(
                    startBar: startBar, endBar: endBar, label: "B", expectedProjectPath: nil
                )
            }
        } catch {
            // Never leave the change applied after a failed B bounce - the
            // render/solo_bounce methods already guarantee this.
            cancelBounceDialog()
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

        let pathA = bounceA["path"] as? String ?? ""
        let pathB = bounceB["path"] as? String ?? ""
        reportProgress("measuring A against B", percent: 94)
        let metricsA = LogicAccessibility.audioFileMetrics(path: pathA)
        let metricsB = LogicAccessibility.audioFileMetrics(path: pathB)
        var deltas: [String: Any] = [:]
        if let a = metricsA?["rms_db"] as? [Double], let b = metricsB?["rms_db"] as? [Double] {
            deltas["rms_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }
        if let a = metricsA?["peak_db"] as? [Double], let b = metricsB?["peak_db"] as? [Double] {
            deltas["peak_delta_db"] = zip(a, b).map { (($1 - $0) * 100).rounded() / 100 }
        }

        var evalResult: [String: Any] = [
            "success": true,
            // Same meaning as the render/solo_bounce methods: did we end in
            // the state we promised (rolled back, or deliberately kept)?
            "verified": restored || keepChange,
            "state": "evaluated",
            "method": "bounce",
            "decision": decision,
            "change": [
                // track_name matches the INPUT key so a result round-trips
                // into the next call; `track` stays for existing readers.
                "track": trackName, "track_name": trackName,
                "plugin": pluginName, "parameter": parameter,
                "before": change["before"] ?? expectedCurrentValue,
                "applied": change["after"] ?? targetValue
            ],
            // "range" across all three methods (this one used to say "loop")
            "range": ["start_bar": startBar, "end_bar": endBar],
            "baseline_audio": pathA,
            "after_audio": pathB,
            // One shape across all three methods: keys a method genuinely has
            // nothing for are present and null, so an agent can read the same
            // fields regardless of how the A/B was produced. This method's
            // bounces ARE the full renders, so full == audio here.
            "baseline_full_audio": pathA,
            "after_full_audio": pathB,
            "baseline_preview": bounceA["preview_path"] ?? NSNull(),
            "after_preview": bounceB["preview_path"] ?? NSNull(),
            "baseline_metrics": metricsA ?? NSNull(),
            "after_metrics": metricsB ?? NSNull(),
            "deltas": deltas,
            "note": "Offline 24-bit master renders; no playback occurred. Metrics computed from the files."
        ]
        evalResult = MCUController.attachABAudio(to: evalResult, baselinePath: pathA, afterPath: pathB)
        return evalResult
    }

}
