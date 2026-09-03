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
    ///
    /// **Logic has to be FRONTMOST before ANY menu bar press, unconditionally.**
    /// MEASURED live 2026-09-03: `View > Inspector` pressed with Logic in the
    /// background answered `.success` and left the pane closed, 3/3, including
    /// a System Events click as a control — the same press with Logic
    /// frontmost worked first try (`InspectorVisibility.pressInspectorMenuItem`).
    /// `Mix > Delete Automation` showed the identical shape the same day
    /// (`AXRemoveAutomation.swift`). Both of those fixes put
    /// `ensureLogicFrontmost` in front of their own press; a THIRD caller
    /// (`AXListEditors.withListEditorsTab`, pressing `View > List Editors`) had
    /// skipped it and silently mis-reported the pane as missing the requested
    /// tab instead of never having opened at all. Guarding HERE, once, instead
    /// of at each of the eight call sites means a future caller cannot forget
    /// it — sprinkling the same guard at every site is exactly how the third
    /// one got missed. Free when Logic already is frontmost:
    /// `ensureLogicFrontmost` returns on its very first check (measured
    /// 2026-09-03: ~1 ms warm against 935 ms when Logic had to be activated).
    /// - Parameter requireEnabled: refuse a DISABLED item instead of pressing
    ///   it. Logic answers `.success` to the `AXPress` of a greyed-out item
    ///   and does nothing at all, so a caller that can explain the greying to
    ///   the user is better off being told (measured 2026-09-03: `View >
    ///   Inspector` reads `AXEnabled 0` while a plug-in window is Logic's key
    ///   window, and three presses in a row — this server's and a System
    ///   Events click as a control — left the Inspector exactly as it was).
    ///   Off by default: for the other callers a stale disabled flag would
    ///   turn a press that works into a refusal that does not.
    func pressMenuItem(
        containing fragment: String,
        underMenu parent: String,
        pressLikelyInert: Bool = false,
        requireEnabled: Bool = false,
        settled: (() -> Bool)? = nil
    ) throws {
        try ensureLogicFrontmost(for: "the '\(fragment)' menu press")
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
        if requireEnabled, stringAttribute(item, kAXEnabledAttribute as String) == "0" {
            throw LogicianError.preconditionUnmet(
                "Logic's '\(parent) > \(fragment)' menu item is DISABLED right now, so pressing"
                    + " it would answer success and do nothing. Nothing was pressed."
            )
        }
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed("menu press returned AXError \(status.rawValue)")
        }
        guard let settled else { return }
        // N1. `pressLikelyInert` is the caller saying "this item's AXPress is a
        // MEASURED no-op, do not spend the full budget proving it again". Only
        // `keyCommandsWindow` passes it, and it passes it because the comment
        // four lines below records exactly that measurement: `Logic Pro > Key
        // Commands > Edit Assignments…` answers `.success` to both AXPress and
        // AXPick and opens nothing, every time. The poll was 12 × 0.15 s =
        // 1.8 s of waiting for an outcome this code already knows never
        // arrives, on 100 % of key-command window opens. The bounce path,
        // where the press DOES work and the poll is load-bearing, keeps the
        // full budget — this is scoped, not shortened globally.
        for attempt in 0..<(pressLikelyInert ? 3 : 12) {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.15) }
            if settled() { return }
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
        // N7, pattern #11: this slept BEFORE it looked, so a window that opens
        // in 30 ms still cost 250 ms and one that opens in 260 cost 500 — on
        // every call that reaches the shortcut. The sibling poll fifteen lines
        // up always had the right shape. Same 10 s budget, one free first look.
        for attempt in 0..<40 {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.25) }
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
                stringAttribute($0, kAXTitleAttribute as String)
                    .hasPrefix(LogicUIStrings.Window.bouncePrefix)
            }) {
                return dialog
            }
            // 20 ms, not 100: the read above BLOCKS while Logic is opening the
            // dialog, so the sleep is only the granularity of the look that
            // follows a genuine miss.
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// Types an absolute bar into one of the bounce dialog's position fields —
    /// the whole cost of `setBouncePosition`, replaced by one gesture.
    ///
    /// MEASURED live 2026-09-01 on the sandbox project. The position group is
    /// not just four sliders: it publishes AppKit's text attributes
    /// (`AXFocused` settable, `AXSelectedTextRange`, `AXNumberOfCharacters`),
    /// and focusing it SELECTS THE WHOLE FIELD. Typing `12` into it then
    /// landed `12 1 1 1` — from bar 41, in 53 ms, across the project's 5/4
    /// meter change, in both fields, forwards and backwards, with the
    /// beat/division/tick digits reset to 1 for free (which is the sub-bar
    /// clamp the slider route needs a separate descent to bar 1 to achieve).
    /// The slider route needs one write per bar of distance instead: ~45 ms
    /// each, 3-5 s per field on a 64-bar project.
    ///
    /// WHY THIS CANNOT PRESS OK BY ACCIDENT — the thing to be careful about,
    /// because the dialog is modal and its default button starts a render:
    ///
    /// - Focus is WRITTEN and then READ BACK, and not one key is posted
    ///   unless the field itself says it has focus.
    /// - The commit key is TAB, never Return. Tab moves focus along; Return
    ///   would activate the default button.
    /// - Only digits are typed, and only ever the caller's bar number.
    ///
    /// Returns false — having posted nothing, or having left the field
    /// somewhere it can be stepped from — whenever it cannot prove the field
    /// reads the requested bar. Every false falls through to the slider loop.
    func typeBouncePosition(group: AXUIElement, bar: Int) -> Bool {
        guard bar > 0 else { return false }
        // A bar past the end of the project CLAMPS rather than errors
        // (measured: typing 200 landed `64 1 1 1`), so the read-back below is
        // what catches it - it reports the requested bar was not reached and
        // the slider fallback then fails honestly, naming what the field
        // reads. Nothing here silently accepts a clamp.
        guard AXUIElementSetAttributeValue(
            group, kAXFocusedAttribute as CFString, kCFBooleanTrue
        ) == .success,
            stringAttribute(group, kAXFocusedAttribute as String) == "1" else { return false }

        // Unicode keystrokes, not virtual key codes: the digits must land the
        // same on this machine's Swedish layout as on a US one.
        let source = CGEventSource(stateID: .hidSystemState)
        for character in String(bar).unicodeScalars {
            var unit = UniChar(character.value)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
        }
        let tab: CGKeyCode = 48
        CGEvent(keyboardEventSource: source, virtualKey: tab, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: tab, keyDown: false)?.post(tap: .cghidEventTap)

        // Pace by the effect: the field paints the typed digits before it
        // reformats them (an intermediate read really does say `4` on the way
        // to `42 1 1 1`), so accept only the settled bar/beat text, and give
        // it a bounded window to get there.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if let position = BouncePosition.parse(
                stringAttribute(group, kAXValueAttribute as String)
            ), position.bar == bar, position.isBarStart {
                return true
            }
            Thread.sleep(forTimeInterval: 0.008)
        }
        return false
    }

    /// Drives one of the bounce dialog's Start/End position fields to the START
    /// OF A BAR, and verifies it against the field's own bar/beat display.
    ///
    /// TWO ROUTES, and the fast one is tried first.
    ///
    /// 1. TYPE THE BAR (`typeBouncePosition`). One absolute jump, ~50 ms, any
    ///    distance. This is the path every normal call takes.
    /// 2. STEP THE SLIDER (the loop below). One of Logic's bars per write, so
    ///    O(distance) — kept as the honest fallback for the case where the
    ///    field refuses focus or a keystroke goes astray, and it converges
    ///    from wherever route 1 left the field.
    ///
    /// THE FIELD. Four `AXSlider` digits that all mirror one absolute tick
    /// count. Writing a value inside the range steps it by exactly ONE of
    /// Logic's bars toward that value — MEASURED per write 2026-09-01: the
    /// display lands one bar away 0-6 ms after the write and does not move
    /// again, whatever the value written, so the absolute `hint` below is only
    /// ever a DIRECTION.
    ///
    /// AND WRITING THE MINIMUM DOES NOT CLAMP. The old comment here claimed
    /// `write(minimum)` snaps the field to `1 1 1 1`; measured, it steps ONE
    /// bar down per write exactly like every other value (bar 41 -> `39 4 1 1`
    /// -> `38 4 1 1` -> ...), so the reset path is O(distance) too. It earns
    /// its place only because it is the one direction that erases a sub-bar
    /// remainder.
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
        /// One slider write, waiting for the EFFECT rather than a fixed 40 ms:
        /// measured 2026-09-01, the display lands 0-6 ms after the write on
        /// every step, so the old blind `sleep(0.04)` was ~35 ms of pure wait
        /// per bar of distance. A write that changes nothing still costs the
        /// full window, which is exactly what the stall counters below need.
        func write(_ value: Int64) {
            let before = stringAttribute(group, kAXValueAttribute as String)
            AXUIElementSetAttributeValue(
                segment, kAXValueAttribute as CFString, NSNumber(value: value)
            )
            let deadline = Date().addingTimeInterval(0.04)
            while Date() < deadline {
                if stringAttribute(group, kAXValueAttribute as String) != before { return }
                Thread.sleep(forTimeInterval: 0.004)
            }
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

        // Route 1: type the bar. One gesture, any distance.
        if typeBouncePosition(group: group, bar: bar) { return }

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
        // A write that MOVES the field but not towards the target is not a
        // stall, and the raw-value check above cannot see it. Measured
        // 2026-09-01: at the field's ceiling (bar 64 on this project) the
        // slider oscillates 63 <-> 64 under a hint above it, changing `raw()`
        // every time, so the loop below used to burn its whole 400-write
        // budget - ~18 s - before reporting a target it could never reach.
        // Counting steps that do not close the distance ends that in six.
        var noProgress = 0
        var closest = Int.max
        while true {
            guard let current = display() else { throw failure("the field stopped publishing a position") }
            if current.bar == bar, current.isBarStart { return }
            if current.bar > bar {
                throw failure("it stepped past the target to '\(current.text)'")
            }
            let distance = bar - current.bar
            if distance < closest {
                closest = distance
                noProgress = 0
            } else {
                noProgress += 1
                if noProgress >= 6 {
                    throw failure("it will not move past '\(current.text)' towards bar \(bar)")
                }
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
    ///
    /// Structure first, words second, in both halves of the search. WHICH
    /// window: the `AXDialog` subrole is the locale-independent half of the
    /// filter and the `Bounce` title fragment the English one, and they are
    /// already ORed — so a translated title still reaches the cancel below.
    /// WHICH button: `AXCancelButton` if the dialog publishes one (it is the
    /// button Escape activates, and it does not translate), the button titled
    /// `Cancel` otherwise.
    func cancelBounceDialog() {
        guard let windows = try? logicWindows() else { return }
        for window in windows
        where stringAttribute(window, kAXTitleAttribute as String)
            .contains(LogicUIStrings.Window.bouncePrefix)
            || stringAttribute(window, kAXSubroleAttribute as String) == "AXDialog" {
            if let cancel = abortButton(of: window, maximumDepth: AXDepth.bounceDialogControl) {
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
            ("file_type", LogicUIStrings.Value.bounceFileType, BounceFormat.fileTypes),
            ("bit_depth", LogicUIStrings.Value.bounceBitDepth, BounceFormat.bitDepths),
            ("sample_rate", LogicUIStrings.Value.bounceSampleRate, BounceFormat.sampleRates),
            ("dithering", LogicUIStrings.Value.bounceDithering, BounceFormat.ditherings),
            ("normalize", LogicUIStrings.Value.bounceNormalize, BounceFormat.normalizeModes)
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
            guard let box = checkBox(
                in: dialog, titled: LogicUIStrings.Value.includeAudioTail
            ) else {
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
            ("file_type", LogicUIStrings.Value.bounceFileType),
            ("bit_depth", LogicUIStrings.Value.bounceBitDepth),
            ("sample_rate", LogicUIStrings.Value.bounceSampleRate),
            ("dithering", LogicUIStrings.Value.bounceDithering),
            ("normalize", LogicUIStrings.Value.bounceNormalize)
        ] {
            if let popup = labelledPopUp(in: dialog, label: label) {
                state[argument] = stringAttribute(popup, kAXValueAttribute as String)
            }
        }
        for (argument, title) in [
            ("include_audio_tail", LogicUIStrings.Value.includeAudioTail),
            ("include_tempo_information", LogicUIStrings.Value.includeTempoInformation),
            ("bounce_2nd_cycle_pass", LogicUIStrings.Value.bounce2ndCyclePass)
        ] {
            if let box = checkBox(in: dialog, titled: title) {
                state[argument] = stringAttribute(box, kAXValueAttribute as String) == "1"
            }
        }
        return state
    }

    /// The bounce save panel's commit button — the one titled `Bounce`.
    ///
    /// Identifier first: AppKit gives a save/open panel's confirm button the
    /// `AXIdentifier` `OKButton` whatever it is TITLED (measured on Logic's
    /// import panel, R2 §3.4, where the same button reads `Import`). The
    /// English title is the fallback for a panel that publishes no
    /// identifier, which is exactly the behaviour this had before.
    ///
    /// Doubles as the test for "is this window the save panel?" — the panel is
    /// hosted either inside a Logic window or in an AppKit XPC process, and
    /// carrying this button is what identifies it in both places.
    ///
    /// FOUND BREADTH-FIRST. The button sits within three levels of the panel window; the window's
    /// first child is the file browser, which is thousands of elements deep.
    /// Measured 2026-09-01: pre-order at this depth cap took **993 ms**, the
    /// same predicate breadth-first takes single-digit ms, and this search ran
    /// twice per bounce (once to identify the panel, once to press it) for
    /// ~1.7 s a call. Same cap, same predicates, same one button.
    func savePanelCommitButton(in root: AXUIElement) -> AXUIElement? {
        nearestDescendant(of: root, maximumDepth: AXDepth.bounceDialogControl) {
            self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && self.stringAttribute($0, kAXIdentifierAttribute as String)
                    == LogicUIStrings.Identifier.okButton
        } ?? nearestDescendant(of: root, maximumDepth: AXDepth.bounceDialogControl) {
            self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && self.stringAttribute($0, kAXTitleAttribute as String)
                    == LogicUIStrings.Button.bounce
        }
    }

    /// Presses the save panel's "already exists" Replace button if it is up,
    /// and says whether it pressed anything.
    ///
    /// STILL STRING-GATED, on purpose. The sheet publishes a default button
    /// too, but AppKit's overwrite alert makes CANCEL the default - pressing
    /// "the default" would silently abandon the bounce instead of replacing
    /// the file. Only the title says Replace, so only the title is trusted;
    /// the checklist carries the probe that would give this one a
    /// locale-independent address.
    ///
    /// Breadth-first for the same reason the commit button is: the sheet's
    /// buttons are shallow and the windows underneath it are enormous.
    func pressReplaceSheetIfPresent() -> Bool {
        for window in (try? logicWindows()) ?? [] {
            let match = nearestDescendant(
                of: window, maximumDepth: AXDepth.bounceDialogControl
            ) {
                self.stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                    && self.stringAttribute($0, kAXTitleAttribute as String)
                        == LogicUIStrings.Button.replace
            }
            guard let replace = match else { continue }
            return AXUIElementPerformAction(replace, kAXPressAction as CFString) == .success
        }
        return false
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

    /// - Parameter deliberatelySoloed: the tracks the CALLER soloed on purpose
    ///   before asking for this bounce. `nil` (the default) is a bounce that
    ///   has to find out for itself and walks the track headers to do it.
    ///   Non-nil replaces that walk: the caller already knows, and it is not
    ///   about to be warned about a solo it wrote itself one line earlier.
    ///   `logic_export_stems` passes the one track of the stem — the walk cost
    ///   ~51 ms of `parsedTrackHeaders()` inside EVERY stem, N per export
    ///   (measured 2026-09-02), purely to produce a warning that loop discards.
    func bounceRange(
        startBar: Int,
        endBar: Int,
        label: String,
        expectedProjectPath: String?,
        options: [String: String] = [:],
        includeAudioTail: Bool? = nil,
        deliberatelySoloed: [String]? = nil
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
        try pressMenuItem(
            containing: LogicUIStrings.Menu.projectOrSection, underMenu: LogicUIStrings.Menu.bounce
        )
        guard let dialog = bounceDialog() else {
            throw LogicianError.windowNotFound("bounce dialog")
        }
        reportProgress("bounce dialog open", percent: 5)

        // Destinations: ensure exactly Uncompressed. Settings persist between
        // bounces, so this is usually zero presses.
        for (name, checkbox) in destinationRows(in: dialog) {
            let checked = stringAttribute(checkbox, kAXValueAttribute as String) == "1"
            let wanted = name == LogicUIStrings.Value.uncompressed
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
            _ = abortButton(of: dialog, maximumDepth: AXDepth.bounceDialogControl)
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

        guard let okButton = confirmButton(
            of: dialog, maximumDepth: AXDepth.bounceDialogControl
        ) else {
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
        // LOOK FIRST, sleep only after a miss. Measured 2026-09-01: the OK
        // press returns in ~15 ms and the FIRST Accessibility read after it
        // blocks for ~1.3 s while Logic builds the panel (the second costs
        // 5 ms) - so the panel is already up by the time that read returns,
        // and the old leading `sleep(0.08)` bought nothing. The whole loop ran
        // exactly ONE iteration; its 2 s was Logic's own work plus a pre-order
        // button search, not waiting.
        let bounceStart = Date()
        var panelRoot: AXUIElement?
        var commitButton: AXUIElement?
        let panelDeadline = Date().addingTimeInterval(8)
        while Date() < panelDeadline && panelRoot == nil {
            for window in (try? logicWindows()) ?? [] {
                // The button that IDENTIFIES the panel is the button that gets
                // pressed: finding it twice used to cost ~730 ms extra.
                if let commit = savePanelCommitButton(in: window) {
                    panelRoot = window
                    commitButton = commit
                    break
                }
            }
            if panelRoot == nil, let xpc = savePanelApplication() {
                panelRoot = xpc
                commitButton = savePanelCommitButton(in: xpc)
            }
            if panelRoot != nil { break }
            Thread.sleep(forTimeInterval: 0.08)
        }
        guard let panel = panelRoot else {
            throw LogicianError.openVerificationFailed("the save panel did not appear")
        }

        // The panel keeps its default name regardless of AXValue writes, so we
        // accept the default and move the rendered file to the label name after.
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "logicmcp-\(sanitizedFilenameComponent(label, fallback: "bounce"))-\(timestamp)"
        guard let bounceButton = commitButton ?? savePanelCommitButton(in: panel) else {
            throw LogicianError.openVerificationFailed("no Bounce button in the save panel")
        }
        guard AXUIElementPerformAction(bounceButton, kAXPressAction as CFString) == .success else {
            throw LogicianError.writeFailed("pressing Bounce failed")
        }
        // The possible "already exists" sheet is handled by the render wait
        // below, not here: see `pressReplaceSheetIfPresent`. What used to sit
        // at this point was a blind `sleep(0.25)` followed by ONE pre-order
        // `Replace` search across every Logic window - 0.67-0.84 s measured,
        // for a look taken at a single moment. Folding the look into the wait
        // that follows costs nothing (that loop is already polling) and keeps
        // looking for as long as no file has appeared, which is exactly the
        // state a sheet would hold us in.

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
        var replacePressed = false
        while Date() < renderDeadline {
            try checkCancelled()
            Thread.sleep(forTimeInterval: 0.1)
            if resultPath == nil { resultPath = findResult() }
            // No file yet is the only state an overwrite sheet can be holding
            // us in, so that is the only state worth looking in. Once bytes
            // are landing, nothing is blocked and the search stops.
            if resultPath == nil, !replacePressed, pressReplaceSheetIfPresent() {
                replacePressed = true
            }
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
        // Move the render into the captures directory under the label name,
        // making room first: nothing pruned that folder before 2026-09-02 and
        // every writer now shares one policy (`Captures.makeRoom`).
        let capturesDirectory = Captures.ensureRoot()
        let pruned = Captures.makeRoom()
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
        // ONE encode where there used to be two of the same file (~290 ms,
        // every call). The 128 kbps preview written beside the bounce is
        // already a stereo AAC; when it fits an attachment it IS the ear copy,
        // and only a preview too big to attach pays the second, smaller
        // encode - which is the only case that used to be paid at all.
        let earCopy = LogicAccessibility.earCopy(preview: bouncePreview, sourcePath: finalPath)
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
        if let pruned { result["captures_pruned"] = pruned }
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
        // A caller that soloed on purpose already knows, and asking Logic again
        // is a full rendered-header walk per bounce for an answer it discards.
        let soloed = deliberatelySoloed ?? soloedTrackNamesIfReadable()
        if let deliberatelySoloed {
            result["soloed_tracks"] = deliberatelySoloed
            result["soloed_tracks_source"] = "caller"
        } else if let soloed, !soloed.isEmpty {
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
                && stringAttribute(child, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.soloDescription {
                let value = stringAttribute(child, kAXValueAttribute as String)
                if value == "1" || value == LogicUIStrings.Value.on { names.append(header.name) }
            }
        }
        return names
    }

    /// The audio block a bounce result carries, taking the preview encode's
    /// output when it is small enough to attach and encoding a smaller one
    /// only when it is not.
    ///
    /// Both files were always the same audio through the same encoder, at
    /// 128 and 64 kbps, run back to back on every call for ~290 ms. A 4-bar
    /// bounce's preview is ~130 KB, so the second run bought nothing; a long
    /// bounce whose preview exceeds `maxBytes` still gets the 64 kbps cut,
    /// and a preview that cannot be read falls back to exactly what this did
    /// before.
    static func earCopy(
        preview: String?, sourcePath: String, maxBytes: Int = 400_000
    ) -> Data? {
        if let preview,
           let data = try? Data(contentsOf: URL(fileURLWithPath: preview)),
           !data.isEmpty, data.count <= maxBytes {
            return data
        }
        return encodeEarCopy(path: sourcePath, maxBytes: maxBytes)
    }

    /// The audio block a result carries, the length it covers, and the note
    /// that tells the agent which of those it got. `data == nil` is a real
    /// outcome here, never a silence: `note` then names the reason and the
    /// file to open instead.
    struct EarAudio {
        let data: Data?
        /// Always present. Goes into the result as `listen_note`.
        let note: String
        /// Seconds of audio the block holds; nil when there is no block.
        let coveredSeconds: Double?
        /// Seconds the SOURCE file holds, when it could be read.
        let sourceSeconds: Double?
        /// The block is a window, not the whole file.
        let windowed: Bool
    }

    /// The sound a result carries — whole when it fits, a WINDOW when it does
    /// not, and an explanation when neither works.
    ///
    /// The defect this replaces, measured 2026-09-02 on a 136.7 s freeze
    /// render of one track (6 029 645 frames at 44.1 kHz): `encodeEarCopy` encodes the whole file at 64 kbps
    /// and returns nil above `maxBytes`, so the result reached the agent with
    /// **no audio block and no `listen_note`** (2/2) while the tool
    /// description, the server instructions and the agent guide all promised
    /// the audio rides along — and the encode that produced nothing cost
    /// 933–1 004 ms, 11% of the call. Anything past ~42 s is over the cap,
    /// i.e. every normal full-track render.
    ///
    /// So the LENGTH decides first (`AudioClip.earPlan`, from the header):
    ///
    ///  - Short enough: encoded whole, and the 128 kbps preview already on
    ///    disk IS the block whenever it fits (`earCopy`) — no second encode.
    ///  - Too long: the first `AudioClip.earWindowCapSeconds` are cut through
    ///    the seek-and-decode route `logic_get_audio_clip` uses, so only the
    ///    window is ever decoded, and the note says which window it is and
    ///    how to reach the rest.
    ///  - Neither: no block, and a note naming the reason plus `preview_path`.
    static func earAudio(
        sourcePath: String, previewPath: String?, maxBytes: Int = 400_000
    ) -> EarAudio {
        let fileSeconds = AudioClip.seconds(ofFile: sourcePath)
        func trimmed(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
        }
        func noBlock(_ reason: String) -> EarAudio {
            EarAudio(
                data: nil,
                note: "NO audio block could be made for this result: \(reason). Nothing was"
                    + " heard. To listen, open preview_path with your client's FILE VIEWER, or"
                    + " call logic_get_audio_clip {path, start_seconds, duration_seconds} for a"
                    + " listenable window of the file at `path`. NEVER read audio files as"
                    + " text/bash.",
                coveredSeconds: nil, sourceSeconds: fileSeconds, windowed: false
            )
        }
        switch AudioClip.earPlan(fileSeconds: fileSeconds, maxBytes: maxBytes) {
        case .whole:
            guard let data = earCopy(
                preview: previewPath, sourcePath: sourcePath, maxBytes: maxBytes
            ) else {
                return noBlock(
                    "the AAC encode of '\(sourcePath)' produced nothing under the"
                        + " \(maxBytes / 1000) KB attachment cap"
                )
            }
            return EarAudio(
                data: data,
                note: "This result CARRIES the rendered audio as an MCP audio block - listen"
                    + " now. If no audio block reached you, open preview_path with your client's"
                    + " file viewer instead.",
                coveredSeconds: fileSeconds, sourceSeconds: fileSeconds, windowed: false
            )
        case .window(let windowSeconds):
            guard windowSeconds > 0 else {
                return noBlock("the attachment cap leaves no room for any audio")
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("logician-ear-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let clip: AudioClip.Clip
            do {
                clip = try AudioClip.write(
                    sourcePath: sourcePath, startSeconds: 0,
                    durationSeconds: windowSeconds, destination: scratch
                )
            } catch let fault as AudioClip.Fault {
                return noBlock(fault.message)
            } catch {
                return noBlock((error as NSError).localizedDescription)
            }
            guard let data = try? Data(contentsOf: scratch),
                  !data.isEmpty, data.count <= maxBytes else {
                return noBlock(
                    "the \(trimmed(clip.durationSeconds)) s window still encoded above the"
                        + " \(maxBytes / 1000) KB attachment cap"
                )
            }
            return EarAudio(
                data: data,
                note: "This result CARRIES the FIRST \(trimmed(clip.durationSeconds)) s of this"
                    + " \(trimmed(clip.sourceSeconds)) s render as an MCP audio block - listen"
                    + " now. The WHOLE file does not fit an audio block (the cap is"
                    + " \(maxBytes / 1000) KB, about"
                    + " \(trimmed(AudioClip.earWindowCapSeconds(maxBytes: maxBytes))) s at"
                    + " 64 kbps), so a window rides along instead: the complete render is on"
                    + " disk at `path` (and as an AAC copy at preview_path), and any other"
                    + " stretch of it comes back from logic_get_audio_clip {path,"
                    + " start_seconds, duration_seconds}. Do not describe what you have not"
                    + " heard - this block is the first"
                    + " \(trimmed(clip.durationSeconds)) s only.",
                coveredSeconds: clip.durationSeconds, sourceSeconds: clip.sourceSeconds,
                windowed: true
            )
        }
    }

    /// Encodes a file as a small mono AAC "ear copy" suitable for an MCP
    /// audio content block (nil when encoding fails or the result exceeds
    /// the safe attachment size). This is what lets bounce/render results
    /// CARRY their own sound instead of just naming a file.
    ///
    /// Callers that may be handed a LONG file want `earAudio` instead: this
    /// one encodes whatever it is given and only then compares the result to
    /// the cap, which is a full encode spent to return nil.
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

    /// Whether the first bytes of a render describe a FINISHED file — the
    /// container is covered AND it actually holds audio.
    ///
    /// `containerComplete` is not enough on its own, measured 2026-09-02 on
    /// the sandbox: Logic publishes the freeze `.aif` before it starts
    /// streaming samples, and that snapshot is a 4 096-byte header whose FORM
    /// size reads 504 — every declared byte present, `numSampleFrames` zero.
    /// Two renders were copied out in 3.3 s in exactly that state (against
    /// 4.3–4.9 s for a real one) and came back as 0-frame captures. So the
    /// COMM chunk's own frame count is read here too, and a header-only
    /// snapshot is what it is: NOT complete, keep waiting.
    ///
    /// nil for a container this cannot judge (not AIFF/AIFC/WAV), so callers
    /// keep whatever evidence they had before.
    static func audioRenderComplete(head: Data, fileSize: UInt64) -> Bool? {
        guard let covered = containerComplete(header: head, fileSize: fileSize) else { return nil }
        guard covered else { return false }
        let bytes = [UInt8](head)
        guard bytes.count >= 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "FORM" else {
            // WAV: the container check is all this knows how to do.
            return covered
        }
        func beUInt32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(beUInt32(offset + 4))
            if chunkID == "COMM" {
                // numSampleFrames is the 4 bytes after the 2-byte channel
                // count; a partial header that does not reach it is not
                // evidence of anything.
                guard offset + 14 <= bytes.count else { return false }
                return beUInt32(offset + 10) > 0
            }
            offset += 8 + size + (size % 2)
        }
        // FORM says the file is whole but no COMM chunk was found in the head
        // that was read: judge nothing rather than pass it.
        return nil
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
        expectedProjectPath: String?,
        includeAudio: Bool
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
        evalResult = MCUController.attachABAudio(
            to: evalResult, baselinePath: pathA, afterPath: pathB, includeAudio: includeAudio
        )
        return evalResult
    }

}
