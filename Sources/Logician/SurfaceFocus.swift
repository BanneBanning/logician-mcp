import Foundation
import LogicMCUBridge

// Logic's focused CHANNEL versus the selected TRACK HEADER.
//
// They are two different selections. Selecting a track header moves the
// focused channel with it — but the reverse is not true: selecting a
// HEADERLESS strip (Stereo Out, an aux, a bus) on the control surface moves
// only the focused channel, and the track header that was selected before
// stays selected. Every control-surface follow-view (the plugin insert list,
// the plugin-edit pages, the send view) follows the FOCUSED CHANNEL.
//
// Observed live 2026-08-31: `logic_list_inserts {Stereo Out, mcu}` moved the
// focused channel to Stereo Out; a later `logic_list_inserts {Bas, mcu}` found
// Bas's track header still selected, took `selectTrack`'s `already_selected`
// fast path, and returned STEREO OUT's insert chain attributed to Bas with
// `verified: true` — and by the same path a write would have landed on the
// wrong plugin. So the fast path's premise ("header selected" implies "channel
// focused") has to be checked, and this file is where that knowledge lives.
extension MCUController {

    /// The strip this process last PROVED Logic's focused channel to be on —
    /// set only after verified selections (an Accessibility track selection
    /// that actually moved, or an LCD/LED-verified surface select), cleared
    /// whenever a selection moves without that proof. Scoped to the project it
    /// was proven in, because a project switch rebuilds every selection.
    ///
    /// Like `surfaceDebt`, this is bookkeeping about what this process did,
    /// not a mirror of Logic: the live probe in `currentFocusVerdict` outranks
    /// it whenever the surface can actually be read. (Single-threaded server
    /// loop, like `hotEditView`.)
    struct ChannelFocus: Equatable {
        let strip: String
        let projectPath: String?
    }

    nonisolated(unsafe) static var knownChannelFocus: ChannelFocus? // single-threaded server loop

    static func noteChannelFocus(_ strip: String, projectPath: String?) {
        knownChannelFocus = ChannelFocus(strip: strip, projectPath: projectPath)
    }

    /// The record is cleared, never guessed at, when focus moves without a
    /// name attached — a raw channel select, or a track selection that failed
    /// halfway. "Unknown" keeps today's behaviour; a stale name would not.
    static func forgetChannelFocus() {
        knownChannelFocus = nil
    }

    /// What the two knowledge sources say about "is Logic's focused channel
    /// the strip the caller named?".
    enum FocusVerdict: Equatable {
        /// Proceed; `evidence` names what proved it.
        case agrees(evidence: String)
        /// The focused channel is a DIFFERENT strip — realign or refuse,
        /// never read through it. `from` names what the evidence showed.
        case diverged(from: String)
        /// No evidence either way. The header plane's own verification is all
        /// there is, which is exactly the pre-existing contract.
        case unknown
    }

    /// The live half of the question: in the pan-names view the selected
    /// strip's SELECT LED and its LCD name cell together name the focused
    /// channel, and that positive evidence outranks any record.
    ///
    /// Everything else is `unknown`, not a verdict: another assignment view
    /// names no channel, zero lit LEDs usually means the focused strip is
    /// outside the visible bank, several lit is an echo this project has only
    /// seen mid-transition, and a cell that is empty or part of a transient
    /// banner (the single-channel Pan view paints four or more `-` fields,
    /// the signature `settledTop` refuses) proves nothing about a name.
    static func focusProbeVerdict(
        requested: String,
        assignment: String?,
        lcdTop: String?,
        litStrips: [Int]
    ) -> FocusVerdict {
        guard assignment == MCULCDStrings.Assignment.pan,
              let top = lcdTop,
              litStrips.count == 1,
              let strip = litStrips.first else { return .unknown }
        let fields = lcdFields(top)
        guard fields.filter({ $0 == MCULCDStrings.clearingCell }).count < 4,
              fields.indices.contains(strip) else { return .unknown }
        let cell = fields[strip]
        guard !cell.isEmpty, cell != MCULCDStrings.clearingCell else { return .unknown }
        return lcdAbbreviationPlausible(track: requested, lcd: cell)
            ? .agrees(evidence: "mcu_select_led_lcd_name")
            : .diverged(from: cell)
    }

    /// The bookkeeping half: only a record proven in the SAME project says
    /// anything, and it says exactly which strip this process last verifiably
    /// pointed the focused channel at.
    static func focusRecordVerdict(
        requested: String,
        record: ChannelFocus?,
        projectPath: String?
    ) -> FocusVerdict {
        guard let record, record.projectPath == projectPath else { return .unknown }
        return record.strip == requested
            ? .agrees(evidence: "process_focus_record")
            : .diverged(from: record.strip)
    }

    /// Both sources, probe first, for the strip a tool is about to trust the
    /// surface's follow-views on. One bridge status read; the Accessibility
    /// project scan is only paid when the record has to be consulted.
    static func currentFocusVerdict(requested: String) -> FocusVerdict {
        let status = freshStatus()
        let probe = focusProbeVerdict(
            requested: requested,
            assignment: status?["assignment"] as? String,
            lcdTop: status?["lcd_top"] as? String,
            litStrips: status.map { selectedStrips(in: $0) } ?? []
        )
        if case .agrees = probe {
            // The live mirror outranks the record — a record that disagrees
            // with it is stale (the user reselected in Logic) and would force
            // a pointless realign on some later call when the probe happens
            // to be unreadable.
            if let record = knownChannelFocus, record.strip != requested {
                forgetChannelFocus()
            }
            return probe
        }
        if case .diverged = probe { return probe }
        return focusRecordVerdict(
            requested: requested,
            record: knownChannelFocus,
            projectPath: currentProjectPath()
        )
    }
}
