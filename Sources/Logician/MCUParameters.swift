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
        return pageIndicator(in: top)
    }

    /// The same read, from a row already in hand. Pure, so what the indicator
    /// is allowed to prove can be tested without a surface.
    static func pageIndicator(in top: String) -> (current: Int, total: Int)? {
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

    /// Is this LCD cell (part of) the transient "Page x/y" indicator rather
    /// than a parameter name?
    static func isPageIndicatorCell(_ cell: String) -> Bool {
        cell.range(of: MCULCDStrings.pageIndicatorCellPattern, options: .regularExpression) != nil
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

    /// Where the edit view actually IS, using a harmless cursor_left press to
    /// surface the "Page x/y" indicator (cursor_left on page 1 keeps the
    /// parameters unchanged; verified). The press itself is a page step, so
    /// what comes back is the position AFTER it.
    ///
    /// Logic remembers the page a plugin was last left on, so this is the
    /// difference between navigating and guessing: measured 2026-09-02, a
    /// call that follows a 9-page read starts on page 9 and used to walk 8
    /// cursor presses home (472 ms) before stepping back out again. Callers
    /// that need page 1 say so (`normalizeToPageOne`); callers that know
    /// which page they want step straight there (`walkToPage`).
    static func pageProbe() throws -> (current: Int, total: Int) {
        try pressNote(0x62)
        // The "Page x/y" indicator is drawn in a later sysex than the first
        // redraw event, so wait for it explicitly rather than for any event.
        _ = waitFor(seconds: 0.9) { status in
            (status["lcd_top"] as? String)?
                .range(of: MCULCDStrings.pageIndicatorPresentPattern, options: .regularExpression) != nil
        }
        guard let indicator = pageIndicator() else {
            return (1, 1) // single-page plugins may show no indicator at all
        }
        return indicator
    }

    /// How many cursor presses, and in which direction, get from one page to
    /// another. Pure. No wrap: whether cursor-right rolls over from the last
    /// page to the first is UNMEASURED, and a wrong guess would land the
    /// write on a page the caller never named — the landing proof would catch
    /// it, at the price of the 2.1 s fade it exists to avoid.
    static func pageStepPlan(from current: Int, to page: Int) -> (steps: Int, forward: Bool) {
        (steps: abs(page - current), forward: page > current)
    }

    /// Steps the cursor from `current` to `page`, event-driven per press.
    static func walkToPage(_ page: Int, from current: Int) throws {
        let plan = pageStepPlan(from: current, to: page)
        for _ in 0..<plan.steps {
            let events = freshStatus()?["received_events"] as? Int ?? -1
            try pressNote(plan.forward ? 0x63 : 0x62)
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
    }

    /// Normalizes the edit view to page 1 and returns the page count.
    static func normalizeToPageOne() throws -> Int {
        let position = try pageProbe()
        try walkToPage(1, from: position.current)
        return position.total
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
        _ hit: CachedParameterLocation, cachedRow: [String],
        from currentPage: Int = 1, totalPages: Int
    ) throws -> [(name: String, value: String)]? {
        guard cachedRow.count == 8, (0..<8).contains(hit.index) else { return nil }
        try walkToPage(hit.page, from: currentPage)
        if let fast = fastLandingCheck(hit, cachedRow: cachedRow, totalPages: totalPages) {
            return fast
        }
        guard let settled = settledParameterPage(),
              cachedNameRowMatches(cached: cachedRow, live: settled.map(\.name)) else {
            debugLog("landOnCachedPage: settled row disagrees with the cache for page \(hit.page)")
            return nil
        }
        return settled
    }

    /// Does the live top row prove the cached row well enough to turn the
    /// encoder at `hit.index`? Pure.
    ///
    /// Cells 1-6 are repainted immediately, so the ordinary proof is an exact
    /// match on the cell about to move plus agreement on every other cell
    /// that is readable at all.
    ///
    /// Cells 7-8 are where Logic draws the transient "Page x/y" indicator, so
    /// the cell about to move CANNOT be read there for ~2.1 s — and waiting
    /// for it was measured 2026-09-02 at 2 092 ms against 156 ms for cell 2,
    /// paid on every warm write to a quarter of an instrument's parameters.
    /// What stands in for the unreadable cell is the indicator itself: it
    /// states, in Logic's own paint, WHICH page of how many is showing. A row
    /// whose six readable cells match the cached page AND whose indicator
    /// names that same page out of the same total the cache holds IS that
    /// page — the identical witness `pageProbe` already trusts to navigate.
    /// Anything less (no indicator, a different page, a cell that differs for
    /// some other reason) still falls through to the full fade.
    static func cachedRowProvesCell(
        hit: CachedParameterLocation, cachedRow: [String], live: [String],
        indicator: (current: Int, total: Int)?, totalPages: Int
    ) -> Bool {
        guard cachedRow.count == 8, live.count == 8, (0..<8).contains(hit.index) else { return false }
        for index in 0..<6 where live[index] != cachedRow[index] {
            guard isPageIndicatorCell(live[index]) else { return false }
        }
        if live[hit.index] == cachedRow[hit.index] { return true }
        guard hit.index >= 6, isPageIndicatorCell(live[hit.index]), let indicator else { return false }
        return indicator.current == hit.page && indicator.total == totalPages
    }

    /// The 150 ms half of `landOnCachedPage`: cached names paired with live
    /// values, or nil when the live row does not back them up.
    private static func fastLandingCheck(
        _ hit: CachedParameterLocation, cachedRow: [String], totalPages: Int
    ) -> [(name: String, value: String)]? {
        _ = quiescentStatus()
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return nil }
        guard cachedRowProvesCell(
            hit: hit, cachedRow: cachedRow, live: lcdFields(top),
            indicator: pageIndicator(in: top), totalPages: totalPages
        ) else { return nil }
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

    // MARK: Partial (capped) cache entries
    //
    // A cache entry is an array of one row per page of the plugin, and a row
    // is either eight fields (this build has read that page) or empty (it has
    // not). The LENGTH is therefore always the plugin's true page count, which
    // is what every "does this entry still describe this plugin?" check
    // compares against, and the empty rows are what makes a capped read
    // cacheable at all.
    //
    // Before this, `parameterPagesCapped` wrote nothing when it hit the cap
    // (`limit >= max(total, 1)`), so an instrument with more pages than
    // `max_pages` had no warm case for ever: measured 2026-09-02, two
    // consecutive default reads of `Bas`/Trilian (64 pages, cap 12) cost
    // 30 973 ms and 30 744 ms and left the cache empty both times. The honesty
    // goal that gate protected — never pair page 13's values with names nobody
    // read — is kept by the empty rows themselves: `locateParameter` refuses
    // any entry with a row it cannot index, and the fast walk is only run over
    // the known prefix.

    /// How many leading pages of an entry are actually known.
    static func cachedNameRowPrefix(_ rows: [[String]]) -> Int {
        rows.prefix { $0.count == 8 }.count
    }

    /// Whether an entry holds every page of the plugin.
    static func cachedNameRowsComplete(_ rows: [[String]]) -> Bool {
        !rows.isEmpty && cachedNameRowPrefix(rows) == rows.count
    }

    /// The rows a walk read, padded out to the plugin's real page count so the
    /// entry says how much of the plugin it does NOT hold.
    static func paddedNameRows(_ rows: [[String]], total: Int) -> [[String]] {
        guard total > rows.count else { return rows }
        return rows + Array(repeating: [], count: total - rows.count)
    }

    /// What to store when a fresh walk meets an entry that is already there.
    /// Pure — this is the rule that lets a later, larger read COMPLETE a
    /// partial entry instead of replacing it, and stops a small capped read
    /// from throwing away pages a big one already paid for.
    ///
    /// A page-count change is not a merge but a different plugin (or a
    /// different version of one): the fresher walk wins outright.
    static func mergedNameRows(existing: [[String]]?, incoming: [[String]]) -> [[String]] {
        guard let existing, existing.count == incoming.count else { return incoming }
        return zip(existing, incoming).map { old, new in new.count == 8 ? new : old }
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

    /// Cold read capped at maxPages: each page costs ~2.1 s (Logic's own
    /// "Page x/y" indicator fade, measured at 2 137 ms over n=16 on
    /// 2026-09-02), so an 80-page instrument like Augmented takes minutes
    /// uncapped — and floods the caller with hundreds of parameters it rarely
    /// needs at once. Returns the total page count so truncation is always
    /// explicit, and caches the pages it actually read (see the partial-entry
    /// note above) so the SAME capped read is warm next time.
    static func parameterPagesCapped(
        cacheKey: String?, maxPages: Int
    ) throws -> (pages: [[(name: String, value: String)]], total: Int, truncated: Bool)? {
        // Resolve the project once: the read below and the write further down
        // must agree on which project's cache they are touching.
        let projectPath = currentProjectPath()
        // Cached name rows make the read cheap — use as many as we hold.
        if let key = cacheKey, let cachedNames = loadNameCache(projectPath: projectPath)[key] {
            // max(,1) mirrors the slow path below: an agent-supplied max_pages
            // of 0 must not turn into an empty walk (or a 1...0 range).
            let walk = min(max(maxPages, 1), cachedNames.count)
            if walk <= cachedNameRowPrefix(cachedNames) {
                if let fast = (try? rawParameterPagesFast(cachedNames: cachedNames, limit: walk)) ?? nil {
                    // End-overlap dedup only applies when the true last page was read.
                    let pages = walk == cachedNames.count
                        ? dedupedPages(fast)
                        : fast.map { page in page.filter { !$0.name.isEmpty } }
                    return (pages, cachedNames.count, walk < cachedNames.count)
                }
                // The live LCD contradicted the cached names (or the page count
                // moved): forget the entry before falling through, so the same
                // lie cannot be told again on the next call.
                dropNameCache(key: key, projectPath: projectPath)
            }
            // Otherwise the entry is honest, it just does not reach that far:
            // keep it, read the pages the slow way, and merge the two below.
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
        if let key = cacheKey, let rows = cacheableNameRows(pages) {
            var cache = loadNameCache(projectPath: projectPath)
            cache[key] = mergedNameRows(
                existing: cache[key], incoming: paddedNameRows(rows, total: max(total, 1))
            )
            saveNameCache(cache, projectPath: projectPath)
        }
        // End-overlap dedup only applies when the true last page was read —
        // the same rule the cached branch above follows. Logic end-aligns the
        // LAST page, so stripping a "repeat" from page 12 of 64 would delete
        // parameters that are really there.
        let visible = limit >= max(total, 1)
            ? dedupedPages(pages)
            : pages.map { page in page.filter { !$0.name.isEmpty } }
        return (visible, max(total, 1), limit < max(total, 1))
    }

    /// Whether a live top row is already showing the page whose cached names
    /// these are. The same comparison the walk performs three lines later —
    /// fields 0-5, with a cell the "Page x/y" indicator is sitting on counting
    /// as no evidence either way. Pure.
    static func cachedRowVisible(cached: [String], live: [String]) -> Bool {
        guard cached.count == 8, live.count == 8 else { return false }
        for index in 0..<6 where live[index] != cached[index] {
            guard isPageIndicatorCell(live[index]) else { return false }
        }
        return true
    }

    /// Waits for a page step to LAND, proved by what Logic painted rather than
    /// by a fixed silence.
    ///
    /// This was `_ = quiescentStatus()`, a 150 ms window that — measured
    /// 16/16 on 2026-09-02, 150.9-159.9 ms with zero variance — ALWAYS timed
    /// out: Logic had finished the repaint before the call, so the whole
    /// 151 ms was dead time, 29% of a warm page walk and rising linearly with
    /// the page count. What it stood in for is still needed, because cached
    /// NAMES are about to be paired with the LIVE value row and a row read one
    /// frame early pairs them with the previous page's values. So the wait is
    /// now positive: it returns as soon as the new page's own names are on the
    /// top row AND Logic has then been silent for `confirmMs` (the pairing
    /// proof — the value row cannot still be in flight through a gap that
    /// long), and otherwise spends the same 150 ms it always did, after which
    /// the caller's unchanged per-cell check rejects the row exactly as before.
    static func settleOnCachedRow(
        expecting names: [String], budgetMs: Int = 150, confirmMs: Int = 40
    ) {
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000)
        while true {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return }
            let events = status["received_events"] as? Int ?? -1
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            let window = min(confirmMs, max(1, Int(remaining * 1000)))
            if cachedRowVisible(cached: names, live: lcdFields(top)) {
                if awaitEvents(since: events, timeoutMs: window)?["timed_out"] as? Bool == true {
                    return
                }
            } else {
                _ = awaitEvents(since: events, timeoutMs: window)
            }
        }
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
                let names = cachedNames[pageNumber - 1]
                guard names.count == 8 else { return nil }
                settleOnCachedRow(expecting: names)
                guard let status = freshStatus(),
                      let top = status["lcd_top"] as? String,
                      let bottom = status["lcd_bottom"] as? String else { return nil }
                let liveNames = lcdFields(top)
                let values = lcdValueFields(bottom)
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

    /// What a plug-in name that matched MORE THAN ONE insert cell turns out
    /// to mean once the other plane has been asked about it.
    enum InsertNameResolution: Equatable {
        /// One cell is real and the rest were never inserts at all. `stale`
        /// names the cells Accessibility could not account for.
        case resolved(slot: Int, stale: [Int])
        /// Both planes hold the plug-in that many times. A genuine duplicate:
        /// only the caller can say which copy it meant.
        case duplicate(slots: [Int])
        /// The second plane could not settle it — it was unreadable, or it
        /// disagrees with the surface in a way this rule will not guess past.
        case unresolved(slots: [Int], reason: String)
    }

    /// Which of several same-named insert cells is the real one, decided by
    /// asking Accessibility what the strip actually holds.
    ///
    /// THE DEFECT THIS CLOSES, measured live 2026-09-03 on the demo project:
    /// `logic_set_plugin_parameter {Sub Phatty, "Channel EQ", "Peak 1 Gain"}`
    /// was refused in 1.3 s as ambiguous across two slots, and the same call
    /// minutes later succeeded in 557 ms against a strip that holds exactly
    /// ONE Channel EQ. The surface's insert row is repainted cell by cell and
    /// this server read it the instant the TOP row said "insert list", so a
    /// cell that had not yet repainted still carried the previous view's
    /// content — a second `Cha EQ`, or an instrument name, sitting in a slot
    /// that is really empty. The agent that met that refusal fell back to raw
    /// vpot presses and lost minutes to it, twice.
    ///
    /// The rule is a corroboration walk, deliberately NOT an order mapping:
    /// MCU slot order and Accessibility ordinals were observed REVERSED on an
    /// output strip (2026-08-27), so the only thing compared is the multiset
    /// of names. Each occupied cell, in slot order, consumes one unclaimed AX
    /// name it plausibly abbreviates; a cell that consumes none is not on the
    /// strip. The duplicate resolves only when the walk is COMPLETE — every AX
    /// insert claimed by some cell — and exactly one of the candidates was
    /// corroborated. Anything less refuses, because a wrong pick here writes a
    /// parameter into a plug-in nobody named.
    ///
    /// `axNames` is `insertPluginNames`' reading: the strip's inserts WITHOUT
    /// the instrument slot, which the surface's insert list never shows.
    static func resolveDuplicateInsertSlots(
        pluginName: String, cells: [String], axNames: [String]
    ) -> InsertNameResolution {
        let matches = insertSlotsMatching(pluginName: pluginName, cells: cells)
        guard !axNames.isEmpty else {
            return .unresolved(
                slots: matches,
                reason: "The Accessibility cross-check that tells a stale LCD cell from a real"
                    + " second copy could not run: no inspector is showing this strip's channel"
                    + " strip, so the surface's word is all there is."
            )
        }
        var unclaimed = axNames
        var corroborated: [Int] = []
        for (index, raw) in cells.enumerated() {
            let marker = MCULCDStrings.bypassMarker
            let bypassed = raw.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
            let cell = raw.trimmingCharacters(in: CharacterSet(charactersIn: marker + " "))
            guard !cell.isEmpty, cell != MCULCDStrings.emptySlot else { continue }
            let width = lcdNameCellWidth - (bypassed ? marker.count : 0)
            guard let claim = unclaimed.firstIndex(where: {
                lcdAbbreviationPlausible(track: $0, lcd: cell, cellWidth: width)
            }) else { continue }
            unclaimed.remove(at: claim)
            corroborated.append(index + 1)
        }
        guard unclaimed.isEmpty else {
            return .unresolved(
                slots: matches,
                reason: "The two planes do not describe the same strip: Accessibility reads"
                    + " [\(axNames.joined(separator: ", "))] and the surface's insert row"
                    + " accounts for none of \(unclaimed.count == 1 ? "one" : "\(unclaimed.count)")"
                    + " of them, so neither list can be trusted to pick a slot."
            )
        }
        let confirmed = matches.filter(corroborated.contains)
        if confirmed.count > 1 { return .duplicate(slots: confirmed) }
        guard let only = confirmed.first else {
            return .unresolved(
                slots: matches,
                reason: "Accessibility reads [\(axNames.joined(separator: ", "))] on this strip"
                    + " and none of those slots is '\(pluginName)', so every cell that matched"
                    + " it is a stale LCD paint."
            )
        }
        return .resolved(slot: only, stale: matches.filter { $0 != only })
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
    ///
    /// `axInsertNames` is the second plane, asked ONLY when the first one gave
    /// a name two slots (see `resolveDuplicateInsertSlots`). A closure rather
    /// than a list because the inspector walk behind it costs ~1 s and the
    /// happy path must not pay it: on every call that resolves cleanly it is
    /// never invoked.
    static func setPluginParameter(
        slot: Int?,
        pluginName: String? = nil,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        trackName: String? = nil,
        axInsertNames: () -> [String] = { [] }
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
        /// Slots whose cell named the plug-in and which Accessibility says
        /// hold nothing of the sort. Reported, never silently dropped: it is
        /// the evidence that the surface's row was lying.
        var staleInsertCells: [Int] = []

        /// The hot view IS the (strip, slot) -> plugin-name cache this route
        /// needs, held in memory and re-proved against the live LCD on every
        /// use. A caller who named the plugin the surface is already showing
        /// therefore pays nothing at all to be pointed at it.
        func hotMatchesRequest(_ hot: HotEditView) -> Bool {
            guard let trackName, hot.track == trackName,
                  case .insert(let hotSlot) = hot.slot else { return false }
            if let slot { return hotSlot == slot }
            guard let pluginName, let key = hot.cacheKey else { return false }
            return !insertSlotsMatching(pluginName: pluginName, cells: [key]).isEmpty
        }
        if let hot = hotEditView, hotMatchesRequest(hot), hotViewStanding(hot),
           case .insert(let hotSlot) = hot.slot {
            slotName = hot.cacheKey
            resolvedSlot = hotSlot
            if slot == nil { resolvedBy = "hot_view" }
        } else {
            guard let listStatus = try ensurePluginList() else { return nil }
            var cells = (listStatus["lcd_bottom"] as? String).map { lcdFields($0) } ?? []
            if resolvedSlot == nil, let pluginName {
                var matches = insertSlotsMatching(pluginName: pluginName, cells: cells)
                resolvedBy = "insert_list"
                // A row that answers with exactly one slot costs nothing more:
                // the two recoveries below run only when the first read came
                // back with none or with two, which is precisely when the row
                // is most likely to be a half-repainted frame rather than the
                // strip (see `settledInsertCells`).
                if matches.count != 1, let settled = settledInsertCells(previous: cells),
                   settled != cells {
                    cells = settled
                    matches = insertSlotsMatching(pluginName: pluginName, cells: cells)
                    resolvedBy = "insert_list_settled"
                }
                if matches.count > 1 {
                    switch resolveDuplicateInsertSlots(
                        pluginName: pluginName, cells: cells, axNames: axInsertNames()
                    ) {
                    case .resolved(let only, let stale):
                        matches = [only]
                        resolvedBy = "insert_list_cross_checked"
                        staleInsertCells = stale
                    case .duplicate(let slots):
                        throw LogicianError.insertAmbiguous(
                            track: trackName ?? "the selected strip", plugin: pluginName,
                            slots: slots, parameter: "insert_slot",
                            detail: "Accessibility reads the same strip and finds the plug-in"
                                + " there \(slots.count) times too, so this is a real duplicate"
                                + " and not a stale LCD cell.")
                    case .unresolved(let slots, let reason):
                        throw LogicianError.insertAmbiguous(
                            track: trackName ?? "the selected strip", plugin: pluginName,
                            slots: slots, parameter: "insert_slot", detail: reason)
                    }
                }
                guard let only = matches.first, matches.count == 1 else {
                    // Both answers are reported, never resolved by picking one:
                    // the insert list is right there in the message, so the
                    // agent's retry is informed rather than a second guess.
                    let available = cells
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && $0 != MCULCDStrings.emptySlot }
                    throw LogicianError.insertNotFound(
                        track: trackName ?? "the selected strip",
                        plugin: pluginName, available: available)
                }
                resolvedSlot = only
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
            hotEditView = HotEditView(
                track: trackName, slot: .insert(finalSlot),
                cacheKey: slotName.flatMap { $0.isEmpty || $0 == MCULCDStrings.emptySlot ? nil : $0 }
            )
            deferSurfaceRestore(SurfaceDebt(strip: trackName, view: "plugin_edit", slot: finalSlot))
        }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: slotName.flatMap { $0.isEmpty || $0 == MCULCDStrings.emptySlot ? nil : $0 }
        ) else {
            hotEditView = nil
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
        if !staleInsertCells.isEmpty {
            result["stale_insert_cells"] = staleInsertCells
            appendWarning(
                "The control surface's insert row named this plug-in in "
                    + "\(staleInsertCells.count + 1) slots; Accessibility reads it on this strip"
                    + " once, so slot"
                    + (staleInsertCells.count == 1 ? " " : "s ")
                    + staleInsertCells.map(String.init).joined(separator: ", ")
                    + " had not repainted yet and slot \(finalSlot) is the one that was written."
                    + " Re-read the inserts if you want the row confirmed.",
                to: &result
            )
        }
        return result
    }

}
