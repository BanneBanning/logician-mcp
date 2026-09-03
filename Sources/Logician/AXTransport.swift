import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// What one walk of Logic's control bar found, as optionals: `nil` means the
/// element was not there, which the payload publishes as `null` — never as a
/// missing key. Separating the READ from the payload is what makes the
/// never-a-missing-key contract testable with Logic Pro closed; see
/// `LogicAccessibility.transportPayload`.
struct ControlBarReading {
    var projectDocument: String?
    var playing: Bool?
    var recording: Bool?
    var cycle: Bool?
    var metronome: Bool?
    var countIn: Bool?
    var soloMode: Bool?
    /// Set only when the Cycle button was missing and the ruler answered.
    var cycleSource: String?
    var playheadBar: Int?
    var playheadBeat: Int?
    /// The tempo, signature and key IN FORCE AT THE PLAYHEAD — the control bar
    /// publishes no project-level constant.
    var tempo: Double?
    var timeSignature: String?
    var keySignature: String?
    var tempoMode: ProjectTempoMode = .absent
    var tempoModeRoute: String = "control_bar"
    var tempoModeVisitNote: String?
}

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
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.controlBar
        }), let slider = children(of: inner).first(where: {
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.tempo
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
    ///
    /// SUPERSEDED as the only route (2026-08-28): the mode IS readable, from
    /// `File > Project Settings > Smart Tempo…`. See
    /// `projectTempoMode(allowingSettingsWindow:)`, which keeps this cheap
    /// no-side-effect read as the first attempt and falls back to the window.
    func projectTempoMode() -> ProjectTempoMode {
        guard let bar = try? controlBarGroup(),
              let inner = children(of: bar).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.controlBar
              }) else {
            return .absent
        }
        return projectTempoMode(inControlBar: inner)
    }

    /// The same read against an already-resolved inner "Control Bar" group, so
    /// `getTransport` does not walk the window twice.
    func projectTempoMode(inControlBar inner: AXUIElement) -> ProjectTempoMode {
        projectTempoMode(inControlBarChildren: children(of: inner))
    }

    /// The same read against an inner group whose children have already been
    /// enumerated. Keyed on role + help rather than description, which is why
    /// `DescribedChildren` hands its `all` array out at all.
    func projectTempoMode(inControlBarChildren siblings: [AXUIElement]) -> ProjectTempoMode {
        guard let popup = siblings.first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXPopUpButton"
                && stringAttribute($0, kAXHelpAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.projectTempoMenuHelpPrefix)
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

    /// The project tempo mode, with the Project Settings window as a fallback
    /// when the control bar withholds the value — which, on Logic Pro 12.3.1,
    /// it always does.
    ///
    /// The cheap read runs first and costs one control-bar walk with no side
    /// effect whatsoever; only when it comes back `.unreadable`/`.absent` is a
    /// window involved, and that window is opened on the Smart Tempo pane,
    /// read, and closed again (see `projectTempoModeViaSettings`).
    ///
    /// `allowingSettingsWindow` is opt-in per call site rather than always-on
    /// for one reason: raising and closing a window is a visible thing to do,
    /// and a status poll should not do it. The paths that pass `true` are the
    /// ones where the answer is worth a window — `logic_record_midi`, whose
    /// Adapt-mode refusal exists to protect the user's tempo track, and
    /// `logic_get_transport` when the caller explicitly asks.
    func projectTempoMode(
        allowingSettingsWindow: Bool
    ) -> (mode: ProjectTempoMode, visit: ProjectSettingsVisit?) {
        let cheap = projectTempoMode()
        switch cheap {
        case .keep, .adapt, .auto:
            return (cheap, nil)
        case .unreadable, .absent:
            guard allowingSettingsWindow else { return (cheap, nil) }
            let deep = projectTempoModeViaSettings()
            return (deep.mode, deep.visit)
        }
    }

    // MARK: - Two-point tempo sampling (is the tempo constant across a range?)

    /// The control bar's Tempo value — the tempo AT THE PLAYHEAD POSITION, which
    /// is the whole basis of the sampling below. Cheap on purpose: one control
    /// bar walk, none of `getTransport`'s document read.
    func controlBarTempo() -> Double? {
        guard let bar = try? controlBarGroup(),
              let inner = children(of: bar).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.controlBar
              }),
              let slider = children(of: inner).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.tempo
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
              let savedBar = sliderValue(lcd, LogicUIStrings.Element.playheadBarSlider) else {
            return .verdict(.unverified(
                reason: "\(cannotSample): the control bar reports no playhead position, and the"
                    + " playhead is never moved when it cannot be put back"
            ))
        }
        let savedBeat = sliderValue(lcd, LogicUIStrings.Element.playheadBeatSlider)
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
              let playheadBar = sliderValue(lcd, LogicUIStrings.Element.playheadBarSlider) else {
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

    func getTransport(readSmartTempoMode: Bool = false) throws -> [String: Any] {
        LogicAccessibility.transportPayload(
            try readControlBar(readSmartTempoMode: readSmartTempoMode)
        )
    }

    /// Everything `logic_get_transport` reads, in ONE walk of the control bar.
    ///
    /// Two enumerations, not thirteen. Every named control is looked up in a
    /// `DescribedChildren` index built once per group; before 2026-09-02 each
    /// of the six checkboxes, the playhead LCD, the inner group, the tempo, the
    /// signature, the key and the Smart Tempo pop-up re-fetched its siblings
    /// and re-read their descriptions — 98 of the call's 129 AX reads. The
    /// project window is resolved once too, and the document path taken off it
    /// rather than through a second walk of Logic's window list.
    ///
    /// MEASURED 2026-09-02, same project, same process, before and after:
    /// **8.2–9.4 ms → 4.9–6.1 ms** warm, with a byte-identical payload.
    ///
    /// Missing elements come back as `nil` and are published as `null`; see
    /// `transportPayload`.
    private func readControlBar(readSmartTempoMode: Bool) throws -> ControlBarReading {
        let window = try projectWindow()
        let bar = try controlBarGroup(in: window)
        var reading = ControlBarReading()
        // `projectWindow()` only ever returns a window it has already proven
        // carries the document, so this is a single attribute read; the walk
        // stays as the fallback for the day that stops being true.
        reading.projectDocument = documentPath(of: window) ?? (try? projectDocumentPath())

        let barChildren = describedChildren(of: bar)
        func checkbox(_ description: String) -> Bool? {
            barChildren[description].map {
                stringAttribute($0, kAXValueAttribute as String) == "1"
            }
        }
        reading.playing = checkbox(LogicUIStrings.Element.playButton)
        reading.recording = checkbox(LogicUIStrings.Element.recordButton)
        reading.cycle = checkbox(LogicUIStrings.Element.cycleButton)
        reading.metronome = checkbox(LogicUIStrings.Element.metronomeButton)
        reading.countIn = checkbox(LogicUIStrings.Element.countInButton)
        reading.soloMode = checkbox(LogicUIStrings.Element.soloModeButton)
        if reading.cycle == nil, let rulerCycle = cycleStateFromRuler() {
            // Narrow windows collapse the Cycle button; the ruler still knows.
            reading.cycle = rulerCycle
            reading.cycleSource = "ruler_cycle_region"
        }

        guard let inner = barChildren[LogicUIStrings.Element.controlBar] else {
            // No inner group: the playhead, tempo, signature and key stay nil
            // and are published as null. They are NOT dropped — see
            // `transportPayload`.
            return reading
        }
        let innerChildren = describedChildren(of: inner)
        if let lcd = innerChildren[LogicUIStrings.Element.playheadPosition] {
            let fields = describedChildren(of: lcd)
            func field(_ description: String) -> Int? {
                fields[description].flatMap { Int(stringAttribute($0, kAXValueAttribute as String)) }
            }
            reading.playheadBar = field(LogicUIStrings.Element.playheadBarSlider)
            reading.playheadBeat = field(LogicUIStrings.Element.playheadBeatSlider)
        }
        // The tempo, signature and key the control bar publishes are the ones
        // IN FORCE AT THE PLAYHEAD, not project constants — measured 2026-09-02
        // on one project, one uninterrupted run, nothing edited between the
        // reads: 121 BPM in 5/4 with the playhead at bar 51, 120 BPM in 4/4
        // with it at bar 1. The whole maps live in `logic_tempo_events` and
        // `logic_list_signatures`, and every description that names these three
        // fields says so.
        reading.tempo = innerChildren[LogicUIStrings.Element.tempo]
            .flatMap { Double(stringAttribute($0, kAXValueAttribute as String)) }
        reading.timeSignature = innerChildren[LogicUIStrings.Element.timeSignature]
            .map { stringAttribute($0, kAXValueAttribute as String) }
        reading.keySignature = innerChildren[LogicUIStrings.Element.keySignature]
            .map { stringAttribute($0, kAXValueAttribute as String) }

        // Smart Tempo: which mode a recording will apply to the project's
        // tempo map. The MODE is reported only when it is actually known — an
        // unreadable mode reported as a value would read as "keep", and Adapt
        // is the one that rewrites the tempo track.
        reading.tempoMode = projectTempoMode(inControlBarChildren: innerChildren.all)
        // Opt-in, because this one raises and closes a window: the control
        // bar publishes no value (Logic Pro 12.3.1), so the mode is only
        // knowable from File > Project Settings > Smart Tempo.
        //
        // NOT CACHED, deliberately. The mode is a project setting that changes
        // only in Logic's own UI — the shape this server caches everywhere else
        // — but every other cache has a cheap live cross-check (the tempo map
        // against the control bar's tempo, the bank map against the LCD) and
        // this one CANNOT have any: the reason the window route exists is that
        // the control bar publishes nothing to check against, so a cache hit
        // would be unverifiable by construction. And the consumer is
        // `logic_record_midi`'s refusal, which exists to stop an Adapt-mode
        // project rewriting the user's tempo track. A cached "keep" from before
        // the user switched the pane would let exactly that through, silently.
        // 0.73 s of honesty beats a 0 ms answer that can be confidently wrong.
        if readSmartTempoMode, reading.tempoMode.name == nil {
            let deep = projectTempoModeViaSettings()
            reading.tempoMode = deep.mode
            reading.tempoModeRoute = "project_settings_window"
            reading.tempoModeVisitNote = deep.visit.note
        }
        return reading
    }

    /// The result payload, PURE — no Accessibility, no Logic, so the contract
    /// below is a unit test rather than a hope.
    ///
    /// THE CONTRACT: every documented key is present on every call, `null` when
    /// its control bar element was missing. Until 2026-09-02 the playhead pair
    /// and the tempo/signature/key trio were assigned INSIDE the `if let` that
    /// found their group, so a collapsed control bar or a non-English Logic UI
    /// dropped the keys entirely while the description promised nulls — and
    /// `logic_project_snapshot`, which serves this payload as its `transport`
    /// section under a never-a-missing-key contract, would have shown a diff
    /// reading "the tempo was removed" where the truth was "the tempo could not
    /// be read".
    static func transportPayload(_ reading: ControlBarReading) -> [String: Any] {
        var result: [String: Any] = [
            "project_document": reading.projectDocument ?? NSNull(),
            "playing": reading.playing ?? NSNull(),
            "recording": reading.recording ?? NSNull(),
            "cycle": reading.cycle ?? NSNull(),
            "metronome": reading.metronome ?? NSNull(),
            "count_in": reading.countIn ?? NSNull(),
            "solo_mode": reading.soloMode ?? NSNull(),
            "playhead_bar": reading.playheadBar ?? NSNull(),
            "playhead_beat": reading.playheadBeat ?? NSNull(),
            "tempo": reading.tempo ?? NSNull(),
            "time_signature": reading.timeSignature ?? NSNull(),
            "key_signature": reading.keySignature ?? NSNull()
        ]
        // Reported only when it happened: "the ruler answered instead" is an
        // event, not a field, and a null one would read as a claim about a
        // route that was never taken.
        if let cycleSource = reading.cycleSource {
            result["cycle_source"] = cycleSource
        }
        if let name = reading.tempoMode.name {
            result["project_tempo_mode"] = name
            result["project_tempo_mode_route"] = reading.tempoModeRoute
            if let note = reading.tempoModeVisitNote {
                result["project_tempo_mode_note"] = note
            }
        } else if let explanation = reading.tempoMode.explanation {
            result["project_tempo_mode_note"] = reading.tempoModeVisitNote.map {
                "\(explanation) The Project Settings fallback also failed: \($0)."
            } ?? explanation
        }
        return result
    }

    func setCycle(enabled: Bool) throws -> [String: Any] {
        if controlBarChild(try controlBarGroup(), LogicUIStrings.Element.cycleButton) != nil {
            return try setTransportCheckbox(
                description: LogicUIStrings.Element.cycleButton,
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
        // Look first, sleep only on a miss: an `AXUIElementPerformAction`/key
        // command's effect is typically readable in single-digit ms, so a
        // fixed 100 ms sleep before every look was mostly waste on the common
        // case (borrowed estimate, pattern #9 — never measured live here
        // because the MCU plane answered on every profiled call, see
        // profiles/logic_set_cycle.md C1, 2026-09-02). Same 20-look budget,
        // just moved off the front of it.
        for attempt in 0..<20 {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.1) }
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
              let region = rulerChild(ruler, LogicUIStrings.Element.cycleRegion) else { return nil }
        switch stringAttribute(region, kAXValueDescriptionAttribute as String)
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case LogicUIStrings.Value.on: return true
        case LogicUIStrings.Value.off: return false
        default: return nil
        }
    }

    /// ONE control bar reading: the Play checkbox, nothing else.
    ///
    /// The second witness `MCUController.setPlaying` cross-checks its play LED
    /// against (profiles/logic_set_playing.md, DEFECT). `getTransport()` would
    /// answer the same question, but it also resolves the tempo, the
    /// signature, the key, five more checkboxes and the playhead LCD — 4.9-6.1
    /// ms warm (measured 2026-09-02) for one boolean. This walk stops at the
    /// control bar's own children.
    ///
    /// nil, never false, when the control bar cannot be read at all
    /// (Accessibility not trusted, no project window, a modal in front): the
    /// verdict then rests on the witnesses that did answer.
    func playingCheckbox() -> Bool? {
        guard let bar = try? controlBarGroup(),
              let play = controlBarChild(bar, LogicUIStrings.Element.playButton) else { return nil }
        return stringAttribute(play, kAXValueAttribute as String) == "1"
    }

    func setPlaying(playing: Bool) throws -> [String: Any] {
        if playing {
            // Pressing the Play checkbox starts playback, but pressing it again
            // does NOT stop (verified 2026-08-24), so only the start path uses it.
            return try setTransportCheckbox(
                description: LogicUIStrings.Element.playButton,
                key: "playing",
                desired: true,
                onState: "playing",
                offState: "stopped"
            )
        }

        let bar = try controlBarGroup()
        guard let play = controlBarChild(bar, LogicUIStrings.Element.playButton) else {
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
            if let refreshed = controlBarChild(try controlBarGroup(), LogicUIStrings.Element.playButton),
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

    /// Moves the playhead to a bar (and optionally a beat) by stepping the
    /// control bar's position display, and proves the landing by reading it
    /// back.
    ///
    /// THREE THINGS THIS OWES THE CALLER BESIDES THE MOVE, all added
    /// 2026-09-03 after the profile caught them
    /// (profiles/logic_set_playhead.md §5 defects 3 and 4):
    ///
    /// 1. **A bar the project cannot reach stops being expensive.** `bar: 93`
    ///    on this 64-bar project used to cost 1 585 ms of stepping to Logic's
    ///    ceiling before it could report the honest mismatch. There is still
    ///    no way to know the ceiling without walking into it — the slider's
    ///    `AXMaxValue` is a ±1 window, see `convergeSlider` — but the walk is
    ///    now ~1.4 ms a bar, so the same refusal costs ~15 ms.
    /// 2. **A beat nobody asked about is put back.** Logic resets the sub-bar
    ///    position when the bar slider hits that ceiling — measured beat
    ///    3 → 1, silently, with the error naming only the bar, leaving the
    ///    corruption for the next unrelated caller to discover. The beat is
    ///    read before and after every locate and, when the caller passed no
    ///    `beat`, restored and reported in `warning`.
    /// 3. **A failed locate does not leave the playhead mid-climb.** Like
    ///    `sampleTempo` (:200) this writes the position it read back and says
    ///    in `restored` whether that worked, instead of abandoning the
    ///    playhead wherever the attempt stopped.
    func setPlayhead(barNumber: Int, beat: Int?) throws -> [String: Any] {
        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar) else {
            throw LogicianError.windowNotFound("Playhead Position display in the control bar")
        }
        let barSlider = LogicUIStrings.Element.playheadBarSlider
        let beatSlider = LogicUIStrings.Element.playheadBeatSlider
        let beforeBar = sliderValue(lcd, barSlider)
        let beforeBeat = sliderValue(lcd, beatSlider)

        /// Puts the playhead back where this call found it and folds the
        /// outcome into the error, so a refusal never doubles as a move.
        /// Costs nothing when nothing moved: `convergeSlider` returns on its
        /// first read when the slider is already on target.
        func abandoning(_ error: Error) -> Error {
            var restored = true
            if let beforeBar {
                restored = (try? convergeSlider(in: controlBar, sliderName: barSlider, target: beforeBar)) != nil
            }
            if let beforeBeat, restored {
                restored = (try? convergeSlider(in: controlBar, sliderName: beatSlider, target: beforeBeat)) != nil
            }
            guard case .verificationFailed(let requested, let actual, _)? = error as? LogicianError else {
                return error
            }
            return LogicianError.verificationFailed(requested: requested, actual: actual, restored: restored)
        }

        do {
            try convergeSlider(in: controlBar, sliderName: barSlider, target: barNumber)
            if let beat = beat {
                try convergeSlider(in: controlBar, sliderName: beatSlider, target: beat)
            }
        } catch {
            throw abandoning(error)
        }

        guard let refreshed = playheadGroup(in: try controlBarGroup()),
              let afterBar = sliderValue(refreshed, barSlider),
              afterBar == barNumber,
              beat == nil || sliderValue(refreshed, beatSlider) == beat else {
            let now = playheadGroup(in: (try? controlBarGroup()) ?? controlBar) ?? lcd
            throw abandoning(LogicianError.verificationFailed(
                requested: "bar \(barNumber)\(beat.map { ", beat \($0)" } ?? "")",
                actual: "bar \(sliderValue(now, barSlider).map(String.init) ?? "?"), beat \(sliderValue(now, beatSlider).map(String.init) ?? "?")",
                restored: false
            ))
        }

        var landedBeat = sliderValue(refreshed, beatSlider)
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "moved",
            "before": ["bar": beforeBar ?? -1, "beat": beforeBeat ?? -1],
            "write_route": "ax_value_stepwise"
        ]
        if let putBack = PlayheadLocate.unrequestedBeatDrift(
            requested: beat, before: beforeBeat, after: landedBeat
        ), let drifted = landedBeat {
            let attempted = (try? convergeSlider(in: controlBar, sliderName: beatSlider, target: putBack)) != nil
            let settled = playheadGroup(in: (try? controlBarGroup()) ?? controlBar)
                .flatMap { sliderValue($0, beatSlider) }
            let ok = attempted && settled == putBack
            landedBeat = settled ?? landedBeat
            result["beat_restored"] = ok
            result["warning"] = PlayheadLocate.beatDriftWarning(
                from: putBack, to: drifted, restored: ok
            )
        }
        result["after"] = ["bar": barNumber, "beat": beat ?? landedBeat ?? -1]
        return result
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
        // Three witnesses, not the play LED's word alone: that bit can be
        // wrong and can stay wrong (TransportWitness.swift), and here a false
        // "rolling" silently downgrades an exact cut while a false "stopped"
        // rewinds a playing transport to bar 1. `observeTransport` pays for
        // the position sample only when the cheap witnesses disagree.
        let rolling = MCUController.observeTransport(
            status: MCUController.freshStatus() ?? [:], logic: self
        ).playing ?? false
        var rewound = false
        if isZero(before) != true && !rolling {
            try pressControlBarButton("Go to Beginning")
            Thread.sleep(forTimeInterval: 0.4)
            rewound = true
        }
        let moved = try setPlayhead(barNumber: bar, beat: beat)
        let after = residue()
        let group = playheadGroup(in: try controlBarGroup())
        var result: [String: Any] = [
            // Where the playhead was — after any rewind, which is the honest
            // "before" for the stepping, and the one a caller reporting a move
            // wants to show. Carried through from `setPlayhead` rather than
            // read again.
            "before": moved["before"] ?? NSNull(),
            "bar": group.flatMap { sliderValue($0, LogicUIStrings.Element.playheadBarSlider) } ?? bar,
            "beat": group.flatMap { sliderValue($0, LogicUIStrings.Element.playheadBeatSlider) } ?? beat,
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
        // Look first, sleep only on a miss — see the identical rationale
        // above `setCycle`'s key-command fallback (profiles/
        // logic_set_cycle.md C1, 2026-09-02): an `AXPress` is synchronous and
        // its effect is usually readable in single-digit ms, so this loop
        // used to burn a guaranteed 100 ms on the common case. Same 20-look
        // budget, shared by `setCycle`'s primary AX route and `setPlaying`'s
        // start path.
        for attempt in 0..<20 {
            if lookFirstShouldSleep(attempt: attempt) { Thread.sleep(forTimeInterval: 0.1) }
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

    /// Waits for one LCD stepper write to become READABLE instead of sleeping
    /// through it, and hands back the value it stopped on so the converge
    /// loop does not pay for the same read twice.
    ///
    /// The `Thread.sleep(0.12)` this replaces was the dominant cost of every
    /// playhead move in the server: measured 125.4–131.8 ms per step across
    /// eight legs and 2–23 bars (profiles/logic_set_playhead.md §3), against
    /// an `AXUIElementSetAttributeValue` that is synchronous and lands in
    /// 0–6 ms on the literal sibling control (the bounce dialog's position
    /// field, ten writes back to back, nothing coalesced —
    /// profiles/logic_bounce_range.md §8.1). Re-measured on THIS slider
    /// 2026-09-03 before shipping: see the numbers in CHANGELOG.
    ///
    /// The deadline is the OLD sleep, unchanged: a slider that genuinely will
    /// not move is given exactly as long as before to prove it, so the stall
    /// verdict below is no less patient than it was. Only the common case —
    /// a write that lands — stops waiting.
    private func awaitSliderStep(
        _ slider: AXUIElement,
        changedFrom current: Int,
        within deadline: TimeInterval = 0.12
    ) -> Int? {
        let limit = Date().addingTimeInterval(deadline)
        while true {
            let value = Int(stringAttribute(slider, kAXValueAttribute as String))
            if let value, value != current { return value }
            if Date() >= limit { return value }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// Steps one of the control bar position display's sliders to `target`.
    ///
    /// Logic's LCD sliders move exactly ONE step toward the requested value
    /// per `AXValue` write (verified 2026-08-24), so the written number is
    /// only ever a DIRECTION and this is a loop rather than a write. It is
    /// the shared engine under 16 call sites — `logic_set_playhead`,
    /// `logic_set_cycle_range`, every region tool that parks, tempo sampling,
    /// automation read/record, MIDI record, marker parking, `logic_import_midi`
    /// — so what it costs per step, all of them pay.
    ///
    /// THERE IS NO PRE-WRITE BOUND CHECK, and the reason is a measurement.
    /// The profile that asked for one (profiles/logic_set_playhead.md §5
    /// defect 3) proposed reading the slider's own `AXMaxValue` to refuse a
    /// bar past the project's end before paying the climb. Probed live
    /// 2026-09-03 on this exact slider: with the playhead on bar 56 the bar
    /// slider publishes `AXMinValue 55, AXMaxValue 57`, and the beat slider
    /// `0`/`2` around beat 1 — a ±1 window that TRACKS THE CURRENT VALUE, not
    /// the project's range. A check against it would have refused every move
    /// longer than one bar. So the ceiling is still found the only way Logic
    /// exposes it — by walking into it — and the stall check below reports it
    /// in one extra step. What made the old defect expensive was never the
    /// walk: it was 120 ms per step of it. Eight wasted steps now cost ~12 ms.
    ///
    /// (Also measured, and deliberately NOT used: `AXIncrement`/`AXDecrement`
    /// move TEN bars per action on this slider, clamping at the project's
    /// last bar — the same coarse gear the event-list steppers have. At
    /// ~1.4 ms per fine step the whole 23-bar restore leg costs ~33 ms, so a
    /// second gear would save tens of milliseconds for a second overshoot
    /// mode to get wrong. Left in this comment for whoever needs it if the
    /// per-step cost ever grows again.)
    ///
    /// The budget, the stall check and the final readback are unchanged: this
    /// fix cut the WAIT between writes, never the proof.
    func convergeSlider(in controlBar: AXUIElement, sliderName: String, target: Int) throws {
        guard let lcd = playheadGroup(in: controlBar),
              let slider = children(of: lcd).first(where: {
                  stringAttribute($0, kAXDescriptionAttribute as String) == sliderName
              }),
              let start = Int(stringAttribute(slider, kAXValueAttribute as String)) else {
            throw LogicianError.windowNotFound("playhead \(sliderName) slider")
        }
        if start == target { return }
        let maximumSteps = PlayheadLocate.stepBudget(from: start, to: target)
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
            let after = awaitSliderStep(slider, changedFrom: current) ?? current
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

    /// Sets the cycle (locator) range to a whole-bar span.
    ///
    /// TWO KINDS OF HONESTY THIS OWES THE CALLER, both added 2026-09-03 after
    /// the profile caught them (profiles/logic_set_cycle_range.md §4 defects
    /// 3 and 4):
    ///
    /// - **Cycle mode is left as it was found.** A real drag in the ruler's
    ///   cycle strip engages Cycle the way it would for a human, so a call
    ///   that passed no `enabled` used to return `cycle_enabled: true` from a
    ///   project where it had been false, and nothing put it back. The
    ///   pre-call state is read on every path and reported as
    ///   `cycle_enabled_before`; when `enabled` was omitted and the write
    ///   flipped it, it is written back and verified.
    /// - **A range that scrolled out of view is scrolled back.** Logic
    ///   auto-scrolls the ruler to follow a drag, which used to strand an
    ///   absolute bar range that had been reachable one call earlier: the
    ///   profiler needed an out-of-band CGEvent scroll to reach bars 5–9
    ///   again, and nothing in this server could do that. `recentreRuler`
    ///   now posts that scroll itself, MEASURES what it did against the
    ///   ruler's own Start marker, and only refuses when the ruler will not
    ///   move — with the pixels it tried in the message.
    ///
    /// The playhead this tool borrows for its anchor/verify geometry is
    /// restored EAGERLY in a `defer`, not deferred as a debt. Measured
    /// 2026-09-03 after the `convergeSlider` fix: the restore leg is ~12 ms
    /// per bar (~0.4 s for the sandbox's habitual 36-bar distance) against a
    /// call that no longer costs ten seconds — a debt would have to be
    /// settled by every position-sensitive tool in the server to save that,
    /// and would leave the user's playhead visibly moved in the meantime.
    /// Re-price it if the per-step cost ever grows again.
    func setCycleRange(startBar: Int, endBar: Int, enabled: Bool?) throws -> [String: Any] {
        guard startBar >= 1, endBar > startBar else {
            throw LogicianError.invalidArguments("start_bar must be >= 1 and end_bar > start_bar")
        }
        let targetLength = endBar - startBar

        let ruler = try rulerArea()
        guard let region = rulerChild(ruler, LogicUIStrings.Element.cycleRegion) else {
            throw LogicianError.trackNotExposed(requested: "cycle region", exposed: "no cycle region in the ruler")
        }
        let originalLength = cycleLengthBars(region)

        let controlBar = try controlBarGroup()
        guard let lcd = playheadGroup(in: controlBar),
              let savedBar = sliderValue(lcd, LogicUIStrings.Element.playheadBarSlider),
              let savedBeat = sliderValue(lcd, LogicUIStrings.Element.playheadBeatSlider) else {
            throw LogicianError.windowNotFound("Playhead Position display in the control bar")
        }
        // Read BEFORE anything is written, on every path — including the ones
        // that never pass `enabled` — because that is the only moment the
        // pre-call Cycle state still exists.
        let cycleEnabledBefore = cycleButtonState()
        defer {
            try? convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBarSlider, target: savedBar)
            try? convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBeatSlider, target: savedBeat)
        }

        // Snapshot helper: Logic auto-scrolls the view when the playhead moves,
        // so the thumb and the region must always be read in the same instant
        // and never compared across playhead moves.
        func snapshot() throws -> (regionX: CGFloat, regionY: CGFloat, thumbX: CGFloat, slope: CGFloat, rulerFrame: CGRect) {
            let freshRuler = try rulerArea()
            guard let freshRegion = rulerChild(freshRuler, LogicUIStrings.Element.cycleRegion),
                  let thumb = rulerChild(freshRuler, LogicUIStrings.Element.playheadThumb) else {
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
            try convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBarSlider, target: candidate)
            try convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBeatSlider, target: 1)
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
        // The playhead is on the anchor bar, so the thumb plus the measured
        // constant offset IS that bar's line. A horizontal scroll moves every
        // pixel in the ruler by the same amount, so recovery only has to add
        // the shift it measured.
        var originBarX = preDrag.thumbX + anchored.thumbOffset
        func xForBar(_ bar: Int) -> CGFloat {
            originBarX + preDrag.slope * CGFloat(bar - anchored.bar)
        }
        // A drag that ends on the ruler's last pixel is not really reachable,
        // so demand three quarters of a bar of air at each edge.
        let visibilityMargin = preDrag.slope * 0.75
        func rangeIsVisible() -> Bool {
            RulerVisibility.isVisible(
                startX: xForBar(startBar),
                endX: xForBar(endBar),
                rulerMinX: preDrag.rulerFrame.minX,
                rulerMaxX: preDrag.rulerFrame.maxX,
                margin: visibilityMargin
            )
        }
        var recentredBy: CGFloat = 0
        if !rangeIsVisible() {
            recentredBy = try recentreRuler(
                shift: {
                    RulerVisibility.shiftToReveal(
                        startX: xForBar(startBar),
                        endX: xForBar(endBar),
                        rulerMinX: preDrag.rulerFrame.minX,
                        rulerMaxX: preDrag.rulerFrame.maxX,
                        margin: visibilityMargin
                    )
                },
                apply: { moved in originBarX += moved },
                satisfied: rangeIsVisible
            )
            guard rangeIsVisible() else {
                throw LogicianError.trackNotExposed(
                    requested: "bars \(startBar)-\(endBar)",
                    exposed: "the target range is outside the visible ruler and scrolling it back "
                        + "did not reach it (the ruler moved \(Int(recentredBy.rounded())) px of the "
                        + "\(Int(RulerVisibility.shiftToReveal(startX: xForBar(startBar), endX: xForBar(endBar), rulerMinX: preDrag.rulerFrame.minX, rulerMaxX: preDrag.rulerFrame.maxX, margin: visibilityMargin).rounded())) px still needed). "
                        + "Zoom the Tracks area out, or ask for a range nearer bar \(anchored.bar)"
                )
            }
        }
        let startX = xForBar(startBar)
        let endX = xForBar(endBar)
        let stripY = preDrag.regionY + 10
        let writeRoute: String

        func regionFrameNow() throws -> CGRect {
            guard let current = rulerChild(try rulerArea(), LogicUIStrings.Element.cycleRegion) else {
                throw LogicianError.windowNotFound("cycle region in the ruler")
            }
            return try frame(of: current)
        }
        func setRegionPosition(x: CGFloat) throws {
            guard let current = rulerChild(try rulerArea(), LogicUIStrings.Element.cycleRegion) else {
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
        try convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBarSlider, target: startBar)
        try convergeSlider(in: controlBar, sliderName: LogicUIStrings.Element.playheadBeatSlider, target: 1)
        Thread.sleep(forTimeInterval: 0.15)
        let verifySnap = try snapshot()
        let startError = (verifySnap.regionX - verifySnap.thumbX - anchored.thumbOffset) / verifySnap.slope
        guard let resized = rulerChild(try rulerArea(), LogicUIStrings.Element.cycleRegion),
              abs(startError) <= 0.3,
              cycleLengthBars(resized) == targetLength else {
            let actualLength = rulerChild((try? rulerArea()) ?? ruler, LogicUIStrings.Element.cycleRegion)
                .map { stringAttribute($0, "AXSizeDescription") } ?? "?"
            throw LogicianError.verificationFailed(
                requested: "cycle bars \(startBar)-\(endBar) (\(targetLength) bars)",
                actual: "start is \(String(format: "%.2f", startError)) bars off, size is '\(actualLength)'",
                restored: false
            )
        }

        var cycleWarning: String?
        if let enabled = enabled {
            _ = try MCUController.setCycle(enabled) ?? setCycle(enabled: enabled)
        } else if let before = cycleEnabledBefore, cycleButtonState() != before {
            // The drag engages Cycle exactly as it would for a human. Nobody
            // asked for that, so it goes back — measured live 2026-09-03:
            // `cycle_enabled` false → true on a call with no `enabled` key.
            _ = try? MCUController.setCycle(before) ?? setCycle(enabled: before)
            if cycleButtonState() != before {
                cycleWarning = "Setting the range switched Cycle mode "
                    + (before ? "off" : "on") + ", which this call never asked for, and it could "
                    + "NOT be put back. Set it explicitly with logic_set_cycle {enabled: \(before)}."
            }
        }
        let finalCycle = cycleButtonState()

        var result: [String: Any] = [
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
            "cycle_enabled_before": cycleEnabledBefore ?? NSNull(),
            "cycle_enabled": finalCycle ?? NSNull(),
            "verification": "playhead-thumb alignment at the start bar and AXSizeDescription reporting \(targetLength) bars"
        ]
        if abs(recentredBy) >= 1 {
            result["ruler_recentred_px"] = Int(recentredBy.rounded())
        }
        if let cycleWarning { result["warning"] = cycleWarning }
        return result
    }

    /// The control bar's Cycle button as a Bool, or nil when the control bar
    /// cannot be read — never a silent `false`, because "we could not tell"
    /// and "it is off" lead to opposite decisions in the restore above.
    func cycleButtonState() -> Bool? {
        (try? controlBarGroup())
            .flatMap { controlBarChild($0, LogicUIStrings.Element.cycleButton) }
            .map { stringAttribute($0, kAXValueAttribute as String) == "1" }
    }

    /// Scrolls the Tracks ruler horizontally until `satisfied()` or until the
    /// ruler stops moving, and reports the pixels it actually shifted.
    ///
    /// WHY THIS CAN MEASURE ITSELF. The ruler's Start marker is a child whose
    /// frame stays readable when it is scrolled out of the window — that is
    /// how `pixelsPerBar` measures a slope across a 64-bar project inside a
    /// 20-bar window — so the shift in pixels is the difference in that
    /// marker's x, read before and after each scroll. Nothing here assumes a
    /// direction or a scale: the first post is a probe, and its measured
    /// effect gives both the sign and the pixels-per-unit for the rest.
    ///
    /// Bounded at five posts and stopped by a ruler that will not move, so
    /// the caller gets a refusal naming what was tried rather than a loop.
    /// The scroll position is view state, not project content — Logic's own
    /// drag moves it on every `cg_drag_create` call and the project is never
    /// saved.
    func recentreRuler(
        shift: () -> CGFloat,
        apply: (CGFloat) -> Void,
        satisfied: () -> Bool
    ) throws -> CGFloat {
        let area = try rulerArea()
        func markerX() -> CGFloat? {
            rulerChild(area, LogicUIStrings.Element.startMarker)
                .flatMap { try? frame(of: $0).origin.x }
        }
        /// The marker read once it has STOPPED moving. Measured 2026-09-03:
        /// reading the shift straight after the wheel event under-counts —
        /// Logic animates the scroll over several frames — and an accumulated
        /// sum of under-counts put the pixel mapping 0.67 of a bar out, which
        /// is enough to land a grid-snapped write on the wrong bar. Every
        /// mapping update below is therefore an ABSOLUTE difference from the
        /// marker's position before the first scroll, never a running sum.
        func settledMarkerX() -> CGFloat? {
            var last = markerX()
            let limit = Date().addingTimeInterval(0.5)
            while Date() < limit {
                Thread.sleep(forTimeInterval: 0.02)
                let now = markerX()
                if let now, let previous = last, abs(now - previous) < 0.5 { return now }
                last = now
            }
            return last
        }
        guard let origin = markerX() else { return 0 }
        try ensureLogicFrontmost(for: "the Tracks ruler")
        let target = try frame(of: area)
        var applied: CGFloat = 0
        var pixelsPerUnit: CGFloat?
        for _ in 0..<5 {
            if satisfied() { break }
            let wanted = shift()
            guard abs(wanted) >= 1 else { break }
            // The first post is a probe: 200 pixel-units in the direction
            // that is right if the wheel and the content agree in sign. Its
            // measured effect gives both the sign and the scale for the rest.
            let units = pixelsPerUnit.map { Int32((wanted / $0).rounded()) } ?? (wanted > 0 ? 200 : -200)
            postRulerScroll(units: max(-4000, min(4000, units)), at: target)
            guard let now = settledMarkerX() else { break }
            let step = (now - origin) - applied
            guard abs(step) >= 1 else { break }
            if pixelsPerUnit == nil, units != 0 { pixelsPerUnit = step / CGFloat(units) }
            applied = now - origin
            apply(step)
        }
        return applied
    }

    /// One horizontal wheel event over the ruler. The caller reads the effect
    /// off the Start marker once it has settled.
    private func postRulerScroll(units: Int32, at target: CGRect) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: units,
            wheel3: 0
        ) else { return }
        event.location = CGPoint(x: target.midX, y: target.midY)
        event.post(tap: .cghidEventTap)
    }

    func rulerArea() throws -> AXUIElement {
        let mainWindow = try projectWindow()
        let ruler = firstDescendant(of: mainWindow, maximumDepth: AXDepth.timeRuler) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXLayoutArea"
                && stringAttribute(element, kAXDescriptionAttribute as String)
                == LogicUIStrings.Element.tracksTimeRuler
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
        guard let start = rulerChild(ruler, LogicUIStrings.Element.startMarker),
              let end = rulerChild(ruler, LogicUIStrings.Element.endMarker),
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
        guard let start = rulerChild(ruler, LogicUIStrings.Element.startMarker),
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
              description.range(of: LogicUIStrings.Element.beat, options: .caseInsensitive) == nil,
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
              let region = rulerChild(ruler, LogicUIStrings.Element.cycleRegion) else { return }
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

    /// Whether Logic is publishing a REAL window tree, not just the floats.
    ///
    /// `AXFrontmost` is not that evidence. Measured 2026-08-30 (R2 import
    /// research §2) with Safari full-screen on the active Space: Logic reported
    /// `AXFrontmost = 1` while `logicWindows()` returned ONLY the floating
    /// `Transport` window — no project window, no modal alert, and
    /// `CGWindowListCopyWindowInfo` listing no Logic window at all. Every read
    /// and every synthetic keystroke in that state goes nowhere, which is where
    /// three of that session's route failures came from.
    ///
    /// So this asks the question the callers actually have: is there a window
    /// worth talking to? A document window (the project), or a dialog/sheet/
    /// standard window (the bounce dialog, the import panel, an alert). A
    /// Transport float alone answers no.
    func logicPublishesItsWindows() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        return windows.contains { window in
            if documentPath(of: window) != nil { return true }
            return ["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXSheet"]
                .contains(stringAttribute(window, kAXSubroleAttribute as String))
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
        /// Frontmost AND publishing a tree. The second half is what
        /// `AXFrontmost` alone cannot promise; see `logicPublishesItsWindows`.
        func ready() -> Bool { frontmost() && logicPublishesItsWindows() }
        if ready() { return }
        if !frontmost() {
            application.activate()
            for _ in 0..<10 where !ready() {
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
            for _ in 0..<10 where !ready() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if !ready() {
            // THE LAST RESORT, and the only one measured to work from the
            // collapsed state above: an AppleScript `activate`. Neither
            // `NSRunningApplication.activate()` nor the system-wide
            // `AXFocusedApplication` write brought the window tree back —
            // after this one, `AXWindows` listed the modal alert, the Tracks
            // window and Transport immediately, every time (R2 import research
            // 2026-08-30 §2). It goes through the house AppleScript helper
            // rather than a second Process spawn of its own; `source` is a
            // constant, so nothing agent-controlled can reach osascript.
            _ = LogicAccessibility.runAppleScript(
                #"tell application "Logic Pro" to activate"#
            )
            for _ in 0..<15 where !ready() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        // The REFUSAL is still `AXFrontmost` alone, deliberately: a Logic with
        // no project open publishes no document window, and a tool that only
        // needs the key focus (a save, a key command) must not start failing
        // because the tree looks thin. An unpublished tree escalates; it does
        // not refuse.
        guard frontmost() else {
            throw LogicianError.writeFailed("Logic could not be brought frontmost; refusing to interact with \(label)")
        }
    }

    func controlBarGroup() throws -> AXUIElement {
        try controlBarGroup(in: projectWindow())
    }

    /// The same lookup against a window the caller has already resolved, so a
    /// reader that also wants the project document path does not walk Logic's
    /// window list a second time to get it — `projectWindow()` filters on
    /// `documentPath(of:) != nil` and then throws the path away.
    func controlBarGroup(in mainWindow: AXUIElement) throws -> AXUIElement {
        let bar = firstDescendant(of: mainWindow, maximumDepth: AXDepth.controlBar) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXGroup"
                && stringAttribute(element, kAXDescriptionAttribute as String)
                    == LogicUIStrings.Element.controlBar
                && stringAttribute(element, kAXHelpAttribute as String)
                    .hasPrefix(LogicUIStrings.Element.controlBarHelpPrefix)
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
            stringAttribute($0, kAXDescriptionAttribute as String) == LogicUIStrings.Element.controlBar
        }) else { return nil }
        return children(of: inner).first {
            stringAttribute($0, kAXDescriptionAttribute as String)
                == LogicUIStrings.Element.playheadPosition
        }
    }

    func sliderValue(_ group: AXUIElement, _ description: String) -> Int? {
        children(of: group)
            .first { stringAttribute($0, kAXDescriptionAttribute as String) == description }
            .flatMap { Int(stringAttribute($0, kAXValueAttribute as String)) }
    }

}
