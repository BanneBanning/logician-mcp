import Foundation

// "Is Logician registered with the app you are actually using?"
//
// The commonest first-day failure is not a Logic problem at all: the binary
// was built, the Mackie Control was added, and the client was never restarted
// — or was registered with a path that has since moved. The maintainer cannot
// see any of that from an issue, and the user has no reason to know which file
// their client keeps its MCP servers in. So the doctor reads them.
//
// READ-ONLY, and narrow: it opens known config paths, looks for a server entry
// that mentions us, and reports the client name, whether we are in it, and the
// launch flags that entry carries. It never writes, never rewrites a config,
// and never reports the file's other contents — `~/.claude.json` in particular
// is a list of every project the user has ever opened, and none of that
// belongs in a support report.

/// One MCP client's config file, as the doctor knows how to find it.
struct DoctorClientConfig {
    /// What the user calls the app.
    let client: String
    /// Path relative to the home directory.
    let relativePath: String
}

/// What a config file says about us.
struct DoctorClientRegistration: Equatable {
    /// The server key Logician is registered under, e.g. `logician`. Several
    /// when a user has registered it more than once, which is itself worth
    /// seeing: two entries with different paths is a real support case.
    let serverNames: [String]
    /// `--toolsets=…` or `LOGICIAN_TOOLSETS`, verbatim, when the entry carries
    /// one. This is why a user's agent "cannot see" a tool that exists.
    let toolsets: String?
    /// The `command` the client will run, so a path that no longer exists is
    /// visible. Redacted before it is printed.
    let command: String?

    var isRegistered: Bool { !serverNames.isEmpty }
}

enum DoctorClients {
    /// The paths worth looking in, in the order INSTALL.md introduces them.
    /// A client whose file is absent is simply not reported: the doctor says
    /// which clients it FOUND, never which ones the user failed to install.
    static let known: [DoctorClientConfig] = [
        DoctorClientConfig(client: "Claude Code", relativePath: ".claude.json"),
        DoctorClientConfig(
            client: "Claude Desktop",
            relativePath: "Library/Application Support/Claude/claude_desktop_config.json"
        ),
        DoctorClientConfig(client: "Gemini CLI", relativePath: ".gemini/settings.json"),
        DoctorClientConfig(
            client: "Gemini CLI (extension)",
            relativePath: ".gemini/extensions/logician/gemini-extension.json"
        ),
        DoctorClientConfig(client: "Antigravity", relativePath: ".antigravity/mcp_config.json"),
        DoctorClientConfig(client: "Cursor", relativePath: ".cursor/mcp.json"),
        DoctorClientConfig(
            client: "VS Code", relativePath: "Library/Application Support/Code/User/mcp.json"
        ),
        DoctorClientConfig(
            client: "Windsurf", relativePath: ".codeium/windsurf/mcp_config.json"
        ),
        DoctorClientConfig(client: "LM Studio", relativePath: ".lmstudio/mcp.json")
    ]

    /// The substring that makes a server entry ours. Matched against the
    /// entry's KEY and against its `command`, so both `"logician": {...}` and
    /// a differently-named entry pointing at our binary are found.
    static let marker = "logician"

    /// What a config file turned out to be. Three of these are not JSON
    /// objects, and each needed its own sentence: an EMPTY file (VS Code
    /// creates one the moment you open the MCP view) reads as "not readable
    /// JSON" unless it is told apart, and a file with `//` comments in it —
    /// which VS Code and Cursor both accept — is a perfectly good config that
    /// `JSONSerialization` refuses. Saying "unreadable" about either would
    /// send a user to fix a file that is fine.
    enum Reading: Equatable {
        case empty
        case parsed
        /// Not strict JSON, but the text mentions us — almost certainly a
        /// JSONC config with comments.
        case commentedMentioningUs
        /// Not strict JSON and no mention of us either.
        case unreadable
    }

    /// Classifies a config file's bytes. Pure, so the empty file and the
    /// commented file are pinned by tests rather than by whatever this
    /// developer happens to have installed.
    static func reading(of data: Data) -> (Reading, Any?) {
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (.empty, nil) }
        if let object = try? JSONSerialization.jsonObject(with: data) { return (.parsed, object) }
        return (text.lowercased().contains(marker) ? .commentedMentioningUs : .unreadable, nil)
    }

    /// Walks a parsed config object and reports what it says about us.
    ///
    /// Deliberately shape-agnostic. Every client nests its servers somewhere
    /// slightly different — Claude Code keeps a global `mcpServers` AND one per
    /// project, Gemini's extension file has no `mcpServers` wrapper at all —
    /// and hard-coding nine shapes would rot the first time one of them
    /// changed. Instead: recurse, and treat any dictionary under a key named
    /// `mcpServers` or `servers` as a server table. Pure, so the shapes are
    /// pinned by tests rather than by whatever is installed on the developer's
    /// Mac.
    static func registration(in object: Any) -> DoctorClientRegistration {
        var names: [String] = []
        var toolsets: String?
        var command: String?
        walk(object) { name, entry in
            let entryCommand = entry["command"] as? String
            let mentionsUs = name.lowercased().contains(marker)
                || (entryCommand?.lowercased().contains(marker) ?? false)
            guard mentionsUs else { return }
            if !names.contains(name) { names.append(name) }
            command = command ?? entryCommand
            toolsets = toolsets ?? self.toolsets(in: entry)
        }
        return DoctorClientRegistration(
            serverNames: names.sorted(), toolsets: toolsets, command: command
        )
    }

    /// `--toolsets=…` from the argument vector, or `LOGICIAN_TOOLSETS` from the
    /// entry's environment — the two spellings `MCPServer.configureToolsets`
    /// accepts, read back from the config that will supply them.
    static func toolsets(in entry: [String: Any]) -> String? {
        if let arguments = entry["args"] as? [Any] {
            for argument in arguments.compactMap({ $0 as? String })
            where argument.hasPrefix(MCPServer.toolsetsFlag + "=") {
                return argument
            }
        }
        if let environment = entry["env"] as? [String: Any],
           let value = environment[MCPServer.toolsetsEnvironmentVariable] as? String {
            return MCPServer.toolsetsEnvironmentVariable + "=" + value
        }
        return nil
    }

    /// Recurses into every dictionary, handing the visitor each `(name, entry)`
    /// pair found under an `mcpServers` / `servers` table. A table whose values
    /// are not dictionaries is skipped rather than guessed at.
    private static func walk(_ object: Any, visit: (String, [String: Any]) -> Void) {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] {
                for element in array { walk(element, visit: visit) }
            }
            return
        }
        for (key, value) in dictionary {
            if key == "mcpServers" || key == "servers", let table = value as? [String: Any] {
                for (name, entry) in table {
                    if let entry = entry as? [String: Any] { visit(name, entry) }
                }
            }
            walk(value, visit: visit)
        }
    }
}
