import Foundation

// MARK: - The channel strip's grammar, as pure data

/// One child of an inspector channel strip, reduced to the attributes that
/// carry meaning. Kept separate from Accessibility so the whole reading — what
/// a strip IS, what it is routed to, and what it publishes nothing about — is
/// unit-testable against the strings Logic really produced.
///
/// Every field here was measured on Logic Pro 12.3.1, 2026-08-28, across an
/// audio track, a software-instrument track and a reduced (folder-stack) main
/// track; see `ChannelStripTests` for the verbatim rows.
struct StripChild: Equatable {
    let role: String
    let subrole: String
    let description: String
    let title: String
    let value: String
    let valueDescription: String
    let help: String
    /// The child's vertical position in the window. Logic's strip is a
    /// top-to-bottom layout and the AXChildren order does NOT follow it, so
    /// this is what tells the instrument slot apart from an insert.
    let y: Double

    init(
        role: String,
        subrole: String = "",
        description: String = "",
        title: String = "",
        value: String = "",
        valueDescription: String = "",
        help: String = "",
        y: Double = 0
    ) {
        self.role = role
        self.subrole = subrole
        self.description = description
        self.title = title
        self.value = value
        self.valueDescription = valueDescription
        self.help = help
        self.y = y
    }

    /// The kind of slot this child is, read off Logic's own help text. The
    /// help is the identity: an EMPTY slot's description is a placeholder
    /// ("audio plug-in", "send button", "Input", "Instrument") while an
    /// OCCUPIED slot is an `AXGroup` with no help at all, so neither the role
    /// nor the description alone can name a slot.
    var slotKind: ChannelStrip.SlotKind? {
        for (prefix, kind) in ChannelStrip.slotHelpPrefixes where help.hasPrefix(prefix) {
            return kind
        }
        return nil
    }
}

/// A whole strip, read.
///
/// Every field is optional and `nil` means "Logic published nothing for it" —
/// never "the value is off". That distinction is the whole point of the type:
/// a reduced strip publishes no output slot at all, and reporting that as
/// "no output" would be a lie about a track that certainly has one.
struct ChannelStripReading: Equatable {
    var name: String = ""
    var kind: ChannelStrip.Kind = .unknown
    var kindEvidence: [String] = []
    var input: String?
    var inputDisplay: String?
    var outputDisplay: String?
    var inputGain: String?
    var channelMode: String?
    var output: String?
    var group: String?
    var groupDisplay: String?
    var automationMode: String?
    var mute: Bool?
    var solo: Bool?
    var recordArmed: Bool?
    var inputMonitoring: Bool?
    var volumeDB: Double?
    var pan: String?
    var instrument: String?
    var hasInstrumentSlot = false
    var hasMIDIEffectSlot = false
    var midiEffects: [String] = []
    var eqOn: Bool?
    var plugins: [String] = []
    var sends: [ChannelStrip.Send] = []
    var childCount = 0
}

enum ChannelStrip {

    enum SlotKind: Equatable {
        case output
        case input
        case send
        case audioEffect
        case midiEffect
        case inputGain
        case group
        case setting
        case volume
        case pan
    }

    struct Send: Equatable {
        let destination: String
        let level: String?
    }

    /// What sort of strip this is, inferred from which slots exist.
    ///
    /// `reduced` is a real, measured case and not a fallback: a folder-stack
    /// main track publishes SEVEN children — name, mute, solo, volume fader,
    /// its level field, the automation group and the group pop-up — and no
    /// output, no inserts, no pan, no meter. Reading that as "an audio track
    /// with nothing routed" would be wrong twice over.
    enum Kind: String, Equatable {
        case audio
        case softwareInstrument = "software_instrument"
        case reduced
        case unknown
    }

    /// Logic's help-text prefixes, which are how a slot says what it is.
    /// Measured verbatim 2026-08-28.
    static let slotHelpPrefixes: [(String, SlotKind)] = [
        ("Output slot.", .output),
        ("Input slot.", .input),
        ("Send slot.", .send),
        ("Audio Effect slot.", .audioEffect),
        ("MIDI Effect slot.", .midiEffect),
        ("Input Gain field and knob.", .inputGain),
        ("Group slot.", .group),
        ("Setting button.", .setting),
        ("Volume fader.", .volume),
        ("Pan/Balance knob.", .pan)
    ]

    /// Logic's placeholder label on an EMPTY group slot. The pop-up's title is
    /// `"group, <label>"`, and with no group the label is the word "Group"
    /// itself — so the empty case and a group actually NAMED "Group" are
    /// indistinguishable from here, which is why `group` and `groupDisplay`
    /// are both reported.
    static let emptyGroupLabel = "Group"

    /// The same placeholder trick on the two routing slots: an unassigned
    /// input slot reads `"Input"` and (by the same pattern) an output slot
    /// with no destination reads `"Output"`. Both are reported raw as
    /// `*_display` beside the interpreted value, because a bus could in
    /// principle be named either word.
    static let emptyInputLabel = "Input"
    static let emptyOutputLabel = "Output"

    /// The head of a menu title Logic decorated with its destination:
    /// `"Bus 2 → Aux 2"` is the bus named `Bus 2`, and `"Bus 5 ← Acke Slagverk , Ivan Slagverk"`
    /// on the input side names the same bus by who feeds it. The arrow half is
    /// Logic explaining itself; the head is the identity, exactly as
    /// `RegionInspector.popupShortForm` treats a parenthesis.
    /// The group menu adds its own decoration on the other side — `"Group 1:
    /// (new)"` is the offer to CREATE group 1 — so a colon ends the head too.
    static func routingHead(_ title: String) -> String {
        for separator in [" → ", " ← ", " -> ", " <- ", ": "] {
            if let range = title.range(of: separator) {
                return String(title[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// The three ways Logic says "nothing here", paired: the MENU offers
    /// `"No Output"` / `"No Input"` / `"No Group"` while the SLOT then reads
    /// the bare placeholder `"Output"` / `"Input"` / `"Group"`.
    ///
    /// Measured the hard way (2026-08-28): pressing `No Group` on an ungrouped
    /// strip left the slot reading `Group`, and a literal comparison called
    /// that a `verification_failed` on a write that had done exactly what was
    /// asked.
    static let emptyPairs: [(menu: String, slot: String)] = [
        ("No Output", emptyOutputLabel),
        ("No Input", emptyInputLabel),
        ("No Group", emptyGroupLabel)
    ]

    /// Whether a routing menu item — or a slot's own label — is the one the
    /// caller asked for. A request may be the head alone (`"Bus 2"`), Logic's
    /// whole decorated title, or either half of an empty pair.
    static func routingMatches(item: String, requested: String) -> Bool {
        func canonical(_ text: String) -> String {
            let head = routingHead(text)
            for pair in emptyPairs
            where head.localizedCaseInsensitiveCompare(pair.menu) == .orderedSame
                || head.localizedCaseInsensitiveCompare(pair.slot) == .orderedSame {
                return pair.slot.lowercased()
            }
            // A GROUP slot drops the word once the strip is in a group: the
            // menu item is "Group 1: (new)" and the slot then reads bare "1"
            // (measured 2026-08-28, and it turned a working write into a
            // readback mismatch). A number alone is a group number.
            if head.allSatisfy(\.isNumber), !head.isEmpty { return "group \(head)" }
            return head.lowercased()
        }
        return canonical(item) == canonical(requested)
            || item.localizedCaseInsensitiveCompare(requested) == .orderedSame
    }

    /// `"-10,6 dB"` / `"1,0 dB"` -> the number. Logic prints a decimal comma in
    /// a Swedish locale and a point elsewhere; both parse.
    static func decibels(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: "\u{33A9}", with: "") // ㏈, the glyph Logic uses in some panels
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    /// `"Read, automation enabled"` -> `"Read"`. The strip's automation group
    /// carries the mode as the head of its description.
    static func automationMode(fromGroupDescription description: String) -> String? {
        let head = description.split(separator: ",", maxSplits: 1)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return head.isEmpty ? nil : head
    }

    /// `"group, Group 1"` -> `"Group 1"`; `"group, Group"` -> `"Group"`.
    static func groupLabel(fromTitle title: String) -> String? {
        guard let range = title.range(of: ", ") else { return nil }
        let label = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// Logic's switch buttons publish `"on"`/`"off"` — and sometimes more,
    /// e.g. the gain reduction meter's `"on, 0 dB"` — so this reads the first
    /// word only and refuses anything else rather than treating an unexpected
    /// string as `false`.
    static func switchState(_ value: String) -> Bool? {
        switch value.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// The whole reading, from the strip's children in AXChildren order.
    static func read(children: [StripChild]) -> ChannelStripReading {
        var reading = ChannelStripReading()
        reading.childCount = children.count

        for (index, child) in children.enumerated() {
            switch child.slotKind {
            case .output:
                reading.outputDisplay = child.description
                reading.output = child.description == emptyOutputLabel ? nil : child.description
            case .input:
                // Logic labels an UNASSIGNED input slot with the bare word
                // "Input" (measured on `Fill`, `Sweeps`, `Vinyl`, all stereo),
                // and an assigned one with the input's name ("Input 1"). Same
                // shape as the empty group slot's "Group".
                reading.inputDisplay = child.description
                reading.input = child.description == emptyInputLabel ? nil : child.description
            case .inputGain:
                reading.inputGain = child.valueDescription.isEmpty
                    ? child.value : child.valueDescription
            case .midiEffect:
                reading.hasMIDIEffectSlot = true
            case .volume:
                reading.volumeDB = decibels(child.valueDescription)
            case .pan:
                reading.pan = child.valueDescription.isEmpty ? child.value : child.valueDescription
            case .group:
                reading.groupDisplay = groupLabel(fromTitle: child.title)
                if let label = reading.groupDisplay, label != emptyGroupLabel {
                    reading.group = label
                }
            case .send, .audioEffect, .setting, .none:
                break
            }

            if child.role == "AXTextField", child.description == "name" {
                reading.name = child.value
            }
            if child.role == "AXButton", child.subrole == "AXSwitch" {
                switch child.description {
                case "mute": reading.mute = switchState(child.value)
                case "solo": reading.solo = switchState(child.value)
                case "record": reading.recordArmed = switchState(child.value)
                case "monitoring": reading.inputMonitoring = switchState(child.value)
                case "channel mode": reading.channelMode = child.value
                default: break
                }
            }
            if child.role == "AXButton", child.description == "EQ" {
                reading.eqOn = switchState(child.value)
            }
            if child.role == "AXButton", child.description == "Instrument" {
                // The EMPTY instrument slot names itself.
                reading.hasInstrumentSlot = true
            }
            if child.role == "AXGroup",
               let mode = automationMode(fromGroupDescription: child.description),
               child.description.contains("automation") {
                reading.automationMode = mode
            }
            // An occupied plugin slot is an AXGroup whose description is the
            // plugin's displayed name and which is neither the automation
            // group nor a send. Sends are told apart by the `send knob` slider
            // that FOLLOWS them (measured: `AXGroup "Bus 2"` then
            // `AXSlider desc "send knob" vdesc "-9,0"`).
            if child.role == "AXGroup", child.slotKind == nil,
               !child.description.isEmpty,
               !child.description.contains("automation") {
                let next = index + 1 < children.count ? children[index + 1] : nil
                if next?.description == "send knob" {
                    reading.sends.append(Send(
                        destination: child.description,
                        level: next?.valueDescription.isEmpty == false
                            ? next?.valueDescription : next?.value
                    ))
                } else {
                    reading.plugins.append(child.description)
                }
            }
        }

        // The instrument slot, by GEOMETRY, because nothing else tells it from
        // an insert: an occupied instrument slot is an `AXGroup` with exactly
        // the same bypass/open children as an insert group.
        //
        // MEASURED 2026-08-28 (y grows DOWNWARD): setting 319 -> EQ 351 ->
        // MIDI plug-in 386 -> **instrument 413** -> inserts 438… -> sends ->
        // output -> group -> automation -> pan -> volume -> name. So the
        // instrument is the first plugin-bearing element BELOW the MIDI Effect
        // slot — and "below the first empty audio-effect slot" is NOT the
        // boundary, which is the version that got this wrong live: on `Lofi
        // Pad` the empty placeholders sit at 461/478 while the OCCUPIED
        // inserts sit at 427/445, above them, so the rule picked `Channel EQ`
        // as the instrument of a track whose instrument slot is empty.
        if reading.hasMIDIEffectSlot, let midiY = children.first(where: { $0.slotKind == .midiEffect })?.y {
            reading.hasInstrumentSlot = true
            let sendDestinations = Set(reading.sends.map(\.destination))
            let candidates = children.filter { child in
                guard child.y > midiY else { return false }
                if child.role == "AXButton", child.description == "Instrument" { return true }
                return child.role == "AXGroup" && child.slotKind == nil
                    && !child.description.isEmpty
                    && !child.description.contains("automation")
                    && !sendDestinations.contains(child.description)
            }
            if let slot = candidates.min(by: { $0.y < $1.y }), slot.role == "AXGroup" {
                reading.instrument = slot.description
                reading.plugins.removeAll { $0 == slot.description }
            }
            // An `Instrument` BUTTON there means the slot exists and is empty,
            // which is exactly `instrument: null` with `has_instrument_slot`.
        }

        // The kind, and the evidence for it — never a bare label.
        var evidence: [String] = []
        if reading.inputDisplay != nil { evidence.append("an Input slot") }
        if reading.channelMode != nil { evidence.append("a channel mode switch") }
        if reading.hasMIDIEffectSlot { evidence.append("a MIDI Effect slot") }
        if reading.outputDisplay == nil { evidence.append("no Output slot") }
        reading.kindEvidence = evidence
        if reading.hasMIDIEffectSlot {
            reading.kind = .softwareInstrument
        } else if reading.inputDisplay != nil {
            reading.kind = .audio
        } else if reading.outputDisplay == nil {
            reading.kind = .reduced
        } else {
            reading.kind = .unknown
        }
        return reading
    }
}
