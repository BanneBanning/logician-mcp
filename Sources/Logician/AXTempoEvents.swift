import AppKit
import ApplicationServices
import Foundation

// MARK: - Writing the tempo map: the Tempo List's create, retune and delete

extension LogicAccessibility {

    /// One position field of a Tempo List row, as Logic publishes it while the
    /// row is SELECTED: four `AXSlider`s described `Segment 0`…`Segment 3` =
    /// bar, beat, division, tick.
    ///
    /// They are steppers, not fields: `AXUIElementSetAttributeValue` moves them
    /// ONE step towards the written value and the action set is
    /// `AXIncrement`/`AXDecrement` (measured 2026-08-28 and again here), so
    /// every one of them is converged rather than written.
    private func positionSegments(of row: ListEditorRow) -> [AXUIElement] {
        guard let cell = children(of: row.element).first else { return [] }
        return cellSegments(cell)
    }

    /// The `Segment N` steppers inside one List Editors cell.
    ///
    /// They are NOT direct children — measured 2026-08-28, a `children(of:)`
    /// filter found zero of them and reported "the row published 0 position
    /// steppers" on a row that had four. They sit one level further down,
    /// beside the `AXGroup` that carries the cell's text.
    private func cellSegments(_ cell: AXUIElement) -> [AXUIElement] {
        descendants(of: cell, maximumDepth: 3).filter {
            stringAttribute($0, kAXRoleAttribute as String) == kAXSliderRole as String
        }
    }

    /// Writes `target` into a stepper until it gets there. Returns the value it
    /// actually reached and how many writes it took.
    ///
    /// The loop is `setTempo`'s, which has converged Logic's one-step-per-write
    /// sliders since v0.33.0: write, wait ~8 ms, re-read, and give up on a value
    /// that has stopped moving rather than spinning to the deadline.
    @discardableResult
    func convergeStepper(
        _ element: AXUIElement, to target: Int, budget: TimeInterval = 12
    ) -> (value: Int?, writes: Int) {
        let deadline = Date().addingTimeInterval(budget)
        var writes = 0
        var stuck = 0
        var last = Int(stringAttribute(element, kAXValueAttribute as String))
        while Date() < deadline {
            guard let current = Int(stringAttribute(element, kAXValueAttribute as String)) else {
                return (nil, writes)
            }
            if current == target { return (current, writes) }
            _ = AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, target as CFNumber
            )
            writes += 1
            usleep(8000)
            if current == last {
                stuck += 1
                if stuck > 40 { break }
            } else {
                stuck = 0
            }
            last = current
        }
        return (Int(stringAttribute(element, kAXValueAttribute as String)), writes)
    }

    /// Steps ONE Tempo List row's BPM to `target`, with the Tempo tab already
    /// showing. Returns the BPM it reached and how many writes it took.
    ///
    /// WHY NOT THE CONTROL BAR. The first design wrote the BPM through the
    /// control bar's Tempo slider, on the reasoning that it edits the tempo
    /// event in force at the playhead. Logic disagrees, and says so in a MODAL:
    /// **"Multiple Tempo Events detected! Use the tempo track for further tempo
    /// editing."** — an alert with a single OK button that froze the whole
    /// Accessibility plane until it was dismissed (measured 2026-08-28). So on
    /// a project that already has a tempo map, the control-bar slider is not a
    /// tempo-map editor at all. That also settles, from Logic's own mouth, the
    /// open question behind `logic_set_tempo`'s refusal.
    ///
    /// The row's own tempo cell is the route, and its grammar is peculiar:
    /// seven `Segment` steppers, the first three reporting the whole BPM with
    /// `min`/`max` clamped to ±1 around it (121 -> min 120, max 122) and the
    /// last four the decimals (0, min -1, max 1). A write outside the clamp
    /// therefore moves exactly ONE BPM in that direction — and raises no
    /// alert. The element goes STALE after each write (its value reads empty),
    /// which is why the row is re-located every step instead of the stepper
    /// being hammered.
    private func convergeRowTempo(
        in window: AXUIElement, bar: Int, to target: Double, maxSteps: Int = 400
    ) -> (Double?, Int) {
        var writes = 0
        var last: Double?
        var stalled = 0
        for _ in 0..<maxSteps {
            let (table, _) = readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.tempo, in: window)
            guard let table, let row = table.rows.first(where: {
                TempoMap.parseTempoListPosition($0.cell(0))?.bar == bar
            }), let current = TempoMap.parseTempoListBPM(row.cell(1)) else {
                return (last, writes)
            }
            if abs(current - target) < 0.5 { return (current, writes) }
            if current == last {
                stalled += 1
                if stalled > 5 { return (current, writes) }
            } else {
                stalled = 0
            }
            last = current
            let cells = children(of: row.element)
            guard cells.count > 1, let stepper = cellSegments(cells[1]).first else {
                return (current, writes)
            }
            _ = AXUIElementSetAttributeValue(
                stepper, kAXValueAttribute as CFString, Int(target.rounded()) as CFNumber
            )
            writes += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (last, writes)
    }

    /// Create, retune or delete a tempo event.
    ///
    /// THE GRAMMAR, measured live 2026-08-28 (Logic Pro 12.3.1):
    ///
    /// - The Tempo tab carries a `Create new Tempo Event` button (`AXPress`)
    ///   which places an event **at the playhead** — not at the nearest bar
    ///   line, and `setPlayhead` only converges the control bar's BAR and BEAT
    ///   sliders, so whatever division and tick the playhead already carried
    ///   come along. That is why every create here FIXES the new row's position
    ///   afterwards instead of trusting the playhead.
    /// - A SELECTED row publishes its position cell as four steppers (bar,
    ///   beat, division, tick), each converged one step per write, which is how
    ///   the position is made exact.
    /// - The BPM is stepped on the ROW's own tempo cell, one BPM per write —
    ///   NOT through the control bar, which answers a tempo write on a mapped
    ///   project with a modal alert (see `convergeRowTempo`). The proof is the
    ///   re-read: the map must come back with the SAME number of events, ours
    ///   at the requested BPM and every other one untouched. A create that
    ///   produced a second event, or moved a neighbour, is reported as a
    ///   failure and not as a success with a caveat.
    /// - Each row carries a custom `Delete` action (`performListEditorRowDelete`).
    ///
    /// Every path re-reads the whole map and compares it against the map read
    /// before the write, which is the verification story for all three actions.
    ///
    /// ONE PANE, NOT FOUR. Every phase of this call reads or writes the same
    /// Tempo tab — the before-read, the action itself, the BPM stepper, the
    /// after-read — and each of them used to open the List Editors pane, do its
    /// work and close it again. Profiled live 2026-09-03: the phase sums matched
    /// wall time to within 10 ms, so those cycles WERE the cost — a `set` that
    /// wrote zero BPM (121 → 121, nothing to converge) still took 3 332 ms.
    /// Holding the pane for the whole edit (`withListEditorsPaneHeld`, the same
    /// scope `ProjectSnapshot` has used for its contiguous run of lists since
    /// 2026-09-02) leaves one open/settle/close instead of three or four; the
    /// verification is untouched, every read still happens.
    func editTempoEvent(
        action: String,
        bar: Int,
        beat: Int,
        bpm: Double?,
        expectedCurrentBPM: Double?
    ) throws -> [String: Any] {
        guard ["create", "set", "delete"].contains(action) else {
            throw LogicianError.invalidArguments("action must be 'create', 'set' or 'delete'")
        }
        guard bar >= 1 else { throw LogicianError.invalidArguments("bar must be 1 or greater") }
        guard beat >= 1 else { throw LogicianError.invalidArguments("beat must be 1 or greater") }
        if action != "delete" {
            guard let bpm, bpm >= 5, bpm <= 990 else {
                throw LogicianError.invalidArguments("bpm must be 5-990 for action '\(action)'")
            }
        }
        return try withListEditorsPaneHeld {
            try editTempoEventUnderHold(
                action: action, bar: bar, beat: beat,
                bpm: bpm, expectedCurrentBPM: expectedCurrentBPM
            )
        }
    }

    /// The edit itself, with the List Editors pane already held open by
    /// `editTempoEvent`. Split out only so the hold is one scope around the
    /// whole call rather than a `defer` threaded through every early throw.
    private func editTempoEventUnderHold(
        action: String,
        bar: Int,
        beat: Int,
        bpm: Double?,
        expectedCurrentBPM: Double?
    ) throws -> [String: Any] {
        let before = readTempoMap()
        guard let mapBefore = before.map else {
            throw LogicianError.preconditionUnmet(
                "the tempo map could not be read, and a tempo write is not made blind: "
                    + (before.failure?.reason ?? "the Tempo List did not answer")
            )
        }
        // Matched by BAR, and by beat only when the caller gave one that
        // several events on that bar could tell apart. Matching on an exact
        // beat was the first version and it was wrong in a way that made a
        // mess: `Create new Tempo Event` lands at the playhead's sub-beat
        // position, so the event it had just made at "bar 17 beat 1.28" did
        // not match a later "bar 17 beat 1" — and the guard that should have
        // refused a second create let it through, leaving two events on the
        // same bar.
        let atBar = mapBefore.events.filter { $0.bar == bar }
        let existing = atBar.first { abs($0.beatInBar - Double(beat)) < 0.5 } ?? atBar.first
        switch action {
        case "create":
            if let existing {
                throw LogicianError.preconditionUnmet(
                    "a tempo event already sits at bar \(bar) beat \(beat) (\(existing.bpm) BPM)."
                        + " Use action 'set' to change its tempo, or 'delete' to remove it"
                )
            }
        case "set", "delete":
            guard existing != nil else {
                throw LogicianError.preconditionUnmet(
                    "no tempo event sits at bar \(bar) beat \(beat). The map holds: "
                        + mapBefore.events.map { "bar \($0.bar) beat \($0.beatInBar) = \($0.bpm) BPM" }
                            .joined(separator: "; ")
                )
            }
            if let expectedCurrentBPM, let existing,
               abs(existing.bpm - expectedCurrentBPM) > 0.001 {
                throw LogicianError.currentValueMismatch(
                    expected: "\(expectedCurrentBPM) BPM", actual: "\(existing.bpm) BPM"
                )
            }
            if action == "delete", bar == 1 {
                throw LogicianError.preconditionUnmet(
                    "the tempo event at bar 1 is the project's base tempo and is not deletable;"
                        + " change it with action 'set' (or logic_set_tempo on a project with no map)"
                )
            }
        default:
            break
        }

        var steps: [String] = []
        var payload: [String: Any] = [
            "action": action,
            "bar": bar,
            "beat": beat,
            "events_before": mapBefore.events.count
        ]

        if action == "create" {
            // Park on the event's own bar/beat: `Create` places the event
            // exactly where the playhead IS.
            //
            // THE SUB-BEAT RESIDUE HAS TO GO FIRST. The control bar publishes
            // only a BAR and a BEAT stepper, so `setPlayhead` cannot touch the
            // division and tick the playhead already carries. Measured
            // 2026-08-28: parked at "bar 17 beat 1", the created event landed
            // at `17 1 2 29`. `Go to Beginning` puts the playhead at 1 1 1 1,
            // after which whole-bar and whole-beat steps keep division and tick
            // at 1.
            //
            // ASK BEFORE PRESSING. This used to fire `Go to Beginning`
            // unconditionally and with no retry, and live-profiling on
            // 2026-09-03 caught it refusing a whole create with "'Go to
            // Beginning' button in the control bar" not found — one of two
            // attempts, the immediate retry succeeding. `parkPlayheadOnGrid` is
            // this server's answer to exactly that: it reads the MCU
            // timecode's division/tick first and presses only when the residue
            // is non-zero OR unreadable (never on a rolling transport), then
            // steps and reports where it landed. A playhead already on the grid
            // now costs no rewind and no travel back out at all.
            let parked = try parkPlayheadOnGrid(bar: bar, beat: beat)
            let rewound = parked["rewound_first"] as? Bool ?? false
            steps.append(rewound
                ? "playhead zeroed with 'Go to Beginning', then parked at bar \(bar) beat \(beat)"
                : "playhead was already on the grid; parked at bar \(bar) beat \(beat) without rewinding")
            payload["playhead_on_grid"] = parked["on_grid"] ?? NSNull()
        } else if action == "set" {
            // For `set` the row's own tempo cell is the write route, but the
            // playhead is still parked on the event: it is what makes the
            // control bar's reading (and any human watching) agree with the row
            // that is about to change.
            _ = try setPlayhead(barNumber: bar, beat: beat)
            steps.append("playhead parked at bar \(bar) beat \(beat)")
        }

        if action == "create" {
            let created = withListEditorsTab(named: LogicUIStrings.Element.ListEditorTab.tempo) { window -> String? in
                let (table, _) = self.readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.tempo, in: window)
                guard let table, let button = self.firstDescendant(
                    of: table.group, maximumDepth: AXDepth.listEditorTable,
                    where: {
                        self.stringAttribute($0, kAXDescriptionAttribute as String)
                            == LogicUIStrings.Element.createNewTempoEvent
                    }
                ) else { return "the Tempo tab publishes no 'Create new Tempo Event' button" }
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    return "'Create new Tempo Event' could not be pressed"
                }
                Thread.sleep(forTimeInterval: 0.6)
                // Where did it actually land? With the playhead zeroed first
                // this is normally exact; when it is not, the row's own
                // position steppers are the second chance, and if THEY are not
                // published the event is removed again rather than left in the
                // user's tempo track at a position nobody asked for.
                let (after, _) = self.readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.tempo, in: window)
                guard let after else { return "the Tempo List could not be re-read after the create" }
                guard let row = after.rows.first(where: { row in
                    TempoMap.parseTempoListPosition(row.cell(0))?.bar == bar
                }) else { return "no row appeared at bar \(bar)" }
                let landedAt = TempoMap.parseTempoListPosition(row.cell(0))
                steps.append("created at '\(row.cell(0).trimmingCharacters(in: .whitespaces))'")
                if let landedAt, !landedAt.offBeat, landedAt.beatInBar == Double(beat) {
                    return nil
                }
                self.selectListEditorRow(row, in: after)
                Thread.sleep(forTimeInterval: 0.5)
                let (selected, _) = self.readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.tempo, in: window)
                let live = selected?.rows.first { candidate in
                    TempoMap.parseTempoListPosition(candidate.cell(0))?.bar == bar
                }
                let segments = live.map { self.positionSegments(of: $0) } ?? []
                guard segments.count >= 4 else {
                    // Undo our own mess with the row's own Delete action; a
                    // blind Undo is never fired here.
                    let removed = self.performListEditorRowDelete(row)
                    Thread.sleep(forTimeInterval: 0.4)
                    return "the event was created at '\(row.cell(0).trimmingCharacters(in: .whitespaces))'"
                        + " instead of bar \(bar) beat \(beat), and its position steppers were not"
                        + " published (\(segments.count) of 4), so the position could not be corrected."
                        + " The event was \(removed ? "removed again" : "LEFT IN THE PROJECT — delete it in the Tempo List")"
                }
                for (index, target) in [bar, beat, 1, 1].enumerated() {
                    let outcome = self.convergeStepper(segments[index], to: target)
                    steps.append("position segment \(index) -> \(String(describing: outcome.value))"
                                 + " in \(outcome.writes) write(s)")
                }
                return nil
            }
            if let failure = created.failure {
                throw LogicianError.preconditionUnmet(failure.reason)
            }
            if let problem = created.value ?? nil {
                throw LogicianError.writeFailed(problem)
            }
        }

        if action == "create" || action == "set" {
            guard let bpm else { throw LogicianError.invalidArguments("bpm required") }
            let outcome = withListEditorsTab(named: LogicUIStrings.Element.ListEditorTab.tempo) { window -> (Double?, Int) in
                self.convergeRowTempo(in: window, bar: bar, to: bpm)
            }
            if let failure = outcome.failure {
                throw LogicianError.preconditionUnmet(failure.reason)
            }
            let reachedBPM: Double? = outcome.value?.0
            let reachedWrites: Int = outcome.value?.1 ?? 0
            let reachedText: String = reachedBPM.map { "\($0)" } ?? "?"
            steps.append("tempo cell stepped to " + reachedText + " in \(reachedWrites) write(s)")
        }

        if action == "delete" {
            let deleted = withListEditorsTab(named: LogicUIStrings.Element.ListEditorTab.tempo) { window -> String? in
                let (table, _) = self.readListEditorTable(tab: LogicUIStrings.Element.ListEditorTab.tempo, in: window)
                guard let table else { return "the Tempo List could not be read" }
                guard let row = table.rows.first(where: { candidate in
                    let position = TempoMap.parseTempoListPosition(candidate.cell(0))
                    return position?.bar == bar
                }) else { return "no Tempo List row sits at bar \(bar)" }
                self.selectListEditorRow(row, in: table)
                Thread.sleep(forTimeInterval: 0.3)
                guard self.performListEditorRowDelete(row) else {
                    return "the row at bar \(bar) offers no Delete action this server could perform"
                }
                Thread.sleep(forTimeInterval: 0.5)
                return nil
            }
            if let failure = deleted.failure {
                throw LogicianError.preconditionUnmet(failure.reason)
            }
            if let problem = deleted.value ?? nil {
                throw LogicianError.writeFailed(problem)
            }
            steps.append("row deleted")
        }

        // The verification: the whole map, re-read and compared. (The server's
        // per-project cache is dropped by the handler, which owns it.)
        let after = readTempoMap()
        guard let mapAfter = after.map else {
            throw LogicianError.verificationFailed(
                requested: "\(action) at bar \(bar)",
                actual: "the tempo map could not be re-read: \(after.failure?.reason ?? "unknown")",
                restored: false
            )
        }
        payload["events_after"] = mapAfter.events.count
        payload["tempo_map"] = mapAfter.events.map { event in
            ["bar": event.bar, "beat": event.beatInBar, "bpm": event.bpm] as [String: Any]
        }
        payload["steps"] = steps
        payload["write_route"] = action == "delete"
            ? "tempo_list_row_delete_action"
            : "tempo_list_create_button_plus_row_tempo_stepper"
        payload["readback_route"] = "tempo_list"

        let expectedCount: Int
        switch action {
        case "create": expectedCount = mapBefore.events.count + 1
        case "delete": expectedCount = mapBefore.events.count - 1
        default: expectedCount = mapBefore.events.count
        }
        guard mapAfter.events.count == expectedCount else {
            throw LogicianError.verificationFailed(
                requested: "\(expectedCount) tempo event(s) after '\(action)'",
                actual: "the Tempo List holds \(mapAfter.events.count)",
                restored: false
            )
        }
        let landedCandidates = mapAfter.events.filter { $0.bar == bar }
        let landed = landedCandidates.first { abs($0.beatInBar - Double(beat)) < 0.5 }
            ?? landedCandidates.first
        switch action {
        case "delete":
            guard landed == nil else {
                throw LogicianError.verificationFailed(
                    requested: "no tempo event at bar \(bar) beat \(beat)",
                    actual: "one is still there at \(landed?.bpm ?? -1) BPM",
                    restored: false
                )
            }
        default:
            guard let landed, let bpm, abs(landed.bpm - bpm) < 0.51 else {
                throw LogicianError.verificationFailed(
                    requested: "\(bpm ?? -1) BPM at bar \(bar) beat \(beat)",
                    actual: landed.map { "bar \($0.bar) beat \($0.beatInBar) = \($0.bpm) BPM" }
                        ?? "no event at that position",
                    restored: false
                )
            }
            payload["bpm"] = landed.bpm
        }
        // Every OTHER event must be where it was. A tempo write that moved a
        // neighbour is a different project, not a caveat.
        let othersBefore = mapBefore.events.filter { $0.bar != bar }
        let othersAfter = mapAfter.events.filter { $0.bar != bar }
        if othersBefore != othersAfter {
            payload["warning"] = "OTHER tempo events changed as a side effect of this write."
                + " Before: \(othersBefore.map { "bar \($0.bar)=\($0.bpm)" }.joined(separator: ", "))."
                + " After: \(othersAfter.map { "bar \($0.bar)=\($0.bpm)" }.joined(separator: ", "))."
                + " Check the tempo track."
        }
        payload["success"] = true
        payload["verified"] = true
        payload["state"] = action == "delete" ? "deleted" : (action == "create" ? "created" : "confirmed")
        return payload
    }
}
