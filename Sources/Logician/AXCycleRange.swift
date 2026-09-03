import AppKit
import ApplicationServices
import Foundation

// MARK: - The cycle range, written as numbers

extension LogicAccessibility {

    /// The cycle's two locator cells in the control bar LCD, resolved.
    struct CycleLocatorCells {
        let left: AXUIElement
        let right: AXUIElement
    }

    /// What one locator cell holds, and the text Logic renders it as.
    struct LocatorReading {
        let bar: Int
        let beat: Int
        let division: Int
        let tick: Int
        let text: String

        /// A locator exactly on a bar line — which is the only kind of range
        /// this tool sets, and therefore what its verification demands.
        var isOnBarLine: Bool { beat == 1 && division == 1 && tick == 1 }
    }

    /// The locator cells, plus the display mode that has to be put back.
    struct LocatorDisplay {
        let cells: CycleLocatorCells
        let modeFound: String
        /// nil when the LCD already showed the cells and nothing was switched.
        let modeToRestore: String?
    }

    /// The LCD's Display Mode pop-up, or nil when the control bar does not
    /// publish one (a collapsed or very narrow window).
    func displayModePopUp(in controlBar: AXUIElement) -> AXUIElement? {
        if let inner = controlBarChild(controlBar, LogicUIStrings.Element.controlBar),
           let popUp = controlBarChild(inner, LogicUIStrings.Element.displayModePopUp) {
            return popUp
        }
        return controlBarChild(controlBar, LogicUIStrings.Element.displayModePopUp)
    }

    /// Every numeric LCD cell the control bar is publishing right now, with
    /// its frame — the raw material `LocatorCells.pairs` turns into locator
    /// pairs.
    ///
    /// A cell is recognised by SHAPE and DIGITS, never by a translated word:
    /// an `AXGroup` whose description is its own value (`"0005  1  1  001"`)
    /// carrying a bar slider. The position display sitting beside it is
    /// described in words and is never picked up.
    func locatorCellCandidates(in controlBar: AXUIElement) -> [(cell: AXUIElement, frame: CGRect)] {
        let inner = controlBarChild(controlBar, LogicUIStrings.Element.controlBar) ?? controlBar
        return children(of: inner).compactMap { child in
            let description = stringAttribute(child, kAXDescriptionAttribute as String)
            guard LocatorCells.isCellDescription(description),
                  children(of: child).contains(where: {
                      stringAttribute($0, kAXDescriptionAttribute as String)
                          == LogicUIStrings.Element.playheadBarSlider
                  }),
                  let frame = try? frame(of: child) else { return nil }
            return (child, frame)
        }
    }

    /// The cycle's locator pair among whatever the LCD is showing, or nil when
    /// there is none — and `ambiguous` when there is more than one pair and
    /// the ruler cannot say which is the cycle's.
    func cycleLocatorCells(
        in controlBar: AXUIElement, regionLengthBars: Int?
    ) -> (cells: CycleLocatorCells?, candidatePairs: Int) {
        let candidates = locatorCellCandidates(in: controlBar)
        let pairs = LocatorCells.pairs(frames: candidates.map { $0.frame })
        guard !pairs.isEmpty else { return (nil, 0) }
        let spans: [Int] = pairs.map { pair in
            let top = LocatorCells.bar(
                inCellDescription: stringAttribute(candidates[pair.top].cell, kAXDescriptionAttribute as String)
            ) ?? 0
            let bottom = LocatorCells.bar(
                inCellDescription: stringAttribute(candidates[pair.bottom].cell, kAXDescriptionAttribute as String)
            ) ?? 0
            return bottom - top
        }
        guard let chosen = LocatorCells.cyclePair(spans: spans, regionLengthBars: regionLengthBars) else {
            return (nil, pairs.count)
        }
        return (
            CycleLocatorCells(
                left: candidates[pairs[chosen].top].cell,
                right: candidates[pairs[chosen].bottom].cell
            ),
            pairs.count
        )
    }

    /// Shows the cycle locators in the LCD, switching its display mode only
    /// when they are not there already.
    ///
    /// A user whose LCD already shows them pays nothing — and needs no
    /// English, since the cells are recognised by their digits. Switching is
    /// the fallback, and it is undone by the caller.
    func showLocatorCells(in controlBar: AXUIElement, regionLengthBars: Int?) throws -> LocatorDisplay {
        let popUp = displayModePopUp(in: controlBar)
        let modeFound = popUp.map { stringAttribute($0, kAXValueAttribute as String) } ?? "unreadable"
        let found = cycleLocatorCells(in: controlBar, regionLengthBars: regionLengthBars)
        if let cells = found.cells {
            return LocatorDisplay(cells: cells, modeFound: modeFound, modeToRestore: nil)
        }
        if found.candidatePairs > 1 {
            throw LogicianError.preconditionUnmet(
                LocatorCells.ambiguousPairsRefusal(count: found.candidatePairs)
            )
        }
        guard let popUp, modeFound != LogicUIStrings.Element.customDisplayMode else {
            throw LogicianError.preconditionUnmet(
                LocatorCells.noCellsRefusal(displayMode: modeFound, triedSwitch: false)
            )
        }
        try selectDisplayMode(popUp, title: LogicUIStrings.Element.customDisplayMode)
        // The LCD rebuilds its children AFTER the pop-up's value changes —
        // measured 2026-09-03: the value lands 165 ms after the item press and
        // the cells appear ~7 ms later. Look first, then poll.
        var appeared: CycleLocatorCells?
        var pairsSeen = 0
        let deadline = Date().addingTimeInterval(1.0)
        while appeared == nil {
            let now = cycleLocatorCells(in: controlBar, regionLengthBars: regionLengthBars)
            appeared = now.cells
            pairsSeen = now.candidatePairs
            if appeared != nil || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let cells = appeared else {
            _ = restoreDisplayMode(popUp, to: modeFound, controlBar: controlBar)
            throw LogicianError.preconditionUnmet(
                pairsSeen > 1
                    ? LocatorCells.ambiguousPairsRefusal(count: pairsSeen)
                    : LocatorCells.noCellsRefusal(displayMode: modeFound, triedSwitch: true)
            )
        }
        return LocatorDisplay(cells: cells, modeFound: modeFound, modeToRestore: modeFound)
    }

    /// Picks one item out of the LCD's Display Mode pop-up, and proves the
    /// pop-up took it.
    ///
    /// An open menu swallows Logic's keyboard, so every path out of here
    /// closes it — including the one where the item is not in the list at all.
    func selectDisplayMode(_ popUp: AXUIElement, title: String) throws {
        guard AXUIElementPerformAction(popUp, kAXPressAction as CFString) == .success else {
            throw LogicianError.writeFailed("the LCD's Display Mode pop-up would not open")
        }
        var menus: [AXUIElement] = []
        let menuDeadline = Date().addingTimeInterval(1.0)
        while menus.isEmpty {
            menus = children(of: popUp)
            if !menus.isEmpty || Date() >= menuDeadline { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer {
            // Cancel whatever is still open. A menu that already took a press
            // is gone and answers this harmlessly.
            for menu in children(of: popUp) {
                _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
        }
        guard let item = menus.flatMap({ children(of: $0) }).first(where: {
            stringAttribute($0, kAXTitleAttribute as String) == title
        }) else {
            throw LogicianError.preconditionUnmet(
                "the LCD's Display Mode pop-up has no '\(title)' entry (it lists "
                    + menus.flatMap { children(of: $0) }
                        .map { stringAttribute($0, kAXTitleAttribute as String) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    + "), so the cycle locators cannot be shown from here"
            )
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw LogicianError.writeFailed("the LCD's Display Mode pop-up would not take '\(title)'")
        }
        let deadline = Date().addingTimeInterval(1.5)
        while stringAttribute(popUp, kAXValueAttribute as String) != title {
            guard Date() < deadline else {
                throw LogicianError.verificationFailed(
                    requested: "LCD display mode '\(title)'",
                    actual: "'\(stringAttribute(popUp, kAXValueAttribute as String))'",
                    restored: nil
                )
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Puts the LCD's display mode back, and says whether it went.
    ///
    /// The pop-up's value is not the whole readback: Logic rebuilds the LCD's
    /// children AFTER the value flips, and until it has, the display is still
    /// publishing the cells of the mode that just left — measured 2026-09-03,
    /// where the next call in the same second wrote into those leftovers and a
    /// `logic_get_transport` fired at the same moment reported a null key
    /// signature from a half-built control bar. So the restore is not finished
    /// until the cells this call revealed are gone.
    func restoreDisplayMode(_ popUp: AXUIElement, to mode: String, controlBar: AXUIElement) -> Bool {
        if stringAttribute(popUp, kAXValueAttribute as String) != mode {
            // Twice, not once: the first press can land while Logic is still
            // rebuilding the LCD from the switch that got us here.
            for _ in 0..<2 {
                try? selectDisplayMode(popUp, title: mode)
                if stringAttribute(popUp, kAXValueAttribute as String) == mode { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard stringAttribute(popUp, kAXValueAttribute as String) == mode else { return false }
        let deadline = Date().addingTimeInterval(1.0)
        while !locatorCellCandidates(in: controlBar).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// What a locator cell holds right now.
    func locatorReading(_ cell: AXUIElement) -> LocatorReading? {
        let fields = describedChildren(of: cell)
        func value(_ description: String) -> Int? {
            fields[description].flatMap { Int(stringAttribute($0, kAXValueAttribute as String)) }
        }
        guard let bar = value(LogicUIStrings.Element.playheadBarSlider) else { return nil }
        return LocatorReading(
            bar: bar,
            beat: value(LogicUIStrings.Element.playheadBeatSlider) ?? 1,
            division: value(LogicUIStrings.Element.lcdDivisionSlider) ?? 1,
            tick: value(LogicUIStrings.Element.lcdTickSlider) ?? 1,
            text: stringAttribute(cell, kAXDescriptionAttribute as String)
        )
    }

    /// Writes one locator to a bar LINE: the bar itself, and the sub-bar cells
    /// to 1 so the locator sits exactly on it. Each cell is stepped by the
    /// same one-step-per-write engine the playhead LCD uses, and each is left
    /// alone when it already reads what it should.
    func writeLocator(_ cell: AXUIElement, toBar bar: Int, label: String) throws {
        do {
            try convergeLCDCell(
                in: cell, sliderName: LogicUIStrings.Element.playheadBarSlider, target: bar, label: label
            )
        } catch let error as LogicianError {
            // A bar the locator will not climb to is a REACHABILITY refusal,
            // not a failed write, and it names the bar it stopped on. Measured
            // 2026-09-03: asking for bars 70-74 on a 64-bar project stopped the
            // right locator at 64, exactly where the playhead's own slider
            // clamps. Only the stuck verdict is translated — a missing slider
            // or a rejected write keeps its own error.
            guard case .verificationFailed = error else { throw error }
            let reached = locatorReading(cell)?.bar
            throw LogicianError.trackNotExposed(
                requested: "bar \(bar) for the \(label)",
                exposed: "the \(label) stopped at bar \(reached.map(String.init) ?? "?") and would go "
                    + "no further — that is where Logic clamps a locator at the end of the project. "
                    + "Ask for a range inside the project, or lengthen the project first"
            )
        }
        for name in [
            LogicUIStrings.Element.playheadBeatSlider,
            LogicUIStrings.Element.lcdDivisionSlider,
            LogicUIStrings.Element.lcdTickSlider
        ] {
            guard describedChildren(of: cell)[name] != nil else { continue }
            try convergeLCDCell(in: cell, sliderName: name, target: 1, label: label)
        }
    }

    /// Puts one locator back exactly as it was found, sub-bar digits included.
    func restoreLocator(_ cell: AXUIElement, to reading: LocatorReading, label: String) {
        try? convergeLCDCell(in: cell, sliderName: LogicUIStrings.Element.playheadBarSlider, target: reading.bar, label: label)
        for (name, target) in [
            (LogicUIStrings.Element.playheadBeatSlider, reading.beat),
            (LogicUIStrings.Element.lcdDivisionSlider, reading.division),
            (LogicUIStrings.Element.lcdTickSlider, reading.tick)
        ] {
            guard describedChildren(of: cell)[name] != nil else { continue }
            try? convergeLCDCell(in: cell, sliderName: name, target: target, label: label)
        }
    }

    /// The ruler's cycle region as a second witness: how many bars it spans,
    /// and roughly which bar it starts on.
    ///
    /// The span is EXACT (Logic denominates it in bars itself). The start bar
    /// is an ESTIMATE and is reported as one — it comes from the ruler's
    /// average pixels-per-bar, which a meter change bends by up to about a
    /// bar over a long extrapolation, plus the constant few pixels Logic
    /// insets the region's frame by. It is here to catch a GROSS
    /// disagreement between the numbers Logic shows in the LCD and the range
    /// it draws in the ruler, not to judge a landing: the locator cells are
    /// the exact witness and they are checked exactly.
    func cycleRegionWitness() -> (lengthBars: Int?, startBarEstimate: Int?, unavailable: String?) {
        guard let ruler = try? rulerArea() else {
            return (nil, nil, "the Tracks time ruler is not published")
        }
        guard let region = rulerChild(ruler, LogicUIStrings.Element.cycleRegion) else {
            return (nil, nil, "the ruler publishes no cycle region")
        }
        let length = cycleLengthBars(region)
        guard let marker = rulerChild(ruler, LogicUIStrings.Element.startMarker),
              let markerBar = leadingInt(stringAttribute(marker, kAXValueDescriptionAttribute as String)),
              let regionX = (try? frame(of: region))?.origin.x,
              let markerX = (try? frame(of: marker))?.origin.x,
              let slope = try? pixelsPerBar(in: ruler) else {
            return (length, nil, length == nil ? "the cycle region publishes no bar count" : nil)
        }
        return (
            length,
            RulerBarMapping.barAt(
                offset: regionX - markerX, anchorOffset: 0, anchorBar: markerBar, pixelsPerBar: slope
            ),
            nil
        )
    }

    /// How far the ruler's drawing may disagree with the LCD's numbers before
    /// the write is treated as unverified. Three bars, because the estimate it
    /// judges is an average-slope one: measured 2026-09-03, extrapolating
    /// across the sandbox's 4/4 → 5/4 meter change is worth up to ~1 bar, and
    /// the region's frame inset another ~0.6. A real failure is not off by
    /// three bars, it is off by the whole distance between two ranges.
    static let rulerWitnessToleranceBars = 3

    /// Sets the cycle (locator) range to a whole-bar span — with no mouse.
    ///
    /// **The route.** Both locators are written as NUMBERS, into the control
    /// bar LCD's own locator cells, one step per `AXValue` write on the same
    /// engine the playhead display uses. MEASURED 2026-09-03 (Logic Pro
    /// 12.3.1, sandbox project): 0.1–1.6 ms per step, 6.6–8.1 ms for both
    /// locators of a 15-bar move, and the ruler's cycle region follows
    /// exactly.
    ///
    /// **What this replaces, and why.** Until this change a range whose
    /// LENGTH changed was written by dragging the ruler with synthetic mouse
    /// events (`cg_drag_create`). That route moved the user's pointer, turned
    /// Cycle mode on by itself, scrolled the ruler out from under the next
    /// call, needed the target range to be VISIBLE, and needed the playhead —
    /// borrowed, parked on up to five candidate bars to work out which bar
    /// the region sat on, and put back afterwards. On 2026-09-03 it also did
    /// not work at all: three consecutive length-change calls refused with
    /// *"hit test at the cycle strip of the ruler resolved to AXTable ''"*,
    /// because a drag aims at screen coordinates and cannot see what the
    /// window stack has done to them. Numbers have none of those failure
    /// modes: nothing needs to be visible, nothing is borrowed, nothing moves
    /// that was not asked to move.
    ///
    /// **The honesty this owes the caller**, kept from the drag-era tool:
    ///
    /// - a write that fails verification is put BACK to the range this call
    ///   read first — by the same route — and says `Restored: true`, or names
    ///   where it is left;
    /// - `cycle_enabled_before` and `cycle_enabled` are both reported, and a
    ///   Cycle state nobody asked to change is put back (the LCD route does
    ///   not touch it — measured — but the net stays);
    /// - the ruler's own drawing is read back as a SECOND witness, and when
    ///   it cannot be read the result says so rather than dropping the key.
    func setCycleRange(startBar: Int, endBar: Int, enabled: Bool?) throws -> [String: Any] {
        guard startBar >= 1, endBar > startBar else {
            throw LogicianError.invalidArguments("start_bar must be >= 1 and end_bar > start_bar")
        }
        let targetLength = endBar - startBar
        let controlBar = try controlBarGroup()
        // Read BEFORE anything is written, on every path — including the ones
        // that never pass `enabled` — because that is the only moment the
        // pre-call Cycle state still exists.
        let cycleEnabledBefore = cycleButtonState()
        let witnessBefore = cycleRegionWitness()

        let display = try showLocatorCells(
            in: controlBar, regionLengthBars: witnessBefore.lengthBars
        )
        var displayRestored = true
        var displayPutBack = false
        func putDisplayBack() {
            guard !displayPutBack, let mode = display.modeToRestore else { return }
            displayPutBack = true
            let freshBar = (try? controlBarGroup()) ?? controlBar
            guard let popUp = displayModePopUp(in: freshBar) else {
                displayRestored = false
                return
            }
            displayRestored = restoreDisplayMode(popUp, to: mode, controlBar: freshBar)
        }
        /// The sentence a refusal ends with when the LCD was switched to reach
        /// the locators and could not be switched back — the one piece of
        /// state a failed call could otherwise leave behind silently.
        func displaySentence() -> String {
            guard let mode = display.modeToRestore, !displayRestored else { return "" }
            return " The control bar's LCD was switched to "
                + "'\(LogicUIStrings.Element.customDisplayMode)' to reach the locator cells and could "
                + "NOT be switched back to '\(mode)'; set it from the small arrow at the right of the LCD."
        }
        defer { putDisplayBack() }

        guard let leftBefore = locatorReading(display.cells.left),
              let rightBefore = locatorReading(display.cells.right) else {
            throw LogicianError.windowNotFound("the control bar LCD's cycle locator cells")
        }
        let originalRangeText = LocatorCells.rangeText(
            startBar: leftBefore.bar, endBar: rightBefore.bar
        )
        let alreadySet = leftBefore.bar == startBar && rightBefore.bar == endBar
            && leftBefore.isOnBarLine && rightBefore.isOnBarLine

        /// Puts both locators back where this call found them, and says
        /// whether that worked.
        func restoreRange() -> (restored: Bool, leftAt: String) {
            restoreLocator(display.cells.left, to: leftBefore, label: "left locator")
            restoreLocator(display.cells.right, to: rightBefore, label: "right locator")
            let left = locatorReading(display.cells.left)
            let right = locatorReading(display.cells.right)
            let back = left?.bar == leftBefore.bar && right?.bar == rightBefore.bar
                && left?.beat == leftBefore.beat && right?.beat == rightBefore.beat
            return (
                back,
                back
                    ? originalRangeText
                    : LocatorCells.rangeText(left: left?.text ?? "unreadable", right: right?.text ?? "unreadable")
            )
        }
        /// Folds the restore into the error, so a refusal never doubles as a
        /// half-finished write.
        func abandoning(_ error: Error) -> Error {
            let outcome = restoreRange()
            if let before = cycleEnabledBefore, cycleButtonState() != before {
                _ = try? MCUController.setCycle(before) ?? setCycle(enabled: before)
            }
            // Before the sentence is written, not in the `defer` afterwards:
            // a refusal has to be able to SAY whether the display went back.
            putDisplayBack()
            let sentence = RulerBarMapping.restoreSentence(
                restored: outcome.restored, original: originalRangeText, leftAt: outcome.leftAt
            ) + displaySentence()
            switch error as? LogicianError {
            case .verificationFailed(let requested, let actual, _):
                return LogicianError.verificationFailed(
                    requested: requested,
                    actual: outcome.restored ? actual : "\(actual); \(sentence)",
                    restored: outcome.restored
                )
            case .stateVerificationFailed(let subject, let detail):
                return LogicianError.stateVerificationFailed(subject: subject, detail: "\(detail) \(sentence)")
            case .writeFailed(let detail):
                return LogicianError.writeFailed("\(detail). \(sentence)")
            case .trackNotExposed(let requested, let exposed):
                return LogicianError.trackNotExposed(requested: requested, exposed: "\(exposed). \(sentence)")
            default:
                return error
            }
        }

        var witnessAfter = witnessBefore
        do {
            if !alreadySet {
                // Never invert the pair, not even between the two legs: an
                // inverted pair is Logic's SKIP cycle, a different feature.
                switch LocatorCells.writeOrder(currentRight: rightBefore.bar, startBar: startBar) {
                case .left:
                    try writeLocator(display.cells.left, toBar: startBar, label: "left locator")
                    try writeLocator(display.cells.right, toBar: endBar, label: "right locator")
                case .right:
                    try writeLocator(display.cells.right, toBar: endBar, label: "right locator")
                    try writeLocator(display.cells.left, toBar: startBar, label: "left locator")
                }
            }

            guard let leftAfter = locatorReading(display.cells.left),
                  let rightAfter = locatorReading(display.cells.right) else {
                throw LogicianError.verificationFailed(
                    requested: LocatorCells.rangeText(startBar: startBar, endBar: endBar),
                    actual: "the locator cells could not be re-read",
                    restored: false
                )
            }
            guard leftAfter.bar == startBar, rightAfter.bar == endBar,
                  leftAfter.isOnBarLine, rightAfter.isOnBarLine else {
                throw LogicianError.verificationFailed(
                    requested: "cycle \(LocatorCells.rangeText(startBar: startBar, endBar: endBar)) "
                        + "(\(targetLength) bars)",
                    actual: "the locators read '\(leftAfter.text)' and '\(rightAfter.text)'",
                    restored: false
                )
            }
            witnessAfter = cycleRegionWitness()
            if let rulerLength = witnessAfter.lengthBars, rulerLength != targetLength {
                throw LogicianError.verificationFailed(
                    requested: "cycle \(LocatorCells.rangeText(startBar: startBar, endBar: endBar)) "
                        + "(\(targetLength) bars)",
                    actual: "the LCD's locators read \(startBar) and \(endBar) but the ruler draws a "
                        + "\(rulerLength)-bar cycle region",
                    restored: false
                )
            }
            if let estimate = witnessAfter.startBarEstimate,
               abs(estimate - startBar) > LogicAccessibility.rulerWitnessToleranceBars {
                throw LogicianError.verificationFailed(
                    requested: "cycle \(LocatorCells.rangeText(startBar: startBar, endBar: endBar))",
                    actual: "the LCD's locators read \(startBar) and \(endBar) but the ruler draws the "
                        + "cycle region around bar \(estimate)",
                    restored: false
                )
            }
        } catch {
            throw abandoning(error)
        }

        var cycleWarning: String?
        if let enabled = enabled {
            _ = try MCUController.setCycle(enabled) ?? setCycle(enabled: enabled)
        } else if let before = cycleEnabledBefore, cycleButtonState() != before {
            // Measured 2026-09-03: the LCD route does NOT change Cycle mode
            // (the ruler drag it replaced did, every time). The net stays
            // because a state nobody asked to change must never be left
            // changed, whatever Logic does next.
            _ = try? MCUController.setCycle(before) ?? setCycle(enabled: before)
            if cycleButtonState() != before {
                cycleWarning = "Setting the range switched Cycle mode "
                    + (before ? "off" : "on") + ", which this call never asked for, and it could "
                    + "NOT be put back. Set it explicitly with logic_set_cycle {enabled: \(before)}."
            }
        }
        let finalCycle = cycleButtonState()
        putDisplayBack()

        var rulerWitness: [String: Any] = [:]
        if let length = witnessAfter.lengthBars { rulerWitness["length_bars"] = length }
        if let estimate = witnessAfter.startBarEstimate { rulerWitness["start_bar_estimate"] = estimate }
        if let unavailable = witnessAfter.unavailable { rulerWitness["unavailable"] = unavailable }
        if rulerWitness.isEmpty { rulerWitness["unavailable"] = "the ruler published no readable cycle region" }

        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": alreadySet ? "already_set" : "cycle_range_set",
            "start_bar": startBar,
            "end_bar": endBar,
            "length_bars": targetLength,
            "previous": [
                "start_bar": leftBefore.bar,
                "end_bar": rightBefore.bar,
                "length_bars": rightBefore.bar - leftBefore.bar
            ],
            "write_route": "lcd_locator_cells",
            "ruler_witness": rulerWitness,
            "cycle_enabled_before": cycleEnabledBefore ?? NSNull(),
            "cycle_enabled": finalCycle ?? NSNull(),
            "verification": LocatorCells.verificationSentence(
                startBar: startBar, endBar: endBar, rulerLength: witnessAfter.lengthBars
            )
        ]
        if let restoreMode = display.modeToRestore {
            result["display_mode"] = [
                "found": display.modeFound,
                "switched_to": LogicUIStrings.Element.customDisplayMode,
                "restored": displayRestored
            ]
            if !displayRestored {
                cycleWarning = (cycleWarning.map { $0 + " " } ?? "")
                    + "The control bar's LCD was switched to "
                    + "'\(LogicUIStrings.Element.customDisplayMode)' to reach the locator cells and "
                    + "could NOT be switched back to '\(restoreMode)'. Set it from the small arrow at "
                    + "the right of the LCD."
            }
        }
        if let cycleWarning { result["warning"] = cycleWarning }
        return result
    }
}
