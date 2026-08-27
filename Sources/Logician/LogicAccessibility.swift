import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

final class LogicAccessibility {
    let bundleIdentifier = "com.apple.logic10"

    func health() -> [String: Any] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        var result: [String: Any] = [
            "accessibility_trusted": AXIsProcessTrusted(),
            "logic_running": !applications.isEmpty,
            "logic_pid": applications.first.map { Int($0.processIdentifier) } ?? NSNull(),
            "bundle_identifier": bundleIdentifier
        ]
        result["project_document"] = (try? projectDocumentPath()) ?? NSNull()
        return result
    }

    // MARK: - Read-only discovery

    func listWindows() throws -> [[String: Any]] {
        try logicWindows().map { window in
            [
                "title": stringAttribute(window, kAXTitleAttribute as String),
                "subrole": stringAttribute(window, kAXSubroleAttribute as String),
                "is_main": stringAttribute(window, kAXMainAttribute as String) == "1",
                "document": documentPath(of: window) ?? NSNull(),
                "kind": documentPath(of: window) != nil ? "project" : "plugin_or_auxiliary"
            ]
        }
    }

    func projectDocumentPath() throws -> String {
        for window in try logicWindows() {
            if let path = documentPath(of: window) {
                return path
            }
        }
        throw LogicianError.windowNotFound("project window with AXDocument")
    }

    func listTracks() throws -> [String: Any] {
        let tracks: [[String: Any]] = try parsedTrackHeaders().map { header in
            var entry: [String: Any] = [
                "track_number": header.number,
                "track_name": header.name,
                "selected": header.selected,
                "is_stack": header.disclosure != nil
            ]
            if let expanded = header.expanded {
                entry["expanded"] = expanded
            }
            return entry
        }
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "tracks": tracks,
            "note": "Only track headers currently rendered in the Tracks area are exposed through Accessibility. Subtracks of collapsed track stacks and scrolled-out tracks are not listed; use logic_set_track_stack to expand a stack."
        ]
    }

    func listInserts(trackName: String) throws -> [String: Any] {
        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "track": trackName,
            "strip_source": "left_inspector_channel_strip",
            "inserts": slots.map(\.dictionary)
        ]
    }

}
