import Foundation

// MARK: - What Logic's one plugin window per channel is SHOWING

/// Does a plugin name Logic DISPLAYS mean the plugin that was REQUESTED?
///
/// Logic truncates the names it paints in an insert slot ("Space D" for
/// "Space Designer", "Decapitato" for "Decapitator"), and the same plugin is
/// spelled at full length in the plugin window's header, so the two strings
/// that name one plugin routinely differ by a tail. A prefix relationship in
/// EITHER direction is therefore the match: the strip may be the truncated
/// side, or the request may be.
///
/// A free function rather than a method because the window-content decisions
/// below are pure and are tested without an Accessibility tree.
func pluginNamesMatch(_ displayed: String, _ requested: String) -> Bool {
    let lhs = displayed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let rhs = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !lhs.isEmpty, !rhs.isEmpty else { return false }
    return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
}

/// The plugin a Logic plugin-window header NAMES.
///
/// MEASURED live 2026-09-02 on track `808`: a plugin window publishes its
/// header as DIRECT CHILDREN of the window, and the last two of them are
/// `AXStaticText`s carrying the plugin's full name and then the channel's —
/// `Decapitator` / `808`, and after an in-place swap `Channel EQ` / `808`.
/// Both values are data (a plugin name, a track name), so this reads the same
/// on a Logic running in any language.
///
/// The rule is "the text immediately BEFORE the one that is the track name",
/// not "the text that is not the track name": Channel EQ publishes a third
/// static text, `View:`, earlier in the same list.
///
/// An empty answer means the window named nothing, and the callers fall back
/// to the window's shape. Two windows do that: one whose header the user has
/// hidden (the header has a Show/Hide button), and the INSTRUMENT slot's
/// window — `Q-Sampler`, measured live 2026-09-02, opened and swapped
/// correctly on the shape alone.
func pluginNameFromHeader(staticTexts: [String], trackName: String) -> String {
    guard let position = staticTexts.lastIndex(of: trackName), position > 0 else { return "" }
    return staticTexts[position - 1].trimmingCharacters(in: .whitespacesAndNewlines)
}

/// One window titled after the track, and what it says it is showing.
///
/// WHY THIS TYPE EXISTS. MEASURED live 2026-09-02, reproduced 3/3: Logic
/// reuses ONE plugin window per channel and swaps the plugin INTO it — the
/// same `AXUIElement`, the same title, the same place on screen. Opening
/// insert 2 while insert 1's window was up moved the window list not at all
/// (`before=2 now=2`), so `logic_open_plugin`, which verified by diffing that
/// list, spent 2.5 s proving nothing had happened and returned
/// `verification_failed` about a press that had WORKED — a false
/// `success: false` about a real change, which an agent can retry for ever.
/// What changed is INSIDE the window, so that is what is now read.
struct PluginWindowShowing<Key: Hashable>: Equatable {
    let key: Key
    /// The plugin name the window's header publishes; "" when it publishes
    /// none.
    let shows: String
    /// What the window publishes at a glance — its size and the roles and
    /// descriptions of its direct children, and deliberately nothing that
    /// carries a VALUE, so a moving meter or a stepped preset cannot make it
    /// look like a different plugin. This is the fallback evidence for a swap
    /// whose new plugin will not name itself: a changed shape is a changed
    /// plugin.
    let shape: [String]
}

/// Which of the channel's open windows is already showing `plugin` — the
/// question that turns `already_open` from a destructive round trip into a
/// read.
///
/// MEASURED 2026-09-02: the old code answered it by PRESSING the toggle
/// (closing the user's window in 8.7 ms), waiting out a 2.2 s poll for an
/// appearance that a look at 13 ms had already ruled out, pressing again and
/// polling again — 2 570 ms, with the window off the screen for 2.4 s of it.
/// The window list it needed was already in hand at 1.2–3.3 ms.
///
/// nil when two of the channel's windows both answer to the name: a window
/// showing one of two Channel EQs cannot say WHICH, and guessing there is the
/// difference between "already open" and closing the user's window.
func windowAlreadyShowing<Key: Hashable>(
    _ windows: [PluginWindowShowing<Key>], plugin: String
) -> Key? {
    let matching = windows.filter { pluginNamesMatch($0.shows, plugin) }
    guard matching.count == 1, let only = matching.first else { return nil }
    return only.key
}

/// How the tool knows the requested plugin's window is up.
enum PluginOpenVerdict<Key: Hashable>: Equatable {
    /// A window on this channel NAMES the plugin that was asked for. The
    /// strongest answer there is, and the one that sees an in-place swap.
    case showing(Key)
    /// A window that was not open before the press is open now.
    case appeared(Key)
    /// The channel's window is the same window publishing a different shape:
    /// the swap happened, and the window will not say into what.
    case changed(Key)
    /// The press toggled a window titled after the track SHUT — the plugin
    /// was already open and nothing readable said so.
    case closed
}

/// One tick of the open poll: every question asked of the same window list,
/// so the loop ends the moment any of them is answered.
///
/// `showing` is checked first because it is the outcome the caller asked for
/// AND the only one that can see Logic's in-place content swap; an appearance
/// comes next, and a title-matched appearance outranks any other window that
/// happened to open inside the poll. `closed` and `changed` are the two ways
/// a press can be accounted for when the window would not name itself.
func pluginOpenVerdict<Key: Hashable>(
    plugin: String,
    before: [PluginWindowShowing<Key>],
    allBefore: Set<Key>,
    now: [PluginWindowShowing<Key>],
    allNow: [Key]
) -> PluginOpenVerdict<Key>? {
    if let showing = windowAlreadyShowing(now, plugin: plugin) {
        return .showing(showing)
    }
    if let appeared = now.first(where: { !allBefore.contains($0.key) }) {
        return .appeared(appeared.key)
    }
    if let appeared = allNow.first(where: { !allBefore.contains($0) }) {
        return .appeared(appeared)
    }
    if anyTargetWindowVanished(targets: Set(before.map(\.key)), current: Set(allNow)) {
        return .closed
    }
    let shapeBefore = Dictionary(before.map { ($0.key, $0.shape) }, uniquingKeysWith: { first, _ in first })
    for window in now {
        guard let was = shapeBefore[window.key], was != window.shape else { continue }
        return .changed(window.key)
    }
    return nil
}
