import Foundation

/// The pure half of the shared project OPEN: which open document PROVES the
/// target is open, and when the poll may spend an AppleScript round trip to
/// ask. No Logic, no Accessibility, unit-tested — the shape `ProjectClose`
/// established for the close.
///
/// `openProject` is one function serving `logic_open_project`,
/// `logic_new_project`, `logic_duplicate_project` and `logic_reset_to`, so
/// these two decisions were four tools' decisions, made in two lines inside a
/// poll loop, and both were wrong (code triage 2026-09-01,
/// `Logician-archive/profiles/logic_duplicate_project.md` §5.1 and §5.2).
enum ProjectOpen {

    // MARK: - What proves the open

    /// The open document that IS the target, matched by PATH — or nil when the
    /// list does not hold it.
    ///
    /// The predicate used to be `docs.contains(where: { $0.name == expectedName })`
    /// over the destination's BASENAME, while the tuple it matches against
    /// carries a path and Logic's own document path is one Accessibility read
    /// away: the identifying field was available and the weaker one was used.
    /// A destination in a DIFFERENT DIRECTORY with the same basename —
    /// `logic_duplicate_project {destination_path: "~/Desktop/Sandbox/Song.logicx"}`,
    /// which is exactly what that parameter is for — matched the still-open
    /// ORIGINAL on the first poll tick, before Logic had switched anything,
    /// and the tool answered `verified: true` for a copy that was not open.
    /// The agent then made its destructive changes in the original, having
    /// been told it was in the sandbox: a check whose positive answer could
    /// not tell the thing it wanted from something else that fit.
    static func openedDocument(
        in documents: [(name: String, path: String?, modified: Bool)],
        targetPath: String,
        normalize: (String) -> String
    ) -> (name: String, path: String)? {
        let expected = normalize(targetPath)
        for document in documents {
            guard let path = document.path, normalize(path) == expected else { continue }
            return (document.name, path)
        }
        return nil
    }

    // MARK: - The decision that must be made before anything is written

    /// The refusal for a modified current project that the open would close
    /// without being told what to do with it — or nil when the open may go
    /// ahead. Nothing has been written when this returns a refusal.
    ///
    /// It is a function, and it runs where it does, because of what the order
    /// used to be. `logic_new_project` copies the bundled template to the
    /// caller's path and then opens it, and the copy ran BEFORE this decision:
    /// a bare `logic_new_project {path: X}` against a modified project created
    /// an empty project at X, refused with *"'Y' has unsaved changes; pass
    /// if_current_modified"*, and never mentioned the package it had just
    /// written. Measured live 2026-09-02: the retry carrying the very decision
    /// the refusal demanded was then refused again — *"'X' already exists; use
    /// logic_open_project"* — pointing the caller at a project it did not know
    /// it owned. `ProjectDuplicate.openDecisionRefusal` had already learned
    /// this on the copy; the template create is the same shape and was missed.
    ///
    /// Reopening the SAME path is never refused: there is no other project to
    /// decide about, which is exactly what an eval reset does.
    static func currentModifiedRefusal(
        current: [(name: String, path: String?, modified: Bool)],
        targetPath: String,
        targetName: String,
        ifCurrentModified: String,
        creating: Bool,
        normalize: (String) -> String
    ) -> LogicianError? {
        guard let open = current.first, open.modified else { return nil }
        guard normalize(open.path ?? "") != normalize(targetPath) else { return nil }
        guard ifCurrentModified != "save", ifCurrentModified != "dont_save" else { return nil }
        return LogicianError.trackNotExposed(
            requested: (creating ? "creating and opening '" : "opening '") + targetName + "'",
            exposed: "'\(open.name)' has unsaved changes; pass if_current_modified: 'save' or"
                + " 'dont_save' (explicit decision required), or call logic_save_project first."
                + (creating
                    ? " NOTHING was created — the template is copied only once this decision is made,"
                        + " so the path you asked for is still free."
                    : " NOTHING was closed.")
        )
    }

    /// Does the open have to READ Logic's document list before it may write
    /// anything? Only when the caller has made no explicit decision about the
    /// current project's unsaved changes.
    ///
    /// This mirrors `currentModifiedRefusal`'s third guard, and it exists
    /// because the read it skips is not cheap: **260–412 ms, one Apple Event,
    /// 13–16% of a warm 1.6–2.1 s call** (measured live 2026-09-02,
    /// `Logician-archive/profiles/logic_new_project.md` §2 phase 2). With
    /// `save` or `dont_save` the refusal returns nil no matter what the list
    /// says, and nothing else in `openProject` reads it — so the call was
    /// buying an answer it then discarded, on every
    /// `logic_open_project {if_current_modified: …}`, every `logic_reset_to`
    /// (which passes `dont_save`) and every
    /// `logic_duplicate_project {open_copy: true}`.
    ///
    /// The read is KEPT for `fail` — the default, and the one decision where
    /// the answer is load-bearing. It doubles there as an early diagnosis: a
    /// document list that will not answer refuses in 300 ms with the dialogs
    /// on screen named, instead of timing out 30 s later. That diagnosis is
    /// kept exactly where the read is the only thing providing it; on the
    /// explicit-decision path the poll's own read reaches the same verdict.
    static func needsCurrentDocumentList(ifCurrentModified: String) -> Bool {
        ifCurrentModified != "save" && ifCurrentModified != "dont_save"
    }

    // MARK: - The sheet an empty project raises

    /// How long the open waits for the "Create New Track" sheet after a
    /// TEMPLATE create, before concluding this Logic does not raise one.
    ///
    /// Spent only when the sheet has not appeared yet. Measured live
    /// 2026-09-02: on this Logic the sheet is already standing when the
    /// document-list read that proves the open returns (that read alone costs
    /// 264–400 ms after the load), so the first look finds it and the budget
    /// is never touched. It is small on purpose — a Logic version that stops
    /// prompting must cost the create a look, not a wait.
    static let createTrackSheetBudgetSeconds: TimeInterval = 1.5

    /// How long to keep looking for the sheet to GO AWAY after it is answered,
    /// before reporting it as still standing. A dismissal that has not happened
    /// in a second is a dismissal that did not happen.
    static let createTrackSheetDismissalSeconds: TimeInterval = 1.0

    /// What the caller is told about the project they now have. It differs by
    /// exactly one fact — whether Logic demanded a first track on the way in —
    /// and that fact must not be buried in the dialog log, because it is the
    /// difference between an empty project and a project with a track in it.
    static func openNote(created: Bool, answeredCreateTrackSheet: Bool) -> String {
        guard created else {
            return answeredCreateTrackSheet
                ? "Opened. It had no tracks, so Logic demanded one before it would show the"
                    + " project: its Create New Track sheet was answered with Create and this"
                    + " project now has ONE more track than the file on disk does"
                    + " (`dialogs_answered` says so; logic_list_tracks names it)."
                : "Opened."
        }
        return answeredCreateTrackSheet
            ? "Created from the bundled empty template and opened; already saved on disk."
                + " Logic will not show a project with no tracks, so its Create New Track sheet"
                + " was answered with Create: the project has ONE track, and `initial_track`"
                + " names it (kind, number and name — logic_list_tracks agrees, and"
                + " logic_delete_track removes it). Cancelling instead would have closed the"
                + " project Logic had just opened — measured, not guessed."
            : "Created from the bundled empty template and opened; already saved on disk."
                + " Logic raised no Create New Track sheet, so the project is EMPTY — add"
                + " tracks with logic_create_track."
    }

    // MARK: - WHICH track the sheet creates

    /// A track-type name reduced to what can be compared across two spellings
    /// of it: lowercased, `_` and `-` read as spaces, runs of whitespace
    /// collapsed, ends trimmed. `"software_instrument"` (how an agent types
    /// it, and how `logic_create_track` spells its own argument) and
    /// `"Software Instrument"` (how the sheet prints it) are one request.
    static func normalizedTrackTypeName(_ raw: String) -> String {
        let spaced = String(raw.lowercased().map { $0 == "_" || $0 == "-" ? " " : $0 })
        return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// One thing the sheet can make: a CATEGORY and one of its VARIANTS.
    ///
    /// The shape is the sheet's, read live 2026-09-03. The Create New Track
    /// sheet is not a flat list of track types — it is four category groups,
    /// each publishing an `AXDescription` of `"<category>, <variant>"` (plus
    /// `", selected"` on the one that is chosen) over a radio group of its
    /// own variants:
    ///
    /// | category | variants |
    /// |---|---|
    /// | MIDI | Software Instrument, External MIDI |
    /// | Pattern | Software Instrument, External MIDI |
    /// | Session Player | Drummer, Bass Player, Keyboard Player |
    /// | Audio | Mic or Line, Guitar or Bass |
    ///
    /// Two consequences a flat model got wrong on the first live run: every
    /// group has a variant reading `value = 1` whether or not its category is
    /// the selected one (so "the radio that is on" names four things, not the
    /// track that will be made), and `"Software Instrument"` names a variant
    /// of TWO categories.
    struct TrackTypeOffer: Equatable {
        let category: String
        let variant: String
        /// Is this the variant its own category currently has selected? Used
        /// to answer a bare category request with the sheet's own choice
        /// inside it rather than with the first one listed.
        let variantSelectedInCategory: Bool

        /// How the offer is spelled to the caller, and what may be passed back
        /// as `initial_track` to ask for exactly it.
        var label: String { "\(category)/\(variant)" }
    }

    /// The `AXDescription` Logic puts on one category group, read as data:
    /// `"MIDI, Software Instrument"` → (MIDI, Software Instrument, not
    /// selected); `"Audio, Mic or Line, selected"` → the same with the flag.
    /// Nil for any group that is not one of these — the sheet is full of
    /// unrelated groups, and guessing at one of them would put "Details" in
    /// the track-type vocabulary.
    ///
    /// The `, selected` suffix is the ONLY signal on the sheet that says which
    /// category will be created (every category's own radio group has a
    /// member reading 1), and it is an English word: on a Logic in another
    /// language the parse degrades to "no category is marked selected", which
    /// `initialTrackPayload` reports as an unreadable type rather than as a
    /// guess. See `LogicUIStrings.Element.axSelectedSuffix`.
    static func parseTrackTypeGroup(
        _ description: String
    ) -> (category: String, variant: String?, selected: Bool)? {
        var parts = description.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        var selected = false
        if let last = parts.last,
           last.caseInsensitiveCompare(LogicUIStrings.Element.axSelectedSuffix) == .orderedSame {
            selected = true
            parts.removeLast()
        }
        guard let category = parts.first, !category.isEmpty else { return nil }
        guard parts.count >= 2 else { return (category, nil, selected) }
        return (category, parts[1], selected)
    }

    /// The offer that answers `requested`, or nil when this sheet has nothing
    /// of the kind on it.
    ///
    /// Matched against the sheet's own words rather than a table of English
    /// track types this server would have to keep in step with Logic. The
    /// chooser's contents are a moving target twice over — they change with
    /// the Logic version and they are LOCALIZED — so the vocabulary is read
    /// off the sheet at the moment of the create and reported back in
    /// `initial_track.offered`. A caller who asks for something this Logic
    /// does not offer learns the real vocabulary from the result instead of
    /// from this server's guess about it.
    ///
    /// Four ways to name one thing, in this order:
    ///
    /// 1. `"audio/guitar or bass"` — category and variant, exactly what
    ///    `offered` prints, and the only spelling that can express "the
    ///    Pattern one" when two categories share a variant name.
    /// 2. `"audio"` — a category, answered with the variant that category
    ///    already has selected.
    /// 3. `"software_instrument"` — a variant. `logic_create_track` spells its
    ///    own argument that way, so it is the spelling an agent already knows.
    ///    When two categories offer it (MIDI and Pattern both do), the FIRST
    ///    the sheet lists wins and the result names the category it picked —
    ///    silence about which one would be the real defect.
    /// 4. A unique prefix of any of the above.
    static func matchedTrackTypeOffer(
        requested: String, offers: [TrackTypeOffer]
    ) -> TrackTypeOffer? {
        let want = normalizedTrackTypeName(requested)
        guard !want.isEmpty, !offers.isEmpty else { return nil }
        if let slash = want.firstIndex(of: "/") {
            let category = String(want[want.startIndex..<slash]).trimmingCharacters(in: .whitespaces)
            let variant = String(want[want.index(after: slash)...])
                .trimmingCharacters(in: .whitespaces)
            return offers.first {
                normalizedTrackTypeName($0.category) == category
                    && normalizedTrackTypeName($0.variant) == variant
            } ?? uniquePrefix(want, in: offers) { normalizedTrackTypeName($0.label) }
        }
        if offers.contains(where: { normalizedTrackTypeName($0.category) == want }) {
            return insideCategory(want, of: offers)
        }
        if let variant = offers.first(where: { normalizedTrackTypeName($0.variant) == want }) {
            return variant
        }
        if let byCategory = uniquePrefix(want, in: offers, field: {
            normalizedTrackTypeName($0.category)
        }) {
            return insideCategory(normalizedTrackTypeName(byCategory.category), of: offers)
        }
        return uniquePrefix(want, in: offers) { normalizedTrackTypeName($0.variant) }
    }

    /// A whole category was asked for, so the choice inside it is the sheet's:
    /// the variant that category already has selected, or its first.
    private static func insideCategory(
        _ category: String, of offers: [TrackTypeOffer]
    ) -> TrackTypeOffer? {
        let inside = offers.filter { normalizedTrackTypeName($0.category) == category }
        return inside.first(where: \.variantSelectedInCategory) ?? inside.first
    }

    /// The one offer whose `field` starts with `want`, or nil when none or
    /// several do. Several is not "close enough": with `Bass Player` and
    /// `Keyboard Player` both on the sheet, a caller who typed half a name is
    /// told what was offered instead of handed whichever came first.
    private static func uniquePrefix(
        _ want: String, in offers: [TrackTypeOffer], field: (TrackTypeOffer) -> String
    ) -> TrackTypeOffer? {
        let hits = offers.filter { field($0).hasPrefix(want) }
        guard let first = hits.first else { return nil }
        // Several offers that all name the same THING (the same category, or
        // the same category/variant pair) are one hit, not an ambiguity.
        return hits.allSatisfy({ field($0) == field(first) }) ? first : nil
    }

    /// Why `initial_track.type` cannot name a kind. Not `nil`, not an empty
    /// string: the sheet was answered and a track exists either way, so the
    /// field says which part of the answer is missing and why.
    static let trackTypeUnreadable = "unavailable: this Logic's Create New Track sheet does not"
        + " publish which of its track-type groups is selected (the marker is the English word"
        + " 'selected' in the group's Accessibility description), so the kind it created cannot"
        + " be named from here — logic_list_tracks names the track itself"

    /// The `initial_track` block: WHICH track the caller now owns because
    /// Logic would not open an empty project without one.
    ///
    /// It exists because the fact was previously only in prose, inside a
    /// dialog log entry: an agent that wanted to know what it had just been
    /// handed had to spend another round trip on `logic_list_tracks`, and the
    /// KIND was not in that answer at all. Every field degrades to a spoken
    /// reason rather than to absence.
    static func initialTrackPayload(
        requested: String?,
        selected: TrackTypeOffer?,
        offered: [TrackTypeOffer],
        track: (number: Int, name: String)?,
        trackUnavailable: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": selected?.label ?? trackTypeUnreadable,
            "offered": offered.map(\.label)
        ]
        if let selected {
            payload["category"] = selected.category
            payload["variant"] = selected.variant
        }
        if let requested {
            payload["requested"] = requested
            // Honoured means the sheet ended up on the very offer the request
            // resolved to — checked against what was READ BACK after the
            // press, never against the intention.
            payload["requested_honoured"] = selected.map {
                matchedTrackTypeOffer(requested: requested, offers: [$0]) == $0
            } ?? false
        }
        if let track {
            payload["track_number"] = track.number
            payload["track_name"] = track.name
            payload["verified_by"] = "logic_list_tracks"
        } else {
            payload["track_name"] = "unavailable: "
                + (trackUnavailable ?? "the track list did not answer after the sheet was answered")
        }
        return payload
    }

    /// The warning for an `initial_track` request this sheet could not honour.
    ///
    /// A REFUSAL is not available here and saying so is the point: the sheet is
    /// already up over a project Logic has already opened, Cancel abandons that
    /// project (measured 3/3, `ProjectReset.createNewTrack`), and a create that
    /// answered "you cannot have an audio track" by throwing the new project
    /// away would be worse than the one track it cannot name. So the sheet is
    /// answered with its own selection and the caller is told exactly what
    /// happened, what was on offer, and the two calls that fix it.
    static func trackTypeNotOfferedWarning(
        requested: String, offered: [TrackTypeOffer], created: String?
    ) -> String {
        let whatIsThere = offered.isEmpty
            ? "this Logic's sheet publishes no track-type radio buttons through Accessibility at all"
            : "the sheet offered: " + offered.map(\.label).joined(separator: ", ")
        return "initial_track: '\(requested)' was not created — \(whatIsThere)."
            + " The project was opened with the kind the sheet already had selected"
            + " (\(created ?? "not readable from here")), because Logic will not keep a project"
            + " with no tracks and cancelling that sheet closes the project (measured)."
            + " Add the track you wanted with logic_create_track and drop this one with"
            + " logic_delete_track, or repeat the create using one of the names above."
    }

    /// How long to keep asking for the track list after the sheet is answered,
    /// before `initial_track.track_name` says it could not be read. Logic
    /// builds the track as the sheet closes, so the first look can land in the
    /// gap; the loop looks BEFORE it waits and stops the moment a row appears.
    static let initialTrackNameBudgetSeconds: TimeInterval = 2.0

    // MARK: - When the expensive read may be spent

    /// Whether this poll tick may ask Logic's document list.
    ///
    /// The list is an `osascript` spawn (45–50 ms floor, measured) on the one
    /// plane that BLOCKS while Logic is modal — for AppleScript's ~120 s
    /// default timeout, far past any of these tools' deadlines — and this poll
    /// is the poll that is *expecting* the save-changes prompt: a loop stuck
    /// inside the read cannot answer the very dialog it is waiting for. So the
    /// read is gated behind two signals that cost 1–2 ms on the Accessibility
    /// plane, which keeps answering while Logic is modal. It is the same rule
    /// `closeOpenDocument` applies from the other side (ProjectReset.swift):
    /// ask the list only once the cheap signals agree.
    ///
    /// - An alert this server RECOGNISES is on screen: never ask. That is the
    ///   deadlock, and it is the state this loop is built to walk through.
    /// - A document window is up publishing a path that is NOT the target: the
    ///   switch is still in flight (that window is the outgoing project, the
    ///   one the prompt is about), so the answer would be "no" anyway.
    /// - The target's own path, or no document window at all: ask. The AX
    ///   document path SETTLES after the open rather than arriving with it
    ///   (measured live 2026-08-28, ProjectReset phase 5 — the document list
    ///   held the project while the window still published no AXDocument), so
    ///   treating "no AXDocument yet" as "do not ask" would trade this loop's
    ///   answer for a 30 s timeout.
    static func mayAskDocumentList(
        frontmostDocumentPath: String?,
        targetPath: String,
        recognisedAlertOnScreen: Bool,
        normalize: (String) -> String
    ) -> Bool {
        guard !recognisedAlertOnScreen else { return false }
        guard let frontmost = frontmostDocumentPath else { return true }
        return normalize(frontmost) == normalize(targetPath)
    }

    /// How often the open poll looks, in seconds. The close's measured pacing
    /// (`closeOpenDocument`, 200 ms on two cheap Accessibility signals),
    /// reused rather than re-guessed — and it replaces a `Thread.sleep(0.5)`
    /// that ran BEFORE the loop's first look, so a project Logic finished
    /// opening in 300 ms was reported at 500 ms.
    static let pollIntervalSeconds: TimeInterval = 0.2

    // MARK: - The plug-in window a fresh create can leave standing

    /// Whether the track a create just made is one MEASURED to make Logic
    /// open a plug-in window on its own — the gate `openProject` uses to
    /// decide whether `closeStrayPluginWindows` is worth a poll at all.
    ///
    /// Only a software-instrument variant is measured to do this (`MIDI` and
    /// `Pattern` both offer it under that name); an `audio` create opens
    /// none, 5/5, and Session Player/Drummer and the rest are untested — this
    /// says nothing about them, so they get the cheap `waitingUpTo: 0` path
    /// rather than a guessed-at wait.
    static func selectedTrackTypeExpectsStrayWindow(_ selected: TrackTypeOffer?) -> Bool {
        guard let selected else { return false }
        return normalizedTrackTypeName(selected.variant) == "software instrument"
    }

    /// How long `closeStrayPluginWindows` waits for the window it expects,
    /// once `selectedTrackTypeExpectsStrayWindow` says one is coming.
    ///
    /// MEASURED 2026-09-03, two independently timed live creates: Logic's
    /// `Inst 1` window appeared **1.13–1.60 s** and **1.25–1.83 s** after
    /// `openProject` would otherwise already have returned (0.1–0.15 s poll
    /// resolution — the true instant is inside each bracket, never before
    /// it: a look taken the moment the track's own row exists finds nothing,
    /// 5/5). This budget clears the slower run's edge with margin instead of
    /// re-guessing a number between two live measurements.
    static let strayPluginWindowBudgetSeconds: TimeInterval = 2.5

    /// One `dialogs_closed` line for a plug-in window `closeStrayPluginWindows()`
    /// found open right after a create — pure, so this SHAPE is unit-tested
    /// without Logic running. `closeStrayPluginWindows()` (AXPlugins.swift)
    /// supplies `closed` from `closePluginWindow(title:)`'s own result or from
    /// whether it threw at all, and this function does nothing but describe
    /// that outcome consistently.
    ///
    /// MEASURED 2026-09-03: a `logic_new_project` whose `initial_track` is a
    /// software instrument leaves Logic's own `Inst 1` plug-in window
    /// (`AXDialog`) open; an audio create opens none. Left standing, that
    /// window is what every region tool's `key_focus: unverified` /
    /// `blocked_by` names (the region-focus fix, 0bafa09) — a brand-new
    /// project starting life already degraded, silently, until this line
    /// existed to say so.
    static func strayPluginWindowClosedEntry(
        title: String, closed: Bool, detail: String? = nil
    ) -> [String: Any] {
        [
            "phase": "post_create",
            "dialog": "plugin_window",
            "window": title,
            "state": closed ? "closed" : "open",
            "effect": closed
                ? "closed Logic's own plug-in window, left open after the track was created, so"
                    + " region and focus tools do not start blocked"
                : "the window is still open"
                    + (detail.map { " (\($0))" } ?? "")
        ]
    }

    /// The `warning` naming the way out, or nil when every `dialogs_closed`
    /// entry says `state: "closed"` — including the empty list (nothing to
    /// close is not a warning).
    static func strayPluginWindowWarning(dialogsClosed: [[String: Any]]) -> String? {
        guard dialogsClosed.contains(where: { $0["state"] as? String != "closed" }) else { return nil }
        return "A plug-in window Logic opened on its own could not be closed automatically;"
            + " logic_close_plugin_window {window_title: \"<name>\"} is the way out."
    }
}
