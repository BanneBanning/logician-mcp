import Foundation

/// Every literal this project matches against the Mackie Control LCD, in ONE
/// place — the precondition for running against a Logic that is not in
/// English.
///
/// Both processes read LCD text: the daemon converges numeric echoes
/// in-process next to the mirror, the server verifies views and parses
/// parameter pages afterwards. So the table lives in the bridge target for the
/// same reason `MCULCDRow` does — two copies would be two chances to disagree
/// about what the surface says, and a write lands on the disagreement.
///
/// The table is split by what a locale change would actually do to it:
///
/// * **LOCALE-RISK** — Logic's OWN words, painted into LCD cells from Logic's
///   localized string catalogue. A Swedish Logic is expected to paint
///   something else. Every entry carries where Logic paints it and what a
///   per-locale session has to re-measure.
/// * **PROTOCOL-CONSTANT** — tokens that come from the Mackie Control display
///   grammar rather than from Logic's prose: 2-character assignment codes on
///   the 7-segment display, the `--`/`-` placeholders, the `*` bypass marker.
///   They are collected here so the duplication has one home, and each says
///   why it is NOT expected to move — a localization pass should read this
///   section, confirm the reasoning, and then leave it alone.
///
/// Two locale hazards are already neutralized elsewhere and are recorded here
/// so a future pass does not "fix" them twice:
///
/// * **Decimal separator.** Logic paints `-19,5` on a Swedish system and
///   `-19.5` on an English one. Every numeric read normalizes `,` to `.`
///   before parsing (`MCUController.parseDb`, the daemon's `converge`), so the
///   separator is handled, not assumed.
/// * **The `dB` suffix.** A 7-character cell cuts it mid-word (`-10,0 d`), so
///   nothing matches on it: parsing keeps the leading numeric run and drops
///   the rest. A translated unit therefore costs nothing.
///
/// # Measured against a FRENCH Logic, 2026-08-30 (R4)
///
/// **The mode banners are NOT localized.** With Logic's UI in French,
/// `assign_track` still painted `Channel Strip parameter: Volume` across the
/// top row, and the `Pan/Surround parameter…` banner appeared in English too —
/// so `channelStripVolumeBanner` and `parameterBannerMarker` both matched
/// unchanged, and the whole control-surface plane read correctly
/// (`logic_mixer_snapshot` returned all 25 strips with the right dB, pan,
/// mute, solo, selection and record-arm).
///
/// The PROTOCOL-CONSTANT reasoning is confirmed: the assignment display read
/// `PN` for the Pan view and `CS` for the channel-strip view under a French
/// UI, exactly as this file predicts. Leave that section alone.
///
/// Two cautions for the next locale pass:
///
/// * **Do not generalize "the LCD is English".** The surround pan page painted
///   `Angle Divers LFE Spread … CStrip Ang/Dv X/Y`, and `Divers` IS French. So
///   Logic draws *some* LCD pages from its localized catalogue; only the
///   entries measured above are known safe.
/// * `insertListFirstSlotLabel`, `sendFieldLabelPrefix`,
///   `sendLevelFieldLabel`, `pageIndicatorWord`, `instrumentChannelFormats`
///   and `minusInfinity` are STILL UNMEASURED in French. Not because the LCD
///   was unreachable, but because every tool that would put those views on
///   screen resolves its target with `track_name`, and `selectStripTarget`
///   gates that on an Accessibility track-header read that a French Logic
///   fails — see `Logician-archive/R4-LOCALE-SESSION-CHECKLIST.md` §6.
public enum MCULCDStrings {

    // MARK: - LOCALE-RISK — Logic's own words on the LCD

    /// The mode banner Logic paints across the top row when `assign_track`
    /// puts the surface in the multi-channel channel-strip VOLUME view.
    ///
    /// This is the *functional* proof that the view is right: the 7-segment
    /// assignment code reads `CS` for every channel-strip submode, so only the
    /// banner tells volume apart from the others.
    ///
    /// Per locale, re-measure: press `assign_track` and read `lcd_top`. The
    /// whole sentence is Logic's, including the word for "Volume".
    public static let channelStripVolumeBanner = "Channel Strip parameter: Volume"

    /// The fragment shared by every mode banner Logic paints over the names
    /// row — `Channel Strip parameter: …`, `Pan/Surround parameter: …`. Its
    /// presence means "a banner is covering the right half of the row, the
    /// names underneath are not readable yet"; it fades on its own.
    ///
    /// Per locale, re-measure: press `assign_pan` and `assign_track` and read
    /// `lcd_top` during the first second. Whatever the banners have in common
    /// goes here — if the localized banners share nothing, this becomes a set
    /// and `MCUTransportLCD` needs a `contains(where:)`.
    public static let parameterBannerMarker = "parameter:"

    /// The top-row label of insert slot 1 in the plugin-list view
    /// (`assign_plugin`) — Logic's 7-character abbreviation of "Insert 1
    /// Plug-in". Used as the proof that the list view (rather than a
    /// per-insert parameter bank) is showing.
    ///
    /// Per locale, re-measure: `assign_plugin` on a track with inserts, read
    /// cell 0 of `lcd_top`. Logic abbreviates to fit 7 characters, so the
    /// localized form is not derivable from the localized word for "insert".
    public static let insertListFirstSlotLabel = "Ins1Pl"

    /// The prefix Logic gives every send FIELD label in the single-channel
    /// send view (`assign_send`, code `SE`): `SenNIn` (destination), `SenNPo`
    /// (position), `SenNMu` (status). Matching the prefix — rather than the
    /// whole label — is what lets one test cover all four field kinds.
    ///
    /// Per locale, re-measure: `assign_send` on a track with a send, read all
    /// eight cells of `lcd_top`. The 7-character budget again means the
    /// abbreviation must be observed, not translated.
    public static let sendFieldLabelPrefix = "Sen"

    /// The LEVEL field's label in the send view, spelled in full because the
    /// level is the only field this project ever turns a vpot on: an exact
    /// match is the guard that stops a mis-laid-out page from aiming the
    /// encoder at the destination browser.
    ///
    /// Per locale, re-measure alongside `sendFieldLabelPrefix`; note whether
    /// the number still trails the word.
    public static func sendLevelFieldLabel(_ sendNumber: Int) -> String {
        "Send \(sendNumber)"
    }

    /// The names Logic paints over a strip's NAME cell when it sees that
    /// strip's control pressed on the surface — press solo on `Bas` and the
    /// row reads `LofPad Solo   808 …` where the bank map says
    /// `LofPad Bas    808 …`.
    ///
    /// It stands for about two seconds and then clears itself: measured
    /// 2026-09-02 on `Testlåt Copy` by polling the LCD mirror every 50 ms
    /// across a solo and an unsolo of `Bas`, the cell appeared 0.22 s into the
    /// call and cleared 1.94 s and 1.99 s later. A bank change does NOT clear
    /// it — the same day a banner rode through three consecutive bank steps.
    /// (`bankedAtMatch`'s note that a 600 ms wait never recovered the row is
    /// right about 600 ms and wrong about the cause.) The bank census checks
    /// every bank's row against this list, because a banner standing there
    /// would otherwise be published as a strip's name and written to the bank
    /// cache, where the next `findChannel` misses that track, deletes the
    /// cache and pays a full rescan.
    ///
    /// Only `Solo` is measured. The others are the same mechanism on the other
    /// per-strip buttons and are listed so the check does not have to be
    /// rediscovered one banner at a time; a missing entry costs one banner
    /// read as a name, and an entry that is also a real strip name costs one
    /// forced repaint and nothing else — the check re-reads and believes what
    /// the repainted row says.
    ///
    /// Per locale, re-measure: solo a track and read `lcd_top`. These ARE
    /// Logic's words for its own controls, so unlike the mode banners (which
    /// stayed English under a French UI) they are expected to translate.
    public static let controlNameBanners = ["Solo", "Mute", "Select", "Rec/Rdy"]

    /// The word in the transient page indicator Logic flashes over the top row
    /// after a cursor-left/right press: `Page 3/12`. The indicator hides
    /// fields 6-7 while it is up, so half the parameter-page machinery is
    /// timed against its appearance and its fade.
    ///
    /// Per locale, re-measure: open a multi-page plugin, press cursor_left,
    /// read `lcd_top` within ~1 s. Check the word AND the separator — if a
    /// locale writes `3 av 12` the patterns below need reshaping, not just a
    /// new word.
    public static let pageIndicatorWord = "Page"

    private static let escapedPageWord =
        NSRegularExpression.escapedPattern(for: pageIndicatorWord)

    /// `Page 3/12` with both numbers captured — the read that yields
    /// (current, total).
    public static let pageIndicatorPattern = escapedPageWord + #" +(\d+)/(\d+)"#

    /// `Page 3/12` uncaptured — "is the indicator up right now".
    public static let pageIndicatorPresentPattern = escapedPageWord + #" +\d+/\d+"#

    /// `Page 3` — the looser form, for cells that hold only the head of the
    /// indicator because it spilled across a cell boundary.
    public static let pageIndicatorCellPattern = escapedPageWord + #" +\d+"#

    /// The channel-format words Logic appends to an instrument browser entry
    /// (`Drum Kit Designer Stereo`, `… Multi-Output`). Order matters: the
    /// two-word spelling is tried before the shorter ones so `Multi Output`
    /// is not read as a name ending in "Multi" plus nothing.
    ///
    /// Per locale, re-measure: browse the IN bank view's vpot on a scratch
    /// track and collect the suffixes. `Stereo`/`Mono` survive most locales;
    /// `Multi-Output` does not.
    public static let instrumentChannelFormats = ["Multi-Output", "Multi Output", "Stereo", "Mono"]

    /// How Logic renders minus infinity in a dB readout — ASCII, because the
    /// LCD has no `∞`. Parsed as `minusInfinityDb`.
    ///
    /// Per locale, re-measure: pull any fader to the bottom and read the
    /// bottom row. Low risk (it is a glyph substitution, not a word), but it
    /// IS painted by Logic and would silently read as "not numeric" if it
    /// moved — which is a wrong answer, not an error.
    public static let minusInfinity = "-oo"

    /// The dB value `minusInfinity` stands for. Not a floor Logic reports; the
    /// number this project agrees to treat "off" as, so convergence has
    /// something to compare against.
    public static let minusInfinityDb = -70.0

    // MARK: - PROTOCOL-CONSTANT — not localization surface

    /// An empty slot: insert, send destination, instrument. Two ASCII hyphens
    /// filling a 7-character cell — the Mackie display grammar's "nothing
    /// here", not a word, and the plugin-removal browser walks TOWARD it as a
    /// boundary entry. No locale is expected to translate punctuation.
    public static let emptySlot = "--"

    /// A single hyphen: the placeholder Logic paints into a cell it is in the
    /// middle of clearing, and into the strips of a bank that is not full.
    /// Same reasoning as `emptySlot` — punctuation, not prose. Four or more of
    /// them across the row is this project's "the display is mid-repaint"
    /// signal.
    public static let clearingCell = "-"

    /// The bypass marker Logic prefixes to a bypassed insert's name (`*ChanEQ`).
    /// A leading glyph, not part of the name and not a word; trimmed off
    /// before any name comparison.
    public static let bypassMarker = "*"

    /// What the 10-digit 7-segment TIMECODE display reads while a modal dialog
    /// has Logic's attention. Five characters chosen for what a 7-segment cell
    /// can actually form — the same constraint that keeps the assignment codes
    /// two letters — so it is display grammar rather than prose. Matched
    /// case-insensitively already; cheap to re-confirm per locale, but it is
    /// not on the translation list.
    public static let modalAlertTimecode = "ALERT"

    /// The 2-character codes on the assignment display. These are the Mackie
    /// Control's own mode identifiers: `PN` pan, `IN` instrument, `SE` send,
    /// `EQ`, `CS` channel strip, `P1`…`P8` per-insert parameter banks. They are
    /// not words and do not follow Logic's UI language — an English `Pan` view
    /// and a Swedish one both report `PN`.
    ///
    /// Kept as a table only so the codes have one home; a localization pass
    /// should confirm the reasoning once and then skip this section.
    public enum Assignment {
        public static let pan = "PN"
        public static let instrument = "IN"
        public static let send = "SE"
        public static let channelStrip = "CS"
        public static let equalizer = "EQ"

        /// The per-insert parameter bank for insert `slot` (1-8): `P1`…`P8`.
        public static func insertSlot(_ slot: Int) -> String { "P\(slot)" }
    }
}
