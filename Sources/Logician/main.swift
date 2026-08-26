import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

if CommandLine.arguments.contains("--bridge") {
    LogicMCUBridge.bridgeMain()
}
MCUBridge.ensureRunning()
MCPServer().run()
