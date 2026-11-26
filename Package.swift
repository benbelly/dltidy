// swift-tools-version:6.0
import PackageDescription

// Module layout:
//   DLTidyKit     shared protocols and infrastructure (tool runner, keychain, clock, notifier)
//   DLTidyMedia   probing and conversion (ImageMagick, ffmpeg, AVFoundation)
//   DLTidyNaming  name rules, slug, content extraction, Anthropic HTTP client
//   DLTidyCore    ledger, scanner, readiness, reconciler, pipeline, budget, health, commands
//   dltidy        daemon + CLI entry point
let package = Package(
    name: "dltidy",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DLTidyKit"),
        .target(name: "DLTidyMedia", dependencies: ["DLTidyKit"]),
        .target(name: "DLTidyNaming", dependencies: ["DLTidyKit"]),
        .target(name: "DLTidyCore", dependencies: ["DLTidyKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "dltidy", dependencies: ["DLTidyCore", "DLTidyMedia", "DLTidyNaming", "DLTidyKit"]),
        .testTarget(name: "DLTidyKitTests", dependencies: ["DLTidyKit"]),
        .testTarget(name: "DLTidyMediaTests", dependencies: ["DLTidyMedia", "DLTidyKit"]),
        .testTarget(name: "DLTidyNamingTests", dependencies: ["DLTidyNaming", "DLTidyKit"]),
        .testTarget(name: "DLTidyCoreTests", dependencies: ["DLTidyCore", "DLTidyKit"]),
    ]
)
