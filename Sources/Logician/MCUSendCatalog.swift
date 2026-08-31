import Foundation
import LogicMCUBridge

/// The shape of the send-destination catalog, and the arithmetic that reaches
/// into it — everything the browse needs that can be decided without Logic.
///
/// # What the catalog is
///
/// Measured live 2026-08-31 against `Testlåt Copy`: the destination field
/// of an empty send slot browses
///
///     Output 1 … Output 8, Bus 1 … Bus 256, Stereo Output,
///     Output 3-4, Output 5-6, Output 7-8
///
/// — 268 entries, one per vpot tick. So `Bus N` sits at entry `8 + N`, and —
/// unlike the plug-in catalog, which is a property of what is installed and has
/// to be walked once and cached — **this address is arithmetic**. There is
/// nothing to learn and nothing to keep.
///
/// Note where it ENDS: in Logic's stereo output pairs, four entries past the
/// last bus. A browse sent past the end of the list is held by Logic on
/// `Output 7-8`, which is why a refusal reads the tail back rather than
/// reporting the last entry it happens to be sitting on
/// (`sendBrowseTailEntries`).
///
/// The same session measured the multi-tick jump on this browser and found it
/// exact, linear and reversible: `delta 10` → +10 entries, `20` → +20,
/// `30` → +30, `60` → +60, and `−30`/`−60` came home to the entry they left.
/// One tick per entry here, against the plug-in browser's two — which is why
/// none of `MCUPluginCatalog`'s constants transfer.
///
/// # Why the arithmetic is only ever a HINT
///
/// Two of the three ways this file reaches a destination need no table at all,
/// and that is deliberate — the table is the locale-fragile part:
///
/// 1. **Same-family arithmetic** (`sendJumpDelta`). Once the browser is
///    showing `Bus 23` and the request is `Bus 90`, the jump is 67 entries and
///    no one had to know where `Bus 1` lives. This works on a Logic whose UI
///    language spells the family word differently, because both sides of the
///    subtraction are that same word.
/// 2. **Stepping.** One tick, one entry, always available.
/// 3. **The measured ordinal** (`sendDestinationOrdinal`), which DOES name
///    Logic's words and is therefore a cold-start shortcut only: an
///    unrecognized family simply walks to the first entry of its own family
///    (nine steps for a bus) and then jumps by (1). A wrong hint cannot
///    produce a wrong send — a browse writes nothing until the vpot press, and
///    the press is gated on an exact name match — it can only cost steps.
extension MCUController {

    /// One vpot tick per catalog entry in the SEND destination browser.
    /// Measured, and the reason `browseTicksPerEntry` (2, the plug-in browser)
    /// must not be reused here.
    static let sendBrowseTicksPerEntry = 1

    /// `turnVPot` clamps one message at 63 ticks, and at one tick per entry
    /// that is 63 entries in a single MIDI message — the whole distance from
    /// `Output 1` to `Bus 55` at once.
    static let sendBrowseJumpEntriesPerMessage = 63

    /// How many entries of the catalog sit ahead of `Bus 1`: `Output 1`…
    /// `Output 8`. Only `sendDestinationOrdinal` reads it, so only the
    /// cold-start shortcut depends on it.
    static let sendOutputCatalogEntries = 8

    /// The family words the measured catalog shape is known for, folded to
    /// lower case. English only, and knowingly: a locale that spells them
    /// differently loses the cold-start jump and keeps everything else (see
    /// the type comment). Nothing is guessed here — a word goes in this table
    /// when it has been read off the surface.
    static let sendBusFamilies: Set<String> = ["bus"]
    static let sendOutputFamilies: Set<String> = ["output"]

    /// The shortest jump worth making. A jump costs a message plus a silence
    /// proof (~300 ms); a step costs ~120 ms. So two entries are cheaper
    /// walked, and anything backwards has to be a jump because the walk only
    /// goes forward.
    static let sendBrowseMinJumpEntries = 3

    /// How many identical reads in a row mean the list is not moving. A step
    /// that lands in an unfinished repaint reads its predecessor's name, which
    /// is ordinary; four of them in a row is not.
    static let sendBrowseStallSteps = 4

    /// How far the probe jumps when the list has stopped moving. Its whole job
    /// is to be a distance a list with anything left in it could not fail to
    /// answer — so that "the list ends here" is something this code PROVES
    /// before it says it, rather than infers from a quiet surface.
    static let sendBrowseProbeEntries = 8

    /// How many of the list's last entries a refusal reads back, by stepping
    /// BACK from the end once the browse has run out of list.
    ///
    /// This is the one thing such a refusal can still learn, and it is the fact
    /// the agent actually needs. Measured live 2026-08-31: the catalog is
    /// `Output 1`…`Output 8`, `Bus 1`…`Bus 256`, and then Logic's four stereo
    /// output PAIRS — so a browse that walks off the end of it lands on
    /// `Output 7-8`, four entries past the last bus. "The list ends at
    /// 'Output 7-8'" is true and no use to someone who asked for `Bus 999`;
    /// "the highest bus in the list is 256" is the answer.
    static let sendBrowseTailEntries = 6

    /// How many jumps one browse may take before it falls back to walking.
    /// The safety valve for a pathological landing that keeps re-planning the
    /// same jump: stepping always makes forward progress, so the browse then
    /// either finds the destination or produces an honest enumeration.
    static let sendBrowseJumpCap = 8

    /// How far into the catalog a browse will look. Logic offers 256 buses plus
    /// the eight outputs, so this is the whole catalog with room over — a bound
    /// to stop a runaway, not a limit anything real should meet.
    ///
    /// It bounds two different things, and both need it. It is how many entries
    /// the browse will STEP through, and it is how far ahead a jump may AIM: a
    /// request for `Bus 999` has an ordinal of 1007, and aiming a browse there
    /// spent 16 clamp-sized messages and 9 s walking off the end of the list to
    /// learn what the entry the first five messages landed on would have said
    /// (measured live 2026-08-31, on the first version of this code).
    static let sendBrowseEntryCap = 300

    /// A planned jump trimmed so it cannot aim past the far end of any catalog.
    /// Trimming is safe where refusing would not be: Logic stops the browse at
    /// its own last entry, so a trimmed jump lands on a REAL entry whose name
    /// then says where the list actually got to — which is the whole answer a
    /// request for a destination past the end of the list needs.
    static func sendClampedJump(_ entries: Int, from position: Int) -> Int {
        guard entries > 0 else { return entries }
        return min(position + entries, sendBrowseEntryCap) - position
    }

    /// The wall clock a fruitless search gets. The old 80-step loop spent
    /// 9.6 s failing; this buys the far half of the catalog for about twice
    /// that, and only ever on the path that is about to refuse — a destination
    /// the arithmetic recognizes is one or two messages away whatever this is
    /// set to.
    static let sendBrowseSearchBudget: TimeInterval = 20

    // MARK: - Reading the destination cell

    /// The destination name showing at a send slot's field group, cut out of
    /// one bottom row. Pure, so the cut can be exercised against captured rows.
    ///
    /// The browse paints the name into the slot's own cell and lets it spill
    /// into the next, so the cell boundary is not the name boundary: cut at the
    /// first long gap instead, and take a neighbour's `--` back off (the same
    /// contamination that used to defeat the plug-in browser's wrap test — see
    /// `normalizedBrowseEntry`).
    static func sendDestinationCell(_ bottom: String, destIndex: Int) -> String {
        let start = bottom.index(bottom.startIndex, offsetBy: min(destIndex * 7, bottom.count))
        let raw = String(bottom[start...])
        let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
        return normalizedBrowseEntry(cut)
    }

    // MARK: - The arithmetic

    /// A destination name split into the family it belongs to and its number
    /// within that family: `"Bus 12"` → (`bus`, 12). The family is folded to
    /// lower case so two spellings of one word compare equal; it is never
    /// translated or matched against a table here, which is what keeps
    /// `sendJumpDelta` locale-proof.
    struct SendDestinationName: Equatable {
        let family: String
        let number: Int
    }

    static func parseSendDestination(_ name: String) -> SendDestinationName? {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard let digits = text.range(of: #"\d+$"#, options: .regularExpression),
              let number = Int(text[digits]) else { return nil }
        let family = text[..<digits.lowerBound]
            .trimmingCharacters(in: .whitespaces).lowercased()
        // The family carries no digits of its own. That is what tells a member
        // of a numbered family from one of Logic's stereo output PAIRS, which
        // end the catalog: `Output 7-8` would otherwise read as member 8 of a
        // family called `output 7-`, and the arithmetic would cheerfully
        // subtract it from `Output 3`.
        guard !family.isEmpty, !family.contains(where: \.isNumber) else { return nil }
        return SendDestinationName(family: family, number: number)
    }

    /// How many entries forward (or back) the requested destination is from the
    /// one the browser is showing, when both belong to the same family and the
    /// family is therefore numbered consecutively. nil when they are not
    /// comparable — a bus read against an output request, or either side not a
    /// name of this shape at all.
    static func sendJumpDelta(from shown: String, to requested: String) -> Int? {
        guard let here = parseSendDestination(shown),
              let target = parseSendDestination(requested),
              here.family == target.family else { return nil }
        return target.number - here.number
    }

    /// The entry the measured catalog shape puts a destination at, counted from
    /// the `--` origin an empty slot starts at. nil for a name whose family
    /// this build has not measured — which costs the cold-start jump and
    /// nothing else.
    static func sendDestinationOrdinal(_ name: String) -> Int? {
        guard let parsed = parseSendDestination(name), parsed.number >= 1 else { return nil }
        if sendBusFamilies.contains(parsed.family) {
            return sendOutputCatalogEntries + parsed.number
        }
        if sendOutputFamilies.contains(parsed.family),
           parsed.number <= sendOutputCatalogEntries {
            return parsed.number
        }
        return nil
    }

    /// The messages that carry a browse `entries` entries from where it is now:
    /// signed chunks of at most `sendBrowseJumpEntriesPerMessage`, summing back
    /// to `entries` exactly.
    static func sendBrowseJumpPlan(entries: Int) -> [Int] {
        guard entries != 0 else { return [] }
        let sign = entries < 0 ? -1 : 1
        var remaining = abs(entries)
        var plan: [Int] = []
        while remaining > 0 {
            let chunk = min(remaining, sendBrowseJumpEntriesPerMessage)
            plan.append(sign * chunk)
            remaining -= chunk
        }
        return plan
    }

    /// Whether the SEND LIST's destination cell names the destination that was
    /// asked for.
    ///
    /// The browse cell shows a destination's full name, because the browse
    /// banner lets it spill across the row. The settled send list does not: its
    /// destination cell is six characters of Logic's own abbreviation, so a
    /// send to `Output 3-4` reads back as `Out3-4`. An exact compare therefore
    /// calls a perfectly good write a failure — measured live 2026-08-31, it
    /// did exactly that: the send was created, the tool reported
    /// `verification_failed` with `restored: false`, and the send was sitting
    /// in the project all along.
    ///
    /// Abbreviation-tolerant, and deliberately NOT tolerant of the one
    /// confusion that matters here. `Bus 1` is an ordered subsequence of
    /// `Bus 12`, so a bare subsequence test would accept a send to the wrong
    /// bus; the trailing NUMBER has to agree as well. Logic abbreviates by
    /// dropping characters from the middle and keeps the tail (`Lofi Pad` →
    /// `LofPad`, `Output 3-4` → `Out3-4`), so requiring the tail costs nothing.
    ///
    /// This is a READBACK check, not the gate on the write: the press is gated
    /// by an exact match against the browse cell, which is not truncated.
    static func sendListDestinationMatches(_ cell: String, requested: String) -> Bool {
        let shown = cell.trimmingCharacters(in: .whitespaces)
        if shown.caseInsensitiveCompare(requested) == .orderedSame { return true }
        guard lcdNameMatches(track: requested, lcd: shown) else { return false }
        return sendDestinationTrailingNumber(shown)
            == sendDestinationTrailingNumber(requested)
    }

    /// The number a destination name ends in, or nil where it ends in a letter.
    /// Unlike `parseSendDestination` this asks nothing of what comes before it,
    /// because its job is to tell `Out3-4` from `Out3-6`, not to place either in
    /// a family.
    static func sendDestinationTrailingNumber(_ name: String) -> Int? {
        guard let digits = name.range(of: #"\d+$"#, options: .regularExpression) else {
            return nil
        }
        return Int(name[digits])
    }

    // MARK: - Saying what the browse saw

    /// Why a browse stopped without its destination. Each one is a different
    /// claim about the catalog, and the refusal says which — because "the list
    /// ends here, so there is no Bus 300" and "I ran out of time and the list
    /// goes on" are opposite pieces of advice.
    enum SendBrowseStop: Equatable {
        /// The list stopped advancing and a probe jump proved it had nothing
        /// left. The destination does not exist.
        case listEnded
        /// The first entry came round again — a full lap, no match.
        case wrapped
        case entryCap
        case timeBudget
    }

    /// What one browse actually saw. `seen` is the catalog in the order it was
    /// met — entries READ, never entries aimed at — and `jumped` records that
    /// the walk was not contiguous, so `seen` has holes in it and the refusal
    /// must not pretend otherwise.
    struct SendBrowseReport: Equatable {
        var seen: [String] = []
        /// The list's final entries in LIST order, read back from the end when
        /// a jumped browse ran out of list. Empty when the browse walked there
        /// contiguously, because `seen` is then the list itself.
        var tail: [String] = []
        var jumped = false
        var stop: SendBrowseStop = .listEnded
    }

    /// The catalog rendered for a reader: consecutive entries of one family
    /// fold into a range, so a refusal can name 264 destinations in half a line
    /// instead of dumping them one by one.
    static func sendCatalogSummary(_ entries: [String]) -> String {
        guard !entries.isEmpty else { return "nothing" }
        var parts: [String] = []
        var runStart = 0
        func flush(_ endExclusive: Int) {
            let count = endExclusive - runStart
            guard count > 0 else { return }
            if count >= 3 {
                parts.append(
                    "\(entries[runStart]) … \(entries[endExclusive - 1]) (\(count) entries)"
                )
            } else {
                parts.append(contentsOf: entries[runStart..<endExclusive])
            }
            runStart = endExclusive
        }
        for index in 1..<max(entries.count, 1) {
            guard let previous = parseSendDestination(entries[index - 1]),
                  let current = parseSendDestination(entries[index]),
                  previous.family == current.family,
                  current.number == previous.number + 1 else {
                flush(index)
                continue
            }
        }
        flush(entries.count)
        return parts.joined(separator: ", ")
    }

    /// The `exposed` half of the refusal: what the browser held, in place of
    /// the old message's silence about it. The browse enumerated the catalog
    /// and threw it away; `logic_set_track_routing` has always refused an
    /// unknown destination with the slot's actual menu listed, and this is the
    /// same courtesy from the surface's own list.
    static func sendDestinationRefusalText(
        requested: String, report: SendBrowseReport
    ) -> String {
        let read = report.seen.count == 1 ? "1 entry" : "\(report.seen.count) entries"
        let holes = report.jumped
            ? " (the browse jumped ahead, so the entries between the ones it names are unread)"
            : ""
        let list = sendCatalogSummary(report.seen)
        switch report.stop {
        case .listEnded:
            let end = report.tail.last ?? report.seen.last ?? "nothing"
            var text = "the destination browser's list ends at '\(end)' and does not hold it"
            // The list's end is proven, and the tail was read down from it — so
            // the highest member of the requested family anywhere in what was
            // read IS the highest one the list offers. That sentence is the
            // answer to "why not?", where naming the last entry is only the
            // answer to "how far does it go?".
            if let target = parseSendDestination(requested),
               let highest = (report.seen + report.tail)
                   .compactMap(parseSendDestination)
                   .filter({ $0.family == target.family })
                   .map(\.number).max(),
               target.number > highest {
                text += " — the highest '\(target.family)' in it is \(highest)"
            }
            if !report.tail.isEmpty {
                text += ". Its last entries are \(sendCatalogSummary(report.tail))"
            }
            return text + ". Entries read: \(list)\(holes). Nothing was written"
        case .wrapped:
            return "the destination browser came back round to its first entry without"
                + " showing it. The whole list is: \(list)\(holes). Nothing was written"
        case .entryCap, .timeBudget:
            let bound = report.stop == .entryCap
                ? "the \(sendBrowseEntryCap)-entry limit"
                : "the \(Int(sendBrowseSearchBudget)) s search budget"
            return "the destination browser never showed it in the \(read) this browse read,"
                + " and never reached the end of its list — so the list may well go on past"
                + " there (\(bound)). Entries read: \(list)\(holes). Nothing was written"
        }
    }
}
