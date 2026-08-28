import Foundation

/// Thrown by `checkCancelled()` when the client has withdrawn the request that
/// is currently running.
///
/// A plain `Error`, deliberately NOT a `LogicianError`: a cancelled call never
/// produces a JSON-RPC response at all (the spec says the server must not
/// answer a request it abandoned), so it never needs an `error_code` and must
/// never be mistaken for a tool that ran and failed. Throwing rather than
/// returning is what makes the existing `defer`/restore paths run: every tool
/// that parks the transport, arms a track or opens a plugin view already
/// unwinds correctly on a thrown error, and a cancellation is just another
/// thrown error to them.
struct RequestCancelled: LocalizedError {
    var errorDescription: String? { "The client cancelled this request." }
}

/// The one tool call that can be in flight, as the reader thread and the
/// executing thread both see it.
///
/// There is exactly one slot because there is exactly one executor: tool calls
/// run serially on the main thread (see `MCPServer.run()`), so "the current
/// call" is unambiguous. Everything here is behind a lock anyway, because the
/// reader thread writes `cancel` and reads nothing else while the executing
/// thread reads the cancel flag and the progress token.
///
/// This is deliberately not a general async runtime. It is a mailbox with a
/// flag: enough to answer `ping` and `notifications/cancelled` while a
/// four-minute bounce is rendering, and nothing more.
final class CallSession: @unchecked Sendable {
    private let lock = NSLock()

    /// Cancellation is keyed by the request id rendered as a string.
    ///
    /// Loose on purpose: clients disagree about whether `notifications/cancelled`
    /// carries the id in its original JSON type or stringified (the spec's own
    /// example shows `"requestId": "123"` for what was plainly a number), so
    /// integer `3` and string `"3"` deliberately collide here. A client would
    /// have to use both forms as ids in the same session to be hurt by that,
    /// and the alternative — ignoring a cancellation because the type did not
    /// match — is the failure this leniency exists to prevent.
    static func key(for id: Any) -> String {
        if let string = id as? String { return string }
        if let number = id as? NSNumber { return number.stringValue }
        return String(describing: id)
    }

    private var runningKey: String?
    private var progressToken: Any?
    private var lastProgress: Double = 0
    private var lastSentAt: Date = .distantPast

    /// Cancellations that arrived for a call that had not started yet, or has
    /// already finished. Bounded: a client that spams cancellations for ids
    /// that never existed must not grow this process's memory.
    private var cancelled: [String] = []
    private static let cancelledMemory = 64

    /// Where a `notifications/progress` goes. Set once by `MCPServer.run()`;
    /// nil in tests and in any context with no client attached, which is what
    /// makes `reportProgress` a safe no-op everywhere.
    private var emit: (([String: Any]) -> Void)?

    func setEmitter(_ emit: @escaping ([String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.emit = emit
    }

    /// Marks a call as running. `token` is `params._meta.progressToken`, or nil
    /// when the client did not ask for progress.
    func begin(key: String, progressToken token: Any?) {
        lock.lock(); defer { lock.unlock() }
        runningKey = key
        progressToken = token
        lastProgress = 0
        lastSentAt = .distantPast
    }

    /// Ends the running call and reports whether it was cancelled while it ran
    /// (or before it started). The caller uses that answer to decide whether to
    /// write a response at all.
    @discardableResult
    func finish(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasCancelled = cancelled.contains(key)
        cancelled.removeAll { $0 == key }
        runningKey = nil
        progressToken = nil
        return wasCancelled
    }

    /// Records a `notifications/cancelled`. Safe to call for an id that is not
    /// running, has already finished, or never existed - the spec requires
    /// exactly that tolerance, because cancellations race with completion.
    func cancel(key: String) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled.contains(key) else { return }
        cancelled.append(key)
        if cancelled.count > Self.cancelledMemory {
            cancelled.removeFirst(cancelled.count - Self.cancelledMemory)
        }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let runningKey else { return false }
        return cancelled.contains(runningKey)
    }

    func isCancelled(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(key)
    }

    /// Sub-ranges of the 0…100 scale, innermost last.
    ///
    /// This is what makes nesting work. `logic_export_stems` is a loop over
    /// `logic_bounce_range`, and `logic_project_snapshot` contains a whole
    /// `logic_mixer_snapshot`; both inner tools report on the same 0…100 scale
    /// as the outer one, and without a mapping the inner run to 100 would
    /// freeze the outer tool's progress at 100 for the rest of the call. A
    /// scope says "the next 0…100 you hear is really 12.5…25", so the inner
    /// tool needs no idea it is nested.
    private var scopes: [(offset: Double, span: Double)] = []

    func pushProgressScope(from: Double, to: Double) {
        lock.lock(); defer { lock.unlock() }
        let current = scopes.last ?? (offset: 0, span: 100)
        scopes.append((
            offset: current.offset + current.span * (from / 100),
            span: current.span * ((to - from) / 100)
        ))
    }

    func popProgressScope() {
        lock.lock(); defer { lock.unlock() }
        if !scopes.isEmpty { scopes.removeLast() }
    }

    /// Builds the `notifications/progress` for the running call, or nil when
    /// there is nothing to send: no client asked for progress, no call is
    /// running, the step would not advance, or `throttle` has not elapsed.
    ///
    /// The monotonicity rule is the server's to keep ("progress MUST increase
    /// with each notification"), and a non-increasing step is DROPPED rather
    /// than nudged upward: a fabricated number would be a lie about how far
    /// along the work is, and this server does not send those.
    ///
    /// `throttle` is the other half of the spec's advice ("both parties SHOULD
    /// implement rate limiting"). A 100 ms poll loop watching a bounce grow
    /// would otherwise emit six hundred notifications for one bounce; phase
    /// boundaries pass 0 and are never held back.
    func progressNotification(
        percent: Double, message: String, throttle: TimeInterval
    ) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let progressToken, runningKey != nil else { return nil }
        let absolute: Double
        if let scope = scopes.last {
            absolute = scope.offset + scope.span * (min(max(percent, 0), 100) / 100)
        } else {
            absolute = min(max(percent, 0), 100)
        }
        guard absolute > lastProgress else { return nil }
        let now = Date()
        guard throttle <= 0 || now.timeIntervalSince(lastSentAt) >= throttle else { return nil }
        lastProgress = absolute
        lastSentAt = now
        return ["jsonrpc": "2.0", "method": "notifications/progress", "params": [
            "progressToken": progressToken,
            "progress": absolute,
            "total": 100,
            "message": message
        ]]
    }

    func send(_ notification: [String: Any]) {
        lock.lock()
        let emit = self.emit
        lock.unlock()
        emit?(notification)
    }
}

/// The process-wide call session.
///
/// A global for the same reason `MCUController.hotPluginView` is one: the
/// alternative is threading a reporter through 84 tool handlers and every
/// helper they call, to reach a handful of poll loops six frames down. It is
/// `let` on a lock-guarded class rather than `nonisolated(unsafe) var`, so the
/// concurrency checker is satisfied by construction instead of by assertion.
let callSession = CallSession()

/// Emits one `notifications/progress` for the in-flight `tools/call`.
///
/// A no-op unless the client opted in with `params._meta.progressToken`, so
/// call sites never branch: sprinkle it at real phase boundaries and it costs
/// nothing when nobody is listening.
///
/// ONE scale, everywhere: `percent` is 0…100 of this tool's own work, and the
/// notification always carries `total: 100`. A single house scale is what lets
/// tools nest inside each other (see `withProgressScope`) and makes the
/// monotonicity rule something a call site can satisfy by reading its own
/// numbers, rather than by knowing what every other phase chose.
///
/// Pass `throttle` from inside a poll loop to cap how often it may speak (the
/// long file-size polls use 1 s); leave it at 0 for a phase boundary, which
/// must never be swallowed.
func reportProgress(_ message: String, percent: Double, throttle: TimeInterval = 0) {
    guard let notification = callSession.progressNotification(
        percent: percent, message: message, throttle: throttle
    ) else { return }
    callSession.send(notification)
}

/// Runs `body` with its 0…100 progress mapped into `range` of the caller's own
/// 0…100 — the whole of how a tool that calls another tool keeps one honest,
/// monotonic progress line.
func withProgressScope<T>(_ range: ClosedRange<Double>, _ body: () throws -> T) rethrows -> T {
    callSession.pushProgressScope(from: range.lowerBound, to: range.upperBound)
    defer { callSession.popProgressScope() }
    return try body()
}

/// Throws `RequestCancelled` if the client withdrew the running request.
///
/// Belongs at the top of every poll/settle iteration in the long tools. It is
/// cheap (one lock, one set lookup) relative to the millisecond sleeps those
/// loops already do, and it is the ONLY cancellation mechanism: nothing is
/// killed from the outside, so a tool always unwinds through its own restore
/// path.
func checkCancelled() throws {
    if callSession.isCancelled { throw RequestCancelled() }
}
