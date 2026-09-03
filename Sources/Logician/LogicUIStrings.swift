import Foundation

// MARK: - Every English word the Accessibility plane matches Logic's UI on

/// The Accessibility plane reads Logic's own UI. Some of what it reads is
/// STRUCTURE — roles, subroles, identifiers, the default-button attribute —
/// and structure does not change when Logic's language does. The rest is
/// TEXT, and text does: a Swedish Logic publishes `Avbryt` where this server
/// looks for `Cancel`.
///
/// This file is the single place those English words live, so that
///
/// * the cost of a non-English Logic is COUNTABLE (one file, one list) rather
///   than a rumour about "roughly seventy literals somewhere in ten files";
/// * a locale session has one table to translate instead of a grep to run;
/// * every entry can say what READS it and what BREAKS if Logic renames it,
///   which is the thing a grep can never tell you.
///
/// **Order of preference at every call site**, and the reason:
///
/// 1. `Identifier` — an `AXIdentifier` is Logic's own internal name for a
///    control. It does not translate. Prefer it always.
/// 2. Structure — role, subrole, child count, `AXDefaultButton` /
///    `AXCancelButton`. See `AXDialogShape.swift`. Also does not translate.
/// 3. These strings — the last resort, and a real dependency on an English
///    Logic UI. Every one of them is a line item in
///    `Logician-archive/R4-LOCALE-SESSION-CHECKLIST.md`.
///
/// Nothing here is guessed. An entry exists because some call site was
/// already matching on that exact string; moving it here changed no
/// behaviour. Where a dialog's identifier or shape is simply UNKNOWN because
/// nobody has recorded it, the string match STAYS and the checklist names the
/// probe that would replace it — a guessed identifier that silently matches
/// nothing is worse than an honest English literal.
///
/// # Measured against a FRENCH Logic, 2026-08-30 (R4)
///
/// The full per-entry table is in
/// `Logician-archive/R4-LOCALE-SESSION-CHECKLIST.md`. The four results that
/// change how this file should be FIXED, rather than merely translated:
///
/// 1. **Descriptions and help text ARE localized.** The hoped-for cheap
///    outcome did not happen: `Control Bar` is `Barre des commandes`,
///    `Tracks header` is `En-tête Pistes`. A handful of words survive by
///    coincidence (`Tempo`, `Cycle`, `Solo`, `solo`, `pan`, `automation`,
///    `Note`), and no call site may rely on that.
/// 2. **Word order reverses.** `Tracks header` → `En-tête Pistes`,
///    `Output slot.` → `Slot de sortie .`, `MIDI File` → `Fichier MIDI…`,
///    and `Left inspector` stops being a PREFIX entirely (French appends
///    `gauche` to the end of the sentence). Those call sites need a different
///    matching STRATEGY, not a second string.
/// 3. **NO-BREAK SPACE, U+00A0, appears inside Logic's own French text**:
///    `Logic\u{00A0}Pro` in the menu bar, `« \u{00A0}…\u{00A0} »` around a
///    track name, `Région MIDI\u{00A0}.` in a region's help. A shared
///    whitespace-normalizing comparison is a precondition for French to work
///    and is behaviour-neutral for English.
/// 4. **The structural escape hatches held.** Logic's bounce dialog publishes
///    `AXDefaultButton` (`OK`) and `AXCancelButton` (`Annuler`) in French, and
///    every `AXIdentifier` read was unchanged — so `Identifier` and
///    `AXDialogShape` are the right preference order and it is now measured,
///    not assumed.
enum LogicUIStrings {

    // MARK: - Identifiers (locale-independent — the gold standard)

    /// `AXIdentifier` values. These are Logic's / AppKit's own internal
    /// names, they are not shown to the user and they are not localised
    /// (measured 2026-08-30, R2 import research §3.4–3.5). Anything reachable
    /// through one of these needs no English at all.
    enum Identifier {
        /// The `File > Import > MIDI File…` open panel's WINDOW. Hangs off
        /// Logic's own window list even though AppKit's XPC service draws its
        /// insides. Read by `importPanel()`; without it the import cannot find
        /// its own panel and every import fails at the first phase.
        static let openPanel = "open-panel"
        /// The open panel's Go-to-Folder sheet (⌘⇧G). Read by
        /// `goToFolderSheet(in:timeout:)`; without it the path cannot be typed
        /// and the import falls back to nothing.
        static let goToFolderSheet = "GoToWindow"
        /// The Go-to-Folder sheet's path field. Read by `setImportPanelPath`.
        static let pathTextField = "PathTextField"
        /// An AppKit panel's confirm button (`Import` in the open panel,
        /// `Bounce` in the bounce save panel). Read by `commitImportPanel` and,
        /// as the preferred address, by the bounce save panel.
        static let okButton = "OKButton"
        /// An AppKit panel's Cancel button. Read by `dismissImportPanel`.
        static let cancelButton = "CancelButton"
        /// The Go-to-Folder sheet's close button. Read by `dismissImportPanel`.
        static let closeButton = "CloseButton"

        /// Logic's alert buttons are numbered from the RIGHT-hand (default)
        /// end: `action-button-1` is the default answer, `-2` the second,
        /// `-3` the third. Measured on two different alerts (R2 §3.5, §8):
        ///
        /// * tempo prompt — 1 `No`, 2 `Import Tempo`, 3 `Cancel`
        /// * save-changes — 1 `Save`, 2 `Don't Save`, 3 `Cancel`
        ///
        /// The NUMBERING is stable; WHICH button carries which meaning is per
        /// alert and must be measured per alert. Read by `pressAlertButton`
        /// and `ImportMIDI.TempoPrompt`.
        static let actionButton1 = "action-button-1"
        static let actionButton2 = "action-button-2"
        static let actionButton3 = "action-button-3"
        /// The "Don't ask again" checkbox on a suppressible alert. Logic's own
        /// misspelling, not a typo here. NEVER pressed by anything in this
        /// server: ticking it writes a persistent preference into the user's
        /// Logic and destroys this server's ability to see the alert at all.
        /// Read only as a SHAPE signal (`AXDialogShape.hasSuppressionCheckbox`).
        static let suppressionCheckbox = "supression-checkbox"
    }

    // MARK: - Window titles and title fragments

    /// Window titles. Logic localises these. Where a window can be found any
    /// other way it is; these are the ones where it cannot.
    enum Window {
        /// The offline bounce dialog's title starts with this. Read by
        /// `bounceDialog()` and `cancelBounceDialog()`. If it drifts, a bounce
        /// reports "bounce dialog" not found and — worse on the cleanup path —
        /// `cancelBounceDialog` leaves a MODAL standing, which freezes every
        /// later tool. The cleanup path therefore also accepts any
        /// `AXDialog`-subrole window (structure), which is what actually saves
        /// it on a non-English Logic.
        ///
        /// FRENCH (R4, measured): the title is `Bounce « Testlåt Copy »`,
        /// so this prefix STILL MATCHES — Logic does not translate the word.
        /// The dialog also publishes `AXDefaultButton` = `OK` and
        /// `AXCancelButton` = `Annuler`, so answering it is already
        /// locale-independent and only the recognition above needed checking.
        static let bouncePrefix = "Bounce"
        /// The Remove Silence floating window. NO LONGER THE GATE, only the
        /// corroboration: `removeSilence(…)` snapshots the window list, fires
        /// the command and takes the window that APPEARED
        /// (`pollNewWindow(before:)`), so a translated title costs the result
        /// nothing but the word `identified_by: "title"`.
        ///
        /// It used to be the gate, and the comment here claimed the failure was
        /// safe. MEASURED 2026-09-02 (`logic_remove_silence` profile §4): the
        /// window is `AXModal = 1`, so a title miss left a MODAL standing that
        /// swallowed Logic's keyboard and every later tool call with it. That is
        /// the hole this string is no longer load-bearing for.
        static let removeSilence = "Remove Silence"
        /// The split-a-MIDI-region confirmation. Read by
        /// `notesCrossingSplitDialog()`. If it drifts, the modal is not found,
        /// is not answered, and EVERY later tool stalls behind it — the worst
        /// failure mode in this table.
        static let notesCrossingSplitPoint = "Notes Crossing Split Point"
        /// `File > Project Settings > …` opens `"<project> - Project
        /// Settings"`. Compared against the segment after the last
        /// `viewSeparator`. Read by `projectSettingsWindow()`.
        static let projectSettingsView = "Project Settings"
        /// Logic's Mixer window is `"<project> - Mixer: Tracks"`. The segment
        /// after the last `viewSeparator` starts with this. Read by
        /// `isMixerWindow(_:)`, which is what keeps `projectWindow()` from
        /// returning the Mixer and failing every Accessibility read.
        static let mixerViewPrefix = "Mixer"
        /// The Key Commands window's title CONTAINS this (the full title also
        /// carries the key-command set's name and an edited marker, e.g.
        /// `Key Command Assignments – Swedish – Edited` — where "Swedish" is
        /// the SET's name, not the UI language). Read by `keyCommandsWindow()`
        /// and `closeKeyCommandsWindow()`.
        static let keyCommandsFragment = "Key Command"

        /// Logic separates a project name from the view name with this.
        /// Not English, but locale-adjacent: it is the parsing rule behind
        /// `isMixerWindow` and `projectSettingsWindow`.
        static let viewSeparator = " - "
    }

    // MARK: - Element descriptions and help text

    /// `AXDescription` / `AXHelp` values Logic publishes on its controls.
    ///
    /// These are the plane's bread and butter and the biggest locale
    /// exposure: they are what turns "some group in the project window" into
    /// "the Control Bar". Logic ships them through the same localisation
    /// machinery as its visible strings, so a Swedish Logic is expected to
    /// publish Swedish descriptions — **VERIFIED 2026-08-30 against a French
    /// Logic: they are.** `Control Bar` is `Barre des commandes`,
    /// `Tracks header` is `En-tête Pistes`, `Playhead Position` is
    /// `Position de la tête de lecture`. This section is therefore the real
    /// cost of a non-English Logic, not the free win it might have been:
    /// `logic_get_transport`, `logic_list_tracks`, `logic_list_inserts` and
    /// `logic_track_info` all answer "not found" on a perfectly healthy
    /// French Logic.
    ///
    /// A few entries survive by coincidence and are marked below. Do not read
    /// a survivor as a pattern — `Tempo` survives, `Time Signature` does not.
    enum Element {
        // MARK: Tracks area

        /// The track header column's container. Read by `trackHeaderGroup()`,
        /// which is the root of every track-header read: track list, freeze,
        /// selection, solo census. If it drifts the whole Accessibility plane
        /// answers "Tracks header group" not found.
        static let tracksHeader = "Tracks header"
        /// A track header's Freeze checkbox. Read by `trackFreezeState`.
        static let freeze = "Freeze"
        /// A track header's focus indicator, pressed as one route to
        /// selecting a track. Read by `selectTrack`.
        static let hasFocus = "Has Focus"
        /// The ruler above the arrange area. Read by `rulerArea()`.
        static let tracksTimeRuler = "Tracks time ruler"
        /// The cycle range element inside the ruler. Read by cycle reads and
        /// `setCycle`.
        static let cycleRegion = "cycle region"
        /// The cycle range's two handles. Read by `setCycle`.
        static let startMarker = "Start Marker"
        static let endMarker = "End Marker"
        /// Ruler children whose description mentions a beat are EXCLUDED from
        /// the marker search (they are grid ticks, not the cycle handles).
        static let beat = "beat"

        // MARK: Control bar

        /// The transport strip. Read by `controlBarGroup()` and by the
        /// transport, tempo and playhead reads that hang off it.
        static let controlBar = "Control Bar"
        /// Some builds publish the same group with only an `AXHelp`, which
        /// starts with this (note the different capitalisation — Logic's, not
        /// a slip). Read by the control-bar fallback in `AXTransport`.
        static let controlBarHelpPrefix = "Control bar"
        /// The control bar's LCD fields.
        static let tempo = "Tempo"
        static let timeSignature = "Time Signature"
        static let keySignature = "Key Signature"
        static let playheadPosition = "Playhead Position"
        /// The control bar's Project Tempo pop-up, addressed by its `AXHelp`
        /// prefix. Publishes no value (probed 2026-08-27), which is why
        /// `projectTempoModeViaSettings` exists at all.
        static let projectTempoMenuHelpPrefix = "Project Tempo menu"

        /// The control bar's transport toggles, by description. Read by
        /// `logic_get_transport` (each one it cannot find is reported `null`
        /// rather than `false`) and pressed by the play/record/cycle tools.
        static let playButton = "Play"
        static let recordButton = "Record"
        static let cycleButton = "Cycle"
        static let metronomeButton = "Metronome Click"
        static let countInButton = "Count In"
        static let soloModeButton = "Solo"
        /// The ruler's playhead handle, dragged when the LCD route is not
        /// available.
        static let playheadThumb = "Playhead thumb"

        /// The LCD position display's per-digit sliders, by description. The
        /// playhead is READ and WRITTEN one digit at a time through these.
        /// Same words as `beat` above and deliberately separate entries: that
        /// one is a ruler-child EXCLUSION test, these are LCD addresses, and a
        /// locale session may find Logic translates one and not the other.
        static let playheadBarSlider = "bar"
        static let playheadBeatSlider = "beat"

        // MARK: Channel strips

        /// Every inspector channel strip's `AXHelp` contains this; the LEFT
        /// one's starts with `leftInspectorPrefix`. Read by `inspectorStrip`,
        /// `anyInspectorStrip`, `visibleInspectorStripNames`, and the Mixer
        /// census. The single most-read literal in the file.
        ///
        /// FRENCH (R4): `Tranche de console d’inspecteur`.
        static let inspectorChannelStrip = "inspector channel strip"
        /// FRENCH (R4): **this stops being a prefix.** English says
        /// `Left inspector channel strip.`; French says
        /// `Tranche de console d’inspecteur gauche .` — the qualifier moves to
        /// the END. A translated constant cannot fix this call site; it needs
        /// a suffix (or contains) test, which is why the checklist proposes
        /// carrying a match STRATEGY alongside each string.
        static let leftInspectorPrefix = "Left inspector"
        /// Strip controls, by description.
        static let mute = "mute"
        static let solo = "solo"
        static let pan = "pan"
        static let volumeFader = "volume fader"
        /// A strip's own name field — the Mixer census reads THIS rather than
        /// the strip's description, because headerless strips publish a
        /// numeric triple as their description.
        static let name = "name"
        /// The solo state a track header's Solo button publishes when lit
        /// (`AXValue` is the word, not `"1"`). Read by the solo census.
        static let soloDescription = "Solo"

        /// The last comma-separated word Logic appends to the `AXDescription`
        /// of the CHOSEN category group on the Create New Track sheet:
        /// `"Audio, Mic or Line, selected"` against `"MIDI, Software
        /// Instrument"` (measured live 2026-09-03).
        ///
        /// It is the only signal on that sheet that says which kind of track
        /// Create will make — every category's own radio group has a member
        /// reading `1`, so the radios cannot answer it — and it is an English
        /// word with no structural alternative. Recognising nothing is the
        /// safe failure here: `initial_track.type` then reports itself
        /// unreadable (`ProjectOpen.trackTypeUnreadable`) rather than naming a
        /// kind nobody read, and the create is unaffected either way.
        static let axSelectedSuffix = "selected"

        /// The track header's own checkboxes, by `AXDescription`, mapped to
        /// the keys `logic_track_info` reports them under. Read by
        /// `trackHeaderControls(_:)`; a description that drifts drops that
        /// control out of the report silently (the `default: continue` arm),
        /// which is the quiet failure mode worth knowing about.
        static let trackHeaderControls: [String: String] = [
            "Mute": "mute",
            "Solo": "solo",
            "Freeze": "freeze",
            recordEnable: "record_enable",
            "Input Monitoring": "input_monitoring"
        ]

        /// The track header's record button, by `AXDescription`. Read by
        /// `trackHeaderControls(_:)` and, on its own, by
        /// `MCURecordArm.axRecordEnabled` — the independent witness that names
        /// the TRACK when the control surface can only name a strip index.
        ///
        /// **It is also painted on the LCD.** Logic answers a rec/ready press
        /// on the Mackie Control by drawing this same phrase over the touched
        /// strip's name cell and its right-hand neighbour's, which is why the
        /// control-surface plane carries it too as
        /// `MCULCDStrings.recordArmBanner` (the two cannot be one constant:
        /// `MCULCDStrings` lives in the bridge target, which this file's
        /// module depends on and not the other way round). A locale pass has
        /// to translate BOTH — translate only this one and the arm write still
        /// verifies, but every arm-on → arm-off pair goes back to paying a
        /// full bank rescan; translate neither and the arm write loses its
        /// second witness and says so (`cross_check: "unavailable"`).
        static let recordEnable = "Record Enable"

        /// A channel strip slot names itself in its `AXHelp`, which STARTS
        /// with one of these. Paired with a `ChannelStrip.SlotKind` in
        /// `ChannelStrip.slotHelpPrefixes` — the pairing lives there because
        /// it needs the enum; the words live here.
        ///
        /// These drive strip READS (what kind of slot is this?) and strip
        /// WRITES (which slot do I open to change the output?), so a
        /// translation takes the whole Accessibility strip plane with it.
        ///
        /// FRENCH (R4, measured): **every entry reverses word order.** English
        /// is `<Thing> slot.`; French is `Slot de <thing> .` —
        /// `Output slot.` → `Slot de sortie .`, `Send slot.` →
        /// `Slot d’envoi .`, `Audio Effect slot.` → `Slot d’effet audio .`,
        /// `MIDI Effect slot.` → `Slot d’effet MIDI .`, `Group slot.` →
        /// `Slot de groupe .`, `Setting button.` → `Bouton Réglage .`,
        /// `Volume fader.` → `Curseur Volume .`, `Pan/Balance knob.` →
        /// `Potentiomètre Pan/Balance .`. So no `hasPrefix` match survives and
        /// the DISCRIMINATING word moves from first position to third.
        /// `input` and `inputGain` were not on the probed strips.
        enum StripSlotHelp {
            static let output = "Output slot."
            static let input = "Input slot."
            static let send = "Send slot."
            static let audioEffect = "Audio Effect slot."
            static let midiEffect = "MIDI Effect slot."
            static let inputGain = "Input Gain field and knob."
            static let group = "Group slot."
            static let setting = "Setting button."
            static let volume = "Volume fader."
            static let pan = "Pan/Balance knob."
        }

        // MARK: Inserts and plugins

        /// An insert slot's bypass checkbox and open button.
        static let bypass = "bypass"
        static let open = "open"
        /// A window's own close button, on windows that publish no
        /// `AXCloseButton` attribute (Drum Machine Designer does this).
        static let close = "close"
        /// The channel strip's insert area and one plugin slot inside it.
        static let insertBar = "insert bar"
        static let audioPlugIn = "audio plug-in"
        /// A plugin chooser menu's list container.
        static let list = "list"
        /// Parameter names come from a slider's `AXHelp`, which reads
        /// `"<name> knob and field. …"`. These suffixes are stripped to get
        /// the name. Read by `extractedParameterName(fromHelp:)`.
        static let parameterHelpSuffixes = [" knob and field", " knob"]

        // MARK: Inspector panels

        /// The Inspector container and the Region panel's heading (the panel's
        /// static text starts with it). Read by the Region inspector.
        static let inspector = "Inspector"
        static let regionPanelPrefix = "Region"
        /// A region element's `AXRoleDescription`. Read by `regionRows()`.
        static let regionRoleDescription = "Region"
        /// Automation lanes are told from regions by this appearing in the
        /// row's description.
        static let automation = "automation"

        // MARK: List Editors

        /// The four List Editors tabs, by the radio buttons' descriptions.
        /// Read by `tempoListTabs(in:)` and, as the `named:`/`tab:` argument,
        /// by every tool scoped through it — the event, marker, tempo and
        /// signature lists. They are also the tab names those tools print in
        /// their own failure payloads, which is why they come from here rather
        /// than being typed at each of the twenty call sites.
        ///
        /// `tempo` is spelled the same as `Element.tempo` (the control bar's
        /// LCD field) and is a separate entry on purpose: same word, two
        /// unrelated controls, and a translation may well differ.
        ///
        /// FRENCH (R4, measured with the pane open): `Event` → `Évènement`,
        /// `Marker` → `Marqueur`, `Tempo` → `Tempo` (survives),
        /// `Signature` → `Altération`. `tempoListTabs(in:)` requires **all
        /// four** to match before it returns a tab strip, so three misses
        /// make the one survivor worthless: the function returns `[]`, and
        /// every marker / event / tempo / signature read falls back or fails.
        /// A partial translation of this enum buys exactly nothing.
        enum ListEditorTab {
            static let event = "Event"
            static let marker = "Marker"
            static let tempo = "Tempo"
            static let signature = "Signature"
            static let all = [event, marker, tempo, signature]
        }

        static let listEditorTabs = ListEditorTab.all

        /// The Remove Silence window's four numeric field LABELS, as the
        /// fragment each one is recognised by (compared lowercased, so the
        /// trailing colon and the `-Time` suffix are not part of the gate).
        ///
        /// MEASURED 2026-09-02, identical on 5/5 openings, the window's direct
        /// children in tree order — value first, then the label that follows
        /// it:
        ///
        /// ```
        /// AXGroup "0,1000"  → AXStaticText "Minimum Time to accept as Silence:"
        /// AXGroup "0,0000"  → AXStaticText "Post Release-Time:"
        /// AXGroup "0,0060"  → AXStaticText "Pre Attack-Time:"
        /// AXGroup "-28"     → AXStaticText "Threshold:"
        /// ```
        ///
        /// These are the labels Logic PRINTS, so they translate — which is why
        /// `logic_remove_silence` reports every value with the label it was
        /// printed beside no matter what, and adds the stable keys
        /// (`threshold_db`, …) only for the labels it recognises. A label that
        /// matches nothing costs the caller a key, never a wrong number: the
        /// tool says `fields_identified_by: "label"` when the four resolved and
        /// `"unrecognised"` when they did not, and the value is always paired
        /// with its own label in `settings.fields`. Checklist item for a
        /// locale session.
        enum RemoveSilenceLabel {
            static let threshold = "threshold"
            static let minimumSilence = "silence"
            static let preAttack = "pre attack"
            static let postRelease = "post release"
        }
        /// The count text every List Editors tab publishes.
        static let numberOfItems = "Number of Items"
        /// The Event tab's "what am I showing?" field.
        static let regionPath = "Region Path"
        /// A column header containing this is the position column. Compared
        /// lowercased. Read by the marker and signature list readers.
        static let positionColumn = "position"
        /// The tabs' own create buttons, preferred over the equivalent key
        /// commands (a button cannot be orphaned by a MIDI port being
        /// recreated).
        static let createNewMarker = "Create new Marker"
        static let createNewEvent = "Create new Event"
        static let createNewTempoEvent = "Create new Tempo Event"
        /// A List Editors row publishes its delete as a NAMED AX action; any
        /// action whose descriptor contains this is accepted. Read by
        /// `performListEditorRowDelete`.
        static let deleteRowAction = "Delete"
        /// An Event List row's status column value contains this on a note
        /// row. Read by `EventListWrite`'s payload mapping.
        static let noteStatus = "note"

        // MARK: Project Settings

        /// The Smart Tempo pane's Project Tempo Mode pop-up, addressed by its
        /// `AXHelp` prefix rather than by position (its neighbours are pop-ups
        /// too). Read by `projectTempoModePopUp(in:)`.
        static let projectTempoModeHelpPrefix = "Project Tempo Mode pop-up menu"

        // MARK: Key Commands window

        /// The Key Commands filter field is recognised three ways; this is the
        /// English one (its `AXHelp` contains it, or a child is described with
        /// it). The other two — `AXTextField` with subrole `AXSearchField` —
        /// are STRUCTURE and are tried first, so this is already a fallback.
        static let search = "search"

        // MARK: Alerts

        /// Logic's alert windows publish this as their `AXDescription` and
        /// carry NO title. Read by `importAlert(timeout:)`.
        ///
        /// UNVERIFIED whether this is localised. It is an accessibility role
        /// hint rather than visible text, so it may well not be — the locale
        /// session's cheapest and highest-value single probe.
        static let alert = "alert"
    }

    // MARK: - Button, checkbox and radio titles

    /// `AXTitle` values on the controls this server presses.
    ///
    /// Where a dialog publishes `AXDefaultButton` / `AXCancelButton` the
    /// STRUCTURE is preferred and these are the fallback — see
    /// `AXDialogShape.swift`. Where it does not, these are the only address.
    enum Button {
        /// The confirm/abort pair, everywhere. `cancel` is the more important
        /// of the two: a Cancel that cannot be found leaves a MODAL standing.
        static let ok = "OK"
        static let cancel = "Cancel"

        /// The delete-track alert's two answers (`delete` is the default).
        static let delete = "Delete"
        /// The "Create New Track" prompt's confirm.
        static let create = "Create"
        /// The auto-save recovery prompt's "open the last saved version".
        static let saved = "Saved"
        /// The save-changes prompt. Logic spells the apostrophe U+2019; the
        /// straight-quote spelling is accepted too so an OS or font change
        /// cannot turn a known dialog into an unknown one.
        static let save = "Save"
        static let dontSave = "Don\u{2019}t Save"
        static let dontSaveStraightQuote = "Don't Save"
        /// Both spellings, in the order they should be tried.
        static let dontSaveSpellings = [dontSave, dontSaveStraightQuote]
        /// The "track is frozen, unfreeze it?" confirmation's answer.
        static let unfreeze = "Unfreeze"
        /// The save panel's "a file with that name exists" sheet.
        static let replace = "Replace"
        /// The bounce save panel's commit button (its `AXIdentifier`
        /// `OKButton` is tried first).
        static let bounce = "Bounce"
        /// The Project Settings toolbar's Smart Tempo pane button.
        static let smartTempo = "Smart Tempo"
        /// The Key Commands window's learn checkbox and delete button.
        static let learnNewAssignment = "Learn New Assignment"
        static let deleteAssignment = "Delete Assignment"
    }

    // MARK: - Alert static-text markers

    /// The words an alert is RECOGNISED by. Logic's alerts carry no
    /// `AXIdentifier` on the window and no title, so — except where a shape
    /// tells them apart (see `AXDialogShape`) — their own body text is the
    /// only identity they have.
    ///
    /// Recognition is the safety gate: this server presses a button only on an
    /// alert whose grammar was MEASURED, and reports anything else verbatim
    /// rather than clicking on a guess. On a non-English Logic these markers
    /// stop matching, which is the SAFE direction to fail — the alert is
    /// reported, not mis-answered — but it does mean the tool that raised it
    /// times out with a modal on screen.
    enum AlertMarker {
        /// "Do you want to save the changes made to the document …?"
        /// Read by `answerSaveChangesDialog` and `ProjectReset.knownDialogs`.
        static let saveChanges = "save the changes"
        /// The auto-save recovery prompt.
        static let autoSaved = "auto-saved"
        /// The "Create New Track" prompt raised by an empty project.
        static let createNewTrack = "Create New Track"
        /// "Track X is frozen. Do you want to unfreeze it?"
        static let frozen = "frozen"
        /// The Key Commands window's assignment-collision alert.
        static let alreadyAssigned = "already assigned"
        /// The delete-track confirmation's heading. Deleting the wrong track
        /// is unrecoverable in practice, so this gate is deliberately strict
        /// and the doubt goes to Cancel.
        static let deleteTrackAndRegions = "Delete Track and Regions?"
        /// The MIDI import's tempo prompt, matched as a lowercased PREFIX of
        /// the alert's first line ("Also import tempo information?"). This one
        /// has a structural alternative — see `AXDialogShape.isTempoPromptShape`
        /// — so a non-English Logic still recognises it.
        static let alsoImportTempo = "also import tempo"
        /// The bounce-in-place sheet has no title; a static text naming it is
        /// what tells the sheet apart from a save panel. Backed by a shape
        /// check, so this is a cross-check rather than the gate.
        static let bounceInPlaceSheet = "Bounce"
    }

    // MARK: - Menu paths

    /// `pressMenuItem(containing:underMenu:)` walks Logic's menu bar by
    /// TITLE — both the parent menu's and a fragment of the item's. Menu
    /// titles are the most visibly localised strings in any Mac app, so every
    /// one of these is a hard English dependency with no structural
    /// alternative: AppKit menu items publish no identifiers here.
    ///
    /// (There IS one locale-independent escape hatch already in use: when a
    /// press reports success and nothing happens, `pressMenuItem` falls back
    /// to the keystroke the item advertises through `AXMenuItemCmdChar`. That
    /// only helps once the item has been FOUND, which is the part that needs
    /// the title.)
    ///
    /// # FRENCH (R4, 2026-08-30) — read verbatim off Logic's own menu bar
    ///
    /// | entry | French |
    /// |---|---|
    /// | `bounce` | `Bounce` — **survives** |
    /// | `projectOrSection` | `Projet ou section…` |
    /// | `regionsInPlace` | `Régions en place…` |
    /// | `tracksInPlace` | `Pistes à leur place…` / `Piste à sa place…` |
    /// | `importMenu` | `Importer` |
    /// | `midiFile` | `Fichier MIDI…` (word order reversed) |
    /// | `view` | `Présentation` |
    /// | `listEditors` | `Éditeurs de listes` |
    /// | `projectSettings` | `Réglages du projet` |
    /// | `smartTempo` | `Smart Tempo…` — **survives** |
    /// | `keyCommands` | `Raccourcis clavier` |
    /// | `editAssignments` | `Modifier les assignations…` |
    /// | `window` | `Fenêtre` |
    /// | `openMixer` | `Ouvrir la table de mixage` |
    ///
    /// Two traps a plain translation would walk into:
    ///
    /// * **`tracksInPlace` changes with the selection** — Logic writes
    ///   `Pistes à leur place…` or `Piste à sa place…` depending on how many
    ///   tracks are selected, so a fragment match must not carry the plural.
    /// * **The application menu is `Logic\u{00A0}Pro`**, with a NO-BREAK
    ///   SPACE. `pressMenuItem` matches the parent by exact equality, so any
    ///   future entry naming that menu needs the U+00A0 — or, better, the
    ///   whitespace-normalizing comparison the checklist proposes.
    enum Menu {
        /// `File > Bounce > …`
        static let bounce = "Bounce"
        static let projectOrSection = "Project or Section"
        static let regionsInPlace = "Regions in Place"
        static let tracksInPlace = "Tracks in Place"
        /// `File > Import > MIDI File…`
        static let importMenu = "Import"
        static let midiFile = "MIDI File"
        /// `View > Show/Hide List Editors`
        static let view = "View"
        static let listEditors = "List Editors"
        /// `File > Project Settings > Smart Tempo…`
        static let projectSettings = "Project Settings"
        static let smartTempo = "Smart Tempo"
        /// `Logic Pro > Key Commands > Edit Assignments…`
        static let keyCommands = "Key Commands"
        static let editAssignments = "Edit Assignments"
        /// `Window > Open Mixer`
        static let window = "Window"
        static let openMixer = "Open Mixer"
    }

    // MARK: - Control values and option names

    /// Values Logic publishes IN a control, and option names the tools pass
    /// back INTO one. These leak into tool arguments and results, so a
    /// translation here is an API change as well as a UI one.
    ///
    /// # FRENCH (R4) — the bounce dialog, captured in full
    ///
    /// Labels: `Uncompressed` → `Sans compression`; `File Type` →
    /// `Type de fichier :`; `Bit Depth` → `Profondeur de bit :`;
    /// `Sample Rate` → `Fréquence d’échantillonnage :`; `Dithering` →
    /// `Dithering :`; `Normalize` → `Normaliser :`. (French adds a trailing
    /// colon to every one of them.) Checkboxes: `Include Audio Tail` →
    /// `Inclure les résonances`; `Include Tempo Information` →
    /// `Inclure des informations de tempo`; `Bounce 2nd Cycle Pass` →
    /// `Bounce du 2e cycle`. Buttons: `OK` → `OK`, `Cancel` → `Annuler`.
    ///
    /// **And the VALUES, which are also tool ARGUMENTS in
    /// `BounceOptions.swift`:** `AIFF` survives, `24-bit` → `24 bits`,
    /// `44.1 kHz` → **`44,1 kHz`**, dithering `None` → `Aucun`, normalize
    /// off → `Non`, `Interleaved` → `Entrelacé`.
    ///
    /// `44,1 kHz` settles the open question the checklist raised: a locale can
    /// put a DECIMAL COMMA inside a value the caller is expected to pass, so
    /// **keep the English argument vocabulary and MAP it to the localized menu
    /// item.** No API should make an agent guess the host's number format.
    enum Value {
        /// A track header toggle's lit state is the word, not `"1"`. The
        /// ruler's cycle region publishes the same pair as its
        /// `AXValueDescription`, which is the fallback cycle read for a window
        /// too narrow to show the Cycle button.
        static let on = "on"
        static let off = "off"
        /// The bounce dialog's destination row this server insists on.
        static let uncompressed = "Uncompressed"
        /// The bounce dialog's delivery pop-up labels, paired with their
        /// controls by GEOMETRY (label and pop-up are unconnected siblings on
        /// the same row).
        static let bounceFileType = "File Type"
        static let bounceBitDepth = "Bit Depth"
        static let bounceSampleRate = "Sample Rate"
        static let bounceDithering = "Dithering"
        static let bounceNormalize = "Normalize"
        /// The bounce dialog's checkboxes.
        static let includeAudioTail = "Include Audio Tail"
        static let includeTempoInformation = "Include Tempo Information"
        static let bounce2ndCyclePass = "Bounce 2nd Cycle Pass"
        /// The bounce-in-place sheet's two radio groups. They sit in ONE flat
        /// list with no group element between them, so membership of this
        /// array is what says which group a selected radio belongs to.
        static let bounceInPlaceSourceModes = ["Mute", "Leave", "Delete"]
        static let bounceInPlaceDestinations = [
            "selected_track": "Selected Track", "new_track": "New Track"
        ]
        static let bounceInPlaceSources = [
            "mute": "Mute", "leave": "Leave", "delete": "Delete"
        ]
        /// The one bounce-in-place checkbox whose state changes what the print
        /// SOUNDS like, warned about by name in the result.
        static let bypassEffectPlugIns = "Bypass Effect Plug-ins"
        /// The insert menu's format submenu and its "remove the plugin" item.
        static let audioUnits = "Audio Units"
        static let noPlugIn = "No Plug-in"
    }

    // MARK: - Locale-sensitive FORMATS

    /// Not words — SHAPES of text. Logic formats numbers and labels with the
    /// system's locale and with typographic punctuation, and several of these
    /// already bite on an English Mac with a Swedish number format.
    ///
    /// The parsers themselves are NOT here: each lives next to the thing it
    /// parses, and moving them would break the "one place per concept" the
    /// rest of the file has. What is here is the constants they share and a
    /// map of where they are, so a locale session has one page to read.
    ///
    /// | format | where it is parsed |
    /// |---|---|
    /// | `Track N “Name”` | `TrackRowAddressing.parseRowDescription` (one parse, both planes) |
    /// | `120,0000` (decimal comma) | `TempoMap.parseTempoListPosition`, `normalizedFormattedValue` |
    /// | `-6,0 dB` | `decibelValue(of:)`, `ChannelStrip.parseDb` |
    /// | `-oo dB` | `ChannelStrip.parseDb`, the send-level tools |
    /// | `9 Regions` | `RemoveSilence.previewCount` |
    /// | `1 1 1 1` bar/beat/division/tick | `BouncePosition.parse`, `TempoMap` |
    enum Format {
        /// A track header/region row is described `Track 7 “Bass”` — with
        /// TYPOGRAPHIC quotes, U+201C and U+201D, not `"`. Read by
        /// `TrackRowAddressing.parseRowDescription`, for the track-header
        /// column and the region row walk alike; a straight-quote build of
        /// Logic would make every region read return nothing.
        ///
        /// The quotes are also what tells the NAME from the row's live state:
        /// Logic writes `Track 26 “Crash”, solo` on a soloed row, and the
        /// parse takes only what is between them (measured 2026-09-03).
        ///
        /// FRENCH (R4, exact code points): `Piste 1 « Lofi Pad »` is
        /// `P i s t e SP 1 SP U+00AB U+00A0 L o f i SP P a d U+00A0 U+00BB` —
        /// French GUILLEMETS, each with a NO-BREAK SPACE on the inside. So
        /// both of these change GLYPH per locale, and the space inside the
        /// quotes is part of the punctuation, not part of the name. The
        /// number still comes BEFORE the name, so `parseTrackDescription`'s
        /// shape holds and this is a constants problem, not a parser one.
        static let openQuote: Character = "\u{201C}"
        static let closeQuote: Character = "\u{201D}"
        /// The word before the number in that same description.
        /// FRENCH (R4): `Piste `.
        static let trackDescriptionPrefix = "Track "

        /// Logic suffixes level readouts with this and formats the number in
        /// the SYSTEM's locale — so a Swedish Mac reads `-6,0 dB`. Every dB
        /// parser therefore strips the suffix and maps `,` to `.` before
        /// `Double(_:)`.
        ///
        /// FRENCH (R4): confirmed handled, no change needed. Logic printed
        /// `-16,5 dB` on the inspector strip and `+0,0dB` / `-10,7` on the MCU
        /// LCD; `logic_mixer_snapshot` parsed all 25 strips correctly. The
        /// unit stayed the two ASCII letters and no `㏈` was sighted.
        static let decibelSuffix = "dB"
        /// Some Logic panels print the SQUARE DB glyph U+33A9 (`㏈`) instead of
        /// the two letters. Both are stripped.
        static let decibelGlyph = "\u{33A9}"
        /// Both decimal separators a Logic readout can use. The parsers accept
        /// either rather than asking the system which is in force: the two
        /// cannot be confused in a Logic number (no thousands grouping
        /// appears in these fields).
        static let decimalSeparators: [Character] = [".", ","]
        /// A region publishes its POSITION only as an English sentence in its
        /// `AXHelp`: `"Region starts at 9 bars 2 beats and ends at 11 bars ,
        /// MIDI region."` Every bar number in `logic_list_regions` — and so
        /// every region-addressing tool that resolves `start_bar` — comes out
        /// of these three regexes.
        ///
        /// This is the single largest locale exposure in the server: a
        /// translated help sentence leaves the arrangement map with region
        /// NAMES and no bars or types at all. It is also the one that cannot
        /// be fixed structurally — Logic publishes the numbers nowhere else on
        /// this element. The locale session's job here is to capture the
        /// translated sentence and add a second pattern, not to find a better
        /// address.
        ///
        /// FRENCH (R4, measured verbatim on MIDI and audio regions, with and
        /// without a beat offset):
        ///
        /// ```
        /// La région commence à 1 mesure  et se termine à 5 mesures , Région MIDI .
        /// La région commence à 39 mesures 4 temps 4 divisions  et se termine à 41 mesures 35 ticks , Région audio .
        /// ```
        ///
        /// * `starts at` → `commence à`, `ends at` → `se termine à`
        /// * `bars` → `mesures` (singular `mesure` for 1, so `mesures?`
        ///   still does the right thing); `beats` → `temps`; `divisions` and
        ///   `ticks` keep their English nouns
        /// * **`typePattern` cannot be translated, only RESHAPED.** English
        ///   writes `<TYPE> region`; French writes `Région <TYPE>` — the noun
        ///   comes FIRST, so the capture group has to move:
        ///   `#",\s*Région ([A-Za-zÀ-ÿ]+)"#`. And the tail carries a NO-BREAK
        ///   SPACE before the period (`Région MIDI\u{00A0}.`).
        /// * The type words differ in case between kinds — `MIDI` uppercase,
        ///   `audio` lowercase — so a case-sensitive map would miss one.
        ///
        /// On a French Logic the row walk finds nothing at all (the row
        /// descriptions are localized too), and `logic_list_regions` used to
        /// answer `{"tracks": []}` — an empty project. It now cross-checks the
        /// track header column and REFUSES when the walk came up empty while
        /// the arrangement is unreadable or visibly has tracks; see
        /// `LogicAccessibility.emptyArrangementVerdict`.
        enum RegionHelp {
            static let startPattern = #"starts at \d+ bars?\s*(\d+ beats?)?"#
            static let endPattern = #"ends at \d+ bars?\s*(\d+ beats?)?"#
            /// Captures the `, MIDI region` / `, Audio region` tail; the noun
            /// is then stripped to leave the type.
            static let typePattern = #",\s*([A-Za-z]+) region"#
            static let typeNoun = "region"
        }

        /// The Key Commands window prints a learned MIDI-note assignment as
        /// `Note 109`. The learn verification looks for this, but does NOT
        /// depend on it: some notes display symbolically instead (note 109
        /// shows as `F2 (Modifiers ▶︎ Cmd/Alt)` because it maps to a named
        /// MCU control), so "the row's assignment display CHANGED" is the
        /// fallback proof and the one that survives translation.
        static let keyCommandNotePrefix = "Note "

        /// Logic's spelling of "minus infinity" on a fader or send level.
        /// A send created by the control surface lands here and is INAUDIBLE,
        /// which is why the tools say so out loud.
        static let negativeInfinity = "-oo"

        /// Strips `decibelSuffix` and normalises the decimal separator.
        /// Gathered here so the two independent copies (`decibelValue(of:)` on
        /// the Accessibility plane, `ChannelStrip.parseDb` on the surface
        /// plane) share one definition of what a dB string looks like.
        static func normalizedDecibelText(_ raw: String) -> String {
            raw.replacingOccurrences(of: decibelSuffix, with: "")
                .replacingOccurrences(of: decibelGlyph, with: "")
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
