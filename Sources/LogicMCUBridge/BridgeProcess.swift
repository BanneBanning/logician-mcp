// Identifying the running bridge daemon — precisely enough to replace it.
//
// Replacing an outdated daemon is a KILL, so getting the target wrong is
// expensive in both directions, and this code has been wrong in both:
//
//  * too loose, once: an early `pkill -f` matched on a broad substring and
//    could hit unrelated processes (closed as a security finding, v0.49);
//  * too tight, since: the anchored replacement matched
//    `"<absolute path to logician> --bridge"`, and the user's daemon is
//    routinely started as the RELATIVE `./.build/release/logician --bridge`.
//    The pattern never matched, so "replacing outdated bridge daemon" was a
//    line in the log and nothing else — every upgrade silently no-opped while
//    a second bridge was spawned, failed to claim the socket, and died
//    (observed live 2026-08-28, and it reset the MCU surface on the way out).
//
// The fix is to stop pattern-matching a command line whose spelling we do not
// control. A daemon writes its OWN pid into the lockfile it already holds, so
// replacement addresses a number rather than a string. The scan below stays
// as the fallback for a daemon that predates the pid file, and it is written
// to be precise rather than broad: a candidate must carry the `--bridge`
// argument AND be one of our own executables.

import Foundation

public enum BridgeProcess {
    /// The lockfile the single live daemon flocks for its whole lifetime, and
    /// now also writes its pid into.
    public static let lockFileName = "bridge.lock"

    /// Executable names that are legitimately a bridge daemon: the current
    /// single binary, and the pre-v0.50 standalone one.
    public static let daemonExecutableNames: Set<String> = ["logician", "logic-mcu-bridge"]

    /// One row of `ps -axww -o pid=,args=`.
    ///
    /// `comm` is deliberately NOT used. On macOS `ps` truncates it to 16
    /// characters, so the daemon this code exists to find reports its
    /// executable as `./.build/release` — the interesting part, the binary
    /// name, is exactly what gets cut off. Matching on that would have
    /// reproduced the very bug being fixed. The argument vector is not
    /// truncated (with `-ww`), so argv[0] is the reliable source.
    public struct Candidate: Equatable, Sendable {
        public let pid: Int32
        /// The full argument vector as one string.
        public let arguments: String

        public init(pid: Int32, arguments: String) {
            self.pid = pid
            self.arguments = arguments
        }
    }

    /// Which candidates are genuinely a bridge daemon we may replace.
    ///
    /// Pure, and deliberately conjunctive: the process must be running one of
    /// OUR executables *and* carry `--bridge` as a whole argument. Either test
    /// alone is unsafe — the name alone would match the MCP server itself
    /// (same binary, no `--bridge`), and the argument alone would match an
    /// editor, a `tail`, or a shell whose command line merely mentions it,
    /// which is exactly the security finding that produced the over-tight
    /// pattern this replaces.
    ///
    /// `excluding` is the caller's own pid, so a server can never order its
    /// own execution.
    public static func daemonPids(among candidates: [Candidate], excluding own: Int32) -> [Int32] {
        candidates.filter { candidate in
            guard candidate.pid > 1, candidate.pid != own else { return false }
            guard hasBridgeArgument(candidate.arguments) else { return false }
            return invokesDaemonExecutable(candidate.arguments)
        }.map(\.pid)
    }

    /// True when the argument vector invokes one of our daemon binaries.
    ///
    /// Splitting argv[0] off on whitespace is NOT good enough: this project
    /// lives at `…/Random Projekt/Logic MCP/…`, so the executable path itself
    /// contains spaces and the first "word" of the command line is
    /// `/Users/x/Desktop/Progg/Random`. The test is therefore on the binary
    /// NAME appearing as a path-final component, which survives both a
    /// relative invocation and a path with spaces in it.
    ///
    /// It stays precise: the name must be preceded by a `/` or start the line,
    /// and must be followed by whitespace or end the string. `zsh -c
    /// 'logician --bridge'` is quoted, not path-final, and is not matched.
    public static func invokesDaemonExecutable(_ arguments: String) -> Bool {
        for name in daemonExecutableNames {
            if arguments == name || arguments.hasSuffix("/" + name) { return true }
            if arguments.hasPrefix(name + " ") { return true }
            if arguments.contains("/" + name + " ") { return true }
        }
        return false
    }

    /// True when `--bridge` appears as a WHOLE argument.
    ///
    /// Substring matching would accept `--bridgeless` and, worse, a path like
    /// `/Users/x/my--bridge-notes.txt` sitting in some other process's
    /// arguments. Splitting on whitespace is enough here because the only
    /// argument that matters carries none.
    public static func hasBridgeArgument(_ arguments: String) -> Bool {
        arguments.split(whereSeparator: \.isWhitespace).contains("--bridge")
    }

    /// Parses `ps -axww -o pid=,args=` output: a pid, then the whole argument
    /// vector, which may itself contain spaces (an executable path with a
    /// space in it, as this very project has).
    ///
    /// A row whose pid does not parse, or that has no arguments at all, is
    /// DROPPED — an unparseable row must never become a kill target.
    public static func parsePS(_ output: String) -> [Candidate] {
        output.split(separator: "\n").compactMap { line -> Candidate? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]) else { return nil }
            let arguments = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            guard !arguments.isEmpty else { return nil }
            return Candidate(pid: pid, arguments: arguments)
        }
    }

    /// Reads a pid written by a daemon into its lockfile. `nil` for an empty
    /// or malformed file, which is exactly what a pre-pid-file daemon leaves.
    public static func parsePidFile(_ contents: String) -> Int32? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 1 else { return nil }
        return pid
    }
}
