import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// Record-arm: the intent that ended persona (c) at its second sentence.
//
// COVERAGE's open question 1 asked whether Logic's rec/ready buttons really are
// MCU notes 0x00–0x07 and whether their LEDs echo. Both answered yes, live, on
// 2026-08-28 — but with a wrinkle worth more than the answer: an armed strip's
// LED FLASHES rather than staying lit (~640 ms on, ~640 ms off). Every read here
// is therefore a window over at least one blink cycle, and the evidence is
// asymmetric in the direction that cannot lie: one sighting proves armed, and
// only a whole quiet window is allowed to mean disarmed.

extension MCUController {

    /// Whether the strip's record-ready LED was seen lit within one blink cycle.
    static func recArmObserved(channel: Int, window: TimeInterval = recBlinkWindow) -> Bool {
        let deadline = Date().addingTimeInterval(window)
        repeat {
            if let status = freshStatus(), ledLit(0x00 + channel, in: status) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    /// The track header's own Record Enable checkbox — an independent source
    /// that NAMES the track, so a press that landed on the wrong strip cannot
    /// pass. nil when Accessibility cannot see that header (scrolled out, a
    /// headerless strip, or the AX layer degraded), which is never a reason to
    /// fail a write the surface proved.
    static func axRecordEnabled(logic: LogicAccessibility, trackName: String) -> Bool? {
        guard let header = ((try? logic.parsedTrackHeaders()) ?? [])
            .first(where: { $0.name == trackName }) else { return nil }
        guard let box = logic.children(of: header.item).first(where: {
            logic.stringAttribute($0, kAXDescriptionAttribute as String) == "Record Enable"
        }) else { return nil }
        return logic.stringAttribute(box, kAXValueAttribute as String) == "1"
    }

    /// Arms or disarms a track for recording. Compare-and-set: an already
    /// correct state is reported and nothing is pressed.
    ///
    /// Refuses a strip with no track header BEFORE pressing anything: arming is
    /// a track property, an output/aux/bus strip has none, and the surface
    /// simply ignores the press there (verified 2026-08-28 on `Stereo Out` — no
    /// LED, no state change), which would otherwise look like a failed write.
    static func setRecordArm(
        logic: LogicAccessibility,
        trackName: String,
        trackNumber: Int?,
        enabled: Bool
    ) throws -> [String: Any] {
        try requireSurface(
            "record-arm for '\(trackName)'",
            consequence: "Record-arm has no Accessibility-only route in this server, so nothing"
                + " was read or pressed"
        )
        // Headerless strips are refused up front. `parsedTrackHeaders` sees only
        // the RENDERED rows, so an empty list means "cannot tell", not "not a
        // track" — refusing on that would break a scrolled-out but perfectly
        // armable track, and the LED check below still catches a strip that
        // ignores the press.
        let headers = (try? logic.parsedTrackHeaders()) ?? []
        if !headers.isEmpty, isKnownHeaderlessName(trackName, headers: headers) {
            throw LogicianError.trackNotExposed(
                requested: "record-arm on '\(trackName)'",
                exposed: "that strip has no track header — output, aux, bus and master strips cannot be"
                    + " record-armed, and the control surface silently ignores the press on them"
                    + " (verified 2026-08-28 on 'Stereo Out'). Nothing was pressed."
            )
        }
        if let number = trackNumber {
            _ = try logic.selectTrack(trackName: trackName, trackNumber: number, expectedProjectPath: nil)
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw headerlessStripError(
                name: trackName,
                resolution: lastChannelResolution,
                visibleTracks: headers.map(\.name),
                trackMiss: .trackNotFound(trackName, available: headers.map(\.name))
            )
        }
        // findChannel leaves the surface banked at the match in the pan-names
        // view, where the cells ARE painted — prove the strip before pressing,
        // the same third question `selectChannelVerified` asks, but without
        // touching the project-wide selection (arming does not need it).
        guard let top = freshStatus()?["lcd_top"] as? String,
              lcdAbbreviationPlausible(track: trackName, lcd: lcdFields(top)[channel]) else {
            throw LogicianError.verificationFailed(
                requested: "strip \(channel + 1) showing '\(trackName)'",
                actual: "it shows '\(lcdFields(freshStatus()?["lcd_top"] as? String ?? "")[channel])'"
                    + " — the surface is banked somewhere else; nothing was pressed",
                restored: true
            )
        }

        let axBefore = axRecordEnabled(logic: logic, trackName: trackName)
        let ledBefore = recArmObserved(channel: channel)
        // Accessibility names the track, so it wins when the two disagree; the
        // LED can only say "some strip at this position".
        let current = axBefore ?? ledBefore
        if current == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "armed" : "disarmed"),
                "track": trackName, "track_name": trackName,
                "record_armed": enabled,
                "mcu_strip": channel + 1,
                "route": "mcu",
                "readback_route": axBefore != nil ? "ax_record_enable_checkbox" : "mcu_rec_led_window"
            ]
        }

        let events = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(.press(note: 0x00 + channel))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU record-arm press failed: \(response.error ?? "?")")
        }
        _ = awaitEvents(since: events, timeoutMs: 800)

        // Positive evidence for armed; a whole quiet window for disarmed.
        let ledAfter = enabled
            ? recArmObserved(channel: channel, window: 2.5)
            : !recArmObserved(channel: channel, window: recBlinkWindow)
        var axAfter: Bool?
        for _ in 0..<8 {
            axAfter = axRecordEnabled(logic: logic, trackName: trackName)
            if axAfter == enabled { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let axAgrees = axAfter == enabled
        guard ledAfter || axAgrees else {
            // Put it back: a press that changed nothing observable is still a
            // press, and leaving an unproven arm behind is the one state a
            // vocal session must not start from.
            _ = try? MCUBridge.send(.press(note: 0x00 + channel))
            throw LogicianError.verificationFailed(
                requested: "record_armed=\(enabled) on '\(trackName)' (strip \(channel + 1))",
                actual: "neither the record LED"
                    + (axAfter == nil ? "" : " nor the track header's Record Enable checkbox")
                    + " reached that state; the press was undone",
                restored: true
            )
        }
        var result: [String: Any] = [
            "success": true, "verified": true,
            "state": enabled ? "armed" : "disarmed",
            "track": trackName, "track_name": trackName,
            "record_armed": enabled,
            "mcu_strip": channel + 1,
            "route": "mcu",
            "write_route": "mcu_rec_ready_button",
            "readback_route": axAgrees
                ? (ledAfter ? "mcu_rec_led_window_and_ax_checkbox" : "ax_record_enable_checkbox")
                : "mcu_rec_led_window",
            "cross_check": axAfter == nil ? "unavailable" : (axAgrees ? "ax_record_enable_checkbox" : "disagreed")
        ]
        if axAfter == nil {
            appendWarning(
                "The independent Accessibility cross-check could not run: no rendered track header"
                    + " named '\(trackName)' is on screen. The arm state is confirmed only by Logic's"
                    + " own record LED on the strip whose LCD cell matched the name.",
                to: &result
            )
        }
        if enabled {
            appendWarning(
                "Logic allows several tracks to be armed at once (verified 2026-08-28), so this did"
                    + " not disarm anything else. Read logic_mixer_snapshot if you need to know what"
                    + " else is armed before you roll.",
                to: &result
            )
        }
        return result
    }

    /// True when the name is one the surface knows but the track headers do
    /// not — the signature of an output/aux/bus/master strip. Deliberately
    /// conservative: it says yes only when the bank map HAS the name, so an
    /// unknown name still travels to `findChannel` and gets its own error.
    static func isKnownHeaderlessName(
        _ name: String, headers: [LogicAccessibility.TrackHeader]
    ) -> Bool {
        guard let cached = loadBankCache(projectPath: currentProjectPath()) else { return false }
        let matches = channelMatches(name: name, bankTops: cached)
        guard matches.count == 1 else { return false }
        return !headers.contains { $0.name == name }
    }
}
