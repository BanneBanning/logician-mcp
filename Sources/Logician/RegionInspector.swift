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

        /// Whether the panel is showing ONE region — the only subject a write
        /// path may proceed on, and the condition the settle poll waits for.
        var isRegion: Bool {
            if case .region = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .region(let name): return "the region '\(name)'"
            case .multiple(let count): return "\(count) selected regions"
            case .defaults(let kind): return "the track's \(kind) region defaults (no region is selected)"
            }
        }
    }

    /// What the caller knows about the selection from a channel the panel's
    /// name field cannot forge.
    ///
    /// The name field is USER-WRITABLE — `logic_rename_region` writes exactly
    /// that field — so classifying the panel by sniffing it alone reads
    /// Logic's grammar out of a string a user chose. A region called
    /// "2 selected" would report itself as a two-region selection to every
    /// Region-inspector tool, and the write paths would refuse it forever.
    /// This server refuses to CREATE such a name (`reservedPanelNameReason`),
    /// but Logic's own UI does not, and a project that arrives carrying one
    /// has to stay addressable. Evidence taken from the ARRANGEMENT breaks
    /// the tie.
    struct SelectionEvidence: Equatable {
        /// How many regions a sweep of the arrangement found selected, or nil
        /// when nobody counted. It sees RENDERED rows only (a collapsed
        /// folder stack is invisible to it), so it is only ever allowed to
        /// NARROW: on its own it can never talk the panel out of "several are
        /// selected".
        let selectedCount: Int?
        /// The arrangement map's own name for the one region the caller
        /// addressed — the independent channel that says a reserved-looking
        /// panel string is really this region's name.
        let addressedRegionName: String?

        static let none = SelectionEvidence()

        init(selectedCount: Int? = nil, addressedRegionName: String? = nil) {
            self.selectedCount = selectedCount
            self.addressedRegionName = addressedRegionName
        }
    }

    /// Classifies the panel's name field. `"2 selected"` and `"MIDI Defaults"`
    /// are Logic's own strings, measured; anything else is a region name.
    ///
    /// `evidence` is how a region NAMED like one of Logic's strings is told
    /// apart from the state itself. Both halves are required to overrule the
    /// string, and each covers the other's blind spot: the count proves this
    /// is not a multi-selection of rendered regions, and the map name proves
    /// the panel string is a name Logic is showing rather than a state it is
    /// reporting. With no evidence the string stands on its own, which is the
    /// read path's behaviour and was the only behaviour before 2026-09-02.
    static func panelSubject(
        nameField: String, evidence: SelectionEvidence = .none
    ) -> PanelSubject {
        let text = nameField.trimmingCharacters(in: .whitespaces)
        let sniffed = sniffedPanelSubject(text)
        if case .region = sniffed { return sniffed }
        if evidence.selectedCount == 1,
           let addressed = evidence.addressedRegionName,
           PrintedRegion.canonicalName(addressed).trimmingCharacters(in: .whitespaces) == text {
            return .region(name: text)
        }
        return sniffed
    }

    /// The name field read as nothing but a string — Logic's grammar, with no
    /// arrangement evidence to check it against.
    private static func sniffedPanelSubject(_ text: String) -> PanelSubject {
        if text.hasSuffix(" Defaults") {
            return .defaults(kind: String(text.dropLast(" Defaults".count)))
        }
        if text.hasSuffix(" selected"),
           let count = Int(text.dropLast(" selected".count).trimmingCharacters(in: .whitespaces)) {
            return .multiple(count: count)
        }
        return .region(name: text)
    }

    /// The name field, compared the way every check in this family compares a
    /// region name: trimmed, and with Logic's `, muted` state suffix off. The
    /// arrangement map no longer prints it (`parseRegion` cleans the name at
    /// the source since 2026-09-03), but this side reads the INSPECTOR's own
    /// string, so the strip stays here and goes through the one shared word
    /// list — `RegionNameAnnotation`.
    static func canonicalPanelName(_ raw: String) -> String {
        PrintedRegion.canonicalName(raw).trimmingCharacters(in: .whitespaces)
    }

    /// Why a call that ADDRESSED one region must not go on with the panel in
    /// front of it — or nil when the panel is showing that region.
    ///
    /// Every Region-inspector tool that names a region selects it EXCLUSIVELY
    /// first, so a panel that afterwards reports several regions, the track's
    /// defaults, or a DIFFERENT region is a panel that has not caught up — and
    /// the rows underneath it belong to something other than the region that
    /// was asked about. Reading those out as that region's parameters, or
    /// writing into them, is the silent wrong answer this refusal replaces.
    ///
    /// MEASURED 2026-09-02 on the old build: a `logic_get_region_params` for
    /// `Latin` at bar 13 on "Acke Slagverk", taken immediately after the
    /// exclusive selection, came back `panel_name: "Crash"` — Logic was still
    /// painting the region the PREVIOUS call had selected — and the tool
    /// reported Crash's twenty-two rows under a `region` key naming Latin.
    /// Nothing in the payload said so.
    ///
    /// It is reached only after the settle poll and after `SelectionEvidence`
    /// has had its say, so a region genuinely NAMED like one of Logic's own
    /// strings never gets here — which is why the multi-selection message can
    /// afford to say so.
    ///
    /// What it cannot catch, stated plainly: two regions on ONE track sharing
    /// a name (Logic makes those constantly) are the same string in the panel,
    /// which publishes no position. The name check narrows the window to
    /// same-track namesakes; it does not close it.
    ///
    /// `outcome` is what the caller did or did not do, in its own words
    /// ("nothing was written", "nothing was read").
    static func addressedPanelRefusal(
        _ subject: PanelSubject, addressedRegionName: String?, outcome: String
    ) -> String? {
        switch subject {
        case .region(let shown):
            guard let addressedRegionName else { return nil }
            let wanted = canonicalPanelName(addressedRegionName)
            let showing = canonicalPanelName(shown)
            guard showing != wanted else { return nil }
            return "the Region inspector is still showing the region '\(showing)' rather than "
                + "'\(wanted)', the region that was addressed: \(outcome). Logic never repainted "
                + "the panel onto the new selection, so every row under it is '\(showing)'s."
        case .defaults(let kind):
            return "the Region inspector is showing the track's \(kind) region DEFAULTS — what "
                + "every FUTURE region on that track inherits — rather than the region that was "
                + "addressed: \(outcome). The selection did not take."
        case .multiple(let count):
            return "\(count) regions are selected, and the Region inspector's name field then "
                + "reads '\(count) selected' rather than naming the addressed region: \(outcome). "
                + "The selection did not take. (A region genuinely NAMED '\(count) selected' is "
                + "addressed normally: the arrangement map's name for the selected region is what "
                + "tells the two apart, and here it did not match.)"
        }
    }

    /// Why a region must not be GIVEN this name — or nil when it is safe.
    ///
    /// Logic reserves two shapes of the Region inspector's name field for
    /// itself, and the panel is the only place it says whose parameters are on
    /// screen. A region named into one of those shapes reads as a selection
    /// STATE: `logic_rename_region` and `logic_set_region_params` refuse it
    /// (the refusal is honest-looking and describes a selection problem that
    /// does not exist) and `logic_get_region_params` reports it as several
    /// regions. Refused before the write instead, since the recovery would
    /// otherwise be Logic's own UI.
    ///
    /// Derived from `panelSubject` rather than from a second copy of the
    /// rules, so the refusal cannot drift from the sniffing it protects.
    static func reservedPanelNameReason(_ name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespaces)
        switch panelSubject(nameField: text) {
        case .region:
            return nil
        case .multiple(let count):
            return "'\(text)' is the string Logic's Region inspector prints when \(count) regions "
                + "are selected"
        case .defaults(let kind):
            return "'\(text)' is the string Logic's Region inspector prints when NO region is "
                + "selected and the panel is showing the track's \(kind) region defaults"
        }
    }

    /// A name close to the refused one that Logic does not reserve, so the
    /// refusal can name the alternative instead of only the problem. Escaping
    /// both shapes needs one character that is neither " selected" nor
    /// " Defaults" at the end.
    static func unreservedAlternative(to name: String) -> String {
        name.trimmingCharacters(in: .whitespaces) + "_"
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
        /// `Quantize` or `Smart Quantize` depending on the mode, and the two
        /// fade rows read `Fade-In`/`Speed Up` and `Fade-Out`/`Slow Down`.
        /// The FIRST entry is the mode this server writes.
        let labels: [String]
        /// The labels of the row this parameter's row must come AFTER. The
        /// audio panel publishes TWO rows called `Curve` (row 14 belongs to
        /// Fade-In, row 17 to Fade-Out), so those two cannot be addressed by
        /// label alone — see `rowIndex(for:labels:)`.
        let after: [String]
        /// True where the row's label is a mode pop-up and a mode OTHER than
        /// `labels[0]` means the value is a different quantity: a `Speed Up`
        /// row holds a speed-up length, not a fade length, and writing a fade
        /// into it would be a silent lie. Refused instead.
        let refuseAlternateMode: Bool
        let control: Control
        /// Region types that HAVE this parameter, as `logic_list_regions`
        /// spells them.
        let regionTypes: Set<String>
        /// Rows below the "More" disclosure, which has to be open first.
        let underMore: Bool
        /// Slider bounds as Logic publishes them (`AXMinValue`/`AXMaxValue`).
        let range: ClosedRange<Int>?
        /// Bounds that differ per region type: Transpose is ±96 semitones on
        /// a MIDI region and ±36 on an audio one, measured on both.
        let rangeByRegionType: [String: ClosedRange<Int>]
        /// Human unit, for the result and the refusals.
        let unit: String

        init(
            _ key: String, labels: [String], control: Control,
            regionTypes: Set<String>, underMore: Bool = false,
            after: [String] = [], refuseAlternateMode: Bool = false,
            range: ClosedRange<Int>? = nil,
            rangeByRegionType: [String: ClosedRange<Int>] = [:], unit: String = ""
        ) {
            self.key = key
            self.labels = labels
            self.control = control
            self.regionTypes = regionTypes
            self.underMore = underMore
            self.after = after
            self.refuseAlternateMode = refuseAlternateMode
            self.range = range
            self.rangeByRegionType = rangeByRegionType
            self.unit = unit
        }

        /// The range Logic enforces for THIS region type; the widest one when
        /// the type is not known yet (the arguments are validated before the
        /// panel has been read).
        func range(forRegionType regionType: String?) -> ClosedRange<Int>? {
            if let regionType, let specific = rangeByRegionType[regionType] { return specific }
            return range
        }
    }

    static let midi = "midi"
    static let audio = "audio"
    static let both: Set<String> = [midi, audio]

    /// The parameters `logic_set_region_params` writes. Every one of them was
    /// written and read back live on a scratch region — the MIDI side on
    /// 2026-08-28, the audio side the same day in the following session;
    /// nothing is here on inference.
    static let writable: [Parameter] = [
        Parameter("quantize", labels: ["Quantize", "Smart Quantize"], control: .popup,
                  regionTypes: both, unit: "note value"),
        Parameter("q_swing", labels: ["Q-Swing"], control: .slider,
                  regionTypes: both, range: 1...99, unit: "%"),
        Parameter("q_strength", labels: ["Q-Strength"], control: .slider,
                  regionTypes: both, underMore: true, range: 0...100, unit: "%"),
        Parameter("transpose", labels: ["Transpose"], control: .slider,
                  regionTypes: both, range: -96...96,
                  rangeByRegionType: [audio: -36...36], unit: "semitones"),
        Parameter("fine_tune", labels: ["Fine Tune"], control: .slider,
                  regionTypes: [audio], range: -50...50, unit: "cents"),
        Parameter("velocity_offset", labels: ["Velocity Offset"], control: .slider,
                  regionTypes: [midi], range: -99...99, unit: "velocity"),
        Parameter("dynamics", labels: ["Dynamics"], control: .slider,
                  regionTypes: [midi], underMore: true, range: 0...14, unit: "scale"),
        Parameter("gate_time", labels: ["Gate Time"], control: .slider,
                  regionTypes: [midi], underMore: true, range: 0...15, unit: "scale"),
        Parameter(gainKey, labels: ["Gain"], control: .slider,
                  regionTypes: [audio], range: -300...300, unit: "tenths of a dB"),
        Parameter("delay_ticks", labels: ["Delay"], control: .slider,
                  regionTypes: both, underMore: true, range: -999...9999, unit: "ticks"),
        Parameter("fade_in_ms", labels: ["Fade-In", "Speed Up"], control: .slider,
                  regionTypes: [audio], underMore: true, refuseAlternateMode: true,
                  range: 0...99999, unit: "milliseconds"),
        Parameter("fade_in_curve", labels: ["Curve"], control: .slider,
                  regionTypes: [audio], underMore: true, after: ["Fade-In", "Speed Up"],
                  range: -99...99, unit: "curve"),
        Parameter("fade_out_ms", labels: ["Fade-Out", "Slow Down"], control: .slider,
                  regionTypes: [audio], underMore: true, refuseAlternateMode: true,
                  range: 0...99999, unit: "milliseconds"),
        Parameter("fade_type", labels: ["Type"], control: .popup,
                  regionTypes: [audio], underMore: true, unit: "fade/crossfade type"),
        Parameter("fade_out_curve", labels: ["Curve"], control: .slider,
                  regionTypes: [audio], underMore: true, after: ["Fade-Out", "Slow Down"],
                  range: -99...99, unit: "curve"),
        Parameter("reverse", labels: ["Reverse"], control: .checkbox,
                  regionTypes: [audio], underMore: true),
        Parameter("loop", labels: ["Loop"], control: .checkbox, regionTypes: both),
        Parameter("mute", labels: ["Mute"], control: .checkbox, regionTypes: both)
    ]

    /// The order writes are applied in.
    ///
    /// Quantize FIRST: every Q-row (Q-Swing, Q-Strength, Q-Velocity, Q-Length,
    /// Q-Flam, Q-Range) is DISABLED while Quantize is Off, and an AXValue
    /// write to a disabled slider does nothing (measured). Setting the grid
    /// first is what makes "quantize to 1/16 with 75% swing" one call instead
    /// of two.
    ///
    /// Each fade LENGTH goes before its curve and type for the same reason in
    /// reverse: a fade of 0 ms is a fade that is not there, so "fade out over
    /// 400 ms with a -40 curve" reads as one gesture and lands in that order.
    static let writeOrder = [
        "quantize", "q_swing", "q_strength", "transpose", "fine_tune",
        "velocity_offset", "dynamics", "gate_time", gainKey, "delay_ticks",
        "fade_in_ms", "fade_in_curve", "fade_out_ms", "fade_type", "fade_out_curve",
        "reverse", "loop", "mute"
    ]

    static func parameter(key: String) -> Parameter? {
        writable.first { $0.key == key }
    }

    /// Which shipped parameter a published row label belongs to, or nil for
    /// the rows this server reads but does not write.
    ///
    /// AMBIGUOUS BY DESIGN for the two `Curve` rows: use `rowIndexes(labels:)`
    /// to address a row, which is what both the read and the write path do.
    static func parameter(forLabel label: String) -> Parameter? {
        let normalized = normalizedLabel(label)
        return writable.first { parameter in
            parameter.labels.contains { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        }
    }

    // MARK: - Which ROW a parameter is

    /// Rows 14 and 17 of an audio region are BOTH labelled `Curve` — the first
    /// belongs to Fade-In, the second to Fade-Out — so a label is not an
    /// address. This resolves a parameter to a POSITION in Logic's own row
    /// order: an unambiguous label matches directly, and a duplicated one is
    /// resolved by the row it must follow (`Parameter.after`). A label that
    /// appears more than once with no anchor to sort it out returns nil rather
    /// than picking the first, because writing a fade-out curve into a fade-in
    /// is a silent wrong answer.
    static func rowIndex(for parameter: Parameter, labels: [String]) -> Int? {
        let published = labels.map(normalizedLabel)
        func matches(_ index: Int, _ candidates: [String]) -> Bool {
            candidates.contains { $0.caseInsensitiveCompare(published[index]) == .orderedSame }
        }
        let hits = published.indices.filter { matches($0, parameter.labels) }
        guard !hits.isEmpty else { return nil }
        guard !parameter.after.isEmpty else {
            return hits.count == 1 ? hits[0] : nil
        }
        guard let anchor = published.indices.first(where: { matches($0, parameter.after) }) else {
            return nil
        }
        return hits.first { $0 > anchor }
    }

    /// Every shipped parameter that this row list actually publishes, as
    /// key → row index. Rows the panel does not show for this region type are
    /// simply absent.
    static func rowIndexes(labels: [String]) -> [String: Int] {
        var resolved: [String: Int] = [:]
        for parameter in writable {
            if let index = rowIndex(for: parameter, labels: labels) {
                resolved[parameter.key] = index
            }
        }
        return resolved
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

    // MARK: - Gain: decibels in, tenths of a decibel out

    /// Logic holds region gain in TENTHS of a decibel: the slider runs
    /// -300…300 and 30 reads `+3,0 ㏈`. The tool argument is decibels, because
    /// `gain: 30` meaning +3 dB is exactly the kind of unit trap the Dynamics
    /// scale already cost a session — `gain_db: -6.5` cannot be misread.
    static let gainKey = "gain_db"
    static let gainLimitDecibels = 30.0

    static func decibels(tenths: Int) -> Double {
        (Double(tenths) / 10.0 * 10).rounded() / 10
    }

    /// What the value means in words. Logic prints its own version in the
    /// cell (`+3,0 ㏈`, with the user's decimal separator); this is the one
    /// the tool result says out loud, and it is deliberately ASCII.
    static func gainDisplay(tenths: Int) -> String {
        let sign = tenths > 0 ? "+" : (tenths < 0 ? "-" : "")
        let magnitude = abs(tenths)
        return "\(sign)\(magnitude / 10).\(magnitude % 10) dB"
    }

    /// Decibels (a decimal, as anyone talks about gain) → the integer Logic's
    /// slider takes. Rounded to the tenth Logic can actually hold.
    static func gainTenths(fromDecibels argument: Any) throws -> Int {
        let decibels: Double
        if let value = argument as? Double {
            decibels = value
        } else if let value = argument as? Int {
            decibels = Double(value)
        } else if let text = argument as? String,
                  let value = Double(text.trimmingCharacters(in: .whitespaces)
                      .replacingOccurrences(of: ",", with: ".")) {
            decibels = value
        } else {
            throw ValueError.notANumber(key: gainKey, given: "\(argument)", unit: "decibels")
        }
        guard decibels.isFinite, abs(decibels) <= gainLimitDecibels else {
            throw ValueError.outOfDecibelRange(
                key: gainKey, given: decibels, limit: gainLimitDecibels
            )
        }
        return Int((decibels * 10).rounded())
    }

    // MARK: - Argument → slider value

    enum ValueError: Error, Equatable {
        case notANumber(key: String, given: String, unit: String)
        case outOfRange(key: String, given: Int, range: ClosedRange<Int>, unit: String)
        case outOfDecibelRange(key: String, given: Double, limit: Double)
        case unknownName(key: String, given: String, available: [String])
        /// A range that only THIS region type enforces — audio transpose caps
        /// at ±36 where MIDI runs to ±96.
        case outOfRangeForRegionType(
            key: String, given: Int, range: ClosedRange<Int>, unit: String, regionType: String
        )
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
        if key == gainKey {
            return try gainTenths(fromDecibels: argument)
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

    /// The SECOND range check, run once the panel has said which region type
    /// is on screen. Transpose is the parameter this exists for: 50 semitones
    /// is legal on a MIDI region and would be silently clamped to 36 on an
    /// audio one, so it is refused by name before anything at all is written.
    static func checkRange(key: String, value: Int, regionType: String?) throws {
        guard let parameter = parameter(key: key),
              let range = parameter.range(forRegionType: regionType) else { return }
        if range.contains(value) { return }
        if let regionType, parameter.rangeByRegionType[regionType] != nil {
            throw ValueError.outOfRangeForRegionType(
                key: key, given: value, range: range, unit: parameter.unit, regionType: regionType
            )
        }
        throw ValueError.outOfRange(key: key, given: value, range: range, unit: parameter.unit)
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
        if key == gainKey {
            // `value` is what Logic holds (tenths of a dB); `db` is what the
            // tool takes and what a human means. Both, always, so a result can
            // be fed straight back in as an argument.
            entry["db"] = decibels(tenths: raw)
            entry["gain"] = gainDisplay(tenths: raw)
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

    // MARK: - Pop-ups that display less than they offer

    /// Logic's fade Type menu offers `X (Crossfade)` and the pop-up then reads
    /// `X`; `EqP (Equal Power Crossfade)` reads `EqP`. Measured 2026-08-28 —
    /// and until it was, a perfectly successful write was reported as a
    /// verification failure, because the read-back compared the strings
    /// literally. The head before " (" is the identity; the parenthetical is
    /// Logic explaining itself.
    static func popupShortForm(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let parenthesis = text.range(of: " (") else { return text }
        return String(text[text.startIndex..<parenthesis.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether a pop-up showing `displayed` is showing `requested` — either
    /// spelling of it, in either direction.
    static func popupValuesMatch(_ displayed: String, _ requested: String) -> Bool {
        popupShortForm(displayed).compare(
            popupShortForm(requested), options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}
