import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Track rendering via Freeze (dialog-free offline export)

    /// Resolves a key command to its learned MIDI note; when missing and the
    /// command is one of the standard set, learns it automatically on the
    /// spot (lazy onboarding — the registry records what was added).
    static func resolveKeyCommand(
        named name: String, logic: LogicAccessibility?,
        learnIfMissing: Bool = false,
        source: String = "logic_setup_key_commands"
    ) throws -> (note: Int, channel: Int) {
        lastResolveLearned = false
        if let found = KeyCommandRegistry.note(named: name) { return found }
        if let logic, let standard = KeyCommandRegistry.standardCommands.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            _ = try? logic.setupKeyCommands([standard])
            if let found = KeyCommandRegistry.note(named: name) {
                lastResolveLearned = true
                return found
            }
        }
        // G00 made lazy onboarding possible for commands that are NOT in the
        // standard set: a tool whose whole job is one Logic command may learn
        // it on the spot, from the free note range, with the registry
        // recording which tool did it. Opt-in per caller (`learnIfMissing`) —
        // never on the generic path, because learning writes into the user's
        // own key command set and that must stay a decision, not a side
        // effect of some unrelated call.
        if learnIfMissing, let logic,
           let note = KeyCommandRegistry.freeNote(taken: KeyCommandRegistry.takenNotes()) {
            _ = try? logic.setupKeyCommands(
                [(search: KeyCommandRegistry.defaultSearchTerm(for: name),
                  name: name, preferredNote: note)],
                source: source
            )
            if let found = KeyCommandRegistry.note(named: name) {
                lastResolveLearned = true
                return found
            }
        }
        throw LogicianError.trackNotExposed(
            requested: "key command '\(name)'",
            exposed: "not in the registry and automatic learning did not succeed; run logic_setup_key_commands with Logic frontmost"
        )
    }

    /// Ensures a track is NOT frozen before a freeze-render cycle starts:
    /// reads the header checkbox, and if frozen sends the toggle and answers
    /// Logic's unfreeze confirmation dialog.
    static func ensureUnfrozen(logic: LogicAccessibility, trackName: String) throws {
        guard logic.trackFreezeState(trackName: trackName) == true else { return }
        guard let freeze = try? resolveKeyCommand(
            named: KeyCommandRegistry.Name.toggleTrackFreeze, logic: logic
        ) else { return }
        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)
        var answered = false
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.2)
            if logic.answerFreezeDialog() { answered = true; break }
            if logic.trackFreezeState(trackName: trackName) == false { return }
        }
        _ = answered
        for _ in 0..<20 {
            if logic.trackFreezeState(trackName: trackName) == false { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw LogicianError.verificationFailed(
            requested: "unfreeze of '\(trackName)' before rendering",
            actual: "the track header's freeze button is still lit",
            restored: false
        )
    }

    /// Renders the SELECTED track offline by toggling Track Freeze and
    /// pressing play: Logic writes a 32-bit float AIFF into the project's
    /// Media/Freeze Files with no dialogs. The file is copied out before the
    /// freeze is toggled back off (Logic deletes it on unfreeze).
    /// `restorePlayhead: false` is for a caller that already owns the
    /// playhead — `logic_record_midi` parks and restores it around its whole
    /// take, verification render included, and a second restore inside this
    /// function would step the same sliders twice for the same position.
    /// `includeAudio: false` skips the ear encode outright rather than paying
    /// for a block the transport is about to drop.
    static func renderSelectedTrack(
        projectPath: String, label: String,
        sliceStartSeconds: Double? = nil, sliceEndSeconds: Double? = nil,
        logic: LogicAccessibility? = nil, trackName: String? = nil,
        restorePlayhead: Bool = true, includeAudio: Bool = true
    ) throws -> [String: Any] {
        let freeze = try resolveKeyCommand(named: KeyCommandRegistry.Name.toggleTrackFreeze, logic: logic)
        // WHERE THE PLAYHEAD WAS. The stop press below jumps to the project
        // start by design and the play roll then carries it forward, so this
        // tool MOVES the user's playhead: measured 2026-09-02, a baseline of
        // bar 41 beat 3 read bar 8 beat 4 after four renders, with nothing in
        // the description or the result saying so. Read before anything is
        // touched (~6 ms, one control-bar walk) and put back at the end, the
        // way `logic_record_midi` already does.
        var savedPlayhead: (bar: Int, beat: Int)?
        if restorePlayhead, let logic, let transport = try? logic.getTransport(),
           let bar = transport["playhead_bar"] as? Int {
            savedPlayhead = (bar, transport["playhead_beat"] as? Int ?? 1)
        }
        // A rolling transport queues freeze dialogs invisibly and swallows
        // toggles — make sure we start from silence. And a track that is
        // ALREADY frozen must be thawed first, or the toggle inverts.
        _ = try? setPlaying(false)
        // Play does NOTHING when the playhead sits at/past the project end,
        // so the freeze render would never start. Stop-when-stopped jumps
        // to the project start — pure MCU, position-safe.
        _ = try? MCUBridge.send(.press(button: "stop"))
        if let logic, let trackName {
            // LOOK BEFORE YOU SLEEP. A blind `Thread.sleep(0.4)` used to sit
            // here to let the stop settle, with the decisive read on the very
            // next line: `ensureUnfrozen` asks Logic's own track header
            // (44–67 ms measured 2026-09-02, 4/4) and an answer from the
            // Accessibility tree IS the evidence the sleep was waiting for.
            // 405 ms, 4/4, for nothing.
            //
            // Progress runs 0…100 for the whole render, and the freeze wait
            // below owns most of it: the phases before it are seconds, the
            // render itself is minutes.
            reportProgress("thawing the track before the render", percent: 3)
            try ensureUnfrozen(logic: logic, trackName: trackName)
        } else {
            // Nothing here can observe the transport, so the blind settle
            // stays exactly where the evidence is missing.
            Thread.sleep(forTimeInterval: 0.4)
        }
        let freezeDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("Media/Freeze Files")
        let manager = FileManager.default
        func freezeFiles() -> Set<String> {
            Set((try? manager.contentsOfDirectory(atPath: freezeDir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
        }
        let baseline = freezeFiles()

        /// Puts the track back the way this function found it - ensureUnfrozen
        /// guarantees that is UNFROZEN - and reports whether that could be
        /// CONFIRMED. Every exit between arming Freeze and the final unfreeze
        /// goes through here, so no path can leave the project changed while
        /// the error says otherwise, and no `restored` flag is ever a guess.
        /// `certainlyFrozen` marks the paths where a freeze render demonstrably
        /// happened, so the toggle is safe with no header to read; elsewhere a
        /// blind re-toggle would FREEZE a never-frozen track.
        func restoreUnfrozen(certainlyFrozen: Bool, renderedFile: String? = nil) -> Bool {
            func header() -> Bool? {
                guard let logic, let trackName else { return nil }
                return logic.trackFreezeState(trackName: trackName)
            }
            if !certainlyFrozen {
                switch header() {
                case .some(false): return true  // never armed; nothing to undo
                case .some(true): break         // armed; toggle it back
                case nil:
                    // No readable header. We pressed the toggle ourselves, so
                    // press it back - blind, and therefore unconfirmable.
                    _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
                    return false
                }
            }
            guard (try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)) != nil else {
                return false
            }
            guard renderedFile != nil || (logic != nil && trackName != nil) else {
                return false  // toggled, but nothing here can observe the result
            }
            var cleared = false
            for attempt in 0..<40 {
                // Unfreeze makes Logic delete the freeze file again; that is
                // the signal that survives without an Accessibility handle.
                if let file = renderedFile, !freezeFiles().contains(file) { cleared = true; break }
                if renderedFile == nil, header() == false { cleared = true; break }
                if attempt % 4 == 3, let logic { _ = logic.answerFreezeDialog() }
                Thread.sleep(forTimeInterval: 0.25)
            }
            // The header is the authority whenever it is readable.
            if header() == true { cleared = false }
            return cleared
        }

        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)

        // Freeze arms instantly (the header checkbox flips before any render
        // starts). If it refuses to arm there is no point pressing play and
        // waiting out the long timeout - fail fast with the structural cause.
        if let logic, let trackName {
            var armed = false
            var checkboxSeen = false
            for _ in 0..<8 {
                if let state = logic.trackFreezeState(trackName: trackName) {
                    checkboxSeen = true
                    if state { armed = true; break }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if !armed {
                throw LogicianError.openVerificationFailed(checkboxSeen
                    ? "Logic refuses to arm Freeze on this track: the header checkbox exists "
                        + "but stays off (verified via Accessibility). Common causes: the track "
                        + "shares its channel strip with another track (e.g. a duplicated track "
                        + "for the same channel), or it has nothing to render. Use "
                        + "logic_evaluate_change with method 'bounce', or logic_bounce_range "
                        + "with the track soloed, instead."
                    : "this track has no Freeze button in its header (track stacks and buses "
                        + "cannot be frozen; or the Freeze header component is hidden: "
                        + "Track > Configure Track Header > Freeze). Use method 'bounce' instead. "
                        + "If freeze recently worked on other tracks, run "
                        + "logic_setup_key_commands with relearn: true to repair the binding.")
            }
        }
        reportProgress("freeze armed; rolling the transport", percent: 10)
        // A PRESS, not a verified `setPlaying(true)`. Logic does not light the
        // MCU play LED during an offline freeze render, so the readback could
        // only ever wait out its whole budget: measured 2 487 / 2 487 / 2 474
        // ms against `pollStatus`'s 15 x 0.15 s (2026-09-02), three values
        // inside 13 ms of each other, with the throw swallowed by `try?` and
        // the render's own positive proof — the `.aif` and
        // `FreezeInProgress.lock` — found 0.2 ms later, 3/3. Negative proof of
        // something that cannot happen, paid in full where a positive one was
        // already in hand. The loop below still proves the render STARTED, and
        // its 10 s `startDeadline` still catches a toggle or a press that never
        // engaged; that refusal names the swallowed press among its causes.
        _ = try? press("play")

        // The render announces itself with FreezeInProgress.lock plus the
        // growing .aif; completion is the lock disappearing AND the file
        // holding audio.
        //
        // "the lock is gone" alone is not completion, measured 2026-09-02:
        // Logic publishes the `.aif` as a 4 096-byte header (FORM size 504,
        // `numSampleFrames` 0) before it streams a single sample, and twice in
        // one session that snapshot was visible with no lock beside it — the
        // call returned a 0-frame capture in 3.3 s where a real render takes
        // 4.3–4.9 s. So the file's own COMM chunk has to agree that there is
        // audio in it before this loop calls the render finished.
        func renderedFileComplete(_ name: String) -> Bool? {
            let url = freezeDir.appendingPathComponent(name)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            let head = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            return LogicAccessibility.audioRenderComplete(head: head, fileSize: size)
        }
        var newAudio: String?
        var renderStarted = false
        let startDeadline = Date().addingTimeInterval(10)
        let renderBudget: TimeInterval = 180
        let renderStart = Date()
        let deadline = renderStart.addingTimeInterval(renderBudget)
        while Date() < deadline {
            // Cancelling here throws past `restoreUnfrozen`, so the track is
            // left frozen and the transport rolling — which is why the throw
            // goes through `stopAndUnfreeze` first.
            if callSession.isCancelled {
                _ = try? setPlaying(false)
                _ = restoreUnfrozen(certainlyFrozen: false)
                throw RequestCancelled()
            }
            // Logic publishes no render percentage, so the NUMBER tracks the
            // 180 s budget and the MESSAGE carries the bytes actually written.
            reportProgress(
                "rendering (freeze)", percent: 10 + 75 * min(Date().timeIntervalSince(renderStart) / renderBudget, 0.99),
                throttle: 1
            )
            let fresh = freezeFiles().subtracting(baseline)
            if !fresh.isEmpty { renderStarted = true }
            if let audio = fresh.first(where: { $0.hasSuffix(".aif") || $0.hasSuffix(".wav") }),
               !fresh.contains("FreezeInProgress.lock"),
               // nil = a container this cannot judge; keep the old evidence
               // (no lock) rather than wait for a verdict that never comes.
               renderedFileComplete(audio) != false {
                newAudio = audio
                break
            }
            // A modal alert freezes the whole flow — the MCU timecode
            // mirrors it as 'ALERT'. And if no freeze activity showed up
            // within seconds of play, the toggle never engaged (track
            // stacks and buses cannot be frozen) — Logic is just playing.
            if let timecode = freshStatus()?["timecode"] as? String,
               timecode.contains(MCULCDStrings.modalAlertTimecode) {
                _ = try? setPlaying(false)
                _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
                throw LogicianError.openVerificationFailed(
                    "Logic is showing a modal alert (MCU timecode reads ALERT); dismiss it and retry"
                )
            }
            if !renderStarted && Date() > startDeadline { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        _ = try? setPlaying(false)

        guard let rendered = newAudio else {
            // Restore state: only toggle back when the track actually shows
            // as frozen (a blind re-toggle would freeze a never-frozen track).
            let restored = restoreUnfrozen(certainlyFrozen: false)
            throw LogicianError.openVerificationFailed(
                (renderStarted
                    ? "freeze render started but no finished file appeared within 180 s"
                    : "freeze never engaged within 10 s of play. Likely causes: the track is a stack or bus (not freezable), it has nothing to render, the Freeze button is not enabled in the track header (Logic: Track > Configure Track Header > Freeze), the play press was swallowed by Logic, or the Toggle Track Freeze key-command binding is orphaned - run logic_setup_key_commands with relearn: true to repair")
                    + (restored
                        ? ". The track was returned to its unfrozen state."
                        : ". The track could NOT be confirmed unfrozen - check the track header and unfreeze it manually if it is still lit.")
            )
        }

        // The lock can vanish before Logic finishes writing the file (a
        // 4 KB header-only snapshot copies otherwise), so the file must be
        // proven complete before it is copied.
        //
        // The PROOF is the file, not the clock. An AIFF declares both the
        // payload that follows its FORM header and, in COMM, how many sample
        // frames it holds — so "every declared byte is present AND there are
        // frames" is a positive, absolute answer (`audioRenderComplete`),
        // where "the size did not change over 100 ms" also holds for a render
        // Logic has merely paused writing. This loop used to demand THREE
        // rounds of size stability 0.3 s apart, which is a 0.9 s blind FLOOR
        // on a file that was already 48 237 672 bytes and complete on the
        // first look — measured 913–915 ms, 4/4, 2026-09-02. One decisive
        // look now ends it; size stability stays as the fallback for a
        // container this cannot judge, and a file that never completes is
        // REPORTED rather than copied silently.
        let renderedURL = freezeDir.appendingPathComponent(rendered)
        var stableSize: UInt64 = 0
        var stableRounds = 0
        var flushed = false
        let flushDeadline = Date().addingTimeInterval(30)
        reportProgress("render finished; waiting for Logic to flush the file", percent: 86)
        while Date() < flushDeadline {
            try checkCancelled()
            let size = (try? manager.attributesOfItem(atPath: renderedURL.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0
            var header = Data()
            if let handle = try? FileHandle(forReadingFrom: renderedURL) {
                header = (try? handle.read(upToCount: 4096)) ?? Data()
                try? handle.close()
            }
            switch LogicAccessibility.audioRenderComplete(head: header, fileSize: size) {
            case .some(true):
                stableSize = size
                flushed = true
            case .some(false):
                stableRounds = 0
            case .none:
                // Neither AIFF nor WAV — never seen out of Logic's freeze,
                // which writes 32-bit float AIFF. Two agreeing sizes are the
                // only evidence left, so they are what this waits for.
                if size > 0, size == stableSize { stableRounds += 1 } else { stableRounds = 0 }
                if stableRounds >= 2 { flushed = true }
            }
            if flushed { break }
            stableSize = size
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Copy out before unfreezing (unfreeze deletes the file).
        let captures = Captures.ensureRoot()
        // A freeze render is always the whole PROJECT length whatever bars
        // were asked for — ~46 MB per call on the reference project — and
        // until 2026-09-02 nothing ever removed one: 169 files / 1.2 GB, of
        // which 71 render leftovers. The sweep runs BEFORE the copy so the
        // room is made for the file about to be written, and it reports what
        // it took rather than pruning the user's folder silently.
        let pruned = Captures.makeRoom()
        let stamp = Int(Date().timeIntervalSince1970)
        let safeLabel = sanitizedFilenameComponent(label, fallback: "render")
        // The name is only second-resolution, so two renders of the same label
        // inside one second collided - and a collision here threw from
        // copyItem with the track still frozen. Walk a suffix until the name
        // is free; the stamp still identifies the render.
        let extensionName = URL(fileURLWithPath: rendered).pathExtension
        var stem = "render-\(safeLabel)-\(stamp)"
        var attemptIndex = 2
        while manager.fileExists(atPath:
            captures.appendingPathComponent("\(stem).\(extensionName)").path), attemptIndex < 1000 {
            stem = "render-\(safeLabel)-\(stamp)-\(attemptIndex)"
            attemptIndex += 1
        }
        let destination = captures.appendingPathComponent("\(stem).\(extensionName)")
        do {
            try manager.copyItem(at: renderedURL, to: destination)
        } catch {
            // THE one non-optional throw between arming freeze and unfreezing.
            // A full disk, a permission error or a name collision used to
            // escape here leaving the track frozen, the freeze file on disk and
            // no word of it in the error. Restore first, then report - with a
            // `restored` flag that was actually checked.
            let restored = restoreUnfrozen(certainlyFrozen: true, renderedFile: rendered)
            throw LogicianError.verificationFailed(
                requested: "copy of the freeze render to \(destination.path)",
                actual: "the copy failed: \(error.localizedDescription)",
                restored: restored
            )
        }

        // Unfreeze and verify Logic removed the freeze file again; answer the
        // confirm dialog if the toggle raises one, and double-check via the
        // header checkbox when we can. A failure to even SEND the toggle no
        // longer throws past the caller: the capture is already safe on disk,
        // so it is reported through `unfrozen: false` like every other way
        // this can fail to restore.
        reportProgress("copied out (\(stableSize) bytes); unfreezing the track", percent: 92)
        let unfroze = restoreUnfrozen(certainlyFrozen: true, renderedFile: rendered)

        var result: [String: Any] = [
            "success": true,
            "verified": unfroze,
            "path": destination.path,
            "write_route": "freeze_render_headless",
            "unfrozen": unfroze,
            "note": unfroze
                ? "Track rendered offline via Freeze (no dialogs) and unfrozen again; the file is the full track from project start, mono/stereo as the track."
                : "Rendered file copied out, but the freeze file is still present — the track may still be frozen; toggle freeze manually or rerun."
        ]
        if let pruned { result["captures_pruned"] = pruned }
        // The playhead goes back where the caller had it, before anything
        // slow (the preview and the ear encode) is paid for: the render is
        // safe on disk from here on, so the project's own state is what
        // deserves the next call. Stepping the control bar's bar slider costs
        // ~0.1 s per bar of distance (measured 2026-09-02: 8.13–8.55 s for a
        // render whose playhead was 7 bars from the project start, 11.8 s for
        // one 55 bars away), which is the honest price of not leaving the
        // user's playhead somewhere they did not put it.
        if let logic, let saved = savedPlayhead {
            let report = restorePlayheadReport(logic: logic, saved: saved)
            result["playhead"] = report
            if report["restored"] as? Bool != true {
                appendWarning(report["note"] as? String, to: &result)
            }
        }
        if let metrics = LogicAccessibility.audioFileMetrics(path: destination.path),
           (metrics["frames"] as? Int ?? 0) > 0 {
            result["metrics"] = metrics
        } else {
            appendWarning(
                "the rendered file contains no audio — does the track have any regions?",
                to: &result
            )
        }
        if !flushed {
            appendWarning(
                "Logic never confirmed the render was fully written (30 s): \(stableSize) bytes"
                    + " were copied while the AIFF still does not cover the size it declares or"
                    + " reports no sample frames, so the file may be a header-only snapshot."
                    + " Render again, or read what is there with logic_get_audio_clip.",
                to: &result
            )
        }
        if let start = sliceStartSeconds, let end = sliceEndSeconds {
            // Derived from the (collision-free) capture name so the slice
            // cannot collide either.
            let slicePath = captures.appendingPathComponent("\(stem)-slice.wav").path
            if let slice = LogicAccessibility.sliceAudioFile(
                path: destination.path, startSeconds: start, endSeconds: end,
                destinationPath: slicePath
            ) {
                result["slice"] = slice
            } else {
                result["slice_warning"] =
                    "slicing failed — the requested range may lie beyond the rendered audio"
            }
        }
        // ONE encode of the audio the caller asked to HEAR, where there used
        // to be two of different files: a 128 kbps preview of the whole
        // 136.7 s render (1 265 ms, measured 2026-09-02) plus a 64 kbps ear
        // copy of the bar-range slice. With a bar range the preview is now of
        // the SLICE — the whole render is still on disk at `path`, and the
        // slice is both what was asked for and small enough that the preview
        // beside it IS the audio block, at no extra cost.
        let earSource = ((result["slice"] as? [String: Any])?["path"] as? String) ?? destination.path
        reportProgress("encoding the audio for listening", percent: 96)
        let preview = LogicAccessibility.makeAACPreview(sourcePath: earSource)
        if let preview {
            result["preview_path"] = preview
            result["preview_note"] = (earSource == destination.path
                ? "Compressed stereo AAC copy of the whole render. "
                : "Compressed stereo AAC copy of the requested BAR RANGE (the whole render is"
                    + " the AIFF at `path`). ")
                + "To LISTEN: open preview_path with your client's FILE VIEWER (passes as real audio in most clients, even those that drop MCP audio blocks), or logic_get_audio_clip if your client forwards audio blocks. NEVER read audio files as text/bash."
        }
        if includeAudio {
            let ear = LogicAccessibility.earAudio(sourcePath: earSource, previewPath: preview)
            if let data = ear.data {
                result["_audio"] = ["data": data.base64EncodedString(), "mimeType": "audio/mp4"]
            }
            result["listen_note"] = ear.note
            if ear.windowed, let covered = ear.coveredSeconds {
                // Named as data, not just in prose: an agent that has to
                // decide whether to fetch another window should not have to
                // parse a sentence to find out what it heard.
                result["audio_window"] = [
                    "start_seconds": 0,
                    "seconds": covered,
                    "of_seconds": ear.sourceSeconds.map { $0 as Any } ?? NSNull() as Any,
                    "rest_via": "logic_get_audio_clip {path, start_seconds, duration_seconds}"
                ]
            }
        } else {
            // No encode at all when the block would be dropped anyway; the
            // transport writes the omission note in its place.
            result["_audio_suppressed"] = true
        }
        reportProgress("render complete", percent: 100)
        return result
    }

    /// Puts the playhead back and REPORTS what happened, never throwing: the
    /// render is already on disk when this runs, so a failed restore is a fact
    /// to publish (with the position it was actually left at), not a reason to
    /// lose the result.
    static func restorePlayheadReport(
        logic: LogicAccessibility, saved: (bar: Int, beat: Int)
    ) -> [String: Any] {
        func current() -> (bar: Int, beat: Int)? {
            guard let transport = try? logic.getTransport(),
                  let bar = transport["playhead_bar"] as? Int else { return nil }
            return (bar, transport["playhead_beat"] as? Int ?? 1)
        }
        let now = current()
        if let now, now == saved {
            // The render left it where it started (a project whose start IS
            // the caller's position). A verified no-op, not a move.
            return [
                "restored": true, "verified": true, "state": "already_at_baseline",
                "bar": saved.bar, "beat": saved.beat
            ]
        }
        guard (try? logic.setPlayhead(barNumber: saved.bar, beat: saved.beat)) != nil else {
            let left = current()
            return [
                "restored": false, "verified": false, "state": "not_restored",
                "bar": saved.bar, "beat": saved.beat,
                "left_at": left.map { ["bar": $0.bar, "beat": $0.beat] as [String: Any] }
                    ?? ["bar": NSNull(), "beat": NSNull()] as [String: Any],
                "note": "the playhead could NOT be put back to bar \(saved.bar) beat"
                    + " \(saved.beat) after the render — a freeze render jumps it to the"
                    + " project start and rolls from there, so it is now at "
                    + (left.map { "bar \($0.bar) beat \($0.beat)" } ?? "an unreadable position")
                    + ". Move it yourself with logic_set_playhead."
            ]
        }
        return [
            "restored": true, "verified": true, "state": "restored",
            "bar": saved.bar, "beat": saved.beat,
            "note": "The render moved the playhead to the project start and rolled from there;"
                + " it was put back where you had it (verified against Logic's control bar)."
        ]
    }

}
