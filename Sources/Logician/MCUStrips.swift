import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// The census and the one-call mixer read.
//
// `logic_list_tracks` answers with the track headers Logic has RENDERED — 20 of
// the reference project's 26 strips on 2026-08-28, reported as a plain success;
// 19 of 25 on 2026-09-02, the project having lost an aux in between. The strip
// count moves, the blind spot does not.
// The control surface has no such blind spot: every strip in the project is an
// ordinary bank channel, the bank scan already walks all of them, and the mirror
// already carries the faders, the lit LED note numbers and the vpot rings. What
// was missing was not access but DECODING — which is all this file is.
//
// Both reads are built on the same two-row grammar the rest of the MCU plane
// uses, and neither invents a number: the dB values are the ones Logic paints
// into its own channel-strip view (the readout `setVolume` converges against),
// and the LED states are Logic's own echo.

extension MCUController {

    /// One strip as the surface can address it.
    struct StripEntry: Equatable {
        /// 1-based position in the whole project's strip order.
        let position: Int
        /// Bank index from the leftmost bank, and the 0-based channel in it.
        let bank: Int
        let channel: Int
        /// The LCD name cell, verbatim (Logic's 6-character abbreviation).
        let cell: String
    }

    /// Every strip the surface can reach, in project order, from a bank map.
    ///
    /// The only non-obvious rule is the clamp: with a strip count that is not a
    /// multiple of 8 Logic's RIGHTMOST bank shows the *last* 8 strips, so it
    /// re-shows the tail of the bank before it shifted left. Counting the banks
    /// naively therefore invents up to seven strips that do not exist — the same
    /// double-count that once made `Stereo Out` read as "ambiguous"
    /// (`dedupedMatches`). Only the entries the clamp genuinely adds are kept,
    /// and each surviving strip keeps the bank/channel address it is reachable
    /// at in the EARLIEST bank that shows it, which is never the clamped one.
    ///
    /// Pure: a wrong answer here is a mixer read attributed to the wrong track,
    /// so every rule is unit-tested rather than watched.
    static func stripInventory(bankTops: [String]) -> [StripEntry] {
        guard !bankTops.isEmpty else { return [] }
        let overlapShift = bankTops.count >= 2
            ? clampOverlap(
                previous: lcdFields(bankTops[bankTops.count - 2]),
                last: lcdFields(bankTops[bankTops.count - 1])
              )
            : nil
        var entries: [StripEntry] = []
        for (bank, top) in bankTops.enumerated() {
            let cells = lcdFields(top)
            // On the clamped rightmost bank the first `8 - shift` cells are the
            // previous bank's tail again; only the rest are new strips.
            let firstNew = (bank == bankTops.count - 1)
                ? (overlapShift.map { 8 - $0 } ?? 0)
                : 0
            for (channel, cell) in cells.enumerated() where channel >= firstNew {
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                // A bank that is not full pads with empty cells (and Logic
                // paints a lone "-" while clearing) — neither is a strip.
                guard !trimmed.isEmpty, trimmed != MCULCDStrings.clearingCell else { continue }
                entries.append(StripEntry(
                    position: entries.count + 1, bank: bank, channel: channel, cell: trimmed
                ))
            }
        }
        return entries
    }

    /// One bank as the pan-names view shows it: the channel-name row, the pan
    /// value row underneath it and the vpot rings, all read at the same settled
    /// moment so they describe the same eight strips.
    struct BankReading {
        let top: String
        let bottom: String
        let rings: [Int]
    }

    /// Everything one bank walk established — the banks, and the one caveat
    /// that can survive a walk that otherwise succeeded.
    struct BankScan {
        let banks: [BankReading]
        /// A cell that has the exact spelling of a control-surface banner
        /// (`Solo`, `Mute`, …) and was STILL there after the fade budget. The
        /// name may be Logic's banner rather than the strip's — nothing can
        /// tell a stuck banner from a strip somebody really called `Solo` — so
        /// the map is not cached and the caller says so. nil in the ordinary
        /// case, including the ordinary banner, which fades in about two
        /// seconds and is simply waited out.
        let standingBanner: String?
    }

    /// The bank walk, with both of its ends PROVEN rather than counted.
    ///
    /// Where it starts: `resetToLeftmostBank` now returns whether the left
    /// edge proved itself, and this refuses rather than reading a map from an
    /// unknown starting bank — the census's `bank`/`strip` numbers and the
    /// `bank-cache.json` written from them are what every later WRITE resolves
    /// through, so a map that begins in the wrong place aims writes at the
    /// wrong channels. Before 2026-09-02 the walk was eight blind presses, so
    /// any project past 64 strips got exactly that, silently, with
    /// `success: true`.
    ///
    /// Where it ends: the rightmost bank CLAMPS (it re-shows the previous
    /// bank's tail), so pressing past it leaves the row unchanged — that is
    /// the surface proving the list ended, and `SettledTopOutcome.unchanged`
    /// is the only exit that means it. Running out of loop and a row that
    /// never settles are separate answers now, and both refuse.
    ///
    /// DELIBERATELY never reads the bank cache. The cache exists to make
    /// `findChannel` fast, and a stale entry there costs one failed lookup that
    /// the caller retries; in a CENSUS it would be a different and much worse
    /// error — the snapshot walks the live surface for dB and LED states and
    /// would pair them, row by row, with the names of a project that no longer
    /// exists. Observed 2026-08-28: a cache one track out of date attributed
    /// every value from that strip rightwards to its neighbour. Reading is what
    /// these two tools are FOR, so they pay for the scan and refresh the cache
    /// for everyone else.
    static func scanBanks() throws -> BankScan {
        let projectPath = currentProjectPath()
        guard try ensurePanNames() else {
            throw LogicianError.trackNotExposed(
                requested: "the control surface's channel-name view",
                exposed: "the pan-names view could not be reached, so the strips cannot be read"
            )
        }
        if case .unproven(let presses, let reason) = try resetToLeftmostBank() {
            throw LogicianError.trackNotExposed(
                requested: "the leftmost bank, which is where a census has to start counting",
                exposed: "\(reason) (\(presses) bank_left presses). Numbering the strips from an "
                    + "unknown bank would misname every one of them and poison the bank map every "
                    + "later write resolves through, so nothing was read and nothing was cached — "
                    + "check logic_health and try again"
            )
        }
        var settled = try settledTop()
        if settled == nil {
            _ = try ensurePanNames()
            settled = try settledTop()
        }
        guard var top = settled else {
            throw LogicianError.trackNotExposed(
                requested: "a settled channel-name row",
                exposed: "the surface's name row never settled; nothing was read"
            )
        }
        var standingBanner: String?
        var banks: [BankReading] = []
        var reachedRightmostBank = false
        scan: while banks.count < bankScanCap {
            // The pass-1 bank walk. No progress here — the caller reports on a
            // scale this loop does not know the size of — but it is a real
            // multi-second wait, so it takes the cancellation check.
            try checkCancelled()
            // THE BANNER, on every bank's row and not just the first: it
            // outlived three consecutive bank steps when this was measured.
            switch try rowWithoutControlBanner(top) {
            case .clear(let clean):
                top = clean
            case .standing(let row, let cell):
                top = row
                standingBanner = standingBanner ?? cell
            }
            let status = freshStatus()
            banks.append(BankReading(
                top: top,
                bottom: status?["lcd_bottom"] as? String ?? "",
                rings: status?["vpot_rings"] as? [Int] ?? []
            ))
            let beforeEvents = status?["received_events"] as? Int ?? -1
            try press("bank_right")
            switch try settledTopOutcome(previous: top, eventsBeforePress: beforeEvents) {
            case .settled(let next):
                top = next
            case .unchanged:
                reachedRightmostBank = true
                break scan
            case .neverSettled:
                throw LogicianError.trackNotExposed(
                    requested: "bank \(banks.count + 1)'s channel-name row",
                    exposed: "the row never settled after the bank step, so the surface could not be "
                        + "read past bank \(banks.count). A census that stopped there would look "
                        + "complete, so nothing was cached"
                )
            case .surfaceUnreadable:
                throw LogicianError.trackNotExposed(
                    requested: "bank \(banks.count + 1)'s channel-name row",
                    exposed: "the control-surface mirror stopped answering during the scan; "
                        + "nothing was cached (see logic_health)"
                )
            }
        }
        guard reachedRightmostBank else {
            throw LogicianError.trackNotExposed(
                requested: "every bank in the project",
                exposed: "the surface was still showing new banks after \(bankScanCap) of them "
                    + "(\(bankScanCap * 8) strips), so the census would be truncated without "
                    + "saying so; nothing was cached"
            )
        }
        // A row that may still be carrying a banner is not a map: cache it and
        // every later `findChannel` resolves that strip by a name Logic never
        // gave it.
        if standingBanner == nil {
            saveScopedCache(banks.map(\.top), to: bankCacheURL, projectPath: projectPath)
        }
        return BankScan(banks: banks, standingBanner: standingBanner)
    }

    /// Is this ONE cell spelling part of a control name Logic paints over a
    /// strip's name (`MCULCDStrings.controlNameBannerCells`) rather than a
    /// strip's name?
    ///
    /// PART of, not all of, and that is the record-arm case: `Record Enable`
    /// is thirteen characters laid down at a strip's cell origin, so the row
    /// carries it as the two cells `Record` and `Enable` and each of them has
    /// to be recognized on its own. The cell list is derived from the phrase
    /// list, so the census's row-level check and `bankedAtMatch`'s cell-level
    /// one can never disagree about what a banner looks like.
    static func isControlBannerCell(_ cell: String) -> Bool {
        MCULCDStrings.controlNameBannerCells.contains(cell.trimmingCharacters(in: .whitespaces))
    }

    /// The first cell of `row` that has the exact spelling of one of the
    /// control names Logic paints over a strip's name
    /// (`MCULCDStrings.controlNameBannerCells`).
    static func controlBannerCell(in row: String) -> String? {
        lcdFields(row)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: isControlBannerCell)
    }

    /// May this bank map be written to `bank-cache.json`?
    ///
    /// FS-4, measured 2026-09-03 (profiles/logic_set_track_solo.md): a full
    /// scan run while a press banner was standing wrote the literal `"Solo"`
    /// into `808`'s slot on disk, where it outlived the banner, the call and
    /// the process. Every later resolution that landed on that bank then met a
    /// cached row the live surface could never reproduce, and paid a
    /// guaranteed-to-fail 1.5 s wait plus a second full rescan — 4 332 ms for
    /// one solo restore, 3 627 of it inside `findChannel`.
    ///
    /// The scan waits a banner out first (`rowWithoutControlBanner`); this is
    /// the guard for the case where it would not fade. Pure, so the poisoned
    /// shape is tested without a surface.
    static func bankMapCacheable(_ bankTops: [String]) -> Bool {
        bankTops.allSatisfy { controlBannerCell(in: $0) == nil }
    }

    /// A per-strip control THIS SERVER pressed, and therefore a cell Logic is
    /// expected to be painting the control's own name over right now.
    ///
    /// The record exists for one reason: to tell "the banner over that cell is
    /// mine, from a press I made a moment ago" apart from "that cell says
    /// something the bank map does not". The first is a transient this process
    /// caused and can wait out for free; the second is a stale map, and
    /// `bankedAtMatch` must still fall through to a full rescan for it.
    struct ControlPressBanner: Equatable {
        /// The track whose cell was painted — matched by name, so a resolution
        /// of any OTHER track never gets the wildcard.
        let track: String
        /// The strip index within the showing bank.
        let channel: Int
        /// How many cells the banner covers, counted from `channel` rightwards.
        /// 1 for mute/solo/select, 2 for record-arm's `Record Enable` — the
        /// press site says which, because only it knows which button it sent.
        let cells: Int
        /// When the press went out.
        let at: Date

        init(track: String, channel: Int, cells: Int = 1, at: Date) {
            self.track = track
            self.channel = channel
            self.cells = max(1, cells)
            self.at = at
        }
    }

    nonisolated(unsafe) static var lastControlPressBanner: ControlPressBanner? // single-threaded server loop

    /// Records a per-strip press whose echo is a banner over that strip's name
    /// cell. Called at the press, not at the readback: the banner is up ~0.22 s
    /// later and the clock that matters is the press's.
    ///
    /// `banner` is the phrase from `MCULCDStrings` that this press is expected
    /// to paint, and it is passed rather than assumed because its WIDTH is the
    /// whole difference between mute and record-arm: `Mute` covers the touched
    /// cell, `Record Enable` covers that cell and its right-hand neighbour.
    static func noteControlPressBanner(
        track: String, channel: Int, banner: String, at: Date = Date()
    ) {
        lastControlPressBanner = ControlPressBanner(
            track: track, channel: channel,
            cells: MCULCDStrings.controlNameBannerSpan(banner), at: at
        )
    }

    /// How long after our own press a banner on that cell is still credibly
    /// ours.
    ///
    /// Longer than `controlBannerFadeBudget`, and deliberately: that budget
    /// bounds a WAIT, so it is sized to the 1.94-1.99 s the banner was measured
    /// to stand under 50 ms polling, while this bounds a piece of EVIDENCE and
    /// has to cover the longest stand anyone has seen. The solo profile hit the
    /// full tax at ~6.0 s after the press that painted the cell
    /// (profiles/logic_set_track_solo.md §5, 2026-09-03), so the real fade sits
    /// somewhere in a 2-8 s band rather than on a fixed number.
    ///
    /// Widening it costs nothing in safety: the wildcard only ever fires on a
    /// cell that LITERALLY spells one of Logic's control names, on the strip
    /// this server just pressed, for the track it is resolving — an expired
    /// record only sends the call down the slow path it used to always take.
    static let ownPressBannerTrustSeconds: TimeInterval = 8.0

    /// Is a banner over `channel` this server's OWN, from a press young enough
    /// to still be standing? Pure, so the rule is tested without a surface.
    ///
    /// Three things must agree: the same track (by name), the same strip index,
    /// and a press no older than `ownPressBannerTrustSeconds`.
    static func ownPressBannerStanding(
        _ record: ControlPressBanner?, track: String, channel: Int, now: Date
    ) -> Bool {
        ownPressBannerCells(record, track: track, channel: channel, now: now) > 0
    }

    /// HOW MANY cells starting at `channel` this server's own press is
    /// entitled to have painted — 0 when nothing here is ours.
    ///
    /// The same three-way agreement as `ownPressBannerStanding`; this is the
    /// form the matcher wants, because a record-arm press paints `Record
    /// Enable` across the touched cell AND its neighbour and "there is a
    /// banner" is no longer enough to say which cells to excuse.
    ///
    /// The span is what the PRESS SITE recorded, never what the live row
    /// looks like: a row that happens to show two banner-shaped cells after a
    /// one-cell press gets one cell excused and takes the walk for the other,
    /// which is the same conservative answer as before.
    static func ownPressBannerCells(
        _ record: ControlPressBanner?, track: String, channel: Int, now: Date
    ) -> Int {
        guard let record, record.track == track, record.channel == channel else { return 0 }
        let age = now.timeIntervalSince(record.at)
        guard age >= 0, age <= ownPressBannerTrustSeconds else { return 0 }
        return record.cells
    }

    /// Does the strip's own LCD cell prove it is the track about to be
    /// written — either because it still spells the name, or because the only
    /// thing standing on it is a banner THIS server painted there?
    ///
    /// The plain reading (`lcdAbbreviationPlausible`) is the first answer and
    /// the usual one. The second exists because making the banner-aware
    /// resolution fast MOVED this problem rather than solving it: with
    /// `findChannel` no longer waiting the banner out, a compare-and-set pair
    /// arrives here ~200 ms after its own press, reads `Record` where the
    /// track is called `Bas`, and refuses a write to a strip it had just
    /// proved. Measured live 2026-09-03: five consecutive record-arm calls
    /// refused with "the surface is banked somewhere else" — safely (nothing
    /// was pressed) but wrongly.
    ///
    /// Excusing the banner adds no trust that has not already been paid for.
    /// The caller got here through `findChannel`, whose `bankedAtMatch` had to
    /// match every OTHER cell of the row against the cached map for this bank
    /// before it would answer — seven or eight names, where a neighbouring
    /// bank differs in all of them. So the row has already said which bank the
    /// surface is standing on, and the map says which strip of it carries this
    /// name. What this check adds on top is that the surface has not moved
    /// since; a banner cell says exactly that, because it is the echo of the
    /// press that put us here.
    ///
    /// Pure, so the rule that lets a write through is pinned by a test rather
    /// than by a surface.
    static func stripProvenByCell(
        track: String, cell: String, channel: Int,
        record: ControlPressBanner?, now: Date = Date()
    ) -> Bool {
        if lcdAbbreviationPlausible(track: track, lcd: cell) { return true }
        guard isControlBannerCell(cell) else { return false }
        return ownPressBannerCells(record, track: track, channel: channel, now: now) > 0
    }

    /// What a look at a row carrying a control-name cell settled on.
    enum ControlBannerLook: Equatable {
        /// The row, with no cell spelling a control name — either it never had
        /// one, or the banner faded and this is what Logic painted underneath.
        case clear(String)
        /// The cell was still there when the budget ran out. Either Logic is
        /// holding a banner far longer than it has ever been measured to, or
        /// the strip really is called that; nothing on the surface can tell
        /// those apart, so the caller stops trusting the row instead.
        case standing(String, cell: String)
    }

    /// How long to let a control banner fade before giving up on it.
    ///
    /// MEASURED 2026-09-02 on `Testlåt Copy`, polling the LCD mirror every
    /// 50 ms across a solo of `Bas`: the `Solo` cell appeared 0.22 s after the
    /// call started and cleared **1.94 s** later; the unsolo repeated it at
    /// **1.99 s**. So it is a timed transient of roughly two seconds — the
    /// `bankedAtMatch` note that "a 600 ms wait never recovered it" was right
    /// about 600 ms and wrong to conclude that only a repaint clears it. A
    /// bank change does NOT clear it: measured the same day, a banner rode
    /// through three consecutive bank steps and was gone on the fourth purely
    /// because two seconds had passed.
    ///
    /// The budget is 1.5× the longest stand measured, counted from the moment
    /// the banner is FIRST SEEN — by then it has already spent part of its
    /// life, so the real headroom is larger.
    static let controlBannerFadeBudget = 3.0

    /// Waits out a control banner standing over a strip's name cell, and costs
    /// nothing at all when there is none — the check is one pure string
    /// comparison per bank.
    ///
    /// This became load-bearing when the bank walk got fast. The old walk spent
    /// 1.7 s on blind `bank_left` presses before it read anything, which
    /// happened to outlast the banner; measured 2026-09-02, the same
    /// solo-then-census experiment came back clean on the old build and, on
    /// the fast one, published `Solo` as a strip name in THREE banks and a
    /// strip count of 32 instead of 25 (the banner breaks `clampOverlap` too).
    /// An accidental wait is not a guard, so this is the real one.
    static func rowWithoutControlBanner(_ row: String) throws -> ControlBannerLook {
        guard let cell = controlBannerCell(in: row) else { return .clear(row) }
        let deadline = Date().addingTimeInterval(controlBannerFadeBudget)
        var latest = row
        while Date() < deadline {
            guard let status = freshStatus(), let now = status["lcd_top"] as? String else { break }
            latest = now
            if controlBannerCell(in: now) == nil {
                // Logic has just repainted the cell; take the row through the
                // usual settle so a half-painted one cannot be published.
                let settled = (try settledTop()) ?? now
                guard let stillThere = controlBannerCell(in: settled) else { return .clear(settled) }
                return .standing(settled, cell: stillThere)
            }
            _ = awaitEvents(since: status["received_events"] as? Int ?? -1, timeoutMs: 150)
        }
        return .standing(latest, cell: cell)
    }

    /// The census. Cross-checks every strip against the track headers
    /// Accessibility can see, so a strip that IS a rendered track comes back
    /// with its full name and track number, and a strip that is not is reported
    /// as exactly that — unresolved — rather than guessed at.
    static func listStrips(logic: LogicAccessibility) throws -> [String: Any] {
        try requireSurface("the Mackie Control bridge")
        let scan = try scanBanks()
        let bankTops = scan.banks.map(\.top)
        let inventory = stripInventory(bankTops: bankTops)
        let headers = (try? logic.parsedTrackHeaders()) ?? []
        var strips: [[String: Any]] = []
        for entry in inventory {
            var row: [String: Any] = [
                "strip": entry.position,
                "bank": entry.bank + 1,
                "channel": entry.channel + 1,
                "lcd_name": entry.cell
            ]
            let matches = headers.filter { lcdAbbreviationPlausible(track: $0.name, lcd: entry.cell) }
            if matches.count == 1, let header = matches.first {
                row["track_name"] = header.name
                row["track_number"] = header.number
                row["kind"] = "track"
                row["name_source"] = "ax_track_header"
            } else {
                // Either no rendered header abbreviates to this cell (an
                // output/aux/bus strip, or a track whose header is scrolled
                // out) or several do. Both are unresolved, and saying so is
                // the whole point of this tool.
                row["kind"] = "unresolved"
                row["name_source"] = "mcu_lcd_cell"
                if matches.count > 1 {
                    row["header_candidates"] = matches.map(\.name)
                }
            }
            strips.append(row)
        }
        var result: [String: Any] = [
            "success": true,
            "strips": strips,
            "strip_count": strips.count,
            "bank_count": bankTops.count,
            "bank_rows": bankTops,
            "read_route": "mcu_bank_scan",
            "rendered_track_headers": headers.count,
            "note": "Every strip the control surface can reach, in project order — outputs, auxes and buses included, and independent of what the Tracks area has scrolled into view. `lcd_name` is Logic's own 6-character abbreviation; `track_name` is filled in only where exactly one RENDERED track header abbreviates to that cell, so `kind: unresolved` means 'not a visible track header' (an output/aux/bus, or a track scrolled out) and never 'does not exist'. Address any strip by its full Mixer name, not by the abbreviation."
        ]
        if let banner = scan.standingBanner {
            result["warning"] = "A strip's name cell reads '\(banner)', which is exactly how Logic "
                + "spells the control it last saw pressed when it paints that name over the strip's "
                + "own name — and it was still there after \(Int(controlBannerFadeBudget)) seconds, "
                + "where that banner clears itself in about two. So either the strip really is "
                + "called '\(banner)' or the surface is holding a banner far longer than it has "
                + "ever been measured to; the bank map was NOT cached either way. Re-run to see "
                + "which."
        }
        return result
    }

    // MARK: Mixer snapshot

    /// Enters the multi-channel channel-strip VOLUME view and proves it by the
    /// LCD label rather than the assignment code: the assign_track button
    /// cycles submodes and the 7-segment code ("CS") is shown for all of them,
    /// so only the label is functional truth. Extracted from `setVolume`, which
    /// established the rule.
    static func ensureVolumeView() throws -> Bool {
        func showing() -> Bool {
            (freshStatus()?["lcd_top"] as? String)?
                .contains(MCULCDStrings.channelStripVolumeBanner) == true
        }
        if showing() { return true }
        for _ in 0..<3 {
            try press("assign_track")
            if waitFor(seconds: 1.2, { status in
                (status["lcd_top"] as? String)?
                    .contains(MCULCDStrings.channelStripVolumeBanner) == true
            }) != nil { return true }
        }
        return showing()
    }

    /// The four per-strip LED rows of the Mackie protocol, as note numbers.
    /// Eight wide each and BANK-RELATIVE, which is why one read only ever
    /// describes eight strips.
    static let recArmLEDBase = 0x00
    static let soloLEDBase = 0x08
    static let muteLEDBase = 0x10
    static let selectLEDBase = 0x18

    /// Strips whose record-ready LED (notes 0x00-0x07) was lit IN THIS ONE
    /// SNAPSHOT. Every one of these four decoders reads a single instant, and
    /// an instant is not a state: see `ledSteadiness` for the rule that turns
    /// a window of them into an answer, and D1 in
    /// `profiles/logic_mixer_snapshot.md` for what publishing one directly
    /// cost.
    static func recArmedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(recArmLEDBase + $0, in: status) }
    }

    static func mutedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(muteLEDBase + $0, in: status) }
    }

    static func soloedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(soloLEDBase + $0, in: status) }
    }

    /// The Mackie Control "rude solo" indicator — the ONE solo signal on this
    /// surface that is not bank-relative.
    ///
    /// Every other solo read here describes eight strips: notes 0x08…0x0F are
    /// the showing bank's, so a project wider than one bank needs a walk. Note
    /// 0x73 is different — Logic lights it while ANY channel in the project is
    /// soloed and clears it when the last one goes.
    ///
    /// Measured live 2026-09-02 on `Testlåt Copy` (19 rendered headers,
    /// 26 strips): soloing `Kick Tight` — track 10, inside the COLLAPSED
    /// `Drum Synth Kit` stack, so it publishes no track header AND occupies no
    /// surface strip — lit note 115, and unsoloing it cleared it. That makes
    /// this the only whole-project solo answer either plane can give.
    ///
    /// It is STEADY, not blinking, which is what lets a single read decide:
    /// 15 consecutive status reads across 2.5 s of a standing solo all had it
    /// lit, while the per-strip mute LEDs the same solo makes blink came and
    /// went inside that very sample. (Contrast `recBlinkWindow`, where the
    /// blinking is why a single read is not allowed to answer.)
    static let rudeSoloLED = 0x73

    /// Whether ANY channel in the project is soloed, from a status snapshot.
    /// Pure, so the rule is tested without a surface.
    static func anySoloedStrip(in status: [String: Any]) -> Bool {
        ledLit(rudeSoloLED, in: status)
    }

    /// The same question, asked of the live surface. `nil` means the surface
    /// could not be asked, which is NEVER the same answer as `false` — the
    /// caller that treats it as "nothing is soloed" is the bug this exists to
    /// prevent.
    static func anySoloedStripOnSurface() -> Bool? {
        guard let status = freshStatus() else { return nil }
        return anySoloedStrip(in: status)
    }

    /// Logic's own per-strip meter feed for the bank currently showing, or nil
    /// when the daemon does not publish it.
    ///
    /// nil and "all zero" are DIFFERENT answers and the difference is the
    /// whole point: a daemon older than bridge protocol 5 discarded the meter
    /// bytes, so absent keys mean "this daemon cannot tell you", while zeros
    /// mean "Logic says silence". Reporting the first as the second would
    /// invent a reading, which is the one thing a state read must never do.
    static func meterReading(in status: [String: Any]) -> (levels: [Int], overloads: [Bool])? {
        guard let levels = status["meter_levels"] as? [Int], !levels.isEmpty else { return nil }
        let overloads = status["meter_overloads"] as? [Bool] ?? []
        return (levels, overloads)
    }

    /// True when the daemon has decoded at least one meter message this
    /// session. `false` after a stretch of playback is the honest answer to
    /// "does Logic feed this surface meters at all?" — see FINDINGS G56.
    static func meterFeedSeen(in status: [String: Any]) -> Bool {
        (status["meter_events"] as? Int ?? 0) > 0
    }

    /// How long one record-ready blink cycle lasts, plus margin.
    ///
    /// Logic does not light the rec LED of an armed strip steadily — it FLASHES
    /// it, measured 2026-08-28 at roughly 640 ms on / 640 ms off (an 80 ms
    /// sampling of a single armed strip read
    /// `####........########........#########........`). A single snapshot of
    /// the mirror therefore reads an armed strip as unarmed about half the
    /// time, which is exactly how an early probe "lost" an arm it had just
    /// made. Every rec-LED read in this file is a WINDOW, and the evidence is
    /// asymmetric: seen lit once = armed; never lit across a full window =
    /// not armed.
    ///
    /// It is also the window that tells a blinking MUTE LED from a mute, and
    /// that blink is SLOWER than the record-ready one — worth knowing, because
    /// it is what sets the floor under this number. MEASURED 2026-09-02 on
    /// `Testlåt Copy` with `Bas` soloed, sampling the daemon's own mirror
    /// every 7.2 ms for 6 s: the mute LEDs of two solo-silenced strips (notes
    /// 0x10 and 0x15) toggled in exact phase with each other, 8 edges each,
    /// the gaps 729/730/730/731/732/734/735/736/738/741 ms — a ~733 ms phase,
    /// not 640. Two edges are therefore guaranteed only past
    /// 2 × 741 = 1 482 ms, so 1.6 s clears the bound by 118 ms while 1.4 s
    /// would NOT: it would read a flashing mute as steady on the ~9% of phases
    /// where it opens late enough to catch a single edge. That is the whole
    /// defect, so the margin is not decoration.
    static let recBlinkWindow: TimeInterval = 1.6

    // MARK: The blink rule — one window, four LED rows, two kinds of evidence

    /// How often the LED mirror is read inside a window. 60 ms against a
    /// 640 ms blink phase is ~10 samples per phase, so no phase can be missed.
    static let ledSampleInterval: TimeInterval = 0.06

    /// The window a bank pays when nothing that BLINKS is being asked about.
    ///
    /// Long enough to be a settle for the value row after a bank step (the
    /// pass-1 row settled in 137–164 ms, measured 2026-09-02) and to catch a
    /// late LED repaint, and short enough that four of them cost 1.2 s instead
    /// of the blink window's 6.5 s. It is NOT long enough to tell a blink from
    /// a steady LED, so it is only ever taken when the surface has said no
    /// solo is standing — see `ledWindowSeconds`.
    static let settledLEDWindow: TimeInterval = 0.3

    /// The longest a short window will wait for the value row to stop moving.
    static let valueRowHoldCap: TimeInterval = 1.2

    /// One pass over the mirror: the lit-note sets and the value rows seen,
    /// sample by sample, at `ledSampleInterval`.
    ///
    /// Sampling once and deciding four questions from the samples is what
    /// makes the blink rule free: `mixerSnapshot` was already paying this
    /// window for record-arm and reading mute/solo/select off a single instant
    /// beside it.
    ///
    /// `holdValueRow` extends a short window (never past `valueRowHoldCap`)
    /// until the value row has been byte-identical across two consecutive
    /// samples, so the dB read that follows cannot land on a half-painted row
    /// — the settle the blink window used to provide by being long.
    static func sampleSurface(
        window: TimeInterval, holdValueRow: Bool = false
    ) -> (leds: [Set<Int>], valueRows: [String]) {
        var leds: [Set<Int>] = []
        var rows: [String] = []
        let start = Date()
        while true {
            if let status = freshStatus() {
                leds.append(Set(status["leds_lit"] as? [Int] ?? []))
                if let bottom = status["lcd_bottom"] as? String { rows.append(bottom) }
            }
            Thread.sleep(forTimeInterval: ledSampleInterval)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= max(window, valueRowHoldCap) { break }
            if elapsed >= window, !holdValueRow || valueRowHeld(rows) { break }
        }
        return (leds, rows)
    }

    /// Has the value row stopped moving? Two consecutive identical samples,
    /// 60 ms apart. Pure, so "settled" is a rule rather than a sleep.
    static func valueRowHeld(_ rows: [String]) -> Bool {
        guard rows.count >= 2 else { return false }
        return rows[rows.count - 1] == rows[rows.count - 2]
    }

    /// What a window of samples says about ONE LED.
    enum LEDSteadiness: Equatable {
        /// It held one state for the whole window (at most one edge, and this
        /// is the state the window ENDED in).
        case steady(lit: Bool)
        /// It changed twice or more: Logic is flashing it.
        case blinking
        /// Nothing was sampled — the mirror never answered. NEVER the same
        /// answer as `steady(lit: false)`.
        case unsampled
    }

    /// Classifies one LED note across a window of samples by COUNTING EDGES.
    ///
    /// Not a majority vote and not a union, because the two failure modes pull
    /// in opposite directions and edges tell them apart:
    ///
    /// - Logic's blink is ~640 ms on / 640 ms off on the record-ready LED
    ///   (measured 2026-08-28) and ~733 ms on the mute LED a solo silences
    ///   (measured 2026-09-02 — see `recBlinkWindow`), so its edges are at
    ///   most ~741 ms apart and any window of `recBlinkWindow` (1.6 s)
    ///   contains AT LEAST TWO of them. Two edges is therefore proof of a
    ///   blink, and no steady state can produce them.
    /// - One edge is not a blink: it is a state that ARRIVED during the window
    ///   (the LED repaint after a bank step lands a few samples in), and the
    ///   honest reading of that is the state the window ended in. A rule that
    ///   demanded "lit in every sample" would report a genuinely muted strip
    ///   as unmuted whenever its repaint was late — the same silent wrongness
    ///   pointing the other way.
    static func ledSteadiness(_ note: Int, across samples: [Set<Int>]) -> LEDSteadiness {
        guard let first = samples.first else { return .unsampled }
        var edges = 0
        var lit = first.contains(note)
        for sample in samples.dropFirst() where sample.contains(note) != lit {
            edges += 1
            lit.toggle()
            if edges >= 2 { return .blinking }
        }
        return .steady(lit: lit)
    }

    /// The strips of one bank whose LED at `base` was steadily lit, and the
    /// ones Logic was flashing. Blinking is reported separately and never
    /// folded into "lit": which of the two a caller may publish depends on
    /// what the LED means (see `decodeBankLEDs`).
    static func steadyLitStrips(
        base: Int, across samples: [Set<Int>]
    ) -> (lit: [Int], blinking: [Int]) {
        var lit: [Int] = []
        var blinking: [Int] = []
        for channel in 0..<8 {
            switch ledSteadiness(base + channel, across: samples) {
            case .steady(let on): if on { lit.append(channel) }
            case .blinking: blinking.append(channel)
            case .unsampled: break
            }
        }
        return (lit, blinking)
    }

    /// The strips whose LED at `base` was EVER lit — the asymmetric rule
    /// record-arm needs, where a blink is the positive answer.
    static func everLitStrips(base: Int, across samples: [Set<Int>]) -> [Int] {
        (0..<8).filter { channel in samples.contains { $0.contains(base + channel) } }
    }

    /// One LED note, classified across a window of the LIVE mirror — the
    /// single-strip counterpart of `decodeBankLEDs`, for the write paths.
    ///
    /// It returns the moment `ledSteadiness` can say `.blinking`, because two
    /// edges are proof and no later sample can revise them; only a steady LED
    /// has to be watched for the whole window. `samples` and `elapsed` come
    /// back so a result — or a refusal — can say what its evidence cost.
    static func ledSteadinessOnSurface(
        _ note: Int, window: TimeInterval
    ) -> (verdict: LEDSteadiness, samples: Int, elapsed: TimeInterval) {
        var samples: [Set<Int>] = []
        let start = Date()
        while true {
            if let status = freshStatus() {
                samples.append(Set(status["leds_lit"] as? [Int] ?? []))
                if ledSteadiness(note, across: samples) == .blinking { break }
            }
            if Date().timeIntervalSince(start) >= window { break }
            Thread.sleep(forTimeInterval: ledSampleInterval)
        }
        return (
            ledSteadiness(note, across: samples),
            samples.count,
            Date().timeIntervalSince(start)
        )
    }

    /// One bank's four LED rows, decided from one window.
    struct BankLEDReading: Equatable {
        /// Steadily lit mute LEDs: a real mute.
        let muted: [Int]
        /// Mute LEDs Logic was FLASHING — channels a standing solo silences,
        /// which is not the same fact as `muted` and is reported separately.
        let muteBlinking: [Int]
        let soloed: [Int]
        let selected: [Int]
        /// Any LED row that blinked where nothing is known to blink. Empty in
        /// every state measured so far; a warning rather than a silent guess.
        let unexpectedBlinks: [String]
        /// Strips seen record-armed, or nil when the caller did not ask —
        /// which makes the field ABSENT from the row rather than false.
        let recordArmed: [Int]?
    }

    /// The per-family evidence rules, in one place, over one window.
    ///
    /// - record-arm: EVER lit. Logic flashes an armed strip's rec LED, so a
    ///   blink is the armed answer (`recBlinkWindow`).
    /// - mute: STEADILY lit. Logic flashes the mute LED of every channel a
    ///   standing solo silences (proven live 2026-09-02: with only `Bas`
    ///   soloed and nothing muted anywhere, one instant reported six strips
    ///   `muted: true`), so a mute LED that blinks is evidence of a SOLO and a
    ///   real mute is the steady one. Exactly the mirror image of the rule
    ///   above, from the same samples.
    /// - solo and select: STEADILY lit. Both are steady in every state
    ///   measured (15 consecutive reads of a standing solo, 2026-09-02), so
    ///   the window costs them nothing and protects them from the transient
    ///   mid-repaint frame that the single instant never guarded against.
    ///
    /// `nil` when the window produced no sample at all: with nothing sampled
    /// every list would be empty and every field would read `false`, which is
    /// an invented state read. The caller reports those strips without LED
    /// fields and says why.
    static func decodeBankLEDs(
        samples: [Set<Int>], includeRecordArm: Bool
    ) -> BankLEDReading? {
        guard !samples.isEmpty else { return nil }
        let mute = steadyLitStrips(base: muteLEDBase, across: samples)
        let solo = steadyLitStrips(base: soloLEDBase, across: samples)
        let select = steadyLitStrips(base: selectLEDBase, across: samples)
        var unexpected: [String] = []
        if !solo.blinking.isEmpty { unexpected.append("solo") }
        if !select.blinking.isEmpty { unexpected.append("select") }
        return BankLEDReading(
            muted: mute.lit,
            muteBlinking: mute.blinking,
            soloed: solo.lit,
            selected: select.lit,
            unexpectedBlinks: unexpected,
            recordArmed: includeRecordArm
                ? everLitStrips(base: recArmLEDBase, across: samples)
                : nil
        )
    }

    /// The LED fields of one strip row. Pure, because "absent, not false" is a
    /// contract and a contract is worth a test: `record_armed` is missing
    /// entirely when it was not asked for, and `mute_led_blinking` appears
    /// only on a strip Logic is flashing.
    static func ledRowFields(channel: Int, reading: BankLEDReading) -> [String: Any] {
        var fields: [String: Any] = [
            "muted": reading.muted.contains(channel),
            "soloed": reading.soloed.contains(channel),
            "selected": reading.selected.contains(channel)
        ]
        if let armed = reading.recordArmed {
            fields["record_armed"] = armed.contains(channel)
        }
        if reading.muteBlinking.contains(channel) {
            fields["mute_led_blinking"] = true
        }
        return fields
    }

    /// How long one bank's LED window has to be.
    ///
    /// The full blink window is paid when something that blinks is actually
    /// being asked about: record-arm (the caller asked for it) or mute while a
    /// solo stands anywhere in the project — which note 0x73 answers for the
    /// whole project in one steady read (`anySoloedStrip`). With no solo
    /// standing nothing flashes a mute LED, so a short settle is enough and
    /// the four windows cost 1.2 s instead of 6.5 s.
    ///
    /// `nil` (the surface could not be asked) takes the long window: the
    /// conservative side of that question is the one that stays correct.
    static func ledWindowSeconds(includeRecordArm: Bool, soloStanding: Bool?) -> TimeInterval {
        if includeRecordArm { return recBlinkWindow }
        return soloStanding == false ? settledLEDWindow : recBlinkWindow
    }

    /// The whole mixer in one call: every strip's fader dB as Logic prints it,
    /// its mute/solo/select/record state off the LED mirror, its raw 14-bit
    /// fader echo, and its pan.
    ///
    /// Two walks, because the facts live in two views: the PAN view paints the
    /// channel names and the pan positions, and the channel-strip VOLUME view
    /// paints the dB values (verified 2026-08-28). The first walk is also what
    /// establishes strip identity — see `scanBanks` for why a cached map is not
    /// allowed to do that here. LED states are read per bank: the LED note
    /// numbers are bank-RELATIVE, so one read only ever describes eight strips.
    ///
    /// Every LED answer comes out of a sampled WINDOW rather than an instant
    /// (`decodeBankLEDs`), which is what stops a blinking LED being published
    /// as a steady state. `includeRecordArm: false` drops the one question
    /// that needs the full 1.6 s blink window per bank and makes the field
    /// absent — as long as no solo is standing, because a standing solo makes
    /// the mute LEDs blink and the window is then the mute answer's evidence
    /// too.
    ///
    /// MEASURED 2026-09-02 on `Testlåt Copy` (25 strips / 4 banks), against
    /// 12 246–12 432 ms before this change: **8 547 / 10 126 ms** with
    /// record-arm, **5 517 ms** without it, and 10 238 / 11 148 ms with a solo
    /// standing (was 14 560–14 686 ms).
    static func mixerSnapshot(
        logic: LogicAccessibility, includeRecordArm: Bool = true
    ) throws -> [String: Any] {
        try requireSurface("the Mackie Control bridge")
        // Pass 1: names, pan and the pan-view vpot rings, in one settled read
        // per bank.
        let scan = try scanBanks()
        let banks = scan.banks
        let bankTops = banks.map(\.top)
        let inventory = stripInventory(bankTops: bankTops)
        guard !inventory.isEmpty else {
            throw LogicianError.trackNotExposed(
                requested: "a readable bank map",
                exposed: "the surface reported no named strips"
            )
        }
        var panByBank: [Int: [String]] = [:]
        var ringsByBank: [Int: [Int]] = [:]
        for (bank, reading) in banks.enumerated() {
            panByBank[bank] = lcdValueFields(reading.bottom)
            ringsByBank[bank] = reading.rings
        }

        // Pass 2: dB, faders and the LED states, bank by bank. Pass 1's
        // identities are paired with these values by bank index, so a walk
        // that fell short of the left edge would pair every strip with its
        // neighbour's dB — the same wrong-channel hazard as a shifted census.
        if case .unproven(let presses, let reason) = try resetToLeftmostBank() {
            _ = try? ensurePanNames()
            throw LogicianError.trackNotExposed(
                requested: "the leftmost bank, to start the second (dB and LED) walk",
                exposed: "\(reason) (\(presses) bank_left presses). The values would be paired "
                    + "with the wrong strips, so nothing was read"
            )
        }
        guard try ensureVolumeView() else {
            _ = try? ensurePanNames()
            throw LogicianError.trackNotExposed(
                requested: "the control surface's channel-strip Volume view",
                exposed: "it could not be reached, so no dB value can be read; nothing was written"
            )
        }
        var dbByBank: [Int: [String]] = [:]
        var fadersByBank: [Int: [Int]] = [:]
        var ledsByBank: [Int: BankLEDReading] = [:]
        var metersByBank: [Int: (levels: [Int], overloads: [Bool])] = [:]
        var meterFeedAvailable = false
        // THE WHOLE-PROJECT SOLO ANSWER, taken once. Note 0x73 is steady and
        // not bank-relative (`rudeSoloLED`), and it is what decides whether
        // the mute LEDs are being blinked at all — so it is both the cheap
        // window decision and the independent witness the per-strip solo list
        // is cross-checked against below.
        let soloStanding = anySoloedStripOnSurface()
        let window = ledWindowSeconds(includeRecordArm: includeRecordArm, soloStanding: soloStanding)
        for bank in 0..<bankTops.count {
            // Each bank costs a settle plus its LED window, so this loop is
            // where a big mixer spends its time and where a cancellation has
            // to land. Bailing here leaves the surface parked on whichever
            // bank was reached, which the next tool's own reset (and the
            // shutdown path) handle.
            //
            // Pass 1 (the bank walk above) is roughly a third of the cost, so
            // this pass reports across 30…100. Nested inside
            // logic_project_snapshot these land inside that section's slice.
            try checkCancelled()
            reportProgress(
                "reading mixer bank \(bank + 1)/\(bankTops.count)",
                percent: 30 + 70 * Double(bank) / Double(bankTops.count)
            )
            _ = quiescentStatus()
            // ONE window, four LED rows. It doubles as the settle the value
            // row needs after a bank step: the long window is long enough by
            // itself, and the short one waits for the row to hold still.
            let samples = sampleSurface(
                window: window, holdValueRow: window < recBlinkWindow
            )
            ledsByBank[bank] = decodeBankLEDs(samples: samples.leds, includeRecordArm: includeRecordArm)
            guard let status = freshStatus() else { break }
            dbByBank[bank] = (status["lcd_bottom"] as? String).map(lcdValueFields) ?? []
            fadersByBank[bank] = status["faders_14bit"] as? [Int] ?? []
            // Logic's own meter feed, if this daemon publishes it. Sampled at
            // the same instant as the rest of this bank's row — which is a
            // DIFFERENT instant from every other bank's, so these eight
            // numbers are a snapshot, never a comparison across the mixer.
            if let reading = meterReading(in: status) {
                meterFeedAvailable = true
                metersByBank[bank] = reading
            }
            if meterFeedSeen(in: status) { meterFeedAvailable = true }
            if bank < bankTops.count - 1 { try press("bank_right") }
        }
        reportProgress("mixer read", percent: 100)
        // PATTERN #1, the debt: everything this call reports is in memory by
        // now, and putting the surface back in the Pan view at the leftmost
        // bank cost 3 671 ms — 30% of the call, measured 2026-09-02 — AFTER
        // the last byte the caller waited for. So it is recorded as a debt
        // instead of paid here. `ensurePanNames` settles it the moment any
        // tool that needs that view asks for it (107 ms if the surface is
        // already there), `settleSurfaceDebt` pays it before an Accessibility
        // selection onto another strip, and `MCPServer.shutdown()` pays it
        // when the session ends — so the surface is never LEFT in this view,
        // it is only handed over in it. Every FAILURE path above keeps its own
        // explicit restore: a refusal has no result for the debt to travel
        // with.
        deferSurfaceRestore(SurfaceDebt(strip: nil, view: "channel_strip", slot: nil))
        // Read AFTER the restore decision, which is the whole point: this used
        // to be read before two restore calls that changed it, so a payload
        // saying "CS" described a surface the call had already moved to PN.
        let assignment = freshStatus()?["assignment"] as? String

        let headers = (try? logic.parsedTrackHeaders()) ?? []
        var strips: [[String: Any]] = []
        var unreadableDb = 0
        var blinkingMutes: [Int] = []
        var unexpectedBlinks: Set<String> = []
        var unreadLEDStrips = 0
        for entry in inventory {
            var row: [String: Any] = [
                "strip": entry.position,
                "bank": entry.bank + 1,
                "channel": entry.channel + 1,
                "lcd_name": entry.cell
            ]
            let matches = headers.filter { lcdAbbreviationPlausible(track: $0.name, lcd: entry.cell) }
            if matches.count == 1, let header = matches.first {
                row["track_name"] = header.name
                row["track_number"] = header.number
                row["kind"] = "track"
            } else {
                row["kind"] = "unresolved"
            }
            let dbCells = dbByBank[entry.bank] ?? []
            let dbText = dbCells.indices.contains(entry.channel) ? dbCells[entry.channel] : ""
            row["volume_text"] = dbText
            if let db = parseDb(dbText) {
                row["volume_db"] = (db * 10).rounded() / 10
            } else {
                row["volume_db"] = NSNull()
                unreadableDb += 1
            }
            let faders = fadersByBank[entry.bank] ?? []
            row["fader_14bit"] = faders.indices.contains(entry.channel) && faders[entry.channel] >= 0
                ? faders[entry.channel] as Any : NSNull() as Any
            if let leds = ledsByBank[entry.bank] {
                row.merge(ledRowFields(channel: entry.channel, reading: leds)) { current, _ in current }
                if leds.muteBlinking.contains(entry.channel) { blinkingMutes.append(entry.position) }
                unexpectedBlinks.formUnion(leds.unexpectedBlinks)
            } else {
                // The bank was never sampled (the mirror stopped answering
                // mid-walk). Absent is the only honest answer — `false` here
                // would be a state read this call never took.
                unreadLEDStrips += 1
            }
            let panCells = panByBank[entry.bank] ?? []
            let panText = panCells.indices.contains(entry.channel) ? panCells[entry.channel] : ""
            row["pan_text"] = panText
            row["pan"] = parseNumber(panText).map { $0 as Any } ?? NSNull() as Any
            let rings = ringsByBank[entry.bank] ?? []
            row["pan_ring"] = rings.indices.contains(entry.channel)
                ? rings[entry.channel] as Any : NSNull() as Any
            // Meters are present only when the daemon publishes them, and a
            // strip Logic has never metered stays absent rather than reading 0.
            if let reading = metersByBank[entry.bank] {
                if reading.levels.indices.contains(entry.channel),
                   reading.levels[entry.channel] >= 0 {
                    row["meter_level"] = reading.levels[entry.channel]
                }
                if reading.overloads.indices.contains(entry.channel) {
                    row["meter_overload"] = reading.overloads[entry.channel]
                }
            }
            strips.append(row)
        }
        var result: [String: Any] = [
            "success": true,
            "strips": strips,
            "strip_count": strips.count,
            "bank_count": bankTops.count,
            "assignment_after": assignment ?? NSNull(),
            "surface_restore": "deferred",
            "read_route": "mcu_lcd_and_led_mirror",
            "any_soloed": soloStanding.map { $0 as Any } ?? NSNull() as Any,
            "led_evidence": window >= recBlinkWindow ? "blink_window" : "settled_window",
            "meter_feed": meterFeedAvailable ? "available" : "unavailable",
            "note": "One read of the whole mixer off Logic's own control-surface feedback. volume_db is the dB string Logic prints in its channel-strip Volume view (the readout logic_set_track_mix converges against) — not a conversion of the fader position, which is reported separately and raw as fader_14bit. muted/soloed/selected/record_armed come from the LED mirror, each sampled across a WINDOW rather than one instant, because Logic uses a blinking LED as a state of its own: an armed strip's record LED flashes (~640 ms on / 640 ms off), so seen-lit-once means armed, while the mute LED flashes on every channel a standing solo silences, so only a STEADY mute LED is a mute — a blinking one is marked mute_led_blinking and reported muted: false. any_soloed is note 0x73, Logic's whole-project solo indicator, which sees soloed channels this surface has no strip for. assignment_after is the view the surface is HANDED OVER in: the return to the pan view is deferred (surface_restore) and paid by the next control-surface tool or at session end."
        ]
        if meterFeedAvailable {
            result["meter_note"] = "meter_level is Logic's OWN control-surface meter for that strip:"
                + " the segment count it would light on a Mackie Control, 0 (silence) to 12 (top"
                + " segment), with meter_overload as its clip indicator. It is a STATE READ of a"
                + " value Logic published, exactly like the fader echo — it is NOT an audio"
                + " measurement, it has no dB calibration, and it must never be reported as"
                + " loudness. Two further limits: meters only move while the transport is ROLLING"
                + " (everything reads 0 when stopped), and each bank was sampled at a different"
                + " instant during the walk, so these numbers are eight-strip snapshots and not"
                + " a like-for-like comparison across the mixer. To hear a level, bounce and listen."
        } else {
            result["meter_note"] = "This daemon does not publish Logic's meter feed"
                + " (bridge protocol < 5, which received the meter bytes and discarded them)."
                + " meter_level/meter_overload are therefore ABSENT rather than zero. Restart the"
                + " bridge daemon on a current build to get them."
        }
        if unreadableDb > 0 {
            appendWarning(
                "\(unreadableDb) strip(s) had no parsable dB cell in the channel-strip Volume view;"
                    + " their volume_db is null and volume_text carries whatever the LCD showed."
                    + " Re-read, or ask for the single strip with logic_set_track_mix's readback.",
                to: &result
            )
        }
        // The blinking mutes are NOT a fault — they are what a standing solo
        // looks like on this surface — so they are reported as a fact rather
        // than a warning, and named, because "silenced right now but not
        // muted" is exactly what an agent asked to undo a solo pass needs.
        if !blinkingMutes.isEmpty {
            result["mute_blink_note"] = "Strip(s) \(blinkingMutes.map(String.init).joined(separator: ", "))"
                + " have a BLINKING mute LED and are reported muted: false. Logic flashes the mute"
                + " LED of every channel a standing solo silences (any_soloed is true), so those"
                + " channels are silent right now but not muted — pressing mute on them would"
                + " mute them. Unsolo and re-read to see the mixer without the blink."
        }
        if !unexpectedBlinks.isEmpty {
            appendWarning(
                "The \(unexpectedBlinks.sorted().joined(separator: " and ")) LED(s) of at least one"
                    + " strip were BLINKING, which nothing in this project has been measured to do."
                    + " Those strips are reported false for that field rather than guessed at;"
                    + " re-read, and if it persists the LED meaning needs re-establishing.",
                to: &result
            )
        }
        if soloStanding == true, strips.allSatisfy({ $0["soloed"] as? Bool != true }) {
            result["solo_note"] = "Logic's whole-project solo indicator (note 0x73) is lit but no"
                + " strip on the surface reads soloed: the soloed channel has no strip of its own"
                + " here — a track inside a collapsed folder stack is the measured case. Nothing is"
                + " wrong with the strip rows; the mixer simply cannot name it."
        }
        if unreadLEDStrips > 0 {
            appendWarning(
                "\(unreadLEDStrips) strip(s) carry no muted/soloed/selected fields at all: the"
                    + " control-surface mirror stopped answering during their bank's LED window, and"
                    + " an absent field is the honest answer where false would be an invented state."
                    + " Re-read (see logic_health).",
                to: &result
            )
        }
        return result
    }
}
