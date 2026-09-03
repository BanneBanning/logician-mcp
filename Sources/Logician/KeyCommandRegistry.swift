import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// Key commands learned onto the dedicated "Logic MCP Commands" MIDI port
/// (Key Commands window > Learn New Assignment). The registry file is the
/// consent record: only notes listed there may be triggered, because an
/// unlisted note could be bound to anything in the user's key command set.
enum KeyCommandRegistry {
    static var url: URL {
        MCUBridge.directory.appendingPathComponent("keycmd-registry.json")
    }

    static func commands() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]] else { return [] }
        return commands
    }

    static func entry(note: Int, channel: Int) -> [String: Any]? {
        commands().first {
            ($0["note"] as? Int) == note && (($0["channel"] as? Int) ?? 16) == channel
        }
    }

    static func note(named name: String) -> (note: Int, channel: Int)? {
        guard let hit = commands().first(where: {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }), let note = hit["note"] as? Int else { return nil }
        return (note, (hit["channel"] as? Int) ?? 16)
    }

    /// What a `register` call did. A refusal is not a failure of the LEARN —
    /// the assignment may well exist in Logic — it says the consent record was
    /// left alone because writing would have made it lie, and the text names
    /// what to do instead.
    enum Registration: Equatable {
        case registered
        case refused(String)

        var refusal: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// The name of a DIFFERENT command that already answers to this note.
    ///
    /// Pure over the rows so every guard built on it can be tested without a
    /// registry file. Case-insensitive on the name, because the registry holds
    /// Logic's own spelling and callers type their own.
    static func noteHolder(
        note: Int, channel: Int = 16, otherThan name: String, in commands: [[String: Any]]
    ) -> String? {
        for entry in commands {
            guard (entry["note"] as? Int) == note,
                  ((entry["channel"] as? Int) ?? 16) == channel else { continue }
            let holder = (entry["name"] as? String) ?? "?"
            if holder.caseInsensitiveCompare(name) != .orderedSame { return holder }
        }
        return nil
    }

    /// Why this note may not be written into the registry under this name, or
    /// nil when it may.
    ///
    /// `register` de-dupes by NAME only, so before this guard two rows could
    /// hold the same note and nothing anywhere noticed: `takenNotes()`
    /// collapsed them into a `Set`, `entry(note:channel:)` returned whichever
    /// sorted first, and `logic_trigger_key_command` therefore reported the
    /// WRONG command name while firing whatever Logic had actually bound.
    static func registrationRefusal(
        note: Int, channel: Int, name: String, in commands: [[String: Any]]
    ) -> String? {
        guard let holder = noteHolder(note: note, channel: channel, otherThan: name, in: commands)
        else { return nil }
        return "note \(note) (channel \(channel)) is already registered to '\(holder)'. "
            + "The registry is the consent record and one note can only mean one command, so "
            + "'\(name)' was NOT recorded. Remove '\(holder)' in Logic's Key Commands window "
            + "(select it, Delete Assignment) and delete its entry from \(url.path), or learn "
            + "'\(name)' again without forcing a note."
    }

    /// Why an explicit `note:` argument may not be used for this command.
    /// Same rule as `registrationRefusal`, phrased for the caller who is about
    /// to bind rather than for the record that is about to be written — and
    /// applied whether or not `relearn` was passed: re-binding a command to
    /// ANOTHER command's note is exactly as much of a lie the second time.
    static func explicitNoteRefusal(
        note: Int, channel: Int = 16, name: String, in commands: [[String: Any]]
    ) -> String? {
        guard let holder = noteHolder(note: note, channel: channel, otherThan: name, in: commands)
        else { return nil }
        return "note \(note) is already registered to '\(holder)'. Nothing was bound. "
            + "Omit 'note' to let the free range pick one."
    }

    @discardableResult
    static func register(
        note: Int, channel: Int, name: String, notes: String,
        source: String = "logic_setup_key_commands", search: String? = nil,
        portUniqueID: Int? = nil
    ) -> Registration {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["port": "Logic MCP Commands"]
        var commands = root["commands"] as? [[String: Any]] ?? []
        if let refusal = registrationRefusal(
            note: note, channel: channel, name: name, in: commands
        ) { return .refused(refusal) }
        commands.removeAll {
            (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date())
        // `learned` (the date) is kept exactly as it was so an existing
        // registry file keeps reading the same; `learned_at` and `source`
        // are the consent record G00 needs — WHO bound this and WHEN, to the
        // second, because an arbitrary command learned by an agent has to be
        // tellable apart from the product's own onboarding set.
        var entry: [String: Any] = [
            "note": note, "channel": channel, "name": name,
            "learned": String(stamp.prefix(10)),
            "learned_at": stamp,
            "source": source,
            "notes": notes
        ]
        if let search { entry["search"] = search }
        // Logic scopes an assignment to the ENDPOINT's unique ID, and the Key
        // Commands row text carries no port identity at all — which is why an
        // orphaned twin port is invisible to this flow's own readback. Writing
        // the identity that was live at learn time is what lets
        // `logic_list_key_commands` say later that these bindings were made
        // against a port Logic no longer sees.
        if let portUniqueID { entry["port_unique_id"] = portUniqueID }
        commands.append(entry)
        root["commands"] = commands
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
        return .registered
    }

    /// The commands whose recorded port identity is NOT the one live now —
    /// bindings Logic scoped to an endpoint that no longer exists under that
    /// unique ID, i.e. rows that read as healthy and can never fire.
    ///
    /// Entries with no recorded identity (everything bound before this was
    /// written) are NOT reported: absence of a witness is not evidence.
    /// `currentPortUniqueID` nil means the port could not be read at all, and
    /// then nothing is claimed either.
    static func staleIdentityNames(
        in commands: [[String: Any]], currentPortUniqueID: Int?
    ) -> [String] {
        guard let current = currentPortUniqueID else { return [] }
        return commands.compactMap { entry in
            guard let recorded = entry["port_unique_id"] as? Int, recorded != current
            else { return nil }
            return (entry["name"] as? String) ?? "?"
        }
    }

    // MARK: - Notes for arbitrary (non-standard) commands

    /// Where `logic_learn_key_command` puts a command it was asked to learn.
    /// Deliberately BELOW the 100-121 block `standardCommands` prefers: an
    /// arbitrary command must never take a note one of the product's own
    /// tools is about to want, because the standard learn would then land on
    /// an alternate note and the two would be harder to tell apart in the
    /// user's own Key Commands window.
    static let learnableNoteRange = 60...99

    /// Every note this machine has already spoken for: what the registry
    /// holds, plus every note the named set PREFERS (whether or not it has
    /// been learned yet — reserving them is the whole point). `onDemand`
    /// commands are reserved here too: they are not installed, but a note
    /// handed to an arbitrary command today would collide with them the day
    /// something asks for one.
    static func takenNotes() -> Set<Int> {
        var taken = Set(allNamedCommands.map(\.preferredNote))
        for entry in commands() {
            if let note = entry["note"] as? Int { taken.insert(note) }
        }
        return taken
    }

    /// The lowest free note for an arbitrary command: the 60-99 range first,
    /// then 122-127, then 21-59. Pure so the choice can be tested without a
    /// registry file. nil when all three ranges are full — 112 commands is far
    /// past anything real, and a wrong answer there would silently rebind
    /// something, so it refuses instead of wrapping.
    static func freeNote(taken: Set<Int>) -> Int? {
        let order = Array(learnableNoteRange) + Array(122...127) + Array(21...59)
        return order.first { !taken.contains($0) }
    }

    /// The notes one learn may try, in order: the chosen note first, then
    /// FREE notes from the same allocator that chose it, each one added to
    /// `taken` before the next is picked.
    ///
    /// What this replaced was a bare arithmetic ladder —
    /// `[n, (n + 20) % 128, (n + 40) % 128]` — which consulted neither
    /// `takenNotes()`, nor either note range, nor the registry. Because
    /// `learnableNoteRange` is exactly 40 notes wide starting at 60, that
    /// aimed straight into the block this scheme reserves: `n ∈ 60…79` put
    /// `n + 40` in 100-119 and `n ∈ 80…99` put `n + 20` there, so EVERY
    /// first choice the picker can make had a fallback sitting on a note one
    /// of the product's own standard commands is about to want. Logic raises
    /// its conflict alert only for a note it has ALREADY bound, so a note
    /// merely reserved here — the ordinary state before onboarding runs —
    /// was taken silently and the standard command displaced later.
    static func candidateNotes(preferred: Int, taken: Set<Int>, limit: Int = 3) -> [Int] {
        var chosen = [preferred]
        var blocked = taken
        blocked.insert(preferred)
        while chosen.count < limit, let next = freeNote(taken: blocked) {
            chosen.append(next)
            blocked.insert(next)
        }
        return chosen
    }

    // MARK: - Reading an assignment out of a Key Commands row

    /// Every MIDI note the row's ASSIGNMENT columns name (the command's own
    /// name is not passed in — Logic has commands with "Note" in their titles).
    /// Only the literal `Note N` spelling is recognised: Logic paints some
    /// notes symbolically ("F2 (Modifiers …)" for note 109 on an MCU device),
    /// and there is no way to tell such a label from a keyboard F-key, so
    /// those are deliberately NOT claimed.
    static func assignedNotes(in assignmentText: String) -> [Int] {
        let prefix = LogicUIStrings.Format.keyCommandNotePrefix
        var notes: [Int] = []
        var rest = Substring(assignmentText)
        while let range = rest.range(of: prefix) {
            var digits = ""
            var index = range.upperBound
            while index < rest.endIndex, rest[index].isNumber {
                digits.append(rest[index])
                index = rest.index(after: index)
            }
            if let value = Int(digits) { notes.append(value) }
            rest = rest[range.upperBound...]
        }
        return notes
    }

    /// What a command row already carries, relative to the note about to be
    /// learned onto it.
    enum RowAssignment: Equatable {
        /// No MIDI-note assignment the row text can prove.
        case none
        /// The row already answers to exactly this note — a verified no-op.
        case preferred(Int)
        /// The row answers to OTHER notes. Learning again would STACK a
        /// second controller assignment rather than replace the first.
        case other([Int])
    }

    static func rowAssignment(_ assignmentText: String, preferredNote: Int) -> RowAssignment {
        let notes = assignedNotes(in: assignmentText)
        if notes.contains(preferredNote) { return .preferred(preferredNote) }
        return notes.isEmpty ? .none : .other(notes)
    }

    /// The refusal for a learn attempted while the port list carries orphaned
    /// twins, or nil when it is clean.
    ///
    /// A virtual endpoint that outlived a dead daemon keeps the name and takes
    /// a random unique ID, and Logic scopes key-command assignments to the
    /// unique ID — so with two `Logic MCP Commands` in the list, learning binds
    /// to whichever one Logic is pointed at, which may not be the one this
    /// server sends on. Nothing in this flow's readback can see that: the row
    /// text says "Note 74" either way. Refusing costs one 0.8 ms audit
    /// (16.6 ms cold, measured in the logic_health profile) and saves a
    /// registry entry that lies.
    static func orphanRefusal(orphans: [String], action: String) -> String? {
        guard !orphans.isEmpty else { return nil }
        return "Logic's MIDI port list shows orphaned twin ports (\(orphans.joined(separator: ", "))"
            + "), left by a bridge daemon that died without cleaning up. Logic binds key commands "
            + "to a port's unique ID, so \(action) now would record an assignment that may never "
            + "fire — and nothing in the Key Commands window can tell the two twins apart. "
            + "NOTHING WAS BOUND. Fix first: quit this MCP client, run 'killall MIDIServer' in a "
            + "terminal, start the client again, re-pick 'Logic MCP MCU' in Logic > Control "
            + "Surfaces > Setup, then call again. logic_health reports the same audit."
    }

    /// The Key Commands window's search field takes a substring of the row's
    /// name, so the first words of the name the caller gave are a search term
    /// that is correct BY CONSTRUCTION whenever the name is. Two words (three
    /// when the first two are very short) — broad enough that a near-miss name
    /// still puts its neighbours on screen, which is what the not_found answer
    /// reports back.
    static func defaultSearchTerm(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return name.lowercased() }
        var taken = Array(words.prefix(2))
        if taken.joined().count < 6, words.count >= 3 { taken = Array(words.prefix(3)) }
        return taken.joined(separator: " ").lowercased()
    }

    // MARK: - Names

    /// Every Logic key-command name this product spells, as a constant.
    ///
    /// These are rows in the user's Key Commands window, and Logic translates
    /// that window — so each one is a localization surface, and a caller that
    /// re-spelled a name inline was a leak that a Swedish pass would have had
    /// to find by grep. `resolveKeyCommand(named:)` matches the registry
    /// case-insensitively on exactly this string; `standardCommands` carries
    /// the matching search term, which the suite proves is a substring of the
    /// name, so a translated name and a stale search term cannot ship
    /// together silently.
    ///
    /// Per locale, re-measure: open Logic's Key Commands window and read the
    /// row. The English name is not always the menu item's text (`New Track
    /// with Duplicate Settings and Content` has no menu twin), so each one has
    /// to be read out of that window, not translated from the menu bar.
    ///
    /// # FRENCH (R4, 2026-08-30) — what was and was not established
    ///
    /// **Triggering an already-learned command still works, and this was
    /// PROVEN rather than argued.** With Logic's UI in French,
    /// `logic_trigger_key_command {name: "Rename Track"}` sent note 119 on
    /// channel 16 and Logic's `AXFocusedUIElement` changed from a control-bar
    /// button to an `AXTextField` holding the selected track's name — the
    /// inline rename editor, open and focused. The binding is a note, the
    /// registry holds the note, and Logic's MIDI-learn assignment does not
    /// care what language the window that made it was drawn in. All 22
    /// `standardCommands` still report `registered: true`.
    ///
    /// **Learning a NEW one by name is dead, and fails loudly:**
    /// `logic_learn_key_command` reports
    /// `menu item 'Edit Assignments' under 'Key Commands'` not found, because
    /// French spells those `Modifier les assignations…` under
    /// `Raccourcis clavier` (both captured — see `LogicUIStrings.Menu`).
    ///
    /// **The 28 French row names below are NOT captured.** Activating
    /// `Modifier les assignations…` by `AXPress` did not open the window in
    /// two attempts, so the rows could not be read. Note when someone does
    /// capture them: `standardCommands`' search TERMS are English substrings
    /// of these English names, so the two columns must be re-measured
    /// together — which the suite's substring check already enforces.
    enum Name {
        static let save = "Save"
        static let newSoftwareInstrumentTrack = "New Software Instrument Track"
        static let newAudioTrack = "New Audio Track"
        static let toggleTrackFreeze = "Toggle Track Freeze"
        static let undo = "Undo"
        static let redo = "Redo"
        static let flashbackCaptureAsRecording = "Flashback Capture as Recording"
        static let splitRegionsAtPlayhead = "Split Regions/Events at Playhead Position"
        static let cut = "Cut"
        static let copy = "Copy"
        static let paste = "Paste"
        static let delete = "Delete"
        static let nudgeRightByBar = "Nudge Region/Event Position Right by Bar"
        static let nudgeLeftByBar = "Nudge Region/Event Position Left by Bar"
        static let nudgeRightByBeat = "Nudge Region/Event Position Right by Beat"
        static let nudgeLeftByBeat = "Nudge Region/Event Position Left by Beat"
        static let duplicateTrack = "New Track with Duplicate Settings and Content"
        static let deleteTrack = "Delete Track"
        static let renameTrack = "Rename Track"
        static let nextPluginSetting = "Next Plug-in Setting for topmost Plug-in Window"
        static let previousPluginSetting = "Previous Plug-in Setting for topmost Plug-in Window"
        static let createMarker = "Create Marker"

        // MARK: Learned on demand (not in `standardCommands`)
        //
        // G00's opt-in path learns these on the spot rather than claiming a
        // reserved note for a command most sessions never fire. They are Key
        // Commands rows all the same, so they belong on the same translation
        // list.

        /// Note the trailing ellipsis — Logic's own character, not three dots.
        static let removeSilenceFromAudioRegion = "Remove Silence from Audio Region…"

        /// The five region-selection commands, spelled as Logic 12.3.1's Key
        /// Commands window shows them (read 2026-08-28). Two of them are not
        /// what anyone would guess from the menus, which is the whole reason
        /// they are written down rather than derived.
        static let selectAllRegionsOfSameTrack = "Select All Regions/Cells of Same Track"
        static let selectAllFollowing = "Select All Following"
        static let selectAllFollowingOfSameTrack = "Select All Following of Same Track/Pitch"
        static let selectAll = "Select All"
        static let deselectAll = "Deselect All"

        /// The translation list: every name above, in one array, so a
        /// localization pass has something to enumerate and the suite has
        /// something to check call sites against. Kept in the same order as
        /// the constants.
        static let all: [String] = [
            save, newSoftwareInstrumentTrack, newAudioTrack, toggleTrackFreeze,
            undo, redo, flashbackCaptureAsRecording, splitRegionsAtPlayhead,
            cut, copy, paste, delete,
            nudgeRightByBar, nudgeLeftByBar, nudgeRightByBeat, nudgeLeftByBeat,
            duplicateTrack, deleteTrack, renameTrack,
            nextPluginSetting, previousPluginSetting, createMarker,
            removeSilenceFromAudioRegion,
            selectAllRegionsOfSameTrack, selectAllFollowing,
            selectAllFollowingOfSameTrack, selectAll, deselectAll
        ]
    }

    /// The commands the product's tools rely on, with search terms for the
    /// Key Commands window and preferred (not guaranteed) note numbers —
    /// collisions on a user's machine get an alternate note automatically.
    ///
    /// **This is the INSTALL SET**, and every row in it is a row written into
    /// the user's own persisted Logic key command set — state outside the
    /// project file, outside Undo and outside the sandbox protocol. So the
    /// bar for membership is "a tool handler fires it", not "an agent might
    /// want it": at the measured 10.1 s per command of the 2026-09-02 live
    /// round (223 s for 22), three commands nothing fires were 30 s of a
    /// one-time, irreversible write. Those three moved to `onDemandCommands`
    /// below.
    ///
    /// `Create Marker` (104) is the one member here whose *tool* route is not
    /// the key command — `logic_markers {action:"create"}` presses the Marker
    /// tab's own `Create new Marker` button, measured 3/3, and only falls
    /// back to this command when that button is absent. It stays in the
    /// install set anyway, for two reasons that are both about diagnosis: it
    /// is that fallback, and it is the server's only GLOBAL key command with
    /// a cheap count readback, which makes it the standing probe for "are key
    /// commands firing at all?" (`logic_trigger_key_command {name: "Create
    /// Marker"}` then `logic_markers list`, count +1 — `Deselect All` is not
    /// a valid probe, it is Tracks-area-scoped and reads `unchanged` when
    /// keyboard focus is elsewhere).
    static let standardCommands: [(search: String, name: String, preferredNote: Int)] = [
        ("save", Name.save, 105),
        ("new software instrument", Name.newSoftwareInstrumentTrack, 106),
        ("new audio track", Name.newAudioTrack, 107),
        ("toggle track freeze", Name.toggleTrackFreeze, 117),
        ("split regions/events", Name.splitRegionsAtPlayhead, 103),
        ("cut", Name.cut, 108),
        ("copy", Name.copy, 109),
        ("paste", Name.paste, 110),
        ("delete", Name.delete, 111),
        ("nudge region", Name.nudgeRightByBar, 112),
        ("nudge region", Name.nudgeLeftByBar, 113),
        ("nudge region", Name.nudgeRightByBeat, 114),
        ("nudge region", Name.nudgeLeftByBeat, 115),
        ("duplicate", Name.duplicateTrack, 116),
        ("delete track", Name.deleteTrack, 118),
        ("rename track", Name.renameTrack, 119),
        ("next plug-in", Name.nextPluginSetting, 120),
        ("previous plug-in", Name.previousPluginSetting, 121),
        ("create marker", Name.createMarker, 104)
    ]

    /// Registered, reserved, spelled — and NOT written into the user's Logic
    /// by the install round. Learned on the spot the first time something
    /// actually asks for one (`MCUController.resolveKeyCommand` reads this
    /// list as well as `standardCommands`), which costs that one call the
    /// Key Commands window and nothing to the 99 % of users who never fire it.
    ///
    /// Why each one is here rather than above (audited 2026-09-03 across
    /// every handler in `Sources/`):
    ///
    /// * **Undo (100) and Redo (101)** — **no tool fires either, deliberately.**
    ///   The house rule is that a tool restores by inverse operation with a
    ///   verified readback (`logic_remove_send`, `logic_delete_region`, …),
    ///   never by Undo: Logic's Undo menu shows no operation name, so a blind
    ///   Undo cannot be proven to have reverted the caller's edit rather than
    ///   somebody else's — in one live session an Undo fired after a tool had
    ///   *failed* removed an empty track another agent had just made. They
    ///   stay learnable because the AGENT-facing escape hatch
    ///   (`logic_trigger_key_command {name: "Undo"}`, right after a known
    ///   edit) is documented and worth keeping; the first such call pays a
    ///   one-time learn and says so in `first_run_learning`.
    /// * **Flashback Capture as Recording (102)** — no handler, no guide
    ///   passage, named only inside `logic_setup_key_commands`' own
    ///   description. It is the one command in this file with a genuine claim
    ///   on the MIDI plane (no menu path, no default shortcut, so nothing
    ///   else can reach it) and it is also the one nothing calls. When a
    ///   capture tool exists it moves back up.
    ///
    /// Their preferred notes stay reserved (`takenNotes` counts them), so an
    /// arbitrary `logic_learn_key_command` can never take 100-102 and make
    /// the two harder to tell apart in the user's own window later.
    static let onDemandCommands: [(search: String, name: String, preferredNote: Int)] = [
        ("undo", Name.undo, 100),
        ("redo", Name.redo, 101),
        ("flashback", Name.flashbackCaptureAsRecording, 102)
    ]

    /// Every command this product spells a search term and a reserved note
    /// for, installed or not. What `resolveKeyCommand` looks a name up in,
    /// and what `logic_setup_key_commands {commands: [...]}` accepts — asking
    /// for `Undo` by name is an explicit choice and is honoured; the install
    /// round's default just does not make it for you.
    static var allNamedCommands: [(search: String, name: String, preferredNote: Int)] {
        standardCommands + onDemandCommands
    }

    /// The channel every learn uses unless something forces another one. Named
    /// so the listing can leave it OUT of a row and say it once instead.
    static let defaultChannel = 16

    /// The standard commands the registry holds no entry for, in the order
    /// `standardCommands` declares them and spelled the way it spells them.
    /// `registryNames` is the LOWERCASED name of every entry in the file.
    ///
    /// The `Set` is a safety property, not an optimisation. Until 2026-09-02
    /// `handleListKeyCommands` keyed these names through
    /// `Dictionary(uniqueKeysWithValues:)`, which does not throw on a
    /// duplicate key — it TRAPS, killing the whole MCP server process, on a
    /// `.readOnly` call that touches nothing. `Name` is a localization
    /// surface (see its FRENCH notes above) and four of these entries are
    /// `Nudge Region/Event Position …` variants one word apart, so a
    /// translation pass is exactly the change that could collide two of them.
    /// The dictionary's values were never read; membership was the only
    /// question it was ever asked. A collision now costs the name being
    /// listed once instead of twice, and nothing else.
    static func standardNotLearned(
        in standard: [(search: String, name: String, preferredNote: Int)] = standardCommands,
        registryNames: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var missing: [String] = []
        for command in standard {
            let key = command.name.lowercased()
            guard !registryNames.contains(key), seen.insert(key).inserted else { continue }
            missing.append(command.name)
        }
        return missing
    }

    /// How many entries were bound before the registry recorded WHICH tool
    /// bound them. The listing says this once instead of apologising for it on
    /// every row.
    static func unrecordedSourceCount(in commands: [[String: Any]]) -> Int {
        commands.filter { (($0["source"] as? String) ?? "").isEmpty }.count
    }

    /// The rows `logic_list_key_commands` answers with — pure over the registry
    /// rows so the payload's SHAPE can be pinned by a test on a machine with no
    /// registry file.
    ///
    /// What is left OUT is the point. Measured 2026-09-02: the answer was
    /// 7 026 B and 55% of it was the same text 22–27 times over — a 55-char
    /// "unrecorded" sentence on 22 rows, a `notes` string restating `source`
    /// on 26, `channel: 16` on all 27. Every one of those facts is now said
    /// once, at the top level, or not at all:
    ///
    /// - `source` only when the entry records one; the answer says once how
    ///   many entries predate source tracking.
    /// - `channel` only when it is NOT the default 16 (`channel_default`).
    /// - `notes` never — it restated `source` in other words.
    /// - `learned`, `learned_at`, `search`, `standard` never: they are in the
    ///   file the answer names in `registry_path`, and nothing branches on them.
    /// - `port_unique_id` only when it is NOT the live identity (where it
    ///   agrees, the top-level `port_unique_id` already said it) or when there
    ///   is no live identity to compare it against.
    ///
    /// What survives is every fact a caller can act on: the name, the note
    /// that fires it, a non-default channel, a recorded source, and whether
    /// the port identity the binding was scoped to is still the live one.
    static func listingRows(
        from commands: [[String: Any]], currentPortUniqueID: Int?
    ) -> [[String: Any]] {
        commands.map { entry -> [String: Any] in
            var row: [String: Any] = [
                "name": (entry["name"] as? String) ?? "?",
                "note": entry["note"] ?? NSNull()
            ]
            // Anything that is not exactly the default survives, including a
            // value that is not an Int at all: a corrupt channel is a fact,
            // and dropping it would let the caller assume 16.
            if let channel = entry["channel"], (channel as? Int) != defaultChannel {
                row["channel"] = channel
            }
            if let source = entry["source"] as? String, !source.isEmpty {
                row["source"] = source
            }
            if let recorded = entry["port_unique_id"] as? Int {
                if let live = currentPortUniqueID {
                    row["port_identity"] = recorded == live ? "current" : "changed"
                    if recorded != live { row["port_unique_id"] = recorded }
                } else {
                    // No live identity to judge against, so the recorded one
                    // is the only witness left; keep it rather than claim.
                    row["port_unique_id"] = recorded
                }
            }
            return row
        }.sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }
    }
}

