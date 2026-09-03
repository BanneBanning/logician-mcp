import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// MARK: - Supported protocol range

/// The MODERN revisions: no handshake at all. Every request carries its own
/// protocol version and the client's capabilities in `params._meta`, every
/// result carries `resultType` and the server's identity, and `server/discover`
/// replaces `initialize` as the way a client learns what this server is.
let modernProtocolVersions = ["2026-07-28"]

/// The LEGACY revisions: the version is fixed once, by an `initialize`
/// handshake, and holds for the process.
///
/// `2024-11-05` is deliberately ABSENT, and its removal is a bug fix rather
/// than a policy change. This server unconditionally emits `audio` content
/// blocks and tool `annotations`, and neither existed before `2025-03-26`; a
/// client that asked for `2024-11-05` was told "yes" and then handed messages
/// its schema cannot describe. Refusing the version is honest, and it costs
/// nothing real: every client that offers `2024-11-05` also offers something
/// newer, and one that truly cannot will now get a version it can parse
/// instead of a promise this server was never able to keep.
///
/// `2025-03-26` is the floor for the same reason it is the floor: audio blocks,
/// tool annotations and JSON-RPC batching all arrive in that revision, so it is
/// the oldest one whose schema covers everything this server puts on the wire.
let legacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

/// Everything this server will speak, newest first — the list `server/discover`
/// advertises and the one an `UnsupportedProtocolVersionError` offers back.
let supportedProtocolVersions = modernProtocolVersions + legacyProtocolVersions

/// How long a client may cache `tools/list` and `server/discover`. The tool
/// surface is baked into the binary and cannot change while the process lives,
/// so the only thing that can invalidate it is a new build — an hour is
/// conservative for something that is, in practice, immutable.
let toolListCacheTTLMs = 3_600_000

/// `UnsupportedProtocolVersionError`, from the range the 2026-07-28 spec
/// reserves for itself (`-32020`…`-32099`).
let unsupportedProtocolVersionCode = -32022

/// Which wire dialect one request is served in.
///
/// The era is a property of the REQUEST, not of the connection: a dual-era
/// server picks it from how the client opens, and on stdio both kinds of client
/// can, in principle, arrive at the same process. `_meta` says modern;
/// `initialize` says legacy; nothing at all means legacy, because a client that
/// sends neither is a pre-2026 client that skipped its handshake.
enum MCPEra {
    case modern(String)
    case legacy(String)

    var version: String {
        switch self {
        case .modern(let version), .legacy(let version): return version
        }
    }

    var isModern: Bool {
        if case .modern = self { return true }
        return false
    }

    /// Revision ids are ISO dates, so lexical order IS chronological order and
    /// a feature that "arrived in X" is a string comparison against X. This is
    /// only sound because every id in `supportedProtocolVersions` has the same
    /// `YYYY-MM-DD` shape; nothing in MCP has ever had another.
    func isAtLeast(_ revision: String) -> Bool { version >= revision }

    /// `resource_link` content blocks. 2025-03-26 has exactly four content
    /// types in a tool result — text, image, audio and the embedded `resource`
    /// — and no link among them, so a link sent to one is a block its schema
    /// cannot describe. Added in 2025-06-18.
    var supportsResourceLinks: Bool { isAtLeast("2025-06-18") }

    /// `title` and `annotations` on a `Resource`. Both arrive in 2025-06-18;
    /// the 2025-03-26 `Resource` is uri/name/description/mimeType/size and
    /// nothing else. The `resources` capability itself is older than either and
    /// is declared on every revision this server speaks.
    var supportsResourceTitles: Bool { isAtLeast("2025-06-18") }
}

/// A JSON-RPC error worked out before the method ever runs: a bad id, a bad
/// envelope, an unsupported protocol version.
/// `@unchecked Sendable` for the same reason every JSON payload in this server
/// is: `data` is a decoded JSON value, which has no Swift type better than
/// `Any`, and it is built once and never mutated.
struct JSONRPCFault: Error, @unchecked Sendable {
    let code: Int
    let message: String
    var data: [String: Any]?
}

/// The three things the `id` member can be.
enum RequestID {
    /// No `id` member: a notification, which must never be answered.
    case absent
    /// A string or an integer — the only two forms MCP allows.
    case valid(Any)
    /// Present but illegal. This is NOT a notification: JSON-RPC wants an
    /// `Invalid Request` back, with a null id because no usable one was read.
    case invalid(String)

    /// The distinction that used to be missed: a JSON `null` decodes to
    /// `NSNull`, which is not Swift `nil`, so `request["id"] == nil` was false
    /// for `{"id": null}` and the server dutifully ANSWERED it — with
    /// `"id": null`, the exact reply the notification guard exists to prevent.
    static func classify(_ raw: Any?) -> RequestID {
        guard let raw else { return .absent }
        if raw is NSNull {
            return .invalid(
                "`id` must not be null. MCP narrows JSON-RPC here: a null id is neither a "
                    + "request (which needs a string or integer id) nor a notification (which "
                    + "must omit the member entirely). Nothing was executed."
            )
        }
        if let string = raw as? String { return .valid(string) }
        if let number = raw as? NSNumber {
            // JSON `true`/`false` also decode to NSNumber. A boolean is not an
            // integer, and echoing one back as an id would be a third thing
            // again.
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .invalid("`id` must be a string or an integer, not a boolean. Nothing was executed.")
            }
            let value = number.doubleValue
            guard value.rounded() == value, value.magnitude <= 9_007_199_254_740_992 else {
                return .invalid(
                    "`id` must be a string or an INTEGER; \(number) is not one. A fractional id "
                        + "cannot be echoed back unchanged — it would come back through a binary "
                        + "double as a different number, and the client would never match the "
                        + "response to its request. Nothing was executed."
                )
            }
            return .valid(number)
        }
        return .invalid(
            "`id` must be a string or an integer, not a \(type(of: raw)). Nothing was executed."
        )
    }
}

// MARK: - The server

/// `@unchecked Sendable` because two threads touch it by design: a reader
/// thread owns stdin and answers the cheap protocol methods, while tool calls
/// run on the main thread (see `run()`). The only mutable state is the
/// negotiated legacy version and the output handle, and both are behind locks.
final class MCPServer: @unchecked Sendable {
    let logic = LogicAccessibility()

    private let stateLock = NSLock()
    private let outputLock = NSLock()
    private let jobs = JobQueue()

    private var storedLegacyVersion: String?

    /// The legacy revision an `initialize` settled on, once — and it IS stored
    /// now. It used to be a local that the response echoed and then dropped, so
    /// the server had no idea afterwards which revision it had promised, and
    /// nothing downstream could vary by it.
    var negotiatedLegacyVersion: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedLegacyVersion }
        set { stateLock.lock(); defer { stateLock.unlock() }; storedLegacyVersion = newValue }
    }

    // MARK: Lifecycle

    /// Reading and executing are split across two threads, and which one gets
    /// which is deliberate.
    ///
    /// The MAIN thread runs tool calls, because that is the thread every tool
    /// has always run on: they drive the Accessibility API and AppKit, and
    /// moving every handler to a worker to satisfy a protocol requirement would
    /// be trading a real risk for a cosmetic one. A background thread owns
    /// stdin instead, and answers everything that touches no Logic state —
    /// `ping`, `tools/list`, `initialize`, `server/discover`,
    /// `notifications/cancelled` — inline, while a four-minute bounce is still
    /// rendering on the main thread. That is the whole point: before this, a
    /// long tool blocked the read loop, so a client could neither ping nor
    /// cancel until the tool it wanted to cancel had finished.
    ///
    /// One tool at a time, by construction: there is one executor, and it is a
    /// FIFO. That is not a limitation to fix later — Logic has one transport,
    /// one selected track and one control surface, and two tools driving them
    /// at once would produce results neither one could honestly report.
    func run() {
        log("starting \(serverName) \(serverVersion); MCP \(supportedProtocolVersions.joined(separator: ", "))")
        callSession.setEmitter { [weak self] notification in self?.write(notification) }

        let reader = Thread { [self] in
            readLoop()
            jobs.close()
        }
        reader.name = "logician.stdin"
        reader.stackSize = 4 << 20
        reader.start()

        while let job = jobs.next() { job() }
        shutdown()
    }

    private func readLoop() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let message: Any
            do {
                message = try JSONSerialization.jsonObject(with: Data(line.utf8))
            } catch {
                write(jsonRPCError(id: NSNull(), code: -32700, message: error.localizedDescription))
                continue
            }
            dispatch(message)
        }
    }

    private func shutdown() {
        // The Region inspector's disclosure triangles are the surface debt's
        // Accessibility-plane cousin: the region tools leave open what they
        // opened, so a chain of region calls does not spend ~0.6 s per call
        // re-opening a panel it is about to close again. This is where that
        // debt is paid. Self-guarding — no debt, no walk, and the close looks
        // at each triangle before pressing it (see `InspectorDebt`).
        if logic.settleInspectorDebt() {
            log("stdin closed; the Region inspector's disclosures were closed again")
        }

        // stdin closed: the client is gone. Leave the control surface in the
        // neutral Pan view — a leaked hot plugin/instrument view otherwise
        // makes Logic auto-open plugin windows on every later track selection.
        //
        // Guarded, because it used to run unconditionally: a session that only
        // listed tools, or that never got past `initialize`, still reached in
        // and moved the user's real control surface on the way out. A process
        // that never touched the surface has nothing to restore and now says
        // so instead.
        guard MCUBridge.didTouchSurface else {
            log("stdin closed; the control surface was never touched, so nothing was restored")
            return
        }
        MCUController.exitToPan()
        log("stdin closed; surface returned to Pan view")
    }

    // MARK: Dispatch

    /// A `tools/call` that will actually execute — the only message that has to
    /// leave the reader thread.
    private func isExecutableToolCall(_ request: [String: Any]) -> Bool {
        guard request["method"] as? String == "tools/call" else { return false }
        if case .valid = RequestID.classify(request["id"]) { return true }
        return false
    }

    private func dispatch(_ message: Any) {
        if let request = message as? [String: Any] {
            if isExecutableToolCall(request) {
                submitToolCall(request)
            } else {
                respond { try self.handle(request) }
            }
        } else if let batch = message as? [Any] {
            // A JSON-RPC batch. Batching is NOT something every revision has:
            // `2024-11-05` had no batch type at all, `2025-03-26` added one,
            // `2025-06-18` removed it again, and nothing since has brought it
            // back. So an array on the wire means exactly one thing — a
            // `2025-03-26` client — and it is still accepted, because rejecting
            // it would strand the one revision that is allowed to send it.
            // (The comment that used to sit here had this backwards, crediting
            // `2024-11-05` with batching it never had.)
            if batch.contains(where: { ($0 as? [String: Any]).map(isExecutableToolCall) ?? false }) {
                // Keep the whole batch on the executor rather than splitting
                // it: the response has to go out as one array, and any member
                // of it may touch Logic.
                jobs.submit { [self] in runBatch(batch) }
            } else {
                runBatch(batch)
            }
        } else {
            write(jsonRPCError(
                id: NSNull(), code: -32600,
                message: "Invalid Request: a JSON-RPC message must be an object, or an array of them"
            ))
        }
    }

    private func runBatch(_ batch: [Any]) {
        if let output = handleBatch(batch) { writeJSON(output) }
    }

    private func respond(_ produce: () throws -> [String: Any]?) {
        do {
            if let response = try produce() { write(response) }
        } catch {
            write(jsonRPCError(id: NSNull(), code: -32603, message: error.localizedDescription))
        }
    }

    /// Hands one `tools/call` to the main thread, and decides afterwards
    /// whether it may be answered at all.
    private func submitToolCall(_ request: [String: Any]) {
        guard case .valid(let id) = RequestID.classify(request["id"]) else { return }
        let key = CallSession.key(for: id)
        let token = ((request["params"] as? [String: Any])?["_meta"] as? [String: Any])?["progressToken"]

        jobs.submit { [self] in
            // A cancellation can win the race to the queue. Then the tool never
            // runs, and — like a tool cancelled halfway — it is never answered.
            if callSession.isCancelled(key: key) {
                callSession.finish(key: key)
                log("request \(key) was cancelled before it started; not executed, not answered")
                return
            }
            callSession.begin(key: key, progressToken: token)
            var response: [String: Any]?
            do {
                response = try handle(request)
            } catch is RequestCancelled {
                response = nil
            } catch {
                response = jsonRPCError(id: id, code: -32603, message: error.localizedDescription)
            }
            // Asked AFTER the call, not before: a cancellation that lands while
            // the tool is unwinding still suppresses the response. "Not send a
            // response for the cancelled request" is the spec's wording, and a
            // client that has moved on must not be handed a stale result for
            // work it withdrew.
            guard !callSession.finish(key: key) else {
                log("request \(key) was cancelled; abandoned without a response, per the spec")
                return
            }
            if let response { write(response) }
        }
    }

    // MARK: Era resolution

    /// Reads the era out of one request, or the error that must be returned
    /// instead of serving it.
    func era(for request: [String: Any], method: String) -> Result<MCPEra, JSONRPCFault> {
        let meta = (request["params"] as? [String: Any])?["_meta"] as? [String: Any]
        guard let declared = meta?["io.modelcontextprotocol/protocolVersion"] as? String else {
            // No per-request version: a legacy client, whether it handshook or
            // not. Note that `_meta` alone does NOT mean modern — the
            // `progressToken` key has lived there since 2025-03-26.
            return .success(.legacy(negotiatedLegacyVersion ?? protocolVersion))
        }
        guard supportedProtocolVersions.contains(declared) else {
            return .failure(JSONRPCFault(
                code: unsupportedProtocolVersionCode,
                message: "Unsupported protocol version: \(declared)",
                data: ["supported": supportedProtocolVersions, "requested": declared]
            ))
        }
        guard modernProtocolVersions.contains(declared) else {
            // A legacy revision announced through the modern slot. Serve it in
            // the dialect it named, not the one it used to ask.
            return .success(.legacy(declared))
        }
        // `clientCapabilities` is required on every modern request, and a
        // request missing a required `_meta` field is malformed (-32602).
        //
        // Enforced everywhere EXCEPT the two methods a client uses to work out
        // what it is talking to. Failing `server/discover` over a missing
        // capabilities map would be self-defeating: the spec's own stdio
        // fallback rule reads any non-modern error from the probe as "this is a
        // legacy server", so being strict there would talk a modern client OUT
        // of the modern path over a field discovery does not need.
        if method != "server/discover" && method != "initialize",
           meta?["io.modelcontextprotocol/clientCapabilities"] == nil {
            return .failure(JSONRPCFault(
                code: -32602,
                message: "Missing required _meta field 'io.modelcontextprotocol/clientCapabilities'. "
                    + "Protocol \(declared) requires it on every request, because there is no "
                    + "handshake left to carry it. Nothing was executed."
            ))
        }
        return .success(.modern(declared))
    }

    // MARK: The method table

    func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let method = request["method"] as? String ?? ""

        // A notification (no id) must NEVER get a response - answering one,
        // even with an error, is invalid JSON-RPC and strict clients
        // (Antigravity's Go MCP layer) close the connection over it.
        //
        // Checked BEFORE the switch, not inside `default:` where it used to
        // live: an id-less `tools/call`, `tools/list` or `ping` matched a
        // case, never reached the guard, and was answered with `"id": null` -
        // exactly the reply the guard exists to prevent.
        let id: Any
        switch RequestID.classify(request["id"]) {
        case .absent:
            handleNotification(method: method, request: request)
            return nil
        case .invalid(let reason):
            // Null and fractional ids land here. There is no id to echo, so the
            // response carries the JSON-RPC null.
            return jsonRPCError(id: NSNull(), code: -32600, message: "Invalid Request: \(reason)")
        case .valid(let value):
            id = value
        }

        // The envelope itself. A member that is missing or is not exactly
        // "2.0" is not a JSON-RPC 2.0 message, and guessing at what a sender
        // who cannot spell the version meant is how a wrong reply gets built
        // on a wrong assumption.
        guard let version = request["jsonrpc"] as? String, version == "2.0" else {
            let found = request["jsonrpc"].map { "\($0)" } ?? "no `jsonrpc` member at all"
            return jsonRPCError(
                id: id, code: -32600,
                message: "Invalid Request: every message must carry `\"jsonrpc\": \"2.0\"`; found \(found). "
                    + "Nothing was executed."
            )
        }

        let era: MCPEra
        switch self.era(for: request, method: method) {
        case .failure(let fault):
            return jsonRPCError(id: id, code: fault.code, message: fault.message, data: fault.data)
        case .success(let resolved):
            era = resolved
        }

        switch method {
        case "server/discover":
            // Mandatory in 2026-07-28, and the whole handshake for a modern
            // client: supported versions, capabilities, identity and
            // instructions in one call, with no state left behind on either
            // side. Always answered in the modern dialect — the method does not
            // exist in any other one.
            return response(id: id, result: discoverResult(), era: .modern(modernProtocolVersions[0]))

        case "initialize":
            return response(id: id, result: initializeResult(request), era: era)

        case "notifications/initialized", "initialized":
            return nil

        case "ping":
            // Removed in 2026-07-28 along with the rest of the session
            // machinery, and still answered here in both eras. It is a
            // stateless no-op that costs one line; refusing a client's
            // keepalive to make a point about a revision it may not have read
            // would break sessions and prove nothing.
            return response(id: id, result: [:], era: era)

        case "tools/list":
            let params = request["params"] as? [String: Any] ?? [:]
            // This server does not paginate: `tools/list` returns the whole
            // registry and no `nextCursor`, so there is no cursor it could have issued
            // and every cursor is by definition unrecognized. The spec's answer
            // for an unrecognized cursor is -32602, and saying so is far better
            // than silently returning page one again to a client that believes
            // it is paging forward.
            if let cursor = params["cursor"], !(cursor is NSNull) {
                return jsonRPCError(
                    id: id, code: -32602,
                    message: "Unknown cursor: \(cursor). This server does not paginate tools/list — "
                        + "it returns every tool in one page and never issues a nextCursor, so no "
                        + "cursor value is valid. Call tools/list with no cursor."
                )
            }
            var result: [String: Any] = ["tools": toolDefinitions()]
            if era.isModern {
                // CacheableResult. The list is compiled into the binary, so
                // "public" is honest: it is identical for every client and
                // holds nothing about this user or project.
                result["ttlMs"] = toolListCacheTTLMs
                result["cacheScope"] = "public"
            }
            return response(id: id, result: result, era: era)

        case "resources/list":
            // Same no-pagination stance as `tools/list`, for a different
            // reason: this list is CAPPED rather than complete. It names the
            // guide plus the `capturesListLimit` most recent captures and never
            // issues a `nextCursor`, so no cursor can be one it handed out, and
            // an older capture is reached by naming it — `resources/read` takes
            // any filename in the directory, listed or not.
            if let cursor = (request["params"] as? [String: Any])?["cursor"], !(cursor is NSNull) {
                return jsonRPCError(
                    id: id, code: -32602,
                    message: "Unknown cursor: \(cursor). This server does not paginate "
                        + "resources/list — it returns the agent guide plus the \(capturesListLimit) "
                        + "most recent captures in one page and never issues a nextCursor. Call "
                        + "resources/list with no cursor; an older capture can still be read "
                        + "directly at \(capturesURIPrefix)<filename>."
                )
            }
            var result: [String: Any] = ["resources": resourceList(era: era)]
            if era.isModern {
                // Short, and deliberately not the hour `tools/list` gets: the
                // captures family gains a file every time this session renders
                // one. "private" because it is a listing of THIS user's audio.
                result["ttlMs"] = resourceListCacheTTLMs
                result["cacheScope"] = "private"
            }
            return response(id: id, result: result, era: era)

        case "resources/templates/list":
            // Answered with an empty list rather than -32601. A server that
            // declares `resources` and then reports "method not found" for the
            // sibling discovery call reads as broken to a client walking the
            // capability; "there are no templates" is both true and quiet.
            return response(id: id, result: ["resourceTemplates": []], era: era)

        case "resources/read":
            let params = request["params"] as? [String: Any] ?? [:]
            guard let uri = params["uri"] as? String, !uri.isEmpty else {
                return jsonRPCError(
                    id: id, code: -32602,
                    message: "resources/read requires a non-empty string `uri`. Nothing was read."
                )
            }
            switch resourceContents(uri: uri, era: era) {
            case .failure(let fault):
                return jsonRPCError(id: id, code: fault.code, message: fault.message, data: fault.data)
            case .success(let contents):
                var result: [String: Any] = ["contents": contents]
                if era.isModern {
                    // The guide is immutable for the life of the binary; a
                    // capture is a file on the user's disk that a re-render can
                    // replace under the same name.
                    let isGuide = uri == guideResourceURI
                    result["ttlMs"] = isGuide ? toolListCacheTTLMs : resourceListCacheTTLMs
                    result["cacheScope"] = isGuide ? "public" : "private"
                }
                return response(id: id, result: result, era: era)
            }

        case "tools/call":
            // Deliberately served whether or not `initialize` came first. The
            // legacy lifecycle asks the CLIENT not to send requests before the
            // handshake, but it puts no matching duty on the server, and real
            // clients skip it — so does every `echo ... | logician` smoke test
            // in this repo. The 2026-07-28 spec bakes that reality in: it
            // warns clients that some servers "do not validate that a request
            // arrives after initialize" and tells them to probe with
            // `server/discover` if they need a deterministic answer, which
            // this server gives them. Refusing here would break working
            // clients to enforce a rule aimed at someone else. (In particular
            // NOT -32002: 2026-07-28 retired that code, and implementations of
            // this revision must not emit it.)
            if !era.isModern && negotiatedLegacyVersion == nil {
                log("tools/call before initialize; serving it anyway under \(era.version)")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            // An unknown NAME is an invalid `params.name`, not a tool that ran
            // and failed. MCP reserves `isError` for EXECUTION failures, so
            // returning one told a strict client "the call succeeded, the tool
            // reported a problem" - the wrong half of the protocol.
            if let unknown = unknownToolMessage(name: toolName) {
                return jsonRPCError(id: id, code: -32602, message: unknown)
            }
            return response(
                id: id,
                result: callTool(name: toolName, arguments: arguments, era: era),
                era: era
            )

        default:
            // Real notifications already returned above. An unknown
            // `notifications/*` that carries an id anyway is still a
            // notification by name, and gets no "method not found" either.
            if method.hasPrefix("notifications/") { return nil }
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Everything that arrives without an id. Nothing here may produce output.
    private func handleNotification(method: String, request: [String: Any]) {
        switch method {
        case "notifications/cancelled":
            guard let raw = (request["params"] as? [String: Any])?["requestId"], !(raw is NSNull) else {
                log("notifications/cancelled carried no requestId; ignored")
                return
            }
            let key = CallSession.key(for: raw)
            callSession.cancel(key: key)
            let reason = (request["params"] as? [String: Any])?["reason"] as? String
            log("cancelling request \(key)" + (reason.map { ": \($0)" } ?? ""))

        case "notifications/initialized", "initialized":
            break

        default:
            // A REQUEST method arriving without an id is a client bug, and it is
            // deliberately NOT dispatched: performing a Logic write whose result
            // could never be reported back is worse than dropping the message.
            // The drop is logged so it is diagnosable rather than silent.
            if !method.hasPrefix("notifications/") {
                log("dropped '\(method)' sent without an id: a notification gets no response, so its result could never reach the caller")
            }
        }
    }

    // MARK: Handshake payloads

    /// What this server can do, in the one shape every supported revision
    /// spells the same way.
    ///
    /// `resources` is declared to BOTH eras because resources are older than
    /// both: `resources/list` and `resources/read` have been in the spec since
    /// 2025-03-26, unchanged in shape, and only the caching hints on the result
    /// and the `title`/`annotations` on a `Resource` are newer. Neither
    /// `listChanged` nor `subscribe` is claimed: the captures directory does
    /// gain files while a session renders, but this server has no watcher and
    /// promising notifications it will never send is worse than a client
    /// re-listing.
    ///
    /// (Computed rather than stored: a `[String: Any]` is not `Sendable`, and a
    /// static one is a shared mutable global as far as Swift 6 is concerned.
    /// It is three literals — rebuilding it per handshake costs nothing.)
    static var serverCapabilities: [String: Any] {
        [
            "tools": ["listChanged": false],
            "resources": ["listChanged": false]
        ]
    }

    /// The 2026-07-28 `DiscoverResult`.
    func discoverResult() -> [String: Any] {
        [
            "supportedVersions": supportedProtocolVersions,
            "capabilities": MCPServer.serverCapabilities,
            "instructions": MCPServer.instructions,
            "ttlMs": toolListCacheTTLMs,
            "cacheScope": "public"
        ]
    }

    /// The legacy `InitializeResult`, and the place the negotiated revision is
    /// recorded for the rest of the process.
    func initializeResult(_ request: [String: Any]) -> [String: Any] {
        // Echo the client's protocol version when we know it - strict
        // clients disconnect on a version they did not offer.
        let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
        let negotiated = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? protocolVersion
        if let previous = negotiatedLegacyVersion {
            // A second `initialize` is a client bug, not a protocol violation
            // worth hanging up over. Re-negotiating is idempotent here (the
            // result depends on nothing but the request), so it is answered
            // again and simply noted.
            log("initialize called again (was \(previous), now \(negotiated))")
        }
        negotiatedLegacyVersion = negotiated
        return [
            "protocolVersion": negotiated,
            "capabilities": MCPServer.serverCapabilities,
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": MCPServer.instructions
        ]
    }


    // MARK: Result shapes

    /// The `CallToolResult` wire shape.
    ///
    /// `includeAudio: false` is the `include_audio` opt-out: the audio keys
    /// are still stripped from the text payload (they are transport, never
    /// content), but no audio block is attached and the note that promised
    /// one is rewritten - a result that says "this CARRIES the audio" while
    /// carrying nothing is exactly the dishonesty this server refuses.
    ///
    /// The `resource_link` blocks are NOT part of that opt-out, and that is the
    /// point of them. Inline audio is unchanged: a multimodal client hears
    /// exactly what it heard before. A client that cannot take a few hundred KB
    /// of base64 turns it off and STILL gets the link, so it can fetch the
    /// render through `resources/read` when it decides it wants to. Era-gated,
    /// because `resource_link` does not exist before 2025-06-18.
    func toolResult(
        payload: Any, isError: Bool, includeAudio: Bool = true,
        era: MCPEra = .legacy(protocolVersion)
    ) -> [String: Any] {
        // A payload carrying "_audio" {data, mimeType} becomes an MCP audio
        // content block so multimodal clients can LISTEN instead of being
        // tempted to read raw audio files into their context.
        var textPayload = payload
        var audioBlocks: [[String: Any]] = []
        if var object = payload as? [String: Any] {
            // Whether this payload was an AUDIO-CARRYING one, decided BEFORE
            // the keys are lifted out and independently of `includeAudio`: a
            // result whose blocks were suppressed still sends the agent to the
            // file paths, so it still owes the same epistemic warning.
            // A producer that SKIPPED the encode because `include_audio` was
            // already false says so with this key rather than by going quiet:
            // the result still owes the omission note and the epistemics line
            // it would have owed had the blocks been built and dropped here.
            let suppressed = (object["_audio_suppressed"] as? Bool) == true
            object.removeValue(forKey: "_audio_suppressed")
            let carriedAudio = object["_audio"] != nil || object["_audio_list"] != nil || suppressed
            if let audio = object["_audio"] as? [String: String],
               let data = audio["data"], let mime = audio["mimeType"] {
                audioBlocks.append(["type": "audio", "data": data, "mimeType": mime])
                object.removeValue(forKey: "_audio")
            }
            if let list = object["_audio_list"] as? [[String: String]] {
                for audio in list {
                    guard let data = audio["data"], let mime = audio["mimeType"] else { continue }
                    audioBlocks.append(["type": "audio", "data": data, "mimeType": mime])
                }
                object.removeValue(forKey: "_audio_list")
            }
            if !includeAudio && (!audioBlocks.isEmpty || suppressed) {
                audioBlocks = []
                // Correct the standing promise in place: the value of the note
                // that would otherwise tell the agent to listen to blocks that
                // are not there. (A producer that skipped the encode outright
                // never wrote that note, so for it the key is written here
                // instead of rewritten - same result, one fewer transcode.)
                let omitted = "Audio blocks were OMITTED because you passed include_audio: false. Nothing was heard. To listen, open the audio paths in this result (preview_path / clip_path / baseline_audio / after_audio) with your client's file viewer, or call again with include_audio: true. NEVER read audio files as text/bash."
                if object["listen_note"] != nil || suppressed {
                    // `suppressed` gets the same key the attached-then-dropped
                    // path gets: the producer skipped writing `listen_note`
                    // precisely because it had no blocks to point at.
                    object["listen_note"] = omitted
                } else if object["note"] != nil {
                    object["note"] = omitted
                }
            }
            // The epistemics line, after the omission rewrite so it survives
            // it. Attached to whichever note the agent is already going to
            // read; a result that carries audio and no note at all gets one.
            if carriedAudio {
                if let existing = object["listen_note"] as? String {
                    object["listen_note"] = existing + Tool.epistemicsNote
                } else if let existing = object["note"] as? String {
                    object["note"] = existing + Tool.epistemicsNote
                } else {
                    object["listen_note"] = Tool.epistemicsNote
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            textPayload = object
        }
        let text: String
        if JSONSerialization.isValidJSONObject(textPayload),
           let data = try? JSONSerialization.data(withJSONObject: textPayload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = String(describing: textPayload)
        }

        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: audioBlocks)
        // Built from the TEXT payload, which is the one that still holds the
        // paths: `_audio` was already lifted out of it above, and the paths are
        // what a link points at.
        content.append(contentsOf: resourceLinks(for: textPayload, era: era))
        // NO `structuredContent`. It used to carry a second copy of the same
        // dictionary the text block already holds, which doubled the tokens of
        // every call in any client that renders both - and it was unvalidated:
        // the spec pairs structured content with an `outputSchema`, and these
        // 57 results are heterogeneous, branch-dependent dictionaries (an
        // optional `warning`, an optional `slice`, `metrics` only when the
        // file could be measured, a completely different error shape) that no
        // honest schema describes. A permissive `{"type": "object"}` would
        // validate nothing while keeping the duplicate; a specific one would
        // eventually reject a truthful result, which is the worst outcome this
        // server can produce. The serialized-JSON text block is what the spec
        // prescribes without an output schema, and it is also the ONLY form
        // the 2025-03-26 clients this server negotiates down to understand -
        // structured content did not exist before 2025-06-18.
        return [
            "content": content,
            "isError": isError
        ]
    }

    /// Wraps a result in whatever the negotiated era requires of it.
    ///
    /// 2026-07-28 makes two additions mandatory on every result: `resultType`,
    /// which tells the client whether this is the final answer or a
    /// round-trip request for more input (always the former here — this server
    /// asks the client for nothing), and the server's identity in `_meta`,
    /// which replaces the `serverInfo` a handshake used to carry. Neither is
    /// emitted to a legacy client, which has no schema for them.
    func response(id: Any, result: [String: Any], era: MCPEra = .legacy(protocolVersion)) -> [String: Any] {
        var result = result
        if era.isModern {
            result["resultType"] = "complete"
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta["io.modelcontextprotocol/serverInfo"] = ["name": serverName, "version": serverVersion]
            result["_meta"] = meta
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    func jsonRPCError(id: Any, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }

    /// One JSON-RPC batch. Every member is processed in order, and only the
    /// members that carry an id produce a response.
    ///
    /// Returns the object or array to write, or nil for "write NOTHING" - the
    /// required answer when every member was a notification, and the same rule
    /// that keeps a strict client from closing the connection over a reply it
    /// never asked for.
    func handleBatch(_ members: [Any]) -> Any? {
        guard !members.isEmpty else {
            // A single error OBJECT, not an array holding one. JSON-RPC is
            // explicit: an empty batch is not a batch, it is one Invalid
            // Request, and the reply is the bare error. An array here made
            // clients look for a member to correlate and find none.
            return jsonRPCError(
                id: NSNull(), code: -32600, message: "Invalid Request: the batch is empty"
            )
        }
        var responses: [[String: Any]] = []
        for member in members {
            guard let request = member as? [String: Any] else {
                responses.append(jsonRPCError(
                    id: NSNull(), code: -32600,
                    message: "Invalid Request: every member of a batch must be a JSON object"
                ))
                continue
            }
            do {
                if let response = try handle(request) {
                    responses.append(response)
                }
            } catch {
                // One bad member must not lose the rest of the batch.
                let id: Any
                if case .valid(let value) = RequestID.classify(request["id"]) { id = value } else { id = NSNull() }
                responses.append(jsonRPCError(
                    id: id, code: -32603, message: error.localizedDescription
                ))
            }
        }
        return responses.isEmpty ? nil : responses
    }

    // MARK: Output

    func write(_ object: [String: Any]) {
        writeJSON(object)
    }

    /// Writes one newline-delimited JSON message: an object for a single
    /// response, an array for a batch.
    ///
    /// Locked, because two threads write here now: the reader thread answers
    /// `ping` and `tools/list` while the main thread is emitting progress
    /// notifications out of a running tool. Interleaved bytes would be a
    /// corrupt stream, and stdout is the only channel there is.
    func writeJSON(_ message: Any) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            log("failed to serialize response")
            return
        }
        line.append("\n")
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func log(_ message: String) {
        let line = "[\(serverName)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// The reader thread's hand-off to the executor.
///
/// A FIFO with a condition variable and nothing else. `next()` blocks until
/// there is work or stdin has closed, which is what lets the main thread be the
/// executor without spinning.
final class JobQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var closed = false

    func submit(_ job: @escaping () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        jobs.append(job)
        condition.signal()
    }

    /// nil once stdin has closed AND everything queued before it closed has
    /// been handed out — a tool call that arrived on the last line still runs.
    func next() -> (() -> Void)? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && !closed { condition.wait() }
        return jobs.isEmpty ? nil : jobs.removeFirst()
    }

    func close() {
        condition.lock()
        defer { condition.unlock() }
        closed = true
        condition.broadcast()
    }
}
