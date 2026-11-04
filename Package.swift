// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "restore-engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RestoreEngine", targets: ["RestoreEngine"]),
        .executable(name: "restore-engine", targets: ["restore-engine"]),
        .executable(name: "restore-engine-dfu", targets: ["restore-engine-dfu"]),
    ],
    targets: [
        // Foundation only: no SwiftUI, Security or ServiceManagement, so it builds and
        // tests anywhere Swift runs. Apps add their own root door (e.g. an XPC helper).
        .target(name: "RestoreEngine"),
        // `restore-engine serve|status`: JSON lines around the engine, run as the user.
        .executableTarget(name: "restore-engine", dependencies: ["RestoreEngine"]),
        // The root door for machines without an app helper: `check`, `dfu --port N`.
        .executableTarget(name: "restore-engine-dfu", dependencies: ["RestoreEngine"]),
        .testTarget(name: "RestoreEngineTests", dependencies: ["RestoreEngine"]),
    ]
)
