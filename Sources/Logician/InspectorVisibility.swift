import AppKit
import ApplicationServices
import Foundation

// Logic's Inspector can be HIDDEN, and that is ordinary user state — View >
// Inspector, or the `I` key, and it stays hidden until the user presses it
// again. Every Accessibility-plane track tool in this server was written
// against an Inspector that is showing.
//
// MEASURED 2026-09-03 on the sandbox, Inspector hidden:
//
//     logic_select_track {Bas}   -> 15.7 s, verification_failed,
//                                  "Requested 'Bas', selection is 'Track 2 “Bas”'"
//     logic_track_info  {Bas}    -> 29.9 s, same cause
//     logic_record_automation    -> "Logic's inspector never showed a channel strip"
//
// The selection had LANDED in every one of those. What failed was the
// readback: `verifySelection` cross-checks the header row against the left
// inspector channel strip, a strip that does not exist while the Inspector is
// hidden, so `pollTrackSelected` ran its whole 20-look budget, the Has Focus
// fallback ran it again, and the refusal named the very row it had just
// selected. Three tree walks per look made each of those looks cost ~350 ms
// rather than the 100 ms the sleep suggests.
//
// Two facts do the repairing. First, "no inspector strip at all" is a
// DIFFERENT state from "the inspector shows another track", and only the
// second one is evidence against a selection — `InspectorReadback` already
// trusts the header row's own `AXDescription` when the two planes disagree
// after a rename, and a hidden Inspector is the same argument with less to
// argue about: there is no second plane to disagree. Second, the state is
// free to detect: the strips walk the readback already pays answers it, so
// nothing here adds a read.
//
// AFTER, same session, same sandbox, same Inspector-hidden state:
//
//     logic_select_track    ->    471 /  599 /  263 ms, state "selected"
//     logic_track_info      ->  1 172 / 1 132 ms, full strip payload,
//                               byte-identical to the Inspector-shown read
//     logic_rename_track    ->    313 + 281 ms round trip
//     logic_list_inserts    ->  1 013 ms, the real four-insert chain
//
// and with the Inspector SHOWN nothing moved: 241 / 613 / 276 ms against the
// old build's 241 / 618 / 266, track_info 178 / 191 against 160 / 163.
//
// THE REGION INSPECTOR joined them on 2026-09-03, and it needed two things
// the track family did not. Its plane is the PANE, not a channel strip (see
// `InspectorEvidence`), and its Region panel is deliberately left OPEN across
// calls (`AXRegionInspector.InspectorDebt`) — a debt that cannot survive a
// pane this call is about to press away, so it is settled first. Measured the
// same session, Inspector hidden, sandbox "Testlåt Copy":
//
//     logic_get_region_params  ->  refused in 458 / 314 ms
//                              ->  1 495 / 1 081 ms, full rows
//     logic_set_region_params  ->  refused in 334 / 324 ms
//                              ->  1 473 / 1 524 ms, verified write + restore
//     logic_rename_region      ->  refused in 349 ms
//                              ->  912 + 877 ms round trip, verified
//
// with the Inspector SHOWN unchanged: 776 / 258 / 756 / 683 / 553 / 392 ms
// against the old build's 642 / 338 / 743 / 777 / 498 / 472, and the
// disclosure deferral untouched (`panel_state.restore: "deferred"`, closed at
// shutdown). Logic REMEMBERS the disclosure across a hide: a panel left open,
// hidden and shown again read back "already open", which is why leaving that
// debt standing behind a hidden Inspector would have been a permanent
// invisible change rather than a saving.

/// What Logic's inspector plane was able to say, this call.
///
/// Reported on tool results as `inspector`, so an agent that gets a
/// header-only verification (or a strip it could not have) can see WHY without
/// guessing.
enum InspectorPresence: String, Equatable {
    /// At least one inspector channel strip is published. The pre-existing
    /// world: the readback has two planes.
    case shown
    /// The project window is readable and publishes NO inspector channel
    /// strip. Logic's Inspector is hidden (View > Inspector), or its channel
    /// strip section is collapsed — from Accessibility the two are the same
    /// fact, and the way out of both is the same menu item.
    case hidden
    /// The question could not be asked: no project window, no Accessibility
    /// trust. Never reported as `hidden`, which would read as "the user hid
    /// it" for a plane that was never reachable.
    case unavailable

    /// The verdict, from a strips walk that either happened or did not.
    /// `nil` means the walk itself failed. Pure, so the three-way distinction
    /// is tested without an inspector.
    static func verdict(stripNames: [String]?) -> InspectorPresence {
        guard let names = stripNames else { return .unavailable }
        return names.isEmpty ? .hidden : .shown
    }

    /// The same verdict for a reader of the INSPECTOR PANE rather than of a
    /// channel strip — the Region inspector's question. `nil` means the
    /// project window itself could not be read.
    ///
    /// A pane that is on screen with its Channel Strip section collapsed
    /// answers `shown` here and `hidden` to `verdict(stripNames:)`, and both
    /// are right: the Region panel is reachable and no strip is. That is why
    /// the two questions are asked separately rather than one being derived
    /// from the other — see `InspectorEvidence`.
    static func verdict(inspectorPanePublished: Bool?) -> InspectorPresence {
        guard let published = inspectorPanePublished else { return .unavailable }
        return published ? .shown : .hidden
    }
}

/// What "the Inspector is showing" MEANS to the caller that needs it.
///
/// One pane, two planes this server reads out of it, and they fail
/// independently: a track tool needs a channel STRIP, and the Region
/// inspector needs the PANE (its Region panel is published whenever the pane
/// is, collapsed triangle and all). Asking the strips question on the Region
/// path would read a collapsed Channel Strip section as a hidden Inspector
/// and press `View > Inspector` at a pane that is already open — hiding it,
/// which is the one outcome worse than refusing.
///
/// It is also what a RESTORE is confirmed against: the press back is only
/// believed once the same probe that proved the show says the pane is gone.
enum InspectorEvidence: String, Equatable {
    /// At least one inspector channel strip is published.
    case channelStrip
    /// The Inspector pane itself is published, whatever its panels are doing.
    case inspectorPane
}

/// Logic's Inspector, held open across ONE tool call.
///
/// Two jobs, and it decides neither on its own. It REMEMBERS what the first
/// inspector walk of this call saw, so the result can report the state the
/// call found rather than the state the call left behind. And it books the
/// one show/hide a call is allowed to perform: a tool that genuinely needs a
/// channel strip (its payload IS the strip — `logic_track_info`, the routing
/// and insert writes, an automation pass that can only confirm a mode press
/// off the strip's own label) shows the Inspector for the call and puts it
/// back on the way out.
///
/// Per-call, like `ListEditorsPaneHold` and for the same reason: an Inspector
/// left standing narrows the arrangement area, and a performance debt that
/// changes what another reader can see is not a debt, it is a bug. The show is
/// also LAZY — nothing is pressed until a strip is actually asked for and
/// missing — so a call against a showing Inspector pays exactly nothing, and a
/// call that never wanted a strip presses nothing whatever the Inspector is
/// doing.
///
/// One attempt per call. A press that does not produce a strip is undone and
/// not retried: the alternative is a tool that drums on Logic's View menu.
/// (Single-threaded server loop, like `MCUController.surfaceDebt`.)
final class InspectorHold {
    /// What the FIRST inspector walk of this call saw. Later walks do not
    /// overwrite it — after this hold shows the Inspector they would all say
    /// `shown`, and the honest answer to "what was the Inspector doing" is the
    /// one the call arrived to.
    private(set) var observed: InspectorPresence?
    /// This call has already pressed View > Inspector once.
    private(set) var attempted = false
    /// …and it worked, so this call owes a press back.
    private(set) var openedByUs = false
    /// Which plane proved the show, and therefore which plane has to say the
    /// pane is gone again before the restore is believed.
    private(set) var shownFor: InspectorEvidence?
    /// Whether that press back was confirmed. `nil` until it is owed.
    private(set) var restored: Bool?
    /// Why Logic itself refused a press, when it did. Published as
    /// `inspector_note`, because "the Inspector is standing open" is a state
    /// the user can fix once they are told what is holding it.
    private(set) var obstacle: String?

    init() {}

    func observe(_ presence: InspectorPresence) {
        if observed == nil { observed = presence }
    }

    func noteAttempt() { attempted = true }
    func noteOpened(for evidence: InspectorEvidence) {
        openedByUs = true
        shownFor = evidence
    }
    func noteRestored(_ confirmed: Bool) { restored = confirmed }
    /// First obstacle only: the press back that follows a failed press would
    /// otherwise overwrite the reason the first one failed.
    func noteObstacle(_ text: String) { if obstacle == nil { obstacle = text } }

    /// What a tool result says about the Inspector. Empty when this call never
    /// looked at the inspector plane at all — a field that is absent means the
    /// question was not asked, never that the answer was `shown`.
    var resultFields: [String: Any] {
        guard let observed else { return [:] }
        var fields: [String: Any] = ["inspector": observed.rawValue]
        if let obstacle { fields["inspector_note"] = obstacle }
        guard openedByUs else { return fields }
        fields["inspector_shown_for_call"] = true
        fields["inspector_restored"] = restored ?? false
        return fields
    }
}

extension LogicAccessibility {

    /// How long Logic is given to paint a channel strip after View > Inspector
    /// is pressed. Look-first: the loop reads before it sleeps, and each look
    /// is itself a ~120 ms strips walk, so the budget is looks rather than
    /// milliseconds. Twelve spans ~1.5 s of looking, well past the repaint
    /// measured on the sandbox (the first or second look, every time).
    static let inspectorRepaintLooks = 12
    static let inspectorRepaintGap: TimeInterval = 0.05

    /// The presence, from a walk taken now. Only for callers that have no
    /// strips list in hand — everything on the verification path gets this
    /// answer as a by-product of a walk it was paying anyway.
    func inspectorPresence() -> InspectorPresence {
        InspectorPresence.verdict(stripNames: (try? inspectorStrips())?.map(\.name))
    }

    /// Is the plane this caller needs on screen right now? One read, and it is
    /// the read the caller was going to take anyway.
    func inspectorIsShowing(_ evidence: InspectorEvidence) -> Bool {
        switch evidence {
        case .channelStrip: return !(((try? inspectorStrips()) ?? []).isEmpty)
        case .inspectorPane: return inspectorPaneGroup() != nil
        }
    }

    /// Presses `View > Inspector`, which is a toggle, so this is both the show
    /// and the hide.
    ///
    /// **Logic has to be FRONTMOST.** Measured live 2026-09-03 on the sandbox:
    /// pressed while Logic was in the background the item answered `.success`
    /// and DID NOTHING — three presses (two from this code, one from a System
    /// Events click for a control) left the Inspector hidden and the strips
    /// walk empty every time, and the same press with Logic frontmost showed
    /// it on the first try. That is the failure `pressMenuItem`'s own
    /// documentation describes, so the fix belongs here rather than in a
    /// settle budget: get Logic to the front first, and if that is impossible,
    /// do not press at all. Free when Logic already is frontmost
    /// (`ensureLogicFrontmost` returns on its first check).
    ///
    /// Returns false when the item could not be pressed at all — including
    /// when Logic has GREYED IT OUT, which it answers `.success` to and
    /// ignores. A refused press records WHY on the hold, so the result can say
    /// it instead of publishing a bare `inspector_restored: false`.
    private func pressInspectorMenuItem() -> Bool {
        guard (try? ensureLogicFrontmost(for: "showing Logic's Inspector")) != nil else {
            return false
        }
        keyProjectWindowForInspectorPress()
        do {
            try pressMenuItem(
                containing: LogicUIStrings.Menu.inspector,
                underMenu: LogicUIStrings.Menu.view,
                requireEnabled: true
            )
            return true
        } catch {
            inspectorHold?.noteObstacle(
                error.localizedDescription
                    + " MEASURED CAUSE (2026-09-03): Logic disables View > Inspector while a"
                    + " PLUG-IN window is its key window, and a plug-in window keeps that"
                    + " status even when Accessibility reports the project window as focused."
                    + " Close the plug-in window (logic_close_plugin) and the Inspector can be"
                    + " shown or hidden again, or press I in Logic."
            )
            return false
        }
    }

    /// Makes Logic's PROJECT window its key window, so the `View > Inspector`
    /// press that follows is not greyed out. Unconditional and cheap: an
    /// `AXRaise` plus one attribute write, both no-ops for the window that
    /// already has it.
    ///
    /// WHY, measured live 2026-09-03 on the sandbox — this is the
    /// `logic_survey_plugins` §7 defect, and the mechanism is NOT the one that
    /// profile suspected. `logic_open_plugin` against a hidden Inspector came
    /// back `inspector_shown_for_call: true`, `inspector_restored: false`, and
    /// left the Inspector standing open. Reproduced here, then probed: with
    /// the plug-in window open, `View > Inspector` read **`AXEnabled 0`** and
    /// a plain System Events click on it did nothing either — while
    /// `AXFocusedWindow` and `AXMainWindow` BOTH named the project window.
    /// Accessibility's idea of the focused window and Logic's idea of its key
    /// window had come apart, so no comparison of the two could have caught
    /// it; what fixed it was performing `AXRaise` on the project window and
    /// setting its `AXMain`, after which the same item read `AXEnabled 1`
    /// immediately.
    ///
    /// Nothing is handed back afterwards, deliberately: there is no reliable
    /// reading of which window Logic considered key (that is the very fact
    /// that lied), and Logic's plug-in windows float above the document
    /// window, so raising the project window under one does not hide it.
    private func keyProjectWindowForInspectorPress() {
        guard let project = try? projectWindow() else { return }
        _ = AXUIElementPerformAction(project, "AXRaise" as CFString)
        AXUIElementSetAttributeValue(project, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Shows Logic's Inspector for the rest of this tool call, once, when a
    /// channel strip is needed and none is published.
    ///
    /// Returns true only when a strip is published afterwards — the caller's
    /// question, not "was a menu item pressed". A press that produced no strip
    /// is PRESSED BACK before this returns: `View > Inspector` is a toggle, so
    /// the press is its own undo, and leaving a stray pane open because a
    /// fragment matched the wrong item is the one failure this can cause on
    /// its own.
    /// - Parameter evidence: which plane has to appear for this to count as a
    ///   show — a channel strip for the track family, the pane itself for the
    ///   Region inspector. See `InspectorEvidence`.
    @discardableResult
    func showInspectorForThisCall(evidence: InspectorEvidence = .channelStrip) -> Bool {
        guard let hold = inspectorHold, !hold.attempted else { return false }
        hold.noteAttempt()
        guard pressInspectorMenuItem() else { return false }
        for attempt in 0..<Self.inspectorRepaintLooks {
            if lookFirstShouldSleep(attempt: attempt) {
                Thread.sleep(forTimeInterval: Self.inspectorRepaintGap)
            }
            if inspectorIsShowing(evidence) {
                hold.noteOpened(for: evidence)
                return true
            }
        }
        _ = pressInspectorMenuItem()
        return false
    }

    /// Puts the Inspector back, if this call is the one that showed it. A
    /// no-op for a call that found it showing, which is the common case and
    /// pays nothing.
    func restoreInspectorAfterCall() {
        guard let hold = inspectorHold, hold.openedByUs else { return }
        // The same plane that proved the show has to say it is gone.
        let evidence = hold.shownFor ?? .channelStrip
        guard pressInspectorMenuItem() else {
            hold.noteRestored(false)
            return
        }
        // Confirmed, not assumed: `inspector_restored: false` in the result is
        // how the user finds out their Inspector is standing open, and a
        // trusted press cannot say that.
        for attempt in 0..<Self.inspectorRepaintLooks {
            if lookFirstShouldSleep(attempt: attempt) {
                Thread.sleep(forTimeInterval: Self.inspectorRepaintGap)
            }
            if !inspectorIsShowing(evidence) {
                hold.noteRestored(true)
                return
            }
        }
        hold.noteRestored(false)
    }

    /// The refusal a call has earned when it needs a channel strip, the
    /// Inspector publishes none, and showing it did not work. Named the way
    /// out, in Logic's own words. Pure so the sentence is tested.
    static func hiddenInspectorRefusal(
        requested: String, showAttempted: Bool
    ) -> LogicianError {
        LogicianError.trackNotExposed(
            requested: requested,
            exposed: "Logic's Inspector is publishing no channel strip at all, so there is"
                + " nothing on this plane to read"
                + (showAttempted
                    ? " — this call pressed View > Inspector to show it (which needs Logic"
                        + " frontmost) and no strip appeared."
                    : ".")
                + " Show it in Logic (View > Inspector, or the I key) and call again;"
                + " if it is already showing, its Channel Strip section is collapsed."
                + " Nothing was read or written."
        )
    }

    /// The same refusal for the Region inspector, which needs the PANE rather
    /// than a channel strip and so cannot say anything about a collapsed
    /// Channel Strip section. Pure, so the sentence is tested.
    ///
    /// Under a second, always: the panel read that discovers this state is one
    /// depth-8 walk, and the one press it is allowed to try is bounded by
    /// `inspectorRepaintLooks`. Nothing here polls a selection.
    static func hiddenInspectorRegionRefusal(showAttempted: Bool) -> LogicianError {
        LogicianError.trackNotExposed(
            requested: "the Region inspector",
            exposed: "Logic is publishing no Inspector pane at all, so the 'Region:' panel"
                + " this reads is not on screen"
                + (showAttempted
                    ? " — this call pressed View > Inspector to show it (which needs Logic"
                        + " frontmost) and the pane did not appear."
                    : ".")
                + " Show it in Logic (View > Inspector, or the I key) and call again."
                + " Nothing was read or written."
        )
    }
}
