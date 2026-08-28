import Foundation
import XCTest
@testable import Logician

/// Progress reporting and cancellation, which are pure protocol machinery and
/// therefore testable without Logic Pro: what a client has to send to be told
/// anything, what shape the notification takes, and the two rules the spec puts
/// on the server — progress only ever increases, and a cancelled request is
/// never answered.
///
/// The long tools these serve (bounces, renders, snapshots, recordings) cannot
/// run headless, so the loops themselves are exercised by a stand-in that does
/// what they do: report at its phase boundaries and call `checkCancelled()`
/// where it would otherwise sleep.
final class MCPProgressTests: XCTestCase {

    /// The call session is process-wide (one executor, one call at a time), so
    /// each test claims it, drains it and hands it back.
    private func withCall<T>(
        id: Any, progressToken: Any?, _ body: ([[String: Any]]) throws -> T
    ) rethrows -> T {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: CallSession.key(for: id), progressToken: progressToken)
        defer { callSession.finish(key: CallSession.key(for: id)) }
        let value = try body(sink.notifications)
        return value
    }

    /// Collects on whatever thread emits; the emitter is called from the tool's
    /// thread, which in production is the main one and here is this one.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String: Any]] = []
        var notifications: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ notification: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            storage.append(notification)
        }
    }

    private func params(_ notification: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(notification["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(notification["method"] as? String, "notifications/progress")
        XCTAssertNil(notification["id"], "a notification must never carry an id")
        return try XCTUnwrap(notification["params"] as? [String: Any])
    }

    // MARK: - Opting in

    /// No `progressToken`, no notifications. This is what makes
    /// `reportProgress` safe to sprinkle through the long tools: the call sites
    /// never branch, and a client that did not ask hears nothing.
    func testNothingIsEmittedWithoutAProgressToken() {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: nil)
        reportProgress("halfway", percent: 50)
        callSession.finish(key: "1")
        XCTAssertTrue(sink.notifications.isEmpty)
    }

    /// And nothing is emitted outside a call at all, which is why every unit
    /// test in this suite can call a tool helper without spraying the wire.
    func testNothingIsEmittedWhenNoCallIsRunning() {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.finish(key: "not-running")
        reportProgress("orphan", percent: 10)
        XCTAssertTrue(sink.notifications.isEmpty)
    }

    func testTheNotificationCarriesTheTokenProgressTotalAndMessage() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "abc123")
        reportProgress("reticulating splines", percent: 42)
        callSession.finish(key: "1")

        XCTAssertEqual(sink.notifications.count, 1)
        let params = try params(try XCTUnwrap(sink.notifications.first))
        XCTAssertEqual(params["progressToken"] as? String, "abc123")
        XCTAssertEqual(params["progress"] as? Double, 42)
        XCTAssertEqual(params["total"] as? Int, 100)
        XCTAssertEqual(params["message"] as? String, "reticulating splines")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(try XCTUnwrap(sink.notifications.first)))
    }

    /// A numeric token is echoed as a number: the client matches it against
    /// what it sent, so its TYPE has to survive too.
    func testANumericProgressTokenIsEchoedAsANumber() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: 7)
        reportProgress("working", percent: 1)
        callSession.finish(key: "1")
        let params = try params(try XCTUnwrap(sink.notifications.first))
        XCTAssertEqual(params["progressToken"] as? Int, 7)
    }

    // MARK: - The two rules on the numbers

    /// "The progress value MUST increase with each notification." A step that
    /// does not advance is DROPPED rather than nudged upward — an invented
    /// number would be a lie about how far along the work is.
    func testProgressNeverGoesBackwardsAndNeverRepeats() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        for percent in [10.0, 25.0, 25.0, 20.0, 60.0, 60.0, 100.0] {
            reportProgress("step", percent: percent)
        }
        callSession.finish(key: "1")
        let values = try sink.notifications.map { try params($0)["progress"] as? Double }
        XCTAssertEqual(values, [10, 25, 60, 100])
    }

    func testProgressIsClampedToTheHouseScale() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        reportProgress("under", percent: -50)
        reportProgress("over", percent: 250)
        callSession.finish(key: "1")
        let values = try sink.notifications.map { try params($0)["progress"] as? Double }
        XCTAssertEqual(values, [100], "a negative step cannot advance past the 0 it starts at")
    }

    /// The rate limit the spec asks for. A 100 ms file-size poll would
    /// otherwise emit six hundred notifications for one bounce.
    func testAThrottledCallSiteIsHeldBackButAPhaseBoundaryNeverIs() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        reportProgress("phase", percent: 10)
        for step in 1...20 {
            reportProgress("polling", percent: 10 + Double(step), throttle: 60)
        }
        reportProgress("next phase", percent: 90)
        callSession.finish(key: "1")
        let values = try sink.notifications.compactMap { try params($0)["progress"] as? Double }
        XCTAssertEqual(values, [10, 90], "the throttled polls must be held; the phases must not")
    }

    // MARK: - Nesting

    /// `logic_export_stems` is a loop over `logic_bounce_range`, and
    /// `logic_project_snapshot` contains a whole `logic_mixer_snapshot`. Both
    /// inner tools report 0…100 of their own work; without the mapping, the
    /// first inner run to 100 would freeze the outer line for the rest of the
    /// call.
    func testANestedToolsScaleIsFoldedIntoItsSliceOfTheOuterOne() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        // Two "stems", each owning half the line.
        for index in 0..<2 {
            reportProgress("stem \(index + 1)", percent: Double(index) * 50)
            withProgressScope((Double(index) * 50)...(Double(index + 1) * 50)) {
                reportProgress("inner start", percent: 0)
                reportProgress("inner middle", percent: 50)
                reportProgress("inner done", percent: 100)
            }
        }
        callSession.finish(key: "1")
        let values = try sink.notifications.compactMap { try params($0)["progress"] as? Double }
        // 0 is dropped (it cannot advance past the 0 the call starts at), and
        // so is the second stem's "inner start" at 50, which equals the marker
        // just sent. What matters is that the line only ever climbs and that
        // the inner 100s land at 50 and 100, not both at 100.
        XCTAssertEqual(values, [25, 50, 75, 100])
        XCTAssertEqual(values, values.sorted())
    }

    func testAScopeIsPoppedEvenWhenTheNestedToolThrows() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        struct Boom: Error {}
        XCTAssertThrowsError(try withProgressScope(0...50) { throw Boom() })
        reportProgress("back on the outer scale", percent: 80)
        callSession.finish(key: "1")
        let values = try sink.notifications.compactMap { try params($0)["progress"] as? Double }
        XCTAssertEqual(values, [80], "a thrown nested tool must not leave its scope on the stack")
    }

    // MARK: - Cancellation

    func testCheckCancelledThrowsOnlyForTheRunningRequest() throws {
        callSession.begin(key: "7", progressToken: nil)
        XCTAssertNoThrow(try checkCancelled())
        callSession.cancel(key: "8")
        XCTAssertNoThrow(try checkCancelled(), "another request's cancellation is not ours")
        callSession.cancel(key: "7")
        XCTAssertThrowsError(try checkCancelled()) { XCTAssertTrue($0 is RequestCancelled) }
        XCTAssertTrue(callSession.finish(key: "7"), "finish reports that it was cancelled")
        callSession.finish(key: "8")
    }

    /// Clients disagree about whether `notifications/cancelled` carries the id
    /// in its original JSON type or stringified — the spec's own example shows
    /// `"requestId": "123"` for what was plainly a number. The key is loose on
    /// purpose, because ignoring a cancellation over a type mismatch is the
    /// failure that costs a user a four-minute bounce.
    func testANumericIdAndItsStringFormAreTheSameCancellationKey() {
        XCTAssertEqual(CallSession.key(for: 123), CallSession.key(for: "123"))
        XCTAssertEqual(CallSession.key(for: NSNumber(value: 123)), "123")
        XCTAssertNotEqual(CallSession.key(for: "abc"), CallSession.key(for: 1))
    }

    /// A cancellation that arrives before the call starts still counts: the
    /// request is dropped and never answered.
    func testACancellationThatArrivesEarlyIsRemembered() {
        callSession.cancel(key: "early")
        XCTAssertTrue(callSession.isCancelled(key: "early"))
        XCTAssertTrue(callSession.finish(key: "early"))
        XCTAssertFalse(callSession.isCancelled(key: "early"), "finish clears it")
    }

    /// The spec requires tolerance here: cancellations race with completion, so
    /// an unknown or already-finished id must be a no-op, never an error.
    func testCancellingAnUnknownRequestIsHarmless() {
        callSession.cancel(key: "never-existed")
        callSession.cancel(key: "never-existed")
        XCTAssertFalse(callSession.finish(key: "something-else"))
        callSession.finish(key: "never-existed")
    }

    /// `notifications/cancelled` reaches the session through the normal
    /// notification path, and — being a notification — is never answered.
    func testTheCancelNotificationSetsTheFlagAndProducesNoResponse() throws {
        let server = MCPServer()
        let response = try server.handle([
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": 42, "reason": "user pressed stop"]
        ])
        XCTAssertNil(response)
        XCTAssertTrue(callSession.isCancelled(key: "42"))
        callSession.finish(key: "42")
    }

    func testACancelNotificationWithoutARequestIdIsIgnored() throws {
        let server = MCPServer()
        XCTAssertNil(try server.handle([
            "jsonrpc": "2.0", "method": "notifications/cancelled", "params": [:]
        ]))
        XCTAssertNil(try server.handle([
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": NSNull()]
        ]))
    }

    // MARK: - A long tool, as the real ones behave

    /// A stand-in for the poll loops in MCURender/AXBounce/MCUAutomation: it
    /// reports at its boundaries, checks for cancellation where it would sleep,
    /// and unwinds through a `defer` restore exactly as they do. The real ones
    /// need Logic Pro; this one proves the contract they are wired into.
    private func longTool(iterations: Int, onRestore: () -> Void) throws -> String {
        defer { onRestore() }
        reportProgress("starting", percent: 1)
        for index in 0..<iterations {
            try checkCancelled()
            reportProgress(
                "step \(index + 1)/\(iterations)",
                percent: 1 + 98 * Double(index + 1) / Double(iterations)
            )
        }
        reportProgress("done", percent: 100)
        return "finished"
    }

    func testALongToolReportsEveryPhaseWhenItIsLeftAlone() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        var restored = false
        XCTAssertEqual(try longTool(iterations: 4) { restored = true }, "finished")
        XCTAssertFalse(callSession.finish(key: "1"))
        XCTAssertTrue(restored)
        let values = try sink.notifications.compactMap { try params($0)["progress"] as? Double }
        XCTAssertEqual(values.count, 6, "start, four steps, done")
        XCTAssertEqual(values.first, 1)
        XCTAssertEqual(values.last, 100)
        XCTAssertEqual(values, values.sorted())
    }

    /// Cancellation lands at a loop boundary, throws, and the tool's own
    /// `defer` puts things back — which is the whole reason cancellation is a
    /// thrown error rather than a killed thread.
    func testACancelledLongToolStopsEarlyAndStillRestores() throws {
        let sink = Sink()
        callSession.setEmitter { sink.append($0) }
        callSession.begin(key: "1", progressToken: "t")
        var restored = false
        callSession.cancel(key: "1")
        XCTAssertThrowsError(try longTool(iterations: 1000) { restored = true }) {
            XCTAssertTrue($0 is RequestCancelled)
        }
        XCTAssertTrue(restored, "the existing restore path must run on the way out")
        XCTAssertTrue(
            callSession.finish(key: "1"),
            "the executor learns it was cancelled, and therefore sends NO response"
        )
        // Only the "starting" phase got out before the first boundary.
        XCTAssertEqual(sink.notifications.count, 1)
    }
}
