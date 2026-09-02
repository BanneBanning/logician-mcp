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
//
// # Round 2 (2026-09-02) — everything the plug-in browser learned, wired here
//
// The profile of 2026-09-02 found this tool to be `addPluginViaBrowser` as it
// was BEFORE round 2 of `logic_add_plugin`: an 11.9 s warm load of which 46%
// was the surface walking home to Pan twice, 27% four blind sleeps and 0.5%
// the write. It also found two ways a correct call lied. Both are fixed here,
// and every mechanism is the plug-in browser's own — `stepForward`-style
// paced stepping, `browseJumpPlan` / `waitForSurfaceQuiet`, the catalog map,
// `normalizedBrowseEntry`, the entry cap and the wall-clock budget,
// `SurfaceDebt` — reused rather than re-invented. Only the arithmetic differs:
// **one tick per entry, so one MIDI message carries 62 entries** where the
// plug-in browser's carries 31.

/// Where each instrument sits in the control-surface instrument catalog.
///
/// The shape is the plug-in browser's, unchanged and deliberately shared: an
/// entry ordinal counted from the origin, a contiguous-prefix coverage mark,
/// and lowest-position-wins merging. Three things differ and none of them is
/// the shape — the origin (an EMPTY instrument slot, not the `--` No Plug-in
/// entry), the tick arithmetic (`instrumentBrowseTicksPerEntry`), and the name
/// test the lookup uses (`instrumentEntryMatches`, which understands Logic's
/// channel-format suffix). See `PluginCatalogMap` for why an ordinal counted
/// by NAME CHANGES is the only coordinate that survives a swallowed message,
/// and why its residual error can only point too SHORT.
typealias InstrumentCatalogMap = PluginCatalogMap

extension PluginCatalogMap {

    /// The entry a linear instrument walk from the origin would have stopped
    /// at, by the same first-match-wins rule and for the same reason: the map
    /// has no holes below `coveredPositions`.
    func instrumentPosition(matching requested: String, format: String?) -> Int? {
        entries.first {
            MCUController.instrumentEntryMatches(
                entry: $0.name, request: requested, format: format
            )
        }?.position
    }

    /// The ordinal of an entry the browse is looking at RIGHT NOW, by exact
    /// display name — the anchor that lets a browse which did not start at the
    /// origin still jump. Names are unique in a map (merge keeps the lowest
    /// position per name), so this is unambiguous within the map; the catalog
    /// itself may hold the name twice, which is why an anchored browse records
    /// nothing and why a wrong anchor costs steps and never a wrong load.
    func position(ofExactly name: String) -> Int? {
        entries.first { $0.name == name }?.position
    }
}

extension MCUController {

    // MARK: - Reading one browse entry off the shared row (pure)

    /// One vpot tick per catalog entry — the plug-in browser's is two, the
    /// send browser's is one. Confirmed 2026-09-02 by the clean short walks:
    /// 5 messages produced 5 distinct entries, twice. With
    /// `browseJumpTicksPerMessage` at 62 this makes one MIDI message worth
    /// **62 entries**, the largest jump of the three browsers.
    static let instrumentBrowseTicksPerEntry = 1

    /// Characters the browse row leaves for an entry, counted from this
    /// strip's own cell.
    ///
    /// The row is 56 columns; the last one is a separator Logic never paints an
    /// entry into. Measured 2026-09-02 on strip 5 (window 27): five over-long
    /// entries — `Drum Kit Designer Multi-Output`, `Abbey Road Saturator (m)
    /// Mono`, `Berzerk Distortion (s) Stereo`, `External Instrument Legacy
    /// Mono` and `Abbey Road Saturator (s) Stereo` — were each painted so that
    /// their LAST character sat in column 54, i.e. shifted LEFT out of the
    /// window, and were captured with their heads cut off.
    static func instrumentBrowseWindowWidth(channel: Int) -> Int {
        max(0, MCULCDRow.length - 1 - channel * MCULCDRow.cellWidth)
    }

    /// The narrowest window an entry may be identified by its TAIL in. Strip 8
    /// leaves 6 characters, and `-Output` or ` Stereo` names a dozen different
    /// instruments — pressing on that is a guess, and this server refuses
    /// rather than guesses. Strip 7 (14 characters) is the narrowest that
    /// clears the bar.
    static let instrumentHeadCutMinimumWindow = 12

    /// The browsed entry, read out of the bottom row and cleaned of the
    /// neighbouring strips' slot names.
    ///
    /// Two contaminations, both measured 2026-09-02. `ARP 2600 V3 Stereo
    /// Samplr` was captured as one entry (warm run 4, step 0): the entry ended
    /// three columns short of the next cell, so the old four-space cut missed
    /// and strip 6's slot name rode along. And the browse row is SHARED — the
    /// neighbours' names are ordinary instrument names, not the plug-in
    /// browser's `--` markers, so `normalizedBrowseEntry` alone cannot see
    /// them.
    ///
    /// So the cut is made from what the row said BEFORE the browse started:
    /// `slotRow` is the eight slot cells read in the IN bank view, and a
    /// neighbour cell whose name still stands at its own column boundary is
    /// where the entry ends. That is exact even when Logic leaves NO gap at
    /// all. The two-space fallback covers the neighbour having repainted under
    /// us; `normalizedBrowseEntry` takes any trailing `--` back off.
    static func instrumentBrowseWindow(row: String, channel: Int, slotRow: [String]) -> String {
        guard (0..<MCULCDRow.cellCount).contains(channel) else { return "" }
        let padded = Array(row.padding(
            toLength: MCULCDRow.length, withPad: " ", startingAt: 0
        ))
        var window = Array(padded[(channel * MCULCDRow.cellWidth)...])
        for cell in (channel + 1)..<MCULCDRow.cellCount {
            let neighbour = slotRow.indices.contains(cell) ? slotRow[cell] : ""
            guard neighbour.count >= 2 else { continue }
            let offset = (cell - channel) * MCULCDRow.cellWidth
            guard offset < window.count else { break }
            guard String(window[offset...]).hasPrefix(neighbour) else { continue }
            window = Array(window[0..<offset])
            break
        }
        var text = String(window)
        if let gap = text.range(of: "  ") { text = String(text[..<gap.lowerBound]) }
        return normalizedBrowseEntry(text)
    }

    /// How a captured browse cell relates to the instrument that was asked for.
    enum InstrumentBrowseMatch: Equatable {
        case none
        /// The row shows the entry whole and it is the one requested.
        case exact
        /// The row shows the requested entry HEAD-CUT — it did not fit from
        /// this strip's cell rightwards, so Logic painted it shifted left and
        /// the capture is its tail. `full` is the entry as Logic means it.
        case headCut(full: String)
    }

    /// The full entry texts a request could name — the name with each channel
    /// format Logic appends, or just the one when the caller named a format.
    /// This is what a head-cut capture is compared against, so it is also the
    /// answer to "what did the row mean".
    static func instrumentEntryCandidates(request: String, format: String?) -> [String] {
        let wanted = splitInstrumentEntry(request)
        guard !wanted.name.isEmpty else { return [] }
        if let only = format ?? wanted.format {
            return [wanted.name + " " + only]
        }
        return MCULCDStrings.instrumentChannelFormats.map { wanted.name + " " + $0 }
            + [wanted.name]
    }

    /// Whether the captured window is the requested entry painted head-cut,
    /// and if so which entry it is.
    ///
    /// Deliberately an EXACT test rather than a fuzzy one, because the
    /// arithmetic is known: the entry is right-aligned to the row's last
    /// painted column, so a capture that is head-cut FILLS the window, and
    /// what it must then read is exactly the requested entry's tail. Three
    /// conditions, all of which have to hold: the window is wide enough to
    /// identify an entry by its tail at all, the capture fills it, and the
    /// requested entry is too long to have fitted. A shorter capture is a
    /// whole entry and is judged by the exact-name test instead.
    static func instrumentHeadCutEntry(
        captured: String, request: String, format: String?, windowWidth: Int
    ) -> String? {
        let shown = captured.trimmingCharacters(in: .whitespaces)
        guard windowWidth >= instrumentHeadCutMinimumWindow,
              shown.count >= windowWidth - 1 else { return nil }
        return instrumentEntryCandidates(request: request, format: format)
            .first { $0.count > windowWidth && $0.lowercased().hasSuffix(shown.lowercased()) }
    }

    /// The one question the browse loop and the press gate both ask.
    static func instrumentBrowseMatch(
        captured: String, request: String, format: String?, windowWidth: Int
    ) -> InstrumentBrowseMatch {
        let shown = normalizedBrowseEntry(captured)
        guard !shown.isEmpty, shown != MCULCDStrings.emptySlot else { return .none }
        if instrumentEntryMatches(entry: shown, request: request, format: format) {
            return .exact
        }
        if let full = instrumentHeadCutEntry(
            captured: shown, request: request, format: format, windowWidth: windowWidth
        ) {
            return .headCut(full: full)
        }
        return .none
    }

    /// Whether a capture may have lost its head — used to keep a strip-shaped
    /// truncation out of the catalog map, whose names have to mean the same
    /// thing when the next browse runs on a different strip.
    static func instrumentEntryMayBeHeadCut(_ captured: String, windowWidth: Int) -> Bool {
        captured.trimmingCharacters(in: .whitespaces).count >= windowWidth - 1
    }

    // MARK: - Reading the instrument SLOT cell (pure)

    /// Whether the IN view's slot cell names the instrument in question.
    ///
    /// Neither of the two tests this project already had can answer this
    /// alone, and that gap reported a working destructive write as a failure
    /// (profiled 2026-09-02: `ARP 2600 V3` loaded, the slot read `ARPV3`, and
    /// the call returned `verification_failed` with `restored: false` — after
    /// which the documented recovery, Logic's Undo, would have undone a good
    /// load).
    ///
    /// * `lcdAbbreviationPlausible` is calibrated for the 6-character channel
    ///   NAME grid and rejects any cell shorter than six characters, so
    ///   `ARPV3` could never match `ARP 2600 V3` — the same shape of false
    ///   failure `ParEQ`/`Parametric EQ` was in August.
    /// * `axNamesPlugin`, the fix `logic_add_plugin` shipped for that, takes
    ///   `ARPV3` happily but requires the first three characters to survive
    ///   the abbreviation — and Logic drops characters inside them on this row
    ///   (`DrmKit` for `Drum Kit Designer`, `AnlLab` for `Analog Lab V`).
    ///
    /// So the honest test is either: a plausible LCD abbreviation, or the
    /// shape of abbreviation Accessibility uses. Loosening cannot make a
    /// wrong-CHANNEL load pass — the strip is named by the caller, proven by
    /// `selectChannelVerified` before the browse and by the IN bank view's own
    /// top row after it; at worst a correct load is confirmed by a sibling
    /// with a confusingly similar name.
    static func instrumentSlotNames(_ cell: String, instrument: String) -> Bool {
        let slot = cell.trimmingCharacters(
            in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker + " ")
        )
        guard !slot.isEmpty, slot != MCULCDStrings.emptySlot, !instrument.isEmpty else {
            return false
        }
        return lcdAbbreviationPlausible(track: instrument, lcd: slot)
            || axNamesPlugin(slot, requested: instrument)
    }

    /// Whether the slot already holds what was asked for, decided from the
    /// slot cell that is in hand before the browser is ever turned.
    ///
    /// The tool advertises `idempotent: true` and, profiled 2026-09-02, the
    /// repeat call FAILED in 4.9 s — it browsed, drifted, back-stepped four
    /// times and aborted. The free answer was already read.
    ///
    /// A named FORMAT always browses, and that is not timidity: the slot cell
    /// is six characters and carries no format, so `DrmKit` cannot say whether
    /// the track holds `Drum Kit Designer Stereo` or its Multi-Output twin.
    /// That also gives the caller a deterministic way to force a real reload —
    /// name the format.
    static func instrumentSlotAlreadyHolds(
        slot: String, request: String, format: String?
    ) -> Bool {
        let wanted = splitInstrumentEntry(request)
        guard format == nil, wanted.format == nil else { return false }
        return instrumentSlotNames(slot, instrument: wanted.name)
    }

    // MARK: - The instrument catalog cache

    static var instrumentCatalogCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("instrument-catalog-cache.json")
    }

    /// Scoped exactly as the plug-in catalog is, and for the same reason: the
    /// instrument list is a property of the INSTALL, not of the project.
    /// Installing one Audio Unit moves every entry after it, and
    /// `pluginCatalogScope` already digests the plug-in folders that hold
    /// them.
    static func loadInstrumentCatalog() -> InstrumentCatalogMap? {
        loadScopedCache(
            instrumentCatalogCacheURL, scope: pluginCatalogScope(),
            as: InstrumentCatalogMap.self, deleteOnMismatch: true
        )
    }

    static func saveInstrumentCatalog(_ map: InstrumentCatalogMap) {
        guard !map.entries.isEmpty else { return }
        saveScopedCache(map, to: instrumentCatalogCacheURL, scope: pluginCatalogScope())
    }

    static func discardInstrumentCatalog() {
        try? FileManager.default.removeItem(at: instrumentCatalogCacheURL)
    }

    // MARK: - Getting into (and back into) the IN bank view

    /// Presses `assign_instrument` until the IN BANK view is showing and its
    /// top row names this strip. Content-verified, never press-counted: the
    /// same button also steps the confirmed instrument's parameter pages, so
    /// "press once" is a route to somewhere, not a route home.
    ///
    /// This is what lets the mid-call `exitToPan` go. Profiled 2026-09-02, the
    /// old code walked all the way home to Pan (2 864 ms mean, up to 3 845)
    /// and then immediately pressed `assign_instrument` to go back into the
    /// view it had just left — `logic_add_send`'s "leaves a view and presses
    /// straight back into it" finding, here costing a quarter of the call.
    /// Returns the evidence: the named-strip proof when the top row could be
    /// read (which is STRONGER than what the old code checked — it only
    /// waited for the assignment code), the assignment alone when it could
    /// not, or nil when the view never appeared at all.
    static func ensureInstrumentBankView(channel: Int, trackName: String) throws -> String? {
        func evidence(_ status: [String: Any]) -> String? {
            guard (status["assignment"] as? String) == MCULCDStrings.Assignment.instrument else {
                return nil
            }
            guard let top = status["lcd_top"] as? String,
                  lcdAbbreviationPlausible(track: trackName, lcd: lcdFields(top)[channel])
            else { return "mcu_in_bank_assignment_only" }
            return "mcu_in_bank_named_strip"
        }
        var sawView = false
        for attempt in 0..<5 {
            if let status = freshStatus(), let seen = evidence(status) {
                if seen == "mcu_in_bank_named_strip" { return seen }
                sawView = true
            }
            // Three presses that never reached the named bank view means the
            // button is cycling somewhere else; take the long way home once
            // and come back in through the front door.
            if attempt == 3 { exitToPan() }
            try press("assign_instrument")
            if let landed = waitFor(seconds: 1.5, { evidence($0) == "mcu_in_bank_named_strip" }) {
                return evidence(landed)
            }
            if freshStatus().flatMap(evidence) != nil { sawView = true }
        }
        return sawView ? "mcu_in_bank_assignment_only" : nil
    }

    // MARK: - Pure entry matching (unchanged, and still what gates the press)

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

    // MARK: - The load itself

    /// Loads an instrument into a track's instrument slot by browsing the IN
    /// bank view, with the same settle / re-verify / confirm discipline
    /// `addPluginViaBrowser` established — and, since 2026-09-02, the same
    /// pacing, jumping, catalog map, entry cap, wall-clock budget and deferred
    /// surface restore.
    ///
    /// `maxSteps` is the ENTRY cap, not a message count (the old counter
    /// reported "306 entries stepped" where 105 distinct entries had been
    /// shown), and the wall clock a fruitless search gets scales with it, so
    /// raising the cap really does buy a longer search.
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
        // How much of the shared browse row this strip's entry gets. An entry
        // longer than that is painted shifted LEFT and captured head-cut, and
        // on a wide window its tail still identifies it exactly (see
        // `instrumentHeadCutEntry`). A narrow one cannot, and the honest place
        // to say so is the refusal at the end — refusing UP FRONT would need a
        // claim about how Logic paints the last strip of a bank that nothing
        // in this project has measured, and it would block loads that work.
        let windowWidth = instrumentBrowseWindowWidth(channel: channel)
        // The IN view names no channel while a browse is running — the browsed
        // cell's own label is overwritten with "Instrument". So prove the strip
        // in the pan view, where the names ARE painted, before entering.
        try selectChannelVerified(channel: channel, expectedName: trackName)
        guard let viewEvidence = try ensureInstrumentBankView(
            channel: channel, trackName: trackName
        ) else {
            exitToPan()
            throw LogicianError.openVerificationFailed(
                "the control surface's instrument (IN) view did not appear; nothing was changed"
            )
        }

        /// The eight slot cells as the bank view paints them, this strip's
        /// included. Read whole because the NEIGHBOURS are what a browse
        /// capture has to be cleaned of.
        func slotRow() -> [String] {
            guard let bottom = freshStatus()?["lcd_bottom"] as? String else {
                return Array(repeating: "", count: MCULCDRow.cellCount)
            }
            return lcdFields(bottom).map {
                $0.trimmingCharacters(
                    in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker + " ")
                )
            }
        }
        // The blind `Thread.sleep(0.6)` that used to sit here is gone: the
        // zero-wait probe of 2026-09-02 read the row before and after it on
        // four runs and got byte-identical text every time. The press above is
        // already gated on the view appearing.
        let slotsBefore = slotRow()
        let slotBefore = slotsBefore.indices.contains(channel) ? slotsBefore[channel] : ""

        // D6: the answer to "load what is already there" is in hand.
        if instrumentSlotAlreadyHolds(slot: slotBefore, request: instrument, format: format) {
            deferSurfaceRestore(
                SurfaceDebt(strip: trackName, view: "instrument_bank", slot: nil)
            )
            return [
                "success": true,
                "verified": true,
                "state": "already_loaded",
                "track": trackName, "track_name": trackName,
                "instrument": splitInstrumentEntry(instrument).name,
                "slot_before": slotBefore,
                "slot_after": slotBefore,
                "mcu_strip": channel + 1,
                "entries_stepped": 0,
                "browse_messages": 0,
                "write_route": "none",
                "readback_route": "mcu_instrument_slot_name",
                "in_view_check": viewEvidence,
                "note": "'\(trackName)'s instrument slot already reads '\(slotBefore)' — nothing"
                    + " was browsed, pressed or replaced. The slot cell is six characters and"
                    + " carries no channel format, so if you need a specific one, or a genuine"
                    + " reload, pass format and the browser runs."
            ]
        }

        func browsed() -> String {
            guard let bottom = freshStatus()?["lcd_bottom"] as? String else { return "" }
            return instrumentBrowseWindow(row: bottom, channel: channel, slotRow: slotsBefore)
        }
        func match(_ captured: String) -> InstrumentBrowseMatch {
            instrumentBrowseMatch(
                captured: captured, request: instrument,
                format: format, windowWidth: windowWidth
            )
        }
        let ticks = instrumentBrowseTicksPerEntry
        var messages = 0
        /// One entry forward, PACED: the next message is not sent until this
        /// one has visibly landed. The old loop fired a tick, waited 300 ms for
        /// any event and settled every fourth step — and on the long walks
        /// 70-75% of its messages produced no new entry (measured 2026-09-02:
        /// 400 messages showed 105 distinct entries), while the discarded
        /// periodic settle was 27% of the walk. Waiting for the cell to CHANGE
        /// spends exactly one repaint per entry, which is what made the same
        /// change on the plug-in browser both faster and jump-safe.
        func stepForward(from shown: String) throws -> Bool {
            messages += 1
            guard try MCUBridge.send(.vpot(index: channel, delta: ticks)).ok else { return false }
            _ = waitFor(seconds: 0.25) { status in
                (status["lcd_bottom"] as? String).map {
                    instrumentBrowseWindow(row: $0, channel: channel, slotRow: slotsBefore) != shown
                } ?? false
            }
            return true
        }
        /// Carries the browse `count` entries from where it is now. Nothing is
        /// written by a browse — it is uncommitted until the vpot press — so a
        /// jump that lands in the wrong place costs steps and nothing else.
        /// At one tick per entry a single message carries 62 of them.
        var position = 0
        func jump(entries count: Int) throws -> Bool {
            for chunk in browseJumpPlan(ticks: count * ticks) {
                let before = freshStatus()?["received_events"] as? Int ?? -1
                messages += 1
                guard try MCUBridge.send(.vpot(index: channel, delta: chunk)).ok else {
                    return false
                }
                position += chunk / ticks
                _ = awaitEvents(since: before, timeoutMs: 400)
                // A multi-entry repaint goes on advancing while a second chunk
                // is sent into it, and that landing is neither asked-for nor
                // reversible. Wait for real silence between chunks.
                _ = waitForSurfaceQuiet(seconds: 2.0)
            }
            return true
        }

        // The bottom row is the per-strip SLOT list until the vpot is first
        // turned, so the browse's first entry only exists after one tick. Take
        // that step before the loop rather than teaching the loop to ignore its
        // own first read — which is also what makes `position` mean the same
        // thing it means in the plug-in map: entry 1 is one tick from the
        // origin.
        guard try stepForward(from: browsed()) else {
            exitToPan()
            throw LogicianError.writeFailed("MCU vpot failed: the bridge refused the browse tick")
        }

        let entryCap = min(max(maxSteps, 1), 5000)
        let budget = browseSearchBudget * Double(entryCap) / Double(browseEntryCap)
        let searchDeadline = Date().addingTimeInterval(budget)
        var entries: [String] = []
        var observed: [InstrumentCatalogMap.Entry] = []
        var found: InstrumentBrowseMatch = .none
        // The origin is only KNOWN when the slot started empty; a browse that
        // starts on an instrument starts somewhere in the middle of the list.
        // Recording needs a hole-free walk from a known origin (see
        // PluginCatalogMap); jumping needs only a known position, which an
        // anchor on a named entry can also supply.
        let slotWasEmpty = slotBefore.isEmpty || slotBefore == MCULCDStrings.emptySlot
        var positionKnown = slotWasEmpty
        var contiguous = slotWasEmpty
        var catalog = loadInstrumentCatalog()
        var jumpedToward: Int?
        var stepsSinceJump = 0
        var landedByJump = false

        while entries.count < entryCap, Date() < searchDeadline {
            let name = browsed()
            if !name.isEmpty, name != MCULCDStrings.emptySlot {
                let verdict = match(name)
                if verdict != .none {
                    if positionKnown, !landedByJump { position += 1 }
                    found = verdict
                    break
                }
                if name != entries.last {
                    if let first = entries.first, name == first, entries.count > 2 {
                        // A full lap with no match. The walk has now SEEN the
                        // whole catalog, which is the one thing this failure is
                        // good for: keep the map before reporting it.
                        if contiguous {
                            var learned = catalog ?? InstrumentCatalogMap()
                            learned.merge(observed, coveredPositions: position)
                            saveInstrumentCatalog(learned)
                        }
                        exitToPan()
                        throw LogicianError.trackNotExposed(
                            requested: "instrument '\(instrument)'"
                                + (format.map { " (\($0))" } ?? "")
                                + " in the control-surface instrument browser",
                            exposed: "the browser wrapped around without a match after"
                                + " \(Set(entries).count) distinct entries; entries seen: "
                                + entries.joined(separator: ", ")
                        )
                    }
                    if positionKnown, !landedByJump { position += 1 }
                    entries.append(name)
                    // A capture that fills the window may have lost its head,
                    // and a head-cut name means something different on another
                    // strip — never let one into the map.
                    if contiguous, positionKnown,
                       !instrumentEntryMayBeHeadCut(name, windowWidth: windowWidth) {
                        observed.append(
                            InstrumentCatalogMap.Entry(name: name, position: position)
                        )
                    }
                }
                if jumpedToward == nil {
                    // A browse that started on an instrument has no origin —
                    // but if the map knows the entry now on screen, it knows
                    // where this browse is standing.
                    if !positionKnown, let known = catalog,
                       let anchor = known.position(ofExactly: name) {
                        position = anchor
                        positionKnown = true
                    }
                    if positionKnown, let known = catalog,
                       let hint = known.instrumentPosition(
                           matching: instrument, format: format
                       ), hint - browseJumpUndershootEntries > position {
                        jumpedToward = hint
                        contiguous = false
                        guard try jump(
                            entries: hint - browseJumpUndershootEntries - position
                        ) else {
                            exitToPan()
                            throw LogicianError.writeFailed(
                                "MCU vpot failed: the bridge refused a browse jump"
                            )
                        }
                        landedByJump = true
                        continue
                    }
                    // No usable hint on the first real entry means there will
                    // not be one later either; stop asking.
                    jumpedToward = 0
                }
            }
            // A jump that has not paid off within a few steps was a wrong hint,
            // and a map that has been caught out is deleted rather than trusted
            // again — the walk carries on and still finds the instrument, or
            // still wraps, exactly as it would have from cold.
            if let hint = jumpedToward, hint > 0 {
                stepsSinceJump += 1
                if catalog != nil, stepsSinceJump > browseJumpGraceSteps {
                    discardInstrumentCatalog()
                    catalog = nil
                }
            }
            guard try stepForward(from: name) else {
                exitToPan()
                throw LogicianError.writeFailed(
                    "MCU vpot failed: the bridge refused a browse tick"
                )
            }
            landedByJump = false
        }
        let distinctSeen = Set(entries).count
        guard found != .none else {
            if contiguous {
                var learned = catalog ?? InstrumentCatalogMap()
                learned.merge(observed, coveredPositions: position)
                saveInstrumentCatalog(learned)
            }
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
                "the instrument browser never showed '\(instrument)' in the \(distinctSeen)"
                    + " catalog entries it looked at"
                    + (entries.count >= entryCap
                        ? " (the \(entryCap)-entry limit)"
                        : " in \(String(format: "%.0f", budget)) s (the search budget)")
                    + ", and never came back round to where it started — so the catalog may well"
                    + " go on past there. It holds every installed instrument in every channel"
                    + " format and is grouped by vendor, not alphabetical. Check the spelling, or"
                    + " raise max_steps (which raises the time budget with it)."
                    + (windowWidth < instrumentHeadCutMinimumWindow
                        ? " '\(trackName)' is also on MCU strip \(channel + 1), whose share of"
                            + " the shared browse row is only \(windowWidth) characters: an entry"
                            + " too long for that is painted shifted left and read with its head"
                            + " cut off, and \(windowWidth) characters of tail cannot be told"
                            + " from every other entry ending the same way — so a long name may"
                            + " have been shown and not been recognisable. Loading onto a track"
                            + " further left in the mixer is the way round it."
                        : "")
                    + " Nothing was instantiated — the browse was cancelled by leaving the view."
                    + " Entries seen most recently: " + entries.suffix(30).joined(separator: ", ")
            )
        }
        // Settle and re-verify before confirming. TWO quiet reads that agree,
        // and no back-stepping — which is a deliberate departure from
        // `addPluginViaBrowser`, taken on live evidence from 2026-09-02.
        //
        // The browse row's mirror does not always show where the cursor is: on
        // the long walks the profile counted 70-75% of reads returning an entry
        // that had been on screen much earlier, and one read of this run's own
        // proof showed the same name twice with another entry between them.
        // The old loop answered a disagreeing read by turning the vpot BACK up
        // to four times until some read matched — which, when the disagreement
        // was a stale frame rather than real drift, walked the cursor AWAY from
        // the target and pressed there. Measured today: a request for
        // `ARP 2600 V3` instantiated an `Abbey Road` plug-in (the alphabetical
        // neighbour it had just walked past), caught by the slot readback and
        // reported `restored: false` — a wrong destructive write on a tool that
        // cannot put a plug-in's state back.
        //
        // So the press is gated on STABILITY instead: silence, a read, silence
        // again, a second read, and the two must agree and match. A transient
        // stale frame cannot survive that, and a mirror that is persistently
        // wrong cannot be argued with — the honest answer there is to abort
        // with nothing instantiated, which a browse can always do by leaving
        // the view.
        /// Two quiet reads that AGREE, or nil when the row will not hold still.
        /// One read is not evidence here: the mirror can hand back a frame the
        /// cursor has already left.
        func stableEntry() -> String? {
            waitForSurfaceQuiet(seconds: 0.6)
            let first = browsed()
            waitForSurfaceQuiet(seconds: 0.3)
            let second = browsed()
            return first == second ? second : nil
        }
        // Correct onto the target, then prove it again. Direction comes from
        // the walk's own record rather than from guesswork: an entry the walk
        // has ALREADY listed is behind the target (step forward), and one it
        // has never listed is past it (step back). Each correction is proven
        // by another pair of agreeing reads, so a stale frame can neither end
        // the loop nor set its direction.
        var settled = stableEntry() ?? ""
        var corrections = 0
        while match(settled) == .none, corrections < 6 {
            let behind = entries.contains(settled)
            messages += 1
            _ = try? MCUBridge.send(.vpot(index: channel, delta: behind ? ticks : -ticks))
            settled = stableEntry() ?? ""
            corrections += 1
        }
        let landed = match(settled)
        guard landed != .none else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(instrument)' shown, twice over and with the surface quiet,"
                    + " at confirmation time",
                actual: settled.isEmpty
                    ? "the browse row would not hold still long enough to prove which entry the"
                        + " vpot is on; aborted without instantiating. Nothing was changed —"
                        + " call again"
                    : "the browser entry settled on '\(settled)' and \(corrections) correcting"
                        + " step(s) could not bring the target back; aborted without"
                        + " instantiating. Nothing was changed — call again",
                restored: true
            )
        }
        // What the row MEANS, which on a head-cut painting is not what it says.
        let confirmedEntry: String
        switch landed {
        case .headCut(let full): confirmedEntry = full
        default: confirmedEntry = settled
        }
        let expectedName = splitInstrumentEntry(confirmedEntry).name
        // The coordinate is the good one: read after the settle, corrected for
        // drift, and proven by the test that is about to gate the press.
        if contiguous, positionKnown,
           !instrumentEntryMayBeHeadCut(settled, windowWidth: windowWidth) {
            var learned = catalog ?? InstrumentCatalogMap()
            learned.merge(
                observed + [InstrumentCatalogMap.Entry(name: settled, position: position)],
                coveredPositions: position
            )
            saveInstrumentCatalog(learned)
        } else if contiguous {
            var learned = catalog ?? InstrumentCatalogMap()
            learned.merge(observed, coveredPositions: position)
            saveInstrumentCatalog(learned)
        }

        let topBeforeConfirm = freshStatus()?["lcd_top"] as? String ?? ""
        let confirm = try MCUBridge.send(.vpotPress(index: channel))
        guard confirm.ok else {
            exitToPan()
            throw LogicianError.writeFailed("MCU vpot press failed: \(confirm.error ?? "?")")
        }
        // Confirmation drops the surface into the new instrument's parameter
        // page. That page HAD not appeared at 0 ms (probed 2026-09-02 — the one
        // blind sleep here that was buying something real), so it is waited
        // for positively instead of slept through: a fast instrument costs
        // nothing, a slow one gets as long as it needs.
        _ = waitFor(seconds: 2.0) { ($0["lcd_top"] as? String) != topBeforeConfirm }
        waitForSurfaceQuiet(seconds: 0.6)
        let editTop = freshStatus()?["lcd_top"] as? String ?? ""

        // Second source: back in the IN BANK view, this strip's slot must name
        // the instrument. That row is painted per strip, so unlike the browse
        // row it says WHICH channel the instrument landed on — and the bank
        // view's top row names the strip, which is the proof the old code's
        // walk home to Pan was standing in for.
        let readbackEvidence = try ensureInstrumentBankView(
            channel: channel, trackName: trackName
        )
        let bankTop = freshStatus()?["lcd_top"] as? String ?? ""
        func slotCell() -> String {
            let cells = slotRow()
            return cells.indices.contains(channel) ? cells[channel] : ""
        }
        var slotAfter = slotCell()
        if !instrumentSlotNames(slotAfter, instrument: expectedName) {
            // The blind 0.8 s this replaces was already over when it started:
            // probed 2026-09-02, the slot read `DrmKit` / `ARPV3` / `AnlLab`
            // correctly at 0 ms on 3 of 3 runs. Waiting for the NAME instead
            // costs nothing when it is already there and still covers a slow
            // Audio Unit.
            _ = waitFor(seconds: 2.0) { status in
                guard let bottom = status["lcd_bottom"] as? String else { return false }
                let cells = lcdFields(bottom)
                guard cells.indices.contains(channel) else { return false }
                return instrumentSlotNames(cells[channel], instrument: expectedName)
            }
            slotAfter = slotCell()
        }
        guard instrumentSlotNames(slotAfter, instrument: expectedName) else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(expectedName)' in '\(trackName)'s instrument slot",
                actual: slotAfter.isEmpty || slotAfter == MCULCDStrings.emptySlot
                    ? "the slot still reads empty after the confirmation"
                    : "the slot reads '\(slotAfter)', which is not an abbreviation of it",
                restored: false
            )
        }
        // The surface stays in the IN bank view, whose content this readback
        // just proved. Walking home to Pan cost 2 666 ms mean here (22% of the
        // whole call, measured 2026-09-02) and the next surface tool only has
        // to leave again — so record the debt and let whoever actually needs
        // the Pan view settle it. `isPluginEditAssignment` already counts `IN`,
        // so the standing hazard (Logic auto-opening a plug-in window on the
        // next track selection) is covered by the same three settle routes.
        deferSurfaceRestore(SurfaceDebt(strip: trackName, view: "instrument_bank", slot: nil))

        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": slotWasEmpty ? "loaded" : "replaced",
            "track": trackName, "track_name": trackName,
            "instrument": expectedName,
            "browser_entry": confirmedEntry,
            "format": splitInstrumentEntry(confirmedEntry).format as Any? ?? NSNull(),
            "slot_before": slotBefore.isEmpty ? MCULCDStrings.emptySlot : slotBefore,
            "slot_after": slotAfter,
            "mcu_strip": channel + 1,
            // Entries actually SHOWN, not messages sent and not name changes:
            // the old counter said "306 entries stepped" where 105 distinct
            // entries had been on screen, and then advised raising max_steps.
            "entries_stepped": distinctSeen + 1,
            "browse_messages": messages,
            "browse_jumped": jumpedToward.map { $0 > 0 } ?? false,
            "write_route": "mcu_instrument_browser",
            "readback_route": "mcu_instrument_slot_name",
            "in_view_check": readbackEvidence ?? viewEvidence,
            // D7: the parameter page is real evidence when it exists and a row
            // of dashes when it does not — measured 2026-09-02, both Audio Unit
            // loads produced nothing but dashes while Logic's own Drum Kit
            // Designer produced a page. Say which, never imply a page that is
            // not there.
            "edit_page_after_confirm": instrumentEditPageEvidence(
                editTop, bankNamesRow: bankTop, channel: channel
            ),
            "note": "Loaded through the control surface's instrument browser (IN view) — no mouse, no menus. Read the new instrument's parameters with logic_mcu_instrument_parameters, which is also the independent second read of what landed."
        ]
        if case .headCut = landed {
            appendWarning(
                "The browse row was too narrow to show '\(confirmedEntry)' whole on MCU strip"
                    + " \(channel + 1) (\(windowWidth) characters): Logic painted it shifted left"
                    + " and it read '\(settled)'. The entry was identified by its tail, which is"
                    + " exact — the row can only end where the entry ends — and the slot readback"
                    + " confirms what landed.",
                to: &result
            )
        }
        if !slotWasEmpty {
            appendWarning(
                "'\(trackName)' already held an instrument ('\(slotBefore)') and it was REPLACED,"
                    + " along with all of its settings. Logic's own Undo is the way back; this"
                    + " server cannot restore a plug-in's state.",
                to: &result
            )
        }
        return result
    }

    /// The parameter page the confirming press dropped the surface into, or
    /// why there is none to report.
    ///
    /// The field is advertised as "the first sign it took", so what it must
    /// never do is hand back something that is not a page as if it were one.
    /// Two things are not a page, both seen live on 2026-09-02: a row of
    /// Logic's clearing dashes (`Analog Lab V`, and both Audio Unit loads the
    /// profile watched), and the CHANNEL NAMES row (`ARP 2600 V3` came back
    /// `LofPad Bas 808 Inst 2 Select Drums Fill AckSlg`). The names row is
    /// recognised by comparing against the bank view's own top row cell by
    /// cell, skipping the browsed strip's cell — that one carries Logic's
    /// transient `Select` banner.
    ///
    /// Only Logic's own instruments were ever observed painting a real page.
    static func instrumentEditPageEvidence(
        _ editTop: String, bankNamesRow: String, channel: Int
    ) -> Any {
        func unavailable(_ why: String) -> [String: String] {
            ["unavailable": why
                + " The load is verified by the instrument slot's own name instead;"
                + " logic_mcu_instrument_parameters is the independent second read."]
        }
        let stripped = editTop
            .replacingOccurrences(of: MCULCDStrings.clearingCell, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else {
            return unavailable(
                "the confirming press produced no control-surface parameter page — measured"
                + " 2026-09-02, Audio Unit instruments paint a row of dashes here while Logic's"
                + " own instruments paint their first parameter page.")
        }
        let page = lcdFields(editTop), names = lcdFields(bankNamesRow)
        let isNamesRow = !bankNamesRow.trimmingCharacters(in: .whitespaces).isEmpty
            && page.indices.allSatisfy { index in
                index == channel || (names.indices.contains(index) && page[index] == names[index])
            }
        if isNamesRow {
            return unavailable(
                "the confirming press left the channel-names row on the surface rather than a"
                + " parameter page — measured 2026-09-02, only Logic's own instruments open one.")
        }
        return editTop.trimmingCharacters(in: .whitespaces)
    }
}
