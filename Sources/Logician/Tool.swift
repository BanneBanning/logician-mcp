import Foundation

/// What a tool DOES to Logic, in the vocabulary MCP clients use for
/// auto-approve policy and ranking (`annotations` in the 2025-06-18 spec).
///
/// One required choice per tool rather than three loose booleans, for two
/// reasons: `readOnly` and `destructive` are mutually exclusive and a struct
/// of independent flags lets them both be set; and a DEFAULTED safety flag is
/// exactly the silence this exists to remove — the compiler now refuses a new
/// tool that has not said what it does. `idempotent` stays separate because it
/// is orthogonal (a delete can be destructive AND non-idempotent, a value
/// write neither).
enum ToolSafety {
    /// Reads and changes nothing a user could notice or miss: no project
    /// state, no track selection, no window, no transport. The only writes
    /// allowed here are the server's OWN result artifacts (the audio clip
    /// `logic_get_audio_clip` also returns inline), which cannot destroy
    /// anything and which a client should be free to auto-approve.
    case readOnly
    /// Changes something — a value, the selection, the transport, a new
    /// region, a new file — but REMOVES no existing work. Reversible by the
    /// same tool or one Undo.
    case write
    /// Can remove existing work or discard unsaved changes. Deletes, the
    /// project-lifecycle tools (open/new/duplicate all CLOSE the current
    /// project, and `if_current_modified: 'dont_save'` throws its changes
    /// away), plugin removal, region edits that can overlay other regions,
    /// automation passes that overwrite an existing curve, and the two raw
    /// escape hatches whose effect is whatever the caller asked for.
    case destructive
}

/// One tool, whole: the name and schema `tools/list` advertises, the flags
/// that decide which standing instruction a successful result carries, and
/// the function `tools/call` dispatches to. Keeping them in one value is the
/// point — the schema list and the dispatch table used to be two hand-kept
/// lists, and a schema without a handler only showed up as a runtime
/// "unknown tool".
struct Tool {
    let name: String
    /// A short human name for approval dialogs and tool pickers, e.g. "Bounce
    /// a bar range". Required, not defaulted: without it a client renders the
    /// raw `logic_set_track_volume` at the human who has to decide whether to
    /// allow it, and a snake_case identifier is not what a person reads
    /// fastest under a permission prompt. Terse on purpose — it is a label,
    /// and the description is one field away.
    let title: String
    let description: String
    let inputSchema: [String: Any]
    /// How this tool touches Logic. Required on purpose: see `ToolSafety`.
    let safety: ToolSafety
    /// True when this tool's result can carry a top-level `warning`.
    ///
    /// Declared here rather than written into each description by hand for the
    /// same reason `stripAddressingNote` is a constant: 28 tools can warn, the
    /// sentence explaining the key is the same for all of them, and a hand-kept
    /// copy in 28 descriptions is 28 chances to drift. `definition` appends
    /// `Tool.warningNote` when this is set, so the advertised surface and this
    /// flag cannot disagree.
    let mayWarn: Bool
    /// True when repeating the call with the SAME arguments causes no further
    /// change — the tool names an absolute target state ("set X to V",
    /// "select T", "close W") rather than a relative or accumulating one
    /// ("create another", "step by N", "nudge right", "record a take").
    /// Deliberately under-claimed where it is arguable: a missing
    /// idempotentHint only makes a client less willing to retry.
    let idempotent: Bool
    /// Writes that change how the song SOUNDS; successful results carry the
    /// "judge it by ear" note.
    let changesSound: Bool
    /// Writes that move audio around in time; the failure mode is different
    /// (a displaced groove), so the note is too.
    let changesArrangement: Bool
    /// Replaces the generic sound note where a tool needs specific advice.
    let listenNote: String?
    /// Unapplied method reference, e.g. `MCPServer.handleHealth`, so the
    /// registry stays a plain description of the server rather than a set of
    /// closures capturing one.
    let handler: (MCPServer) -> ([String: Any]) throws -> Any

    init(
        name: String,
        title: String,
        description: String,
        inputSchema: [String: Any],
        safety: ToolSafety,
        mayWarn: Bool = false,
        idempotent: Bool = false,
        changesSound: Bool = false,
        changesArrangement: Bool = false,
        listenNote: String? = nil,
        handler: @escaping (MCPServer) -> ([String: Any]) throws -> Any
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.safety = safety
        self.mayWarn = mayWarn
        self.idempotent = idempotent
        self.changesSound = changesSound
        self.changesArrangement = changesArrangement
        self.listenNote = listenNote
        self.handler = handler
    }

    /// The MCP tool annotations (spec 2025-06-18). All four hints are emitted
    /// on every tool, never omitted: the spec's DEFAULTS are `readOnlyHint:
    /// false`, `destructiveHint: TRUE`, `idempotentHint: false`,
    /// `openWorldHint: TRUE`, so silence tells a client the opposite of the
    /// truth for most of this server. Hints, not permissions — a client must
    /// still not trust them for security decisions.
    var annotations: [String: Any] {
        [
            // The spec's own home for a human-readable name (ToolAnnotations
            // .title, 2025-06-18). Here rather than as a top-level `title`
            // because that field arrived later, and this server negotiates
            // down to 2024-11-05: annotations are the version every client it
            // talks to already reads.
            "title": title,
            "readOnlyHint": safety == .readOnly,
            // Only meaningful when readOnlyHint is false; emitted regardless
            // so a client never has to fall back to the `true` default.
            "destructiveHint": safety == .destructive,
            "idempotentHint": idempotent,
            // False everywhere: every tool acts on exactly ONE local Logic Pro
            // instance through its control surface and Accessibility tree.
            // There is no network, no search, no unbounded set of entities —
            // the closed world the spec contrasts with a web search.
            "openWorldHint": false
        ]
    }

    /// The `tools/list` wire shape.
    var definition: [String: Any] {
        [
            "name": name,
            "description": description + (mayWarn ? Tool.warningNote : ""),
            "inputSchema": inputSchema,
            "annotations": annotations
        ]
    }

    /// The standing instruction a successful result carries, or nil for the
    /// tools that neither change the sound nor the arrangement.
    var listenNoteText: String? {
        guard changesSound || changesArrangement else { return nil }
        if changesArrangement { return Tool.arrangementListenNote }
        return listenNote ?? Tool.soundListenNote
    }

    static let soundListenNote = "You changed how the song SOUNDS. Judge the result by LISTENING (bounce the section, open the preview with your client's file viewer) - a fader or parameter value is not loudness; recordings and plugins differ."

    static let arrangementListenNote = "You changed the ARRANGEMENT. Bounce a range that includes a few bars BEFORE your edit and listen across the seam: the classic failure is the copied phrase landing displaced (snare on the wrong beat) even though the region boundaries read as bar-aligned - region positions do NOT prove the groove inside is aligned. If the pattern does not match the original groove exactly, undo and copy from a region that starts ON the beat (watch out for pickup regions)."

    // MARK: The cross-cutting notes
    //
    // Each of the four below states a rule that is true of MANY tools, so each
    // used to be spelled out in full on every one of them: 181 bytes × 28
    // tools, 414 × 14, 407 × 3, 345 × 4 — 13.5 KB of `tools/list` spent saying
    // four things sixty-nine times, once per session, before a single call.
    //
    // The rules now live ONCE in `MCPServer.instructions`, which `initialize`
    // sends before the first tool call, and what stays on the tool is a
    // pointer: enough for a model reading only this description to know the
    // rule applies to it and where the full text is. Nothing was deleted —
    // every sentence that was here is in the instructions, most of it expanded.
    // What was removed is the repetition. Measured over the whole registry,
    // these four plus the nine hand-copied insert-numbering property
    // descriptions took `tools/list` from 151,028 to 143,102 bytes against
    // 2,417 added to the instructions: 5.5 KB a session, and four rules that
    // can no longer drift between their copies because there are none.

    /// Appended by `definition` to every tool whose result can carry a
    /// top-level `warning` (the `mayWarn` flag). The KEY, its joining rule and
    /// the instruction to read it first are in the instructions' RESULT
    /// CONTRACT; what the warning is ABOUT is the warning's own job to say.
    static let warningNote = " MAY RETURN `warning` — read it before the rest of the result (RESULT CONTRACT in the server instructions)."

    /// Appended to every tool whose `track_name` also accepts a strip that has
    /// no track header ('Stereo Out', 'Master', 'Aux 1', a bus).
    static let stripAddressingNote = " Accepts headerless output/aux/bus strips — see STRIP ADDRESSING in the server instructions."

    /// For the Accessibility-only strip tools: they reach a headerless strip
    /// only while an inspector is SHOWING it, which the control-surface tools
    /// do not require (verified 2026-08-27: 'Stereo Out' was visible as the
    /// selected track's output while 'Master' and 'Aux 1' were not).
    static let stripAddressingAXNote = " ACCESSIBILITY-ONLY: a headerless strip works only while an inspector is SHOWING it — see STRIP ADDRESSING in the server instructions."

    /// The `insert_index` / `insert_slot` distinction, on the arguments that
    /// take one. The full statement — which tools take which, and the measured
    /// reversal that makes converting between them dangerous — is the
    /// instructions' INSERT NUMBERING paragraph.
    static let axInsertIndexNote = " ACCESSIBILITY ordinal (logic_list_inserts route 'ax'), NOT the Mackie insert_slot — see INSERT NUMBERING in the server instructions."

    /// The mirror of `axInsertIndexNote`, for the Mackie physical slot.
    static let mcuInsertSlotNote = " MACKIE physical slot 1-8 (logic_list_inserts route 'mcu'), NOT the Accessibility insert_index — see INSERT NUMBERING in the server instructions."

    static let evaluateChangeListenNote = "Do not decide keep/rollback from the numbers alone: LISTEN to baseline_audio and after_audio (open the preview/clip files with your client's file viewer) before judging."

    /// Appended by `toolResult` to the note of EVERY result that carried audio
    /// — the bounce, the render, the A/B and the clip — rather than declared
    /// per tool like `listenNote`.
    ///
    /// It answers a failure mode a live multimodal round produced and no
    /// result key can detect: given the audio AND the metadata, the model
    /// described region names it had read as things it had heard. The
    /// `blind: true` argument is the tool for avoiding that; this sentence is
    /// the standing reminder for the calls that do not pass it, delivered at
    /// the only moment it can land — beside the audio itself. ONE sentence on
    /// purpose: the note it joins already carries the mix-by-ear contract, and
    /// a paragraph here would be read as boilerplate and skipped.
    static let epistemicsNote = " Separate what you HEARD from what you read in metadata: region names, track names and metrics are not listening, and must never be presented as heard."
}
