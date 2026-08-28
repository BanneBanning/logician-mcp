import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Tempo write (control bar slider, rapid-fire stepwise)

    /// Sets the project tempo by converging the control bar's Tempo slider.
    /// The slider steps ±1 BPM per AXValue write regardless of the target,
    /// but accepts writes every ~8 ms, so even a doubling converges in ~1.3 s.
    func setTempo(_ target: Double) throws -> Double {
        guard target >= 5, target <= 990 else {
            throw LogicianError.invalidArguments("tempo must be 5-990 BPM")
        }
        let bar = try controlBarGroup()
        guard let inner = children(of: bar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }), let slider = children(of: inner).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Tempo"
        }) else {
            throw LogicianError.windowNotFound("Tempo slider in the control bar")
        }
        let goal = Double(Int(target.rounded()))
        let deadline = Date().addingTimeInterval(25)
        var lastValue = Double(stringAttribute(slider, kAXValueAttribute as String)) ?? -1
        var stuckCount = 0
        while Date() < deadline {
            guard let current = Double(stringAttribute(slider, kAXValueAttribute as String)) else {
                break
            }
            if abs(current - goal) < 0.5 { return current }
            _ = AXUIElementSetAttributeValue(
                slider, kAXValueAttribute as CFString, Int(goal) as CFNumber
            )
            usleep(8000)
            if current == lastValue {
                stuckCount += 1
                if stuckCount > 40 { break }
            } else {
                stuckCount = 0
            }
            lastValue = current
        }
        let final = Double(stringAttribute(slider, kAXValueAttribute as String)) ?? -1
        guard abs(final - goal) < 0.5 else {
            throw LogicianError.verificationFailed(
                requested: "tempo \(Int(goal)) BPM",
                actual: "tempo stuck at \(final)",
                restored: false
            )
        }
        return final
    }

    // MARK: - Project tempo mode (Smart Tempo write-protection)

    /// Reads Logic's project tempo mode (Smart Tempo: Keep / Adapt / Auto) off
    /// the control bar's Project Tempo pop-up button — the small control the
    /// LCD draws right under the tempo.
    ///
    /// PROBE RESULT (2026-08-27, Logic Pro 12.3.1, LCD Display Mode
    /// "Beats & Project" — the view that *does* show the mode): the button is
    /// there, as a direct sibling of the `Tempo` slider inside the inner
    /// "Control Bar" group, and it carries NO value of any kind. Its whole
    /// attribute set is geometry plus `AXHelp`; `AXValue`, `AXTitle` and
    /// `AXValueDescription` are absent and `AXDescription` is the empty string,
    /// which is also why it can only be identified by its help text. The
    /// neighbouring Time Signature and Key Signature pop-ups DO publish their
    /// `AXValue` ("4/4", "B♭ Major"), so this is Logic withholding the value,
    /// not this walk missing it.
    ///
    /// So `.unreadable` is what this returns in practice today. The three real
    /// modes are the path for the day Logic starts publishing the value, and
    /// they are covered by tests of `normalizedProjectTempoMode` rather than by
    /// a live observation — an honest distinction, not a verified one.
    ///
    /// Deliberately NOT done: the button offers `AXShowMenu`/`AXPress`, and an
    /// opened menu would presumably mark its active item. That is a UI mutation
    /// on a read path, and this function's caller is the arming step of a
    /// recording, where a stray open menu can swallow the transport. Making the
    /// mode readable that way — and then settable, which would upgrade the
    /// refusal to a guarded set-and-restore — is the next experiment.
    func projectTempoMode() -> ProjectTempoMode {
        guard let bar = try? controlBarGroup(),
              let inner = children(of: bar).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
              }) else {
            return .absent
        }
        return projectTempoMode(inControlBar: inner)
    }

    /// The same read against an already-resolved inner "Control Bar" group, so
    /// `getTransport` does not walk the window twice.
    func projectTempoMode(inControlBar inner: AXUIElement) -> ProjectTempoMode {
        guard let popup = children(of: inner).first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXPopUpButton"
                && stringAttribute($0, kAXHelpAttribute as String)
                    .hasPrefix("Project Tempo menu")
        }) else {
            return .absent
        }
        for name in [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXValueDescriptionAttribute as String
        ] {
            if let mode = normalizedProjectTempoMode(stringAttribute(popup, name)) {
                return mode
            }
        }
        return .unreadable
    }

    // MARK: - Two-point tempo sampling (is the tempo constant across a range?)

    /// The control bar's Tempo value — the tempo AT THE PLAYHEAD POSITION, which
    /// is the whole basis of the sampling below. Cheap on purpose: one control
    /// bar walk, none of `getTransport`'s document read.
    func controlBarTempo() -> Double? {
        guard let bar = try? controlBarGroup(),
              let inner = children(of: bar).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
              }),
              let slider = children(of: inner).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == "Tempo"
              }) else { return nil }
        return Double(stringAttribute(slider, kAXValueAttribute as String))
    }

    /// Parks the playhead at `firstBar`, reads the tempo, parks at `secondBar`,
    /// reads again, and puts the playhead back where it was — on the error path
    /// too. Returns a verdict, never throws: a tool that works today must not
    /// start failing because a *check* could not run, so an impossible sample is
    /// reported as `.unverified` and the caller warns instead of refusing.
    ///
    /// COST: `setPlayhead` converges Logic's LCD bar field one step per write
    /// (~0.12 s), so two ends 30 bars apart cost a few seconds and a range far
    /// from the current playhead costs more. That is why this is called at most
    /// once per tool invocation, and never on the paths that hand Logic bar
    /// numbers instead of slicing seconds themselves.
    ///
    /// SAFETY: it never moves a playhead it cannot put back — with no readable
    /// position to restore, it returns `.unverified` before touching anything.
    func sampleTempo(firstBar: Int, secondBar: Int) -> TempoSample {
        let cannotSample = "the tempo could not be sampled at bars \(firstBar) and \(secondBar)"
        guard let controlBar = try? controlBarGroup(),
              let lcd = playheadGroup(in: controlBar),
              let savedBar = sliderValue(lcd, "bar") else {
            return .verdict(.unverified(
                reason: "\(cannotSample): the control bar reports no playhead position, and the"
                    + " playhead is never moved when it cannot be put back"
            ))
        }
        let savedBeat = sliderValue(lcd, "beat")
        func read(at bar: Int) throws -> Double {
            _ = try setPlayhead(barNumber: bar, beat: nil)
            guard let tempo = controlBarTempo() else {
                throw LogicianError.trackNotExposed(
                    requested: "the control bar tempo with the playhead at bar \(bar)",
                    exposed: "the Tempo display published no value"
                )
            }
            return tempo
        }
        func restore() -> String? {
            guard (try? setPlayhead(barNumber: savedBar, beat: savedBeat)) == nil else { return nil }
            return "THE PLAYHEAD WAS NOT PUT BACK: the tempo check moved it to sample the tempo"
                + " and could not return it to bar \(savedBar)"
                + (savedBeat.map { ", beat \($0)" } ?? "") + " — move it yourself before"
                + " anything that depends on the playhead position."
        }
        let startTempo: Double
        let endTempo: Double
        do {
            startTempo = try read(at: firstBar)
            endTempo = try read(at: secondBar)
        } catch {
            let leak = restore()
            return TempoSample(
                sample: .unverified(
                    reason: "\(cannotSample): \(error.localizedDescription)"
                ),
                playheadLeak: leak
            )
        }
        let span = TempoSpan(
            startBar: firstBar, endBar: secondBar,
            startTempo: startTempo, endTempo: endTempo
        )
        return TempoSample(
            sample: span.isConstant ? .constant(span) : .varying(span),
            playheadLeak: restore()
        )
    }

    /// Is the tempo constant across the bars a tool is about to slice into
    /// seconds? Both ends of the range are the sample points, because both ends
    /// are what the `(bar - 1) x beats x 60/BPM` math places.
    func sampleTempoAcross(startBar: Int, endBar: Int) -> TempoSample {
        // Callers reach this through `barRangeSeconds`, which already refuses a
        // range that is not at least one bar long; a degenerate range would
        // sample the same bar twice and prove nothing, so say that instead of
        // inventing a verdict.
        guard endBar > startBar else {
            return .verdict(.unverified(
                reason: "bars \(startBar) and \(endBar) are not two different points, so the"
                    + " tempo could not be compared across the range"
            ))
        }
        return sampleTempo(firstBar: startBar, secondBar: endBar)
    }

    /// Does this project have a tempo map at all? The question `logic_set_tempo`
    /// has to answer before writing a slider that only governs one tempo node.
    ///
    /// The second sample point is BAR 1 — the project's first tempo node, the
    /// one point every project has, and the one a mapped project is most likely
    /// to differ from. (A playhead already at bar 1 samples bar 2 instead: two
    /// reads of the same bar sense nothing.) It is not a proof — a map that
    /// happens to be back at its bar-1 value where the playhead sits reads as
    /// constant here — and the refusal built on it says only what it knows.
    func sampleTempoAgainstProjectStart() -> TempoSample {
        guard let controlBar = try? controlBarGroup(),
              let lcd = playheadGroup(in: controlBar),
              let playheadBar = sliderValue(lcd, "bar") else {
            return .verdict(.unverified(
                reason: "the tempo could not be sampled at a second bar: the control bar reports"
                    + " no playhead position, and the playhead is never moved when it cannot be"
                    + " put back"
            ))
        }
        let secondBar = playheadBar == 1 ? 2 : 1
        return sampleTempo(firstBar: playheadBar, secondBar: secondBar)
    }

    // MARK: - Transport

    func getTransport() throws -> [String: Any] {
        let bar = try controlBarGroup()
        var result: [String: Any] = [
            "project_document": (try? projectDocumentPath()) ?? NSNull()
        ]
        let checkboxes = [
            ("playing", "Play"), ("recording", "Record"), ("cycle", "Cycle"),
            ("metronome", "Metronome Click"), ("count_in", "Count In"), ("solo_mode", "Solo")
        ]
        for (key, description) in checkboxes {
            result[key] = controlBarChild(bar, description).map {
                stringAttribute($0, kAXValueAttribute as String) == "1"
            } ?? NSNull()
        }
        if result["cycle"] is NSNull, let rulerCycle = cycleStateFromRuler() {
            // Narrow windows collapse the Cycle button; the ruler still knows.
            result["cycle"] = rulerCycle
            result["cycle_source"] = "ruler_cycle_region"
        }
        if let lcd = playheadGroup(in: bar) {
            result["playhead_bar"] = sliderValue(lcd, "bar") ?? NSNull()
            result["playhead_beat"] = sliderValue(lcd, "beat") ?? NSNull()
        }
        if let inner = children(of: bar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }) {
            result["tempo"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Tempo" }
                .flatMap { Double(stringAttribute($0, kAXValueAttribute as String)) } ?? NSNull()
            result["time_signature"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Time Signature" }
                .map { stringAttribute($0, kAXValueAttribute as String) } ?? NSNull()
            result["key_signature"] = children(of: inner)
                .first { stringAttribute($0, kAXDescriptionAttribute as String) == "Key Signature" }
                .map { stringAttribute($0, kAXValueAttribute as String) } ?? NSNull()
            // Smart Tempo: which mode a recording will apply to the project's
            // tempo map. The key is present only when the mode is actually
            // known — an unreadable mode reported as a value would read as
            // "keep", and Adapt is the one that rewrites the tempo track.
            let tempoMode = projectTempoMode(inControlBar: inner)
            if let name = tempoMode.name {
                result["project_tempo_mode"] = name
            } else if let explanation = tempoMode.explanation {
                result["project_tempo_mode_note"] = explanation
            }
        }
        return result
    }

    func setCycle(enabled: Bool) throws -> [String: Any] {
        if controlBarChild(try controlBarGroup(), "Cycle") != nil {
            return try setTransportCheckbox(
                description: "Cycle",
                key: "cycle",
                desired: enabled,
                onState: "cycle_on",
                offState: "cycle_off"
            )
        }
        // Narrow windows collapse the Cycle button out of the control bar;
        // fall back to the C key command, verified via the ruler's cycle region.
        guard let current = cycleStateFromRuler() else {
            throw LogicianError.windowNotFound("Cycle button in the control bar and cycle region in the ruler")
        }
        if current == enabled {
            return [
                "success": true,
                "verified": true,
                "state": "already_" + (enabled ? "cycle_on" : "cycle_off"),
                "cycle": enabled
            ]
        }
        try sendKeystrokeToFrontmostLogic(virtualKey: 8, label: "C (cycle)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if cycleStateFromRuler() == enabled {
                return [
                    "success": true,
                    "verified": true,
                    "state": enabled ? "cycle_on" : "cycle_off",
                    "cycle": enabled,
                    "write_route": "key_command_c_frontmost",
                    "readback_route": "ruler_cycle_region"
                ]
            }
        }
        throw LogicianError.verificationFailed(requested: "cycle=\(enabled)", actual: "cycle=\(current)", restored: false)
    }

    func cycleStateFromRuler() -> Bool? {
        guard let ruler = try? rulerArea(),
              let region = rulerChild(ruler, "cycle region") else { return nil }
        switch stringAttribute(region, kAXValueDescriptionAttribute as String)
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    func setPlaying(playing: Bool) throws -> [String: Any] {
        if playing {
            // Pressing the Play checkbox starts playback, but pressing it again
            // does NOT stop (verified 2026-08-24), so only the start path uses it.
            return try setTransportCheckbox(
                description: "Play",
                key: "playing",
                desired: true,
                onState: "playing",
                offState: "stopped"
            )
        }

        let bar = try controlBarGroup()
        guard let play = controlBarChild(bar, "Play") else {
            throw LogicianError.windowNotFound("Play button in the control bar")
        }
        guard stringAttribute(play, kAXValueAttribute as String) == "1" else {
            return [
                "success": true,
                "verified": true,
                "state": "already_stopped",
                "playing": false
            ]
        }

        // Stop has no control bar button in this layout and no plain menu item;
        // the working route is the space key command, sent only after verifying
        // that Logic is the frontmost application.
        try sendKeystrokeToFrontmostLogic(virtualKey: 49, label: "space (play/stop)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if let refreshed = controlBarChild(try controlBarGroup(), "Play"),
               stringAttribute(refreshed, kAXValueAttribute as String) == "0" {
                return [
                    "success": true,
                    "verified": true,
                    "state": "stopped",
                    "playing": false,
                    "write_route": "key_command_space_frontmost"
                ]
            }
        }
        throw LogicianError.verificationFailed(requested: "playing=false", actual: "playing=true", restored: false)
    }

    func sendKeystrokeToFrontmostLogic(virtualKey: CGKeyCode, label: String) throws {
        try ensureLogicFrontmost(for: label)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw LogicianError.writeFailed("could not create keyboard events for \(label)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
    }

    func setPlayhead(barNumber: Int, beat: Int?) throws -> [String: Any] {
        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar) else {
            throw LogicianError.windowNotFound("Playhead Position display in the control bar")
        }
        let beforeBar = sliderValue(lcd, "bar")
        let beforeBeat = sliderValue(lcd, "beat")

        try convergeSlider(in: controlBar, sliderName: "bar", target: barNumber)
        if let beat = beat {
            try convergeSlider(in: controlBar, sliderName: "beat", target: beat)
        }

        guard let refreshed = playheadGroup(in: try controlBarGroup()),
              let afterBar = sliderValue(refreshed, "bar"),
              afterBar == barNumber,
              beat == nil || sliderValue(refreshed, "beat") == beat else {
            throw LogicianError.verificationFailed(
                requested: "bar \(barNumber)\(beat.map { ", beat \($0)" } ?? "")",
                actual: "bar \(sliderValue(lcd, "bar").map(String.init) ?? "?"), beat \(sliderValue(lcd, "beat").map(String.init) ?? "?")",
                restored: false
            )
        }

        return [
            "success": true,
            "verified": true,
            "state": "moved",
            "before": ["bar": beforeBar ?? -1, "beat": beforeBeat ?? -1],
            "after": ["bar": barNumber, "beat": beat ?? sliderValue(refreshed, "beat") ?? -1],
            "write_route": "ax_value_stepwise"
        ]
    }

    /// Presses one of the control bar's transport buttons by its
    /// `AXDescription` ("Go to Beginning", "Forward", "Rewind").
    func pressControlBarButton(_ description: String) throws {
        guard let button = controlBarChild(try controlBarGroup(), description) else {
            throw LogicianError.windowNotFound("'\(description)' button in the control bar")
        }
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed(
                "AXPress on '\(description)' returned AXError \(status.rawValue)"
            )
        }
    }

    /// Parks the playhead EXACTLY on a bar/beat — division and tick included —
    /// and proves it.
    ///
    /// Why this is not just `setPlayhead`: the control bar's position display
    /// publishes **two** sliders, `bar` and `beat`, and nothing below them
    /// (measured 2026-08-28), while both are RELATIVE steppers. So a
    /// sub-beat offset already in the playhead is carried along unchanged by
    /// every step, and a "verified bar 5, beat 1" can sit almost a whole beat
    /// late while the control bar happily reads `5 bars 1 beat`. Measured on
    /// the sandbox project: the MCU's own 10-digit display read `  5 1 4201`,
    /// `  6 1 4201`, `  9 1 4201` after three verified parkings — division 4,
    /// tick 201, i.e. 0.958 beats past the beat every time. That is the
    /// mechanism behind FINDINGS 2026-08-28 fynd 10, where a tempo event
    /// created "at bar 9" landed at `9 1 4 201`.
    ///
    /// The fix uses the one control that is ABSOLUTE: the control bar's `Go to
    /// Beginning` button, which puts the playhead on `1 1 1 1`. From a zero
    /// offset, stepping bars and beats keeps it zero. The MCU timecode is the
    /// sensor for both the before and the after, so `on_grid` is an
    /// observation, not a claim — and it is `null`, never `true`, when the
    /// surface cannot be read.
    func parkPlayheadOnGrid(bar: Int, beat: Int) throws -> [String: Any] {
        func residue() -> (division: Int, ticks: Int)? {
            guard case .beats(_, _, let division, let ticks) =
                MCUController.timecodeReading() else { return nil }
            return (division, ticks)
        }
        /// Divisions and ticks are ONE-based in Logic's display and the
        /// classifier reports a blank field as 0, so both values count as
        /// "exactly on the beat".
        func isZero(_ value: (division: Int, ticks: Int)?) -> Bool? {
            guard let value else { return nil }
            return value.division <= 1 && value.ticks <= 1
        }
        let before = residue()
        // Rewind when the offset is non-zero OR unknown: an unreadable
        // surface must not be treated as a clean playhead. It costs bar
        // stepping (~0.12 s per bar) and buys an exact cut.
        // Never rewind a ROLLING transport: `Go to Beginning` would throw the
        // playhead back to bar 1 and keep playing, which is a far bigger
        // surprise than an inexact cut. The offset is then reported as it is.
        let rolling = (MCUController.freshStatus()?["transport_leds"] as? [String: Any])?["play"]
            as? Bool ?? false
        var rewound = false
        if isZero(before) != true && !rolling {
            try pressControlBarButton("Go to Beginning")
            Thread.sleep(forTimeInterval: 0.4)
            rewound = true
        }
        _ = try setPlayhead(barNumber: bar, beat: beat)
        let after = residue()
        let group = playheadGroup(in: try controlBarGroup())
        var result: [String: Any] = [
            "bar": group.flatMap { sliderValue($0, "bar") } ?? bar,
            "beat": group.flatMap { sliderValue($0, "beat") } ?? beat,
            "rewound_first": rewound,
            "transport_rolling": rolling,
            "on_grid": isZero(after).map { $0 as Any } ?? NSNull() as Any
        ]
        if let after {
            result["timecode_division"] = after.division
            result["timecode_ticks"] = after.ticks
        } else {
            // Only claim the rewind when it actually happened: a ROLLING
            // transport is never rewound (that would throw the playhead back
            // to bar 1 mid-playback), and saying otherwise turns the one
            // sentence that justifies trusting the position into a fiction.
            result["on_grid_note"] = "the MCU position display could not be read, so whether the "
                + "playhead sits exactly on the beat is UNVERIFIED (the control bar publishes bars "
                + "and beats only). "
                + (rewound
                    ? "The playhead was rewound to the project start first, which is the state "
                        + "that makes stepping exact."
                    : rolling
                        ? "It was NOT rewound first, because the transport is rolling — so any "
                            + "sub-beat offset the playhead already carried is still there."
                        : "It was NOT rewound first, because it already read as being on the "
                            + "beat before the move.")
        }
        return result
    }

    func setTransportCheckbox(
        description: String,
        key: String,
        desired: Bool,
        onState: String,
        offState: String
    ) throws -> [String: Any] {
        let bar = try controlBarGroup()
        guard let checkbox = controlBarChild(bar, description) else {
            throw LogicianError.windowNotFound("\(description) button in the control bar")
        }
        let current = stringAttribute(checkbox, kAXValueAttribute as String) == "1"
        if current == desired {
            return [
                "success": true,
                "verified": true,
                "state": "already_" + (desired ? onState : offState),
                key: desired
            ]
        }
        let status = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        guard status == .success else {
            throw LogicianError.writeFailed("AXPress on \(description) returned AXError \(status.rawValue)")
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            guard let refreshed = controlBarChild(try controlBarGroup(), description) else { continue }
            if (stringAttribute(refreshed, kAXValueAttribute as String) == "1") == desired {
                return [
                    "success": true,
                    "verified": true,
                    "state": desired ? onState : offState,
                    key: desired,
                    "write_route": "ax_press"
                ]
            }
        }
        throw LogicianError.verificationFailed(
            requested: "\(description)=\(desired)",
            actual: "\(description)=\(current)",
            restored: false
        )
    }

    /// Logic's LCD sliders move exactly one step toward the requested value per
    /// AXValue write (verified 2026-08-24), so write repeatedly until convergence.
    func convergeSlider(in controlBar: AXUIElement, sliderName: String, target: Int) throws {
        guard let lcd = playheadGroup(in: controlBar),
              let slider = children(of: lcd).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == sliderName
              }),
              let start = Int(stringAttribute(slider, kAXValueAttribute as String)) else {
            throw LogicianError.windowNotFound("playhead \(sliderName) slider")
        }
        let maximumSteps = min(abs(target - start) + 4, 512)
        var last = start
        for _ in 0..<maximumSteps {
            guard let current = Int(stringAttribute(slider, kAXValueAttribute as String)) else { break }
            if current == target { return }
            let status = AXUIElementSetAttributeValue(
                slider,
                kAXValueAttribute as CFString,
                target as CFNumber
            )
            guard status == .success else {
                throw LogicianError.writeFailed("AXValue write on \(sliderName) returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.12)
            let after = Int(stringAttribute(slider, kAXValueAttribute as String)) ?? current
            if after == last && after != target {
                throw LogicianError.verificationFailed(
                    requested: "\(sliderName) \(target)",
                    actual: "\(sliderName) stuck at \(after)",
                    restored: false
                )
            }
            last = after
        }
        guard Int(stringAttribute(slider, kAXValueAttribute as String)) == target else {
            throw LogicianError.verificationFailed(
                requested: "\(sliderName) \(target)",
                actual: "\(sliderName) \(stringAttribute(slider, kAXValueAttribute as String))",
                restored: false
            )
        }
    }

    // MARK: - Cycle range (locators)

    func setCycleRange(startBar: Int, endBar: Int, enabled: Bool?) throws -> [String: Any] {
        guard startBar >= 1, endBar > startBar else {
            throw LogicianError.invalidArguments("start_bar must be >= 1 and end_bar > start_bar")
        }
        let targetLength = endBar - startBar

        let ruler = try rulerArea()
        guard let region = rulerChild(ruler, "cycle region") else {
            throw LogicianError.trackNotExposed(requested: "cycle region", exposed: "no cycle region in the ruler")
        }
        let originalLength = cycleLengthBars(region)

        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar),
              let savedBar = sliderValue(lcd, "bar"),
              let savedBeat = sliderValue(lcd, "beat") else {
            throw LogicianError.windowNotFound("Playhead Position display in the control bar")
        }
        defer {
            try? convergeSlider(in: controlBar, sliderName: "bar", target: savedBar)
            try? convergeSlider(in: controlBar, sliderName: "beat", target: savedBeat)
        }

        // Snapshot helper: Logic auto-scrolls the view when the playhead moves,
        // so the thumb and the region must always be read in the same instant
        // and never compared across playhead moves.
        func snapshot() throws -> (regionX: CGFloat, regionY: CGFloat, thumbX: CGFloat, slope: CGFloat, rulerFrame: CGRect) {
            let freshRuler = try rulerArea()
            guard let freshRegion = rulerChild(freshRuler, "cycle region"),
                  let thumb = rulerChild(freshRuler, "Playhead thumb") else {
                throw LogicianError.windowNotFound("cycle region or playhead thumb in the ruler")
            }
            let regionFrame = try frame(of: freshRegion)
            return (
                regionX: regionFrame.origin.x,
                regionY: regionFrame.origin.y,
                thumbX: try frame(of: thumb).origin.x,
                slope: try pixelsPerBar(in: freshRuler),
                rulerFrame: try frame(of: freshRuler)
            )
        }

        // Anchor calibration: park the playhead on the region's bar line so the
        // thumb identifies which bar the (grid-snapped) region sits on, and
        // measure the constant thumb-to-bar-line pixel offset.
        let initial = try snapshot()
        let approximateBar = try approximateBarAt(x: initial.regionX, in: try rulerArea())
        var anchor: (bar: Int, thumbOffset: CGFloat, regionX: CGFloat, slope: CGFloat)?
        for candidate in [approximateBar, approximateBar - 1, approximateBar + 1] where candidate >= 1 {
            try convergeSlider(in: controlBar, sliderName: "bar", target: candidate)
            try convergeSlider(in: controlBar, sliderName: "beat", target: 1)
            Thread.sleep(forTimeInterval: 0.15)
            let snap = try snapshot()
            if abs(snap.regionX - snap.thumbX) <= snap.slope * 0.55 {
                anchor = (
                    bar: candidate,
                    thumbOffset: snap.regionX - snap.thumbX,
                    regionX: snap.regionX,
                    slope: snap.slope
                )
                break
            }
        }
        guard let anchored = anchor else {
            throw LogicianError.openVerificationFailed(
                "Could not anchor the cycle region to a bar line via the playhead thumb."
            )
        }

        // Verified drag semantics in the cycle strip (2026-08-24): a drag that
        // STARTS on empty strip creates a new grid-snapped range from start to
        // end; a drag that starts inside the existing region MOVES it instead.
        // A pure AXPosition write moves the region start exactly one grid-snapped
        // bar landing. Combine them so the drag start never touches the region.
        let preDrag = try snapshot()
        let originBarX = preDrag.thumbX + anchored.thumbOffset // playhead is on the anchor bar
        func xForBar(_ bar: Int) -> CGFloat {
            originBarX + preDrag.slope * CGFloat(bar - anchored.bar)
        }
        let startX = xForBar(startBar)
        let endX = xForBar(endBar)
        guard startX >= preDrag.rulerFrame.minX, endX <= preDrag.rulerFrame.maxX else {
            throw LogicianError.trackNotExposed(
                requested: "bars \(startBar)-\(endBar)",
                exposed: "the target range is outside the visible ruler; scroll or zoom Logic so it is visible"
            )
        }
        let stripY = preDrag.regionY + 10
        let writeRoute: String

        func regionFrameNow() throws -> CGRect {
            guard let current = rulerChild(try rulerArea(), "cycle region") else {
                throw LogicianError.windowNotFound("cycle region in the ruler")
            }
            return try frame(of: current)
        }
        func setRegionPosition(x: CGFloat) throws {
            guard let current = rulerChild(try rulerArea(), "cycle region") else {
                throw LogicianError.windowNotFound("cycle region in the ruler")
            }
            var origin = CGPoint(x: x, y: preDrag.regionY)
            guard let value = AXValueCreate(.cgPoint, &origin) else {
                throw LogicianError.writeFailed("could not create the AXPosition value")
            }
            let status = AXUIElementSetAttributeValue(current, kAXPositionAttribute as CFString, value)
            guard status == .success else {
                throw LogicianError.writeFailed("AXPosition write on the cycle region returned AXError \(status.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        func covers(_ frame: CGRect, _ x: CGFloat) -> Bool {
            x >= frame.minX - 3 && x <= frame.maxX + 3
        }

        if originalLength == targetLength {
            // Same length: the grid-snapped position write is enough.
            writeRoute = "ax_position_grid_snap"
            try setRegionPosition(x: startX)
        } else {
            writeRoute = "cg_drag_create"
            var dragFrom = CGPoint(x: startX, y: stripY)
            var dragTo = CGPoint(x: endX, y: stripY)
            var currentFrame = try regionFrameNow()
            if covers(currentFrame, startX) {
                if !covers(currentFrame, endX) {
                    // Drag backwards; only the start point must avoid the region.
                    swap(&dragFrom, &dragTo)
                } else {
                    // The region covers both locator targets: move it aside first.
                    try setRegionPosition(x: min(startX + preDrag.slope, preDrag.rulerFrame.maxX - 2))
                    currentFrame = try regionFrameNow()
                    guard !covers(currentFrame, startX) else {
                        throw LogicianError.openVerificationFailed(
                            "Could not move the existing cycle region away from the drag start point."
                        )
                    }
                }
            }
            try dragBetween(
                from: dragFrom,
                to: dragTo,
                requireHitOn: try rulerArea(),
                label: "cycle strip of the ruler"
            )
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Semantic verification: with the playhead on the start bar, the thumb
        // (plus the measured constant offset) must line up with the region edge,
        // and the region's size description must report the requested bar count.
        try convergeSlider(in: controlBar, sliderName: "bar", target: startBar)
        try convergeSlider(in: controlBar, sliderName: "beat", target: 1)
        Thread.sleep(forTimeInterval: 0.15)
        let verifySnap = try snapshot()
        let startError = (verifySnap.regionX - verifySnap.thumbX - anchored.thumbOffset) / verifySnap.slope
        guard let resized = rulerChild(try rulerArea(), "cycle region"),
              abs(startError) <= 0.3,
              cycleLengthBars(resized) == targetLength else {
            let actualLength = rulerChild((try? rulerArea()) ?? ruler, "cycle region")
                .map { stringAttribute($0, "AXSizeDescription") } ?? "?"
            throw LogicianError.verificationFailed(
                requested: "cycle bars \(startBar)-\(endBar) (\(targetLength) bars)",
                actual: "start is \(String(format: "%.2f", startError)) bars off, size is '\(actualLength)'",
                restored: false
            )
        }

        if let enabled = enabled {
            _ = try MCUController.setCycle(enabled) ?? setCycle(enabled: enabled)
        }
        let finalCycle = controlBarChild(try controlBarGroup(), "Cycle")
            .map { stringAttribute($0, kAXValueAttribute as String) == "1" }

        return [
            "success": true,
            "verified": true,
            "state": "cycle_range_set",
            "start_bar": startBar,
            "end_bar": endBar,
            "length_bars": targetLength,
            "anchor_bar": anchored.bar,
            "previous": [
                "start_bar": anchored.bar,
                "length_bars": originalLength ?? -1
            ],
            "write_route": writeRoute,
            "cycle_enabled": finalCycle ?? NSNull(),
            "verification": "playhead-thumb alignment at the start bar and AXSizeDescription reporting \(targetLength) bars"
        ]
    }

    func rulerArea() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        let ruler = firstDescendant(of: mainWindow, maximumDepth: AXDepth.timeRuler) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea"
                && stringAttribute(element, kAXDescriptionAttribute as String) == "Tracks time ruler"
        }
        guard let area = ruler else {
            throw LogicianError.windowNotFound("Tracks time ruler")
        }
        return area
    }

    func rulerChild(_ ruler: AXUIElement, _ description: String) -> AXUIElement? {
        children(of: ruler).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }
    }

    func frame(of element: AXUIElement) throws -> CGRect {
        guard let value = attribute(element, "AXFrame") else {
            throw LogicianError.writeFailed("could not read an element frame")
        }
        // rectValue, not `as! AXValue`: a non-AXValue frame reply throws the
        // same "could not decode" error instead of trapping the whole process.
        guard let rect = rectValue(value) else {
            throw LogicianError.writeFailed("could not decode an element frame")
        }
        return rect
    }

    /// Pixels per bar, from the ruler's project Start/End markers whose
    /// AXValueDescription names their bar ("1 bar ", "82 bars ").
    func pixelsPerBar(in ruler: AXUIElement) throws -> CGFloat {
        guard let start = rulerChild(ruler, "Start Marker"),
              let end = rulerChild(ruler, "End Marker"),
              let startBar = leadingInt(stringAttribute(start, kAXValueDescriptionAttribute as String)),
              let endBar = leadingInt(stringAttribute(end, kAXValueDescriptionAttribute as String)),
              endBar > startBar else {
            throw LogicianError.windowNotFound("Start/End markers in the ruler")
        }
        let startX = try frame(of: start).origin.x
        let endX = try frame(of: end).origin.x
        let slope = (endX - startX) / CGFloat(endBar - startBar)
        guard slope > 1 else {
            throw LogicianError.openVerificationFailed("Ruler scale too small (\(slope) px/bar); zoom in horizontally.")
        }
        return slope
    }

    func approximateBarAt(x: CGFloat, in ruler: AXUIElement) throws -> Int {
        guard let start = rulerChild(ruler, "Start Marker"),
              let startBar = leadingInt(stringAttribute(start, kAXValueDescriptionAttribute as String)) else {
            throw LogicianError.windowNotFound("Start marker in the ruler")
        }
        let startX = try frame(of: start).origin.x
        let slope = try pixelsPerBar(in: ruler)
        return max(1, Int((CGFloat(startBar) + (x - startX) / slope).rounded()))
    }

    func cycleLengthBars(_ region: AXUIElement) -> Int? {
        let description = stringAttribute(region, "AXSizeDescription")
        guard let bars = leadingInt(description),
              description.range(of: "beat", options: .caseInsensitive) == nil,
              description.range(of: "division", options: .caseInsensitive) == nil else {
            return nil
        }
        return bars
    }

    func leadingInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    func restoreRegionPosition(to x: CGFloat, y: CGFloat) {
        guard let ruler = try? rulerArea(),
              let region = rulerChild(ruler, "cycle region") else { return }
        var origin = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        _ = AXUIElementSetAttributeValue(region, kAXPositionAttribute as CFString, value)
    }

    func dragBetween(
        from: CGPoint,
        to: CGPoint,
        requireHitOn target: AXUIElement,
        label: String
    ) throws {
        try ensureLogicFrontmost(for: label)
        // Floating plugin windows can cover the target; raise the project window
        // so screen-position hit tests and drags reach it.
        if let projectWindow = try? projectWindow() {
            _ = AXUIElementPerformAction(projectWindow, "AXRaise" as CFString)
            Thread.sleep(forTimeInterval: 0.2)
        }
        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(from.x),
            Float(from.y),
            &hit
        )
        guard hitStatus == .success, let hitElement = hit, elementCoversTarget(hitElement, target: target) else {
            let hitDescription = hit.map {
                stringAttribute($0, kAXRoleAttribute as String) + " '"
                    + stringAttribute($0, kAXDescriptionAttribute as String) + "'"
            } ?? "nothing"
            throw LogicianError.writeFailed(
                "hit test at the \(label) resolved to \(hitDescription); refusing to drag. Another window may cover the ruler."
            )
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let previousLocation = CGEvent(source: nil)?.location
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else {
            throw LogicianError.writeFailed("could not create mouse events for \(label)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        let steps = 12
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress
            )
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.08)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        if let restore = previousLocation {
            Thread.sleep(forTimeInterval: 0.05)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: restore, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    func ensureLogicFrontmost(for label: String) throws {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            throw LogicianError.logicNotRunning
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        func frontmost() -> Bool {
            stringAttribute(appElement, "AXFrontmost") == "1"
        }
        if !frontmost() {
            application.activate()
            for _ in 0..<10 where !frontmost() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if !frontmost() {
            // macOS can deny cooperative activation while the user is active in
            // another app; the accessibility route is more forceful.
            AXUIElementSetAttributeValue(
                AXUIElementCreateSystemWide(),
                "AXFocusedApplication" as CFString,
                appElement
            )
            for _ in 0..<10 where !frontmost() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard frontmost() else {
            throw LogicianError.writeFailed("Logic could not be brought frontmost; refusing to interact with \(label)")
        }
    }

    func controlBarGroup() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        let bar = firstDescendant(of: mainWindow, maximumDepth: AXDepth.controlBar) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute(element, kAXDescriptionAttribute as String) == "Control Bar"
                && stringAttribute(element, kAXHelpAttribute as String).hasPrefix("Control bar")
        }
        guard let group = bar else {
            throw LogicianError.windowNotFound("Control Bar group")
        }
        return group
    }

    func controlBarChild(_ bar: AXUIElement, _ description: String) -> AXUIElement? {
        children(of: bar).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == description
        }
    }

    func playheadGroup(in controlBar: AXUIElement) -> AXUIElement? {
        guard let inner = children(of: controlBar).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Control Bar"
        }) else { return nil }
        return children(of: inner).first {
            stringAttribute($0, kAXDescriptionAttribute as String) == "Playhead Position"
        }
    }

    func sliderValue(_ group: AXUIElement, _ description: String) -> Int? {
        children(of: group)
            .first { stringAttribute($0, kAXDescriptionAttribute as String) == description }
            .flatMap { Int(stringAttribute($0, kAXValueAttribute as String)) }
    }

}
