import AppKit
import ApplicationServices
import Foundation

// MARK: - Reading a channel strip, and writing its routing slots

extension LogicAccessibility {

    /// The strip's AUDIO-EFFECT inserts by display name, with the instrument
    /// slot left out — the list the control surface's plug-in view can
    /// actually be compared against.
    ///
    /// `listInserts` cannot make that distinction and never could: an occupied
    /// instrument slot is an `AXGroup` with exactly the same bypass/open
    /// children as an insert, so it comes back as one more `insert_index`
    /// (verified live 2026-08-31 on `Bas` — `Trilian` arrived as insert_index 5
    /// beside the four effects). The MCU plug-in list shows only the eight
    /// audio-effect slots, so comparing the two lists by count made
    /// `logic_add_plugin` and `logic_remove_plugin` refuse EVERY software
    /// instrument track carrying an instrument, reporting the strip mismatch
    /// "the PL view is pointed at another channel" for a strip that was
    /// correctly selected. `ChannelStrip.read` already separates the two by
    /// geometry, so the cross-checks ask it rather than guessing.
    ///
    /// AND THE SAME IS TRUE OF A SUMMING TRACK STACK'S MAIN CHANNEL, which is
    /// an aux-shaped strip with no MIDI Effect slot at all: measured live
    /// 2026-09-02 on `Drum Synth Kit`, Accessibility published eight names
    /// (`Drum Machine Designer` among them) against the surface's seven
    /// inserts plus one empty slot, and every plug-in write on that strip was
    /// refused as "the PL view is pointed at another channel". See
    /// `ChannelStrip.auxInstrument` for the rule that drops it.
    func insertPluginNames(trackName: String) throws -> [String] {
        ChannelStrip.read(children: stripChildren(of: try inspectorStrip(named: trackName))).plugins
    }

    /// One inspector walk, both answers an automation pass needs before it
    /// touches anything: the strip's automation-mode row (absent on a strip
    /// with no track header — an aux, a bus, an output — which is the state
    /// that makes a mode press unconfirmable) and its static volume in dB,
    /// which pairs with Logic's 14-bit fader echo into the cross-check the
    /// cached fader map is trusted on.
    ///
    /// Throws when the inspector is not showing this strip at all, which is a
    /// different fact from "the strip publishes no automation mode" and is
    /// what `automationModeLabel`'s single `nil` cannot say.
    func stripAutomationReading(trackName: String) throws -> ChannelStripReading {
        ChannelStrip.read(children: stripChildren(of: try inspectorStrip(named: trackName)))
    }

    /// The strip's children as `StripChild` values — the shape
    /// `ChannelStrip.read` parses.
    func stripChildren(of strip: AXUIElement) -> [StripChild] {
        children(of: strip).map { child in
            var y: Double = 0
            if let value = attribute(child, kAXPositionAttribute as String),
               CFGetTypeID(value) == AXValueGetTypeID() {
                var point = CGPoint.zero
                if AXValueGetValue((value as! AXValue), .cgPoint, &point) { y = point.y }
            }
            return StripChild(
                role: stringAttribute(child, kAXRoleAttribute as String),
                subrole: stringAttribute(child, kAXSubroleAttribute as String),
                description: stringAttribute(child, kAXDescriptionAttribute as String),
                title: stringAttribute(child, kAXTitleAttribute as String),
                value: stringAttribute(child, kAXValueAttribute as String),
                valueDescription: stringAttribute(child, kAXValueDescriptionAttribute as String),
                help: stringAttribute(child, kAXHelpAttribute as String),
                y: y
            )
        }
    }

    /// The track header's own controls, which publish two things the channel
    /// strip does not always: Freeze, and — on a software-instrument track —
    /// Record Enable and Input Monitoring (the strip publishes those only on
    /// audio strips).
    func trackHeaderControls(_ item: AXUIElement) -> [String: Bool] {
        var state: [String: Bool] = [:]
        for child in children(of: item)
        where stringAttribute(child, kAXRoleAttribute as String) == "AXCheckBox" {
            guard let key = LogicUIStrings.Element.trackHeaderControls[
                stringAttribute(child, kAXDescriptionAttribute as String)
            ] else { continue }
            state[key] = stringAttribute(child, kAXValueAttribute as String) == "1"
        }
        return state
    }

    /// A routing slot of the strip, found by Logic's own help text.
    func routingSlot(of strip: AXUIElement, kind: ChannelStrip.SlotKind) -> AXUIElement? {
        for child in children(of: strip) {
            let help = stringAttribute(child, kAXHelpAttribute as String)
            for (prefix, candidate) in ChannelStrip.slotHelpPrefixes
            where candidate == kind && help.hasPrefix(prefix) {
                return child
            }
        }
        return nil
    }

    // MARK: - logic_track_info

    /// Everything the Accessibility plane knows about a track: the header's
    /// switches and the whole channel strip — type, routing, group,
    /// monitoring, inserts, sends, automation mode.
    ///
    /// COSTS A SELECTION. The LEFT inspector strip shows the SELECTED track and
    /// nothing else, so reading track N means selecting track N. The original
    /// selection is put back at the end and the result says whether that
    /// worked.
    ///
    /// **Every row is addressed by NUMBER.** It used to be addressed by name,
    /// and the reference project has two tracks called `Ivan Vocals` (rows 21
    /// and 22): the loop's "am I already showing this track?" gate compared
    /// names, found row 22's name equal to the name it was already showing,
    /// skipped the re-selection, and re-read ROW 21's strip under
    /// `track_number: 22` — byte-identical payloads, `success: true`, no note
    /// (measured live 2026-09-03, profiles/logic_track_info.md D1). Numbers
    /// are unique and the track family carries them everywhere, so the gate,
    /// the re-selection and the restore all use them now, and a name that
    /// matches several rows is REFUSED with those rows' numbers rather than
    /// resolved to the first of them.
    ///
    /// Measured 2026-09-03, 19 rendered tracks: 15.27 s before this pass,
    /// against 1.14-1.19 s for a single track. What that bought was two blind
    /// waits and two duplicate tree walks per track, all four removed here —
    /// see `settledStripReading` and `selectTrackReportingRows`'s strip
    /// hand-back.
    func trackInfo(trackNames: [String]?, trackNumber: Int?, all: Bool) throws -> [String: Any] {
        let headers = try parsedTrackHeaders()
        guard !headers.isEmpty else {
            throw LogicianError.windowNotFound("track headers")
        }
        let original = headers.first(where: \.selected)
        var wanted: [TrackHeader]
        if all {
            wanted = headers
        } else if let names = trackNames, !names.isEmpty {
            // Resolved BEFORE the first selection moves, all of them: a name
            // that names no row, or several rows, refuses the whole call
            // rather than reading half of it and then failing. The rule is the
            // track family's own (`TrackRowAddressing`), so an ambiguous name
            // comes back with the numbers that would resolve it — which is
            // exactly what `track_number` is for.
            wanted = try names.map { name in
                try resolveTrack(
                    headers,
                    name: name,
                    number: names.count == 1 ? trackNumber : nil,
                    caseInsensitive: true
                )
            }
        } else if let selected = original {
            wanted = [selected]
        } else {
            wanted = [headers[0]]
        }

        var entries: [[String: Any]] = []
        // Which track the inspector is showing RIGHT NOW, by NUMBER. The
        // `selected` flag on `headers` is a snapshot from before the loop, so
        // after the first read it is stale for every other row. `nil` means
        // "no longer known" — a move that failed leaves the inspector wherever
        // it left it, and the next row must not assume.
        var showing = original?.number
        // The header rows, re-walked only when a selection actually MOVED.
        // Selecting a track SCROLLS the Tracks area to show it, and a header
        // element captured before that scroll can be stale — its checkboxes
        // would then read as absent, which this type reports as `null` and an
        // agent would read as "Logic published nothing". Nothing scrolls when
        // nothing moves, so the walk that used to run on every iteration (37-58
        // ms × 19 rows, ≈0.8 s) now runs once per real move.
        var live = headers
        for header in wanted {
            var landing = SelectionVerification.notSelected
            var moveFailure: String?
            if inspectorAlreadyShows(row: header.number, showing: showing) {
                // Already on this row — PROVE it rather than assume it, the
                // same check `selectTrack` makes on its own `already_selected`
                // path, and keep the strip that proves it.
                let row = live.first { $0.number == header.number } ?? header
                landing = verifySelection(row.item, name: row.name)
            } else {
                do {
                    let moved = try selectTrackReportingRows(
                        trackName: header.name,
                        trackNumber: header.number,
                        expectedProjectPath: nil
                    )
                    // `selectTrack` verified the selection by finding this
                    // track's inspector strip; that element is the one this
                    // read needs, so it is not walked for a second time.
                    landing = moved.strip.map { .verified(strip: $0) } ?? .verifiedStaleName
                    showing = header.number
                    live = (try? parsedTrackHeaders()) ?? live
                } catch {
                    moveFailure = error.localizedDescription
                    showing = nil
                }
            }
            var entry: [String: Any] = [
                "track_name": header.name,
                "track_number": header.number
            ]
            let row = live.first { $0.number == header.number } ?? header
            entry["header"] = trackHeaderControls(row.item)
            // A row whose selection could not be proved is NOT read off
            // whatever strip happens to be standing: with two rows sharing a
            // name, that strip can carry the other row's numbers and there is
            // nothing in the payload to tell them apart.
            let strip = landing.strip
                ?? (landing.isVerified ? try? inspectorStrip(named: header.name) : nil)
            guard let strip else {
                entry["strip"] = NSNull()
                entry["strip_note"] = moveFailure.map {
                    "track \(header.number) could not be selected, so its strip was not read"
                        + " and no other strip was read in its place: \($0)"
                } ?? ("no inspector channel strip for track \(header.number) '\(header.name)' was"
                    + " visible after selecting it — the left inspector may be hidden"
                    + " (View > Show Inspector)")
                entries.append(entry)
                continue
            }
            let settled = settledStripReading(strip, expecting: header.name)
            entry["strip"] = stripPayload(settled.reading, strip: strip)
            if let note = settled.note { entry["strip_settle"] = note }
            entries.append(entry)
        }

        var selectionRestored: Bool?
        if let original, showing != original.number {
            selectionRestored = (try? selectTrack(
                trackName: original.name, trackNumber: original.number, expectedProjectPath: nil
            )) != nil
        }

        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "read",
            "tracks": entries,
            "read_route": "accessibility_inspector_strip"
        ]
        if let original {
            payload["selection_before"] = original.name
            // Two tracks can share a name, so the row this selection is going
            // back to is named by the thing that is unique about it as well.
            payload["selection_before_number"] = original.number
        }
        if let selectionRestored { payload["selection_restored"] = selectionRestored }
        payload["note"] = "Every value is read off Logic's own control and a field that is absent means"
            + " Logic published nothing for it — never that it is off. 'kind' is inferred from which"
            + " SLOTS the strip publishes (kind_evidence says which), and 'reduced' is a real case:"
            + " a folder-stack main track publishes only name/mute/solo/volume/automation/group and no"
            + " output slot at all. Reading a track requires SELECTING it; the previous selection is"
            + " restored and selection_restored says whether that worked. Rows are addressed by"
            + " track_number throughout, so two tracks sharing a name are read separately and a"
            + " strip that could not be proved to be the requested row is reported as null with a"
            + " strip_note rather than read off whichever strip was standing."
        return payload
    }

    /// The channel strip, read once it has finished repainting after a
    /// selection moved to it.
    ///
    /// **This replaced a blind `Thread.sleep(0.3)`** that fired after every
    /// real re-selection — measured 300-310 ms on 18 of 18 moves, 26% of a
    /// single-track call and ≈5.4 s of a 15.27 s 19-track read (2026-09-03,
    /// profiles/logic_track_info.md §6). It was not insuring against a race
    /// `selectTrack` leaves open: `selectTrack` returns only once the header
    /// says selected AND the left inspector publishes this track's strip. What
    /// it could still insure against is the strip's CONTENTS lagging its name,
    /// so that is what is checked, by looking instead of waiting.
    ///
    /// Look first. The strip's own name row is a second, independent plane
    /// from the `AXDescription` `selectTrack` matched on, and when it already
    /// names the track just selected the repaint has reached the children and
    /// there is nothing left to wait for — the usual case, at zero wait. When
    /// it does not (a channel legitimately named differently from its track
    /// header), the fallback is agreement: read again 50 ms later and take the
    /// answer when two consecutive reads are identical. A read that never
    /// settles is returned WITH a note saying so, never silently.
    private func settledStripReading(
        _ strip: AXUIElement, expecting name: String
    ) -> (reading: ChannelStripReading, note: String?) {
        let budget = 8
        let gap = 0.05
        var previous: ChannelStripReading?
        var reading = ChannelStripReading()
        for attempt in 0..<budget {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: gap) }
            reading = ChannelStrip.read(children: stripChildren(of: strip))
            let decision = settleDecision(
                attempt: attempt,
                budget: budget,
                proven: reading.childCount > 0 && reading.name == name,
                matchedPrevious: previous == reading
            )
            switch decision {
            case .accept:
                return (reading, attempt == 0 ? nil : "stable after \(attempt + 1) reads")
            case .lookAgain:
                previous = reading
            case .giveUp:
                return (reading, "the strip's own name row still reads '\(reading.name)' and two"
                    + " consecutive reads \(Int(gap * 1000)) ms apart never agreed after"
                    + " \(budget) reads — these values may be mid-repaint")
            }
        }
        return (reading, nil)
    }

    private func stripPayload(_ reading: ChannelStripReading, strip: AXUIElement) -> [String: Any] {
        var payload: [String: Any] = [
            "name": reading.name,
            "kind": reading.kind.rawValue,
            "kind_evidence": reading.kindEvidence,
            "child_count": reading.childCount
        ]
        func put(_ key: String, _ value: Any?) {
            payload[key] = value ?? NSNull()
        }
        put("output", reading.output)
        put("output_display", reading.outputDisplay)
        put("input", reading.input)
        put("input_display", reading.inputDisplay)
        put("input_gain", reading.inputGain)
        put("channel_mode", reading.channelMode)
        put("group", reading.group)
        put("group_display", reading.groupDisplay)
        put("automation_mode", reading.automationMode)
        put("mute", reading.mute)
        put("solo", reading.solo)
        put("record_armed", reading.recordArmed)
        put("input_monitoring", reading.inputMonitoring)
        put("volume_db", reading.volumeDB)
        put("pan", reading.pan)
        put("instrument", reading.instrument)
        put("eq_on", reading.eqOn)
        payload["has_instrument_slot"] = reading.hasInstrumentSlot
        payload["has_midi_effect_slot"] = reading.hasMIDIEffectSlot
        payload["sends"] = reading.sends.map { send in
            ["destination": send.destination, "level": send.level ?? NSNull()] as [String: Any]
        }
        // Inserts come from the same enumeration `logic_list_inserts` uses, so
        // the two tools cannot disagree about slot numbering. On a software
        // instrument strip the INSTRUMENT is one of these groups too (it
        // carries the same bypass/open children), which is why it is reported
        // separately above and named here.
        payload["inserts"] = insertSlots(of: strip).map { slot in
            [
                "insert_index": slot.index,
                "name": slot.name,
                "bypassed": slot.bypassed,
                "is_instrument_slot": InsertSlot.isInstrumentSlot(name: slot.name, instrument: reading.instrument)
            ] as [String: Any]
        }
        return payload
    }

    // MARK: - logic_set_track_routing

    /// How the slot is read back after a routing press.
    ///
    /// The budget is unchanged at 25 looks — a slot that repaints slowly is
    /// still given every one of them. What changed on 2026-09-03 is what a
    /// hopeless poll costs: `output: "Mono"` read the SAME unchanged label 25
    /// times and paid 6.7 s for it, because each look re-walks the inspector
    /// strip (130-165 ms) on top of its own 120 ms sleep. Reads that keep
    /// answering the same non-matching value are not a slot still settling,
    /// they are a slot that has settled — see `routingSettledMisses`.
    static let routingConfirmAttempts = 25
    static let routingConfirmInterval: TimeInterval = 0.12

    /// How many identical, non-empty, non-matching reads in a row end the
    /// confirm-poll early. Five spans ~1.2 s of settled evidence — four times
    /// the whole cost of every successful confirm measured live (one look,
    /// 140 ms) and a fifth of what the doomed poll used to burn.
    static let routingSettledMisses = 5

    /// Writes the strip's routing slots — output, input, group — through their
    /// pop-up menus, one compare-and-set at a time, each verified by reading
    /// the slot back.
    func setTrackRouting(
        trackName: String,
        output: String?,
        input: String?,
        group: String?,
        expected: [String: Any]
    ) throws -> [String: Any] {
        guard output != nil || input != nil || group != nil else {
            throw LogicianError.invalidArguments("nothing to set: pass output, input and/or group")
        }
        let headers = try parsedTrackHeaders()
        guard let header = headers.first(where: {
            $0.name.caseInsensitiveCompare(trackName) == .orderedSame
        }) else {
            throw LogicianError.trackNotExposed(
                requested: trackName, exposed: headers.map(\.name).joined(separator: ", ")
            )
        }
        let original = headers.first(where: \.selected)?.name
        if !header.selected {
            _ = try selectTrack(
                trackName: header.name, trackNumber: header.number, expectedProjectPath: nil
            )
            Thread.sleep(forTimeInterval: 0.3)
        }
        defer {
            if let original, original != header.name {
                _ = try? selectTrack(trackName: original, trackNumber: nil, expectedProjectPath: nil)
            }
        }
        var strip = try inspectorStrip(named: header.name)

        /// Reads a slot's CURRENT value the same way `logic_track_info` does,
        /// so a value read here can be fed straight back as `expected_current`.
        ///
        /// The strip element is RE-RESOLVED every time, not captured: a routing
        /// change repaints the whole inspector strip, and the captured element
        /// then answers every attribute with nothing. Measured 2026-08-28 —
        /// the readback saw `''` forever and called a write that had landed
        /// (the very next tool call read `Bus 4`) a verification failure.
        func currentValue(_ kind: ChannelStrip.SlotKind) -> String? {
            if let fresh = try? inspectorStrip(named: header.name) { strip = fresh }
            let reading = ChannelStrip.read(children: stripChildren(of: strip))
            switch kind {
            case .output: return reading.outputDisplay
            case .input: return reading.inputDisplay
            case .group: return reading.groupDisplay
            default: return nil
            }
        }

        // EVERY refusal happens before the FIRST write: a call that names one
        // reachable slot and one unreachable one must not half-apply. Same
        // discipline as `setRegionParameters` (FINDINGS 2026-08-28, finding 7).
        var plan: [(kind: ChannelStrip.SlotKind, key: String, target: String)] = []
        for (kind, key, target) in [
            (ChannelStrip.SlotKind.input, "input", input),
            (ChannelStrip.SlotKind.output, "output", output),
            (ChannelStrip.SlotKind.group, "group", group)
        ].compactMap({ item -> (ChannelStrip.SlotKind, String, String)? in
            item.2.map { (item.0, item.1, $0) }
        }) {
            guard routingSlot(of: strip, kind: kind) != nil else {
                throw LogicianError.trackNotExposed(
                    requested: "the \(key) slot of '\(trackName)'",
                    exposed: "this channel strip publishes no \(key) slot."
                        + " A software-instrument strip has no input slot, and a folder-stack main"
                        + " track publishes a reduced strip with no routing slots at all"
                        + " — logic_track_info reports which"
                )
            }
            if let expectedValue = expected[key] as? String {
                let current = currentValue(kind) ?? ""
                guard ChannelStrip.routingMatches(item: current, requested: expectedValue) else {
                    throw LogicianError.currentValueMismatch(
                        expected: expectedValue, actual: current
                    )
                }
            }
            plan.append((kind, key, target))
        }

        var results: [String: Any] = [:]
        var unchanged: [String] = []
        for step in plan {
            let before = currentValue(step.kind) ?? ""
            if ChannelStrip.routingMatches(item: before, requested: step.target) {
                unchanged.append(step.key)
                results[step.key] = [
                    "before": before, "after": before, "state": "already_set"
                ] as [String: Any]
                continue
            }
            // Resolved HERE, not in the plan: the strip repaints after every
            // routing change, and a slot element captured before one is dead.
            guard let slotElement = routingSlot(of: strip, kind: step.kind) else {
                throw LogicianError.trackNotExposed(
                    requested: "the \(step.key) slot of '\(trackName)'",
                    exposed: "it was there a moment ago and is not now — the inspector strip repainted"
                )
            }
            let (pressed, menuRoute) = try chooseRouting(slot: slotElement, titled: step.target)
            // The slot REPAINTS after a routing change and publishes an EMPTY
            // description while it does — measured 2026-08-28, where a fixed
            // 0.35 s wait read `''` and called a write that had landed
            // perfectly a `verification_failed` (the very next read, two
            // seconds later, said `Bus 4`). So poll for a settled, non-empty
            // label instead of sleeping a guess.
            var watch = ChannelStrip.SettleWatch(
                target: step.target, limit: Self.routingSettledMisses
            )
            var landed = false
            for attempt in 0..<Self.routingConfirmAttempts {
                if lookFirstShouldSleep(attempt: attempt) {
                    Thread.sleep(forTimeInterval: Self.routingConfirmInterval)
                }
                let verdict = watch.observe(currentValue(step.kind) ?? "")
                if verdict == .landed { landed = true }
                if verdict == .landed || verdict == .settledOnAnother { break }
            }
            let after = watch.last
            results[step.key] = [
                "before": before,
                "requested": step.target,
                "menu_item_pressed": pressed,
                "menu_route": menuRoute,
                "after": after,
                "state": landed ? "confirmed" : "unverified"
            ] as [String: Any]
            guard landed else {
                throw LogicianError.verificationFailed(
                    requested: "\(step.key) = \(step.target)",
                    actual: "the slot reads '\(after)' after pressing '\(pressed)'"
                        + (after == before
                            ? " — the same value it read before, so the press changed nothing"
                            : " (it read '\(before)' before)"),
                    // Nothing to put back and nothing tried: the only write on
                    // this path is the menu press itself, and a slot that never
                    // moved has no inverse. Saying `false` here read as "the
                    // restore was attempted and failed" (D2, 2026-09-03).
                    restored: nil
                )
            }
        }

        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "state": unchanged.count == plan.count ? "already_set" : "confirmed",
            "track_name": header.name,
            "write_route": "accessibility_slot_menu",
            "readback_route": "accessibility_slot_description"
        ]
        for (key, value) in results { payload[key] = value }
        if !unchanged.isEmpty { payload["unchanged"] = unchanged }
        // Routing to a bus is not a pure assignment: Logic CREATES the aux
        // channel strip behind that bus the first time anything is sent to it
        // (measured 2026-08-28 — `Bus 4` was a bare `Bus 4` in the menu before
        // the write and `Bus 4 → Aux 4` after it), and routing away again does
        // not remove the aux. Undoing the routing is not undoing the aux.
        if plan.contains(where: {
            !unchanged.contains($0.key) && ChannelStrip.routingHead($0.target).hasPrefix("Bus")
        }) {
            payload["side_effect_note"] = "Logic creates the AUX channel strip behind a bus the first"
                + " time something is routed to it, and routing away again does NOT remove that aux."
                + " Check logic_list_strips / the Mixer if an unexpected Aux appears."
        }
        return payload
    }

    /// Every open pop-up menu, searched DEEPER than `popupMenus()`.
    ///
    /// A channel strip's slot menu is not always parented where a plugin
    /// window's is: measured 2026-08-28, presses alternated between "the menu
    /// opened" and "the menu did not open" while the press itself was working
    /// every time — the depth-7 walk simply did not reach the menu on the
    /// presses where Logic parented it under the project window's own tree.
    /// The Region inspector hit exactly this and raised its own cap to 14.
    func stripSlotMenus() -> [AXUIElement] {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menus: [AXUIElement] = []
        walk(from: appElement, maximumDepth: AXDepth.stripSlotMenu) { element in
            let role = stringAttribute(element, kAXRoleAttribute as String)
            if role == "AXMenuBar" { return .skipChildren }
            if role == "AXMenu" { menus.append(element); return .skipChildren }
            return .descend
        }
        return menus
    }

    func dismissStripSlotMenus() {
        for menu in stripSlotMenus() {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    /// What a slot press actually produced: the menus that came up, and how
    /// they were found — which matters, because a menu found by hit test is
    /// one `dismissPopupMenus()` cannot cancel and only the element itself
    /// can.
    struct OpenedSlotMenu {
        let menus: [AXUIElement]
        /// What finally opened it, reported to the caller: `ax_press`, or
        /// `mouse_click` when Logic's own press action did nothing and the
        /// synthetic click had to stand in for a hand on the mouse.
        let route: String
        /// Nothing came up. Spelled out rather than a static constant because
        /// `AXUIElement` is not `Sendable` and a static one would be shared
        /// mutable state.
        init(menus: [AXUIElement] = [], route: String = "none") {
            self.menus = menus
            self.route = route
        }
    }

    /// How a slot press's menu is waited for.
    ///
    /// MEASURED 2026-09-03: a press that opens the menu where the shallow
    /// depth-7 walk can see it is answered on the FIRST look, so the poll
    /// looks before it sleeps and steps in 25 ms instead of 100 ms. The deep
    /// depth-14 walk costs far more than the shallow one, so it is asked once
    /// per attempt and only after the shallow deadline has passed: it is the
    /// answer to "the menu is up and I cannot see it", not a per-tick cost.
    static let slotMenuShallowDeadline: TimeInterval = 0.4
    static let slotMenuPollInterval: TimeInterval = 0.025

    /// Attempts at the whole raise-clear-press cycle. Three, not five: the
    /// measured cure for a press that opens nothing is the Escape between
    /// attempts (2026-08-28 — one Escape and the very next press worked), and
    /// the two extra attempts only ever bought a longer walk to the same
    /// failure — 21 s of it on the slot state profiles/logic_set_track_routing
    /// §3 found, where no attempt could ever have succeeded.
    static let slotMenuAttempts = 3

    /// Presses a routing slot until its menu is actually up, raising and
    /// focusing the project window first.
    ///
    /// MEASURED 2026-08-28: the first press in a session opened the menu every
    /// time and later ones reported "the menu did not open" — the same failure
    /// the plugin setting menu had (FINDINGS v0.53.0, finding 8). A press into
    /// a window that does not hold the focus arrives nowhere, and Logic being
    /// the frontmost APPLICATION says nothing about which of its windows is
    /// focused. So: raise, focus, press, and retry the press rather than
    /// reporting a failure that a second attempt fixes.
    private func openSlotMenu(_ slot: AXUIElement) -> OpenedSlotMenu {
        for _ in 0..<Self.slotMenuAttempts {
            try? ensureLogicFrontmost(for: "the channel strip routing menu")
            if let window = try? projectWindow() {
                _ = AXUIElementPerformAction(window, "AXRaise" as CFString)
                if let application = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    AXUIElementSetAttributeValue(
                        AXUIElementCreateApplication(application.processIdentifier),
                        kAXFocusedWindowAttribute as CFString, window
                    )
                }
            }
            // Any menu standing BEFORE our press is not ours; clear it so the
            // one we find afterwards can only be the slot's.
            dismissPopupMenus()
            // ESCAPE, and this is the whole trick. Logic gets into a state
            // where a slot press answers `.success` and opens nothing —
            // reproducibly, for a whole run — and a single Escape clears it:
            // measured 2026-08-28, six presses in a row opened nothing, one
            // Escape and the very next press opened the menu, and every press
            // after that worked. Escape alone opens NO menu here (checked, in
            // case it had raised Logic's Tool palette instead), so it costs
            // nothing when the press would have worked anyway. What Logic
            // thinks it is cancelling is not known; that it cancels it is.
            try? sendKeystrokeToFrontmostLogic(virtualKey: 53, label: "Escape (clearing pending UI state)")
            Thread.sleep(forTimeInterval: 0.25)
            // The press opens a TRACKING menu, so Logic's menu runloop never
            // answers it: waiting for the reply cost 1504 ms — 44% of a whole
            // successful call — on every menu this tool opened
            // (profiles/logic_set_track_routing §2, 2026-09-03). The menu is
            // the only judge, and it is looked for below.
            pressOpeningTrackingMenu(slot)
            if let opened = lookForSlotMenu(over: slot) { return opened }
        }
        return OpenedSlotMenu()
    }

    /// The menu that is on screen OVER this slot, found by asking the window
    /// server what is drawn at the slot's own centre and walking UP from it —
    /// the opposite direction from every other search in this file.
    ///
    /// THIS IS THE CURE FOR THE `No Output` LOCKOUT, and the mechanism is
    /// worth writing down. Measured live 2026-09-03: with the strip's output
    /// set to `No Output`, three presses in a row opened NOTHING that any
    /// downward walk could see — 0 menus at depth 7, 0 at depth 14, on 3
    /// attempts × 4 calls, ~21 s per call in the shipped shape — and the tool
    /// reported "the routing slot's menu did not open" while the menu was in
    /// fact standing open on screen. A hit test at the slot's centre right
    /// after the press found `AXMenuItem <- AXMenu(8 items: '', No Output, '',
    /// Output, Bus, '', Pan, Binaural Panner) <- AXPopUpButton <- AXLayoutArea
    /// 'Mixer' <- … <- AXApplication`: Logic had parented the menu under an
    /// AXPopUpButton proxy that the layout area does not list among its own
    /// AXChildren, so no walk down from the application can ever reach it.
    /// The same strip with a real output parents the same menu where the
    /// depth-7 walk finds it on the first look.
    ///
    /// The state was reachable in one call of this tool and escapable in none
    /// of them: the profile had to leave the tool entirely and press Undo.
    /// One AX call, ~2 ms, closes that hole.
    func slotMenuOnScreen(over slot: AXUIElement) -> [AXUIElement] {
        guard let frameValue = attribute(slot, "AXFrame"),
              let frame = rectValue(frameValue), !frame.isEmpty else { return [] }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(frame.midX), Float(frame.midY), &hit
        ) == .success, var current = hit else { return [] }
        // Up through the menu ITEM (and a submenu's own item) to the menu.
        for _ in 0..<AXDepth.slotMenuAncestors {
            if stringAttribute(current, kAXRoleAttribute as String) == "AXMenu" { return [current] }
            guard let parent = attribute(current, kAXParentAttribute as String),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return [] }
            current = (parent as! AXUIElement)
        }
        return []
    }

    /// Look for the menu the press just opened, cheapest and most direct look
    /// first: what is drawn over the slot, then the shallow depth-7 walk, and
    /// — once, after the deadline — the deep depth-14 walk that this file has
    /// carried since 2026-08-28 for the presses where Logic parents the menu
    /// under the project window's own tree.
    private func lookForSlotMenu(over slot: AXUIElement) -> OpenedSlotMenu? {
        let deadline = Date().addingTimeInterval(Self.slotMenuShallowDeadline)
        while true {
            let onScreen = slotMenuOnScreen(over: slot)
            if !onScreen.isEmpty {
                return OpenedSlotMenu(menus: onScreen, route: "hit_test")
            }
            let menus = popupMenus()
            if !menus.isEmpty {
                return OpenedSlotMenu(menus: menus, route: "shallow_walk")
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: Self.slotMenuPollInterval)
        }
        let deep = stripSlotMenus()
        return deep.isEmpty ? nil : OpenedSlotMenu(menus: deep, route: "deep_walk")
    }

    /// Cancel the menus a slot press opened — the ones we HOLD first, because
    /// a menu found by hit test is exactly the menu no walk can find again,
    /// and then the shallow walk for anything else that came up with it.
    func dismissSlotMenus(_ opened: OpenedSlotMenu) {
        for menu in opened.menus {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
        dismissPopupMenus()
    }

    /// One entry of a routing slot's pop-up menu.
    struct RoutingChoice {
        let title: String
        /// Logic's own tick: `AXMenuItemMarkChar` is `✓` on the destination in
        /// force and `-` on the category that contains it.
        let current: Bool
        let enabled: Bool
    }

    /// Opens a routing slot's menu, enumerates it, and CANCELS. Nothing is
    /// chosen; this is the read half of the write.
    ///
    /// MEASURED 2026-08-28: the slot is an `AXButton` whose only action is
    /// `AXPress`, and the press answers `AXError -25204` while opening the
    /// menu anyway — exactly like the insert slot's plugin chooser and the
    /// plugin window's setting menu, so the error is not checked. The menu is
    /// deep (Bus 1-32, then `33 - 64` … `225 - 256` submenus) and the leaf
    /// titles carry their destination: `"Bus 2 → Aux 2"` on an output slot,
    /// `"Bus 2 ← Lofi Pad"` on an input slot.
    func routingChoices(of slot: AXUIElement) throws -> [RoutingChoice] {
        let opened = openSlotMenu(slot)
        defer {
            dismissSlotMenus(opened)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let menu = opened.menus.first else {
            throw LogicianError.openVerificationFailed(
                ChannelStrip.slotMenuFailure(attempts: Self.slotMenuAttempts)
            )
        }
        var choices: [RoutingChoice] = []
        walk(from: menu, maximumDepth: AXDepth.routingMenuItem) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" else {
                return .descend
            }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            guard !title.isEmpty else { return .descend }
            choices.append(RoutingChoice(
                title: title,
                current: stringAttribute(element, "AXMenuItemMarkChar") == "✓",
                enabled: stringAttribute(element, kAXEnabledAttribute as String) != "0"
            ))
            return .descend
        }
        return choices
    }

    /// Does this menu item merely CONTAIN destinations? A routing menu nests
    /// its channel formats — `Mono`, `Stereo`, `Surround` — as submenus over
    /// the actual physical outputs, and a submenu parent answers `AXPress`
    /// with `.success` while routing nothing anywhere.
    func routingItemIsCategory(_ item: AXUIElement) -> Bool {
        children(of: item).contains {
            stringAttribute($0, kAXRoleAttribute as String) == "AXMenu"
        }
    }

    /// The destination titles inside a category item, in menu order.
    func routingItemLeaves(_ item: AXUIElement) -> [String] {
        var leaves: [String] = []
        walk(from: item, maximumDepth: AXDepth.routingMenuItem) { element in
            guard !CFEqual(element, item),
                  stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" else {
                return .descend
            }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            if !title.isEmpty, !routingItemIsCategory(element) { leaves.append(title) }
            return .descend
        }
        return leaves
    }

    /// Opens a routing slot's menu and presses the item the caller named.
    /// Returns the exact title pressed. The menu is dismissed on every failure
    /// path, because an open menu swallows Logic's keyboard.
    /// Returns the title pressed and HOW the menu was opened — `ax_press`, or
    /// `mouse_click` when Logic's press action opened nothing and the
    /// hit-tested synthetic click had to.
    @discardableResult
    func chooseRouting(slot: AXUIElement, titled requested: String) throws -> (title: String, route: String) {
        let opened = openSlotMenu(slot)
        guard let menu = opened.menus.first else {
            dismissSlotMenus(opened)
            throw LogicianError.openVerificationFailed(
                ChannelStrip.slotMenuFailure(attempts: Self.slotMenuAttempts)
            )
        }
        var target: AXUIElement?
        var category: AXUIElement?
        var titles: [String] = []
        walk(from: menu, maximumDepth: AXDepth.routingMenuItem) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" else {
                return .descend
            }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            guard !title.isEmpty else { return .descend }
            titles.append(title)
            if ChannelStrip.routingMatches(item: title, requested: requested) {
                // A CATEGORY is not a destination, and pressing one is the
                // quiet failure D2 measured: `Mono` answered `.success` in
                // 0.1 ms and left the slot reading `Stereo Output` through a
                // 6.7 s confirm-poll (profiles/logic_set_track_routing §4,
                // 2026-09-03). Remember it, keep looking for a real leaf, and
                // refuse with its contents if a leaf never turns up.
                if routingItemIsCategory(element) {
                    if category == nil { category = element }
                } else if target == nil {
                    target = element
                }
            }
            return .descend
        }
        guard let item = target else {
            dismissSlotMenus(opened)
            Thread.sleep(forTimeInterval: 0.25)
            if let category {
                throw LogicianError.invalidArguments(ChannelStrip.categoryRefusal(
                    requested: requested,
                    category: stringAttribute(category, kAXTitleAttribute as String),
                    leaves: routingItemLeaves(category),
                    offered: titles.filter { !$0.isEmpty }
                ))
            }
            throw LogicianError.parameterNotFound(
                "routing destination '\(requested)'. The slot offers: \(titles.prefix(40).joined(separator: ", "))"
                    + (titles.count > 40 ? ", … (\(titles.count) in all)" : "")
            )
        }
        let title = stringAttribute(item, kAXTitleAttribute as String)
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            dismissSlotMenus(opened)
            Thread.sleep(forTimeInterval: 0.25)
            throw LogicianError.writeFailed(
                "pressing '\(title)' in the routing menu returned AXError \(status.rawValue)"
            )
        }
        // No blind settle here any more. The 0.45 s this used to sleep bought
        // exactly what the caller's own confirm-poll buys, twice over: 454 ms
        // of a 3420 ms call, 13.3% of it, waiting for a repaint the poll then
        // waited for again and actually checked (profiles/logic_set_track_routing
        // §5.4, 2026-09-03). The one thing worth knowing right now is whether
        // a menu is still standing — a menu that survived a successful press
        // is a menu that ate it, and it would swallow Logic's keyboard.
        if !popupMenus().isEmpty || !slotMenuOnScreen(over: slot).isEmpty {
            dismissSlotMenus(opened)
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (title, opened.route)
    }
}
