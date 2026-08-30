import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// Key commands learned onto the dedicated "Logic MCP Commands" MIDI port
/// (Key Commands window > Learn New Assignment). The registry file is the
/// consent record: only notes listed there may be triggered, because an
/// unlisted note could be bound to anything in the user's key command set.
enum KeyCommandRegistry {
    static var url: URL {
        MCUBridge.directory.appendingPathComponent("keycmd-registry.json")
    }

    static func commands() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]] else { return [] }
        return commands
    }

    static func entry(note: Int, channel: Int) -> [String: Any]? {
        commands().first {
            ($0["note"] as? Int) == note && (($0["channel"] as? Int) ?? 16) == channel
        }
    }

    static func note(named name: String) -> (note: Int, channel: Int)? {
        guard let hit = commands().first(where: {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }), let note = hit["note"] as? Int else { return nil }
        return (note, (hit["channel"] as? Int) ?? 16)
    }

    static func register(
        note: Int, channel: Int, name: String, notes: String,
        source: String = "logic_setup_key_commands", search: String? = nil
    ) {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["port": "Logic MCP Commands"]
        var commands = root["commands"] as? [[String: Any]] ?? []
        commands.removeAll {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date())
        // `learned` (the date) is kept exactly as it was so an existing
        // registry file keeps reading the same; `learned_at` and `source`
        // are the consent record G00 needs — WHO bound this and WHEN, to the
        // second, because an arbitrary command learned by an agent has to be
        // tellable apart from the product's own onboarding set.
        var entry: [String: Any] = [
            "note": note, "channel": channel, "name": name,
            "learned": String(stamp.prefix(10)),
            "learned_at": stamp,
            "source": source,
            "notes": notes
        ]
        if let search { entry["search"] = search }
        commands.append(entry)
        root["commands"] = commands
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    // MARK: - Notes for arbitrary (non-standard) commands

    /// Where `logic_learn_key_command` puts a command it was asked to learn.
    /// Deliberately BELOW the 100-121 block `standardCommands` prefers: an
    /// arbitrary command must never take a note one of the product's own
    /// tools is about to want, because the standard learn would then land on
    /// an alternate note and the two would be harder to tell apart in the
    /// user's own Key Commands window.
    static let learnableNoteRange = 60...99

    /// Every note this machine has already spoken for: what the registry
    /// holds, plus every note the standard set PREFERS (whether or not it has
    /// been learned yet — reserving them is the whole point).
    static func takenNotes() -> Set<Int> {
        var taken = Set(standardCommands.map(\.preferredNote))
        for entry in commands() {
            if let note = entry["note"] as? Int { taken.insert(note) }
        }
        return taken
    }

    /// The lowest free note for an arbitrary command: the 60-99 range first,
    /// then 122-127, then 21-59. Pure so the choice can be tested without a
    /// registry file. nil when all three ranges are full — 112 commands is far
    /// past anything real, and a wrong answer there would silently rebind
    /// something, so it refuses instead of wrapping.
    static func freeNote(taken: Set<Int>) -> Int? {
        let order = Array(learnableNoteRange) + Array(122...127) + Array(21...59)
        return order.first { !taken.contains($0) }
    }

    /// The Key Commands window's search field takes a substring of the row's
    /// name, so the first words of the name the caller gave are a search term
    /// that is correct BY CONSTRUCTION whenever the name is. Two words (three
    /// when the first two are very short) — broad enough that a near-miss name
    /// still puts its neighbours on screen, which is what the not_found answer
    /// reports back.
    static func defaultSearchTerm(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return name.lowercased() }
        var taken = Array(words.prefix(2))
        if taken.joined().count < 6, words.count >= 3 { taken = Array(words.prefix(3)) }
        return taken.joined(separator: " ").lowercased()
    }

    // MARK: - Names

    /// Every Logic key-command name this product spells, as a constant.
    ///
    /// These are rows in the user's Key Commands window, and Logic translates
    /// that window — so each one is a localization surface, and a caller that
    /// re-spelled a name inline was a leak that a Swedish pass would have had
    /// to find by grep. `resolveKeyCommand(named:)` matches the registry
    /// case-insensitively on exactly this string; `standardCommands` carries
    /// the matching search term, which the suite proves is a substring of the
    /// name, so a translated name and a stale search term cannot ship
    /// together silently.
    ///
    /// Per locale, re-measure: open Logic's Key Commands window and read the
    /// row. The English name is not always the menu item's text (`New Track
    /// with Duplicate Settings and Content` has no menu twin), so each one has
    /// to be read out of that window, not translated from the menu bar.
    ///
    /// # FRENCH (R4, 2026-08-30) — what was and was not established
    ///
    /// **Triggering an already-learned command still works, and this was
    /// PROVEN rather than argued.** With Logic's UI in French,
    /// `logic_trigger_key_command {name: "Rename Track"}` sent note 119 on
    /// channel 16 and Logic's `AXFocusedUIElement` changed from a control-bar
    /// button to an `AXTextField` holding the selected track's name — the
    /// inline rename editor, open and focused. The binding is a note, the
    /// registry holds the note, and Logic's MIDI-learn assignment does not
    /// care what language the window that made it was drawn in. All 22
    /// `standardCommands` still report `registered: true`.
    ///
    /// **Learning a NEW one by name is dead, and fails loudly:**
    /// `logic_learn_key_command` reports
    /// `menu item 'Edit Assignments' under 'Key Commands'` not found, because
    /// French spells those `Modifier les assignations…` under
    /// `Raccourcis clavier` (both captured — see `LogicUIStrings.Menu`).
    ///
    /// **The 28 French row names below are NOT captured.** Activating
    /// `Modifier les assignations…` by `AXPress` did not open the window in
    /// two attempts, so the rows could not be read. Note when someone does
    /// capture them: `standardCommands`' search TERMS are English substrings
    /// of these English names, so the two columns must be re-measured
    /// together — which the suite's substring check already enforces.
    enum Name {
        static let save = "Save"
        static let newSoftwareInstrumentTrack = "New Software Instrument Track"
        static let newAudioTrack = "New Audio Track"
        static let toggleTrackFreeze = "Toggle Track Freeze"
        static let undo = "Undo"
        static let redo = "Redo"
        static let flashbackCaptureAsRecording = "Flashback Capture as Recording"
        static let splitRegionsAtPlayhead = "Split Regions/Events at Playhead Position"
        static let cut = "Cut"
        static let copy = "Copy"
        static let paste = "Paste"
        static let delete = "Delete"
        static let nudgeRightByBar = "Nudge Region/Event Position Right by Bar"
        static let nudgeLeftByBar = "Nudge Region/Event Position Left by Bar"
        static let nudgeRightByBeat = "Nudge Region/Event Position Right by Beat"
        static let nudgeLeftByBeat = "Nudge Region/Event Position Left by Beat"
        static let duplicateTrack = "New Track with Duplicate Settings and Content"
        static let deleteTrack = "Delete Track"
        static let renameTrack = "Rename Track"
        static let nextPluginSetting = "Next Plug-in Setting for topmost Plug-in Window"
        static let previousPluginSetting = "Previous Plug-in Setting for topmost Plug-in Window"
        static let createMarker = "Create Marker"

        // MARK: Learned on demand (not in `standardCommands`)
        //
        // G00's opt-in path learns these on the spot rather than claiming a
        // reserved note for a command most sessions never fire. They are Key
        // Commands rows all the same, so they belong on the same translation
        // list.

        /// Note the trailing ellipsis — Logic's own character, not three dots.
        static let removeSilenceFromAudioRegion = "Remove Silence from Audio Region…"

        /// The five region-selection commands, spelled as Logic 12.3.1's Key
        /// Commands window shows them (read 2026-08-28). Two of them are not
        /// what anyone would guess from the menus, which is the whole reason
        /// they are written down rather than derived.
        static let selectAllRegionsOfSameTrack = "Select All Regions/Cells of Same Track"
        static let selectAllFollowing = "Select All Following"
        static let selectAllFollowingOfSameTrack = "Select All Following of Same Track/Pitch"
        static let selectAll = "Select All"
        static let deselectAll = "Deselect All"

        /// The translation list: every name above, in one array, so a
        /// localization pass has something to enumerate and the suite has
        /// something to check call sites against. Kept in the same order as
        /// the constants.
        static let all: [String] = [
            save, newSoftwareInstrumentTrack, newAudioTrack, toggleTrackFreeze,
            undo, redo, flashbackCaptureAsRecording, splitRegionsAtPlayhead,
            cut, copy, paste, delete,
            nudgeRightByBar, nudgeLeftByBar, nudgeRightByBeat, nudgeLeftByBeat,
            duplicateTrack, deleteTrack, renameTrack,
            nextPluginSetting, previousPluginSetting, createMarker,
            removeSilenceFromAudioRegion,
            selectAllRegionsOfSameTrack, selectAllFollowing,
            selectAllFollowingOfSameTrack, selectAll, deselectAll
        ]
    }

    /// The commands the product's tools rely on, with search terms for the
    /// Key Commands window and preferred (not guaranteed) note numbers —
    /// collisions on a user's machine get an alternate note automatically.
    static let standardCommands: [(search: String, name: String, preferredNote: Int)] = [
        ("save", Name.save, 105),
        ("new software instrument", Name.newSoftwareInstrumentTrack, 106),
        ("new audio track", Name.newAudioTrack, 107),
        ("toggle track freeze", Name.toggleTrackFreeze, 117),
        ("undo", Name.undo, 100),
        ("redo", Name.redo, 101),
        ("flashback", Name.flashbackCaptureAsRecording, 102),
        ("split regions/events", Name.splitRegionsAtPlayhead, 103),
        ("cut", Name.cut, 108),
        ("copy", Name.copy, 109),
        ("paste", Name.paste, 110),
        ("delete", Name.delete, 111),
        ("nudge region", Name.nudgeRightByBar, 112),
        ("nudge region", Name.nudgeLeftByBar, 113),
        ("nudge region", Name.nudgeRightByBeat, 114),
        ("nudge region", Name.nudgeLeftByBeat, 115),
        ("duplicate", Name.duplicateTrack, 116),
        ("delete track", Name.deleteTrack, 118),
        ("rename track", Name.renameTrack, 119),
        ("next plug-in", Name.nextPluginSetting, 120),
        ("previous plug-in", Name.previousPluginSetting, 121),
        ("create marker", Name.createMarker, 104)
    ]
}

