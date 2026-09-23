// swift-tools-version: 6.2
import PackageDescription

// Pure logic for Bosk. No AppKit and no WebKit here, so `swift test` stays fast.
let package = Package(
    name: "BoskCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BoskCore", targets: ["BoskCore"]),
    ],
    targets: [
        .target(name: "BoskCore"),
        .testTarget(name: "BoskCoreTests", dependencies: ["BoskCore"]),
    ]
)
