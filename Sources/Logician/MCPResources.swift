import Foundation

// MARK: - The captures directory

/// Where every rendered capture lands, and the ONE place that path is spelled.
///
/// It used to be written out three times — in `MCURender`, in `AXBounce` and in
/// the clip handler — which was survivable while nothing but those three
/// touched it. It stopped being survivable the moment `resources/read` had to
/// decide whether a path is inside the directory or outside it: a containment
/// check against a fourth copy of a string literal is a security boundary made
/// of a typo.
enum Captures {
    /// Set by TESTS only, and never by anything that ships. The real path is a
    /// directory of the user's actual renders — hundreds of megabytes of their
    /// music — and a test suite that writes fixtures into it, or reads one out,
    /// is a test suite that has escaped into someone's Application Support.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Logician/captures")
    }

    /// The root, created if it is not there yet. Every writer wants this; the
    /// resource layer deliberately does NOT, because a `resources/list` on a
    /// machine that has never rendered anything should report an empty family
    /// rather than quietly create a folder as a side effect of reading.
    @discardableResult
    static func ensureRoot() -> URL {
        let root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The audio this server is willing to serve, and their MIME types.
    ///
    /// An ALLOW-LIST, not a lookup that falls back to
    /// `application/octet-stream`: the captures directory is the destination of
    /// agent-named renders, and "serve whatever is in there" is a wider promise
    /// than this server can keep. Anything else in the folder is simply not a
    /// resource.
    static let audioMIMETypes: [String: String] = [
        "wav": "audio/wav",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "aifc": "audio/aiff",
        "m4a": "audio/mp4",
        "mp4": "audio/mp4",
        "caf": "audio/x-caf",
        "mp3": "audio/mpeg",
        "flac": "audio/flac"
    ]

    static func mimeType(forPathExtension extensionName: String) -> String? {
        audioMIMETypes[extensionName.lowercased()]
    }

    // MARK: - Retention

    /// The most bytes of audio the captures directory may hold, and the most
    /// files. NOTHING pruned this folder before 2026-09-02, and it grows by
    /// the length of the PROJECT on every freeze render regardless of the bars
    /// asked for: measured on the development machine, 169 files / 1.2 GB, of
    /// which 71 `render-*` files / 1.1 GB were leftovers, ~46 MB per call.
    ///
    /// The numbers are deliberately ABOVE what that machine already held, so
    /// shipping this deletes nothing that is there today and only bounds what
    /// arrives from now on — a retention policy is not a licence to throw away
    /// the user's renders the first time they update the server. Tighten them
    /// here, in one place, when the budget should bite sooner.
    static let retentionByteBudget: Int64 = 2_000_000_000
    static let retentionFileBudget = 200

    /// Captures this never removes, however far over budget the folder is:
    /// the newest few files are the ones the CURRENT call just wrote (a render
    /// writes an `.aif`, its `.m4a` preview and, with a bar range, a `.wav`
    /// slice and that slice's preview), and a sweep that deletes those has
    /// eaten the result it was making room for.
    static let retentionAlwaysKeepNewest = 8

    /// One capture, as the policy sees it. Separately typed so the decision is
    /// pure arithmetic over a list and can be tested without a directory.
    struct Capture: Equatable {
        let name: String
        let bytes: Int64
        let modified: Date
    }

    /// Which captures a sweep would remove, oldest first.
    ///
    /// Newest-first, keep while it fits, and once one file does not fit, it
    /// and everything older goes — the classic shape, and the one an agent can
    /// predict: "the newest N captures inside M bytes survive". Ties in
    /// modification date break by name so two runs on the same folder agree.
    static func retentionPlan(
        _ captures: [Capture],
        byteBudget: Int64 = retentionByteBudget,
        fileBudget: Int = retentionFileBudget,
        alwaysKeepNewest: Int = retentionAlwaysKeepNewest
    ) -> [Capture] {
        let newestFirst = captures.sorted {
            $0.modified == $1.modified ? $0.name > $1.name : $0.modified > $1.modified
        }
        var keptBytes: Int64 = 0
        var keptCount = 0
        var full = false
        var removals: [Capture] = []
        for capture in newestFirst {
            if keptCount < alwaysKeepNewest {
                keptBytes += capture.bytes
                keptCount += 1
                continue
            }
            if full || keptCount >= fileBudget || keptBytes + capture.bytes > byteBudget {
                full = true
                removals.append(capture)
                continue
            }
            keptBytes += capture.bytes
            keptCount += 1
        }
        return removals.reversed()
    }

    /// Enforces the policy on the real directory before a writer adds to it,
    /// and reports what it removed — nil when it removed nothing, which is the
    /// normal answer and must not put an empty block in every result.
    ///
    /// Only files whose extension is in `audioMIMETypes` are considered, so
    /// the sealed-metrics JSON, anything the user dropped in the folder that
    /// is not audio, and every subdirectory are left alone.
    @discardableResult
    static func makeRoom(
        byteBudget: Int64 = retentionByteBudget,
        fileBudget: Int = retentionFileBudget,
        alwaysKeepNewest: Int = retentionAlwaysKeepNewest
    ) -> [String: Any]? {
        let manager = FileManager.default
        let root = root
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }
        var captures: [Capture] = []
        for url in entries {
            guard mimeType(forPathExtension: url.pathExtension) != nil,
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
                  ]),
                  values.isRegularFile == true else { continue }
            captures.append(Capture(
                name: url.lastPathComponent,
                bytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        let removals = retentionPlan(
            captures, byteBudget: byteBudget, fileBudget: fileBudget,
            alwaysKeepNewest: alwaysKeepNewest
        )
        guard !removals.isEmpty else { return nil }
        var removedFiles = 0
        var removedBytes: Int64 = 0
        var failed: [String] = []
        for capture in removals {
            let url = root.appendingPathComponent(capture.name)
            if (try? manager.removeItem(at: url)) != nil {
                removedFiles += 1
                removedBytes += capture.bytes
            } else {
                failed.append(capture.name)
            }
        }
        guard removedFiles > 0 || !failed.isEmpty else { return nil }
        var report: [String: Any] = [
            "removed_files": removedFiles,
            "removed_bytes": Int(removedBytes),
            "policy": "the newest \(fileBudget) captures within"
                + " \(String(format: "%.1f", Double(byteBudget) / 1_000_000_000)) GB,"
                + " oldest first; the newest \(alwaysKeepNewest) are never removed",
            "note": "The captures directory is pruned by every tool that writes to it -"
                + " these files were the oldest over budget. Rendered audio is a CACHE of"
                + " something Logic can render again; anything to keep belongs outside"
                + " \(root.path)."
        ]
        if !failed.isEmpty { report["could_not_remove"] = failed }
        return report
    }
}

// MARK: - URIs

/// The agent guide, compiled into the binary (see `AgentGuideText.swift`).
let guideResourceURI = "logician://guide"

/// Everything under the captures directory: `logician://captures/<filename>`.
let capturesURIPrefix = "logician://captures/"

/// How many captures `resources/list` names. The directory holds hundreds of
/// files — 93 and 738 MB on the development machine after two weeks, 169 and
/// 1.2 GB a fortnight later, which is what `Captures.makeRoom` now bounds — so
/// listing all of them would put a megabyte of JSON in front of a model to
/// describe audio it will read at most one of. The most
/// recent N by modification time is what a session actually wants: the renders
/// it just made.
let capturesListLimit = 50

/// The largest capture `resources/read` will base64 and hand back. A `.wav`
/// master out of a four-minute bounce is 40-80 MB, and base64 makes it a third
/// larger again; a client that asked for one by accident would be handed
/// something no context can hold. Over the cap the read REFUSES and names the
/// AAC preview sibling, which is the file a listener wanted anyway.
let capturesReadByteCap = 8 * 1_024 * 1_024

/// How long a client may cache a resource listing. Short, and deliberately not
/// the hour `tools/list` gets: the tool surface is baked into the binary, while
/// the captures family gains a file every time the session renders one.
let resourceListCacheTTLMs = 15_000

// MARK: - Not found

/// The spec's resource-not-found error, in the code the era understands.
///
/// `-32002` is what 2025-03-26 through 2025-11-25 all specify. 2026-07-28
/// retired it — "servers MUST return a JSON-RPC error with code -32602" — and
/// tells clients to keep ACCEPTING `-32002` only for backwards compatibility.
/// Emitting the retired code to a modern client would be exactly the kind of
/// "we support the revision" claim this server refuses to make falsely.
func resourceNotFoundCode(era: MCPEra) -> Int {
    era.isModern ? -32602 : -32002
}

extension MCPServer {

    // MARK: - resources/list

    /// One `Resource` for the guide plus the most recent captures, in the shape
    /// the era can parse.
    func resourceList(era: MCPEra) -> [[String: Any]] {
        var resources: [[String: Any]] = [guideResource(era: era)]
        resources.append(contentsOf: recentCaptures(era: era))
        return resources
    }

    private func guideResource(era: MCPEra) -> [String: Any] {
        var resource: [String: Any] = [
            "uri": guideResourceURI,
            "name": "AGENT-GUIDE.md",
            "description": "The Logician agent guide: core concepts, verified workflows, "
                + "failure modes and the full tool reference. Compiled into the binary, so it "
                + "reads the same wherever this server was installed. "
                + "\(agentGuideMarkdown.utf8.count / 1024) KB of markdown.",
            "mimeType": "text/markdown",
            "size": agentGuideMarkdown.utf8.count
        ]
        // `title` arrived with 2025-06-18; the 2025-03-26 `Resource` has no such
        // member, and a client validating against that schema would reject it.
        if era.supportsResourceTitles {
            resource["title"] = "Logician Agent Guide"
            resource["annotations"] = ["audience": ["assistant"], "priority": 0.9]
        }
        return resource
    }

    /// The `capturesListLimit` newest audio files in the captures directory,
    /// newest first.
    private func recentCaptures(era: MCPEra) -> [[String: Any]] {
        let manager = FileManager.default
        let root = Captures.root
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        let audio = entries.compactMap { url -> (URL, Date, Int, String)? in
            guard let mime = Captures.mimeType(forPathExtension: url.pathExtension) else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { return nil }
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0, mime)
        }
        // Newest first, and the filename breaks ties so two files written in the
        // same second cannot reorder between two identical calls — a listing a
        // client is invited to cache has to be stable.
        let newest = audio.sorted {
            $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 > $1.1
        }.prefix(capturesListLimit)

        let stamp = ISO8601DateFormatter()
        return newest.map { url, modified, size, mime in
            let name = url.lastPathComponent
            var resource: [String: Any] = [
                "uri": capturesURIPrefix + (name.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? name),
                "name": name,
                "description": "\(describeBytes(size)) \(url.pathExtension.uppercased())"
                    + ", rendered \(stamp.string(from: modified))"
                    + (size > capturesReadByteCap
                        ? ". TOO LARGE to read over MCP — read the .m4a preview beside it instead."
                        : ""),
                "mimeType": mime,
                "size": size
            ]
            if era.supportsResourceTitles {
                resource["annotations"] = [
                    "audience": ["assistant", "user"],
                    "lastModified": stamp.string(from: modified)
                ]
            }
            return resource
        }
    }

    // MARK: - resources/read

    /// The `contents` array for one URI, or the fault to answer with instead.
    ///
    /// Everything a client can name resolves through here, and only two things
    /// resolve at all: the compiled-in guide, and ONE regular audio file whose
    /// real path — symlinks followed — sits directly inside the captures
    /// directory. There is no third case and no fall-through to the filesystem.
    func resourceContents(uri: String, era: MCPEra) -> Result<[[String: Any]], JSONRPCFault> {
        if uri == guideResourceURI {
            return .success([[
                "uri": guideResourceURI,
                "mimeType": "text/markdown",
                "text": agentGuideMarkdown
            ]])
        }
        guard uri.hasPrefix(capturesURIPrefix) else {
            return .failure(notFound(
                uri: uri, era: era,
                detail: "Unknown resource URI. This server serves exactly two families: "
                    + "'\(guideResourceURI)' (the agent guide) and "
                    + "'\(capturesURIPrefix)<filename>' (rendered audio). "
                    + "Call resources/list for the names it will answer to."
            ))
        }
        // Decoded HERE rather than inside the resolver, so the resolver can
        // also be handed a real filename off a tool result. A capture called
        // `take 50%.wav` percent-encodes to `take%2050%25.wav` and must come
        // back as itself; decoding a name that was never encoded would turn it
        // into a different file, or into nil.
        let raw = String(uri.dropFirst(capturesURIPrefix.count))
        guard let name = raw.removingPercentEncoding,
              let file = capturesFile(named: name) else {
            return .failure(notFound(
                uri: uri, era: era,
                detail: "No such capture. The name must be a single filename inside the captures "
                    + "directory — no path separators, no '..', no absolute paths — naming an "
                    + "audio file that exists (\(Captures.audioMIMETypes.keys.sorted().joined(separator: ", "))). "
                    + "Call resources/list for the \(capturesListLimit) most recent."
            ))
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= capturesReadByteCap else {
            return .failure(oversized(uri: uri, file: file, size: size, era: era))
        }
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            return .failure(JSONRPCFault(
                code: -32603,
                message: "The capture '\(file.lastPathComponent)' could not be read from disk.",
                data: ["uri": uri]
            ))
        }
        return .success([[
            "uri": uri,
            "mimeType": Captures.mimeType(forPathExtension: file.pathExtension) ?? "audio/mp4",
            "blob": data.base64EncodedString()
        ]])
    }

    /// Resolves one URI path segment to a real file inside the captures
    /// directory, or nil — and nil is the ONLY other outcome. Every rejection
    /// below has an attack behind it:
    ///
    /// - a segment that is not its own last path component, which rules out
    ///   `../`, `a/b`, and a leading `/` in one test rather than three;
    /// - `.` and `..` themselves, which have no last-component form to fail;
    /// - the real-path prefix check AFTER resolving symlinks, because a symlink
    ///   inside the captures directory is a single filename that names a file
    ///   anywhere on the disk;
    /// - regular-file-ness, so a directory named `x.wav` is not a resource;
    /// - the audio allow-list, so nothing else that lands in the folder is one.
    /// (The caller percent-DECODES first when the name came off a URI; see
    /// `resourceContents`. `%2e%2e%2f` therefore still cannot smuggle a
    /// separator through — it is a separator by the time it arrives here, and
    /// the separator check below rejects it.)
    private func capturesFile(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        guard name != "." && name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name == (name as NSString).lastPathComponent else { return nil }
        guard Captures.mimeType(forPathExtension: (name as NSString).pathExtension) != nil else {
            return nil
        }
        let root = Captures.root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(name)
            .resolvingSymlinksInPath().standardizedFileURL
        // Containment, on path COMPONENTS. A string prefix test would accept
        // `.../Logician/captures-elsewhere/x.wav` as living under
        // `.../Logician/captures`.
        let rootParts = root.pathComponents
        let parts = candidate.pathComponents
        guard parts.count == rootParts.count + 1, Array(parts.dropLast()) == rootParts else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    private func notFound(uri: String, era: MCPEra, detail: String) -> JSONRPCFault {
        JSONRPCFault(
            code: resourceNotFoundCode(era: era),
            message: "Resource not found: \(uri). " + detail,
            data: ["uri": uri]
        )
    }

    /// The refusal that points somewhere useful. Every `.wav`/`.aif` master this
    /// server writes gets an `.m4a` AAC preview beside it under the same stem
    /// (`LogicAccessibility.makeAACPreview`), and that preview is what a client
    /// wanting to LISTEN should fetch — a tenth the size, and the same audio.
    private func oversized(uri: String, file: URL, size: Int, era: MCPEra) -> JSONRPCFault {
        let preview = file.deletingPathExtension().appendingPathExtension("m4a")
        var message = "The capture '\(file.lastPathComponent)' is \(describeBytes(size)), over this "
            + "server's \(describeBytes(capturesReadByteCap)) resource cap; NOTHING was returned. "
        if file.pathExtension.lowercased() != "m4a",
           FileManager.default.fileExists(atPath: preview.path) {
            message += "Read '\(capturesURIPrefix)\(preview.lastPathComponent)' instead — the AAC "
                + "preview of this same render, small enough to fetch and the same audio to listen to."
        } else {
            message += "Call logic_get_audio_clip on '\(file.path)' for a short encoded clip of it "
                + "instead, or open the file with your client's file viewer."
        }
        return JSONRPCFault(
            code: resourceNotFoundCode(era: era),
            message: message,
            data: ["uri": uri, "size": size, "maxBytes": capturesReadByteCap]
        )
    }

    // MARK: - resource_link blocks

    /// The `resource_link` blocks that belong on one tool result.
    ///
    /// Built from the result's OWN path keys rather than from a per-tool list,
    /// so a tool cannot gain an audio path and silently miss its link. A path
    /// earns a link only when it resolves to a real audio file inside the
    /// captures directory, which is also exactly the set of paths
    /// `resources/read` will serve: a link this server cannot honour is worse
    /// than no link at all.
    func resourceLinks(for payload: Any, era: MCPEra) -> [[String: Any]] {
        // 2025-03-26 has three content types — text, image, audio — plus the
        // embedded `resource`. `resource_link` arrived in 2025-06-18, and
        // sending one to a 2025-03-26 client is handing it a block its schema
        // cannot describe.
        guard era.supportsResourceLinks, let object = payload as? [String: Any] else { return [] }

        var paths: [String] = []
        for key in MCPServer.audioPathKeys {
            if let path = object[key] as? String { paths.append(path) }
        }
        // The bar-range slice of a render is a file of its own, beside the
        // full-length capture.
        if let slice = object["slice"] as? [String: Any], let path = slice["path"] as? String {
            paths.append(path)
        }

        var seen: Set<String> = []
        return paths.compactMap { path -> [String: Any]? in
            let name = (path as NSString).lastPathComponent
            guard let file = capturesFile(named: name),
                  file.path == URL(fileURLWithPath: path).resolvingSymlinksInPath()
                      .standardizedFileURL.path,
                  seen.insert(file.path).inserted else { return nil }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var link: [String: Any] = [
                "type": "resource_link",
                "uri": capturesURIPrefix + (name.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? name),
                "name": name,
                "mimeType": Captures.mimeType(forPathExtension: file.pathExtension) ?? "audio/mp4",
                "size": size,
                "description": "\(describeBytes(size)) \(file.pathExtension.uppercased())"
                    + " — fetch with resources/read to listen"
                    + (size > capturesReadByteCap ? " (over the read cap; use the .m4a beside it)" : "")
            ]
            link["annotations"] = ["audience": ["assistant", "user"], "priority": 0.6]
            return link
        }
    }

    /// The result keys that can name an audio file this server wrote. Kept in
    /// one place so the census is checkable — `MCPResourceTests` asserts every
    /// tool that attaches audio uses a key from this set.
    static let audioPathKeys = [
        "path", "preview_path", "clip_path",
        "baseline_audio", "after_audio", "baseline_preview", "after_preview"
    ]
}

/// "3.4 MB" / "812 KB" / "97 bytes" — a size a model can judge at a glance,
/// which a raw byte count is not.
func describeBytes(_ bytes: Int) -> String {
    if bytes >= 1_024 * 1_024 {
        return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }
    if bytes >= 1_024 {
        return "\(bytes / 1_024) KB"
    }
    return "\(bytes) bytes"
}
