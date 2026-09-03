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
    /// The words are in `LogicUIStrings.Element.StripSlotHelp`; the PAIRING is
    /// here because it needs `SlotKind`.
    static let slotHelpPrefixes: [(String, SlotKind)] = {
        typealias Help = LogicUIStrings.Element.StripSlotHelp
        return [
            (Help.output, .output),
            (Help.input, .input),
            (Help.send, .send),
            (Help.audioEffect, .audioEffect),
            (Help.midiEffect, .midiEffect),
            (Help.inputGain, .inputGain),
            (Help.group, .group),
            (Help.setting, .setting),
            (Help.volume, .volume),
            (Help.pan, .pan)
        ]
    }()

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

    /// What "no menu came up" is reported as. Written once, because both
    /// halves of the read/write pair raise it, and it has to tell the caller
    /// the two things it can act on: nothing was written, and there is a way
    /// through that does not need this tool.
    static func slotMenuFailure(attempts: Int) -> String {
        "the routing slot's menu did not open — \(attempts) presses, each one followed by a look"
            + " for the menu at both the depths Logic parents these menus at. NOTHING was written."
            + " This is safe to retry (bring Logic to the front first); a slot that refuses every"
            + " time can still be set by hand in Logic's own channel strip."
    }

    /// The confirm-poll's memory of what the slot has been saying.
    ///
    /// A routing press is verified by reading the slot back until it settles,
    /// and a slot mid-repaint publishes an EMPTY label — so an empty read is
    /// not evidence of anything and never counts. What this adds is the other
    /// end: a slot that keeps answering the same NON-matching label has
    /// settled on it, and the rest of the budget will only produce the same
    /// answer later. Measured 2026-09-03: a doomed poll ran all 25 looks and
    /// cost 6.7 s, because each look re-walks the inspector strip.
    struct SettleWatch {
        let target: String
        let limit: Int
        /// The last non-empty label read, which is what a failure reports.
        private(set) var last = ""
        private(set) var repeats = 0

        enum Verdict: Equatable {
            /// An empty label: the slot is repainting, look again.
            case repainting
            /// The requested destination is in force.
            case landed
            /// Something else, but not yet often enough to call it settled.
            case keepLooking
            /// The same wrong label, `limit` times over. Stop.
            case settledOnAnother
        }

        mutating func observe(_ value: String) -> Verdict {
            guard !value.isEmpty else { return .repainting }
            if ChannelStrip.routingMatches(item: value, requested: target) {
                last = value
                return .landed
            }
            repeats = value == last ? repeats + 1 : 1
            last = value
            return repeats >= limit ? .settledOnAnother : .keepLooking
        }
    }

    /// Why a routing name that IS in the menu still cannot be written: it
    /// names a category the menu nests destinations under, not a destination.
    ///
    /// MEASURED live 2026-09-03 (profiles/logic_set_track_routing §4):
    /// `output: "Mono"` found the item, pressed it with `.success` in 0.1 ms,
    /// changed nothing, and then spent 6.7 s polling a slot that still read
    /// `Stereo Output` before failing — twice. A category answers a press by
    /// opening its submenu, which is not a routing change and never becomes
    /// one, so this refuses BEFORE the press and hands over the names that
    /// are real: the caller's next call is right instead of ten seconds late.
    static func categoryRefusal(
        requested: String, category: String, leaves: [String], offered: [String] = []
    ) -> String {
        let named = category.isEmpty ? requested : category
        // Logic does not always publish a submenu's contents until the
        // submenu has been opened (measured 2026-09-03: `Mono` came back with
        // an AXMenu child and no items in it), so when the inside is empty the
        // refusal offers the rest of the slot's menu rather than nothing.
        // The category itself is not one of the alternatives to it.
        let rest = offered.filter {
            routingHead($0).localizedCaseInsensitiveCompare(routingHead(named)) != .orderedSame
        }
        let list: String
        if !leaves.isEmpty {
            list = "it holds: " + capped(leaves)
        } else if !rest.isEmpty {
            list = "Logic does not publish its contents until the submenu is opened, and the rest of"
                + " this slot's menu is: " + capped(rest)
        } else {
            list = "open the slot in Logic to see what it holds"
        }
        return "'\(requested)' is a CATEGORY in this slot's menu, not a destination"
            + (named.caseInsensitiveCompare(requested) == .orderedSame ? "" : " (Logic titles it '\(named)')")
            + ". Pressing it opens its submenu and routes nothing, so nothing was written."
            + " Name one of the destinations instead — \(list)."
    }

    /// A menu list an error message can carry without becoming the menu.
    private static func capped(_ titles: [String], to limit: Int = 20) -> String {
        titles.prefix(limit).joined(separator: ", ")
            + (titles.count > limit ? ", … (\(titles.count) in all)" : "")
    }

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
        Double(LogicUIStrings.Format.normalizedDecibelText(text))
    }

    /// `"Read, automation enabled"` -> `"Read"`. The strip's automation group
    /// carries the mode as the head of its description.
    ///
    /// FRENCH (R4, 2026-08-30) — **good news, and it settles a question the
    /// locale checklist raised.** A French Logic publishes
    /// `"Read, automation activée"`: only the TRAILING phrase is translated,
    /// and the MODE WORD stays English. Since this function takes the head of
    /// the description, and `MCUAutomation` compares that head against the
    /// English mode words (`Read`, `Latch`, `Touch`, `Write`), **both survive
    /// a French UI unchanged.** No work is needed here for French, and no
    /// per-locale mode table should be added on speculation.
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

    /// Logic's placeholder description on an EMPTY instrument slot. Its
    /// presence is the strip saying "the slot is here and nothing is in it",
    /// which is the one case the geometry rules must not answer with a name.
    static let emptyInstrumentLabel = "Instrument"

    /// The instrument on an AUX-SHAPED strip — one that publishes an Output
    /// slot but no Input slot, no channel mode and no MIDI Effect slot. Only
    /// the main channel of a summing track stack is both of those things at
    /// once; every other strip of that shape (an output, a bus aux) has no
    /// instrument slot at all and must come back `nil`.
    ///
    /// The rule is the insert COLUMN's top edge, and it is chosen because the
    /// column marks itself: an empty `Audio Effect slot.` placeholder or an
    /// `insert bar` divider is unambiguously part of the insert run and can
    /// never be an instrument. A plug-in-bearing group ABOVE that edge is
    /// therefore outside the eight insert slots — which is exactly where
    /// `Drum Machine Designer` sits on `Drum Synth Kit` (328, against the
    /// column's 353) and exactly where nothing sits on `Stereo Out` (its
    /// topmost row above the column, at 328, is the channel-mode BUTTON, with
    /// the column's own `insert bar` at 353 above the first insert at 354).
    /// Both measured live 2026-09-02, along with the audio strip `Ivan Effect`
    /// (Input slot + channel mode at 379, column from 404) which this rule
    /// never sees.
    ///
    /// The lowest such group wins — the instrument slot adjoins the column —
    /// and an empty-slot placeholder anywhere on the strip vetoes the whole
    /// answer: on `Lofi Pad` (a MIDI-Effect strip, so not this path anyway)
    /// the occupied inserts sit ABOVE the placeholders, and that is the shape
    /// that made the first version of the sibling rule name `Channel EQ` an
    /// instrument. A wrong answer here costs a refusal, never a wrong write:
    /// the count check the caller runs would simply disagree the other way.
    private static func auxInstrument(
        children: [StripChild], reading: ChannelStripReading
    ) -> String? {
        guard reading.inputDisplay == nil, reading.channelMode == nil else { return nil }
        guard !children.contains(where: {
            $0.role == "AXButton" && $0.description == emptyInstrumentLabel
        }) else { return nil }
        let columnTop = children.filter { child in
            child.slotKind == .audioEffect
                || (child.role == "AXButton"
                    && child.description == LogicUIStrings.Element.insertBar)
        }.map(\.y).min()
        guard let columnTop else { return nil }
        let sendDestinations = Set(reading.sends.map(\.destination))
        let above = children.filter { child in
            child.role == "AXGroup" && child.slotKind == nil
                && child.y < columnTop
                && !child.description.isEmpty
                && !child.description.contains("automation")
                && !sendDestinations.contains(child.description)
        }
        return above.max(by: { $0.y < $1.y })?.description
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
            if child.role == "AXButton", child.description == emptyInstrumentLabel {
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
                if child.role == "AXButton", child.description == emptyInstrumentLabel { return true }
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
        } else if let instrument = auxInstrument(children: children, reading: reading) {
            // A SUMMING TRACK STACK's main channel hosts an instrument on an
            // AUX-shaped strip: Output slot, no Input slot, no channel mode —
            // and NO MIDI Effect slot, so the rule above never fires and the
            // instrument was counted as a ninth insert.
            //
            // MEASURED LIVE 2026-09-02 on `Drum Synth Kit` (Drum Machine
            // Designer's own stack, 38 strip children, `kind: unknown`):
            // setting 252 -> EQ display 284 -> **AXGroup "Drum Machine
            // Designer" 328** -> empty `Audio Effect slot.` 353 -> the seven
            // occupied inserts 370…473 (17 px apart, `insert bar` dividers
            // between them) -> 489 -> sends 525. The surface's own list on the
            // same strip read `-- | *Ovrdr | *Bitcr | Pedlba | *Envlp |
            // *St-De | *PtVer | Cha EQ` — seven inserts and one empty slot, no
            // Drum Machine Designer anywhere — so Accessibility published EIGHT
            // names to the eight MCU slots' seven, `pluginListAgreesWithAX`
            // read the count difference as "the PL view is pointed at another
            // channel", and `logic_add_plugin` / `logic_remove_plugin` /
            // `logic_set_insert_bypass` refused EVERY write on that strip
            // (a stray `Gain` could only be got off it by closing the project
            // without saving).
            reading.hasInstrumentSlot = true
            reading.instrument = instrument
            reading.plugins.removeAll { $0 == instrument }
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
