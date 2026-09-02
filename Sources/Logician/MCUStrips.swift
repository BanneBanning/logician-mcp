import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// The census and the one-call mixer read.
//
// `logic_list_tracks` answers with the track headers Logic has RENDERED — 20 of
// the reference project's 26 strips on 2026-08-28, reported as a plain success.
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

    /// Walks every bank in the pan-names view and reads it.
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
    static func scanBanks() throws -> [BankReading] {
        let projectPath = currentProjectPath()
        guard try ensurePanNames() else {
            throw LogicianError.trackNotExposed(
                requested: "the control surface's channel-name view",
                exposed: "the pan-names view could not be reached, so the strips cannot be read"
            )
        }
        try resetToLeftmostBank()
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
        var banks: [BankReading] = []
        for _ in 0..<10 {
            // The pass-1 bank walk. No progress here — the caller reports on a
            // scale this loop does not know the size of — but it is a real
            // multi-second wait, so it takes the cancellation check.
            try checkCancelled()
            if banks.last?.top == top { break }
            let status = freshStatus()
            banks.append(BankReading(
                top: top,
                bottom: status?["lcd_bottom"] as? String ?? "",
                rings: status?["vpot_rings"] as? [Int] ?? []
            ))
            try press("bank_right")
            guard let next = try settledTop(previous: top) else { break }
            top = next
        }
        saveScopedCache(banks.map(\.top), to: bankCacheURL, projectPath: projectPath)
        return banks
    }

    /// The census. Cross-checks every strip against the track headers
    /// Accessibility can see, so a strip that IS a rendered track comes back
    /// with its full name and track number, and a strip that is not is reported
    /// as exactly that — unresolved — rather than guessed at.
    static func listStrips(logic: LogicAccessibility) throws -> [String: Any] {
        guard freshStatus() != nil else {
            throw LogicianError.trackNotExposed(
                requested: "the Mackie Control bridge",
                exposed: "the bridge is not running or Logic has never talked to it (see logic_health)"
            )
        }
        let banks = try scanBanks()
        let bankTops = banks.map(\.top)
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
        return [
            "success": true,
            "strips": strips,
            "strip_count": strips.count,
            "bank_count": bankTops.count,
            "bank_rows": bankTops,
            "read_route": "mcu_bank_scan",
            "rendered_track_headers": headers.count,
            "note": "Every strip the control surface can reach, in project order — outputs, auxes and buses included, and independent of what the Tracks area has scrolled into view. `lcd_name` is Logic's own 6-character abbreviation; `track_name` is filled in only where exactly one RENDERED track header abbreviates to that cell, so `kind: unresolved` means 'not a visible track header' (an output/aux/bus, or a track scrolled out) and never 'does not exist'. Address any strip by its full Mixer name, not by the abbreviation."
        ]
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

    /// Strips whose record-ready LED (notes 0x00-0x07) was seen lit.
    static func recArmedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(0x00 + $0, in: status) }
    }

    static func mutedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(0x10 + $0, in: status) }
    }

    static func soloedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(0x08 + $0, in: status) }
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
    static let recBlinkWindow: TimeInterval = 1.6

    /// Samples the eight rec LEDs across a full blink cycle and returns the
    /// union of what was ever lit.
    static func sampleRecArmedStrips(window: TimeInterval = recBlinkWindow) -> Set<Int> {
        var seen: Set<Int> = []
        let deadline = Date().addingTimeInterval(window)
        repeat {
            if let status = freshStatus() {
                seen.formUnion(recArmedStrips(in: status))
            }
            Thread.sleep(forTimeInterval: 0.06)
        } while Date() < deadline
        return seen
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
    static func mixerSnapshot(logic: LogicAccessibility) throws -> [String: Any] {
        guard freshStatus() != nil else {
            throw LogicianError.trackNotExposed(
                requested: "the Mackie Control bridge",
                exposed: "the bridge is not running or Logic has never talked to it (see logic_health)"
            )
        }
        // Pass 1: names, pan and the pan-view vpot rings, in one settled read
        // per bank.
        let banks = try scanBanks()
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

        // Pass 2: dB, faders and the LED states, bank by bank.
        try resetToLeftmostBank()
        guard try ensureVolumeView() else {
            _ = try? ensurePanNames()
            throw LogicianError.trackNotExposed(
                requested: "the control surface's channel-strip Volume view",
                exposed: "it could not be reached, so no dB value can be read; nothing was written"
            )
        }
        var dbByBank: [Int: [String]] = [:]
        var fadersByBank: [Int: [Int]] = [:]
        var mutedByBank: [Int: [Int]] = [:]
        var soloedByBank: [Int: [Int]] = [:]
        var selectedByBank: [Int: [Int]] = [:]
        var armedByBank: [Int: Set<Int>] = [:]
        var metersByBank: [Int: (levels: [Int], overloads: [Bool])] = [:]
        var meterFeedAvailable = false
        for bank in 0..<bankTops.count {
            // Each bank costs a settle plus a 1.6 s blink window, so this loop
            // is where a big mixer spends its time and where a cancellation
            // has to land. Bailing here leaves the surface parked on whichever
            // bank was reached; the `ensurePanNames`/`resetToLeftmostBank`
            // restore below is skipped by the throw, which the shutdown path
            // and the next tool's own reset both handle.
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
            // The record-ready sampling window doubles as the settle the value
            // row needs after a bank step, so the blink costs nothing extra.
            armedByBank[bank] = sampleRecArmedStrips()
            guard let status = freshStatus() else { break }
            dbByBank[bank] = (status["lcd_bottom"] as? String).map(lcdValueFields) ?? []
            fadersByBank[bank] = status["faders_14bit"] as? [Int] ?? []
            mutedByBank[bank] = mutedStrips(in: status)
            soloedByBank[bank] = soloedStrips(in: status)
            selectedByBank[bank] = selectedStrips(in: status)
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
        reportProgress("mixer read; restoring the surface", percent: 100)
        let assignment = freshStatus()?["assignment"] as? String
        // Leave the surface where every other tool expects to find it.
        _ = try? ensurePanNames()
        try? resetToLeftmostBank()

        let headers = (try? logic.parsedTrackHeaders()) ?? []
        var strips: [[String: Any]] = []
        var unreadableDb = 0
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
            row["muted"] = (mutedByBank[entry.bank] ?? []).contains(entry.channel)
            row["soloed"] = (soloedByBank[entry.bank] ?? []).contains(entry.channel)
            row["selected"] = (selectedByBank[entry.bank] ?? []).contains(entry.channel)
            row["record_armed"] = (armedByBank[entry.bank] ?? []).contains(entry.channel)
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
            "read_route": "mcu_lcd_and_led_mirror",
            "meter_feed": meterFeedAvailable ? "available" : "unavailable",
            "note": "One read of the whole mixer off Logic's own control-surface feedback. volume_db is the dB string Logic prints in its channel-strip Volume view (the readout logic_set_track_volume converges against) — not a conversion of the fader position, which is reported separately and raw as fader_14bit. muted/soloed/selected come from the LED mirror. record_armed is sampled across a full blink cycle: Logic FLASHES an armed strip's record LED (~640 ms on / 640 ms off), so a single instant would read half of the armed strips as unarmed."
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
                    + " Re-read, or ask for the single strip with logic_set_track_volume's readback.",
                to: &result
            )
        }
        return result
    }
}
