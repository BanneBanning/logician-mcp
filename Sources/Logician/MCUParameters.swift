import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Parameter paging (cursor left/right, note 0x62/0x63)

    static func pressNote(_ note: Int) throws {
        let response = try MCUBridge.send(.press(note: note))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU note press failed: \(response.error ?? "?")")
        }
    }

    /// Reads the transient "Page x/y" indicator the LCD shows right after a
    /// cursor press. Returns nil when no indicator is visible.
    static func pageIndicator() -> (current: Int, total: Int)? {
        guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
        guard let range = top.range(
            of: MCULCDStrings.pageIndicatorPattern, options: .regularExpression
        ) else {
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
            if top.range(of: MCULCDStrings.pageIndicatorPresentPattern, options: .regularExpression) == nil {
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
                .range(of: MCULCDStrings.pageIndicatorPresentPattern, options: .regularExpression) != nil
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
            $0.range(of: MCULCDStrings.pageIndicatorCellPattern, options: .regularExpression) != nil
        }) { return false }
        return cached == live
    }

    /// Where a parameter sits in a plugin's cached name rows: its page (1-based)
    /// and the vpot index on that page.
    struct CachedParameterLocation: Equatable {
        let page: Int
        let index: Int
        let name: String
    }

    /// How many of the LAST page's entries are a repeat of the previous page's
    /// tail. Logic END-ALIGNS the last parameter page, so a plugin whose count
    /// is not a multiple of 8 shows its final parameters twice; `dedupedPages`
    /// strips the repeat from what callers see, and the live search skips it by
    /// comparing name AND value.
    ///
    /// Offline there are no values to compare, so the repeat is identified the
    /// only other way it can be: as the longest run of names shared by the end
    /// of one row and the start of the next. Anything outside that run is
    /// treated as a genuine second parameter, which is the conservative reading
    /// — it sends the caller back to the live walk instead of quietly picking
    /// one of two candidates.
    static func lastPageOverlap(_ cachedNames: [[String]]) -> Int {
        guard cachedNames.count > 1, let last = cachedNames.last else { return 0 }
        let previous = cachedNames[cachedNames.count - 2].filter { !$0.isEmpty }
        let tail = last.filter { !$0.isEmpty }
        for candidate in stride(from: min(previous.count, tail.count), through: 1, by: -1)
        where Array(previous.suffix(candidate)) == Array(tail.prefix(candidate)) {
            return candidate
        }
        return 0
    }

    /// The page and vpot index a parameter name resolves to in CACHED rows —
    /// the whole page walk, answered offline.
    ///
    /// `searchAndSetParameter` used to walk every page forward to prove the
    /// name unambiguous and then walk back; for a parameter on page 1 of a
    /// six-page EQ that is ~1.4 s of paging to reach something already on
    /// screen. The cached rows answer the same question with no surface
    /// traffic at all — they are the same rows the read path already pairs
    /// with live values.
    ///
    /// Deliberately all-or-nothing: nil means "zero matches, or more than one,
    /// or rows this function will not reason about", and the caller answers nil
    /// with the unchanged live walk. It never resolves an ambiguity, and the
    /// page it names is still proved against the live LCD before a vpot moves
    /// (`landOnCachedPage`). Pure, so the rule is tested without a surface.
    static func locateParameter(_ parameter: String, in cachedNames: [[String]]) -> CachedParameterLocation? {
        guard !cachedNames.isEmpty else { return nil }
        let overlap = lastPageOverlap(cachedNames)
        var found: CachedParameterLocation?
        var matches = 0
        for (pageIndex, row) in cachedNames.enumerated() {
            guard row.count == 8 else { return nil }
            var seen = 0
            for (index, name) in row.enumerated() where !name.isEmpty {
                seen += 1
                // The end-aligned repeat is the same parameter shown again, not
                // a second one; it was already counted on the previous page.
                if pageIndex == cachedNames.count - 1, cachedNames.count > 1, seen <= overlap {
                    continue
                }
                let hit = name.localizedCaseInsensitiveCompare(parameter) == .orderedSame
                    || lcdNameMatches(track: parameter, lcd: name)
                guard hit else { continue }
                matches += 1
                if found == nil {
                    found = CachedParameterLocation(page: pageIndex + 1, index: index, name: name)
                }
            }
        }
        return matches == 1 ? found : nil
    }

    /// Steps from page 1 to a cached location's page and proves, against the
    /// live LCD, that the vpot about to be turned carries the name the cache
    /// promised. Returns that page's entries (cached names, live values), or
    /// nil when the LCD disagrees — which the caller answers by dropping the
    /// cache entry and walking the pages for real.
    ///
    /// The proof is tried cheap first and settled second, because the LCD only
    /// shows half the row straight away. Fields 0-5 are repainted immediately,
    /// so a 150 ms quiescence read confirms them; fields 6-7 hide behind the
    /// transient "Page x/y" indicator until it fades (~2.1 s measured), so an
    /// index up there goes straight to the settled read. Either way the cell
    /// whose encoder is about to move is matched EXACTLY, with no indicator
    /// exemption — stricter than the per-page check the cached read path uses,
    /// and it is the cell that matters.
    ///
    /// A cheap check that DISAGREES is not evidence that the cache is wrong.
    /// Measured 2026-08-31 on `Bas`'s Compressor: right after a write, Logic
    /// paints the touched parameter's FULL name across the top row — cells 1-2
    /// read `Thresho` / `ld` where the cache holds `Thrs` / `Ratio` — and it
    /// stays that way until the page indicator fades. So a disagreement pays
    /// the fade once and compares the whole row; only a settled row that STILL
    /// disagrees means the plugin moved under the cache. Before this, a second
    /// write on the same plugin dropped a perfectly good cache and re-walked
    /// every page: 9.2 s instead of 0.5 s, for a display artefact.
    static func landOnCachedPage(
        _ hit: CachedParameterLocation, cachedRow: [String]
    ) throws -> [(name: String, value: String)]? {
        guard cachedRow.count == 8, (0..<8).contains(hit.index) else { return nil }
        for _ in 0..<(hit.page - 1) { try pageRight() }
        if hit.index < 6, let fast = fastLandingCheck(hit, cachedRow: cachedRow) {
            return fast
        }
        guard let settled = settledParameterPage(),
              cachedNameRowMatches(cached: cachedRow, live: settled.map(\.name)) else {
            debugLog("landOnCachedPage: settled row disagrees with the cache for page \(hit.page)")
            return nil
        }
        return settled
    }

    /// The 150 ms half of `landOnCachedPage`: cached names paired with live
    /// values, or nil when the always-visible fields do not back them up.
    private static func fastLandingCheck(
        _ hit: CachedParameterLocation, cachedRow: [String]
    ) -> [(name: String, value: String)]? {
        _ = quiescentStatus()
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return nil }
        let live = lcdFields(top)
        guard live.count == 8, live[hit.index] == cachedRow[hit.index] else { return nil }
        for index in 0..<6 where live[index] != cachedRow[index] {
            guard live[index].range(
                of: MCULCDStrings.pageIndicatorCellPattern, options: .regularExpression
            ) != nil else { return nil }
        }
        return zip(cachedRow, lcdValueFields(bottom)).map { ($0, $1) }
    }

    /// The name rows a walk is allowed to write to the cache, or nil when it is
    /// not allowed to write at all.
    ///
    /// Every row must be a full eight fields and free of the "Page x/y"
    /// indicator. A row read while the indicator was still up was never fully
    /// repainted — `settledParameterPage` gives up after 3.5 s and returns
    /// whatever is on the LCD — and caching one would teach every later read a
    /// layout Logic never actually showed.
    static func cacheableNameRows(_ pages: [[(name: String, value: String)]]) -> [[String]]? {
        guard !pages.isEmpty else { return nil }
        var rows: [[String]] = []
        for page in pages {
            guard page.count == 8 else { return nil }
            let names = page.map(\.name)
            if names.contains(where: {
                $0.range(of: MCULCDStrings.pageIndicatorCellPattern, options: .regularExpression) != nil
            }) { return nil }
            rows.append(names)
        }
        return rows
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
        if limit >= max(total, 1), let key = cacheKey, let rows = cacheableNameRows(pages) {
            var cache = loadNameCache(projectPath: projectPath)
            cache[key] = rows
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
                let values = lcdValueFields(bottom)
                let names = cachedNames[pageNumber - 1]
                guard names.count == 8 else { return nil }
                for index in 0..<6
                where liveNames[index] != names[index]
                    && liveNames[index].range(
                        of: MCULCDStrings.pageIndicatorCellPattern,
                        options: .regularExpression
                    ) == nil {
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

    /// Which insert slot a `plugin_name` names, decided against the eight LCD
    /// cells of the insert-list view.
    ///
    /// Logic paints each insert as a 6-character abbreviation (`Cha EQ`,
    /// `*PitchS` for a bypassed one), so the match is the same abbreviation-
    /// tolerant comparison every other name lookup on this plane uses: an exact
    /// case-insensitive hit, or `lcdNameMatches` recovering "Channel EQ" from
    /// "Cha EQ". Pure and static so the resolution rule can be tested without a
    /// surface.
    ///
    /// Returns every match, in slot order. Zero and two are both answers the
    /// caller has to report rather than resolve — a name that fits two inserts
    /// is exactly the case where guessing writes to the wrong plugin.
    static func insertSlotsMatching(pluginName: String, cells: [String]) -> [Int] {
        cells.enumerated().compactMap { index, raw in
            let cell = raw.trimmingCharacters(
                in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
            ).trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty, cell != MCULCDStrings.emptySlot else { return nil }
            let hit = cell.localizedCaseInsensitiveCompare(pluginName) == .orderedSame
                || lcdNameMatches(track: pluginName, lcd: cell)
            return hit ? index + 1 : nil
        }
    }

    /// Sets one plugin parameter on the selected track by converging a vpot
    /// against the LCD value echo. Handles numeric values adaptively and
    /// steps text/enum values until exact match. The track must already be
    /// selected.
    ///
    /// The plugin is addressed by `slot` (the MCU physical insert slot) OR by
    /// `pluginName`, and naming it is the cheaper of the two for a caller: the
    /// slot is resolved from the insert-list read this write already performs,
    /// so it costs nothing on the wire and saves the agent a whole
    /// `logic_list_inserts` round trip. When the surface is already hot on a
    /// plugin whose name matches, even that read is skipped.
    static func setPluginParameter(
        slot: Int?,
        pluginName: String? = nil,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        trackName: String? = nil
    ) throws -> [String: Any]? {
        // Bounds-check BEFORE any lcdFields()[slot-1] indexing below — an
        // out-of-range slot (e.g. an AX ordinal like 9, or an off-by-one to
        // 0) would otherwise crash the whole server instead of erroring.
        if let slot, !(1...8).contains(slot) {
            throw LogicianError.invalidArguments(
                "insert_slot must be 1-8 (MCU physical slot); got \(slot)"
            )
        }
        guard slot != nil || pluginName != nil else {
            throw LogicianError.invalidArguments(
                "give insert_slot or plugin_name to name the plugin on the control-surface route"
            )
        }
        guard freshStatus() != nil else { return nil }
        var slotName: String?
        var resolvedSlot = slot
        var resolvedBy: String?

        /// The hot view IS the (strip, slot) -> plugin-name cache this route
        /// needs, held in memory and re-proved against the live assignment
        /// code on every use. A caller who named the plugin the surface is
        /// already showing therefore pays nothing at all to be pointed at it.
        func hotMatchesRequest() -> Bool {
            guard let trackName, let hot = hotPluginView, hot.track == trackName else { return false }
            if let slot { return hot.slot == slot }
            guard let pluginName, let key = hot.cacheKey else { return false }
            return !insertSlotsMatching(pluginName: pluginName, cells: [key]).isEmpty
        }
        let isHot = hotMatchesRequest()
            && (freshStatus()?["assignment"] as? String)
                == MCULCDStrings.Assignment.insertSlot(hotPluginView?.slot ?? -1)
        if isHot, let hot = hotPluginView {
            slotName = hot.cacheKey
            resolvedSlot = hot.slot
            if slot == nil { resolvedBy = "hot_view" }
        } else {
            guard let listStatus = try ensurePluginList() else { return nil }
            let cells = (listStatus["lcd_bottom"] as? String).map { lcdFields($0) } ?? []
            if resolvedSlot == nil, let pluginName {
                let matches = insertSlotsMatching(pluginName: pluginName, cells: cells)
                guard let only = matches.first, matches.count == 1 else {
                    // Both answers are reported, never resolved by picking one:
                    // the insert list is right there in the message, so the
                    // agent's retry is informed rather than a second guess.
                    let available = cells
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && $0 != MCULCDStrings.emptySlot }
                    throw matches.isEmpty
                        ? LogicianError.insertNotFound(
                            track: trackName ?? "the selected strip",
                            plugin: pluginName, available: available)
                        : LogicianError.insertAmbiguous(
                            track: trackName ?? "the selected strip",
                            plugin: pluginName, slots: matches, parameter: "insert_slot")
                }
                resolvedSlot = only
                resolvedBy = "insert_list"
            }
            guard let target = resolvedSlot else { return nil }
            slotName = cells.indices.contains(target - 1)
                ? cells[target - 1].trimmingCharacters(
                    in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker))
                : nil
            guard try enterPluginEdit(slot: target) else {
                exitToPan()
                return nil
            }
        }
        guard let finalSlot = resolvedSlot else { return nil }
        // The view is deliberately LEFT in plugin-edit mode afterwards:
        // consecutive writes on the same track+slot then skip all setup, and
        // the debt is settled by the first operation that needs the names row
        // (or at shutdown) rather than by this call.
        if let trackName {
            hotPluginView = (trackName, finalSlot,
                             slotName.flatMap { $0.isEmpty || $0 == MCULCDStrings.emptySlot ? nil : $0 })
            deferSurfaceRestore(SurfaceDebt(strip: trackName, view: "plugin_edit", slot: finalSlot))
        }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: slotName.flatMap { $0.isEmpty || $0 == MCULCDStrings.emptySlot ? nil : $0 }
        ) else {
            hotPluginView = nil
            exitToPan()
            return nil
        }
        result["insert_slot"] = finalSlot
        if let resolvedBy {
            result["resolved_slot"] = finalSlot
            result["resolved_slot_from"] = resolvedBy
            if let slotName, !slotName.isEmpty {
                result["resolved_plugin"] = slotName
            }
        }
        return result
    }

}
