import Foundation

/// G53: the value vocabulary of Logic's bounce dialog, read off the real
/// dialog on 2026-08-28 by opening every pop-up and enumerating its items.
///
/// These lists are OBSERVATIONS, not guesses — which is why they are exact
/// strings including Logic's own spelling of `POW-r #2 (Noise Shaping)`. They
/// serve two purposes: the caller's friendly value ("48k", "24 bit") is mapped
/// onto the menu title that has to be pressed, and a value that maps onto
/// nothing is refused with the real list rather than pressed at random.
enum BounceFormat {
    /// The `File Type:` pop-up (Uncompressed destination).
    static let fileTypes = ["AIFF", "WAVE", "CAF"]
    /// `Bit Depth:`.
    static let bitDepths = ["8-bit", "16-bit", "24-bit", "32-bit float"]
    /// `Sample Rate:`.
    static let sampleRates = [
        "11.025 kHz", "12 kHz", "22.05 kHz", "24 kHz", "32 kHz", "44.1 kHz",
        "48 kHz", "64 kHz", "88.2 kHz", "96 kHz", "176.4 kHz", "192 kHz"
    ]
    /// `Dithering:` — the separators in the real menu are dropped.
    static let ditherings = [
        "None", "POW-r #1 (Dithering)", "POW-r #2 (Noise Shaping)",
        "POW-r #3 (Noise Shaping)", "UV22HR"
    ]
    /// `Normalize:` — on the bounce dialog AND on the bounce-in-place sheet.
    static let normalizeModes = ["Off", "Overload Protection Only", "On"]
    /// `Format:` (interleaving), listed for completeness; not exposed as an
    /// argument, because a Split file breaks every reader downstream of this
    /// server (the metrics parser included).
    static let interleaving = ["Split", "Interleaved"]

    /// Maps what a caller wrote onto the exact menu title to press.
    ///
    /// Three steps, each one only accepted when it is UNAMBIGUOUS: an exact
    /// match ignoring case and punctuation ("32-bit float" == "32 bit
    /// float"), a unique prefix ("POW-r #1" for the full name, "48" for
    /// "48 kHz"), and a numeric reading for sample rates written in Hz
    /// (48000 -> "48 kHz"). Anything else is nil, and the caller refuses with
    /// the list.
    static func canonical(_ raw: String, in options: [String]) -> String? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(raw)
        guard !wanted.isEmpty else { return nil }
        if let exact = options.first(where: { key($0) == wanted }) { return exact }
        let prefixed = options.filter { key($0).hasPrefix(wanted) }
        if prefixed.count == 1 { return prefixed[0] }
        // "48000", "48000 Hz", "96000hz" — a rate written in Hz.
        let digits = raw.filter { $0.isNumber || $0 == "." }
        if let hertz = Double(digits), hertz >= 1000 {
            let kilohertz = hertz / 1000
            let text = kilohertz == kilohertz.rounded()
                ? String(Int(kilohertz))
                : String(kilohertz)
            let matches = options.filter {
                key($0).contains("khz") && key($0).hasPrefix(key(text))
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    /// The refusal text for a value that maps onto nothing.
    static func rejection(_ raw: String, label: String, options: [String]) -> String {
        "'\(raw)' is not one of \(label)'s values in Logic's bounce dialog. "
            + "Nothing was bounced. Available: \(options.joined(separator: ", "))."
    }
}
