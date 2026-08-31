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
///    produce a wrong send — while the send view is standing, a browse writes
///    nothing until the vpot press, and the press is gated on an exact name
///    match — it can only cost steps. "While the send view is standing" is
///    load-bearing; see the next section.
///
/// # The send view does not stay standing (measured 2026-08-31)
///
/// The uncommitted-until-pressed contract was originally stated without a
/// qualifier, and one live session paid for the difference with a pan driven
/// to its stop, two spurious sends and a stray Aux. What the follow-up
/// measurements established, hand-driving the browser on the sandbox project:
///
/// * An uncommitted destination BLINKS in its cell (~1 s cadence) and expires
///   about 60 seconds after the last vpot tick. Expiry CANCELS the pending
///   entry — the slot read back unchanged — and every tick RESETS the clock,
///   so a browse that keeps moving never expires on its own.
/// * Leaving the send view cancels a pending browse. Verified by readback on
///   an empty slot (parked on `Output 2`, left to Pan, slot still empty) and
///   on an occupied one (parked on `Bus 65` over a `Bus 2` send, left to Pan,
///   `Bus 2` intact).
/// * The hazard is the TEARDOWN, not the timeout. When the view expires — and
///   when Logic tears it down for reasons of its own — the surface passes
///   through a degraded SE frame (occupied slots repaint as `--`), then the
///   MULTI-channel send views (`S_`, `S1` — where each vpot writes a
///   destination or level DIRECTLY, no press involved), then Pan. The whole
///   walk takes a few seconds, and any message still in flight lands on
///   whatever control its index means in the view it arrives in. That is how
///   a "browse" wrote a pan to −64, and the only mechanism found that puts a
///   send on a strip WITHOUT a vpot press.
/// * A freshly ENTERED send view has the same lying-frame problem from the
///   other side: for a beat it can paint an occupied track's slots blank
///   (observed twice — a send list read back `[]` moments before reading its
///   real content).
///
/// So every message a browse sends is gated on the assignment display still
/// reading `SE` (`sendViewStanding`), a read that shows no catalog entry is
/// never answered with more blind ticks (`sendBrowseReadIsEntry`,
/// `sendBrowseBlankReadCap`), and every abandoned browse PROVES it left no
/// write behind before it reports (`sendAbandonVerdict` and its call sites).
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

    /// How many consecutive reads that show NO catalog entry a browse
    /// tolerates before abandoning. A read can be legitimately entry-less for
    /// a beat — the origin `--` before the first tick paints, a blink-off
    /// frame of the pending entry, an unfinished repaint — but a browser that
    /// answers this many times in a row with nothing is not a browser any
    /// more: it is the degraded frame of a view being torn down, or a view
    /// that never painted (both measured 2026-08-31). The old loop kept
    /// ticking blindly into exactly that, for its whole 20 s budget, and the
    /// ticks were landing on a pan.
    static let sendBrowseBlankReadCap = 8

    /// True when a destination-cell read names a catalog entry. Blank cells
    /// and the `--` placeholder are the browse's ordinary non-answers; a BARE
    /// NUMBER (`-64`, `0`, `-12,2`) is worse than a non-answer — no send
    /// destination is ever spelled as one, and a numeric read means the cell
    /// under this index belongs to some other view's parameter (a pan, a
    /// level). Both classes mean "do not treat this as an entry, and do not
    /// keep ticking on the strength of it".
    static func sendBrowseReadIsEntry(_ shown: String) -> Bool {
        let text = shown.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == MCULCDStrings.emptySlot { return false }
        // Numeric: optional sign, then digits with at most separator
        // punctuation — the shapes Logic paints for pans and dB values
        // (`-64`, `+28`, `-12,2`, `-9.0`). Anything with a letter survives.
        if text.range(of: #"^[+-]?[\d.,]*\d[\d.,]*$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    /// The gate every destination-browse message passes before it is sent:
    /// the assignment display must still read `SE`. Anything else means the
    /// send view dropped out from under the browse and the message's index
    /// now addresses a different control entirely (see the type comment).
    /// Takes the status frame so a caller that already holds one pays no
    /// extra round trip.
    static func sendViewStanding(in status: [String: Any]?) -> Bool {
        (status?["assignment"] as? String) == MCULCDStrings.Assignment.send
    }

    /// The error a browse abandons with when `sendViewStanding` says no.
    /// `action` names the message that was about to be sent — and was not.
    static func sendViewDroppedError(
        _ status: [String: Any]?, before action: String
    ) -> LogicianError {
        let code = (status?["assignment"] as? String).map { "'\($0)'" } ?? "nothing readable"
        return .preconditionUnmet(
            "The send view dropped mid-browse: the assignment display reads \(code) where 'SE'"
                + " stood. Logic tears an idle send view down through the multi-channel views to"
                + " Pan, where vpot messages write destinations and pans directly (measured"
                + " 2026-08-31), so \(action) was not sent and the browse was abandoned."
        )
    }

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

    /// The destination text at a send slot's field group, cut out of one PAIR
    /// of rows. Pure, so both states below can be exercised against captured
    /// rows.
    ///
    /// Two states share this read, and that is the whole difficulty. While a
    /// destination is being BROWSED, Logic covers the slot's labels with a
    /// banner (`Send 1  Destination`) and lets the name spill past its own
    /// cell — `Output 3-4` needs ten characters and a cell holds six. Once the
    /// send is SETTLED, the neighbouring cells hold the slot's other fields,
    /// and a read that spilled returns `Bus 90 -oodB  PosPan active`.
    ///
    /// Measured live 2026-08-31, that second reading is not hypothetical: it is
    /// what `logic_remove_send` refused on
    /// (*"the field reads 'Bus 90 -oodB  PosPan active'"*), because the cut it
    /// inherited ran forward to the first four-space gap and a settled row has
    /// no such gap until the field group ends.
    ///
    /// The TOP row is what tells the two apart. A settled field group labels
    /// every cell (`Sen1In Send 1 Sen1Po Sen1Mu`); the browse banner does not.
    /// So the name is allowed to run on only while the cell it would run into
    /// is unlabelled and holds something that is not a placeholder — and it is
    /// then sliced out of the raw row rather than rejoined from trimmed cells,
    /// so a name that spills mid-word comes back as Logic spelled it.
    static func sendDestinationCell(top: String, bottom: String, destIndex: Int) -> String {
        guard (0..<MCULCDRow.cellCount).contains(destIndex) else { return "" }
        let topCells = lcdFields(top)
        let bottomCells = lcdFields(bottom)
        var lastCell = destIndex
        while lastCell + 1 < MCULCDRow.cellCount {
            let next = lastCell + 1
            // A labelled cell is the slot's next FIELD, not more of this name.
            if topCells[next].hasPrefix(MCULCDStrings.sendFieldLabelPrefix) { break }
            let cell = bottomCells[next]
            if cell.isEmpty || cell == MCULCDStrings.clearingCell
                || cell == MCULCDStrings.emptySlot { break }
            lastCell = next
        }
        let padded = Array(bottom.padding(
            toLength: MCULCDRow.length, withPad: " ", startingAt: 0
        ))
        let start = destIndex * MCULCDRow.cellWidth
        let end = min((lastCell + 1) * MCULCDRow.cellWidth, MCULCDRow.length)
        return String(padded[start..<end]).trimmingCharacters(in: .whitespaces)
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

    /// The number a destination name ends in, or nil where it ends in a letter.
    /// Unlike `parseSendDestination` this asks nothing of what comes before it,
    /// because its job is to tell `Out3-4` from `Out3-6` — and `Bus 10` from
    /// `Bus 100` — rather than to place either in a family. Read by
    /// `sendDestinationMatches`, which is what stops an LCD abbreviation from
    /// answering for a different destination that abbreviates into it.
    static func sendDestinationTrailingNumber(_ name: String) -> Int? {
        guard let digits = name.range(of: #"\d+$"#, options: .regularExpression) else {
            return nil
        }
        return Int(name[digits])
    }

    /// How many entries short of home a removal's jump deliberately stops, so
    /// that the paced backward walk is always the thing that finds the
    /// No-Send boundary.
    static let sendRemovalHomeMargin = 8

    /// Carries a destination browse `entries` entries from where it is now, in
    /// clamp-sized messages with a silence proof between them.
    ///
    /// The proof is not optional: a 63-entry repaint is still arriving when the
    /// next message would go out, and a message sent into it is swallowed — so
    /// the landing would be neither where it was asked for nor reversible
    /// (measured on the plug-in browser, same surface, same failure).
    ///
    /// Shared by the two browses, which use it in opposite directions: the add
    /// jumps FORWARD to a destination, the removal jumps BACK toward the
    /// No-Send entry. Neither writes anything by jumping — a browse is
    /// uncommitted until the vpot press — WHILE THE SEND VIEW IS STANDING,
    /// which is why every chunk re-checks the assignment display before it
    /// goes out: a 63-tick message that arrives after the view has dropped is
    /// 63 writes on a pan or, worse, on the multi-channel send view's direct
    /// destination vpots (the type comment has the measured teardown). The
    /// check rides the same status read that anchors the event wait, so the
    /// gate costs no extra round trip.
    static func sendBrowseJump(destIndex: Int, entries: Int) throws -> Bool {
        for chunk in sendBrowseJumpPlan(entries: entries) {
            let status = freshStatus()
            guard sendViewStanding(in: status) else {
                throw sendViewDroppedError(status, before: "a \(chunk)-entry jump")
            }
            let before = status?["received_events"] as? Int ?? -1
            guard try MCUBridge.send(.vpot(index: destIndex, delta: chunk)).ok else {
                return false
            }
            _ = awaitEvents(since: before, timeoutMs: 400)
            waitForSurfaceQuiet(seconds: 1.5)
        }
        return true
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
