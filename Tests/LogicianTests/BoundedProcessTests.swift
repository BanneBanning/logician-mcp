import XCTest
import Darwin
@testable import Logician

final class BoundedProcessTests: XCTestCase {
    func testAlreadyCancelledDoesNotLaunchAChild() throws {
        let result = try BoundedProcess.run(executable: "/no-such-logician-child",
            arguments: [], timeout: 1, cancelled: { true })
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.processID, 0)
    }

    func testDrainsBothPipesBeyondTheirCapacityBeforeWaitingForExit() throws {
        let result = try BoundedProcess.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", "print STDOUT 'x' x 200000; print STDERR 'y' x 200000;"],
            timeout: 5
        )
        XCTAssertEqual(result.outcome, .exited(0))
        XCTAssertEqual(result.stdout, Data(repeating: 120, count: 200000))
        XCTAssertEqual(result.stderr, Data(repeating: 121, count: 200000))
    }

    func testDeadlineKillsAndReapsAChildThatIgnoresTermination() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try BoundedProcess.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 30;"], timeout: 0.15
        )
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(kill(result.processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationStopsTheOwnedChild() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try BoundedProcess.run(
            executable: "/bin/sleep", arguments: ["30"], timeout: 5,
            cancelled: { ProcessInfo.processInfo.systemUptime - start > 0.1 }
        )
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(kill(result.processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOutputBudgetStopsProducerWithoutReturningSuccess() throws {
        let result = try BoundedProcess.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", "$|=1; while(1) { print 'x' x 16384; }"],
            timeout: 5, outputLimit: 32000
        )
        XCTAssertEqual(result.outcome, .outputLimit)
        XCTAssertEqual(result.stdout.count + result.stderr.count, 32000)
        XCTAssertEqual(kill(result.processID, 0), -1)
    }

    func testNonzeroExitAndArgumentsRemainDistinctFromExecutionFailure() throws {
        let result = try BoundedProcess.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", "print $ARGV[0]; exit 7;", "a 'quoted' path; $(not-code)"],
            timeout: 2
        )
        XCTAssertEqual(result.outcome, .exited(7))
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "a 'quoted' path; $(not-code)")
        XCTAssertThrowsError(try BoundedProcess.run(
            executable: "/no-such-logician-child", arguments: [], timeout: 1
        ))
    }
}
