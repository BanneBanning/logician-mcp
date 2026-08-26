import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

let protocolVersion = "2025-06-18"
let serverName = "logician"
let serverVersion = "0.49.0"

enum DemoError: LocalizedError {
    case accessibilityNotTrusted
    case logicNotRunning
    case windowNotFound(String)
    case parameterNotFound(String)
    case parameterAmbiguous(String, Int)
    case valueNotWritable(String)
    case currentValueMismatch(expected: String, actual: String)
    case writeFailed(String)
    case confirmationFailed(String)
    case verificationFailed(requested: String, actual: String, restored: Bool)
    case invalidArguments(String)
    case projectMismatch(expected: String, actual: String)
    case trackNotExposed(requested: String, exposed: String)
    case insertNotFound(track: String, plugin: String, available: [String])
    case insertAmbiguous(track: String, plugin: String, slots: [Int])
    case insertMismatch(slot: Int, expected: String, actual: String)
    case openVerificationFailed(String)
    case windowNotClosable(String)
    case windowAmbiguous(String, Int)
    case pluginNotOpen(String)
    case trackNotFound(String, available: [String])
    case trackAmbiguous(String, numbers: [Int])
    case trackMismatch(number: Int, expected: String, actual: String)
    case selectionFailed(requested: String, actual: String, restored: Bool)
    case trackNotStack(String)

    var code: String {
        switch self {
        case .accessibilityNotTrusted: return "not_trusted"
        case .logicNotRunning: return "not_running"
        case .windowNotFound, .parameterNotFound, .insertNotFound, .trackNotFound: return "not_found"
        case .parameterAmbiguous, .insertAmbiguous, .windowAmbiguous, .trackAmbiguous: return "ambiguous"
        case .valueNotWritable, .trackNotExposed, .windowNotClosable, .trackNotStack: return "not_exposed"
        case .currentValueMismatch, .projectMismatch, .insertMismatch, .pluginNotOpen, .trackMismatch: return "precondition_failed"
        case .writeFailed, .confirmationFailed: return "write_failed"
        case .verificationFailed, .openVerificationFailed, .selectionFailed: return "verification_failed"
        case .invalidArguments: return "invalid_arguments"
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is not granted to the MCP process."
        case .logicNotRunning:
            return "Logic Pro is not running."
        case .windowNotFound(let title):
            return "Logic window not found: \(title)"
        case .parameterNotFound(let name):
            return "Accessible plugin parameter not found: \(name)"
        case .parameterAmbiguous(let name, let count):
            return "Accessible plugin parameter is ambiguous: \(name) matched \(count) controls."
        case .valueNotWritable(let name):
            return "The accessible value is not writable: \(name)"
        case .currentValueMismatch(let expected, let actual):
            return "Current value mismatch. Expected \(expected), found \(actual). No write was attempted."
        case .writeFailed(let detail):
            return "Accessibility write failed: \(detail)"
        case .confirmationFailed(let detail):
            return "Accessibility confirmation failed: \(detail)"
        case .verificationFailed(let requested, let actual, let restored):
            return "Readback mismatch. Requested \(requested), found \(actual). Restored: \(restored)."
        case .invalidArguments(let detail):
            return "Invalid arguments: \(detail)"
        case .projectMismatch(let expected, let actual):
            return "Open project mismatch. Expected \(expected), found \(actual). No action was taken."
        case .trackNotExposed(let requested, let exposed):
            return "Channel strip for track '\(requested)' is not exposed. The inspector currently shows '\(exposed)'. Select the track in Logic first."
        case .insertNotFound(let track, let plugin, let available):
            return "No insert matching '\(plugin)' on track '\(track)'. Available inserts: \(available.joined(separator: ", "))."
        case .insertAmbiguous(let track, let plugin, let slots):
            return "Insert '\(plugin)' on track '\(track)' is ambiguous; it occupies slots \(slots.map(String.init).joined(separator: ", ")). Pass insert_index to disambiguate."
        case .insertMismatch(let slot, let expected, let actual):
            return "Insert slot \(slot) holds '\(actual)', not '\(expected)'. No action was taken."
        case .openVerificationFailed(let detail):
            return "Could not verify that the plugin window state changed as requested: \(detail)"
        case .windowNotClosable(let title):
            return "Refusing to close window '\(title)': only plugin windows (dialogs without a document) may be closed."
        case .windowAmbiguous(let title, let count):
            return "\(count) windows share the title '\(title)'. Use logic_close_plugin with track, plugin and insert index instead."
        case .pluginNotOpen(let detail):
            return "The plugin window was not open: \(detail)"
        case .trackNotFound(let name, let available):
            return "No visible track header matches '\(name)'. Visible tracks: \(available.joined(separator: ", ")). Scrolled-out tracks are not exposed."
        case .trackAmbiguous(let name, let numbers):
            return "Track name '\(name)' is ambiguous; it matches track numbers \(numbers.map(String.init).joined(separator: ", ")). Pass track_number to disambiguate."
        case .trackMismatch(let number, let expected, let actual):
            return "Track \(number) is named '\(actual)', not '\(expected)'. No action was taken."
        case .selectionFailed(let requested, let actual, let restored):
            return "Track selection could not be verified. Requested '\(requested)', selection is '\(actual)'. Restored previous selection: \(restored)."
        case .trackNotStack(let name):
            return "Track '\(name)' exposes no track stack disclosure arrow; it is not a track stack."
        }
    }
}

struct AccessibleParameter {
    let name: String
    let help: String
    let identifier: String
    let rawValue: String
    let minimum: String
    let maximum: String
    let valueDescription: String
    let valueSettable: Bool

    var dictionary: [String: Any] {
        [
            "name": name,
            "help": help,
            "ax_identifier": identifier,
            "raw_value": rawValue,
            "raw_min": minimum,
            "raw_max": maximum,
            "value_description": valueDescription,
            "writable": valueSettable
        ]
    }
}

struct InsertSlot {
    let index: Int
    let name: String
    let bypassed: Bool
    let group: AXUIElement
    let openButton: AXUIElement?

    var dictionary: [String: Any] {
        [
            "insert_index": index,
            "plugin_display_name": name,
            "bypassed": bypassed,
            "can_open": openButton != nil
        ]
    }
}

struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

