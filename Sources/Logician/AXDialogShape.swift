import ApplicationServices
import Foundation

// MARK: - Classifying a modal by its SHAPE rather than by its words

/// What a dialog IS, structurally: how many buttons it has, which
/// identifiers they carry, whether it has a suppression checkbox, whether it
/// publishes a default or cancel button, how many radio buttons and pop-ups
/// sit in it.
///
/// None of that translates. A Swedish Logic's tempo prompt still has three
/// buttons identified `action-button-1…3` and a `supression-checkbox`; it
/// just calls them `Nej`, `Importera tempo` and `Avbryt`.
///
/// This is the second rung of the ladder in `LogicUIStrings`: below an
/// `AXIdentifier` on the control itself, above an English title. It is a
/// PURE value — read once off the tree by `dialogShape(of:)`, then reasoned
/// about by functions that tests can call without Logic running.
///
/// The honest limit: a shape is only a classifier when it DISCRIMINATES. Two
/// buttons and two static texts describes the delete-track alert and half a
/// dozen others, so that one keeps its English gate (see
/// `TrackDeletionAlert`). Shape is used here only where the measured shape is
/// actually distinctive, and every dialog that still needs its words is a
/// line in `R4-LOCALE-SESSION-CHECKLIST.md`.
struct AXDialogShape: Equatable {
    /// Every `AXIdentifier` carried by a button in the dialog, in tree order.
    /// Empty strings are kept: "three buttons, none identified" is a
    /// different shape from "three buttons, all identified".
    let buttonIdentifiers: [String]
    /// Every `AXIdentifier` carried by a checkbox.
    let checkBoxIdentifiers: [String]
    /// Counts of the roles that tell modal species apart.
    let buttonCount: Int
    let checkBoxCount: Int
    let radioButtonCount: Int
    let popUpButtonCount: Int
    let staticTextCount: Int
    /// Whether the window itself publishes `AXDefaultButton` /
    /// `AXCancelButton`. When it does, the confirm and abort answers need no
    /// English at all.
    let publishesDefaultButton: Bool
    let publishesCancelButton: Bool

    /// The alert species Logic numbers its buttons on: three buttons carrying
    /// `action-button-1`, `-2` and `-3`.
    var hasActionButtonTriple: Bool {
        let wanted = [
            LogicUIStrings.Identifier.actionButton1,
            LogicUIStrings.Identifier.actionButton2,
            LogicUIStrings.Identifier.actionButton3
        ]
        return wanted.allSatisfy(buttonIdentifiers.contains)
    }

    /// Whether the alert offers "Don't ask again".
    var hasSuppressionCheckbox: Bool {
        checkBoxIdentifiers.contains(LogicUIStrings.Identifier.suppressionCheckbox)
    }

    /// The MIDI import's tempo prompt, told from every other alert Logic
    /// raises during an import WITHOUT reading a word of it.
    ///
    /// Measured 2026-08-30 (R2 §3.5 and §8), the two alerts an import can
    /// meet are:
    ///
    /// * tempo prompt — 3 `action-button-*` **plus** a `supression-checkbox`
    /// * save-changes — 3 `action-button-*` and **no** checkbox
    ///
    /// The checkbox is therefore the whole discriminator, and it is an
    /// identifier rather than a label. Pressing `action-button-1` on the
    /// wrong one of those two would be the difference between "No, don't
    /// import tempo" and "Save the user's project" — which is why the import
    /// route accepts this shape OR the English text and REPORTS which one
    /// recognised it, rather than quietly widening the gate.
    var isTempoPromptShape: Bool {
        hasActionButtonTriple && hasSuppressionCheckbox
    }

    /// The bounce-in-place sheet, which has no title at all.
    ///
    /// It is the only `AXSheet` in this server's paths that carries BOTH
    /// radio buttons (source: Mute/Leave/Delete, destination: Selected
    /// Track/New Track) and pop-up buttons (Normalize, file split). A save
    /// panel — the other sheet a bounce flow can raise — has pop-ups and no
    /// radios, so the radio count is what separates them.
    var isBounceInPlaceSheetShape: Bool {
        radioButtonCount >= 2 && popUpButtonCount >= 1
    }
}

extension LogicAccessibility {

    /// Reads a dialog's shape off the tree. Shallow on purpose: alert and
    /// sheet content is flat, and `AXDepth.alertDialog` is the depth every
    /// other alert read in this server already uses.
    func dialogShape(of window: AXUIElement, maximumDepth: Int = AXDepth.alertDialog) -> AXDialogShape {
        var buttonIdentifiers: [String] = []
        var checkBoxIdentifiers: [String] = []
        var buttons = 0
        var checkBoxes = 0
        var radios = 0
        var popUps = 0
        var texts = 0
        collect(from: window, maximumDepth: maximumDepth) { element in
            let identifier = { self.stringAttribute(element, kAXIdentifierAttribute as String) }
            switch stringAttribute(element, kAXRoleAttribute as String) {
            case "AXButton":
                buttons += 1
                buttonIdentifiers.append(identifier())
            case "AXCheckBox":
                checkBoxes += 1
                checkBoxIdentifiers.append(identifier())
            case "AXRadioButton":
                radios += 1
            case "AXPopUpButton":
                popUps += 1
            case "AXStaticText":
                texts += 1
            default:
                break
            }
        }
        return AXDialogShape(
            buttonIdentifiers: buttonIdentifiers,
            checkBoxIdentifiers: checkBoxIdentifiers,
            buttonCount: buttons,
            checkBoxCount: checkBoxes,
            radioButtonCount: radios,
            popUpButtonCount: popUps,
            staticTextCount: texts,
            publishesDefaultButton: elementAttribute(window, kAXDefaultButtonAttribute as String) != nil,
            publishesCancelButton: elementAttribute(window, kAXCancelButtonAttribute as String) != nil
        )
    }

    // MARK: - Addressing a dialog's two universal answers

    /// The window's own default (confirm) button, when it publishes one.
    ///
    /// `AXDefaultButton` is the button Return activates — the one drawn
    /// highlighted — and it is a STRUCTURAL attribute: it survives
    /// translation. Every call site tries this first and falls back to the
    /// English title, so on a Logic that publishes nothing the behaviour is
    /// exactly what it was before this existed.
    func defaultButton(of window: AXUIElement) -> AXUIElement? {
        elementAttribute(window, kAXDefaultButtonAttribute as String)
    }

    /// The window's own cancel button, when it publishes one. Same contract.
    ///
    /// This is the more valuable of the two: a Cancel that cannot be found
    /// leaves a MODAL standing, and a standing modal swallows Logic's keyboard
    /// and every later tool call with it.
    func cancelButton(of window: AXUIElement) -> AXUIElement? {
        elementAttribute(window, kAXCancelButtonAttribute as String)
    }

    /// A button by title, anywhere under `root`. The last resort, kept honest
    /// by living behind the two structural lookups above.
    func button(
        in root: AXUIElement,
        titled title: String,
        maximumDepth: Int = AXDepth.alertDialog
    ) -> AXUIElement? {
        firstDescendant(of: root, maximumDepth: maximumDepth) {
            stringAttribute($0, kAXRoleAttribute as String) == "AXButton"
                && stringAttribute($0, kAXTitleAttribute as String) == title
        }
    }

    /// The dialog's confirm button: `AXDefaultButton` if the window publishes
    /// one, otherwise the button carrying `title`.
    func confirmButton(
        of window: AXUIElement,
        titled title: String = LogicUIStrings.Button.ok,
        maximumDepth: Int = AXDepth.alertDialog
    ) -> AXUIElement? {
        defaultButton(of: window) ?? button(in: window, titled: title, maximumDepth: maximumDepth)
    }

    /// The dialog's abort button: `AXCancelButton` if the window publishes
    /// one, otherwise the button carrying `title`.
    func abortButton(
        of window: AXUIElement,
        titled title: String = LogicUIStrings.Button.cancel,
        maximumDepth: Int = AXDepth.alertDialog
    ) -> AXUIElement? {
        cancelButton(of: window) ?? button(in: window, titled: title, maximumDepth: maximumDepth)
    }
}
