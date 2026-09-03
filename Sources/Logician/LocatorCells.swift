import Foundation

/// The pure decisions behind `setCycleRange`'s mouse-free write route: the
/// control bar LCD's two cycle-locator cells.
///
/// WHY THIS EXISTS AT ALL. Until 2026-09-03 a cycle range whose LENGTH
/// changed was written by DRAGGING THE RULER with synthetic `CGEvent` mouse
/// events — the last mouse-driven write in the server, ungated and
/// undocumented, moving the user's pointer, engaging Cycle mode on its own
/// and scrolling the ruler out from under the next call. It was also, by
/// then, simply BROKEN: measured live 2026-09-03, three consecutive
/// length-change calls on the sandbox refused with *"hit test at the cycle
/// strip of the ruler resolved to AXTable ''"* — a drag aims at screen
/// coordinates, and whatever the window stack does to those coordinates the
/// tool cannot see.
///
/// The LCD's locator cells are the same locators, addressed as numbers.
/// MEASURED 2026-09-03 (Logic Pro 12.3.1, sandbox project):
///
/// - each cell is an `AXGroup` whose `AXDescription` IS its value —
///   `"0005  1  1  001"` — holding four sliders (`bar`, `beat`, `division`,
///   `tick`), exactly the shape of the playhead position display;
/// - the sliders take one step per `AXValue` write, the same contract
///   `convergeSlider` is built on, at **0.1–1.6 ms per step**: bar 5 → 20 in
///   15 steps took 3.1 ms, 9 → 26 in 17 steps took 2.9 ms, both locators
///   together **6.6–8.1 ms**;
/// - the ruler's cycle region followed exactly (`4 bars` → `6 bars`, and the
///   region moved from x 461 to x 655), and **Cycle mode did not change**
///   (`0` before, `0` after) — the drag's own worst side effect is gone with
///   it;
/// - nothing needs to be VISIBLE: the write is a number, so a range off the
///   right edge of the ruler needs no scrolling and can never strand a later
///   call.
///
/// The cells only appear in the LCD display mode that carries them (`Custom`
/// on this install; `Beats & Project` and `Beats & Time` publish none), so
/// the live half switches the display and puts it back — measured at 198 ms
/// for the switch, 7 ms for the cells to appear after it.
enum LocatorCells {

    /// The row of a locator cell, and therefore which locator it is: the LEFT
    /// locator is drawn ABOVE the right one in the LCD.
    ///
    /// MEASURED 2026-09-03, and measured the only way that settles it — by
    /// swapping them. With the cycle at bars 5–9 the top cell read `0005` and
    /// the bottom `0009`; writing 9 into the top and 5 into the bottom turned
    /// the range into Logic's SKIP cycle, which publishes an EMPTY
    /// `AXSizeDescription` on the ruler's cycle region and reads `4` on the
    /// Cycle button instead of `0`/`1`. So an inverted pair is both real and
    /// detectable, `writeOrder` below exists to never create one even
    /// momentarily, and the length check catches it if one ever appears.
    enum Locator {
        case left
        case right
    }

    /// Which locator to write FIRST so the pair is never inverted along the
    /// way — not even for the few milliseconds between the two legs.
    ///
    /// Moving the left locator to a bar at or past the CURRENT right locator
    /// would cross it; moving the right one out first cannot, because the
    /// requested end is beyond the requested start which is already at or
    /// past the current right.
    static func writeOrder(currentRight: Int, startBar: Int) -> Locator {
        startBar < currentRight ? .left : .right
    }

    /// Is this AXGroup description a locator cell's own value?
    ///
    /// Locale-independent by construction: Logic renders the cell as the four
    /// numbers it holds (`"0005  1  1  001"`), so this matches digits and
    /// spaces and nothing else. The position display next to it is described
    /// in words (`Playhead Position`) and is therefore never mistaken for one.
    static func isCellDescription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isNumber else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == " " }
    }

    /// The cells that belong together, as index pairs into `frames`.
    ///
    /// A locator pair is a COLUMN: the two cells share an x and differ in y
    /// (measured: both at x 615, the left locator at y 63 and the right at
    /// y 85). Grouping by x rather than by list order is what keeps a second
    /// pair — Logic's Punch locators, which the same Customize dialog can add
    /// — from being read as one locator from each pair.
    ///
    /// Columns that do not hold exactly two cells are dropped: a lone numeric
    /// cell is not a locator pair, and guessing which of three it pairs with
    /// is how a tool writes into the wrong locator.
    static func pairs(frames: [CGRect], columnTolerance: CGFloat = 6) -> [(top: Int, bottom: Int)] {
        var columns: [[Int]] = []
        for index in frames.indices.sorted(by: { frames[$0].origin.x < frames[$1].origin.x }) {
            if let last = columns.indices.last,
               let first = columns[last].first,
               abs(frames[first].origin.x - frames[index].origin.x) <= columnTolerance {
                columns[last].append(index)
            } else {
                columns.append([index])
            }
        }
        return columns.compactMap { column in
            guard column.count == 2 else { return nil }
            let sorted = column.sorted { frames[$0].origin.y < frames[$1].origin.y }
            return (top: sorted[0], bottom: sorted[1])
        }
    }

    /// Which pair is the CYCLE pair, when the LCD shows more than one.
    ///
    /// The ruler's cycle region is the witness: its `AXSizeDescription` says
    /// how many bars the cycle spans, and only the cycle locators can span
    /// exactly that. With one candidate there is nothing to choose; with
    /// several and no witness — or several that all match it — nothing here
    /// guesses, and the caller refuses by name (a wrong choice here would
    /// silently move the user's punch locators instead).
    static func cyclePair(spans: [Int], regionLengthBars: Int?) -> Int? {
        if spans.count == 1 { return 0 }
        guard let regionLengthBars else { return nil }
        let matches = spans.indices.filter { spans[$0] == regionLengthBars }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The bar a cell holds, from its own description (`"0005  1  1  001"` →
    /// 5). The slider's `AXValue` says the same thing; this reads the text
    /// Logic renders, which is the witness a human would check.
    static func bar(inCellDescription text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    /// `bars 5-9`, for the sentences below.
    static func rangeText(startBar: Int, endBar: Int) -> String {
        "bars \(startBar)-\(endBar)"
    }

    /// Where a range was left when it could not be put back — quoted from the
    /// cells themselves rather than derived, because the reason the restore
    /// failed may be exactly that the derivation is wrong.
    static func rangeText(left: String, right: String) -> String {
        "the locators reading '\(left.trimmingCharacters(in: .whitespaces))' and "
            + "'\(right.trimmingCharacters(in: .whitespaces))'"
    }

    /// Why the range could not be written, when the LCD will not show its
    /// locator cells. Names the one thing the user can do about it, because
    /// there is no fallback any more — the mouse drag that used to be one was
    /// removed on purpose.
    static func noCellsRefusal(displayMode: String, triedSwitch: Bool) -> String {
        "The control bar's LCD is not showing the cycle locators, which is where this server "
            + "writes them (the ruler drag that used to do it moved the user's pointer and was "
            + "removed 2026-09-03). The display mode is '\(displayMode)'"
            + (triedSwitch
                ? " and switching it to '\(LogicUIStrings.Element.customDisplayMode)' did not reveal them"
                : "")
            + ". Turn the locators on once in Logic: click the small arrow at the right of the LCD "
            + "→ Customize Control Bar and Display…, tick 'Locators (Left/Right)' under Custom, "
            + "then call this tool again."
    }

    /// Why the range could not be written, when the LCD shows more locator
    /// pairs than this can tell apart.
    static func ambiguousPairsRefusal(count: Int) -> String {
        "The control bar's LCD shows \(count) locator pairs (Logic's Customize Control Bar and "
            + "Display can add the Punch locators next to the cycle ones) and the ruler's cycle "
            + "region does not say which pair is the cycle's, so nothing was written — moving the "
            + "wrong pair would silently change the punch range. Untick one pair in Customize "
            + "Control Bar and Display…, or set the range in Logic."
    }

    /// The one-line proof the result carries: what was compared with what.
    static func verificationSentence(startBar: Int, endBar: Int, rulerLength: Int?) -> String {
        let cells = "both locator cells of the control bar LCD read back bar \(startBar) and bar "
            + "\(endBar) exactly, on beat 1 division 1 tick 1"
        guard let rulerLength else {
            return cells + " (the ruler's cycle region could not be read as a second witness)"
        }
        return cells + ", and the ruler's cycle region reports \(rulerLength) bars"
    }
}
