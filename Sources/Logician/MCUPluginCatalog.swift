import AppKit
import Foundation
import LogicMCUBridge

// MARK: - Reading one browse entry off the LCD

extension MCUController {

    /// The browse cell as the catalog means it, with the neighbouring slots'
    /// "no plug-in" markers taken back off.
    ///
    /// A plug-in name spills across several 7-character LCD cells, so
    /// `browseName()` slices from the browsed slot to the end of the row and
    /// cuts at the first long gap. When the name is long enough to leave only a
    /// short gap before the next cell, that cut misses and the neighbour rides
    /// along: the first catalog entry was captured as
    /// `"Parametric EQ (s/s)  --"` while the same entry reads
    /// `"Parametric EQ (s/s)"` on the way round, so the loop's wrap test — "the
    /// FIRST entry has reappeared" — could never fire. Measured 2026-08-31: a
    /// plug-in that does not exist therefore ran the full step cap (15.3 s)
    /// instead of stopping at the wrap after ~139 entries (~9 s), and the same
    /// contamination was reported back to the agent as `browser_entry`.
    ///
    /// A BARE marker is left alone: `"--"` is a real entry — the No Plug-in
    /// boundary `removePluginViaBrowser` browses to — and only a marker
    /// trailing something else can be a neighbour's.
    static func normalizedBrowseEntry(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(MCULCDStrings.emptySlot) {
            let shorter = String(text.dropLast(MCULCDStrings.emptySlot.count))
                .trimmingCharacters(in: .whitespaces)
            if shorter.isEmpty { break }
            text = shorter
        }
        return text
    }

    /// The catalog entry's name with Logic's channel-format annotation removed
    /// — `"Compressor (s/s)"` → `"Compressor"`.
    static func browseEntryName(_ shown: String) -> String {
        shown.replacingOccurrences(
            of: #"\s*\([sm]/[sm]\)\s*$"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Logic's channel-format annotation, `"(s/s)"` / `"(m/s)"` / …, or nil
    /// when the entry carries none. The catalog a mono strip browses is not the
    /// catalog a stereo strip browses — mono-only and stereo-only plug-ins drop
    /// in and out, which shifts every position after them — so a cached
    /// coordinate is only a hint for the format it was measured on.
    static func browseEntryFormat(_ shown: String) -> String? {
        guard let range = shown.range(
            of: #"\([sm]/[sm]\)\s*$"#, options: .regularExpression
        ) else { return nil }
        return String(shown[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Whether the entry the LCD is showing is the plug-in that was asked for.
    /// Prefix-tolerant in both directions because either side may be truncated:
    /// the LCD row runs out of cells, and the request may be a shorthand.
    static func browseEntryMatches(_ shown: String, requested: String) -> Bool {
        let cleaned = browseEntryName(normalizedBrowseEntry(shown))
        guard !cleaned.isEmpty else { return false }
        let target = requested.trimmingCharacters(in: .whitespaces).lowercased()
        let candidate = cleaned.lowercased()
        return candidate == target
            || candidate.hasPrefix(target)
            || target.hasPrefix(candidate)
    }
}

// MARK: - The catalog map

/// Where each plug-in sits in the control-surface catalog, as an **entry
/// ordinal** counted from the No Plug-in origin an empty slot starts at.
///
/// Which coordinate to store took measuring, because the obvious one is wrong.
/// Ticks are not it: a walk's running tick total OVER-counts, because a 2-tick
/// message sent into an unfinished repaint is swallowed. Measured 2026-08-31,
/// two walks to `Gain` on the same catalog arrived with 88 and 94 ticks spent —
/// and single settled jumps proved `Gain` is reached by exactly 76
/// (`jump 20` → entry 10 `Stereo Delay`, `jump 60` → entry 30 `Low Cut`,
/// `jump 62` → entry 31 `Fat EQ`, each landing repeatably and each `−N` jump
/// returning exactly to `--`). Every one of those swallowed messages shows up
/// in the walk as a read repeating its predecessor's name, so the ordinal —
/// how many times the name CHANGED — is exactly the position, and
/// `jump ticks = 2 × ordinal`.
///
/// The residual error has only one direction, which is what makes this safe: a
/// catalog that really did hold the same display name at two adjacent
/// positions, or a stale read that hid one entry, makes an ordinal too SMALL,
/// never too large. A hint that is short lands the browse short of its target
/// and it walks the last step or two forward; a hint that overshot would have
/// had to walk a whole lap.
struct PluginCatalogMap: Codable, Equatable {

    struct Entry: Codable, Equatable {
        /// The entry as the LCD shows it, normalised — channel-format
        /// annotation included, because that annotation is what says which
        /// strip format the ordinal was counted on.
        var name: String
        /// 1-based entry ordinal from the `--` origin.
        var position: Int
    }

    /// Ascending by `position`, one entry per display name (the FIRST
    /// occurrence, which is the one a linear walk from the origin stops at).
    var entries: [Entry] = []

    /// How far a CONTIGUOUS walk from the origin has got. Every position at or
    /// below this has been looked at, which is the invariant
    /// `position(matching:)` leans on — see there.
    var coveredPositions: Int = 0

    /// The entry a linear walk from the origin would have stopped at for
    /// `requested`, or nil when nothing in this map matches.
    ///
    /// Answering with the first match is only the same answer the walk gives
    /// because the map has no HOLES: every entry sits at or below
    /// `coveredPositions`, and everything at or below `coveredPositions` was
    /// looked at, so a true first match earlier than the one returned would
    /// have been recorded and returned instead. A map built by jumping about
    /// would not have that property, which is why a browse that jumps records
    /// nothing.
    func position(matching requested: String, format: String?) -> Int? {
        entries.first { entry in
            if let format, let entryFormat = MCUController.browseEntryFormat(entry.name),
               entryFormat != format { return false }
            return MCUController.browseEntryMatches(entry.name, requested: requested)
        }?.position
    }

    /// Folds one contiguous browse's observations in. Lowest ordinal per name
    /// wins: a run that saw the same name further along was looking at a second
    /// occurrence, not a moved one. Two contiguous prefixes union to a
    /// contiguous prefix, so coverage is simply the longer of the two.
    mutating func merge(_ observed: [Entry], coveredPositions reached: Int) {
        var lowest: [String: Int] = [:]
        for entry in entries + observed {
            guard !entry.name.isEmpty, entry.position > 0 else { continue }
            if let known = lowest[entry.name], known <= entry.position { continue }
            lowest[entry.name] = entry.position
        }
        entries = lowest.map { Entry(name: $0.key, position: $0.value) }
            .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
        coveredPositions = max(coveredPositions, reached)
    }
}

// MARK: - Planning the jump

extension MCUController {

    /// One vpot message carries at most 63 ticks (`turnVPot` clamps there), and
    /// the list advances one position per two ticks, so 62 is the largest jump
    /// that lands on an entry boundary — 31 catalog entries in one MIDI
    /// message, measured exact and reversible 2026-08-31 (`delta 20` → +10
    /// entries, `60` → +30, `−60` → −30, each 31-entry jump repainting in
    /// ~148 ms).
    ///
    /// Exact and reversible ONLY when the repaint each chunk provokes is
    /// allowed to finish first. Measured the same day: `62` then `26` fired
    /// back to back landed on neither the asked-for entry nor a repeatable one,
    /// and the matching `−88` did not come home to `--`; with a silence proof
    /// between the chunks, six jumps out of six landed on the same entry every
    /// time and every one of them came home. See `waitForSurfaceQuiet`.
    static let browseJumpTicksPerMessage = 62

    /// Two vpot ticks per catalog entry.
    static let browseTicksPerEntry = 2

    /// How many catalog ENTRIES a browse will look at before giving up. The
    /// wrap test is what normally ends a search for a plug-in that is not
    /// there; this is the backstop for a catalog that never repeats a name.
    ///
    /// Counted in entries, not in messages, and that is the point. The loop
    /// used to stop after 500 MESSAGES, which sounds generous and is not:
    /// measured 2026-08-31, a 2-tick message sent into an unfinished repaint is
    /// swallowed, and at unpaced walking speed 500 messages saw only 269
    /// entries — while this machine's catalog (Logic's own plus the installed
    /// Audio Units) runs past 590. The browse could therefore report a plug-in
    /// "not shown" having looked at half the list, which is the shape of
    /// wrongness this server exists to refuse. It now says how many entries it
    /// actually looked at, and that the catalog may be longer.
    static let browseEntryCap = 700

    /// The wall clock a fruitless search gets. Set to what the old
    /// 500-message cap actually cost (15.3 s measured), which buys parity on
    /// both counts at once: a plug-in that is simply not installed fails in
    /// about the time it used to, and the ~390 entries a paced walk covers in
    /// 15 s is about what 500 unpaced messages reached — so nothing that was
    /// findable becomes unfindable. Whatever stops the search, the message says
    /// which bound it hit and how much of the catalog it got through.
    static let browseSearchBudget: TimeInterval = 15

    /// How far short of a cached ordinal a jump deliberately stops, in entries.
    /// Zero, and deliberately: the error in an ordinal can only be downward
    /// (see `PluginCatalogMap`), so aiming straight at it either lands on the
    /// target — which the name test proves as thoroughly as it proves a landing
    /// reached by stepping — or lands short and walks the rest. Aiming one
    /// entry short was measured 2026-08-31 to cost three extra steps rather
    /// than one, because the ticks sent immediately after a 31-entry repaint
    /// are the ones most likely to be swallowed.
    static let browseJumpUndershootEntries = 0

    /// How many ordinary steps a jump is given to pay off before the map is
    /// judged to have been wrong about this plug-in. Generous next to the one
    /// entry of deliberate undershoot, so that a slightly short ordinal is
    /// absorbed rather than convicted; a genuinely stale map is convicted
    /// within ~0.4 s and then deleted.
    static let browseJumpGraceSteps = 6

    /// How far short of the No Plug-in boundary a REMOVAL's backward jump
    /// deliberately stops, in entries.
    ///
    /// Four, and the asymmetry with `browseJumpUndershootEntries` (zero) is
    /// the whole reason this is a separate constant. Landing short of an ADD's
    /// target costs one step forward; landing past the `--` origin wraps into
    /// the far end of a 590+-entry catalog, and the walk home from there is the
    /// whole list. The error in a cached ordinal can only be downward (see
    /// `PluginCatalogMap`), so an exact or short hint cannot overshoot at all —
    /// this margin is insurance against the one thing that could, a map whose
    /// install scope matched when it should not have. Four entries cost ~0.2 s
    /// of paced walking and buy the difference between a fast removal and a
    /// 20-second one.
    static let browseRemovalUndershootEntries = 4

    /// The wall clock a backward walk to the No Plug-in boundary gets.
    ///
    /// Twice `browseSearchBudget`, because it bounds something different. An
    /// add's budget bounds a search for an entry that may not exist at all; a
    /// removal's destination provably DOES exist, at ordinal 0, and the
    /// distance to it is the removed plug-in's own ordinal — so the walk always
    /// terminates and the only open question is how deep the plug-in sits. At
    /// the paced rate (~40 ms/entry) 30 s covers this install's whole
    /// 590+-entry catalog from cold, which is exactly what the old 400-MESSAGE
    /// bound could not do: measured 2026-09-02 on the unpaced loop, 15-23% of
    /// messages were swallowed and 400 of them reached only ~330 entries, so a
    /// plug-in sitting deeper than that could not be removed by the mouse-free
    /// route AT ALL — and the refusal said it had looked at 400 steps without
    /// saying it had never been near the boundary.
    static let browseRemovalBudget: TimeInterval = 30

    /// How many of the last entries a failed backward walk reads back in its
    /// refusal. Enough to say where the browse actually was — which is the
    /// difference between "not found" and "never got near it".
    static let browseRemovalTailEntries = 6

    /// Blocks until Logic stops sending, or the deadline. `quiescentStatus`
    /// answers nil for "more arrived, ask again" rather than looping itself, so
    /// this is the loop — the positive proof that a multi-entry repaint has
    /// finished, which a single `awaitEvents` return does not give.
    @discardableResult
    static func waitForSurfaceQuiet(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let status = quiescentStatus(), status["timed_out"] as? Bool == true { return true }
        }
        return false
    }

    /// The messages that carry a browse `ticks` ticks from where it is now.
    /// Splits into signed chunks of at most `browseJumpTicksPerMessage`; sums
    /// back to `ticks` exactly.
    static func browseJumpPlan(ticks: Int) -> [Int] {
        guard ticks != 0 else { return [] }
        let sign = ticks < 0 ? -1 : 1
        var remaining = abs(ticks)
        var plan: [Int] = []
        while remaining > 0 {
            let chunk = min(remaining, browseJumpTicksPerMessage)
            plan.append(sign * chunk)
            remaining -= chunk
        }
        return plan
    }
}

// MARK: - Scoping the catalog cache to the Logic install

extension MCUController {

    static var pluginCatalogCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("plugin-catalog-cache.json")
    }

    /// Identity the catalog map is valid for.
    ///
    /// The catalog is not the project's, it is the INSTALL's: opening another
    /// song does not move `Gain`, and installing one Audio Unit moves every
    /// entry after it. So the scope is this build, Logic's own version, and a
    /// digest of what is in the plug-in folders — name, size and modification
    /// date of every item, which is what changes when a plug-in is installed,
    /// updated or removed.
    ///
    /// It does not have to be airtight, and deliberately is not: a scope that
    /// wrongly matched would hand the browse a wrong POSITION, and a wrong
    /// position is caught by the name test that gates the press. The cost of
    /// being wrong here is extra steps, never a wrong plug-in.
    static func pluginCatalogScope() -> String? {
        guard let logic = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.logic10").first,
              let bundleURL = logic.bundleURL,
              let info = Bundle(url: bundleURL)?.infoDictionary else { return nil }
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "v\(cacheSchemaVersion)|logic \(version) (\(build))|plugins \(pluginFolderDigest())"
    }

    /// A stable digest of the plug-in folders' contents, shallow: the folders
    /// hold one bundle per plug-in, so one level is the whole plug-in set.
    private static func pluginFolderDigest() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components"),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST"),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
            home.appendingPathComponent("Library/Audio/Plug-Ins/Components"),
            home.appendingPathComponent("Library/Audio/Plug-Ins/VST"),
            home.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
        ]
        var parts: [String] = []
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? item.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values?.fileSize ?? 0
                parts.append("\(item.lastPathComponent):\(Int(stamp)):\(size)")
            }
        }
        return String(format: "%016llx", pluginFolderHash(parts.joined(separator: "|")))
    }

    /// FNV-1a. Spelled out rather than reached for in CryptoKit because the
    /// only property needed is "changes when the input changes", and this file
    /// should not decide the project's dependency graph for that.
    private static func pluginFolderHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The map for this install, or nil when there is not a usable one — which
    /// callers answer with a full walk, never a guess. A file stamped for
    /// another install can never become useful again, so it is retired rather
    /// than left to be re-read and re-rejected on every call.
    static func loadPluginCatalog() -> PluginCatalogMap? {
        loadScopedCache(
            pluginCatalogCacheURL, scope: pluginCatalogScope(),
            as: PluginCatalogMap.self, deleteOnMismatch: true
        )
    }

    static func savePluginCatalog(_ map: PluginCatalogMap) {
        guard !map.entries.isEmpty else { return }
        saveScopedCache(map, to: pluginCatalogCacheURL, scope: pluginCatalogScope())
    }

    /// Retires the map after a jump landed somewhere the map cannot explain.
    /// The house rule for a cache that has been caught out: delete it, record
    /// nothing more from a run whose coordinates are now suspect, and let the
    /// next call walk from the origin and rebuild it.
    static func discardPluginCatalog() {
        try? FileManager.default.removeItem(at: pluginCatalogCacheURL)
    }
}
