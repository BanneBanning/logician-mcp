import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// Loading an instrument — the wall both the beatmaker and the sound designer
// hit at "pick a sound".
//
// `MCUInstrument.swift:12` has carried the sentence "Never turns vpots in the
// bank view (that is the instrument browser)" since the instrument-parameter
// work, written to AVOID the behaviour rather than to use it. COVERAGE's open
// question 4 asked whether that comment was right. It is, verified on a scratch
// track 2026-08-28, and the grammar is a near-twin of the plugin browser's:
//
//   IN bank view      top: channel names          bottom: instrument per strip
//   during a browse   top: "Instrument" from the  bottom: the full entry name,
//                          browsed cell onward,           spilling right across
//                          later cells cleared            the neighbouring cells
//
// Three differences from `addPluginViaBrowser` that matter:
//   * ONE tick per entry here (the plugin browser advances every two).
//   * The entries carry a channel-format word — "Stereo", "Mono",
//     "Multi-Output" — and sometimes an inline "(s)" / "(m)" / "(m->s)"; two or
//     three entries per plugin.
//   * There is no AX list to cross-check against, so the second source is the
//     instrument slot's own name in the IN bank view plus the parameter page
//     Logic drops into on confirmation.
//
// Leaving the view to PAN cancels a browse without instantiating (verified: a
// browse walked to `AmpliTube 5 Stereo`, exited, and the slot still held the
// instrument it started with).

extension MCUController {

    /// An instrument browser entry split into the plugin's name and the channel
    /// format Logic appends. Pure — this is what decides which entry a request
    /// matches, and a wrong answer instantiates the wrong instrument.
    static func splitInstrumentEntry(_ entry: String) -> (name: String, format: String?) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        for format in MCULCDStrings.instrumentChannelFormats {
            let suffix = " " + format
            if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
                return (String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces),
                        format)
            }
        }
        return (trimmed, nil)
    }

    /// Whether a browser entry is the instrument the caller asked for.
    ///
    /// The request may name the format ("Drum Kit Designer Stereo") or not
    /// ("Drum Kit Designer"), and may or may not carry Logic's inline channel
    /// marker ("Abbey Road Saturator (s)"). Matching is case-insensitive and
    /// exact on the name part — never fuzzy, for the same reason
    /// `logic_plugin_preset` refuses a near miss: instantiating the wrong
    /// instrument is not a small error. When the caller names a format, only
    /// that format's entry matches; when they do not, the first entry whose
    /// name matches wins and the result reports which format was taken.
    static func instrumentEntryMatches(
        entry: String, request: String, format: String?
    ) -> Bool {
        let shown = splitInstrumentEntry(entry)
        let wanted = splitInstrumentEntry(request)
        guard !shown.name.isEmpty, !wanted.name.isEmpty else { return false }
        guard shown.name.compare(wanted.name, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame else { return false }
        // An explicit `format` argument outranks one embedded in the request.
        guard let wantedFormat = format ?? wanted.format else { return true }
        guard let shownFormat = shown.format else { return false }
        return shownFormat.compare(wantedFormat, options: .caseInsensitive) == .orderedSame
    }

    /// Loads an instrument into a track's instrument slot by browsing the IN
    /// bank view, with the same settle / re-verify / confirm discipline
    /// `addPluginViaBrowser` established.
    static func loadInstrumentViaBrowser(
        logic: LogicAccessibility,
        trackName: String,
        instrument: String,
        format: String?,
        maxSteps: Int
    ) throws -> [String: Any] {
        guard freshStatus() != nil else {
            throw LogicianError.trackNotExposed(
                requested: "the control-surface instrument browser",
                exposed: "the Mackie Control bridge is not running or Logic has never talked to it"
                    + " (see logic_health). There is no Accessibility route to the instrument slot."
            )
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw headerlessStripError(
                name: trackName,
                resolution: lastChannelResolution,
                visibleTracks: ((try? logic.parsedTrackHeaders()) ?? []).map(\.name),
                trackMiss: .trackNotFound(trackName, available: [])
            )
        }
        // The IN view names no channel while a browse is running — the browsed
        // cell's own label is overwritten with "Instrument". So prove the strip
        // in the pan view, where the names ARE painted, before entering.
        try selectChannelVerified(channel: channel, expectedName: trackName)
        try press("assign_instrument")
        guard waitFor(seconds: 3.0, {
            ($0["assignment"] as? String) == MCULCDStrings.Assignment.instrument
        }) != nil else {
            exitToPan()
            throw LogicianError.openVerificationFailed(
                "the control surface's instrument (IN) view did not appear; nothing was changed"
            )
        }
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.6)

        func slotCell() -> String {
            guard let bottom = freshStatus()?["lcd_bottom"] as? String else { return "" }
            return lcdFields(bottom)[channel]
                .trimmingCharacters(in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker + " "))
        }
        /// The browsed entry: the bottom row from this strip's cell rightwards,
        /// cut at the first long gap so the next occupied slot does not leak in.
        func browsed() -> String {
            guard let bottom = freshStatus()?["lcd_bottom"] as? String else { return "" }
            let start = bottom.index(bottom.startIndex, offsetBy: min(channel * 7, bottom.count))
            let raw = String(bottom[start...])
            return (raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw)
                .trimmingCharacters(in: .whitespaces)
        }
        let slotBefore = slotCell()

        var entries: [String] = []
        var shown = ""
        var found = false
        for step in 0..<max(maxSteps, 1) {
            let events = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: channel, delta: 1))
            guard response.ok else {
                exitToPan()
                throw LogicianError.writeFailed("MCU vpot failed: \(response.error ?? "?")")
            }
            _ = awaitEvents(since: events, timeoutMs: 300)
            if step % 4 == 3 { _ = quiescentStatus() }
            shown = browsed()
            guard !shown.isEmpty, shown != MCULCDStrings.emptySlot else { continue }
            if instrumentEntryMatches(entry: shown, request: instrument, format: format) {
                found = true
                break
            }
            // The LCD repeats the previous entry when it has not repainted yet;
            // a genuine wrap is the FIRST entry reappearing after real progress.
            if shown == entries.last { continue }
            if let first = entries.first, shown == first, entries.count > 2 {
                exitToPan()
                throw LogicianError.trackNotExposed(
                    requested: "instrument '\(instrument)'"
                        + (format.map { " (\($0))" } ?? "")
                        + " in the control-surface instrument browser",
                    exposed: "the browser wrapped around without a match; entries seen: "
                        + entries.joined(separator: ", ")
                )
            }
            entries.append(shown)
        }
        guard found else {
            exitToPan()
            // No entry at ALL means the vpot was not driving a browser: an
            // audio, output, aux or bus strip has no instrument slot, and its
            // cell in the IN view simply stays blank however far it is turned.
            // Saying "never showed X" there would send the caller looking for
            // a spelling mistake instead of a wrong track.
            guard !entries.isEmpty else {
                throw LogicianError.trackNotExposed(
                    requested: "the instrument browser on '\(trackName)'",
                    exposed: "turning that strip's vpot in the instrument view produced no browser"
                        + " entries at all — the strip has no instrument slot. Only SOFTWARE"
                        + " INSTRUMENT tracks have one; audio tracks, outputs, auxes and buses do"
                        + " not. Nothing was changed."
                )
            }
            throw LogicianError.openVerificationFailed(
                "the instrument browser never showed '\(instrument)' within \(maxSteps) steps;"
                    + " nothing was instantiated (the browse was cancelled by leaving the view)."
                    + " The list holds every installed instrument in every channel format and is"
                    + " not alphabetical, so a high max_steps may simply not have reached it yet"
                    + " (\(entries.count) entries stepped, ~0.11 s each). Entries seen most"
                    + " recently: " + entries.suffix(30).joined(separator: ", ")
            )
        }
        // Settle and re-verify before confirming: the display can advance one
        // more entry on trailing sysex, and a confirmation is not undoable by
        // leaving the view.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.35)
        var settled = browsed()
        var corrections = 0
        while !instrumentEntryMatches(entry: settled, request: instrument, format: format),
              corrections < 4 {
            _ = try? MCUBridge.send(.vpot(index: channel, delta: -1))
            Thread.sleep(forTimeInterval: 0.35)
            _ = quiescentStatus()
            settled = browsed()
            corrections += 1
        }
        guard instrumentEntryMatches(entry: settled, request: instrument, format: format) else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(instrument)' shown at confirmation time",
                actual: "the browser entry drifted to '\(settled)' and back-stepping could not"
                    + " recover it; aborted without instantiating",
                restored: true
            )
        }
        let confirmedEntry = settled

        let confirm = try MCUBridge.send(.vpotPress(index: channel))
        guard confirm.ok else {
            exitToPan()
            throw LogicianError.writeFailed("MCU vpot press failed: \(confirm.error ?? "?")")
        }
        Thread.sleep(forTimeInterval: 1.5)
        _ = quiescentStatus()
        // Confirmation drops the surface into the new instrument's parameter
        // page — the first sign it took, and worth reporting because it is what
        // logic_mcu_instrument_parameters would read next.
        let editTop = freshStatus()?["lcd_top"] as? String ?? ""

        // Second source: back in the IN BANK view, this strip's slot must name
        // the instrument. That row is painted per strip, so unlike the browse
        // row it says WHICH channel the instrument landed on.
        exitToPan()
        try press("assign_instrument")
        _ = waitFor(seconds: 3.0, {
            ($0["assignment"] as? String) == MCULCDStrings.Assignment.instrument
        })
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.8)
        let slotAfter = slotCell()
        exitToPan()

        let expectedName = splitInstrumentEntry(confirmedEntry).name
        let slotAgrees = !slotAfter.isEmpty && slotAfter != MCULCDStrings.emptySlot
            && lcdAbbreviationPlausible(track: expectedName, lcd: slotAfter)
        guard slotAgrees else {
            throw LogicianError.verificationFailed(
                requested: "'\(expectedName)' in '\(trackName)'s instrument slot",
                actual: slotAfter.isEmpty || slotAfter == MCULCDStrings.emptySlot
                    ? "the slot still reads empty after the confirmation"
                    : "the slot reads '\(slotAfter)', which is not an abbreviation of it",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": slotBefore.isEmpty || slotBefore == MCULCDStrings.emptySlot
                ? "loaded" : "replaced",
            "track": trackName, "track_name": trackName,
            "instrument": expectedName,
            "browser_entry": confirmedEntry,
            "format": splitInstrumentEntry(confirmedEntry).format as Any? ?? NSNull(),
            "slot_before": slotBefore.isEmpty ? MCULCDStrings.emptySlot : slotBefore,
            "slot_after": slotAfter,
            "mcu_strip": channel + 1,
            "entries_stepped": entries.count + 1,
            "write_route": "mcu_instrument_browser",
            "readback_route": "mcu_instrument_slot_name",
            "edit_page_after_confirm": editTop.trimmingCharacters(in: .whitespaces),
            "note": "Loaded through the control surface's instrument browser (IN view) — no mouse, no menus. Read the new instrument's parameters with logic_mcu_instrument_parameters, which is also the independent second read of what landed."
        ]
        if !(slotBefore.isEmpty || slotBefore == MCULCDStrings.emptySlot) {
            appendWarning(
                "'\(trackName)' already held an instrument ('\(slotBefore)') and it was REPLACED,"
                    + " along with all of its settings. Logic's own Undo is the way back; this"
                    + " server cannot restore a plug-in's state.",
                to: &result
            )
        }
        return result
    }
}
