import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Instrument slot (assign_instrument, assignment code "IN")

    /// Enters the instrument edit mode for a track: bank to the track's
    /// channel in the pan view, switch to the instrument bank view, then
    /// vpot-press the channel. Never turns vpots in the bank view (that is
    /// the instrument browser). Returns nil when unavailable/no instrument.
    static func enterInstrumentEdit(trackName: String) throws -> (channel: Int, name: String)? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        try press("assign_instrument")
        guard let inView = waitFor(seconds: 2.0, {
            ($0["assignment"] as? String) == MCULCDStrings.Assignment.instrument
        }),
              let instrumentBankTop = inView["lcd_top"] as? String else {
            exitToPan()
            return nil
        }
        // Empty instrument slot shows "--"; entering it would be pointless.
        var instrumentName = ""
        if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String {
            instrumentName = lcdFields(bottom)[channel].trimmingCharacters(
                in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
            )
            if instrumentName.isEmpty || instrumentName == MCULCDStrings.emptySlot {
                exitToPan()
                return nil
            }
        }
        let response = try MCUBridge.send(.vpotPress(index: channel))
        guard response.ok else {
            exitToPan()
            return nil
        }
        if waitFor(seconds: 2.5, { status in
            guard (status["assignment"] as? String) == MCULCDStrings.Assignment.instrument,
                  let top = status["lcd_top"] as? String else { return false }
            return top != instrumentBankTop
        }) != nil {
            return (channel, instrumentName)
        }
        exitToPan()
        return nil
    }

    static func setInstrumentParameter(
        trackName: String,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?
    ) throws -> [String: Any]? {
        guard let entered = try enterInstrumentEdit(trackName: trackName) else { return nil }
        defer { exitToPan() }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: "instrument:" + entered.name
        ) else { return nil }
        result["slot_type"] = "instrument"
        return result
    }

    /// Shared core for plugin and instrument edit modes: search every
    /// parameter page for the match, navigate to its page, then converge.
    /// Page read for searching: cached names + instant value row when the
    /// cache matches this plugin, otherwise the fade-waiting settled read.
    static func pageForSearch(
        cacheKey: String?, projectPath: String?, pageNumber: Int, totalPages: Int
    ) -> [(name: String, value: String)]? {
        if let key = cacheKey {
            let cached = loadNameCache(projectPath: projectPath)[key]
            if let names = cached, names.count == max(totalPages, 1),
               pageNumber <= names.count, names[pageNumber - 1].count == 8 {
                _ = quiescentStatus()
                if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String,
                   let top = status["lcd_top"] as? String {
                    // Fields 0-5 are already repainted while the "Page x/y"
                    // indicator still covers 6-7, so they cost nothing to
                    // check - and this row is about to be paired with LIVE
                    // values and then WRITTEN to by vpot index. A shifted
                    // layout must fall back to the honest read, not aim the
                    // encoder at whatever now sits in that position.
                    let names = names[pageNumber - 1]
                    let liveNames = lcdFields(top)
                    let shifted = (0..<6).contains { index in
                        liveNames[index] != names[index]
                            && liveNames[index].range(
                                of: MCULCDStrings.pageIndicatorCellPattern,
                                options: .regularExpression
                            ) == nil
                    }
                    if !shifted {
                        return zip(names, lcdValueFields(bottom)).map { ($0, $1) }
                    }
                    dropNameCache(key: key, projectPath: projectPath)
                }
            }
        }
        return settledParameterPage()
    }

    static func searchAndSetParameter(
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        cacheKey: String? = nil
    ) throws -> [String: Any]? {
        // Search all parameter pages; remember where the match lives.
        let totalPages = try normalizeToPageOne()
        let projectPath = currentProjectPath()
        var trustedKey = cacheKey
        var match: (page: Int, index: Int, name: String)?
        var landedPage: [(name: String, value: String)]?

        // FAST PATH — resolve the address from the cached name rows and go
        // straight there.
        //
        // The walk this replaces existed to answer one question: is this name
        // unambiguous across the plugin's pages? The cached rows answer it
        // offline, and they are the same rows the read path already pairs with
        // live values. So instead of six page-rights, six reads and a walk
        // back, the surface steps once per page up to the match and stops.
        //
        // What is NOT skipped is the proof. `landOnCachedPage` matches the
        // exact cell whose encoder is about to move against the live LCD —
        // stricter than the per-page check the cached read path applies — and
        // the converge that follows reads its own result back. `locateParameter`
        // refuses to resolve an ambiguity, so anything it will not answer takes
        // the unchanged live walk below, where duplicates are counted against
        // live rows and reported as `parameterAmbiguous`.
        if let key = cacheKey, let cachedNames = loadNameCache(projectPath: projectPath)[key],
           cachedNames.count == max(totalPages, 1),
           let hit = locateParameter(parameter, in: cachedNames) {
            if let landed = try landOnCachedPage(hit, cachedRow: cachedNames[hit.page - 1]) {
                match = (hit.page, hit.index, hit.name)
                landedPage = landed
            } else {
                // Delete-on-mismatch, then start over honestly: the surface may
                // be on any page after a failed landing, so re-normalize before
                // the live walk assumes page 1.
                debugLog("param page cache contradicted by LCD for '\(key)'; walking live")
                dropNameCache(key: key, projectPath: projectPath)
                trustedKey = nil
                _ = try normalizeToPageOne()
            }
        }

        if match == nil {
            // This function does not merely REPORT cached names, it picks a
            // vpot index from them and turns it. Spot-check the cache against
            // the live LCD once, up front, before a single cached row is
            // trusted: page 1 read the slow way and compared in full, including
            // the two fields the per-page check inside pageForSearch can never
            // see. On disagreement the entry is dropped and the whole search
            // runs on live reads.
            var verifiedPageOne: [(name: String, value: String)]?
            // True while every page of this walk is being read the slow way —
            // which is exactly the condition for the walk to be worth caching.
            // Deliberately not `trustedKey == nil`: on a COLD plugin the key is
            // perfectly good, there is simply nothing stored under it yet, and
            // that is the case the cache population exists for.
            var walkedLive = true
            if let key = trustedKey, let cachedNames = loadNameCache(projectPath: projectPath)[key],
               cachedNames.count == max(totalPages, 1) {
                verifiedPageOne = verifiedFirstPage(cachedNames: cachedNames)
                if verifiedPageOne == nil {
                    debugLog("param name cache contradicted by LCD for '\(key)'; rescanning live")
                    dropNameCache(key: key, projectPath: projectPath)
                    trustedKey = nil
                } else {
                    walkedLive = false
                }
            }
            var found: (page: Int, index: Int, name: String, value: String)?
            var duplicates = 0
            var allNames: [String] = []
            // Every page this walk reads the slow way, kept for the cache. See
            // the save below: the write path gathers exactly what the read path
            // stores and used to throw it away.
            var livePages: [[(name: String, value: String)]] = []
            for pageNumber in 1...max(totalPages, 1) {
                // Page 1 was already read (and verified) above - reuse it rather
                // than paying the indicator fade a second time.
                let reusable = pageNumber == 1 ? verifiedPageOne : nil
                guard let raw = reusable ?? pageForSearch(
                    cacheKey: trustedKey, projectPath: projectPath,
                    pageNumber: pageNumber, totalPages: totalPages
                ) else { return nil }
                if walkedLive { livePages.append(raw) }
                for (index, entry) in raw.enumerated() where !entry.name.isEmpty {
                    allNames.append(entry.name)
                    let hit = entry.name.localizedCaseInsensitiveCompare(parameter) == .orderedSame
                        || lcdNameMatches(track: parameter, lcd: entry.name)
                    guard hit else { continue }
                    if let existing = found {
                        // The end-aligned last page repeats the previous page's tail;
                        // an identical name+value there is the same parameter.
                        if pageNumber == totalPages
                            && existing.name == entry.name && existing.value == entry.value {
                            continue
                        }
                        duplicates += 1
                    } else {
                        found = (pageNumber, index, entry.name, entry.value)
                    }
                }
                if pageNumber < totalPages { try pageRight() }
            }
            // The write path populates the name cache too. It just read every
            // page the slow way, waiting out the indicator fade on each — the
            // identical material `parameterPagesCapped` stores — and used to
            // discard it, so an agent that goes straight to a write (which the
            // schema allows, and which looks like the cheaper option) paid six
            // fades on every write for ever. Measured 2026-08-31: two
            // consecutive cold writes cost 16.6 s each and left
            // param-names-cache.json absent. Same key, same project+build
            // scope, same all-pages condition the read path uses.
            if let key = cacheKey, walkedLive,
               livePages.count == max(totalPages, 1),
               let rows = cacheableNameRows(livePages) {
                var cache = loadNameCache(projectPath: projectPath)
                cache[key] = rows
                saveNameCache(cache, projectPath: projectPath)
            }
            guard duplicates == 0, let hit = found else {
                throw LogicianError.parameterAmbiguous(
                    "\(parameter) (MCU parameters: \(allNames.joined(separator: ", ")))",
                    found == nil ? 0 : duplicates + 1
                )
            }
            // Navigate back to the match's page (we are on the last page now).
            //
            // Event-driven, exactly like the two other cursor-key walks in this
            // codebase: `normalizeToPageOne` presses the SAME note (0x62) in the
            // same kind of loop and waits on `awaitEvents`, and `pageRight` does
            // the mirror press (0x63) the same way. This loop was the odd one out
            // with a blind 250 ms sleep, and it is the only one of the three that
            // is paid PER PAGE on every parameter write. Measured 2026-08-31 on
            // Bas / Channel EQ (6 pages, match on page 1): the five sleeps cost
            // 1.27 s of the 5.96 s call, while the identical wait in
            // `normalizeToPageOne` returned in ~1 ms per press — Logic answers a
            // cursor press immediately. The read that follows is still settle-
            // gated (`pageForSearch` opens with `quiescentStatus`) and still
            // verified (the `landed[match.index].name == match.name` guard below
            // throws if the surface is not on the page we think it is), so
            // nothing here rests on the wait alone.
            for _ in 0..<(max(totalPages, 1) - hit.page) {
                let events = freshStatus()?["received_events"] as? Int ?? -1
                try pressNote(0x62)
                _ = awaitEvents(since: events, timeoutMs: 250)
            }
            guard let landed = pageForSearch(
                      cacheKey: trustedKey, projectPath: projectPath,
                      pageNumber: hit.page, totalPages: totalPages
                  ),
                  landed.indices.contains(hit.index),
                  landed[hit.index].name == hit.name else {
                throw LogicianError.openVerificationFailed(
                    "the parameter page shifted while navigating to '\(hit.name)'"
                )
            }
            match = (hit.page, hit.index, hit.name)
            landedPage = landed
        }

        guard let match, let landed = landedPage, landed.indices.contains(match.index) else {
            throw LogicianError.openVerificationFailed(
                "the parameter page shifted while navigating to '\(parameter)'"
            )
        }
        let index = match.index
        let entry = (name: match.name, value: landed[match.index].value)
        let originalText = entry.value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }

        func currentText() -> String? {
            parameterPage().map { $0[index].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: index, delta: ticks))
            guard response.ok else {
                throw LogicianError.writeFailed("MCU vpot failed: \(response.error ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }

        let finalText: String
        if let targetNumber = parseNumber(targetValue), parseNumber(originalText) != nil,
           let fast = fastConverge(index: index, target: targetNumber,
                                   tolerance: tolerance ?? 0, maxMs: 4000) {
            finalText = fast.text
        } else if let targetNumber = parseNumber(targetValue), parseNumber(originalText) != nil {
            finalText = try convergeNumeric(
                target: targetNumber,
                tolerance: tolerance,
                read: { currentText().flatMap(parseNumber) },
                readText: { currentText() },
                turn: turn
            )
        } else {
            finalText = try stepToText(
                target: targetValue,
                original: originalText,
                read: { currentText() },
                turn: turn
            )
        }

        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "parameter_field": entry.name,
            "before": originalText,
            "requested": targetValue,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

    static func convergeNumeric(
        target: Double,
        tolerance: Double?,
        read: () -> Double?,
        readText: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        guard var current = read() else {
            throw LogicianError.openVerificationFailed("the parameter value is not readable on the LCD")
        }
        let original = current
        // Probe with a single tick to learn the parameter's step size.
        var ticksPerUnit = 10.0
        var probed = false
        var effectiveTolerance = tolerance ?? 0.05
        var stuck = 0
        for _ in 0..<36 {
            let difference = target - current
            if abs(difference) <= effectiveTolerance { break }
            let ticks: Int
            if probed {
                ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            } else {
                ticks = 1
            }
            try turn(difference > 0 ? ticks : -ticks)
            guard let updated = read() else { break }
            let moved = abs(updated - current)
            if moved < 1e-9 {
                stuck += 1
                if stuck >= 3 {
                    _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
                    throw LogicianError.verificationFailed(
                        requested: "\(target)",
                        actual: "parameter stuck at \(updated)",
                        restored: true
                    )
                }
            } else {
                stuck = 0
                ticksPerUnit = min(400, max(0.2, Double(ticks) / moved))
                if !probed {
                    probed = true
                    if tolerance == nil {
                        effectiveTolerance = max(moved * 0.55, 0.0001)
                    }
                }
            }
            current = updated
        }
        guard abs(current - target) <= effectiveTolerance * 2 else {
            _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
            throw LogicianError.verificationFailed(
                requested: "\(target)",
                actual: "\(current)",
                restored: true
            )
        }
        return readText() ?? "\(current)"
    }

    static func convergeBack(
        to original: Double,
        ticksPerUnit: Double,
        read: () -> Double?,
        turn: (Int) throws -> Void
    ) throws {
        for _ in 0..<24 {
            guard let current = read() else { return }
            let difference = original - current
            if abs(difference) < 0.0001 { return }
            let ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            try turn(difference > 0 ? ticks : -ticks)
        }
    }

    static func stepToText(
        target: String,
        original: String,
        read: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        func matches(_ text: String?) -> Bool {
            text?.localizedCaseInsensitiveCompare(target) == .orderedSame
        }
        if matches(original) { return original }
        var net = 0
        // Search upward, then downward past the start. Enum boundaries can be
        // wider than one vpot tick, so escalate the step size when the display
        // does not move, and treat sustained silence at max step as the end stop.
        for direction in [1, -1] {
            var previous = read()
            var unchanged = 0
            var step = 1
            let limit = direction == 1 ? 24 : 48
            for _ in 0..<limit {
                try turn(direction * step)
                net += direction * step
                let text = read()
                if matches(text) { return text ?? target }
                if text == previous {
                    unchanged += 1
                    if unchanged >= 3 && step >= 8 { break } // end stop
                    step = min(step * 2, 8)
                } else {
                    unchanged = 0
                    step = 1
                    previous = text
                }
            }
        }
        // No match: undo the net movement. `net` routinely exceeds one
        // message's 63-tick capacity here (up to 24 upward plus 48 downward
        // turns at a step size that escalates to 8), and the bridge clamps a
        // single oversized vpot message instead of splitting it - a plain
        // turn(-net) therefore dropped everything past the 63rd tick and left
        // the parameter moved while the error still claimed restored: true.
        // Chunk it, and REPORT WHAT THE LCD ACTUALLY SHOWS: `restored` is only
        // true when every chunk went out AND the readback is back at `original`.
        // An unreadable LCD counts as not restored - we cannot prove it.
        var undone = true
        if net != 0 {
            do {
                for chunk in vpotTickChunks(-net) { try turn(chunk) }
            } catch {
                undone = false
            }
        }
        let landed = read()
        throw LogicianError.verificationFailed(
            requested: target,
            actual: landed ?? "unknown",
            restored: undone && landed?.localizedCaseInsensitiveCompare(original) == .orderedSame
        )
    }
}
