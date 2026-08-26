import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Parameter paging (cursor left/right, note 0x62/0x63)

    static func pressNote(_ note: Int) throws {
        let response = try MCUBridge.send(["cmd": "press", "note": note])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU note press failed: \(response["error"] ?? "?")")
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

    static var nameCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("param-names-cache.json")
    }

    static func loadNameCache() -> [String: [[String]]] {
        guard let data = try? Data(contentsOf: nameCacheURL),
              let cache = try? JSONDecoder().decode([String: [[String]]].self, from: data) else {
            return [:]
        }
        return cache
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
        // A complete cached name set makes even the full read cheap — use it.
        if let key = cacheKey, let cachedNames = loadNameCache()[key] {
            let walk = min(maxPages, cachedNames.count)
            if let fast = (try? rawParameterPagesFast(cachedNames: cachedNames, limit: walk)) ?? nil {
                // End-overlap dedup only applies when the true last page was read.
                let pages = walk == cachedNames.count
                    ? dedupedPages(fast)
                    : fast.map { page in page.filter { !$0.name.isEmpty } }
                return (pages, cachedNames.count, walk < cachedNames.count)
            }
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
            var cache = loadNameCache()
            cache[key] = pages.map { $0.map(\.name) }
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: nameCacheURL)
            }
        }
        return (dedupedPages(pages), max(total, 1), limit < max(total, 1))
    }

    /// Raw pages using cached name rows: waits only for the redraw burst per
    /// page, never the indicator fade. Validates the always-visible fields 0-5
    /// against the cache; nil on any mismatch (caller takes the slow path).
    static func rawParameterPagesFast(
        cachedNames: [[String]], limit: Int? = nil
    ) throws -> [[(name: String, value: String)]]? {
        let total = try normalizeToPageOne()
        guard max(total, 1) == cachedNames.count else { return nil }
        let walkCount = min(limit ?? cachedNames.count, cachedNames.count)
        var pages: [[(name: String, value: String)]] = []
        for pageNumber in 1...walkCount {
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
            var cache = loadNameCache()
            if let cachedNames = cache[key],
               let pages = (try? rawParameterPagesFast(cachedNames: cachedNames)) ?? nil {
                return dedupedPages(pages)
            }
            guard let slow = try rawParameterPagesSlow() else { return nil }
            cache[key] = slow.map { $0.map(\.name) }
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: nameCacheURL)
            }
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
