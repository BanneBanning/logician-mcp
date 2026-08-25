// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LogicMCPDemo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Single distributable binary: the MCP server, which also runs the
        // MCU bridge daemon when launched as `logic-mcp-demo --bridge`
        // (the server spawns that itself; users never start a daemon).
        .executable(name: "logic-mcp-demo", targets: ["LogicMCPDemo"])
    ],
    targets: [
        .executableTarget(
            name: "LogicMCPDemo",
            dependencies: ["LogicMCUBridge"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "LogicMCUBridge",
            swiftSettings: [
                .swiftLanguageMode(.v5) // thread safety handled manually with locks
            ],
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        )
    ]
)
