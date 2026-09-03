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

    /// Which witness answered "is this track armed?", and what it said.
    enum ArmReading: Equatable {
        /// The track header's Record Enable checkbox, which names the TRACK.
        case accessibility(Bool)
        /// The strip's record-ready LED, watched across a blink cycle. It can
        /// only say "some strip at this position", so it is the fallback.
        case ledWindow(Bool)

        var armed: Bool {
            switch self {
            case .accessibility(let value), .ledWindow(let value): return value
            }
        }

        var readbackRoute: String {
            switch self {
            case .accessibility: return "ax_record_enable_checkbox"
            case .ledWindow: return "mcu_rec_led_window"
            }
        }
    }

    /// The pre-press read, and the whole reason a defensive compare-and-set on
    /// this tool used to cost 2.2–3.6 s.
    ///
    /// `ledWindow` is an `@autoclosure` ON PURPOSE. The two witnesses used to
    /// be bound by separate `let`s and combined with `??`, so the LED window
    /// ran in full on every single call and its answer was thrown away
    /// whenever the checkbox had already spoken — which was 4 out of 4 live
    /// calls, at 229–1 651 ms each (measured 2026-09-03; on one pure no-op it
    /// was 46% of a 3 604 ms response). Making the fallback a closure moves
    /// "skipped, not merely unread" into the signature, where re-splitting a
    /// `??` cannot quietly undo it.
    ///
    /// The union rule the LED path needs is unchanged and lives in
    /// `recArmObserved`: one sighting proves armed, only a whole quiet window
    /// proves disarmed.
    static func armReading(
        accessibility: Bool?, ledWindow: @autoclosure () -> Bool
    ) -> ArmReading {
        if let accessibility { return .accessibility(accessibility) }
        return .ledWindow(ledWindow())
    }

    /// What proved a record-arm press landed. Same rule, same laziness, on the
    /// other side of the button: the guard is an OR, so once the checkbox
    /// agrees BY NAME there is nothing a 1.6 s window proving "this strip's
    /// LED is dark" could add.
    enum ArmProof: Equatable {
        case accessibility
        case ledWindow
        /// Neither witness reached the requested state: the press is undone.
        case neither
    }

    static func armProof(
        accessibilityAgrees: Bool, ledWindow: @autoclosure () -> Bool
    ) -> ArmProof {
        if accessibilityAgrees { return .accessibility }
        return ledWindow() ? .ledWindow : .neither
    }

    /// The track header's own Record Enable checkbox — an independent source
    /// that NAMES the track, so a press that landed on the wrong strip cannot
    /// pass. nil when Accessibility cannot see that header (scrolled out, a
    /// headerless strip, or the AX layer degraded), which is never a reason to
    /// fail a write the surface proved.
    ///
    /// `alreadyWalkedRows` is the caller's own `parsedTrackHeaders()` result,
    /// handed down rather than re-asked for. `setRecordArm` walks that tree for
    /// its headerless-strip guard and used to make this function walk it AGAIN
    /// for the before-read and a THIRD time for the after-read — 40–103 ms
    /// each, measured 2026-09-03. A row list that no longer answers (a stale
    /// element after a repaint) still falls back to a fresh walk, so reuse can
    /// only save time, never cost an answer.
    ///
    /// A checkbox that will not report its value at all is `nil`, not `false`:
    /// "unreadable" and "disarmed" are different facts, and the caller's LED
    /// window is there for exactly the first one.
    static func axRecordEnabled(
        logic: LogicAccessibility,
        trackName: String,
        alreadyWalkedRows: [LogicAccessibility.TrackHeader] = []
    ) -> Bool? {
        func read(_ rows: [LogicAccessibility.TrackHeader]) -> Bool? {
            guard let header = rows.first(where: { $0.name == trackName }),
                  let box = logic.children(of: header.item).first(where: {
                      logic.stringAttribute($0, kAXDescriptionAttribute as String) == "Record Enable"
                  })
            else { return nil }
            // `stringAttribute` answers "" for an attribute it could not read,
            // and "unreadable" is not "disarmed": the caller's LED window
            // exists for exactly that case, so nil goes back rather than false.
            let value = logic.stringAttribute(box, kAXValueAttribute as String)
            return value.isEmpty ? nil : value == "1"
        }
        if !alreadyWalkedRows.isEmpty, let answer = read(alreadyWalkedRows) { return answer }
        return read((try? logic.parsedTrackHeaders()) ?? [])
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

        // Accessibility names the track, so it wins; the LED can only say
        // "some strip at this position". It is therefore the FALLBACK, and
        // this line is the whole difference between a 2.2–3.6 s call and a
        // fast one: the two used to be bound by separate `let`s, so the LED
        // window ran in full on every call and `??` threw its answer away
        // whenever the checkbox had already spoken — which was 4 out of 4 live
        // calls, at 229–1 651 ms each (measured 2026-09-03). Written inline it
        // short-circuits, and the window runs only when nothing else can
        // answer: a scrolled-out or headerless-rendered track, where the LED
        // is the only evidence there is.
        let reading = armReading(
            accessibility: axRecordEnabled(
                logic: logic, trackName: trackName, alreadyWalkedRows: headers
            ),
            ledWindow: recArmObserved(channel: channel)
        )
        if reading.armed == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "armed" : "disarmed"),
                "track": trackName, "track_name": trackName,
                "record_armed": enabled,
                "mcu_strip": channel + 1,
                "route": "mcu",
                "readback_route": reading.readbackRoute
            ]
        }

        let events = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(.press(note: 0x00 + channel))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU record-arm press failed: \(response.error ?? "?")")
        }
        _ = awaitEvents(since: events, timeoutMs: 800)

        // The same order as the pre-press read, for the same reason: the
        // checkbox names the TRACK, the guard below is an OR, and a 1.6 s
        // quiet window proving "this strip's LED is dark" adds nothing once
        // Accessibility has said the named track is disarmed. So ask
        // Accessibility first and spend the window only when it cannot answer.
        var axAfter: Bool?
        for _ in 0..<8 {
            axAfter = axRecordEnabled(
                logic: logic, trackName: trackName, alreadyWalkedRows: headers
            )
            if axAfter == enabled { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let axAgrees = axAfter == enabled
        // Positive evidence for armed; a whole quiet window for disarmed —
        // and neither is watched at all when the checkbox already agrees.
        let proof = armProof(
            accessibilityAgrees: axAgrees,
            ledWindow: enabled
                ? recArmObserved(channel: channel, window: 2.5)
                : !recArmObserved(channel: channel, window: recBlinkWindow)
        )
        guard proof != .neither else {
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
            "readback_route": proof == .accessibility
                ? "ax_record_enable_checkbox" : "mcu_rec_led_window",
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
