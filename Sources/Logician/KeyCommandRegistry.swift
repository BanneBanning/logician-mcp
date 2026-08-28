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

    /// The commands the product's tools rely on, with search terms for the
    /// Key Commands window and preferred (not guaranteed) note numbers —
    /// collisions on a user's machine get an alternate note automatically.
    static let standardCommands: [(search: String, name: String, preferredNote: Int)] = [
        ("save", "Save", 105),
        ("new software instrument", "New Software Instrument Track", 106),
        ("new audio track", "New Audio Track", 107),
        ("toggle track freeze", "Toggle Track Freeze", 117),
        ("undo", "Undo", 100),
        ("redo", "Redo", 101),
        ("flashback", "Flashback Capture as Recording", 102),
        ("split regions/events", "Split Regions/Events at Playhead Position", 103),
        ("cut", "Cut", 108),
        ("copy", "Copy", 109),
        ("paste", "Paste", 110),
        ("delete", "Delete", 111),
        ("nudge region", "Nudge Region/Event Position Right by Bar", 112),
        ("nudge region", "Nudge Region/Event Position Left by Bar", 113),
        ("nudge region", "Nudge Region/Event Position Right by Beat", 114),
        ("nudge region", "Nudge Region/Event Position Left by Beat", 115),
        ("duplicate", "New Track with Duplicate Settings and Content", 116),
        ("delete track", "Delete Track", 118),
        ("rename track", "Rename Track", 119),
        ("next plug-in", "Next Plug-in Setting for topmost Plug-in Window", 120),
        ("previous plug-in", "Previous Plug-in Setting for topmost Plug-in Window", 121),
        ("create marker", "Create Marker", 104)
    ]
}

