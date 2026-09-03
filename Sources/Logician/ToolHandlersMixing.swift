import Foundation

/// What the VOLUME half of one `logic_set_track_mix` call asks for, resolved
/// against the value the fader is actually sitting at.
///
/// The whole point is that BOTH routes (control surface and inspector strip)
/// already read the current dB before they move anything, so "2 dB louder" and
/// "only if it is still at -6" can be answered from a value the write path has
/// in hand — no extra read, no read-then-guess round trip for the agent.
///
/// Pure and unit-tested: this is arithmetic and a comparison, and getting
/// either wrong writes a wrong fader value that reports itself as verified.
struct VolumeWrite {
    /// `volume_db`, when the caller named an absolute target.
    let absoluteDb: Double?
    /// `relative_volume_db`, when the caller named an offset instead.
    let relativeDb: Double?
    /// `expected_current_volume_db`, the compare-and-set precondition.
    let expectedCurrentDb: Double?

    /// How far a reading may sit from `expected_current_db` and still count as
    /// a match. Results round dB to one decimal and Logic's own steps are
    /// 0.1-0.3 dB apart, so a tighter window would refuse an agent that passed
    /// back exactly the number the previous call reported.
    static let preconditionToleranceDb = 0.5

    init(absoluteDb: Double?, relativeDb: Double?, expectedCurrentDb: Double?) throws {
        guard absoluteDb == nil || relativeDb == nil else {
            throw LogicianError.invalidArguments(
                "volume_db and relative_volume_db are mutually exclusive: volume_db is an ABSOLUTE"
                    + " target, relative_volume_db an offset from the value read immediately before"
                    + " the write. Pass one of them. NOTHING was written."
            )
        }
        guard absoluteDb != nil || relativeDb != nil else {
            throw LogicianError.invalidArguments(
                "missing number: volume_db (the absolute target in dB) or relative_volume_db"
                    + " (an offset in dB from the current value, e.g. 2 for '2 dB louder')"
            )
        }
        self.absoluteDb = absoluteDb
        self.relativeDb = relativeDb
        self.expectedCurrentDb = expectedCurrentDb
    }

    private init(absoluteDb: Double) {
        self.absoluteDb = absoluteDb
        self.relativeDb = nil
        self.expectedCurrentDb = nil
    }

    /// For the INTERNAL callers that already hold the exact dB they want
    /// (automation calibration, restores) — no argument parsing, no
    /// precondition, and no way to be mis-constructed.
    static func absolute(_ db: Double) -> VolumeWrite { VolumeWrite(absoluteDb: db) }

    /// The dB to converge on, given what the fader reads right now.
    /// Throws `precondition_failed` when `expected_current_db` disagrees with
    /// that reading — before a single tick is sent.
    func target(currentDb: Double) throws -> Double {
        if let expected = expectedCurrentDb,
           abs(currentDb - expected) > VolumeWrite.preconditionToleranceDb {
            throw LogicianError.currentValueMismatch(
                expected: String(format: "%.1f dB", expected),
                actual: String(format: "%.1f dB", currentDb)
            )
        }
        if let absoluteDb { return absoluteDb }
        return currentDb + (relativeDb ?? 0)
    }
}

/// What ONE `logic_set_track_mix` call asks of a track: any subset of the four
/// independent scalar settings of a channel strip, parsed and cross-checked
/// BEFORE the first of them is written.
///
/// Four tools became one (`logic_set_track_volume`, `_pan`, `_mute`, `_solo`,
/// 2026-09-03 token audit fold #4: 6,280 bytes of `tools/list` for four
/// descriptions that repeated the same addressing, verification and
/// compare-and-set rules four times). The four WRITE paths are untouched — the
/// fold is the surface, and this struct is the whole of the new argument
/// handling, which is why it is pure and unit-tested: an ordering or
/// mutual-exclusion mistake here writes a value nobody asked for and then
/// reports it as verified.
struct TrackMixPlan {
    /// The four settings, in the ORDER they are written.
    ///
    /// Solo last, mute second-last, and not for tidiness: Logic flashes the
    /// mute LED of every channel a standing solo silences, so the mute
    /// readback has to be taken across a blink window (1.4 s) instead of a
    /// settled one (0.3 s) whenever a solo stands. Writing mute BEFORE solo
    /// means one call asking for both does not open that window on itself.
    enum Parameter: String, CaseIterable {
        case volume, pan, mute, solo
    }

    /// A pan write and its own precondition.
    struct PanWrite: Equatable {
        let position: Int
        let expectedCurrent: Int?
    }

    /// A mute or solo write and its own precondition.
    struct ToggleWrite: Equatable {
        let enabled: Bool
        let expectedCurrent: Bool?
    }

    let volume: VolumeWrite?
    let pan: PanWrite?
    let mute: ToggleWrite?
    let solo: ToggleWrite?

    /// Exactly the parameters this call asked for, in write order.
    var order: [Parameter] {
        Parameter.allCases.filter { parameter in
            switch parameter {
            case .volume: return volume != nil
            case .pan: return pan != nil
            case .mute: return mute != nil
            case .solo: return solo != nil
            }
        }
    }

    init(arguments: [String: Any]) throws {
        let absolute = MCPServer.doubleArgument("volume_db", in: arguments)
        let relative = MCPServer.doubleArgument("relative_volume_db", in: arguments)
        // Only built when a volume target was actually named: VolumeWrite's own
        // "one of the two is required" guard is for the fader tool it came
        // from, and here a call that names no volume at all is asking for the
        // other three parameters.
        volume = absolute == nil && relative == nil ? nil : try VolumeWrite(
            absoluteDb: absolute, relativeDb: relative,
            expectedCurrentDb: MCPServer.doubleArgument("expected_current_volume_db", in: arguments)
        )
        pan = try TrackMixPlan.integer("pan", in: arguments).map {
            PanWrite(
                position: $0,
                expectedCurrent: try TrackMixPlan.integer("expected_current_pan", in: arguments)
            )
        }
        mute = (arguments["mute"] as? Bool).map {
            ToggleWrite(enabled: $0, expectedCurrent: arguments["expected_current_mute"] as? Bool)
        }
        solo = (arguments["solo"] as? Bool).map {
            ToggleWrite(enabled: $0, expectedCurrent: arguments["expected_current_solo"] as? Bool)
        }
        guard volume != nil || pan != nil || mute != nil || solo != nil else {
            throw LogicianError.invalidArguments(
                "nothing to set. Pass at least one of volume_db (or relative_volume_db), pan,"
                    + " mute, solo — any subset of them goes in ONE call. NOTHING was written."
                    + " To READ the current values instead, call logic_track_info or"
                    + " logic_mixer_snapshot."
            )
        }
        // A guard for a parameter this call does not write is a typo, and
        // silently dropping it would tell the caller a precondition had been
        // checked that never was — the same reason `additionalProperties:
        // false` is enforced on every schema.
        try TrackMixPlan.refuseGuardWithoutItsWrite(
            "expected_current_volume_db", for: "volume_db or relative_volume_db",
            requested: volume != nil, in: arguments
        )
        try TrackMixPlan.refuseGuardWithoutItsWrite(
            "expected_current_pan", for: "pan", requested: pan != nil, in: arguments
        )
        try TrackMixPlan.refuseGuardWithoutItsWrite(
            "expected_current_mute", for: "mute", requested: mute != nil, in: arguments
        )
        try TrackMixPlan.refuseGuardWithoutItsWrite(
            "expected_current_solo", for: "solo", requested: solo != nil, in: arguments
        )
    }

    private static func refuseGuardWithoutItsWrite(
        _ guardKey: String, for parameter: String, requested: Bool, in arguments: [String: Any]
    ) throws {
        guard arguments[guardKey] != nil, !requested else { return }
        throw LogicianError.invalidArguments(
            "\(guardKey) was passed without \(parameter): a compare-and-set guards ONE write and"
                + " this call asks for no \(parameter.hasPrefix("volume") ? "volume" : parameter)"
                + " write. NOTHING was written."
        )
    }

    /// The top-level verdict of one call, assembled from the per-parameter
    /// sections it produced — in write order, each one either a write path's own
    /// payload or a refusal this tool built.
    ///
    /// Pure, and the reason it is pure: `success` and `verified` here are
    /// CONJUNCTIONS, and a conjunction with one term read wrong is a result
    /// claiming a write nobody made. Each section keeps its own vocabulary
    /// (`volume_set`, `already_on`, `mute_led_blinking`, …) so an agent that
    /// read `logic_mixer_snapshot` meets one set of words rather than two; what
    /// this adds is the roll-up — which parameters landed, which were already
    /// there, which were refused — plus the top-level `state` that decides
    /// whether the "judge it by ear" note is owed (see `Tool.changedNothing`).
    static func verdict(
        sections: [(parameter: String, payload: [String: Any])]
    ) -> [String: Any] {
        var written: [String] = []
        var unchanged: [String] = []
        var refused: [String] = []
        var notAttempted: [String] = []
        var refusals: [String] = []
        var verified = true
        var result: [String: Any] = [:]
        for (parameter, payload) in sections {
            result[parameter] = payload
            if payload["verified"] as? Bool != true { verified = false }
            switch payload["state"] as? String {
            case "refused":
                refused.append(parameter)
                refusals.append(
                    "\(parameter) (\(payload["error_code"] as? String ?? "failed")):"
                        + " \(payload["error"] as? String ?? "no reason given")"
                )
            case "not_attempted":
                notAttempted.append(parameter)
            default:
                if Tool.changedNothing(payload) {
                    unchanged.append(parameter)
                } else {
                    written.append(parameter)
                }
            }
        }
        result["success"] = refused.isEmpty && notAttempted.isEmpty
        result["verified"] = verified
        // Three answers, and the difference between them is what a caller acts
        // on: `set` (something landed), `already_set` (every parameter was
        // already where it was asked to be, so there is nothing to judge by
        // ear — see `Tool.changedNothing`), and `refused` (nothing landed at
        // all, which must not read as `set` just because a write was tried).
        if !written.isEmpty {
            result["state"] = "set"
        } else if refused.isEmpty && notAttempted.isEmpty {
            result["state"] = "already_set"
        } else {
            result["state"] = "refused"
        }
        if !written.isEmpty { result["written"] = written }
        if !unchanged.isEmpty { result["unchanged"] = unchanged }
        if !refused.isEmpty { result["refused"] = refused }
        if !notAttempted.isEmpty { result["not_attempted"] = notAttempted }
        if !refusals.isEmpty {
            appendWarning(
                "\(refused.count + notAttempted.count) of \(sections.count) parameter(s) were NOT"
                    + " written: " + refusals.joined(separator: " | ")
                    + (notAttempted.isEmpty
                        ? ""
                        : ". Not attempted after that: \(notAttempted.joined(separator: ", "))")
                    + (written.isEmpty
                        ? ". Nothing was written."
                        : ". These WERE written: \(written.joined(separator: ", "))"
                            + " — read each parameter's own section for its readback."),
                to: &result
            )
        }
        return result
    }

    /// Unreachable by construction — `order` yields a parameter only when its
    /// request exists — and a refusal rather than a default value or an empty
    /// payload, because the one thing this must never do is write a number
    /// nobody asked for.
    static func missingRequest(_ parameter: Parameter) -> LogicianError {
        .invalidArguments("no \(parameter.rawValue) write was requested. NOTHING was written.")
    }

    /// A knob position, however the client typed it. JSON `5` and `5.0` are the
    /// same position and `as? Int` alone refuses the second — worth answering
    /// here rather than in a "missing integer" refusal, because `pan` now
    /// travels beside `volume_db`, which is a genuine `number`.
    static func integer(_ key: String, in arguments: [String: Any]) throws -> Int? {
        if let value = arguments[key] as? Int { return value }
        guard let value = arguments[key] else { return nil }
        guard let double = value as? Double, double == double.rounded() else {
            throw LogicianError.invalidArguments(
                "\(key) must be a whole knob position (typically -64..63, 0 at center),"
                    + " not \(value). NOTHING was written."
            )
        }
        return Int(double)
    }
}

// Mixing: volume, pan, mute, solo, sends and tempo.
extension MCPServer {
    /// The four strip settings in one call, each verified as its own tool
    /// verified it, each reporting its own section of the result.
    ///
    /// The parameters are INDEPENDENT, so a compare-and-set that refuses one of
    /// them refuses only that one: the guard says something about the fader, or
    /// the mute, and nothing about the other three. What is NOT independent is
    /// the plane they all ride on — when the strip itself cannot be addressed
    /// there is nothing to be learned from asking three more times, so the
    /// first non-precondition failure stops the call and the parameters behind
    /// it are reported `not_attempted` rather than paid for.
    func handleSetTrackMix(_ arguments: [String: Any]) throws -> Any {
        let plan = try TrackMixPlan(arguments: arguments)
        let track = try requiredString("track_name", in: arguments)
        let trackNumber = arguments["track_number"] as? Int
        let toleranceDb = doubleArgument("tolerance_db", in: arguments) ?? 0.15
        var sections: [(parameter: String, payload: [String: Any])] = []
        var stopped: String?

        for parameter in plan.order {
            if let stopped {
                sections.append((parameter.rawValue, [
                    "success": false, "verified": false, "state": "not_attempted",
                    "reason": "nothing was written for \(parameter.rawValue): " + stopped
                ]))
                continue
            }
            do {
                sections.append((parameter.rawValue, try write(
                    parameter, plan: plan, track: track, trackNumber: trackNumber,
                    toleranceDb: toleranceDb
                )))
            } catch {
                let code = (error as? LogicianError)?.code ?? "failed"
                // Nothing has happened yet and the very first parameter failed
                // for a reason that is not about ITS value: the whole call is a
                // clean refusal, reported exactly as the single-parameter tool
                // used to report it.
                if sections.isEmpty && code != "precondition_failed" { throw error }
                sections.append((parameter.rawValue, [
                    "success": false, "verified": false, "state": "refused",
                    "error_code": code, "error": error.localizedDescription
                ]))
                if code != "precondition_failed" {
                    stopped = "the \(parameter.rawValue) write failed with \(code), so this call"
                        + " stopped instead of asking the same strip three more times"
                }
            }
        }

        var result: [String: Any] = ["track": track, "track_name": track]
        for (key, value) in TrackMixPlan.verdict(sections: sections) { result[key] = value }
        return result
    }

    /// One parameter of the plan, through the same route its own tool took.
    private func write(
        _ parameter: TrackMixPlan.Parameter, plan: TrackMixPlan,
        track: String, trackNumber: Int?, toleranceDb: Double
    ) throws -> [String: Any] {
        switch parameter {
        case .volume:
            guard let request = plan.volume else { throw TrackMixPlan.missingRequest(parameter) }
            return try MCUController.setVolume(
                trackName: track, request: request, toleranceDb: toleranceDb
            ) ?? logic.setTrackVolume(
                trackName: track, trackNumber: trackNumber,
                request: request, toleranceDb: toleranceDb
            )
        case .pan:
            guard let write = plan.pan else { throw TrackMixPlan.missingRequest(parameter) }
            return try logic.setTrackPan(
                trackName: track, trackNumber: trackNumber,
                position: write.position, expectedCurrentPosition: write.expectedCurrent
            )
        case .mute, .solo:
            guard let write = parameter == .mute ? plan.mute : plan.solo else {
                throw TrackMixPlan.missingRequest(parameter)
            }
            // Both routes already read the control's current state before
            // deciding whether to press it, so compare-and-set costs nothing
            // extra here.
            return try MCUController.setToggle(
                trackName: track, control: parameter.rawValue, enabled: write.enabled,
                expectedCurrent: write.expectedCurrent
            ) ?? logic.setStripToggle(
                trackName: track, trackNumber: trackNumber, control: parameter.rawValue,
                enabled: write.enabled, expectedCurrent: write.expectedCurrent
            )
        }
    }

    func handleAddSend(_ arguments: [String: Any]) throws -> Any {
        let track = try requiredString("track_name", in: arguments)
        let level = (arguments["level_db"] as? Double)
            ?? (arguments["level_db"] as? Int).map(Double.init)
        guard let addedSend = try MCUController.addSend(
            logic: logic,
            trackName: track,
            destination: requiredString("destination", in: arguments),
            // The level write below runs in the send view this call is
            // already in, so hand it the view instead of walking home and
            // pressing straight back in. Everything after this point is
            // responsible for the restore.
            restoringView: level == nil
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "send creation via the control surface",
                exposed: "the MCU bridge is unavailable"
            )
        }
        var sendPayload = addedSend
        sendPayload["track"] = track
        // "Send the snare to the plate at -12" is ONE thought and used to be two
        // calls, with the mix silently wrong in between: a new send lands at
        // -oo dB, so an agent that stopped after this tool had created an
        // inaudible send and reported success (COVERAGE U5). The level is set
        // through the same tool logic_mcu_set_send uses, on the strip this call
        // has already selected.
        guard let level, let slot = addedSend["send"] as? Int else { return sendPayload }
        do {
            guard let levelled = try MCUController.setSendLevel(
                sendNumber: slot, targetDb: level, expectedCurrentValue: nil, strip: track
            ) else {
                // `setSendLevel` restores the view from its own defer, but
                // it can refuse before registering one. Exiting twice is a
                // ~100 ms no-op on a surface already in Pan; not exiting at
                // all leaves the send view standing for the next call.
                MCUController.exitToPan()
                throw LogicianError.trackNotExposed(
                    requested: "the send level vpot", exposed: "the send view did not answer"
                )
            }
            sendPayload["level"] = levelled["after"] ?? NSNull()
            sendPayload["level_db_requested"] = level
            sendPayload["level_verified"] = levelled["verified"] ?? false
            sendPayload["level_write_route"] = levelled["write_route"] ?? NSNull()
            sendPayload["state"] = "added_and_levelled"
        } catch {
            // The SEND EXISTS — that write is verified and must not be reported
            // as a failure. What failed is the level, so the send is sitting at
            // -oo dB and the result says exactly that rather than letting an
            // agent assume the whole intent landed.
            // Same reasoning as above: the add handed its restore to the
            // level write, and the level write can throw before it owns one.
            MCUController.exitToPan()
            sendPayload["level_verified"] = false
            sendPayload["level_db_requested"] = level
            sendPayload["level"] = "-oo dB (unchanged)"
            appendWarning(
                "The send WAS created and verified, but its level could not be set to"
                    + " \(formattedBPM(level)) dB (\(error.localizedDescription)). It is therefore"
                    + " still at -oo dB and inaudible: set it with logic_mcu_set_send"
                    + " {send: \(slot), level_db: \(level)} before judging the mix.",
                to: &sendPayload
            )
        }
        return sendPayload
    }

    func handleRemoveSend(_ arguments: [String: Any]) throws -> Any {
        let track = try requiredString("track_name", in: arguments)
        guard var removed = try MCUController.removeSend(
            trackName: track,
            sendNumber: arguments["send"] as? Int,
            destination: arguments["destination"] as? String
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "send removal via the control surface",
                exposed: "the MCU bridge is unavailable"
            )
        }
        removed["track"] = track
        removed["track_name"] = track
        return removed
    }

    func handleMcuSends(_ arguments: [String: Any]) throws -> Any {
        // Selection routes itself: a track through Accessibility, an
        // output/aux/bus strip through the control surface (the send view
        // shows the SELECTED strip either way).
        let target = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
        )
        // The read keeps the send view standing and records the debt, like the
        // send WRITES do: measured 2026-09-02, walking the surface home was
        // 3.4 s of this call's 5.0 s — two thirds of a read spent putting the
        // surface back so the next call could take it somewhere else again.
        // A failure still restores explicitly.
        guard let sends = try MCUController.readSends(restoringView: false) else {
            MCUController.exitToPan()
            throw LogicianError.trackNotExposed(
                requested: "MCU send view",
                exposed: "the MCU bridge is unavailable or the send view did not appear"
            )
        }
        MCUController.deferSurfaceRestore(MCUController.sendViewDebt(strip: target.name))
        var sendsPayload: [String: Any] = [
            "track": target.name,
            "track_name": target.name,
            "sends": sends,
            "note": "Send slots as the Mackie Control channel view shows them; level in dB, position pre/post, status active/muted."
        ]
        sendsPayload.merge(target.resultFields) { current, _ in current }
        return sendsPayload
    }

    func handleMcuSetSend(_ arguments: [String: Any]) throws -> Any {
        guard let send = arguments["send"] as? Int else {
            throw LogicianError.invalidArguments("missing integer: send (1-8)")
        }
        let levelDb = (arguments["level_db"] as? Double)
            ?? (arguments["level_db"] as? Int).map(Double.init)
        guard let targetDb = levelDb else {
            throw LogicianError.invalidArguments("missing number: level_db")
        }
        let target = try selectStripTarget(
            arguments, expectedProjectPath: arguments["expected_project_path"] as? String
        )
        guard var sendResult = try MCUController.setSendLevel(
            sendNumber: send,
            targetDb: targetDb,
            expectedCurrentValue: arguments["expected_current_value"] as? String,
            strip: target.name
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU send level write",
                exposed: "the MCU bridge is unavailable or the send view layout was unexpected"
            )
        }
        sendResult["track"] = target.name
        sendResult["track_name"] = target.name
        sendResult.merge(target.resultFields) { current, _ in current }
        return sendResult
    }

    func handleSetTempo(_ arguments: [String: Any]) throws -> Any {
        let bpm = (arguments["bpm"] as? Double)
            ?? (arguments["bpm"] as? Int).map(Double.init)
        guard let targetBpm = bpm else {
            throw LogicianError.invalidArguments("missing number: bpm")
        }
        let transportBefore = try logic.getTransport()
        let currentBpm = transportBefore["tempo"] as? Double
        if let expected = (arguments["expected_current_bpm"] as? Double)
            ?? (arguments["expected_current_bpm"] as? Int).map(Double.init) {
            guard let current = currentBpm, abs(current - expected) < 0.5 else {
                throw LogicianError.currentValueMismatch(
                    expected: "\(expected) BPM",
                    actual: "\(currentBpm.map { "\($0)" } ?? "unreadable") BPM"
                )
            }
        }
        // The value this tool writes is POSITION-DEPENDENT. The control bar shows
        // the tempo at the playhead, so on a project with a tempo map a slider
        // write does not set "the project tempo" — it edits the tempo node the
        // playhead happens to sit on, which is an edit to the user's tempo track
        // that nothing in the result would have mentioned. Two reads answer
        // whether such a map exists; see `sampleTempoAgainstProjectStart` for why
        // bar 1 is the second point and what two points cannot prove.
        //
        // The Tempo List answers it OUTRIGHT when it can be read (item 3): the
        // whole map, exactly, with no playhead travel at all — where the sample
        // parks the playhead twice and puts it back. So the map is tried first,
        // and the sample is only the fallback.
        let projectPath = try? logic.projectDocumentPath()
        let resolvedMap = resolveTempoMap(projectPath: projectPath)
        if let map = resolvedMap.map, map.source == .tempoList {
            if !map.isConstant {
                throw LogicianError.tempoMapUnsafe(
                    operation: "logic_set_tempo",
                    detail: "the project has a TEMPO MAP — Logic's Tempo List holds"
                        + " \(map.events.count) tempo events"
                        + " (\(map.tempos.map(formattedBPM).joined(separator: ", ")) BPM), read row"
                        + " by row out of the Tempo tab of the List Editors. This tool writes ONE"
                        + " slider, and that slider shows and sets the tempo AT THE PLAYHEAD, so"
                        + " on a mapped project it would edit whichever tempo node the playhead"
                        + " sits on instead of the project tempo — and which node Logic edits, or"
                        + " whether it creates a new one, has not been verified from here."
                        + " NOTHING was written. Change the tempo where the map lives: Logic's"
                        + " tempo track, or the Tempo List (View > List Editors > Tempo), where"
                        + " every tempo event is an editable row. There is deliberately no"
                        + " override argument — parking the playhead and passing"
                        + " expected_current_bpm would still be a single-slider write with"
                        + " unverified semantics, so it is not offered as a workaround."
                )
            }
            let landed = try logic.setTempo(targetBpm)
            // The write moved a tempo node, so whatever the cache holds
            // describes the map as it was BEFORE it. On the single-event map
            // this branch just proved it was writing into, the map AFTER the
            // write is known exactly (same event, `landed` BPM read back off
            // the slider), so the cache is corrected rather than thrown away —
            // which is what spares the next reader a ~780 ms Tempo List read.
            let cacheRoute = rememberTempoMap(
                after: map, landedBPM: landed, projectPath: projectPath
            )
            return [
                "success": true,
                "verified": true,
                "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
                "bpm": landed,
                "write_route": "control_bar_tempo_slider",
                "tempo_map": [
                    "source": "tempo_list",
                    "events": map.events.count,
                    "tempos": map.tempos,
                    "constant": true,
                    "cache": cacheRoute
                ],
                "note": "Whole-BPM resolution (the slider steps 1 BPM). Logic's Tempo List was read and holds a single tempo, so this write set the project tempo rather than one node of a map. No playhead was moved."
            ]
        }
        let tempoSample = logic.sampleTempoAgainstProjectStart()
        if let span = tempoSample.span, !span.isConstant {
            throw LogicianError.tempoMapUnsafe(
                operation: "logic_set_tempo",
                detail: "the project has a TEMPO MAP — \(tempoSample.refusalDetail ?? span.mismatchClause)"
                    + ", both read off the control bar, which shows the tempo AT THE PLAYHEAD."
                    + " This tool writes ONE slider, so on a mapped project it would edit"
                    + " whichever tempo node the playhead sits on (bar \(span.startBar)) instead"
                    + " of the project tempo — and which node Logic edits, or whether it creates"
                    + " a new one, has not been verified from here. NOTHING was written. Change"
                    + " the tempo where the map lives: Logic's tempo track, or the Tempo List"
                    + " (the Tempo tab of the List Editors, also openable as a floating window),"
                    + " where every tempo event is an editable row. There is deliberately no"
                    + " override argument — parking the playhead and passing expected_current_bpm"
                    + " would still be a single-slider write with unverified semantics, so it is"
                    + " not offered as a workaround."
            )
        }
        let landed = try logic.setTempo(targetBpm)
        // Same reason as above: a tempo write can have edited a node of a map
        // that a later call would otherwise read out of the cache.
        invalidateTempoMapCache()
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "before_bpm": currentBpm.map { $0 as Any } ?? NSNull() as Any,
            "bpm": landed,
            "write_route": "control_bar_tempo_slider",
            "note": "Whole-BPM resolution (the slider steps 1 BPM). Refuses when a tempo map is detected: the slider is position-dependent, so on a mapped project it edits one tempo node rather than the project tempo."
        ]
        if let failure = resolvedMap.failure {
            result["tempo_map_read"] = "unavailable: \(failure.reason)"
        }
        if let span = tempoSample.span {
            // What was actually checked, in bars — two agreeing points are
            // evidence of a constant tempo, not proof of one.
            result["tempo_sampled_at_bars"] = [span.startBar, span.endBar]
        }
        appendWarning(tempoSample.writeWarning, to: &result)
        return result
    }
}
