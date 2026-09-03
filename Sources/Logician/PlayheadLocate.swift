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
