// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Logician",
    // The DEPLOYMENT floor: a built `logician` runs on macOS 13 (Ventura).
    // The BUILD floor is higher and is set by the line above: Swift tools
    // version 6.0 needs a Swift 6 toolchain, which ships in Xcode 16, which
    // Apple will only install on macOS 14.5 or later. A Ventura Mac stops
    // before it compiles a line — `swift build` answers "package 'Logician'
    // is using Swift tools version 6.0.0 but the installed version is 5.9.2"
    // (the shape verified locally 2026-09-04 against a deliberately
    // too-new manifest). Since nothing here is distributed as a binary —
    // Homebrew and packaging/install.sh both compile from source on the
    // user's own machine — macOS 14.5 is the honest floor to ADVERTISE, and
    // it is what packaging/install.sh checks and the formula depends on.
    // Lowering the tools version is not a one-line change: `.swiftLanguageMode`
    // is unavailable before PackageDescription 6.0 (verified 2026-09-04), and
    // the sources use `nonisolated(unsafe)` in 18 places, which is Swift 5.10
    // (SE-0412) and so out of reach of the 5.9 toolchain Ventura tops out at.
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Single distributable binary: the MCP server, which also runs the
        // MCU bridge daemon when launched as `logician --bridge`
        // (the server spawns that itself; users never start a daemon).
        .executable(name: "logician", targets: ["Logician"])
    ],
    targets: [
        .executableTarget(
            name: "Logician",
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
        ),
        // Tests cover the PURE logic only — the parts that are expensive to
        // get wrong and cheap to check: LCD field parsing, the value/dB
        // parsers, filename sanitisation, socket framing, and the MIDI
        // running-status parser. Nothing here needs Logic Pro running.
        .testTarget(
            name: "LogicianTests",
            dependencies: ["Logician", "LogicMCUBridge"]
        ),
        .testTarget(
            name: "LogicMCUBridgeTests",
            dependencies: ["LogicMCUBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
