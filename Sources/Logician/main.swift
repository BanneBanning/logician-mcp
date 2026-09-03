import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

if CommandLine.arguments.contains("--bridge") {
    LogicMCUBridge.bridgeMain()
}
// `logician doctor` — the setup report a musician pastes into a support issue.
// A SUBCOMMAND, not a flag: argv with no subcommand still falls straight
// through to the MCP server below, so a client that launches the binary bare
// is unaffected. It reads only — no daemon start, no MIDI, no writes.
if CommandLine.arguments.dropFirst().first == "doctor" {
    exit(DoctorCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}
// No `MCUBridge.ensureRunning()` here. Starting the daemon at launch made the
// server anything but inert: a client that connected and did nothing but list
// tools still spawned a MIDI bridge, which Logic answers by redrawing the
// user's real control surface. Enumerating a capability must not move
// hardware. The daemon is started lazily by the first command that actually
// needs it (`MCUBridge.transact` retries through `ensureRunning`), and
// `logic_health` starts it explicitly during onboarding, so nothing that used
// to work needs the eager call.
MCPServer.configureToolsets() // --toolsets=<comma list> / LOGICIAN_TOOLSETS
MCPServer().run()
