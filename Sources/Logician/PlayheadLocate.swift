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

/// The pure geometry behind `setCycleRange`'s ruler recovery.
///
/// The tool's own drag makes Logic scroll the ruler to follow the pointer,
/// which used to strand an absolute bar range that was reachable one call
/// earlier: the profiler needed an out-of-band CGEvent scroll to get bars 5–9
/// back (profiles/logic_set_cycle_range.md §4 defect 4), and nothing in this
/// server's tool surface could do that. These are the decisions that recovery
/// makes; the posting and the readback are live.
enum RulerVisibility {

    /// Is the whole requested span inside the ruler, with `margin` bars of
    /// air at each edge so a drag that ends on the very last pixel is not
    /// counted as visible?
    static func isVisible(
        startX: CGFloat,
        endX: CGFloat,
        rulerMinX: CGFloat,
        rulerMaxX: CGFloat,
        margin: CGFloat
    ) -> Bool {
        startX >= rulerMinX + margin && endX <= rulerMaxX - margin
    }

    /// How far the ruler's CONTENT must move (positive = to the right, i.e.
    /// earlier bars come into view) for the span to be visible, or 0 when it
    /// already is.
    ///
    /// A span wider than the window can never fit; the shift then brings its
    /// START into view, because that is the edge every caller of this asks
    /// about first and the one the drag begins on.
    static func shiftToReveal(
        startX: CGFloat,
        endX: CGFloat,
        rulerMinX: CGFloat,
        rulerMaxX: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        if isVisible(startX: startX, endX: endX, rulerMinX: rulerMinX, rulerMaxX: rulerMaxX, margin: margin) {
            return 0
        }
        if startX < rulerMinX + margin { return (rulerMinX + margin) - startX }
        return (rulerMaxX - margin) - endX
    }
}

/// The pure arithmetic behind `setCycleRange`'s ruler mapping — how a bar
/// becomes a pixel, and how a failed write is judged to be back where it
/// started.
///
/// WHY MEASURING BEAT A FORMULA. The ruler publishes one average slope
/// (`pixelsPerBar`: the pixels between the Start and End markers over the bars
/// between them) and the tool used to place every write by extrapolating from
/// it. That is only true of a project that never changes meter. Logic's
/// timeline is linear in BEATS, not bars, so a 5/4 bar is a quarter wider than
/// a 4/4 one: on the sandbox project, which goes 4/4 → 5/4 at bar 41,
/// extrapolating ~38 bars from the anchor landed the start 0.67–0.89 bars out
/// (measured 2026-09-03, on the shipped binary and on its predecessor), and
/// the grid-snapped write would have missed the requested bar — so the tool
/// honestly refused instead, on a range that is perfectly reachable.
///
/// Walking the Signature List would fix the arithmetic for a meter change and
/// nothing else. Measuring fixes it for anything the ruler does: the tool
/// ALREADY parks the playhead on a bar to find out where a bar line is (that
/// is what the anchor is), and since the 2026-09-03 `convergeSlider` fix a
/// park costs ~1–2 ms per bar rather than ~125, so parking on the two bars the
/// call is actually about is cheap enough to prefer over any model. What is
/// left for arithmetic is here, and therefore unit-tested.
enum RulerBarMapping {

    /// How far BEFORE a bar line the acceptance window for that bar starts, as
    /// a fraction of the bar's own width.
    ///
    /// Not centred on the line, because the thing being placed in a bar is not
    /// centred either: Logic draws the cycle region's frame inset a constant
    /// few pixels to the RIGHT of its locator (MEASURED 2026-09-03, Logic Pro
    /// 12.3.1: 8 px, against bars 13.2 px wide in 4/4 and 17.0 px in 5/4 at the
    /// sandbox's resting zoom). So the region's own bar line sits a little to
    /// its left, most of a bar of room is needed to the right, and a couple of
    /// pixels of rounding slack to the left.
    static let anchorWindowLead: CGFloat = 0.15

    /// How far off a grid-snapped landing may be and still count as the
    /// requested bar. Inside half a bar, which is where Logic's own snapping
    /// tips over to the neighbour — and no tighter, because the question this
    /// answers is "which bar line", not "which pixel".
    ///
    /// It was 0.3 and that was too tight to be honest. MEASURED 2026-09-03:
    /// the region's frame inset is read at the ANCHOR bar and applied at the
    /// target, and a pixel or two of rounding between the two is 0.31 of a bar
    /// where a bar is 12.8 px wide — so a write that landed exactly on its bar
    /// line was reported as a miss, and the restore that put it back exactly
    /// was reported as having failed. A whole bar is still a whole bar away.
    static let landingToleranceBars: CGFloat = 0.45

    /// How many bars the cycle region sits away from the bar the playhead is
    /// parked on: 0 when the parked bar IS the region's bar, and otherwise the
    /// signed jump the search should take next.
    ///
    /// Two things this gets right that judging the gap against the ruler's
    /// average slope did not, both measured live on 2026-09-03:
    ///
    /// - **the bar's OWN width**, so a wider-than-average bar past a meter
    ///   change is one bar and not 1.27 of them;
    /// - **the window is not centred on the line**, so the region's constant
    ///   frame inset is not read as most of a bar of error. Judged the old
    ///   way, a region sitting exactly on bar 43 measured 0.60 average bars
    ///   from its own line — outside tolerance — and the search oscillated
    ///   between 43 and 44 until it gave up on a region it was looking
    ///   straight at.
    ///
    /// One step of the search, so it converges from any distance rather than
    /// only from the one bar the old ±1 retry could rescue.
    static func barsOff(gapPixels: CGFloat, localPixelsPerBar: CGFloat) -> Int {
        guard localPixelsPerBar > 1 else { return 0 }
        return Int(((gapPixels + localPixelsPerBar * anchorWindowLead) / localPixelsPerBar)
            .rounded(.down))
    }

    /// Pixels per bar across the span actually being written, from its two
    /// measured bar lines.
    static func localPixelsPerBar(startOffset: CGFloat, endOffset: CGFloat, bars: Int) -> CGFloat {
        guard bars > 0 else { return 0 }
        return (endOffset - startOffset) / CGFloat(bars)
    }

    /// Is a measured local slope believable next to the ruler's average one?
    ///
    /// The guard against a thumb that did not move, or a frame Logic clamped
    /// at the window edge: a real meter change scales a bar by a small ratio
    /// (4/4 → 5/4 is 1.25, 4/4 → 12/8 is 1.5), while a bad reading collapses
    /// the slope towards zero or inverts it. Anything outside a factor of 2.5
    /// either way is treated as unmeasured, and the caller falls back to the
    /// average slope and says so.
    static func isPlausibleSlope(local: CGFloat, average: CGFloat) -> Bool {
        guard average > 0, local > 1 else { return false }
        return local >= average / 2.5 && local <= average * 2.5
    }

    /// How many bars a measured x sits from where a model predicted it.
    static func errorBars(measured: CGFloat, extrapolated: CGFloat, pixelsPerBar: CGFloat) -> Double {
        guard pixelsPerBar > 0 else { return 0 }
        return Double((measured - extrapolated) / pixelsPerBar)
    }

    /// Which bar an offset from the anchor's bar line falls on — for saying
    /// where a range was left when it could not be put back.
    static func barAt(offset: CGFloat, anchorOffset: CGFloat, anchorBar: Int, pixelsPerBar: CGFloat) -> Int {
        guard pixelsPerBar > 0 else { return anchorBar }
        return max(1, anchorBar + Int(((offset - anchorOffset) / pixelsPerBar).rounded()))
    }

    /// Is the cycle region back at the position AND the length it was found
    /// at? A length that could not be read is never called a match: "we could
    /// not tell" must not report itself as `restored: true`.
    static func isSameRange(
        offset: CGFloat?, originalOffset: CGFloat,
        length: Int?, originalLength: Int?,
        pixelsPerBar: CGFloat
    ) -> Bool {
        guard let offset, let length, let originalLength, pixelsPerBar > 0 else { return false }
        return length == originalLength
            && abs(offset - originalOffset) <= pixelsPerBar * landingToleranceBars
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
