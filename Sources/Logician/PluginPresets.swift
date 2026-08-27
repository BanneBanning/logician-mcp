import Foundation

// Reading a plugin's SETTING menu — the popup in the plugin window header that
// Logic calls "Setting" and everyone else calls the preset menu.
//
// Everything in this file is PURE: it takes the shape of the menu as
// Accessibility handed it over and answers questions about it. The
// Accessibility side lives in `AXPresets.swift`, the tool side in
// `ToolHandlersPlugins.swift`.
//
// The menu's shape, read off five real plugins on 2026-08-27 (Compressor,
// Channel EQ, Limiter, Sensor, PShft, plus third-party Trilian), is the same
// every time: a FIXED command block of 20 items, then the settings.
//
//     [0]  "Setting"          disabled header
//     [1]  ""                 separator
//     [2]  "Undo"             [3] "Redo"
//     [4]  "Include Plug-in Undo Steps in Project Undo History"
//     [5]  ""                 separator
//     [6]  "Next"             [7] "Previous"
//     [8]  ""                 separator
//     [9]  "Copy"             [10] "Paste"
//     [11] ""                 separator
//     [12] "Load…"  [13] "Save"  [14] "Save As…"  [15] "Save A Copy As…"
//     [16] "Save As Default"   [17] "Recall Default"  [18] "Delete"
//     [19] ""                 separator
//     [20…] the settings — either FLAT leaves (Limiter: 11) or CATEGORY
//           submenus (Compressor: 6 categories / 156 settings, Channel EQ:
//           7 / 114). Nothing after [19] at all when the plugin ships no
//           factory settings (Sensor, Trilian).
//
// The active setting carries `AXMenuItemMarkChar` "✓" on its leaf, and its
// category carries "-" — so the mark is also the trail to which category the
// current setting came from.

/// One item of a preset menu as Accessibility described it. A leaf has no
/// `children`; a category's children are its submenu's items.
///
/// This is the boundary type: `AXPresets.swift` builds it out of AXUIElements,
/// and everything below here is testable without Logic.
struct PresetMenuItem: Equatable {
    let title: String
    let markChar: String
    let enabled: Bool
    let children: [PresetMenuItem]

    init(title: String, markChar: String = "", enabled: Bool = true, children: [PresetMenuItem] = []) {
        self.title = title
        self.markChar = markChar
        self.enabled = enabled
        self.children = children
    }

    /// A separator: Logic paints those as menu items with no title, disabled.
    var isSeparator: Bool { title.isEmpty }
}

/// One selectable setting, with the category it lives under.
struct PresetEntry: Equatable {
    let name: String
    /// The submenu the setting lives in, nil when the plugin lists its
    /// settings flat (Limiter does).
    let category: String?
    /// True when Logic marked this leaf as the one currently loaded.
    let active: Bool

    /// How a caller names this setting unambiguously.
    var qualifiedName: String {
        guard let category else { return name }
        return category + "/" + name
    }

    var dictionary: [String: Any] {
        var entry: [String: Any] = ["name": name, "active": active]
        entry["category"] = category.map { $0 as Any } ?? NSNull() as Any
        return entry
    }
}

/// The command block above the settings is fixed, English, and the same in
/// every plugin's menu. `Delete` is its last entry, which makes it the anchor.
let presetMenuCommandTitles: Set<String> = [
    "setting", "undo", "redo",
    "include plug-in undo steps in project undo history",
    "next", "previous", "copy", "paste",
    "load…", "load...", "save", "save as…", "save as...",
    "save a copy as…", "save a copy as...",
    "save as default", "recall default", "delete"
]

/// Index of the first item that is a SETTING rather than a command.
///
/// Two rules, in order, because each covers the other's blind spot:
///
///  1. `Delete` is the last command in every observed menu — take the item
///     after it, skipping the separator(s) that follow. This is exact, and it
///     survives Logic adding a command in the middle of the block.
///  2. When `Delete` is absent (a Logic version that renamed it, or a
///     localized UI — see the parked localization item), fall back to the
///     structural rule: the command block is the only part of the menu with
///     separators in it, so the LAST separator ends it. Verified against all
///     six menus read on 2026-08-27, where both rules agree.
///
/// A menu with neither anchor is treated as all settings — the honest reading
/// of "no command block found", and a caller that gets `Undo` back in its
/// preset list will see something is wrong, which beats an empty list that
/// looks like "this plugin has no presets".
func presetRegionStart(_ items: [PresetMenuItem]) -> Int {
    if let deleteIndex = items.lastIndex(where: {
        $0.title.lowercased() == "delete"
    }) {
        var index = deleteIndex + 1
        while index < items.count && items[index].isSeparator { index += 1 }
        return index
    }
    if let lastSeparator = items.lastIndex(where: \.isSeparator) {
        return lastSeparator + 1
    }
    return 0
}

/// Every setting in the menu, categories flattened, in menu order.
///
/// Categories keep their names rather than being dropped, because a caller
/// that wants to jump to `Rock Bass` under `03 Guitars` needs the path, and
/// two categories of one plugin can hold settings with the same name.
func flattenPresetMenu(_ items: [PresetMenuItem]) -> [PresetEntry] {
    var entries: [PresetEntry] = []
    for item in items[presetRegionStart(items)...] {
        guard !item.isSeparator else { continue }
        if item.children.isEmpty {
            entries.append(PresetEntry(
                name: item.title, category: nil, active: !item.markChar.isEmpty
            ))
        } else {
            for leaf in item.children where !leaf.isSeparator {
                entries.append(PresetEntry(
                    name: leaf.title, category: item.title, active: !leaf.markChar.isEmpty
                ))
            }
        }
    }
    return entries
}

/// What matching a requested name against the menu produced.
enum PresetNameMatch: Equatable {
    case resolved(PresetEntry)
    /// The name appears under more than one category; the qualified paths say
    /// which, so the caller can retry with `Category/Name`.
    case ambiguous(paths: [String])
    case notFound(available: [String])
}

/// Finds the setting a caller asked for. Deliberately NOT fuzzy: loading the
/// wrong setting overwrites the plugin's parameters, and there is no undo the
/// server can promise (see `presetOverwriteWarning`), so a near miss must be a
/// question back to the agent rather than a guess.
///
/// Accepted forms: the bare setting name, or a qualified `Category/Name`
/// (`>` and ` - ` work too, since agents write menu paths several ways).
/// Matching is case- and diacritic-insensitive on both halves.
func matchPresetName(_ requested: String, in entries: [PresetEntry]) -> PresetNameMatch {
    let wanted = requested.trimmingCharacters(in: .whitespaces)
    func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // A qualified request pins the category, which is how an ambiguous name
    // gets resolved on the retry.
    for separator in ["/", ">", " - "] {
        guard let range = wanted.range(of: separator) else { continue }
        let category = String(wanted[wanted.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let leaf = String(wanted[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !category.isEmpty, !leaf.isEmpty else { continue }
        let hits = entries.filter { entry in
            same(entry.name, leaf) && entry.category.map { same($0, category) } == true
        }
        if hits.count == 1 { return .resolved(hits[0]) }
        if hits.count > 1 { return .ambiguous(paths: hits.map(\.qualifiedName)) }
        // A path that matches nothing falls through to the bare-name attempt
        // rather than failing here: a setting whose own name contains a slash
        // would otherwise be unreachable.
    }

    let hits = entries.filter { same($0.name, wanted) }
    if hits.count == 1 { return .resolved(hits[0]) }
    if hits.count > 1 { return .ambiguous(paths: hits.map(\.qualifiedName)) }
    return .notFound(available: entries.map(\.qualifiedName))
}

/// A readable sample of a long name list for an error message. A Compressor
/// offers 156 settings and a Channel EQ 114; pasting all of them into one
/// error string helps nobody, and the `list` action is right there.
func presetNameSample(_ names: [String], limit: Int = 12) -> String {
    guard names.count > limit else { return names.joined(separator: ", ") }
    return names.prefix(limit).joined(separator: ", ")
        + ", … (\(names.count - limit) more)"
}

/// The warning every preset CHANGE carries, whichever route made it.
///
/// Learned the hard way on 2026-08-27: a plugin whose header says
/// `FET Electric Bass` is not necessarily in that setting. Stepping away and
/// back restored the label and ten of eleven parameters — and left Output Gain
/// on the factory value instead of the value the project had. Loading a
/// setting means loading ALL of its parameters, so any unnamed tweak the user
/// made on top of a named setting is gone, and selecting the old name back
/// does not bring it back. Logic's own Compare button did not warn: it was
/// disabled (its "unmodified" state) while the deviation existed.
let presetOverwriteWarning =
    "Loading a plugin setting overwrites every parameter of the plugin. A setting NAME is not"
    + " a promise about the current state: unnamed tweaks made on top of a named setting are"
    + " lost, and re-selecting the previous name does NOT bring them back (verified"
    + " 2026-08-27 — one of eleven Compressor parameters did not return). Logic's Compare"
    + " button is not a reliable modified-indicator across sessions. To get back, call this"
    + " tool again with action 'undo' — the setting menu's own Undo, which restores the"
    + " parameter STATE (verified 2026-08-28: it brought back all eight of a Limiter's"
    + " parameters exactly, from a named setting to the unnamed state it started in)."

/// The setting menu's own Undo item. Index 2 of the fixed 20-entry command
/// block every observed plugin's setting menu opens with, but matched by
/// TITLE, not index: the block is stable across six plugins and two Logic
/// versions, and an index would break silently if Logic ever adds a command.
let presetUndoItemTitle = "Undo"

/// Why a preset list could not be produced. Kept as a type so every refusal
/// names the same reasons the same way.
enum PresetMenuFailure: Equatable {
    /// No AXPress-only popup in the window header — a fully custom plugin UI
    /// that hosts its own preset control instead of Logic's.
    case noPresetPopUp
    /// The popup is there, but pressing it produced no menu.
    case menuDidNotOpen

    var reason: String {
        switch self {
        case .noPresetPopUp:
            return "the plugin window header exposes no Logic setting pop-up through Accessibility"
                + " (a fully custom plugin UI); its preset names cannot be read, and relative"
                + " stepping (action 'step') is the only route left"
        case .menuDidNotOpen:
            return "the setting pop-up is there but its menu did not open through Accessibility"
                + " within the timeout; nothing was changed"
        }
    }
}
