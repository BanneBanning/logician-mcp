import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

if CommandLine.arguments.contains("--bridge") {
    LogicMCUBridge.bridgeMain()
}
MCPServer.configureToolsets() // --toolsets=<comma list> / LOGICIAN_TOOLSETS
MCUBridge.ensureRunning()
MCPServer().run()
