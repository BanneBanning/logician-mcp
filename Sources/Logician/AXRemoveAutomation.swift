import AppKit
import ApplicationServices
import Foundation

// MARK: - Taking an automation curve back off a track

// Automation was WRITE-ONLY-then-READABLE: `logic_record_automation` puts a
// curve on a lane, `logic_read_automation` samples it back, and nothing in the
// server could remove one. That was the last coverage gap the profiling
// campaign found (TOOL-OPTIMIZATION-LEDGER, record_automation profile
// 2026-09-02): a recorded pass could only be taken back with a blind Undo,
// which the house rules forbid, so every eval that rode a fader left the lane
// written for good.
//
// THE ROUTE, measured off Logic Pro 12.3.1's own menu bar 2026-09-03 (English,
// `Mix ▸ Delete Automation`, read through Accessibility with nothing pressed):
//
// | item | shortcut | what it deletes |
// |---|---|---|
// | `Delete Visible Automation on Selected Tracks` | ⌘⌃⌫ | the lane currently SHOWING |
// | `Delete All Automation on Selected Tracks` | ⇧⌘⌃⌫ | every lane on the selected rows |
// | `Delete Orphaned Automation on Selected Tracks` | ⇧⌃⌫ | lanes whose parameter is gone |
// | `Delete Redundant Automation Points` | ⌃⌫ | thins a curve, keeps it |
// | `Delete All Track Automation` | — | the WHOLE PROJECT |
//
// Only the second one is wired up here, and the reason is the verification
// rather than the mechanism:
//
// * **Visible** deletes whichever lane the track's automation view happens to
//   be showing, and with the automation view CLOSED — which is how the sandbox
//   sits, and how most projects sit — no track header publishes that
//   parameter at all. A delete whose target cannot be read before the press is
//   a delete that cannot be aimed, so `parameter`-scoped removal is REFUSED
//   here and names the alternative instead of guessing.
// * **All Track Automation** is the whole project, which no readback in this
//   server can prove afterwards. Refused, with the menu path named so a human
//   can do it deliberately.
// * **Redundant/Orphaned** change a curve rather than remove one; they are
//   different tools and are named in the refusals.
//
// TWO PRESS HAZARDS, both measured 2026-09-03 while proving this route:
//
// 1. **A menu press while Logic is not frontmost returns `.success` and does
//    NOTHING.** Toggling `Mix ▸ Show Automation` from the background, three of
//    six presses moved the item's ✓ and three did not, every one of them
//    answering `AXError 0`; with Logic activated first, every press landed. So
//    the press is preceded by `ensureLogicFrontmost` and followed by a
//    readback — the status code is not evidence.
// 2. A press on a LEAF menu item is cheap: 0 ms, three times over. It is the
//    press that OPENS a menu that sits out the messaging timeout (~1.5 s, the
//    plugin_preset finding), and this route never opens one.
//
// TWO MORE THINGS THE LIVE PROOF SETTLED (2026-09-03, sandbox):
//
// * **The menu item's enabled flag says nothing about whether there is
//   anything to delete.** `Delete All Automation on Selected Tracks` read
//   `enabled=1` with a track selected whose every lane had just been cleared
//   by this very tool. So there is no cheap "is there automation here" probe
//   on the menu plane, and the lane readback is the only evidence this tool
//   has — which is why it is taken twice.
// * **The delete leaves the fader where the automation last put it.** On
//   `Bas`, static -5.1 dB before the pass, the strip read **-2.9 dB** after
//   the automation was deleted — roughly the curve's last value, not the
//   value the track had before. So a removal can change what the track
//   SOUNDS like even though it removed rather than added; the result says so,
//   and `logic_set_track_volume` puts it back.

/// The pure half of `logic_remove_automation`: which scopes this route can
/// honestly serve, what a lane read PROVED, and what the two reads together
/// say about the press between them.
///
/// Pure because the whole tool is a compare-and-set whose "compare" is a
/// sampled reading with a documented blind spot — a flat reading is what an
/// unautomated lane and a flat curve both look like — and every decision that
/// rests on that blind spot should be testable without Logic running.
enum AutomationRemoval {

    // MARK: - Scope

    /// The scope this route serves, and the refusal for every scope it does
    /// not. Returns nil for the one that works.
    ///
    /// Each refusal names what to do instead, because "not supported" without
    /// an alternative just moves the problem to the caller.
    static func scopeRefusal(_ scope: String, parameterGiven: String?) -> String? {
        switch scope {
        case "track":
            return nil
        case "lane":
            return "scope 'lane' cannot be aimed from here, so it is refused rather than guessed"
                + " at. Logic's per-lane command is Mix > Delete Automation > Delete VISIBLE"
                + " Automation on Selected Tracks, and 'visible' means the lane the track's"
                + " automation view is showing — with the automation view closed no track header"
                + " publishes which lane that is, so the press could remove a lane nobody asked"
                + " about. Use scope 'track' to clear EVERY lane on the track (read the ones you"
                + " want to keep with logic_read_automation first and re-record them with"
                + " logic_record_automation), or open the automation view in Logic (Mix > Show"
                + " Automation), pick the lane, and press ⌘⌃⌫ there."
        case "range", "bars":
            return "a bar RANGE cannot be removed from here: Logic's Delete Automation commands"
                + " take a track, never a range, and this server has no automation-event editor."
                + " Two ways round it — logic_record_automation OVERWRITES the range it rides, so"
                + " riding the old value across those bars replaces the curve there; or use"
                + " scope 'track' to clear the track and re-record what you want to keep."
        case "project":
            return "scope 'project' is refused on purpose. Logic has the command (Mix > Delete"
                + " Automation > Delete All Track Automation) and it removes every curve in the"
                + " project at once, which no readback in this server can prove afterwards —"
                + " a tool that cannot verify what it destroyed should not be the one to destroy"
                + " it. Remove the tracks you mean one at a time with scope 'track', or press"
                + " that menu item in Logic yourself."
        default:
            return "scope must be 'track' (every automation lane on the addressed track)."
                + (parameterGiven.map {
                    " You asked for parameter '\($0)': that names the lane this call READS as"
                        + " its proof, not a lane it removes on its own."
                } ?? "")
        }
    }

    // MARK: - What one lane read proved

    /// A lane read reduced to the three things a removal verdict needs: how
    /// much of it was readable at all, and how far the readable values spread.
    struct LaneEvidence: Equatable {
        let sampled: Int
        let readable: Int
        let low: Double?
        let high: Double?

        /// nil when nothing was readable — deliberately not 0, which would
        /// read as "perfectly flat".
        var spread: Double? {
            guard let low, let high else { return nil }
            return high - low
        }

        /// Values that vary by more than `tolerance`: the lane is chasing
        /// something, which is the only positive proof of a curve this plane
        /// can produce.
        func isCurve(tolerance: Double) -> Bool {
            guard let spread else { return false }
            return spread > tolerance
        }

        /// Every readable value the same. NOT proof of an empty lane — see
        /// `flatCaveat` — which is why this never decides anything on its own.
        func isFlat(tolerance: Double) -> Bool {
            guard let spread else { return false }
            return spread <= tolerance
        }
    }

    static func evidence(values: [Double?]) -> LaneEvidence {
        let readable = values.compactMap { $0 }
        return LaneEvidence(
            sampled: values.count,
            readable: readable.count,
            low: readable.min(),
            high: readable.max()
        )
    }

    /// The sentence that keeps a flat reading honest. It is repeated in the
    /// `already_empty` result and in the forced-press warning because it is
    /// the one thing a caller must not forget about this tool's evidence.
    static let flatCaveat =
        "A FLAT reading is what an unautomated lane and a perfectly flat curve both look like"
            + " from here — logic_read_automation samples the value Logic chases to, not the"
            + " lane's breakpoints — and it says nothing at all about the track's OTHER lanes,"
            + " which this scope would also remove."

    // MARK: - Whether to press at all

    enum Decision: Equatable {
        /// Press the menu item.
        case press
        /// Do not press: the lane shows no curve, and a destructive press on
        /// no evidence is the wrong direction. Carries the note the result
        /// publishes.
        case alreadyEmpty(String)
        /// Do not press, and say why the evidence was not good enough.
        case refuse(String)
    }

    /// Read-before-write, with the doubt going to NOT pressing.
    ///
    /// `force` is the way past both no-press verdicts, and it exists because
    /// the flat reading is genuinely ambiguous: a track whose VOLUME lane is
    /// clean can still carry a pan or send curve, and the caller may know that
    /// when this tool cannot see it.
    static func decide(before: LaneEvidence, tolerance: Double, force: Bool) -> Decision {
        if force { return .press }
        if before.readable == 0 {
            return .refuse(
                "nothing was readable on the lane that would prove this removal — \(before.sampled)"
                    + " sampled position(s), \(before.readable) with a value — so there is no"
                    + " 'before' to compare an 'after' against and nothing was pressed. Check the"
                    + " lane with logic_read_automation first, or pass force: true to remove every"
                    + " automation lane on the track without that proof."
            )
        }
        if before.isCurve(tolerance: tolerance) { return .press }
        return .alreadyEmpty(
            "The sampled lane is flat, so nothing was pressed and no automation was removed."
                + " " + flatCaveat
                + " Pass force: true to remove every automation lane on the track anyway."
        )
    }

    // MARK: - What the two reads say about the press

    struct Verdict: Equatable {
        let state: String
        let verified: Bool
        let warning: String?
    }

    /// The compare half of compare-and-set. `forced` says the press went ahead
    /// without a curve to prove, which changes what a flat 'after' is worth:
    /// after a proven curve it is proof, after a flat 'before' it is nothing.
    static func verdict(
        before: LaneEvidence, after: LaneEvidence, tolerance: Double, forced: Bool
    ) -> Verdict {
        if after.readable == 0 {
            return Verdict(
                state: "removal_not_confirmed",
                verified: false,
                warning: "The menu item was pressed, but the lane read back with no readable"
                    + " value at all, so this call cannot say whether the automation is gone."
                    + " Read the lane with logic_read_automation before assuming either way."
            )
        }
        if after.isCurve(tolerance: tolerance) {
            return Verdict(
                state: "removal_not_confirmed",
                verified: false,
                warning: "The menu item was pressed and reported success, and the lane STILL"
                    + " reads a spread of \(String(format: "%.2f", after.spread ?? 0)) — the"
                    + " curve looks unchanged. A Logic menu press that lands while Logic is not"
                    + " frontmost answers success and does nothing (measured 2026-09-03), so the"
                    + " most likely reading is that nothing was deleted. Bring Logic to the front"
                    + " and call again."
            )
        }
        if before.isCurve(tolerance: tolerance) {
            return Verdict(state: "removed", verified: true, warning: nil)
        }
        return Verdict(
            state: "removed_unproven",
            verified: false,
            warning: "force was set, so the press went ahead without a curve to prove, and the"
                + " lane reads flat afterwards exactly as it did before. That is not evidence"
                + " either way. " + flatCaveat
        )
    }

    // MARK: - A dialog nobody expected

    /// Every unexpected modal is answered with Cancel and reported verbatim.
    ///
    /// Logic raised NO confirmation for this command in the live proof
    /// (2026-09-03, `Audio 9` and `Aux 1`: no dialog, sheet or floating window
    /// appeared within 600 ms of the press), so there is no recognised alert
    /// to press through — and a delete that meets an alert this code has never
    /// measured must not answer it. The texts travel back so the next version
    /// can recognise what this one refused.
    static func unknownDialogRefusal(titles: [String], texts: [String]) -> String {
        "Logic raised a dialog this server does not recognise after the Delete Automation press"
            + " — \(titles.isEmpty ? "no title" : titles.joined(separator: ", "))"
            + (texts.isEmpty ? "" : ": \"\(texts.joined(separator: " / "))\"")
            + ". It was CANCELLED rather than answered, so the removal may not have happened."
            + " Nothing else was pressed. Answer it in Logic and call again, or report this"
            + " dialog so the tool can learn it."
    }
}

extension LogicAccessibility {

    /// One menu item under `Mix`, found by title fragment, with its enabled
    /// state — the two things a refusal needs before a press is worth making.
    ///
    /// A local walk rather than `pressMenuItem`'s, for two reasons this route
    /// needs and that one does not offer: the ENABLED state is checked before
    /// the press (a greyed item answers `.success` too), and the whole
    /// `Mix ▸ Delete Automation` submenu was already built and readable with
    /// nothing pressed (measured 2026-09-03), so the press-the-parent-to-build
    /// dance the bounce path needs is not paid here.
    func automationMenuItem(containing fragment: String) throws -> (item: AXUIElement, enabled: Bool) {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else { throw LogicianError.logicNotRunning }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar = elementAttribute(appElement, kAXMenuBarAttribute as String) else {
            throw LogicianError.windowNotFound("menu bar")
        }
        var found: AXUIElement?
        func walk(_ element: AXUIElement, depth: Int, path: [String]) {
            guard depth <= AXDepth.menuBarItem, found == nil else { return }
            let title = stringAttribute(element, kAXTitleAttribute as String)
            if stringAttribute(element, kAXRoleAttribute as String) == "AXMenuItem",
               title.contains(fragment), path.contains(LogicUIStrings.Menu.mix) {
                found = element
                return
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1, path: title.isEmpty ? path : path + [title])
            }
        }
        walk(menuBar, depth: 0, path: [])
        guard let item = found else {
            throw LogicianError.windowNotFound(
                "the menu item '\(fragment)' under '\(LogicUIStrings.Menu.mix)'"
            )
        }
        return (item, stringAttribute(item, kAXEnabledAttribute as String) == "1")
    }

    /// The modal Logic has up RIGHT NOW, if any — one look, no waiting, the
    /// shape `trackDeletionAlertNow` established for the same reason: a
    /// negative proof is never worth a timeout of its own.
    func modalWindowNow() -> AXUIElement? {
        for window in (try? logicWindows()) ?? [] {
            let subrole = stringAttribute(window, kAXSubroleAttribute as String)
            if ["AXDialog", "AXSheet", "AXSystemDialog", "AXFloatingWindow"].contains(subrole) {
                return window
            }
        }
        return nil
    }

    /// Narrows the track selection to exactly one row.
    ///
    /// The menu items say "Selected **Tracks**", plural, and they mean it: a
    /// second selected row would have its automation deleted too, silently and
    /// unverifiably. `selectTrack` guarantees the target IS selected but not
    /// that it is ALONE — its `already_selected` fast path writes nothing at
    /// all — so this is the guard that stands between "clear this track" and
    /// "clear whatever else was selected".
    ///
    /// Returns the names of the rows that were deselected, so the result can
    /// say what it changed.
    func narrowSelectionToOneTrack(_ name: String, number: Int) throws -> [String] {
        let group = try trackHeaderGroup()
        let selected = parsedTrackHeaders(in: group).filter(\.selected)
        let others = selected.filter { $0.number != number }.map { "\($0.number): \($0.name)" }
        guard !others.isEmpty else { return [] }
        guard let target = parsedTrackHeaders(in: group).first(where: { $0.number == number }) else {
            throw LogicianError.trackNotFound(name, available: [])
        }
        let status = AXUIElementSetAttributeValue(
            group, "AXSelectedChildren" as CFString, [target.item] as CFArray
        )
        guard status == .success else {
            throw LogicianError.preconditionUnmet(
                "\(selected.count) track rows are selected (\(others.joined(separator: ", ")) as"
                    + " well as \(number): \(name)) and the selection could not be narrowed to one"
                    + " (AXError \(status.rawValue)). Logic's Delete Automation command acts on"
                    + " EVERY selected track, so nothing was pressed. Select only '\(name)' in"
                    + " Logic and call again."
            )
        }
        let landed = parsedTrackHeaders(in: try trackHeaderGroup()).filter(\.selected)
        guard landed.count == 1, landed[0].number == number else {
            throw LogicianError.preconditionUnmet(
                "the track selection could not be narrowed to '\(name)' alone — Logic still"
                    + " reports \(landed.count) selected row(s)"
                    + " (\(landed.map { "\($0.number): \($0.name)" }.joined(separator: ", ")))."
                    + " Delete Automation acts on every selected track, so nothing was pressed."
            )
        }
        return others
    }
}
