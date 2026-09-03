import XCTest
@testable import Logician

/// The channel strip's pure half. Every string here is verbatim from Logic Pro
/// 12.3.1 on 2026-08-28 (`Testlåt Copy`): an audio track (`Ivan Effect`), a
/// software-instrument track (`Crash`, with `Q-Sampler` loaded) and a reduced
/// strip (`Drums`, a folder-stack main track that publishes seven children).
/// A failure here is either a Logic change or a regression.
final class ChannelStripTests: XCTestCase {

    // MARK: - Fixtures, in Logic's own AXChildren order

    /// `Ivan Effect`: 36 children. Trimmed to the ones that carry meaning; the
    /// order and the help prefixes are Logic's.
    private func audioStrip() -> [StripChild] {
        [
            StripChild(role: "AXTextField", description: "name", value: "Ivan Effect",
                       help: "Name field. Double-click to rename the channel strip. ", y: 900),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "mute", value: "off",
                       help: "Mute button. ", y: 860),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "solo", value: "off",
                       help: "Solo button. ", y: 860),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "record", value: "off",
                       help: "Record Enable button. ", y: 840),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "monitoring", value: "off",
                       help: "Input Monitoring button. ", y: 840),
            StripChild(role: "AXSlider", description: "volume fader", value: "152",
                       valueDescription: "-2,1 dB", help: "Volume fader. ", y: 700),
            StripChild(role: "AXSlider", description: "pan", value: "0", valueDescription: "0",
                       help: "Pan/Balance knob. ", y: 660),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 640),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 620),
            StripChild(role: "AXButton", description: "Stereo Output",
                       help: "Output slot. Click and hold to choose the channel strip output destination", y: 600),
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 560),
            StripChild(role: "AXButton", description: "audio plug-in", help: "Audio Effect slot. ", y: 420),
            StripChild(role: "AXGroup", description: "Expander", y: 300),
            StripChild(role: "AXGroup", description: "Compressor", y: 320),
            StripChild(role: "AXGroup", description: "Channel EQ", y: 380),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "channel mode", value: "Mono", y: 240),
            StripChild(role: "AXButton", description: "Input 1", help: "Input slot. ", y: 220),
            StripChild(role: "AXButton", description: "EQ", value: "on", help: "EQ display. ", y: 200),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "gain reduction meter",
                       value: "on, 0 dB", help: "Gain reduction meter. ", y: 180),
            StripChild(role: "AXButton", description: "setting", help: "Setting button. ", y: 120),
            StripChild(role: "AXSlider", description: "input gain", value: "-5", valueDescription: "-5",
                       help: "Input Gain field and knob. ", y: 100)
        ]
    }

    /// `Crash`: a software instrument with `Q-Sampler` in the instrument slot,
    /// four empty audio-effect slots and an empty MIDI Effect slot. The
    /// instrument sits BETWEEN the MIDI Effect slot and the inserts in y.
    private func instrumentStrip() -> [StripChild] {
        [
            StripChild(role: "AXButton", description: "setting", help: "Setting button. ", y: 319),
            StripChild(role: "AXButton", description: "library indicator, (null)", value: "off", y: 319),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "gain reduction meter",
                       value: "off", help: "Gain reduction meter. ", y: 340),
            StripChild(role: "AXButton", description: "EQ", value: "off", help: "EQ display. ", y: 351),
            StripChild(role: "AXButton", description: "MIDI plug-in", help: "MIDI Effect slot. ", y: 386),
            StripChild(role: "AXGroup", description: "Q-Sampler", y: 413),
            StripChild(role: "AXButton", description: "library indicator, Q-Sampler", value: "off", y: 413),
            StripChild(role: "AXButton", description: "audio plug-in", help: "Audio Effect slot. ", y: 438),
            StripChild(role: "AXButton", description: "audio plug-in", help: "Audio Effect slot. ", y: 455),
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 525),
            StripChild(role: "AXButton", description: "Stereo Output", help: "Output slot. ", y: 551),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 574),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 597),
            StripChild(role: "AXSlider", description: "pan", value: "0", valueDescription: "0",
                       help: "Pan/Balance knob. ", y: 622),
            StripChild(role: "AXSlider", description: "volume fader", value: "61",
                       valueDescription: "-16,4 dB", help: "Volume fader. ", y: 682),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "mute", value: "off",
                       help: "Mute button. ", y: 864),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "solo", value: "off",
                       help: "Solo button. ", y: 864),
            StripChild(role: "AXTextField", description: "name", value: "Crash",
                       help: "Name field. ", y: 892)
        ]
    }

    /// `Lofi Pad`, verbatim: a software instrument whose instrument slot is
    /// EMPTY while two inserts are loaded — and whose loaded inserts sit
    /// ABOVE the empty audio-effect placeholders. This is the layout that made
    /// the first version of the geometry rule call `Channel EQ` the instrument.
    private func emptyInstrumentStrip() -> [StripChild] {
        [
            StripChild(role: "AXButton", description: "setting", help: "Setting button. ", y: 308),
            StripChild(role: "AXButton", description: "EQ", value: "on", help: "EQ display. ", y: 340),
            StripChild(role: "AXButton", description: "MIDI plug-in", help: "MIDI Effect slot. ", y: 375),
            StripChild(role: "AXButton", description: "Instrument", y: 402),
            StripChild(role: "AXButton", description: "library indicator, (null)", value: "off", y: 402),
            StripChild(role: "AXGroup", description: "Channel EQ", y: 427),
            StripChild(role: "AXButton", description: "library indicator, Channel EQ", value: "off", y: 427),
            StripChild(role: "AXButton", description: "insert bar", y: 444),
            StripChild(role: "AXGroup", description: "AutoFilter", y: 445),
            StripChild(role: "AXButton", description: "audio plug-in", help: "Audio Effect slot. ", y: 461),
            StripChild(role: "AXButton", description: "audio plug-in", help: "Audio Effect slot. ", y: 478),
            StripChild(role: "AXGroup", description: "Bus 2", y: 514),
            StripChild(role: "AXSlider", description: "send knob", value: "9.011382e+08",
                       valueDescription: "-9,0", y: 514),
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 534),
            StripChild(role: "AXButton", description: "Stereo Output", help: "Output slot. ", y: 551),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 574),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 597),
            StripChild(role: "AXSlider", description: "volume fader", value: "90",
                       valueDescription: "-10,6 dB", help: "Volume fader. ", y: 682),
            StripChild(role: "AXTextField", description: "name", value: "Lofi Pad",
                       help: "Name field. ", y: 892)
        ]
    }

    /// `Drums`: the whole strip, all seven children of it.
    private func reducedStrip() -> [StripChild] {
        [
            StripChild(role: "AXTextField", description: "name", value: "Drums", help: "Name field. ", y: 900),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "mute", value: "off",
                       help: "Mute button. ", y: 860),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "solo", value: "off",
                       help: "Solo button. ", y: 860),
            StripChild(role: "AXSlider", description: "volume fader", value: "173",
                       valueDescription: "0,0 dB", help: "Volume fader. ", y: 700),
            StripChild(role: "AXTextField", description: "volume fader level",
                       title: "volume fader level, 0,0 dB", help: "Volume display. ", y: 690),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 640),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 620)
        ]
    }

    /// `Drum Synth Kit`, verbatim (measured live 2026-09-02, all 38 children
    /// trimmed to the rows that carry meaning, y as Logic published it): the
    /// MAIN CHANNEL of Drum Machine Designer's summing track stack. It is
    /// aux-shaped — an Output slot, no Input slot, no channel mode and **no
    /// MIDI Effect slot** — and it hosts an instrument all the same, with the
    /// insert column drawn BOTTOM-UP (slot 1 empty at the top, `Channel EQ`,
    /// the first insert of the chain, at the bottom).
    private func stackMainStrip() -> [StripChild] {
        [
            StripChild(role: "AXButton", description: "Drum Synth Kit",
                       help: "Setting button. ", y: 252),
            StripChild(role: "AXButton", description: "library indicator, Drum Synth Kit",
                       value: "off", help: "Library Focus triangle. ", y: 252),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "gain reduction meter",
                       value: "off", help: "Gain reduction meter. ", y: 273),
            StripChild(role: "AXButton", description: "EQ", value: "on",
                       help: "EQ display. ", y: 284),
            StripChild(role: "AXGroup", description: "Drum Machine Designer", y: 328),
            StripChild(role: "AXButton", description: "audio plug-in",
                       help: "Audio Effect slot. ", y: 353),
            StripChild(role: "AXGroup", description: "Overdrive", y: 370),
            StripChild(role: "AXButton", description: "insert bar", y: 387),
            StripChild(role: "AXGroup", description: "Bitcrusher", y: 388),
            StripChild(role: "AXButton", description: "insert bar", y: 404),
            StripChild(role: "AXGroup", description: "Pedalboard", y: 405),
            StripChild(role: "AXButton", description: "insert bar", y: 421),
            StripChild(role: "AXGroup", description: "Enveloper", y: 422),
            StripChild(role: "AXButton", description: "insert bar", y: 438),
            StripChild(role: "AXGroup", description: "St-Delay", y: 439),
            StripChild(role: "AXButton", description: "insert bar", y: 455),
            StripChild(role: "AXGroup", description: "PtVerb", y: 456),
            StripChild(role: "AXButton", description: "insert bar", y: 472),
            StripChild(role: "AXGroup", description: "Channel EQ", y: 473),
            StripChild(role: "AXButton", description: "audio plug-in",
                       help: "Audio Effect slot. ", y: 489),
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 525),
            StripChild(role: "AXButton", description: "Stereo Output",
                       help: "Output slot. ", y: 551),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 574),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 597),
            StripChild(role: "AXSlider", description: "pan", value: "0", valueDescription: "0",
                       help: "Pan/Balance knob. ", y: 622),
            StripChild(role: "AXSlider", description: "volume fader", value: "122",
                       valueDescription: "-5,1 dB", help: "Volume fader. ", y: 682),
            StripChild(role: "AXTextField", description: "name", value: "Drum Synth Kit",
                       help: "Name field. ", y: 892)
        ]
    }

    /// `Stereo Out`, verbatim (same session): the aux-shaped strip that has NO
    /// instrument, and the one the rule above must not invent one for. The row
    /// above its insert column is the channel-mode BUTTON at 328, and the
    /// column announces itself with an `insert bar` at 353, one pixel above the
    /// first insert.
    private func outputStrip() -> [StripChild] {
        [
            StripChild(role: "AXButton", description: "setting", help: "Setting button. ", y: 252),
            StripChild(role: "AXButton", description: "library indicator, (null)", value: "off",
                       help: "Library Focus triangle. ", y: 252),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "gain reduction meter",
                       value: "on, 0 dB", help: "Gain reduction meter. ", y: 273),
            StripChild(role: "AXButton", description: "EQ", value: "on", help: "EQ display. ", y: 284),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "channel mode",
                       value: "Stereo", help: "Output Channel Mode button. ", y: 328),
            StripChild(role: "AXButton", description: "insert bar", y: 353),
            StripChild(role: "AXGroup", description: "Channel EQ", y: 354),
            StripChild(role: "AXButton", description: "insert bar", y: 370),
            StripChild(role: "AXGroup", description: "Limiter", y: 371),
            StripChild(role: "AXButton", description: "insert bar", y: 387),
            StripChild(role: "AXGroup", description: "Sensor", y: 388),
            StripChild(role: "AXButton", description: "audio plug-in",
                       help: "Audio Effect slot. ", y: 404),
            StripChild(role: "AXButton", description: "audio plug-in",
                       help: "Audio Effect slot. ", y: 421),
            StripChild(role: "AXButton", description: "mastering assistant", y: 498),
            StripChild(role: "AXPopUpButton", description: "group", title: "group, Group",
                       help: "Group slot. ", y: 574),
            StripChild(role: "AXGroup", description: "Read, automation enabled", y: 597),
            StripChild(role: "AXSlider", description: "pan", value: "0", valueDescription: "0",
                       help: "Pan/Balance knob. ", y: 622),
            StripChild(role: "AXSlider", description: "volume fader", value: "173",
                       valueDescription: "0,0 dB", help: "Volume fader. ", y: 682),
            StripChild(role: "AXTextField", description: "name", value: "Stereo Out",
                       help: "Name field. ", y: 892)
        ]
    }

    /// `Ivan Effect`, verbatim (same session): a MONO audio track with five
    /// occupied inserts. Its insert column also opens with an `insert bar`
    /// (404) one pixel above the first insert (405), and the rows above that
    /// are the Input slot and the channel mode — so the aux rule never gets
    /// near it, and the audio rule must keep all five names.
    private func monoAudioStrip() -> [StripChild] {
        [
            StripChild(role: "AXSlider", description: "input gain", value: "-5",
                       valueDescription: "-5", help: "Input Gain field and knob. ", y: 276),
            StripChild(role: "AXButton", description: "setting", help: "Setting button. ", y: 303),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "gain reduction meter",
                       value: "on, 0 dB", help: "Gain reduction meter. ", y: 324),
            StripChild(role: "AXButton", description: "EQ", value: "on", help: "EQ display. ", y: 335),
            StripChild(role: "AXButton", subrole: "AXSwitch", description: "channel mode",
                       value: "Mono", help: "Channel Mode button. ", y: 379),
            StripChild(role: "AXButton", description: "Input 1", help: "Input slot. ", y: 379),
            StripChild(role: "AXButton", description: "insert bar", y: 404),
            StripChild(role: "AXGroup", description: "Channel EQ", y: 405),
            StripChild(role: "AXButton", description: "insert bar", y: 421),
            StripChild(role: "AXGroup", description: "Space D", y: 422),
            StripChild(role: "AXButton", description: "insert bar", y: 438),
            StripChild(role: "AXGroup", description: "ClipDist", y: 439),
            StripChild(role: "AXButton", description: "insert bar", y: 455),
            StripChild(role: "AXGroup", description: "Compressor", y: 456),
            StripChild(role: "AXButton", description: "insert bar", y: 472),
            StripChild(role: "AXGroup", description: "Expander", y: 473),
            StripChild(role: "AXButton", description: "audio plug-in",
                       help: "Audio Effect slot. ", y: 489),
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 525),
            StripChild(role: "AXButton", description: "Stereo Output",
                       help: "Output slot. ", y: 551),
            StripChild(role: "AXSlider", description: "volume fader", value: "152",
                       valueDescription: "-2,1 dB", help: "Volume fader. ", y: 682),
            StripChild(role: "AXTextField", description: "name", value: "Ivan Effect",
                       help: "Name field. ", y: 892)
        ]
    }

    // MARK: - What kind of strip is this

    func testAnInputSlotMakesItAnAudioStrip() {
        let reading = ChannelStrip.read(children: audioStrip())
        XCTAssertEqual(reading.kind, .audio)
        XCTAssertEqual(reading.input, "Input 1")
        XCTAssertEqual(reading.channelMode, "Mono")
        XCTAssertTrue(reading.kindEvidence.contains("an Input slot"))
    }

    func testAMIDIEffectSlotMakesItASoftwareInstrument() {
        let reading = ChannelStrip.read(children: instrumentStrip())
        XCTAssertEqual(reading.kind, .softwareInstrument)
        XCTAssertTrue(reading.hasMIDIEffectSlot)
        XCTAssertNil(reading.input)
    }

    /// The measured folder-stack case. It must NOT read as an audio track with
    /// nothing routed: that would be a lie about a track that has an output.
    func testAStripWithNoOutputSlotIsReducedNotUnrouted() {
        let reading = ChannelStrip.read(children: reducedStrip())
        XCTAssertEqual(reading.kind, .reduced)
        XCTAssertNil(reading.output)
        XCTAssertEqual(reading.childCount, 7)
        XCTAssertTrue(reading.kindEvidence.contains("no Output slot"))
    }

    // MARK: - Routing

    func testTheOutputSlotsDescriptionIsTheDestination() {
        XCTAssertEqual(ChannelStrip.read(children: audioStrip()).output, "Stereo Output")
    }

    func testAnEmptyGroupSlotIsNotAGroup() {
        let reading = ChannelStrip.read(children: audioStrip())
        XCTAssertNil(reading.group, "Logic's empty group slot is labelled 'Group'")
        XCTAssertEqual(reading.groupDisplay, "Group")
    }

    func testANamedGroupIsReported() {
        var children = audioStrip()
        children = children.map { child in
            child.description == "group"
                ? StripChild(role: child.role, description: "group", title: "group, Group 1",
                             help: child.help, y: child.y)
                : child
        }
        let reading = ChannelStrip.read(children: children)
        XCTAssertEqual(reading.group, "Group 1")
    }

    // MARK: - The instrument slot, found by geometry

    func testTheInstrumentIsThePluginBetweenTheMIDISlotAndTheInserts() {
        let reading = ChannelStrip.read(children: instrumentStrip())
        XCTAssertEqual(reading.instrument, "Q-Sampler")
        XCTAssertTrue(reading.hasInstrumentSlot)
        XCTAssertFalse(reading.plugins.contains("Q-Sampler"), "the instrument is not an insert")
    }

    /// The regression this rule was rewritten for. An EMPTY instrument slot
    /// publishes an `Instrument` button above the loaded inserts, and calling
    /// the first insert the instrument was a confident wrong answer.
    func testAnEmptyInstrumentSlotIsNotTheFirstInsert() {
        let reading = ChannelStrip.read(children: emptyInstrumentStrip())
        XCTAssertEqual(reading.kind, .softwareInstrument)
        XCTAssertTrue(reading.hasInstrumentSlot)
        XCTAssertNil(reading.instrument)
        XCTAssertEqual(reading.plugins, ["Channel EQ", "AutoFilter"])
        XCTAssertEqual(reading.sends, [ChannelStrip.Send(destination: "Bus 2", level: "-9,0")])
    }

    func testAnAudioStripHasNoInstrumentSlotAndItsPluginsAreAllInserts() {
        let reading = ChannelStrip.read(children: audioStrip())
        XCTAssertNil(reading.instrument)
        XCTAssertFalse(reading.hasInstrumentSlot)
        XCTAssertEqual(reading.plugins, ["Expander", "Compressor", "Channel EQ"])
    }

    // MARK: - The instrument on a strip with no MIDI Effect slot

    /// The defect this rule was added for: a summing track stack's main
    /// channel publishes no MIDI Effect slot, so the geometry rule above never
    /// ran and `Drum Machine Designer` was counted as an eighth insert.
    func testTheStackMainChannelsInstrumentIsNotOneOfItsInserts() {
        let reading = ChannelStrip.read(children: stackMainStrip())
        XCTAssertFalse(reading.hasMIDIEffectSlot)
        XCTAssertNil(reading.input, "an aux-shaped strip publishes no Input slot")
        XCTAssertEqual(reading.instrument, "Drum Machine Designer")
        XCTAssertTrue(reading.hasInstrumentSlot)
        XCTAssertEqual(
            reading.plugins,
            ["Overdrive", "Bitcrusher", "Pedalboard", "Enveloper", "St-Delay", "PtVerb", "Channel EQ"]
        )
    }

    // MARK: - Flagging the instrument's OWN row in an insert list

    /// `logic_list_inserts {route: "ax"}` walks the same `AXGroup` shapes
    /// `ChannelStrip.read` does and cannot tell an occupied instrument slot
    /// from a real insert on its own — that is exactly why `logic_track_info`
    /// asks `ChannelStrip.read` for the instrument's name and flags the
    /// matching row `is_instrument_slot`. `InsertSlot.isInstrumentSlot` is
    /// that comparison, isolated: pure, so both readers can flag the row the
    /// same way instead of one of them silently disagreeing.
    func testTheInstrumentRowIsFlaggedAgainstTheGeometryDecidedName() {
        XCTAssertTrue(InsertSlot.isInstrumentSlot(name: "Q-Sampler", instrument: "Q-Sampler"))
        XCTAssertTrue(
            InsertSlot.isInstrumentSlot(name: "Drum Machine Designer", instrument: "Drum Machine Designer")
        )
        XCTAssertFalse(InsertSlot.isInstrumentSlot(name: "Channel EQ", instrument: "Q-Sampler"))
    }

    /// A track with no instrument slot at all (an audio strip, or an
    /// instrument track whose slot reads empty) must never flag a row —
    /// there is no name to agree with, not a name that happens to match
    /// nothing.
    func testNoInstrumentNeverFlagsARow() {
        XCTAssertFalse(InsertSlot.isInstrumentSlot(name: "Channel EQ", instrument: nil))
        XCTAssertFalse(InsertSlot.isInstrumentSlot(name: "", instrument: nil))
        XCTAssertFalse(InsertSlot.isInstrumentSlot(name: "Channel EQ", instrument: ""))
    }

    /// The consequence, and the reason the fix belongs in the classifier: the
    /// count check every plug-in WRITE is gated on now passes on this strip,
    /// against the row the surface really showed (7 inserts and one empty
    /// slot, no Drum Machine Designer, measured 2026-09-02).
    func testTheStackMainChannelNowAgreesWithTheSurfacesOwnRow() {
        let reading = ChannelStrip.read(children: stackMainStrip())
        let mcuRow = ["--", "*Ovrdr", "*Bitcr", "Pedlba", "*Envlp", "*St-De", "*PtVer", "Cha EQ"]
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(mcuCells: mcuRow, axNames: reading.plugins), true
        )
        // And it is a real check, not a vacuous one: the list Accessibility
        // used to hand over — the same names plus the instrument — is exactly
        // what made it refuse.
        XCTAssertEqual(
            MCUController.pluginListAgreesWithAX(
                mcuCells: mcuRow, axNames: reading.plugins + ["Drum Machine Designer"]
            ),
            false
        )
    }

    /// The second half of the same live refusal, and it is independent of the
    /// instrument: a BYPASSED insert spends one of its six LCD characters on
    /// the bypass marker, so `Overdrive` arrives as `*Ovrdr` — five characters
    /// of name — and the six-character plausibility floor threw it out. Five
    /// of `Drum Synth Kit`'s seven inserts are bypassed.
    func testABypassedCellIsJudgedOnTheFiveCharactersItHasLeft() {
        XCTAssertTrue(
            MCUController.lcdAbbreviationPlausible(track: "Overdrive", lcd: "Ovrdr", cellWidth: 5)
        )
        XCTAssertFalse(
            MCUController.lcdAbbreviationPlausible(track: "Overdrive", lcd: "Ovrdr"),
            "with all six characters available, five of them is not an abbreviation Logic makes"
        )
        // And the floor still does its job on the marker-free width: a short
        // cell cannot stand for a long name.
        XCTAssertFalse(
            MCUController.lcdAbbreviationPlausible(track: "Stereo Out", lcd: "St", cellWidth: 5)
        )
    }

    /// An output strip is aux-shaped too — no Input slot, no MIDI Effect slot —
    /// and has no instrument. Naming its topmost insert one would break every
    /// plug-in write on `Stereo Out` the way the missing rule broke them on the
    /// stack's main channel.
    func testAnOutputStripIsNotGivenAnInstrument() {
        let reading = ChannelStrip.read(children: outputStrip())
        XCTAssertNil(reading.instrument)
        XCTAssertFalse(reading.hasInstrumentSlot)
        XCTAssertEqual(reading.plugins, ["Channel EQ", "Limiter", "Sensor"])
    }

    func testAMonoAudioStripKeepsAllFiveOfItsInserts() {
        let reading = ChannelStrip.read(children: monoAudioStrip())
        XCTAssertEqual(reading.kind, .audio)
        XCTAssertEqual(reading.channelMode, "Mono")
        XCTAssertNil(reading.instrument)
        XCTAssertEqual(
            reading.plugins, ["Channel EQ", "Space D", "ClipDist", "Compressor", "Expander"]
        )
    }

    /// An `Instrument` placeholder is Logic saying the slot is there and empty.
    /// It vetoes the geometry answer outright — on this shape the row above the
    /// insert column would otherwise be read as a loaded instrument.
    func testAnEmptyInstrumentPlaceholderVetoesTheAuxRule() {
        var children = stackMainStrip()
        children.append(StripChild(role: "AXButton", description: "Instrument", y: 328))
        let reading = ChannelStrip.read(children: children)
        XCTAssertNil(reading.instrument)
        XCTAssertTrue(reading.hasInstrumentSlot)
        XCTAssertTrue(reading.plugins.contains("Drum Machine Designer"))
    }

    /// The rule reads the insert COLUMN's top edge, so a strip whose column is
    /// marked only by empty placeholders (nothing loaded at all) has nothing
    /// above it to mistake for an instrument.
    func testAnAuxWithNoPluginsAtAllGetsNoInstrument() {
        let children = stackMainStrip().filter { $0.role != "AXGroup" || $0.slotKind != nil }
        let reading = ChannelStrip.read(children: children)
        XCTAssertNil(reading.instrument)
        XCTAssertTrue(reading.plugins.isEmpty)
    }

    // MARK: - Sends

    func testASendIsAGroupFollowedByItsKnob() {
        let children = [
            StripChild(role: "AXButton", description: "send button", help: "Send slot. ", y: 560),
            StripChild(role: "AXGroup", description: "Bus 2", y: 540),
            StripChild(role: "AXSlider", description: "send knob", value: "9.011382e+08",
                       valueDescription: "-9,0", y: 540)
        ]
        let reading = ChannelStrip.read(children: children)
        XCTAssertEqual(reading.sends, [ChannelStrip.Send(destination: "Bus 2", level: "-9,0")])
        XCTAssertTrue(reading.plugins.isEmpty, "a send destination is not a plugin")
    }

    // MARK: - Small pure pieces

    func testTheArrowHalfOfARoutingTitleIsLogicExplainingItself() {
        XCTAssertEqual(ChannelStrip.routingHead("Bus 2 → Aux 2"), "Bus 2")
        XCTAssertEqual(ChannelStrip.routingHead("Bus 5 ← Acke Slagverk , Ivan Slagverk"), "Bus 5")
        XCTAssertEqual(ChannelStrip.routingHead("Stereo Output"), "Stereo Output")
    }

    func testARequestMayBeTheHeadOrTheWholeTitle() {
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Bus 2 → Aux 2", requested: "Bus 2"))
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Bus 2 → Aux 2", requested: "Bus 2 → Aux 2"))
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Stereo Output", requested: "stereo output"))
        XCTAssertFalse(ChannelStrip.routingMatches(item: "Bus 20 → Aux 4", requested: "Bus 2"))
    }

    /// The group menu decorates on the other side: `"Group 1: (new)"` is the
    /// offer to create group 1, and a request for `"Group 1"` must find it.
    func testAColonEndsTheHeadToo() {
        XCTAssertEqual(ChannelStrip.routingHead("Group 1: (new)"), "Group 1")
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Group 1: (new)", requested: "Group 1"))
    }

    /// The live regression: the menu says `No Group`, the slot then reads
    /// `Group`, and comparing them literally called a working write a failure.
    func testTheMenusNoAndTheSlotsPlaceholderAreTheSameState() {
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Group", requested: "No Group"))
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Input", requested: "No Input"))
        XCTAssertTrue(ChannelStrip.routingMatches(item: "Output", requested: "No Output"))
        XCTAssertFalse(ChannelStrip.routingMatches(item: "Stereo Output", requested: "No Output"))
        XCTAssertFalse(ChannelStrip.routingMatches(item: "Output", requested: "No Input"))
    }

    /// Once a strip joins a group, the slot drops the word: the menu item is
    /// `"Group 1: (new)"` and the slot then reads bare `"1"`. Measured live —
    /// and it turned a write that had worked into a readback mismatch.
    func testAGroupSlotReadsTheBareNumberOnceItIsInOne() {
        XCTAssertTrue(ChannelStrip.routingMatches(item: "1", requested: "Group 1"))
        XCTAssertTrue(ChannelStrip.routingMatches(item: "1", requested: "Group 1: (new)"))
        XCTAssertFalse(ChannelStrip.routingMatches(item: "1", requested: "Group 2"))
        XCTAssertFalse(ChannelStrip.routingMatches(item: "1", requested: "No Group"))
        var children = audioStrip()
        children = children.map { child in
            child.description == "group"
                ? StripChild(role: child.role, description: "group", title: "group, 1",
                             help: child.help, y: child.y)
                : child
        }
        XCTAssertEqual(ChannelStrip.read(children: children).group, "1")
    }

    func testAnUnassignedInputSlotReadsAsNoInputNotAsAnInputNamedInput() {
        var children = audioStrip()
        children = children.map { child in
            child.slotKind == .input
                ? StripChild(role: "AXButton", description: "Input", help: child.help, y: child.y)
                : child
        }
        let reading = ChannelStrip.read(children: children)
        XCTAssertNil(reading.input)
        XCTAssertEqual(reading.inputDisplay, "Input")
        XCTAssertEqual(reading.kind, .audio, "an empty input SLOT is still an input slot")
    }

    func testDecibelsParseWithACommaOrAPoint() {
        XCTAssertEqual(ChannelStrip.decibels("-10,6 dB"), -10.6)
        XCTAssertEqual(ChannelStrip.decibels("1.0 dB"), 1.0)
        XCTAssertEqual(ChannelStrip.decibels("0,0 dB"), 0.0)
        XCTAssertNil(ChannelStrip.decibels("-oo"))
    }

    func testTheAutomationModeIsTheHeadOfTheGroupDescription() {
        XCTAssertEqual(
            ChannelStrip.automationMode(fromGroupDescription: "Read, automation enabled"), "Read"
        )
        XCTAssertEqual(
            ChannelStrip.automationMode(fromGroupDescription: "Latch, automation enabled"), "Latch"
        )
    }

    /// The gain reduction meter publishes `"on, 0 dB"`, so a naive `== "on"`
    /// would read it as off and a naive `!= "off"` would read every unknown
    /// string as on.
    func testASwitchStateReadsTheFirstWordAndRefusesTheRest() {
        XCTAssertEqual(ChannelStrip.switchState("on"), true)
        XCTAssertEqual(ChannelStrip.switchState("off"), false)
        XCTAssertEqual(ChannelStrip.switchState("on, 0 dB"), true)
        XCTAssertNil(ChannelStrip.switchState("Mono"))
        XCTAssertNil(ChannelStrip.switchState(""))
    }

    // MARK: - VolumeWrite: what one logic_set_track_volume call resolves to

    /// The arithmetic behind `relative_db` and the comparison behind
    /// `expected_current_db`. Both run inside the write path, against a dB the
    /// route has just read, so a mistake here writes a wrong fader value and
    /// then reports it as verified.

    func testAnAbsoluteRequestIgnoresWhereTheFaderIs() throws {
        let write = try VolumeWrite(absoluteDb: -6, relativeDb: nil, expectedCurrentDb: nil)
        XCTAssertEqual(try write.target(currentDb: -20), -6)
        XCTAssertEqual(try write.target(currentDb: 0), -6)
    }

    func testARelativeRequestIsMeasuredFromTheValueReadBeforeTheWrite() throws {
        let louder = try VolumeWrite(absoluteDb: nil, relativeDb: 2, expectedCurrentDb: nil)
        XCTAssertEqual(try louder.target(currentDb: -14.2), -12.2, accuracy: 1e-9)
        let quieter = try VolumeWrite(absoluteDb: nil, relativeDb: -3, expectedCurrentDb: nil)
        XCTAssertEqual(try quieter.target(currentDb: 0), -3, accuracy: 1e-9)
    }

    func testDbAndRelativeDbAreMutuallyExclusiveAndOneIsRequired() {
        XCTAssertThrowsError(
            try VolumeWrite(absoluteDb: -6, relativeDb: 2, expectedCurrentDb: nil)
        ) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
        XCTAssertThrowsError(
            try VolumeWrite(absoluteDb: nil, relativeDb: nil, expectedCurrentDb: -6)
        ) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
    }

    func testExpectedCurrentDbRefusesBeforeAnythingIsWritten() throws {
        let write = try VolumeWrite(absoluteDb: -6, relativeDb: nil, expectedCurrentDb: -12)
        XCTAssertThrowsError(try write.target(currentDb: -3)) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "precondition_failed")
        }
    }

    /// Results round dB to one decimal, so an agent passing back exactly the
    /// number the previous call reported must not be refused over rounding.
    func testExpectedCurrentDbToleratesTheRoundingThisServerItselfPublishes() throws {
        let write = try VolumeWrite(absoluteDb: -6, relativeDb: nil, expectedCurrentDb: -12.3)
        XCTAssertEqual(try write.target(currentDb: -12.34), -6)
        XCTAssertEqual(try write.target(currentDb: -12.79), -6)
        XCTAssertThrowsError(try write.target(currentDb: -12.9))
    }

    /// A relative move on a stale precondition must refuse rather than land
    /// somewhere nobody asked for.
    func testARelativeRequestStillHonoursItsPrecondition() throws {
        let write = try VolumeWrite(absoluteDb: nil, relativeDb: 2, expectedCurrentDb: -6)
        XCTAssertEqual(try write.target(currentDb: -6), -4, accuracy: 1e-9)
        XCTAssertThrowsError(try write.target(currentDb: -1))
    }

    // MARK: - What `verified` means on a volume write

    private func verdict(
        landed: Double, target: Double = -6, tolerance: Double = 0.15,
        route: String = "bridge_converge"
    ) -> [String: Any] {
        MCUController.volumeVerdict(
            trackName: "Ivan Effect", startDb: -12, targetDb: target,
            landedDb: landed, toleranceDb: tolerance, writeRoute: route
        )
    }

    func testAValueInsideTheCallersToleranceIsVerified() {
        let inside = verdict(landed: -6.1)
        XCTAssertEqual(inside["verified"] as? Bool, true)
        XCTAssertEqual(inside["success"] as? Bool, true)
        XCTAssertEqual(inside["after_db"] as? Double, -6.1)
        XCTAssertEqual(inside["deviation_db"] as? Double, 0.1)
        // Nothing to explain when the write did what it said.
        XCTAssertNil(inside["verification_note"])
    }

    /// The 0.6 dB floor, gone. This is the exact case it used to cover: the
    /// caller asked for 0.15 dB, the fader stopped 0.5 dB out, and the result
    /// said `verified: true` because 0.5 < max(0.15, 0.6). Four times the
    /// tolerance asked for, reported as confirmed.
    func testAValueOutsideTheCallersToleranceIsNotVerifiedEvenUnderSixTenths() {
        let outside = verdict(landed: -6.5)
        XCTAssertEqual(outside["verified"] as? Bool, false)
        // The write still happened and the result still says where the fader
        // is - this is an honest miss, not a failure.
        XCTAssertEqual(outside["success"] as? Bool, true)
        XCTAssertEqual(outside["after_db"] as? Double, -6.5)
        XCTAssertEqual(outside["deviation_db"] as? Double, 0.5)
        let note = outside["verification_note"] as? String
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("-6.5") == true, note ?? "")
        XCTAssertTrue(note?.contains("verified is false") == true, note ?? "")
    }

    /// The boundary belongs to the caller: exactly at the tolerance is inside.
    func testTheToleranceBoundaryIsInclusive() {
        XCTAssertEqual(verdict(landed: -6.15)["verified"] as? Bool, true)
        XCTAssertEqual(verdict(landed: -6.16)["verified"] as? Bool, false)
    }

    /// A caller who asks for a WIDER tolerance gets it — the rule is the
    /// caller's number in both directions, not a floor and not a ceiling.
    func testAWiderToleranceIsHonouredToo() {
        XCTAssertEqual(verdict(landed: -6.5, tolerance: 1.0)["verified"] as? Bool, true)
        XCTAssertEqual(verdict(landed: -7.5, tolerance: 1.0)["verified"] as? Bool, false)
    }

    /// Both write paths report through the same rule, so the route cannot
    /// change what `verified` means — only what produced the value.
    func testEveryWriteRouteReportsTheSameVerdictShape() {
        for route in ["bridge_converge", "bridge_converge+vpot_refine", "mcu_vpot_converge"] {
            let payload = verdict(landed: -6.5, route: route)
            XCTAssertEqual(payload["verified"] as? Bool, false, route)
            XCTAssertEqual(payload["write_route"] as? String, route)
            XCTAssertEqual(payload["readback_route"] as? String, "mcu_lcd_db")
            XCTAssertEqual(payload["tolerance_db"] as? Double, 0.15, route)
        }
    }
}
