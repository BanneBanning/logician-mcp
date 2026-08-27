import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

let protocolVersion = "2025-06-18"
let serverName = "logician"
let serverVersion = "0.50.0"

/// Schema version stamped into every on-disk cache. Deliberately tied to
/// `serverVersion`: these files hold measurements of Logic's MCU LCD, and a
/// build that changes how the LCD is read, sliced or settled must not inherit
/// the previous build's map. Bumping the server version therefore retires
/// every cache automatically - no separate constant to forget.
let cacheSchemaVersion = serverVersion

/// Identity an on-disk cache is valid for. The maps in these files describe
/// ONE open project as read by ONE build; a file that merely *decodes* in
/// another context is not stale, it is WRONG - and a confidently wrong answer
/// is the single failure mode this server exists to prevent.
func cacheScopeToken(projectPath: String) -> String {
    "v\(cacheSchemaVersion)|\(projectPath)"
}

/// A cache payload stamped with the scope it was measured in.
struct ScopedCache<Payload: Codable>: Codable {
    let scope: String
    let payload: Payload
}

/// Reads `url` only when its stamp matches this build and this project.
/// A nil `projectPath` means the scope cannot be established at all (Logic
/// closed, no Accessibility trust, no document window), and an unscopable
/// cache is treated as absent rather than guessed at. Pre-scope files from
/// older builds simply fail to decode, which is the same answer.
func loadScopedCache<Payload: Codable>(
    _ url: URL, projectPath: String?, as: Payload.Type = Payload.self
) -> Payload? {
    guard let projectPath,
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(ScopedCache<Payload>.self, from: data),
          decoded.scope == cacheScopeToken(projectPath: projectPath) else { return nil }
    return decoded.payload
}

/// Writes `payload` stamped with the current scope. A no-op without a project
/// path: an unstamped file could never be validated on the way back in, so it
/// would be a trap for the next run rather than a cache.
func saveScopedCache<Payload: Codable>(
    _ payload: Payload, to url: URL, projectPath: String?
) {
    guard let projectPath,
          let data = try? JSONEncoder().encode(
              ScopedCache(scope: cacheScopeToken(projectPath: projectPath), payload: payload)
          ) else { return }
    try? data.write(to: url)
}

/// Reduces an agent-supplied string to a safe single filename component:
/// keeps `[A-Za-z0-9._-]`, collapses everything else (including `/` and `..`
/// path separators) to `-`, and caps the length. Used for every tool label
/// that is glued into an output path, so a label like `../../etc/x` or a
/// track named with a slash can never escape the captures directory.
func sanitizedFilenameComponent(_ raw: String, fallback: String = "clip") -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    var out = String(raw.map { allowed.contains($0) ? $0 : "-" }.prefix(64))
    // A component that is only dots ("." / "..") still resolves as traversal.
    while out.first == "." { out.removeFirst() }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? fallback : trimmed
}

/// Logic's project tempo mode (Smart Tempo): what a recording is allowed to do
/// to the project's tempo map. `Keep` leaves the map alone (the classic
/// behavior), `Adapt` REWRITES it to follow the recording, and `Auto` decides
/// per take — leaning Adapt when the metronome is off and no tempo reference
/// exists. Since Logic 10.4.2 this applies to MIDI recordings too, which is why
/// it is a write-protection concern for `logic_record_midi` and not merely a
/// timing detail: an Adapt-mode take destroys the user's tempo track as a side
/// effect, on a constant-tempo project, silently.
///
/// The two non-mode cases are deliberate. A mode this destructive must never be
/// *assumed* to be Keep just because it could not be read, so "I could not
/// read it" is a first-class answer that callers have to handle.
enum ProjectTempoMode: Equatable {
    case keep
    case adapt
    case auto
    /// The control bar's Project Tempo pop-up button is there, but Logic
    /// publishes no value on it (see `projectTempoMode()` for the probe).
    case unreadable
    /// No Project Tempo pop-up button in the control bar at all.
    case absent

    /// The mode as a result-payload string, nil when it is not known.
    var name: String? {
        switch self {
        case .keep: return "keep"
        case .adapt: return "adapt"
        case .auto: return "auto"
        case .unreadable, .absent: return nil
        }
    }

    /// Why the mode is missing, in the words an agent needs to act on it.
    /// Nil for the three real modes, which need no excuse.
    var explanation: String? {
        switch self {
        case .keep, .adapt, .auto:
            return nil
        case .unreadable:
            return "Logic's control bar does expose the Project Tempo pop-up button (Smart Tempo: Keep/Adapt/Auto), but publishes no value on it through Accessibility — no AXValue, no AXTitle, no AXValueDescription (probed 2026-08-27, Logic Pro 12.3.1, with the LCD in 'Beats & Project', the display mode that shows the mode) — so the mode cannot be read from here. Read it off the LCD's tempo display, or in File → Project Settings → Smart Tempo."
        case .absent:
            return "No Project Tempo pop-up button is present in the control bar, so the Smart Tempo mode (Keep/Adapt/Auto) cannot be read from here. Read it in File → Project Settings → Smart Tempo."
        }
    }
}

/// Maps whatever text Logic puts on the Project Tempo control to a mode.
///
/// Pure and separately tested precisely because the live AX route currently
/// yields nothing (FINDINGS, 2026-08-27): the day Logic starts publishing that
/// value — or the day the pop-up menu route lands — this mapping is what the
/// guard hangs on, and it must be right before it is ever exercised.
func normalizedProjectTempoMode(_ raw: String) -> ProjectTempoMode? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    // The LCD and the menu both label the modes with a single word; match that
    // exactly first, so a longer sentence can never outvote the label itself.
    switch text {
    case "keep": return .keep
    case "adapt": return .adapt
    case "auto": return .auto
    default: break
    }
    // Longer wordings ("Adapt Project Tempo", "Automatic") still resolve, with
    // adapt/auto tested before keep: a string that names more than one mode
    // then errs toward the refusal rather than toward a destructive recording.
    if text.contains("adapt") { return .adapt }
    if text.contains("auto") { return .auto }
    if text.contains("keep") { return .keep }
    return nil
}

/// The product's error taxonomy. Every tool failure is one of these, and the
/// `code` values (not_found, precondition_failed, ambiguous,
/// verification_failed, …) are the vocabulary agents branch on — they are
/// documented in docs/AGENT-GUIDE.md, so renaming one is an API change.
enum LogicianError: LocalizedError {
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
    case projectTempoModeUnsafe(mode: String, detail: String)

    var code: String {
        switch self {
        case .accessibilityNotTrusted: return "not_trusted"
        case .logicNotRunning: return "not_running"
        case .windowNotFound, .parameterNotFound, .insertNotFound, .trackNotFound: return "not_found"
        case .parameterAmbiguous, .insertAmbiguous, .windowAmbiguous, .trackAmbiguous: return "ambiguous"
        case .valueNotWritable, .trackNotExposed, .windowNotClosable, .trackNotStack: return "not_exposed"
        case .currentValueMismatch, .projectMismatch, .insertMismatch, .pluginNotOpen, .trackMismatch,
             .projectTempoModeUnsafe: return "precondition_failed"
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
        case .projectTempoModeUnsafe(let mode, let detail):
            return "Refusing to record: the project tempo mode is \(mode). \(detail)"
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

