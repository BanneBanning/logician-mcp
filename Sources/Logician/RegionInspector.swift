import Foundation

/// The Region inspector's grammar — the pure half.
///
/// Logic's Region inspector (the "Region:" panel at the top of the left
/// inspector) publishes itself as an `AXOutline` of two-column rows: a LABEL
/// cell and a VALUE cell. What each row means, what its value means, and
/// whose parameters are on screen at all is decided here, so it can be
/// unit-tested without Logic. The Accessibility half is `AXRegionInspector`.
///
/// Everything in this file was measured against Logic Pro 12.3.1 on
/// 2026-08-28; see docs/FINDINGS.md for the session that produced it.
enum RegionInspector {

    // MARK: - Who the panel is showing

    /// The panel's name field answers "whose parameters are these?" — and the
    /// answer is NOT always "a region". With nothing selected Logic shows the
    /// TRACK's region defaults there ("MIDI Defaults" / "Audio Defaults"), and
    /// a write would then change what every future region on that track
    /// inherits rather than a region. With several regions selected it reads
    /// "N selected". Both are refused by the write path; both are reported by
    /// the read path.
    enum PanelSubject: Equatable {
        case region(name: String)
        case multiple(count: Int)
        case defaults(kind: String)

        var description: String {
            switch self {
            case .region(let name): return "the region '\(name)'"
            case .multiple(let count): return "\(count) selected regions"
            case .defaults(let kind): return "the track's \(kind) region defaults (no region is selected)"
            }
        }
    }

    /// Classifies the panel's name field. `"2 selected"` and `"MIDI Defaults"`
    /// are Logic's own strings, measured; anything else is a region name.
    static func panelSubject(nameField: String) -> PanelSubject {
        let text = nameField.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(" Defaults") {
            return .defaults(kind: String(text.dropLast(" Defaults".count)))
        }
        if text.hasSuffix(" selected"),
           let count = Int(text.dropLast(" selected".count).trimmingCharacters(in: .whitespaces)) {
            return .multiple(count: count)
        }
        return .region(name: text)
    }

    // MARK: - Rows

    /// What kind of control a row's value cell is, which decides how it is
    /// written: `AXValue` for a slider, `AXPress` for a checkbox, a menu item
    /// press for a pop-up.
    enum Control: String {
        case checkbox
        case slider
        case popup
        /// A row Logic is not using for this region type: both cells read "-"
        /// and are disabled. Reported, never written.
        case placeholder
        case other
    }

    /// Logic prints a trailing colon on the text-field labels ("Mute:") and
    /// none on the pop-up ones ("Quantize", "Fade-In"). One vocabulary.
    static func normalizedLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(":") { text = String(text.dropLast()) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Logic paints a slider at its DEFAULT with an empty display (three
    /// spaces), which is a real answer — "nothing is being changed" — and not
    /// a missing one. Blank comes back as nil rather than as `"   "`.
    static func displayText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The parameters this server addresses by name

    struct Parameter {
        /// The tool's argument name.
        let key: String
        /// Every label Logic publishes for the row. More than one where the
        /// label cell is itself a pop-up: the Quantize row's label reads
        /// `Quantize` or `Smart Quantize` depending on the mode.
        let labels: [String]
        let control: Control
        /// Region types that HAVE this parameter, as `logic_list_regions`
        /// spells them.
        let regionTypes: Set<String>
        /// Rows below the "More" disclosure, which has to be open first.
        let underMore: Bool
        /// Slider bounds as Logic publishes them (`AXMinValue`/`AXMaxValue`).
        let range: ClosedRange<Int>?
        /// Human unit, for the result and the refusals.
        let unit: String

        init(
            _ key: String, labels: [String], control: Control,
            regionTypes: Set<String>, underMore: Bool = false,
            range: ClosedRange<Int>? = nil, unit: String = ""
        ) {
            self.key = key
            self.labels = labels
            self.control = control
            self.regionTypes = regionTypes
            self.underMore = underMore
            self.range = range
            self.unit = unit
        }
    }

    static let midi = "midi"
    static let audio = "audio"
    static let both: Set<String> = [midi, audio]

    /// The parameters `logic_set_region_params` writes. Every one of them was
    /// written and read back live on a scratch region on 2026-08-28; nothing
    /// is here on inference.
    static let writable: [Parameter] = [
        Parameter("quantize", labels: ["Quantize", "Smart Quantize"], control: .popup,
                  regionTypes: both, unit: "note value"),
        Parameter("q_swing", labels: ["Q-Swing"], control: .slider,
                  regionTypes: both, range: 1...99, unit: "%"),
        Parameter("q_strength", labels: ["Q-Strength"], control: .slider,
                  regionTypes: both, underMore: true, range: 0...100, unit: "%"),
        Parameter("transpose", labels: ["Transpose"], control: .slider,
                  regionTypes: both, range: -96...96, unit: "semitones"),
        Parameter("velocity_offset", labels: ["Velocity Offset"], control: .slider,
                  regionTypes: [midi], range: -99...99, unit: "velocity"),
        Parameter("dynamics", labels: ["Dynamics"], control: .slider,
                  regionTypes: [midi], underMore: true, range: 0...14, unit: "scale"),
        Parameter("gate_time", labels: ["Gate Time"], control: .slider,
                  regionTypes: [midi], underMore: true, range: 0...15, unit: "scale"),
        Parameter("delay_ticks", labels: ["Delay"], control: .slider,
                  regionTypes: both, underMore: true, range: -999...9999, unit: "ticks"),
        Parameter("loop", labels: ["Loop"], control: .checkbox, regionTypes: both),
        Parameter("mute", labels: ["Mute"], control: .checkbox, regionTypes: both)
    ]

    /// The order writes are applied in. Quantize FIRST: every Q-row
    /// (Q-Swing, Q-Strength, Q-Velocity, Q-Length, Q-Flam, Q-Range) is
    /// DISABLED while Quantize is Off, and an AXValue write to a disabled
    /// slider does nothing (measured). Setting the grid first is what makes
    /// "quantize to 1/16 with 75% swing" one call instead of two.
    static let writeOrder = [
        "quantize", "q_swing", "q_strength", "transpose", "velocity_offset",
        "dynamics", "gate_time", "delay_ticks", "loop", "mute"
    ]

    static func parameter(key: String) -> Parameter? {
        writable.first { $0.key == key }
    }

    /// Which shipped parameter a published row label belongs to, or nil for
    /// the rows this server reads but does not write.
    static func parameter(forLabel label: String) -> Parameter? {
        let normalized = normalizedLabel(label)
        return writable.first { parameter in
            parameter.labels.contains { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
    }

    // MARK: - Scaled value vocabularies

    /// Dynamics and Gate Time are INDEXES into a fixed list of scalings, not
    /// percentages: `AXValue` 0…14 (Dynamics) and 0…15 (Gate Time). Measured
    /// by sweeping the slider and reading `AXValueDescription` at every step.
    /// Index 6 is "no change" and Logic prints it BLANK, which is why the
    /// name is derived here rather than read back.
    static let scaleNames = [
        "Fixed", "25%", "50%", "75%", "88%", "94%", "100%",
        "106%", "112%", "125%", "150%", "175%", "200%", "300%", "400%"
    ]
    static let gateTimeNames = scaleNames + ["Legato"]

    static func scaleIndex(_ name: String, names: [String]) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let index = names.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return index
        }
        // "100" for "100%" is the obvious near miss and costs nothing to accept.
        if !wanted.hasSuffix("%"), Int(wanted) != nil {
            return names.firstIndex { $0.caseInsensitiveCompare(wanted + "%") == .orderedSame }
        }
        return nil
    }

    static func scaleName(_ index: Int, names: [String]) -> String? {
        guard index >= 0, index < names.count else { return nil }
        return names[index]
    }

    /// The list a refusal prints.
    static func names(forParameter key: String) -> [String]? {
        switch key {
        case "dynamics": return scaleNames
        case "gate_time": return gateTimeNames
        default: return nil
        }
    }

    // MARK: - Argument → slider value

    enum ValueError: Error, Equatable {
        case notANumber(key: String, given: String, unit: String)
        case outOfRange(key: String, given: Int, range: ClosedRange<Int>, unit: String)
        case unknownName(key: String, given: String, available: [String])
    }

    /// Turns a tool argument into the integer Logic's slider takes.
    ///
    /// Dynamics and Gate Time accept Logic's own words ("Fixed", "125%",
    /// "Legato") as well as the raw index, because the words are what an agent
    /// reading the panel sees; everything else is a plain integer in the
    /// control's own unit, checked against the range Logic publishes.
    static func sliderValue(key: String, argument: Any) throws -> Int {
        guard let parameter = parameter(key: key) else {
            throw ValueError.notANumber(key: key, given: "\(argument)", unit: "")
        }
        if let names = names(forParameter: key) {
            if let text = argument as? String {
                guard let index = scaleIndex(text, names: names) else {
                    throw ValueError.unknownName(key: key, given: text, available: names)
                }
                return index
            }
            if let number = integer(from: argument) {
                guard names.indices.contains(number) else {
                    throw ValueError.unknownName(
                        key: key, given: "\(number)", available: names
                    )
                }
                return number
            }
            throw ValueError.unknownName(key: key, given: "\(argument)", available: names)
        }
        guard let number = integer(from: argument) else {
            throw ValueError.notANumber(key: key, given: "\(argument)", unit: parameter.unit)
        }
        if let range = parameter.range, !range.contains(number) {
            throw ValueError.outOfRange(key: key, given: number, range: range, unit: parameter.unit)
        }
        return number
    }

    static func integer(from argument: Any) -> Int? {
        if let value = argument as? Int { return value }
        if let value = argument as? Double, value == value.rounded() { return Int(value) }
        if let text = argument as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// How a slider's current value is reported: the raw integer Logic holds,
    /// plus the text Logic paints (nil at the default) and, for the two
    /// indexed parameters, the name the index stands for.
    static func report(key: String, raw: Int, published: String) -> [String: Any] {
        var entry: [String: Any] = ["value": raw]
        if let display = displayText(published) { entry["display"] = display }
        if let names = names(forParameter: key), let name = scaleName(raw, names: names) {
            entry["name"] = name
        }
        return entry
    }

    // MARK: - Checkboxes

    /// A checkbox over a multi-selection where the regions DISAGREE publishes
    /// `AXValue` 2, macOS's mixed state (measured: one muted region and one
    /// unmuted, selected together). A press then turns them all ON.
    static func checkboxState(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "1": return true
        case "0": return false
        default: return nil // "2" — mixed across a multi-selection
        }
    }

    /// A pop-up over a multi-selection whose regions disagree reads "*".
    static let mixedPopupValue = "*"
}
