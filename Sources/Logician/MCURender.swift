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
        named name: String, logic: LogicAccessibility?
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
        _ = try? setPlaying(true)

        // The render announces itself with FreezeInProgress.lock plus the
        // growing .aif; completion is the lock disappearing.
        var newAudio: String?
        var renderStarted = false
        let startDeadline = Date().addingTimeInterval(10)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
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
            if let logic, let trackName {
                if logic.trackFreezeState(trackName: trackName) == true {
                    _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
                    Thread.sleep(forTimeInterval: 0.5)
                    _ = logic.answerFreezeDialog()
                }
            } else {
                _ = try? triggerKeyCommand(note: freeze.note, channel: freeze.channel)
            }
            throw LogicianError.openVerificationFailed(
                renderStarted
                    ? "freeze render started but no finished file appeared within 180 s"
                    : "freeze never engaged within 10 s of play. Likely causes: the track is a stack or bus (not freezable), it has nothing to render, the Freeze button is not enabled in the track header (Logic: Track > Configure Track Header > Freeze), or the Toggle Track Freeze key-command binding is orphaned - run logic_setup_key_commands with relearn: true to repair"
            )
        }

        // The lock can vanish before Logic finishes writing the file (a
        // 4 KB header-only snapshot copies otherwise): wait until the size
        // covers the FORM chunk and has stopped growing.
        let renderedURL = freezeDir.appendingPathComponent(rendered)
        var stableSize: UInt64 = 0
        var stableRounds = 0
        let flushDeadline = Date().addingTimeInterval(30)
        while Date() < flushDeadline, stableRounds < 3 {
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
        let destination = captures.appendingPathComponent(
            "render-\(safeLabel)-\(stamp).\(URL(fileURLWithPath: rendered).pathExtension)"
        )
        try manager.copyItem(
            at: freezeDir.appendingPathComponent(rendered), to: destination
        )

        // Unfreeze and verify Logic removed the freeze file again; answer the
        // confirm dialog if the toggle raises one, and double-check via the
        // header checkbox when we can.
        _ = try triggerKeyCommand(note: freeze.note, channel: freeze.channel)
        var unfroze = false
        for attempt in 0..<40 {
            if !freezeFiles().contains(rendered) { unfroze = true; break }
            if attempt % 4 == 3, let logic { _ = logic.answerFreezeDialog() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if let logic, let trackName, logic.trackFreezeState(trackName: trackName) == true {
            unfroze = false
        }

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
            let slicePath = captures.appendingPathComponent(
                "render-\(safeLabel)-\(stamp)-slice.wav"
            ).path
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
        if let earCopy = LogicAccessibility.encodeEarCopy(path: earSource) {
            result["_audio"] = ["data": earCopy.base64EncodedString(), "mimeType": "audio/mp4"]
            result["listen_note"] = "This result CARRIES the rendered audio as an MCP audio block - listen now. If no audio block reached you, open preview_path with your client's file viewer instead."
        }
        return result
    }

}
