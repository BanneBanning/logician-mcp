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
        let freezeBox = firstDescendant(of: header.item, maximumDepth: AXDepth.trackHeaderControl) { element in
            stringAttribute(element, kAXRoleAttribute as String) == "AXCheckBox"
                && stringAttribute(element, kAXDescriptionAttribute as String) == "Freeze"
        }
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
            collect(from: window, maximumDepth: AXDepth.alertDialog) { element in
                let role = stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXStaticText",
                   stringAttribute(element, kAXValueAttribute as String).contains("frozen") {
                    hasFrozenText = true
                }
                if role == "AXButton",
                   stringAttribute(element, kAXTitleAttribute as String) == "Unfreeze" {
                    unfreezeButton = element
                }
            }
            if hasFrozenText, let button = unfreezeButton {
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

}
