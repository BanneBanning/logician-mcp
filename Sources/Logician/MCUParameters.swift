import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Parameter paging (cursor left/right, note 0x62/0x63)

    static func pressNote(_ note: Int) throws {
        let response = try MCUBridge.send(.press(note: note))
        guard response.ok else {
            throw DemoError.writeFailed("MCU note press failed: \(response.error ?? "?")")
        }
    }

    /// Reads the transient "Page x/y" indicator the LCD shows right after a
    /// cursor press. Returns nil when no indicator is visible.
    static func pageIndicator() -> (current: Int, total: Int)? {
        guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
        guard let range = top.range(of: #"Page +(\d+)/(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = top[range].split(separator: " ").last?.split(separator: "/") ?? []
        guard digits.count == 2, let current = Int(digits[0]), let total = Int(digits[1]) else {
            return nil
        }
        return (current, total)
    }

    /// Waits for the page indicator to fade so all 8 fields hold parameters.
    static func settledParameterPage() -> [(name: String, value: String)]? {
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            let events = status["received_events"] as? Int ?? -1
            if top.range(of: #"Page +\d+/\d+"#, options: .regularExpression) == nil {
                // quiescent = the indicator faded and Logic stopped redrawing
                if let after = awaitEvents(since: events, timeoutMs: 130),
                   after["timed_out"] as? Bool == true {
                    return parameterPage()
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 400)
        }
        return parameterPage()
    }

    /// Normalizes the edit view to page 1 and returns the page count, using a
    /// harmless cursor_left press to surface the "Page x/y" indicator
    /// (cursor_left on page 1 keeps the parameters unchanged; verified).
    static func normalizeToPageOne() throws -> Int {
        try pressNote(0x62)
        // The "Page x/y" indicator is drawn in a later sysex than the first
        // redraw event, so wait for it explicitly rather than for any event.
        _ = waitFor(seconds: 0.9) { status in
            (status["lcd_top"] as? String)?
                .range(of: #"Page +\d+/\d+"#, options: .regularExpression) != nil
        }
        guard let indicator = pageIndicator() else {
            return 1 // single-page plugins may show no indicator at all
        }
        for _ in 0..<(indicator.current - 1) {
            let events = freshStatus()?["received_events"] as? Int ?? -1
            try pressNote(0x62)
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return indicator.total
    }

    static func pageRight() throws {
        let before = freshStatus()?["received_events"] as? Int ?? -1
        try pressNote(0x63)
        _ = awaitEvents(since: before, timeoutMs: 250)
    }

    // MARK: Parameter name cache (names never change per plugin type; only
    // values do — and the LCD's bottom value row is complete immediately,
    // while top-row names hide behind the ~1.3 s "Page x/y" indicator fade).
    //
    // That premise holds only for a FIXED plugin type at a FIXED version: a
    // plugin update that inserts or reorders a parameter keeps the name rows
    // decodable while making them describe the wrong values, and the cache is
    // keyed by a 6-character LCD abbreviation that cannot tell the versions
    // apart. So the file is scoped (build + project) and, before any cached
    // row is paired with a live value, one page is verified against the LCD.

    static var nameCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("param-names-cache.json")
    }

    /// Cached name rows, but only the ones measured by THIS build in THIS
    /// project. The key is Logic's 6-character LCD abbreviation of the slot
    /// name ("Channe"), which is far too lossy to be unique on its own; the
    /// project stamp stops two plugins that abbreviate alike - or the same
    /// plugin at a different version in another song - from inheriting each
    /// other's parameter names. Empty when the scope cannot be established.
    static func loadNameCache(projectPath: String?) -> [String: [[String]]] {
        loadScopedCache(nameCacheURL, projectPath: projectPath, as: [String: [[String]]].self) ?? [:]
    }

    static func saveNameCache(_ cache: [String: [[String]]], projectPath: String?) {
        saveScopedCache(cache, to: nameCacheURL, projectPath: projectPath)
    }

    /// Forgets one plugin's cached rows after the live LCD contradicted them.
    /// The same delete-on-mismatch self-heal the bank cache uses: a map that
    /// lied once must not be consulted again.
    static func dropNameCache(key: String, projectPath: String?) {
        var cache = loadNameCache(projectPath: projectPath)
        guard cache.removeValue(forKey: key) != nil else { return }
        saveNameCache(cache, projectPath: projectPath)
    }

    /// Whether a settled (indicator-faded) live name row still matches the row
    /// the cache holds for that page. Exact and all eight fields: the fast read
    /// pairs cached NAMES with live VALUES positionally, so a single parameter
    /// inserted by a plugin update shifts every pair after it and the result is
    /// not "slightly off", it is confidently wrong. A row still carrying the
    /// "Page x/y" indicator was never fully repainted and proves nothing, so it
    /// is not accepted as agreement either.
    static func cachedNameRowMatches(cached: [String], live: [String]) -> Bool {
        guard cached.count == 8, live.count == 8 else { return false }
        if live.contains(where: {
            $0.range(of: #"Page +\d+"#, options: .regularExpression) != nil
        }) { return false }
        return cached == live
    }

    /// One fade-waited read of page 1, compared against the cache before any
    /// cheap cached read is trusted - fields 6-7 sit behind the "Page x/y"
    /// indicator, so the per-page check in the fast walk can never see them.
    /// Returns the settled page so the ~1.7 s fade is paid ONCE per operation
    /// and its content reused as page 1 instead of thrown away; nil means the
    /// cache disagreed (caller drops it and takes the slow path).
    static func verifiedFirstPage(cachedNames: [[String]]) -> [(name: String, value: String)]? {
        guard let cachedFirst = cachedNames.first,
              let live = settledParameterPage(),
              cachedNameRowMatches(cached: cachedFirst, live: live.map(\.name)) else { return nil }
        return live
    }

    /// Raw 8-field pages read the slow way: waits out the indicator fade so
    /// every name field is visible. Positions and empty fields preserved.
    static func rawParameterPagesSlow() throws -> [[(name: String, value: String)]]? {
        let total = try normalizeToPageOne()
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...max(total, 1) {
            guard let page = settledParameterPage() else { return nil }
            pages.append(page)
            if pageNumber < max(total, 1) {
                try pageRight()
            }
        }
        return pages
    }

    /// Cold read capped at maxPages: each page costs ~1.7 s (Logic's own
    /// "Page x/y" indicator fade), so an 80-page instrument like Augmented
    /// takes minutes uncapped — and floods the caller with hundreds of
    /// parameters it rarely needs at once. Returns the total page count so
    /// truncation is always explicit. Full (uncapped) reads still populate
    /// the name cache; capped reads do not, so later full reads stay honest.
    static func parameterPagesCapped(
        cacheKey: String?, maxPages: Int
    ) throws -> (pages: [[(name: String, value: String)]], total: Int, truncated: Bool)? {
        // Resolve the project once: the read below and the write further down
        // must agree on which project's cache they are touching.
        let projectPath = currentProjectPath()
        // A complete cached name set makes even the full read cheap — use it.
        if let key = cacheKey, let cachedNames = loadNameCache(projectPath: projectPath)[key] {
            // max(,1) mirrors the slow path below: an agent-supplied max_pages
            // of 0 must not turn into an empty walk (or a 1...0 range).
            let walk = min(max(maxPages, 1), cachedNames.count)
            if let fast = (try? rawParameterPagesFast(cachedNames: cachedNames, limit: walk)) ?? nil {
                // End-overlap dedup only applies when the true last page was read.
                let pages = walk == cachedNames.count
                    ? dedupedPages(fast)
                    : fast.map { page in page.filter { !$0.name.isEmpty } }
                return (pages, cachedNames.count, walk < cachedNames.count)
            }
            // The live LCD contradicted the cached names (or the page count
            // moved): forget the entry before falling through. A capped slow
            // read does not rewrite the cache, so without this the same lie
            // would be told again on the next call.
            dropNameCache(key: key, projectPath: projectPath)
        }
        let total = try normalizeToPageOne()
        let limit = min(max(total, 1), max(maxPages, 1))
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...limit {
            guard let page = settledParameterPage() else { return nil }
            pages.append(page)
            if pageNumber < limit {
                try pageRight()
            }
        }
        if limit >= max(total, 1), let key = cacheKey {
            var cache = loadNameCache(projectPath: projectPath)
            cache[key] = pages.map { $0.map(\.name) }
            saveNameCache(cache, projectPath: projectPath)
        }
        return (dedupedPages(pages), max(total, 1), limit < max(total, 1))
    }

    /// Raw pages using cached name rows: waits only for the redraw burst per
    /// page, never the indicator fade. Validates the always-visible fields 0-5
    /// against the cache; nil on any mismatch (caller takes the slow path).
    /// Page 1 is verified in full first (one fade, reused as page 1's data),
    /// because fields 6-7 are invisible to the per-page check.
    static func rawParameterPagesFast(
        cachedNames: [[String]], limit: Int? = nil
    ) throws -> [[(name: String, value: String)]]? {
        let total = try normalizeToPageOne()
        guard max(total, 1) == cachedNames.count else { return nil }
        let walkCount = min(limit ?? cachedNames.count, cachedNames.count)
        guard walkCount >= 1 else { return nil } // never index 1...0
        // Spot-check before ANY cached name is trusted: read page 1 the slow
        // way and compare the whole row. The per-page check below only sees
        // fields 0-5 (6-7 hide behind the "Page x/y" indicator), so a plugin
        // update that inserted a parameter into a page's tail would slip past
        // it and pair cached names with values belonging to something else.
        // The verified page is kept as page 1's data, so this costs one fade
        // for the whole walk rather than one per page.
        guard let firstPage = verifiedFirstPage(cachedNames: cachedNames) else { return nil }
        var pages: [[(name: String, value: String)]] = [firstPage]
        if walkCount > 1 {
            try pageRight()
            for pageNumber in 2...walkCount {
                _ = quiescentStatus() // burst settle only
                guard let status = freshStatus(),
                      let top = status["lcd_top"] as? String,
                      let bottom = status["lcd_bottom"] as? String else { return nil }
                let liveNames = lcdFields(top)
                let values = lcdFields(bottom)
                let names = cachedNames[pageNumber - 1]
                guard names.count == 8 else { return nil }
                for index in 0..<6
                where liveNames[index] != names[index]
                    && liveNames[index].range(of: #"Page +\d+"#, options: .regularExpression) == nil {
                    return nil // layout changed; rescan slowly
                }
                pages.append(zip(names, values).map { ($0, $1) })
                if pageNumber < walkCount {
                    try pageRight()
                }
            }
        }
        return pages
    }

    /// Empty-field filtering plus end-aligned last-page overlap dedup.
    static func dedupedPages(_ raw: [[(name: String, value: String)]]) -> [[(name: String, value: String)]] {
        var pages: [[(name: String, value: String)]] = []
        for (index, page) in raw.enumerated() {
            var entries = page.filter { !$0.name.isEmpty }
            if index == raw.count - 1, raw.count > 1, let previous = pages.last {
                let maxOverlap = min(entries.count, previous.count)
                for candidate in stride(from: maxOverlap, through: 1, by: -1) {
                    if previous.suffix(candidate).elementsEqual(
                        entries.prefix(candidate),
                        by: { $0.name == $1.name && $0.value == $1.value }
                    ) {
                        entries.removeFirst(candidate)
                        break
                    }
                }
            }
            pages.append(entries)
        }
        return pages
    }

    /// All parameter pages, preferring the per-plugin name cache (fast, no
    /// fade waits); the slow path populates the cache for next time.
    static func parameterPages(cacheKey: String? = nil) throws -> [[(name: String, value: String)]]? {
        if let key = cacheKey {
            let projectPath = currentProjectPath()
            var cache = loadNameCache(projectPath: projectPath)
            if let cachedNames = cache[key] {
                if let pages = (try? rawParameterPagesFast(cachedNames: cachedNames)) ?? nil {
                    return dedupedPages(pages)
                }
                // Drop the contradicted entry BEFORE the rescan, so a rescan
                // that fails cannot leave the lying map in place.
                cache.removeValue(forKey: key)
                saveNameCache(cache, projectPath: projectPath)
            }
            guard let slow = try rawParameterPagesSlow() else { return nil }
            cache[key] = slow.map { $0.map(\.name) }
            saveNameCache(cache, projectPath: projectPath)
            return dedupedPages(slow)
        }
        guard let slow = try rawParameterPagesSlow() else { return nil }
        return dedupedPages(slow)
    }

    static func parseNumber(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        let numeric = normalized.prefix { "+-0123456789.".contains($0) }
        guard !numeric.isEmpty, numeric != "-", numeric != "+" else { return nil }
        return Double(numeric.hasSuffix(".") ? String(numeric.dropLast()) : String(numeric))
    }

    /// Sets one plugin parameter on the selected track by converging a vpot
    /// against the LCD value echo. Handles numeric values adaptively and
    /// steps text/enum values until exact match. The track must already be
    /// selected and the caller provides the MCU (physical) insert slot.
    static func setPluginParameter(
        slot: Int,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        trackName: String? = nil
    ) throws -> [String: Any]? {
        // Bounds-check BEFORE any lcdFields()[slot-1] indexing below — an
        // out-of-range slot (e.g. an AX ordinal like 9, or an off-by-one to
        // 0) would otherwise crash the whole server instead of erroring.
        guard (1...8).contains(slot) else {
            throw DemoError.invalidArguments(
                "insert_slot must be 1-8 (MCU physical slot); got \(slot)"
            )
        }
        guard freshStatus() != nil else { return nil }
        var slotName: String?
        let isHot = trackName != nil && hotPluginView?.track == trackName
            && hotPluginView?.slot == slot
            && (freshStatus()?["assignment"] as? String) == "P\(slot)"
        if isHot {
            slotName = hotPluginView?.cacheKey
        } else {
            guard let listStatus = try ensurePluginList() else { return nil }
            slotName = (listStatus["lcd_bottom"] as? String).map {
                lcdFields($0)[slot - 1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            }
            guard try enterPluginEdit(slot: slot) else {
                exitToPan()
                hotPluginView = nil
                return nil
            }
        }
        // The view is deliberately LEFT in plugin-edit mode afterwards:
        // consecutive writes on the same track+slot then skip all setup, and
        // any other operation re-establishes its own view anyway.
        if let trackName {
            hotPluginView = (trackName, slot,
                             slotName.flatMap { $0.isEmpty || $0 == "--" ? nil : $0 })
        }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: slotName.flatMap { $0.isEmpty || $0 == "--" ? nil : $0 }
        ) else {
            hotPluginView = nil
            exitToPan()
            return nil
        }
        result["insert_slot"] = slot
        return result
    }

}
