import Foundation

// The left inspector strip's name versus the selected track header's name.
//
// They agree, except after a rename. Logic repaints the track header the
// instant the name is written and does NOT repaint the left inspector channel
// strip's `AXDescription` while that track stays selected — so
// `inspectorStrip(named:)`, which compares that description with `==`, cannot
// find the strip of the track that was just renamed, and
// `trackSelectionVerified` fails for a selection that is perfectly correct.
//
// MEASURED 2026-09-02 (`logic_rename_track` profile §5 D1). Immediately after
// a verified `Inst 2` → `RenamedTrk1`:
//
//     logic_rename_track {track_name: "RenamedTrk1", new_name: "Inst 2"}
//     → 8 853 ms, verification_failed, "Requested 'RenamedTrk1', selection is
//       'Track 4 “RenamedTrk1”'. Restored previous selection: true."
//
// It refused while naming the very row it had been asked for, twice on
// unchanged state (8 853 / 8 948 ms), because `selectTrackReportingRows` lost
// its `already_selected` fast path, wrote a selection that was already made,
// ran `pollTrackSelected` to exhaustion, pressed *Has Focus*, ran it to
// exhaustion again and restored. The blast radius is every tool routed through
// `selectTrack` — delete, duplicate, set_track_stack, select_track itself,
// every plugin and strip tool that selects first — for as long as the renamed
// track stays selected. Moving the selection away and back repaired it
// (293 + 274 ms), which is the proof that the description, not the selection,
// was the stale thing.
//
// The readback is NOT dropped: it is the independent plane that catches a
// header claiming a selection the inspector does not show. What changes is
// that a name the inspector keeps painting after a rename is recognised as
// STALE instead of read as a different track — and only when the header row
// itself, which does repaint, carries the requested name.
enum InspectorReadback {

    /// A rename this process performed on the track that is still selected:
    /// the name the inspector will keep showing, and the name the track now
    /// has.
    ///
    /// The generic proof below (*"no row answers to that name any more"*)
    /// covers a rename from any source, including one done by hand in Logic.
    /// It cannot cover one case: renaming ONE of two rows that share a name
    /// leaves the other row still answering to the old name, so the inspector's
    /// stale text still matches a real track. That is exactly the state
    /// `logic_duplicate_track` manufactures and `logic_rename_track` is the
    /// only way out of, so this record makes the tolerance exact there.
    struct RenamedInPlace: Equatable {
        let was: String
        let now: String
    }

    enum Verdict: Equatable {
        /// The inspector shows the requested track. The pre-existing contract.
        case matches
        /// The inspector is showing a name the requested track used to have.
        case staleAfterRename(was: String)
        /// The inspector is showing a DIFFERENT, real track — the wrong-strip
        /// state the readback exists to catch. Refuse.
        case showsAnotherTrack(String)
        /// No inspector strip could be read at all, so this plane has nothing
        /// to say and the selection is not verified by it.
        case noStripVisible
    }

    /// - Parameters:
    ///   - requested: the name the caller addressed the track by.
    ///   - selectedHeaderName: the name on the header row that is selected,
    ///     read fresh. Case-sensitive, as `resolveTrack` is.
    ///   - inspectorName: the left inspector strip's `AXDescription`.
    ///   - renderedNames: every track name the header column is showing.
    ///   - renamedInPlace: what this process last renamed without the
    ///     selection moving since, if anything.
    static func verdict(
        requested: String,
        selectedHeaderName: String?,
        inspectorName: String?,
        renderedNames: [String],
        renamedInPlace: RenamedInPlace?
    ) -> Verdict {
        guard let shown = inspectorName, !shown.isEmpty else { return .noStripVisible }
        if shown == requested { return .matches }
        // The header row's own identity is what replaces the proof the stale
        // description can no longer give. Logic repaints it on the write, so a
        // selected row that does NOT carry the requested name is not the row
        // that was asked for and nothing here excuses the mismatch.
        guard selectedHeaderName == requested else { return .showsAnotherTrack(shown) }
        if let renamed = renamedInPlace, renamed.was == shown, renamed.now == requested {
            return .staleAfterRename(was: shown)
        }
        // A name no rendered row answers to is not another track; it is text
        // Logic has not repainted. An unreadable header column proves nothing
        // and must not be read as "no row has that name".
        guard !renderedNames.isEmpty else { return .showsAnotherTrack(shown) }
        return renderedNames.contains(shown) ? .showsAnotherTrack(shown) : .staleAfterRename(was: shown)
    }
}

extension LogicAccessibility {
    /// The rename this process performed on the still-selected track, if the
    /// selection has not moved since. Bookkeeping about what this process did,
    /// like `MCUController.knownChannelFocus` — never a mirror of Logic: it
    /// only ever widens `trackSelectionVerified` by one exact pair, and the
    /// live header read still has to carry the requested name.
    /// (Single-threaded server loop, like `hotEditView`.)
    nonisolated(unsafe) static var renamedInPlace: InspectorReadback.RenamedInPlace?

    static func noteRenamedInPlace(was: String, now: String) {
        renamedInPlace = InspectorReadback.RenamedInPlace(was: was, now: now)
    }

    /// A selection that actually MOVES repaints the inspector (measured: the
    /// select-away-and-back workaround), so the record has done its job and
    /// keeping it would only widen the readback for nothing.
    static func forgetRenamedInPlace() {
        renamedInPlace = nil
    }
}
