import AppKit
import ApplicationServices
import Foundation

// MARK: - Writing an insert's bypass state

extension LogicAccessibility {

    /// Bypasses or un-bypasses one insert on a channel strip, with the same
    /// checkbox `logic_list_inserts` already READS as the readback.
    ///
    /// The asymmetry this closes (COVERAGE G36) was the plainest in the surface:
    /// `insertSlots` has been reporting `bypassed` off an `AXCheckBox` described
    /// `bypass` since the first insert listing shipped, and nothing could write
    /// it — while bypass-and-listen is the fastest honest A/B in mixing and
    /// costs a fraction of `logic_evaluate_change`'s fifteen-plus seconds.
    ///
    /// ROUTING. The strip is resolved by `stripForControls`, so a track is
    /// selected first and a headerless strip (`Stereo Out`, an aux, a bus) is
    /// addressed by name in whichever inspector is showing it — the same rule,
    /// and the same limitation, as every other Accessibility-plane strip tool.
    ///
    /// COMPARE-AND-SET. `expectedCurrentBypassed` refuses before the press when
    /// reality disagrees. Without it an already-correct state is a verified
    /// no-op (`already_bypassed` / `already_active`), never a blind toggle: this
    /// control has no absolute write, only `AXPress`, so pressing without
    /// reading first would be a coin flip.
    func setInsertBypass(
        trackName: String,
        trackNumber: Int?,
        pluginName: String?,
        insertIndex: Int?,
        bypassed: Bool,
        expectedCurrentBypassed: Bool?
    ) throws -> [String: Any] {
        let routed = try stripForControls(trackName: trackName, trackNumber: trackNumber)
        let slots = insertSlots(of: routed.strip)
        let slot = try resolveInsertSlot(
            slots, track: trackName, plugin: pluginName, index: insertIndex
        )
        guard let checkbox = bypassCheckBox(of: slot) else {
            throw LogicianError.trackNotExposed(
                requested: "the bypass checkbox of insert \(slot.index) ('\(slot.name)')",
                exposed: "the slot publishes no bypass control"
            )
        }
        let before = stringAttribute(checkbox, kAXValueAttribute as String) == "1"
        if let expected = expectedCurrentBypassed, expected != before {
            throw LogicianError.currentValueMismatch(
                expected: expected ? "bypassed" : "active",
                actual: before ? "bypassed" : "active"
            )
        }
        var payload: [String: Any] = [
            "track": trackName,
            "track_name": trackName,
            "insert_index": slot.index,
            "plugin_display_name": slot.name,
            "before": before,
            "requested": bypassed,
            "write_route": "accessibility_bypass_checkbox",
            "readback_route": "accessibility_bypass_checkbox",
            "note": "insert_index is the ACCESSIBILITY ordinal from logic_list_inserts, not the"
                + " Mackie insert_slot the logic_mcu_* tools take."
        ]
        payload["selection_route"] = routed.plane.rawValue
        if before == bypassed {
            payload["success"] = true
            payload["verified"] = true
            payload["state"] = bypassed ? "already_bypassed" : "already_active"
            payload["after"] = before
            return payload
        }
        let status = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed(
                "the bypass checkbox refused AXPress (AXError \(status.rawValue))"
            )
        }
        // The strip repaints; re-read the SLOT rather than the captured element,
        // because a repaint can hand out new element references.
        var after = before
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let fresh = insertSlots(of: routed.strip).first(where: { $0.index == slot.index })
            else { continue }
            after = fresh.bypassed
            if after == bypassed { break }
        }
        payload["after"] = after
        payload["success"] = after == bypassed
        payload["verified"] = after == bypassed
        payload["state"] = after == bypassed
            ? (bypassed ? "bypassed" : "active")
            : "failed"
        if after != bypassed {
            throw LogicianError.verificationFailed(
                requested: "insert \(slot.index) ('\(slot.name)') \(bypassed ? "bypassed" : "active")",
                actual: "the checkbox still reads \(after ? "bypassed" : "active")",
                restored: true
            )
        }
        return payload
    }

    /// The `AXCheckBox` described `bypass` inside an insert slot's group — the
    /// element `insertSlots` reads and this writes.
    private func bypassCheckBox(of slot: InsertSlot) -> AXUIElement? {
        children(of: slot.group).first {
            stringAttribute($0, kAXRoleAttribute as String) == "AXCheckBox"
                && stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.bypass
        }
    }

    /// Like `resolveSlot`, but the plugin name is OPTIONAL: an index alone is a
    /// complete address (that is what `logic_list_inserts` numbers), and a name
    /// alone is too when it is unique. Given both, the name must match the slot
    /// — the same mismatch guard `resolveSlot` applies, because addressing the
    /// wrong insert is the failure class this repo cares most about.
    func resolveInsertSlot(
        _ slots: [InsertSlot], track: String, plugin: String?, index: Int?
    ) throws -> InsertSlot {
        if let plugin, !plugin.isEmpty {
            return try resolveSlot(slots, track: track, plugin: plugin, index: index)
        }
        guard let index else {
            throw LogicianError.invalidArguments(
                "name the insert: pass plugin_name, insert_index, or both"
            )
        }
        guard let slot = slots.first(where: { $0.index == index }) else {
            throw LogicianError.insertNotFound(
                track: track, plugin: "insert \(index)",
                available: slots.map { "\($0.index): \($0.name)" }
            )
        }
        return slot
    }
}
