import ApplicationServices
import CoreGraphics
import Foundation

/// The keyboard shortcut a menu item advertises about ITSELF, decoded.
///
/// Why this exists: `AXPress` on a menu item is a silent no-op for some of
/// Logic's menus — measured 2026-08-28 on `Logic Pro > Key Commands > Edit
/// Assignments…`, where both `AXPress` and `AXPick` returned `.success` and no
/// window ever appeared, while the same code opens `File > Bounce > Project or
/// Section…` reliably. The item itself publishes what to press instead
/// (`AXMenuItemCmdChar` = "K", `AXMenuItemCmdModifiers` = 10), so the fallback
/// synthesises exactly the shortcut LOGIC shows next to that item rather than
/// a hardcoded guess that could fire whatever the user has bound to it.
enum MenuShortcut {
    /// Apple's `AXMenuItemCmdModifiers` bit field. Command is the DEFAULT and
    /// is switched OFF by bit 3 — a mask of 0 means ⌘ alone, which is exactly
    /// backwards from every other modifier bit and the easiest part of this to
    /// get wrong. Verified against Logic 12.3.1's own menus: `Project or
    /// Section…` (⌘B) = 0, `Regions in Place…` (⌃B) = 12, `Edit Assignments…`
    /// (⌥K) = 10.
    static func flags(fromModifiers modifiers: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 4 != 0 { flags.insert(.maskControl) }
        if modifiers & 8 == 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// Human-readable, for messages: "⌥K", "⌃B", "⌘B".
    static func describe(character: String, modifiers: Int) -> String {
        var text = ""
        if modifiers & 4 != 0 { text += "⌃" }
        if modifiers & 2 != 0 { text += "⌥" }
        if modifiers & 1 != 0 { text += "⇧" }
        if modifiers & 8 == 0 { text += "⌘" }
        return text + character.uppercased()
    }

    /// US-layout virtual key codes for the characters a menu shortcut can
    /// carry here. Deliberately letters and digits only: anything else comes
    /// back nil and the caller reports that it could not synthesise the
    /// shortcut, which is much better than posting the wrong key.
    static let virtualKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]

    /// The key and modifier flags to post for a menu item's advertised
    /// shortcut, or nil when the character is not one this table knows.
    static func decode(character: String, modifiers: Int) -> (key: CGKeyCode, flags: CGEventFlags)? {
        guard let first = character.lowercased().first,
              let key = virtualKeys[first] else { return nil }
        return (key, flags(fromModifiers: modifiers))
    }
}
