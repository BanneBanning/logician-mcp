import Foundation
import XCTest
@testable import LogicMCUBridge

/// The MIDI stream scheduler's wait, which is what makes midi_abort an
/// emergency stop rather than a suggestion. Packets carry host-time stamps
/// and CoreMIDI cannot un-send one, so anything dispatched early is beyond
/// recall: the wait must both hold events back until their send time and
/// notice cancellation WHILE it waits.
///
/// Note: the scheduler's generation counter is module-global, so these tests
/// bump it themselves the way playMIDIStream and midi_abort do. They run
/// serially (XCTest default) and touch no MIDI endpoint.
final class StreamSchedulerTests: XCTestCase {

    private func startGeneration() -> Int {
        midiStreamLock.lock()
        midiStreamGeneration += 1
        let generation = midiStreamGeneration
        midiStreamLock.unlock()
        return generation
    }

    private func abort() {
        midiStreamLock.lock()
        midiStreamGeneration += 1
        midiStreamLock.unlock()
    }

    func testWaitReturnsAtOnceForATimeAlreadyPassed() {
        let generation = startGeneration()
        let started = Date()
        XCTAssertTrue(waitForMIDIStream(until: mach_absolute_time(), generation: generation))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "a due event must not be delayed")
    }

    func testWaitHoldsAnEventPastTheOldOneSecondCap() {
        // The old code slept min(gap, 1 s) ONCE and then sent regardless, so
        // any gap over a second — sparse pads, held chords, slow tempi — was
        // handed to CoreMIDI early. The wait must run to the deadline.
        let generation = startGeneration()
        let started = Date()
        XCTAssertTrue(waitForMIDIStream(
            until: mach_absolute_time() &+ hostTicks(fromMs: 1200), generation: generation
        ))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.15)
    }

    func testWaitSeesCancellationInsideALongGap() {
        // midi_abort during a ten-second rest must return within a slice, not
        // ten seconds later: until it does, the notes it is trying to stop
        // are still queued to go out.
        let generation = startGeneration()
        let deadline = mach_absolute_time() &+ hostTicks(fromMs: 10_000)
        let returned = expectation(description: "wait returned")
        var cancelled = false
        var elapsed = 0.0
        let started = Date()
        Thread.detachNewThread {
            cancelled = !waitForMIDIStream(until: deadline, generation: generation)
            elapsed = Date().timeIntervalSince(started)
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        abort()
        wait(for: [returned], timeout: 3.0)
        XCTAssertTrue(cancelled, "cancellation must be reported, not swallowed")
        XCTAssertLessThan(elapsed, 1.0, "abort must be seen during the gap, not after it")
    }

    func testWaitRefusesToRunUnderAStaleGeneration() {
        // A thread from a previous stream must stop immediately, even when
        // its own deadline is long past.
        let generation = startGeneration()
        abort()
        XCTAssertFalse(waitForMIDIStream(until: mach_absolute_time(), generation: generation))
    }
}
