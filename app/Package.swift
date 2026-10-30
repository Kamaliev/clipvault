// swift-tools-version:5.10
import Foundation
import PackageDescription

// Static Rust core produced by ../scripts/build-core.sh
let coreLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("build/core").path

let package = Package(
    name: "PbWindow",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "pbcoreFFI", path: "Sources/PbCoreFFI"),
        .executableTarget(
            name: "PbWindow",
            dependencies: ["pbcoreFFI"],
            path: "Sources/PbWindow",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
