// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LogicMCPDemo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "logic-mcp-demo", targets: ["LogicMCPDemo"]),
        .executable(name: "logic-mcu-bridge", targets: ["LogicMCUBridge"])
    ],
    targets: [
        .executableTarget(
            name: "LogicMCPDemo",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
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
