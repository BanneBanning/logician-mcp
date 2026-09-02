import XCTest
@testable import Logician

/// Reading a plugin's setting menu. Pure: no Logic, no bridge.
///
/// Every fixture below is a menu that was actually read off a running Logic on
/// 2026-08-27 (project `Testlåt Copy.logicx`), so these tests are a
/// regression net around observed behaviour rather than around a guess.
final class PluginPresetTests: XCTestCase {

    // MARK: - Fixtures, verbatim from the live probe

    /// The command block above the settings. Twenty items, identical in every
    /// plugin's menu — Compressor, Channel EQ, Limiter, Sensor, Pitch Shifter
    /// and third-party Trilian all published exactly this prefix.
    private func commandBlock(recallDefaultEnabled: Bool = true) -> [PresetMenuItem] {
        [
            PresetMenuItem(title: "Setting", enabled: false),
            PresetMenuItem(title: "", enabled: false),
            PresetMenuItem(title: "Undo", enabled: false),
            PresetMenuItem(title: "Redo", enabled: false),
            PresetMenuItem(title: "Include Plug-in Undo Steps in Project Undo History"),
            PresetMenuItem(title: "", enabled: false),
            PresetMenuItem(title: "Next"),
            PresetMenuItem(title: "Previous"),
            PresetMenuItem(title: "", enabled: false),
            PresetMenuItem(title: "Copy"),
            PresetMenuItem(title: "Paste", enabled: false),
            PresetMenuItem(title: "", enabled: false),
            PresetMenuItem(title: "Load…"),
            PresetMenuItem(title: "Save", enabled: false),
            PresetMenuItem(title: "Save As…"),
            PresetMenuItem(title: "Save A Copy As…"),
            PresetMenuItem(title: "Save As Default"),
            PresetMenuItem(title: "Recall Default", enabled: recallDefaultEnabled),
            PresetMenuItem(title: "Delete", enabled: false),
            PresetMenuItem(title: "", enabled: false)
        ]
    }

    /// Compressor on the track "Bas": six categories, 156 settings, the loaded
    /// one marked "✓" on its leaf and "-" on its category. Trimmed to the
    /// leaves that carry the argument; the counts are asserted separately.
    private var compressorMenu: [PresetMenuItem] {
        commandBlock() + [
            PresetMenuItem(title: "01 Drums", children: [
                PresetMenuItem(title: "Classic Drums"),
                PresetMenuItem(title: "Drum Mix"),
                PresetMenuItem(title: "Rock Snare Top")
            ]),
            PresetMenuItem(title: "02 Keyboards", children: [
                PresetMenuItem(title: "FET Clav"),
                PresetMenuItem(title: "Piano")
            ]),
            PresetMenuItem(title: "03 Guitars", markChar: "-", children: [
                PresetMenuItem(title: "Acoustic Guitar"),
                PresetMenuItem(title: "FET Bass"),
                PresetMenuItem(title: "FET Electric Bass", markChar: "✓"),
                PresetMenuItem(title: "Rock Bass")
            ]),
            PresetMenuItem(title: "04 Voice", children: [
                PresetMenuItem(title: "Rock Bass") // deliberate name clash, see below
            ])
        ]
    }

    /// Limiter on "Stereo Out": eleven settings, FLAT — no categories at all,
    /// and none of them marked because the header read "Default Preset".
    private var limiterMenu: [PresetMenuItem] {
        commandBlock() + [
            "Classic Soft Knee", "Fast and Loud", "Hard Clipping", "Modern High End",
            "Modern Presence", "Pumping", "Punchy", "Radical Loudness",
            "Soft and Silky", "Standard Master", "Warm Master"
        ].map { PresetMenuItem(title: $0) }
    }

    /// Sensor on "Stereo Out" (and Trilian on "Bas"): the command block and
    /// nothing after it. A real answer — the plugin ships no factory settings.
    private var noSettingsMenu: [PresetMenuItem] {
        commandBlock(recallDefaultEnabled: false)
    }

    // MARK: - Where the settings begin

    func testTheCommandBlockIsExactlyTwentyItemsInEveryObservedMenu() {
        // The single number this whole file hangs on. If a Logic update adds a
        // command, this is the test that fails first — and it fails loudly
        // rather than by silently listing "Undo" as a preset.
        XCTAssertEqual(presetRegionStart(compressorMenu), 20)
        XCTAssertEqual(presetRegionStart(limiterMenu), 20)
        XCTAssertEqual(presetRegionStart(noSettingsMenu), 20)
    }

    func testAMenuWithNothingAfterTheCommandBlockYieldsNoSettings() {
        XCTAssertEqual(presetRegionStart(noSettingsMenu), noSettingsMenu.count)
        XCTAssertTrue(flattenPresetMenu(noSettingsMenu).isEmpty)
    }

    func testDeleteIsTheAnchorSoAnAddedCommandDoesNotLeakIntoTheList() {
        // Logic inserting one more command *inside* the block must not turn it
        // into a preset name. The separator-based fallback would survive this
        // too; the Delete anchor is what survives an added command AFTER the
        // last separator of the block.
        var menu = commandBlock()
        menu.insert(PresetMenuItem(title: "Reveal in Finder"), at: 18)
        menu += [PresetMenuItem(title: "Classic Soft Knee")]
        let entries = flattenPresetMenu(menu)
        XCTAssertEqual(entries.map(\.name), ["Classic Soft Knee"])
    }

    func testWithoutADeleteItemTheLastSeparatorEndsTheCommandBlock() {
        // The fallback for a Logic version (or a localization) that does not
        // publish "Delete". Both rules agree on every observed menu; this
        // pins the fallback's own behaviour.
        var menu = commandBlock().filter { $0.title != "Delete" }
        menu += [PresetMenuItem(title: "Warm Master")]
        XCTAssertEqual(flattenPresetMenu(menu).map(\.name), ["Warm Master"])
    }

    func testAMenuWithNoAnchorAtAllIsReadAsAllSettings() {
        // No "Delete", no separator: the honest reading is "no command block
        // found", which surfaces the commands in the list where an agent can
        // see something is wrong — better than an empty list that reads as
        // "this plugin has no presets".
        let menu = [PresetMenuItem(title: "One"), PresetMenuItem(title: "Two")]
        XCTAssertEqual(presetRegionStart(menu), 0)
        XCTAssertEqual(flattenPresetMenu(menu).map(\.name), ["One", "Two"])
    }

    // MARK: - Flattening

    func testCategoriesAreFlattenedButKeepTheirNames() {
        let entries = flattenPresetMenu(compressorMenu)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.name, "Classic Drums")
        XCTAssertEqual(entries.first?.category, "01 Drums")
        XCTAssertEqual(entries.first?.qualifiedName, "01 Drums/Classic Drums")
        // Menu order is preserved: an agent that steps the list gets the same
        // order Logic paints.
        XCTAssertEqual(entries.map(\.name).prefix(3), ["Classic Drums", "Drum Mix", "Rock Snare Top"])
    }

    func testAFlatMenuProducesEntriesWithoutACategory() {
        let entries = flattenPresetMenu(limiterMenu)
        XCTAssertEqual(entries.count, 11)
        XCTAssertTrue(entries.allSatisfy { $0.category == nil })
        XCTAssertEqual(entries.first?.qualifiedName, "Classic Soft Knee")
        XCTAssertEqual(entries.last?.name, "Warm Master")
    }

    func testTheLoadedSettingIsTheLEAFWithAMarkCharNotItsCategory() {
        // The category carries "-" and the leaf carries "✓". Reading the
        // category's mark as "active" would report "03 Guitars" as the loaded
        // setting, which is not a setting at all.
        let entries = flattenPresetMenu(compressorMenu)
        let active = entries.filter(\.active)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.name, "FET Electric Bass")
        XCTAssertEqual(active.first?.qualifiedName, "03 Guitars/FET Electric Bass")
    }

    func testAMenuWithNothingMarkedHasNoActiveEntry() {
        // Observed on Limiter and Channel EQ, whose header read
        // "Default Preset" — a state that is not any named setting.
        XCTAssertTrue(flattenPresetMenu(limiterMenu).allSatisfy { !$0.active })
    }

    func testSeparatorsInsideASubmenuAreSkipped() {
        let menu = commandBlock() + [
            PresetMenuItem(title: "Category", children: [
                PresetMenuItem(title: "One"),
                PresetMenuItem(title: "", enabled: false),
                PresetMenuItem(title: "Two")
            ])
        ]
        XCTAssertEqual(flattenPresetMenu(menu).map(\.name), ["One", "Two"])
    }

    func testEntryDictionaryCarriesNullRatherThanAMissingCategory() {
        let flat = PresetEntry(name: "Punchy", category: nil, active: false)
        XCTAssertTrue(flat.dictionary["category"] is NSNull)
        let nested = PresetEntry(name: "Rock Bass", category: "03 Guitars", active: true)
        XCTAssertEqual(nested.dictionary["category"] as? String, "03 Guitars")
        XCTAssertEqual(nested.dictionary["active"] as? Bool, true)
    }

    // MARK: - One menu cycle: entries and elements line up

    /// The Accessibility side keeps one AXUIElement per menu node and picks
    /// the leaf to press by the INDEX of the entry that matched, so a
    /// position list that does not line up with `flattenPresetMenu` would
    /// press the wrong setting — the one failure mode of reading and pressing
    /// in a single menu cycle. Everything below pins that alignment.
    private func names(at positions: [PresetMenuPosition], in items: [PresetMenuItem]) -> [String] {
        positions.map { position in
            let item = items[position.item]
            guard let child = position.child else { return item.title }
            return item.children[child].title
        }
    }

    func testEveryEntryHasExactlyOnePositionInTheSameOrder() {
        for menu in [compressorMenu, limiterMenu, noSettingsMenu] {
            let entries = flattenPresetMenu(menu)
            let positions = flattenPresetMenuPositions(menu)
            XCTAssertEqual(positions.count, entries.count)
            XCTAssertEqual(names(at: positions, in: menu), entries.map(\.name))
        }
    }

    func testAFlatMenusPositionsPointAtTheTopLevelItemItself() {
        let positions = flattenPresetMenuPositions(limiterMenu)
        XCTAssertTrue(positions.allSatisfy { $0.child == nil })
        XCTAssertEqual(positions.first, PresetMenuPosition(item: 20, child: nil))
    }

    func testACategorysPositionsCarryTheChildIndex() {
        let positions = flattenPresetMenuPositions(compressorMenu)
        // "01 Drums" is item 20, and its three settings are children 0-2.
        XCTAssertEqual(positions.prefix(3), [
            PresetMenuPosition(item: 20, child: 0),
            PresetMenuPosition(item: 20, child: 1),
            PresetMenuPosition(item: 20, child: 2)
        ])
    }

    func testASeparatorInsideASubmenuShiftsTheChildIndexButNotTheEntryIndex() {
        // The alignment case that an off-by-one would hide: the separator is
        // dropped from the ENTRIES but still occupies a child slot, so the
        // element for "Two" is child 2, not child 1.
        let menu = commandBlock() + [
            PresetMenuItem(title: "Category", children: [
                PresetMenuItem(title: "One"),
                PresetMenuItem(title: "", enabled: false),
                PresetMenuItem(title: "Two")
            ])
        ]
        let positions = flattenPresetMenuPositions(menu)
        XCTAssertEqual(positions, [
            PresetMenuPosition(item: 20, child: 0),
            PresetMenuPosition(item: 20, child: 2)
        ])
        XCTAssertEqual(names(at: positions, in: menu), ["One", "Two"])
    }

    func testTheEntryAMatchResolvesToHasOneUnambiguousIndex() {
        // `selectPreset` presses `entries.firstIndex(of: entry)`. A name that
        // could mean two rows never gets that far — it comes back ambiguous —
        // so every resolved entry has exactly one index, and it is the row
        // whose element the press reuses.
        let entries = flattenPresetMenu(compressorMenu)
        guard case .resolved(let hit) = matchPresetName("04 Voice/Rock Bass", in: entries) else {
            return XCTFail("expected a resolution")
        }
        XCTAssertEqual(entries.filter { $0 == hit }.count, 1)
        guard let index = entries.firstIndex(of: hit) else { return XCTFail("no index") }
        XCTAssertEqual(names(at: flattenPresetMenuPositions(compressorMenu), in: compressorMenu)[index],
                       "Rock Bass")
        XCTAssertEqual(entries[index].category, "04 Voice")
    }

    // MARK: - Matching a requested name

    func testAnExactNameResolves() {
        let entries = flattenPresetMenu(limiterMenu)
        guard case .resolved(let hit) = matchPresetName("Warm Master", in: entries) else {
            return XCTFail("expected a resolution")
        }
        XCTAssertEqual(hit.name, "Warm Master")
    }

    func testMatchingIgnoresCaseAndDiacriticsAndSurroundingSpace() {
        let entries = flattenPresetMenu(limiterMenu)
        for spelling in ["warm master", "WARM MASTER", "  Warm Master  ", "Wärm Måster"] {
            guard case .resolved(let hit) = matchPresetName(spelling, in: entries) else {
                return XCTFail("'\(spelling)' should resolve")
            }
            XCTAssertEqual(hit.name, "Warm Master")
        }
    }

    func testANameInTwoCategoriesIsAmbiguousWithTheQualifiedPathsOffered() {
        // The fixture's deliberate clash: "Rock Bass" exists under both
        // "03 Guitars" and "04 Voice". Guessing one would load the wrong
        // setting and overwrite the plugin, so the refusal names both.
        let entries = flattenPresetMenu(compressorMenu)
        guard case .ambiguous(let paths) = matchPresetName("Rock Bass", in: entries) else {
            return XCTFail("expected ambiguity")
        }
        XCTAssertEqual(paths, ["03 Guitars/Rock Bass", "04 Voice/Rock Bass"])
    }

    func testAQualifiedPathResolvesTheAmbiguity() {
        let entries = flattenPresetMenu(compressorMenu)
        for spelling in ["04 Voice/Rock Bass", "04 Voice > Rock Bass", "04 voice - rock bass"] {
            guard case .resolved(let hit) = matchPresetName(spelling, in: entries) else {
                return XCTFail("'\(spelling)' should resolve")
            }
            XCTAssertEqual(hit.category, "04 Voice")
            XCTAssertEqual(hit.name, "Rock Bass")
        }
    }

    func testAQualifiedPathWhoseCategoryIsWrongFallsBackToTheBareName() {
        // A setting whose own name contains a slash would otherwise be
        // unreachable. "Nope/Warm Master" has no category "Nope", so the bare
        // name gets its turn — and here it is unique.
        let entries = flattenPresetMenu(limiterMenu)
        if case .resolved = matchPresetName("Nope/Warm Master", in: entries) {
            // The bare-name attempt matched nothing ("Nope/Warm Master" is not
            // a setting), so this must NOT resolve.
            return XCTFail("a bogus path must not resolve to something")
        }
        guard case .notFound = matchPresetName("Nope/Warm Master", in: entries) else {
            return XCTFail("expected not found")
        }
    }

    func testAMissingNameIsRefusedWithTheAvailableOnesListed() {
        let entries = flattenPresetMenu(limiterMenu)
        guard case .notFound(let available) = matchPresetName("Brickwall", in: entries) else {
            return XCTFail("expected not found")
        }
        XCTAssertEqual(available.count, 11)
        XCTAssertTrue(available.contains("Punchy"))
    }

    func testMatchingIsNeverFuzzy() {
        // A near miss must be a question back to the agent: loading the wrong
        // setting overwrites every parameter and there is no undo to promise.
        let entries = flattenPresetMenu(limiterMenu)
        for near in ["Warm", "Warm Master 2", "WarmMaster"] {
            guard case .notFound = matchPresetName(near, in: entries) else {
                return XCTFail("'\(near)' must not resolve")
            }
        }
    }

    func testAnEmptyMenuRefusesEveryName() {
        guard case .notFound(let available) = matchPresetName(
            "Anything", in: flattenPresetMenu(noSettingsMenu)
        ) else { return XCTFail("expected not found") }
        XCTAssertTrue(available.isEmpty)
    }

    // MARK: - Errors an agent branches on

    func testPresetErrorsCarryTheDocumentedCodes() {
        XCTAssertEqual(
            LogicianError.presetNotFound(plugin: "Limiter", requested: "X", available: []).code,
            "not_found"
        )
        XCTAssertEqual(
            LogicianError.presetAmbiguous(requested: "Rock Bass", paths: ["a", "b"]).code,
            "ambiguous"
        )
    }

    func testNotFoundSaysNothingWasLoadedAndNamesTheWayOut() {
        let message = LogicianError.presetNotFound(
            plugin: "Compressor", requested: "Brickwall", available: ["Punchy", "Warm Master"]
        ).errorDescription ?? ""
        XCTAssertTrue(message.contains("Nothing was loaded"))
        XCTAssertTrue(message.contains("Punchy"))
        XCTAssertTrue(message.contains("action 'list'"))
    }

    func testNotFoundOnAPluginWithNoSettingsSaysThatInsteadOfListingNothing() {
        let message = LogicianError.presetNotFound(
            plugin: "Sensor", requested: "Anything", available: []
        ).errorDescription ?? ""
        XCTAssertTrue(message.contains("no factory settings at all"))
    }

    func testALongNameListIsSampledNotDumped() {
        // A Compressor offers 156 settings and a Channel EQ 114; an error
        // string is not the place for all of them.
        let names = (1...156).map { "Setting \($0)" }
        let sample = presetNameSample(names)
        XCTAssertTrue(sample.contains("Setting 1"))
        XCTAssertTrue(sample.contains("144 more"))
        XCTAssertFalse(sample.contains("Setting 156"))
        // A short list is shown whole.
        XCTAssertEqual(presetNameSample(["A", "B"]), "A, B")
    }

    // MARK: - Which action a call means (backward compatibility)

    func testEveryPreV2ArgumentSetStillMeansStep() {
        // The v1 tool took track_name + plugin_name (+ direction/steps). None
        // of those callers may change behaviour.
        XCTAssertEqual(try? MCPServer.presetAction(["track_name": "Bas", "plugin_name": "Compressor"]), "step")
        XCTAssertEqual(try? MCPServer.presetAction(["direction": "previous"]), "step")
        XCTAssertEqual(try? MCPServer.presetAction(["direction": "next", "steps": 3]), "step")
    }

    func testANameWithNoActionMeansSelect() {
        XCTAssertEqual(try? MCPServer.presetAction(["name": "Warm Master"]), "select")
    }

    func testAnExplicitActionWins() {
        XCTAssertEqual(try? MCPServer.presetAction(["action": "list"]), "list")
        // Explicit 'step' beside a name is a caller asking to step, and it is
        // honoured rather than silently upgraded to a jump.
        XCTAssertEqual(try? MCPServer.presetAction(["action": "step", "name": "Warm Master"]), "step")
        XCTAssertEqual(
            try? MCPServer.presetAction(["action": "select", "name": "Warm Master"]), "select"
        )
    }

    func testSelectWithoutANameIsRefusedBeforeAnythingOpens() {
        XCTAssertThrowsError(try MCPServer.presetAction(["action": "select"])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
    }

    func testUndoIsAnActionAndNeedsNoName() {
        // The way back from a select. It takes no name on purpose: it
        // restores the parameter STATE, and the state it returns to may well
        // have no name at all (`Default Preset`).
        XCTAssertEqual(try? MCPServer.presetAction(["action": "undo"]), "undo")
    }

    func testUndoIsNeverInferredFromArgumentsAlone() {
        // Every pre-'undo' argument set keeps its old meaning; an undo has to
        // be asked for, because it changes the plugin.
        XCTAssertEqual(try? MCPServer.presetAction([:]), "step")
        XCTAssertEqual(try? MCPServer.presetAction(["name": "Warm Master"]), "select")
    }

    func testAnUnknownActionIsRefused() {
        XCTAssertThrowsError(try MCPServer.presetAction(["action": "delete"])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
    }

    // MARK: - The honesty text

    func testEveryPresetChangeCarriesTheOverwriteWarning() {
        // The finding this warning exists for: stepping away from
        // "FET Electric Bass" and back restored the label and ten of eleven
        // parameters. A name is not a state.
        XCTAssertTrue(presetOverwriteWarning.contains("overwrites every parameter"))
        XCTAssertTrue(presetOverwriteWarning.contains("does NOT bring them back"))
    }

    // MARK: - A name match is not a state match

    func testTheLabelComparisonIsANameComparisonAndNothingElse() {
        let entry = PresetEntry(name: "Warm Master", category: nil, active: false)
        XCTAssertTrue(presetLabelNames("Warm Master", entry))
        XCTAssertTrue(presetLabelNames("wärm mäster", entry))
        XCTAssertFalse(presetLabelNames("Standard Master", entry))
        XCTAssertFalse(presetLabelNames(nil, entry))
    }

    func testTheFastPathSaysBY_NAMEInTheStateItself() {
        // The defect this exists for: the old token was `already_loaded`, a
        // name match presented as a state match. Measured 2026-09-02 on a
        // Channel EQ whose header named the setting AND carried Logic's own
        // tick, 3 of 26 parameters were away from the factory values — so a
        // caller who wanted those values got "verified, already loaded,
        // nothing was pressed" and kept the tweaks.
        let entry = PresetEntry(name: "Synth Sub Bass Enhancer", category: "02 Keyboards", active: true)
        let payload = presetNameMatchPayload(entry: entry, label: "Synth Sub Bass Enhancer")
        XCTAssertEqual(payload["state"] as? String, "already_loaded_by_name")
        XCTAssertTrue((payload["state"] as? String)?.hasPrefix("already_") == true,
                      "it is still a verified no-op, so it stays in the already_* family")
        XCTAssertEqual(payload["success"] as? Bool, true)
        XCTAssertEqual(payload["verified"] as? Bool, true)
        XCTAssertEqual(payload["pressed"] as? Bool, false)
        XCTAssertEqual(payload["preset"] as? String, "02 Keyboards/Synth Sub Bass Enhancer")
        // What `verified` covers is said out loud, next to the claim.
        XCTAssertTrue((payload["verified_by"] as? String)?.contains("not the parameters") == true)
    }

    func testTheFastPathCarriesTheNameMatchWarningAndNamesTheWayOut() {
        let entry = PresetEntry(name: "Punchy", category: nil, active: false)
        let warning = presetNameMatchPayload(entry: entry, label: "Punchy")["warning"] as? String
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("NAME match") == true)
        XCTAssertTrue(warning?.contains("3 of 26") == true)
        XCTAssertTrue(warning?.contains("reload: true") == true)
        XCTAssertTrue(warning?.contains("logic_list_plugin_parameters") == true)
        // The note offers the alternative rather than only refusing to press.
        let note = presetNameMatchPayload(entry: entry, label: "Punchy")["note"] as? String
        XCTAssertTrue(note?.contains("reload: true") == true)
    }

    func testReloadIsInTheSchemaAndSaysWhatItCosts() {
        guard let tool = MCPServer().toolRegistry()
            .first(where: { $0.name == "logic_plugin_preset" }),
            let properties = tool.inputSchema["properties"] as? [String: Any],
            let reload = properties["reload"] as? [String: Any] else {
            return XCTFail("reload is missing from logic_plugin_preset")
        }
        XCTAssertEqual(reload["type"] as? String, "boolean")
        XCTAssertTrue((reload["description"] as? String)?.contains("OVERWRITES") == true)
        // The description tells an agent which token the no-op answers with.
        XCTAssertTrue(tool.description.contains("already_loaded_by_name"))
    }

    // MARK: - The way back

    func testTheUndoNoteCarriesTheMeasuredOneUndoPerWriteRule() {
        // Measured 2026-09-02: four writes needed exactly four undos, and the
        // state after undo #3 equalled the state after #1 — so an agent
        // cannot feel its way back, and the note has to say so.
        XCTAssertTrue(presetUndoNote.contains("ONE undo per write"))
        XCTAssertTrue(presetUndoNote.contains("not monotonic"))
        XCTAssertTrue(presetUndoNote.contains("logic_list_plugin_parameters"))
        XCTAssertTrue(presetUndoNote.contains("BEFORE the first write"))
    }

    func testTheTwoUnreadableMenuReasonsAreDifferentSentences() {
        // "no factory settings" and "cannot be read" must never collapse into
        // one message; an agent branches on the difference.
        XCTAssertNotEqual(PresetMenuFailure.noPresetPopUp.reason, PresetMenuFailure.menuDidNotOpen.reason)
        XCTAssertTrue(PresetMenuFailure.noPresetPopUp.reason.contains("action 'step'"))
        XCTAssertTrue(PresetMenuFailure.menuDidNotOpen.reason.contains("nothing was changed"))
    }

    func testTheToolSchemaOffersEveryActionAndKeepsTheOldArguments() {
        guard let tool = MCPServer().toolRegistry()
            .first(where: { $0.name == "logic_plugin_preset" }),
            let properties = tool.inputSchema["properties"] as? [String: Any] else {
            return XCTFail("logic_plugin_preset is missing from the registry")
        }
        let actions = (properties["action"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(actions, ["list", "select", "step", "undo"])
        for old in ["track_name", "plugin_name", "insert_index", "track_number", "direction", "steps"] {
            XCTAssertNotNil(properties[old], "\(old) must keep working")
        }
        XCTAssertNotNil(properties["name"])
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["track_name", "plugin_name"])
    }
}
