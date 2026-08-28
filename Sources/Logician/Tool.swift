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

    /// Appended by `definition` to every tool whose result can carry a
    /// top-level `warning` (the `mayWarn` flag). One fixed sentence, because a
    /// model that learns the convention once should not have to relearn it per
    /// tool: the KEY and its joining rule are the same everywhere, and what the
    /// warning is ABOUT is the warning's own job to say.
    static let warningNote = " MAY RETURN `warning`: one string naming something true and unwelcome about this result (several are joined into it with ' ALSO: '). Read it before acting on the rest of the result."

    /// Appended to every tool whose `track_name` also accepts a strip that has
    /// no track header. Same sentence everywhere on purpose: an agent that
    /// learns it once can reuse it, and the caveats are the same in every case.
    static let stripAddressingNote = " Also accepts output/aux/bus strip names ('Stereo Out', 'Master', 'Aux 1', bus names): those have no track header, so they are resolved and selected on the control surface (LCD name + SELECT LED verified before any write) instead of by track selection. Use the name as Logic shows it in the Mixer, not the 6-character LCD abbreviation. Needs the MCU bridge for those names, and track_number applies to tracks only."

    /// For the Accessibility-only strip tools: they reach a headerless strip
    /// only while an inspector is SHOWING it, which the control-surface tools
    /// do not require (verified 2026-08-27: 'Stereo Out' was visible as the
    /// selected track's output while 'Master' and 'Aux 1' were not).
    static let stripAddressingAXNote = " Output/aux/bus strips ('Stereo Out') work too, but only while an inspector is SHOWING that strip (select a track routed to it; opening the Mixer does NOT put a strip in reach of these tools, measured) — Accessibility cannot reach a strip no inspector shows. For any other strip use the control-surface tools (logic_mcu_plugin_inserts, logic_mcu_plugin_parameters), which address every strip in the project."

    static let evaluateChangeListenNote = "Do not decide keep/rollback from the numbers alone: LISTEN to baseline_audio and after_audio (open the preview/clip files with your client's file viewer) before judging."
}
