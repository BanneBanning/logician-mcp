import AppKit
import Foundation
import LogicMCUBridge

/// dB → 14-bit fader position, learned once and reused.
///
/// WHY IT EXISTS. `logic_record_automation` writes ABSOLUTE fader positions on
/// a timed schedule, so it has to know which 14-bit position each target dB
/// *is*. The only way to learn that is to write the fader there and read
/// Logic's own echo — and that converge is ~5 s per distinct dB: **10 003 ms of
/// a 26 523 ms call, 38%** (measured 2026-09-02, `Audio 9`, a two-value curve).
/// It is also the reason a tool that writes a CURVE moves, and then has to
/// restore, the track's static volume.
///
/// WHY IT IS SAFE TO CACHE. The map is a property of Logic's fader taper, not
/// of the track or the curve: measured across three separate server processes,
/// −20 dB came back 5 270 / 5 293 and −14 dB 6 702 / 6 702 — a spread of 23
/// units (±0.1 dB) against the pass's own 500-unit (≈1.5 dB) verification
/// tolerance.
///
/// WHY IT IS STILL CROSS-CHECKED. A taper is a property of a Logic BUILD, and
/// the file is scoped to one (see `faderCalibrationScope`), but a scope that
/// merely *matches* is not evidence. So every call pairs the strip's current dB
/// with the fader echo sitting under it — a reading that costs nothing, because
/// the pass reads both anyway — and refuses to trust a table that disagrees
/// with that pair (`faderCalibrationCrossCheck`). A contradicted table is
/// retired on the spot, the house rule for a cache caught out.
struct FaderCalibrationTable: Codable, Equatable {
    /// dB keyed at ONE decimal: the resolution Logic prints dB in, and finer
    /// than `logic_set_track_volume`'s default 0.15 dB tolerance can resolve.
    private(set) var positions: [String: Int]

    static let empty = FaderCalibrationTable(positions: [:])

    static func key(_ db: Double) -> String {
        String(format: "%.1f", db)
    }

    var isEmpty: Bool { positions.isEmpty }
    var count: Int { positions.count }

    func position(forDb db: Double) -> Int? {
        positions[Self.key(db)]
    }

    mutating func record(db: Double, position: Int) {
        positions[Self.key(db)] = position
    }
}

extension MCUController {

    /// How far a cached position may sit from a live one and still count as
    /// the same taper. The measured process-to-process spread is 23 units
    /// (±0.1 dB); the pass's own per-point verification accepts 500 (≈1.5 dB).
    /// 250 is an order of magnitude above the noise and half of the tolerance
    /// the result would report against, so a table that passes this check
    /// cannot turn a point that would have verified into one that does not.
    static let faderCalibrationTolerance = 250

    static var faderCalibrationCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("fader-calibration-cache.json")
    }

    /// `"18.1 (1234)"` for the Logic that is running, or nil when none is.
    static func runningLogicVersionToken() -> String? {
        guard let logic = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.logic10").first,
              let bundleURL = logic.bundleURL,
              let info = Bundle(url: bundleURL)?.infoDictionary else { return nil }
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }

    /// Identity the fader map is valid for: this build of the server, this
    /// build of Logic (the taper is Logic's), and this project. The project is
    /// in there although a taper is not per-project — a fader map read against
    /// another song is not stale, it is unverifiable from here, and the whole
    /// point of the cross-check is that reuse rests on evidence rather than on
    /// a plausible story.
    static func faderCalibrationScope() -> String? {
        // Logic's version first: it is a bundle read that answers nil without
        // Logic, where the project path is an Accessibility walk. No Logic, no
        // scope, and no reason to have asked the AX tree.
        guard let logic = runningLogicVersionToken(), let project = currentProjectPath() else {
            return nil
        }
        return "v\(cacheSchemaVersion)|logic \(logic)|\(project)"
    }

    static func loadFaderCalibration() -> FaderCalibrationTable? {
        loadScopedCache(
            faderCalibrationCacheURL, scope: faderCalibrationScope(),
            as: FaderCalibrationTable.self, deleteOnMismatch: true
        )
    }

    static func saveFaderCalibration(_ table: FaderCalibrationTable) {
        guard !table.isEmpty else { return }
        saveScopedCache(table, to: faderCalibrationCacheURL, scope: faderCalibrationScope())
    }

    static func discardFaderCalibration() {
        try? FileManager.default.removeItem(at: faderCalibrationCacheURL)
    }

    /// What one live (dB, fader) pair says about a cached table. Pure, so the
    /// rule that decides whether 10 s of fader writes may be skipped can be
    /// tested without a fader.
    enum FaderCalibrationCrossCheck: Equatable {
        /// The table holds this dB and agrees with the live echo.
        case confirmed(db: Double, cached: Int, live: Int)
        /// The table holds this dB and disagrees — the taper is not the one
        /// this table describes, so the table must be retired, not narrowed.
        case contradicted(db: Double, cached: Int, live: Int)
        /// No pair to check against (no table, no readable dB, no readable
        /// echo, or the table simply does not hold this dB). Not a failure —
        /// it means the reuse has no evidence YET, and the first live
        /// calibration of the call becomes the evidence.
        case unavailable(String)

        /// Whether cached positions may be served on this evidence.
        var trustsCache: Bool {
            if case .confirmed = self { return true }
            return false
        }

        var payload: [String: Any] {
            switch self {
            case .confirmed(let db, let cached, let live):
                return [
                    "verdict": "confirmed", "db": db,
                    "cached_fader": cached, "live_fader": live,
                    "tolerance": MCUController.faderCalibrationTolerance
                ]
            case .contradicted(let db, let cached, let live):
                return [
                    "verdict": "contradicted", "db": db,
                    "cached_fader": cached, "live_fader": live,
                    "tolerance": MCUController.faderCalibrationTolerance,
                    "note": "The cached fader map disagreed with Logic's own echo for this dB, so it was retired and every value re-measured."
                ]
            case .unavailable(let reason):
                return ["verdict": "unavailable", "reason": reason]
            }
        }
    }

    static func faderCalibrationCrossCheck(
        table: FaderCalibrationTable?, liveDb: Double?, liveFader: Int?,
        tolerance: Int = faderCalibrationTolerance
    ) -> FaderCalibrationCrossCheck {
        guard let table, !table.isEmpty else {
            return .unavailable("no cached fader map for this Logic build and project")
        }
        guard let liveDb else {
            return .unavailable("the strip published no volume in dB to check the map against")
        }
        guard let liveFader, liveFader >= 0 else {
            return .unavailable("Logic reported no fader echo to check the map against")
        }
        guard let cached = table.position(forDb: liveDb) else {
            return .unavailable(
                "the cached map holds no entry for the strip's current \(FaderCalibrationTable.key(liveDb)) dB"
            )
        }
        return abs(cached - liveFader) <= tolerance
            ? .confirmed(db: liveDb, cached: cached, live: liveFader)
            : .contradicted(db: liveDb, cached: cached, live: liveFader)
    }

    /// The whole calibration decision for one curve: which dB values may come
    /// out of the cache and which have to be written and read back.
    ///
    /// `measure` is the live converge (~5 s a value). It is called only for
    /// values the evidence does not cover, and its first result doubles as the
    /// cross-check when the static pair could not provide one — which is why a
    /// call whose values were all measured before still ends up paying for at
    /// most ONE of them.
    ///
    /// Returns the map the schedule is built from, the table to persist and
    /// the evidence for the result, so a reader can see which positions were
    /// measured in this call and which were reused. The FILE is the caller's
    /// business — passing the table in and out keeps this decision testable
    /// without a Logic, a project or a cache directory.
    static func resolveFaderCalibration(
        targets: [Double],
        liveDb: Double?,
        liveFader: Int?,
        table initialTable: FaderCalibrationTable?,
        measure: (Double) throws -> Int
    ) throws -> (
        map: [Double: Int], measured: [Double], table: FaderCalibrationTable,
        retire: Bool, evidence: [String: Any]
    ) {
        // INHERITED and FRESH are kept apart on purpose. Only the inherited
        // table can be trusted or retired — an entry recorded during this call
        // is a measurement, and a measurement cannot be evidence for itself.
        var inherited = initialTable ?? .empty
        var verdict = faderCalibrationCrossCheck(
            table: inherited, liveDb: liveDb, liveFader: liveFader
        )
        var retired = false
        if case .contradicted = verdict {
            inherited = .empty
            retired = true
        }
        // The strip's current dB and the echo under it are a free calibration
        // sample — no write, no wait — and keeping it is what gives the NEXT
        // call a pair to cross-check against.
        // In order, free pair first: two readings can round to the same 0.1 dB
        // key, and a converged measurement must win over the static echo.
        var fresh: [(db: Double, position: Int)] = []
        if let liveDb, let liveFader, liveFader >= 0 {
            fresh.append((liveDb, liveFader))
        }

        var map: [Double: Int] = [:]
        var measured: [Double] = []
        var reused: [Double] = []
        var trust = verdict.trustsCache
        // A value the table already holds goes FIRST when there is no evidence
        // yet: measuring it produces the pair that lets the rest of the table
        // be served, where measuring a value the table has never seen produces
        // no evidence at all and the next value has to be measured too. Ties
        // break on the dB so the order is deterministic.
        let order = Array(Set(targets)).sorted {
            let known = (inherited.position(forDb: $0) != nil, inherited.position(forDb: $1) != nil)
            return known.0 == known.1 ? $0 < $1 : known.0
        }
        for db in order {
            let cached = inherited.position(forDb: db)
            if trust, let cached {
                map[db] = cached
                reused.append(db)
                continue
            }
            let position = try measure(db)
            if !trust, let cached {
                // The converge just done is the pair the static reading could
                // not give: agree with the table here and the rest of it is
                // evidence-backed; disagree and it is retired, exactly as a
                // contradicted static pair would retire it.
                if abs(cached - position) <= faderCalibrationTolerance {
                    verdict = .confirmed(db: db, cached: cached, live: position)
                    trust = true
                } else {
                    verdict = .contradicted(db: db, cached: cached, live: position)
                    inherited = .empty
                    retired = true
                }
            }
            fresh.append((db, position))
            map[db] = position
            measured.append(db)
        }
        // What to persist: everything measured or read live in this call, on
        // top of the inherited table — which is EMPTY when it was retired, so
        // a caught-out map contributes nothing while this call's own
        // measurements survive.
        var table = inherited
        for pair in fresh { table.record(db: pair.db, position: pair.position) }

        var evidence: [String: Any] = [
            "source": measured.isEmpty ? "cached" : (reused.isEmpty ? "measured" : "mixed"),
            "measured_db": measured,
            "reused_db": reused,
            "cross_check": verdict.payload,
            "cached_entries": table.count
        ]
        if retired {
            evidence["retired_cache"] = true
        }
        if !measured.isEmpty {
            evidence["note"] = "Each measured dB cost a converged fader write (~5 s) that was restored afterwards; reused values cost nothing and moved no fader."
        }
        return (map, measured, table, retired, evidence)
    }
}
