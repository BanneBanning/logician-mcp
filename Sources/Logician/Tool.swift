import Foundation

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
        changesSound: Bool = false,
        changesArrangement: Bool = false,
        listenNote: String? = nil,
        handler: @escaping (MCPServer) -> ([String: Any]) throws -> Any
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.changesSound = changesSound
        self.changesArrangement = changesArrangement
        self.listenNote = listenNote
        self.handler = handler
    }

    /// The `tools/list` wire shape.
    var definition: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
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

    static let evaluateChangeListenNote = "Do not decide keep/rollback from the numbers alone: LISTEN to baseline_audio and after_audio (open the preview/clip files with your client's file viewer) before judging."
}
