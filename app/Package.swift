// swift-tools-version:5.10
import Foundation
import PackageDescription

// Static Rust core produced by ../scripts/build-core.sh
let coreLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("build/core").path

let package = Package(
    name: "Clipvault",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "clipvault_coreFFI", path: "Sources/CoreFFI"),
        .executableTarget(
            name: "Clipvault",
            dependencies: ["clipvault_coreFFI"],
            path: "Sources/Clipvault",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
