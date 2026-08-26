import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    // MARK: - Freeze state (track header checkbox + confirm dialog)

    /// Reads the track header's Freeze checkbox: true = frozen, false = not,
    /// nil = state not readable (header scrolled out or freeze column hidden).
    func trackFreezeState(trackName: String) -> Bool? {
        guard let headers = try? parsedTrackHeaders(),
              let header = headers.first(where: {
                  $0.name.caseInsensitiveCompare(trackName) == .orderedSame
              }) else { return nil }
        var freezeBox: AXUIElement?
        func findFreeze(_ element: AXUIElement, _ depth: Int) {
            guard depth < 4, freezeBox == nil else { return }
            if stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox",
               stringAttribute(element, kAXDescriptionAttribute as String) == "Freeze" {
                freezeBox = element
                return
            }
            for child in children(of: element) { findFreeze(child, depth + 1) }
        }
        findFreeze(header.item, 0)
        guard let box = freezeBox else { return nil }
        return stringAttribute(box, kAXValueAttribute as String) == "1"
    }

    /// Answers Logic's "Track X is frozen. Do you want to unfreeze it?"
    /// confirmation with Unfreeze. Returns false when no such dialog is up.
    func answerFreezeDialog() -> Bool {
        guard let windows = try? logicWindows() else { return false }
        for window in windows {
            var hasFrozenText = false
            var unfreezeButton: AXUIElement?
            func walk(_ element: AXUIElement, _ depth: Int) {
                guard depth < 8 else { return }
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String).contains("frozen") {
                    hasFrozenText = true
                }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == "Unfreeze" {
                    unfreezeButton = element
                }
                for child in children(of: element) { walk(child, depth + 1) }
            }
            walk(window, 0)
            if hasFrozenText, let button = unfreezeButton {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

}
