import Foundation

/// The pure decisions behind the control bar's playhead LCD stepper —
/// `LogicAccessibility.convergeSlider` (AXTransport.swift) and the 16 call
/// sites that inherit every millisecond it spends: `logic_set_playhead`,
/// `logic_set_cycle_range`, every region tool that parks the playhead,
/// tempo sampling, automation read/record, MIDI record, marker parking and
/// `logic_import_midi`.
///
/// The loop itself needs a live Accessibility tree, so what lives here is
/// what can be decided without one, and therefore pinned by unit tests:
///
/// - **how many writes one locate is allowed** (the slider moves exactly one
///   step per `AXValue` write, so the budget is the distance plus a small
///   allowance, hard-capped);
/// - **whether a beat nobody asked about moved**, because Logic resets the
///   sub-bar position when the bar slider hits that ceiling — measured beat
///   3 → 1, silently, with the error naming only the bar.
enum PlayheadLocate {

    /// The write budget for one converge: one write per unit of distance,
    /// plus four for a slider that needs a nudge before it starts moving,
    /// hard-capped so nothing here can spin against a clamp. Unchanged from
    /// the loop's original bound — the 2026-09-03 fix cut the WAIT between
    /// writes, never the number of writes the proof is allowed.
    static func stepBudget(from start: Int, to target: Int) -> Int {
        min(abs(target - start) + 4, 512)
    }

    /// The beat to put back after a locate that was never asked to touch it,
    /// or nil when there is nothing to undo.
    ///
    /// Only fires when the caller passed no `beat` (a caller who asked for a
    /// beat owns whatever it landed on) and the display really moved.
    static func unrequestedBeatDrift(requested: Int?, before: Int?, after: Int?) -> Int? {
        guard requested == nil, let before, let after, before != after else { return nil }
        return before
    }

    /// The sentence that says a beat moved on its own, and what was done
    /// about it. Written for the agent reading the result, so it names the
    /// two numbers and the outcome rather than the mechanism.
    static func beatDriftWarning(from before: Int, to drifted: Int, restored: Bool) -> String {
        restored
            ? "Moving the bar also moved the beat from \(before) to \(drifted), which this call "
                + "never asked for; the beat was put back to \(before) and verified."
            : "Moving the bar also moved the beat from \(before) to \(drifted), which this call "
                + "never asked for, and it could NOT be put back — the playhead now reads beat "
                + "\(drifted). Set it explicitly with logic_set_playhead {bar, beat}."
    }
}

/// What is left of `setCycleRange`'s ruler arithmetic now that the range is
/// written as NUMBERS, into the control bar LCD's locator cells, rather than
/// as pixels in the ruler (see `LocatorCells`, 2026-09-03).
///
/// The pixel model used to place every write: the ruler publishes one average
/// pixels-per-bar slope, Logic's timeline is linear in BEATS rather than bars,
/// and a project that changes meter (the sandbox goes 4/4 → 5/4 at bar 41)
/// therefore bent a ~38-bar extrapolation by 0.67–1.01 bars — enough for the
/// tool to refuse a range it could perfectly well reach. None of that decides
/// anything any more: the LCD's locator cells are exact and are what the write
/// and the verification both go through.
///
/// The ruler is still read, as the SECOND witness — the cycle region Logic
/// draws, against the numbers the LCD reports — so what survives here is the
/// one estimate that witness needs, and the sentence a failed write ends with.
enum RulerBarMapping {

    /// Which bar an offset from a known bar line falls on. An ESTIMATE, and
    /// every caller says so: it multiplies out the ruler's average slope, and
    /// on a meter-changing project that is worth about a bar over a long
    /// extrapolation, plus the constant few pixels Logic insets the cycle
    /// region's frame by (MEASURED 2026-09-03: 8 px against bars 13.2 px wide
    /// in 4/4 and 17.0 px in 5/4). Good enough to catch a range drawn in the
    /// wrong PLACE; never used to judge which bar a write landed on.
    static func barAt(offset: CGFloat, anchorOffset: CGFloat, anchorBar: Int, pixelsPerBar: CGFloat) -> Int {
        guard pixelsPerBar > 0 else { return anchorBar }
        return max(1, anchorBar + Int(((offset - anchorOffset) / pixelsPerBar).rounded()))
    }

    /// What a failed write says about the state it left behind. One sentence,
    /// written for the agent that has to decide whether to retry.
    static func restoreSentence(restored: Bool, original: String, leftAt: String) -> String {
        restored
            ? "The cycle range was put back to \(original) and verified."
            : "The cycle range could NOT be put back to \(original) — it is left at \(leftAt). "
                + "Set it explicitly with logic_set_cycle_range."
    }
}
