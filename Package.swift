// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Logician",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Single distributable binary: the MCP server, which also runs the
        // MCU bridge daemon when launched as `logician --bridge`
        // (the server spawns that itself; users never start a daemon).
        .executable(name: "logician", targets: ["LogicMCPDemo"])
    ],
    targets: [
        .executableTarget(
            name: "LogicMCPDemo",
            dependencies: ["LogicMCUBridge"],
            resources: [
                .copy("Resources/EmptyProject.logicx")
            ],
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
