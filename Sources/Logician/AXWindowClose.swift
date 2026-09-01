import Foundation

// MARK: - What counts as proof that a window closed

/// The two answers a press on Logic's insert OPEN button can have. It is a
/// toggle — there is no separate close action — so the same press either
/// closes the plugin's window or opens one.
enum WindowToggleVerdict<Key: Hashable>: Equatable {
    /// A window the press was aimed at is no longer in the window list.
    case closed
    /// No aimed-at window went away, and a window that was not open before
    /// the press is open now: the plugin had not been open and the toggle
    /// opened it.
    case opened(Key)
}

/// True when at least one of `targets` is missing from `current`.
///
/// `targets` is deliberately NOT "everything that was open before the press".
/// Until 2026-09-01 both close paths asked the loose question — did ANY
/// member of the before-set go away? — while holding the identity of the
/// window they had actually aimed at. A press that silently failed while some
/// unrelated Logic window closed inside the same 2 s poll (a user dismissing
/// an alert, a floating window, a transient Logic retires) then returned
/// `success: true, verified: true, state: "closed"` about a window still on
/// screen. Neither profile provoked it — it needs a failed press AND a
/// concurrent close — but a false `verified` is the one kind of wrongness
/// this server does not ship, so callers now pass only the windows their
/// press could plausibly have closed.
///
/// `closePlugin` cannot narrow it to a single element (two plugin windows on
/// one track both take the track's name as their title), so its targets are
/// the title-matched windows and "one of them went away" is the strongest
/// true statement available to a toggle press.
func anyTargetWindowVanished<Key: Hashable>(targets: Set<Key>, current: Set<Key>) -> Bool {
    !targets.isSubset(of: current)
}

/// True when the exact window that was pressed is gone: its element has left
/// the window list AND no remaining window still carries its title.
///
/// The title half is not redundant. The element identity is what makes the
/// answer precise, but the `AXUIElement` references are Logic's to vend, and
/// a still-open window behind a freshly vended reference would read as "gone"
/// from the identity test alone. `closePluginWindow` resolved its window BY
/// title and refuses an ambiguous one before it presses, so exactly one
/// window carried that title a moment ago — it can afford the stricter
/// question, and over-reporting a close is the expensive direction.
func pressedWindowIsGone<Key: Hashable>(
    target: Key,
    title: String,
    current: [(key: Key, title: String)]
) -> Bool {
    !current.contains { $0.key == target || $0.title == title }
}

/// One tick of the toggle poll: both questions asked of the same window list,
/// so the loop ends the moment either is answered.
///
/// `closePlugin` used to run two loops in sequence — the full 2 s
/// disappearance wait, and only then the "did a window appear?" wait that hit
/// on its first look. MEASURED 2026-09-01: that made the not-open path
/// 2.63–2.79 s, of which 2.2 s was spent proving a negative that was already
/// known at ~60 ms. The predicates are mutually exclusive, so one loop under
/// the same deadline answers both.
///
/// `closed` is checked first on purpose: a close is the outcome the caller
/// asked for, and on a track with two plugin windows open a stray appearance
/// must never outrank the disappearance the press was aimed at.
func windowToggleVerdict<Key: Hashable>(
    targets: Set<Key>,
    before: Set<Key>,
    current: [Key]
) -> WindowToggleVerdict<Key>? {
    if anyTargetWindowVanished(targets: targets, current: Set(current)) {
        return .closed
    }
    if let appeared = current.first(where: { !before.contains($0) }) {
        return .opened(appeared)
    }
    return nil
}
