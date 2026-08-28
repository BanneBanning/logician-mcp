import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

if CommandLine.arguments.contains("--bridge") {
    LogicMCUBridge.bridgeMain()
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
