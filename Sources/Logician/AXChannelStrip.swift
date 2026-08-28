import AppKit
import ApplicationServices
import Foundation

// MARK: - Reading a channel strip, and writing its routing slots

extension LogicAccessibility {

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
            let key: String
            switch stringAttribute(child, kAXDescriptionAttribute as String) {
            case "Mute": key = "mute"
            case "Solo": key = "solo"
            case "Freeze": key = "freeze"
            case "Record Enable": key = "record_enable"
            case "Input Monitoring": key = "input_monitoring"
            default: continue
            }
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
    /// worked. Measured 2026-08-28: ~0.7 s per track.
    func trackInfo(trackNames: [String]?, all: Bool) throws -> [String: Any] {
        let headers = try parsedTrackHeaders()
        guard !headers.isEmpty else {
            throw LogicianError.windowNotFound("track headers")
        }
        let original = headers.first(where: \.selected)?.name
        var wanted: [TrackHeader]
        if all {
            wanted = headers
        } else if let names = trackNames, !names.isEmpty {
            wanted = try names.map { name in
                guard let header = headers.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) else {
                    throw LogicianError.trackNotExposed(
                        requested: name,
                        exposed: headers.map(\.name).joined(separator: ", ")
                    )
                }
                return header
            }
        } else if let selected = headers.first(where: \.selected) {
            wanted = [selected]
        } else {
            wanted = [headers[0]]
        }

        var entries: [[String: Any]] = []
        // Which track the inspector is showing RIGHT NOW. The `selected` flag
        // on `headers` is a snapshot from before the loop, so after the first
        // read it is stale for every other row — reading it instead of this
        // skipped the re-selection and handed back the PREVIOUS track's strip
        // (or, because the name check catches it, no strip at all).
        var showing = original
        for header in wanted {
            if header.name != showing {
                _ = try? selectTrack(
                    trackName: header.name, trackNumber: header.number, expectedProjectPath: nil
                )
                Thread.sleep(forTimeInterval: 0.3)
                showing = header.name
            }
            var entry: [String: Any] = [
                "track_name": header.name,
                "track_number": header.number
            ]
            // Re-resolve the header AFTER the selection. Selecting a track
            // SCROLLS the Tracks area to show it (Logic re-banks the control
            // surface for the same reason), and a header element captured
            // before that scroll can be stale — its checkboxes would then read
            // as absent, which this type reports as `null` and an agent would
            // read as "Logic published nothing".
            let live = (try? parsedTrackHeaders())?.first { $0.number == header.number } ?? header
            entry["header"] = trackHeaderControls(live.item)
            guard let strip = try? inspectorStrip(named: header.name) else {
                entry["strip"] = NSNull()
                entry["strip_note"] = "no inspector channel strip named '\(header.name)' was visible"
                    + " after selecting it — the left inspector may be hidden (View > Show Inspector)"
                entries.append(entry)
                continue
            }
            let reading = ChannelStrip.read(children: stripChildren(of: strip))
            entry["strip"] = stripPayload(reading, strip: strip)
            entries.append(entry)
        }

        var selectionRestored: Bool?
        if let original, showing != original {
            selectionRestored = (try? selectTrack(
                trackName: original, trackNumber: nil, expectedProjectPath: nil
            )) != nil
        }

        var payload: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "read",
            "tracks": entries,
            "read_route": "accessibility_inspector_strip"
        ]
        if let original { payload["selection_before"] = original }
        if let selectionRestored { payload["selection_restored"] = selectionRestored }
        payload["note"] = "Every value is read off Logic's own control and a field that is absent means"
            + " Logic published nothing for it — never that it is off. 'kind' is inferred from which"
            + " SLOTS the strip publishes (kind_evidence says which), and 'reduced' is a real case:"
            + " a folder-stack main track publishes only name/mute/solo/volume/automation/group and no"
            + " output slot at all. Reading a track requires SELECTING it; the previous selection is"
            + " restored and selection_restored says whether that worked."
        return payload
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
                "is_instrument_slot": slot.name == reading.instrument
            ] as [String: Any]
        }
        return payload
    }

    // MARK: - logic_set_track_routing

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
            let pressed = try chooseRouting(slot: slotElement, titled: step.target)
            // The slot REPAINTS after a routing change and publishes an EMPTY
            // description while it does — measured 2026-08-28, where a fixed
            // 0.35 s wait read `''` and called a write that had landed
            // perfectly a `verification_failed` (the very next read, two
            // seconds later, said `Bus 4`). So poll for a settled, non-empty
            // label instead of sleeping a guess.
            var after = ""
            for _ in 0..<25 {
                Thread.sleep(forTimeInterval: 0.12)
                let value = currentValue(step.kind) ?? ""
                guard !value.isEmpty else { continue }
                after = value
                if ChannelStrip.routingMatches(item: value, requested: step.target) { break }
            }
            let landed = ChannelStrip.routingMatches(item: after, requested: step.target)
            results[step.key] = [
                "before": before,
                "requested": step.target,
                "menu_item_pressed": pressed,
                "after": after,
                "state": landed ? "confirmed" : "unverified"
            ] as [String: Any]
            guard landed else {
                throw LogicianError.verificationFailed(
                    requested: "\(step.key) = \(step.target)",
                    actual: "the slot reads '\(after)' after pressing '\(pressed)'",
                    restored: false
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

    private func openSlotMenu(_ slot: AXUIElement) -> [AXUIElement] {
        for _ in 0..<5 {
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
            _ = AXUIElementPerformAction(slot, kAXPressAction as CFString)
            for _ in 0..<15 {
                Thread.sleep(forTimeInterval: 0.1)
                let menus = popupMenus()
                if !menus.isEmpty { return menus }
            }
        }
        return []
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
        let menus = openSlotMenu(slot)
        defer {
            dismissPopupMenus()
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let menu = menus.first else {
            throw LogicianError.openVerificationFailed("the routing slot's menu did not open")
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

    /// Opens a routing slot's menu and presses the item the caller named.
    /// Returns the exact title pressed. The menu is dismissed on every failure
    /// path, because an open menu swallows Logic's keyboard.
    @discardableResult
    func chooseRouting(slot: AXUIElement, titled requested: String) throws -> String {
        let menus = openSlotMenu(slot)
        guard let menu = menus.first else {
            throw LogicianError.openVerificationFailed("the routing slot's menu did not open")
        }
        var target: AXUIElement?
        var titles: [String] = []
        walk(from: menu, maximumDepth: AXDepth.routingMenuItem) { element in
            guard stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem" else {
                return .descend
            }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            guard !title.isEmpty else { return .descend }
            titles.append(title)
            if target == nil, ChannelStrip.routingMatches(item: title, requested: requested) {
                target = element
            }
            return .descend
        }
        guard let item = target else {
            dismissPopupMenus()
            Thread.sleep(forTimeInterval: 0.25)
            throw LogicianError.parameterNotFound(
                "routing destination '\(requested)'. The slot offers: \(titles.prefix(40).joined(separator: ", "))"
                    + (titles.count > 40 ? ", … (\(titles.count) in all)" : "")
            )
        }
        let title = stringAttribute(item, kAXTitleAttribute as String)
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            dismissPopupMenus()
            Thread.sleep(forTimeInterval: 0.25)
            throw LogicianError.writeFailed(
                "pressing '\(title)' in the routing menu returned AXError \(status.rawValue)"
            )
        }
        Thread.sleep(forTimeInterval: 0.45)
        // A menu that stayed up after a successful press is a menu that ate
        // the press; never leave one open.
        if !popupMenus().isEmpty {
            dismissPopupMenus()
            Thread.sleep(forTimeInterval: 0.25)
        }
        return title
    }
}
