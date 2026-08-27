import Foundation

/// One row of the Mackie Control's LCD: 56 characters cut into eight
/// 7-character cells, one per strip. Every numeric echo this project
/// converges a write against is read out of one of these cells, so the
/// slicing lives in ONE place that both planes import — the daemon, which
/// converges in-process next to the mirror, and the server, which verifies
/// the result afterwards. Two slicers would be two chances to disagree about
/// what a strip's value is, and the write lands on the disagreement.
public enum MCULCDRow {
    public static let length = 56
    public static let cellWidth = 7
    public static let cellCount = 8

    /// The literal cell, trimmed — what the row actually says at that column
    /// range. Channel NAMES are read this way; nothing is inferred.
    public static func cell(_ row: String, _ index: Int) -> String {
        guard (0..<cellCount).contains(index) else { return "" }
        let characters = Array(row.padding(toLength: length, withPad: " ", startingAt: 0))
        let start = index * cellWidth
        return String(characters[start..<start + cellWidth])
            .trimmingCharacters(in: .whitespaces)
    }

    public static func cells(_ row: String) -> [String] {
        (0..<cellCount).map { cell(row, $0) }
    }

    /// The cell read as a numeric VALUE echo, with the rightmost cell's
    /// shifted sign character recovered.
    ///
    /// Turning a vpot replaces the multi-channel row with a single-channel
    /// banner, and Logic paints the touched strip's value as an EIGHT
    /// character group — the value plus its trailing space — left-aligned at
    /// that strip's own cell. On the rightmost cell that group would run one
    /// column past the row, so Logic starts it one column EARLY and the sign
    /// character lands in the last column of cell 6. Measured live
    /// 2026-08-28 on channels 1, 3, 5 and 7 of the same bank; only 7 shifts:
    ///
    ///     ch 5: |-19,5  +0,0 dB                     -1,7 dB              |
    ///     ch 7: |-19,5  +0,0 dB                                  -1,7 dB |
    ///                                                     cell 6 ^^ cell 7
    ///
    /// A strict cell slice therefore reads `-1,7 dB` as `1,7 dB` — the
    /// magnitude with its sign silently dropped, which is worse than an
    /// unreadable value. The in-bridge convergence read its own downward step
    /// as an upward one, inverted its adaptive tick ratio and drove
    /// `Stereo Out` to the +6.0 dB end stop in 62 iterations while reporting
    /// success (FINDINGS 2026-08-28).
    ///
    /// The rule fires on positive evidence only: the sign column belongs to
    /// cell 6, and a cell-6 value that ends in `+`/`-` has never been
    /// observed — dB and pan readouts are left-aligned and end in a unit or a
    /// digit. A cell 6 that IS a lone `-` (the dash placeholder) sits at the
    /// cell's first column, six columns to the left, and cannot trigger it.
    public static func valueCell(_ row: String, _ index: Int) -> String {
        let text = cell(row, index)
        // Only the last cell can overflow, and only a cell that does not
        // already carry its own sign was shifted.
        guard index == cellCount - 1, let first = text.first, !"+-".contains(first) else {
            return text
        }
        let characters = Array(row.padding(toLength: length, withPad: " ", startingAt: 0))
        let sign = characters[length - cellWidth - 1]
        guard sign == "+" || sign == "-" else { return text }
        return String(sign) + text
    }

    public static func valueCells(_ row: String) -> [String] {
        (0..<cellCount).map { valueCell(row, $0) }
    }
}
