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
        guard let freeze = try? resolveKeyCommand(named: "Toggle Track Freeze", logic: logic) else { return }
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
    static func renderSelectedTrack(
        projectPath: String, label: String,
        sliceStartSeconds: Double? = nil, sliceEndSeconds: Double? = nil,
        logic: LogicAccessibility? = nil, trackName: String? = nil
    ) throws -> [String: Any] {
        let freeze = try resolveKeyCommand(named: "Toggle Track Freeze", logic: logic)
        // A rolling transport queues freeze dialogs invisibly and swallows
        // toggles — make sure we start from silence. And a track that is
        // ALREADY frozen must be thawed first, or the toggle inverts.
        _ = try? setPlaying(false)
        // Play does NOTHING when the playhead sits at/past the project end,
        // so the freeze render would never start. Stop-when-stopped jumps
        // to the project start — pure MCU, position-safe.
        _ = try? MCUBridge.send(.press(button: "stop"))
        Thread.sleep(forTimeInterval: 0.4)
        if let logic, let trackName {
            // Progress runs 0…100 for the whole render, and the freeze wait
            // below owns most of it: the phases before it are seconds, the
            // render itself is minutes.
            reportProgress("thawing the track before the render", percent: 3)
            try ensureUnfrozen(logic: logic, trackName: trackName)
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
        _ = try? setPlaying(true)

        // The render announces itself with FreezeInProgress.lock plus the
        // growing .aif; completion is the lock disappearing.
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
               !fresh.contains("FreezeInProgress.lock") {
                newAudio = audio
                break
            }
            // A modal alert freezes the whole flow — the MCU timecode
            // mirrors it as 'ALERT'. And if no freeze activity showed up
            // within seconds of play, the toggle never engaged (track
            // stacks and buses cannot be frozen) — Logic is just playing.
            if let timecode = freshStatus()?["timecode"] as? String,
               timecode.contains("ALERT") {
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
                    : "freeze never engaged within 10 s of play. Likely causes: the track is a stack or bus (not freezable), it has nothing to render, the Freeze button is not enabled in the track header (Logic: Track > Configure Track Header > Freeze), or the Toggle Track Freeze key-command binding is orphaned - run logic_setup_key_commands with relearn: true to repair")
                    + (restored
                        ? ". The track was returned to its unfrozen state."
                        : ". The track could NOT be confirmed unfrozen - check the track header and unfreeze it manually if it is still lit.")
            )
        }

        // The lock can vanish before Logic finishes writing the file (a
        // 4 KB header-only snapshot copies otherwise): wait until the size
        // covers the FORM chunk and has stopped growing.
        let renderedURL = freezeDir.appendingPathComponent(rendered)
        var stableSize: UInt64 = 0
        var stableRounds = 0
        let flushDeadline = Date().addingTimeInterval(30)
        reportProgress("render finished; waiting for Logic to flush the file", percent: 86)
        while Date() < flushDeadline, stableRounds < 3 {
            try checkCancelled()
            let size = (try? manager.attributesOfItem(atPath: renderedURL.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0
            var formComplete = false
            if let handle = try? FileHandle(forReadingFrom: renderedURL),
               let header = try? handle.read(upToCount: 8), header.count == 8 {
                let formSize = (UInt64(header[4]) << 24) | (UInt64(header[5]) << 16)
                    | (UInt64(header[6]) << 8) | UInt64(header[7])
                formComplete = size >= formSize + 8 && formSize > 8
                try? handle.close()
            }
            if size > 0, size == stableSize, formComplete {
                stableRounds += 1
            } else {
                stableRounds = 0
            }
            stableSize = size
            if stableRounds < 3 { Thread.sleep(forTimeInterval: 0.3) }
        }

        // Copy out before unfreezing (unfreeze deletes the file).
        let captures = manager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Logician/captures"
        )
        try? manager.createDirectory(at: captures, withIntermediateDirectories: true)
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
        if let preview = LogicAccessibility.makeAACPreview(sourcePath: destination.path) {
            result["preview_path"] = preview
            result["preview_note"] = "Compressed stereo AAC copy. To LISTEN: open preview_path with your client's FILE VIEWER (passes as real audio in most clients, even those that drop MCP audio blocks), or logic_get_audio_clip if your client forwards audio blocks. NEVER read audio files as text/bash."
        }
        if let metrics = LogicAccessibility.audioFileMetrics(path: destination.path),
           (metrics["frames"] as? Int ?? 0) > 0 {
            result["metrics"] = metrics
        } else {
            result["warning"] =
                "the rendered file contains no audio — does the track have any regions?"
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
        // The rendered sound rides along as an MCP audio block (the sliced
        // bar range when one was requested, else the whole render).
        let earSource = ((result["slice"] as? [String: Any])?["path"] as? String) ?? destination.path
        reportProgress("encoding the audio for listening", percent: 96)
        if let earCopy = LogicAccessibility.encodeEarCopy(path: earSource) {
            result["_audio"] = ["data": earCopy.base64EncodedString(), "mimeType": "audio/mp4"]
            result["listen_note"] = "This result CARRIES the rendered audio as an MCP audio block - listen now. If no audio block reached you, open preview_path with your client's file viewer instead."
        }
        reportProgress("render complete", percent: 100)
        return result
    }

}
