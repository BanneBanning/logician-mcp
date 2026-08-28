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
}
