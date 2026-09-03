import XCTest
@testable import Logician

/// `MCUController.pluginListSurfaceRead` — the plug-in-list retry loop's
/// choice of surface read for attempt N, and the decision behind
/// `ensurePluginList`, `setPluginParameter`, `addPluginViaBrowser` and
/// `removePluginViaBrowser` all moving off bare `freshStatus()`.
///
/// `ensurePluginList` gated its FIRST look of every call on bare
/// `freshStatus()`, which returns nil the moment the MCU mirror is older
/// than `staleMirrorSeconds` (600 s) even though Logic is simply idle and
/// one `wakeSurface()` probe would answer it — every other MCU family
/// (`logic_set_cycle`, `logic_set_playing`, `logic_set_metronome`, and seven
/// more call sites) already takes that probe via `requireSurface`. Hit live
/// on the demo project 2026-09-03: the mirror was 1 054 s idle, Logic was
/// simply sitting there, and `logic_list_inserts {route: mcu}` refused with
/// "the control surface's status could not be read at all" until a single
/// `bank_right` press woke it.
///
/// The same bare-`freshStatus()` gate was duplicated at three sibling entry
/// points that do not go through `ensurePluginList` at all:
/// `MCUParameters.setPluginParameter`'s pre-hot-view check and
/// `MCUPluginBrowser.addPluginViaBrowser`/`removePluginViaBrowser`'s entry
/// guards (the latter two even named the fault in their own refusal string,
/// "the surface's mirror is stale or the bridge is not running"). All four
/// now gate on `requireSurface`, `try?`-wrapped so a genuinely unavailable
/// surface (no daemon, Logic not running, Logic never talked to it) still
/// falls through to the same refusal as before.
///
/// An idle mirror past `staleMirrorSeconds` cannot be manufactured in a
/// two-minute live lock hold, so the classification itself rests on
/// `SurfaceLivenessTests` (which already proves `requireSurface`'s wake
/// path); what is pinned here, with a call-counting closure exactly like
/// `MetronomeStateResolutionTests`, is `ensurePluginList`'s own new decision:
/// the wake probe runs on the FIRST attempt only, never again across the
/// retry loop's remaining tries — re-probing on every retry would pay the
/// wake's bank-walk-out-and-back cost up to five times over for a mirror the
/// first wake already left fresh.
final class PluginListSurfaceWakeTests: XCTestCase {

    func testTheFirstAttemptTakesTheWakeProbe() {
        var wakeCalls = 0
        let status = MCUController.pluginListSurfaceRead(
            attempt: 0,
            wake: { wakeCalls += 1; return ["ok": true, "woken": true] },
            fresh: { XCTFail("attempt 0 must not use plain freshStatus"); return nil }
        )
        XCTAssertEqual(wakeCalls, 1)
        XCTAssertEqual(status?["woken"] as? Bool, true)
    }

    func testEveryAttemptAfterTheFirstUsesPlainFreshStatus() {
        for attempt in 1...4 {
            var freshCalls = 0
            let status = MCUController.pluginListSurfaceRead(
                attempt: attempt,
                wake: { XCTFail("attempt \(attempt) must not re-probe"); return nil },
                fresh: { freshCalls += 1; return ["ok": true] }
            )
            XCTAssertEqual(freshCalls, 1, "attempt \(attempt)")
            XCTAssertNotNil(status)
        }
    }

    /// The property the fix actually buys: across a full 5-attempt retry
    /// loop, the wake probe (and the bank-walk-back it pays for on an edge)
    /// is spent exactly once.
    func testExactlyOneWakeAcrossTheWholeRetryLoop() {
        var wakeCalls = 0
        var freshCalls = 0
        for attempt in 0..<5 {
            _ = MCUController.pluginListSurfaceRead(
                attempt: attempt,
                wake: { wakeCalls += 1; return nil },
                fresh: { freshCalls += 1; return ["ok": true] }
            )
        }
        XCTAssertEqual(wakeCalls, 1)
        XCTAssertEqual(freshCalls, 4)
    }

    /// A wake that itself comes back nil (genuinely unavailable, or both
    /// probe directions stayed silent) is not papered over by falling back
    /// to `fresh` on attempt 0 — the caller's own guard sees the nil and
    /// refuses, same as a bare `freshStatus()` returning nil always did.
    func testAFailedWakeStaysNilRatherThanFallingBackToFresh() {
        var freshCalls = 0
        let status = MCUController.pluginListSurfaceRead(
            attempt: 0,
            wake: { nil },
            fresh: { freshCalls += 1; return ["ok": true] }
        )
        XCTAssertNil(status)
        XCTAssertEqual(freshCalls, 0)
    }
}
