import Foundation

// MARK: - What kind of window is this?

/// The one rule the whole server uses to tell Logic's windows apart, in a form
/// `logic_list_windows` can publish.
///
/// It exists because that tool — the server's own window-identification oracle,
/// the one `windowNotClosable` sends agents to by name — used to answer the
/// question with `documentPath != nil ? "project" : "plugin_or_auxiliary"`, and
/// document presence is neither necessary nor sufficient for being the project
/// window:
///
/// - **The Mixer carries the document.** Measured 2026-09-02 with the Mixer
///   open, `logic_list_windows` returned TWO windows both labelled
///   `kind: "project"`, one of them `"<project> - Mixer: Tracks"` — the window
///   `projectWindow()` deliberately filters out, and the one `logic_set_mixer`
///   warns can SHADOW the project window. The oracle named the shadow.
/// - **A dialog can carry it too.** A Drum Machine Designer window is an
///   `AXDialog` holding the project document; under the old rule it came back
///   `"project"`, telling an agent it could not be closed while
///   `logic_close_plugin_window` closes it happily.
///
/// The rule here is the SUBROLE rule the close tools already enforce (see
/// `LogicianError.windowNotClosable`): `AXDialog` is what may be closed,
/// whatever document it carries, and an `AXStandardWindow` is not.
///
/// Pure, so the classification is testable without Logic running.
enum LogicWindowKind {

    /// The project's main (Tracks) window: a standard window with a document
    /// that is not the Mixer. What every Accessibility-plane read targets.
    static let project = "project"
    /// Logic's Mixer: a standard window carrying the SAME document as the
    /// project window. Its own kind because it is a second document window and
    /// a shadowing hazard, not because it is a lesser project window.
    static let mixer = "mixer"
    /// A standard window with no document — a document-less Logic window.
    static let standard = "standard"
    /// An `AXDialog`: plugin and auxiliary windows, INCLUDING document-carrying
    /// ones. The only kind `logic_close_plugin_window` will close.
    static let pluginOrAuxiliary = "plugin_or_auxiliary"
    /// Anything else Logic publishes — floating windows (Key Commands), sheets,
    /// windows with no subrole at all. Named rather than guessed at.
    static let other = "other"

    /// Classify one window from what its payload already reports.
    ///
    /// - Parameters:
    ///   - subrole: `AXSubrole`, the deciding attribute.
    ///   - title: `AXTitle`, needed only to tell the Mixer from the project
    ///     window — the two are otherwise identical standard document windows.
    ///   - hasDocument: whether `AXDocument` is set. It separates `project`
    ///     from `standard`; it never makes a dialog anything but a dialog.
    static func classify(subrole: String, title: String, hasDocument: Bool) -> String {
        switch subrole {
        case "AXDialog":
            return pluginOrAuxiliary
        case "AXStandardWindow":
            if isMixerTitle(title) { return mixer }
            return hasDocument ? project : standard
        default:
            return other
        }
    }

    /// Whether a window title names Logic's Mixer view.
    ///
    /// The view name follows the last `" - "` in Logic's window titles
    /// (`"… - Tracks"`, `"… - Mixer: Tracks"`), so the test is on that segment
    /// and a project called "Mixer Notes" does not fool it. `isMixerWindow(_:)`
    /// reads the title and asks this, so there is one rule and not two.
    static func isMixerTitle(_ title: String) -> Bool {
        guard let view = title.components(
            separatedBy: LogicUIStrings.Window.viewSeparator
        ).last else { return false }
        return view.hasPrefix(LogicUIStrings.Window.mixerViewPrefix)
    }
}
