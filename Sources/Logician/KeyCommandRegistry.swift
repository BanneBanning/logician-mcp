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

    static func register(note: Int, channel: Int, name: String, notes: String) {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["port": "Logic MCP Commands"]
        var commands = root["commands"] as? [[String: Any]] ?? []
        commands.removeAll {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        let formatter = ISO8601DateFormatter()
        commands.append([
            "note": note, "channel": channel, "name": name,
            "learned": String(formatter.string(from: Date()).prefix(10)),
            "notes": notes
        ])
        root["commands"] = commands
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
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

