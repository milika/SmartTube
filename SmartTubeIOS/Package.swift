// swift-tools-version:6.0
import PackageDescription

// The SmartTubeIOS UI target uses iOS-only APIs (UIKit, fullScreenCover, etc.).
// Exclude it when resolving/building on macOS so that `swift test` can run
// against SmartTubeIOSCore without a simulator.
#if os(iOS)
let iosProducts: [Product] = [
    .library(name: "SmartTubeIOS", targets: ["SmartTubeIOS"]),
]
let iosTargets: [Target] = [
    .target(
        name: "SmartTubeIOS",
        dependencies: ["SmartTubeIOSCore"],
        path: "Sources/SmartTubeIOS",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#else
let iosProducts: [Product] = []
let iosTargets: [Target] = []
#endif

let package = Package(
    name: "SmartTubeIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // Cross-platform core: models + InnerTube/SponsorBlock services (Foundation only).
        .library(
            name: "SmartTubeIOSCore",
            targets: ["SmartTubeIOSCore"]
        ),
    ] + iosProducts,
    dependencies: [],
    targets: [
        // MARK: Core – iOS, macOS (Foundation only)
        .target(
            name: "SmartTubeIOSCore",
            dependencies: [],
            path: "Sources/SmartTubeIOSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: Tests
        .testTarget(
            name: "SmartTubeIOSTests",
            dependencies: ["SmartTubeIOSCore"],
            path: "Tests/SmartTubeIOSTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + iosTargets
)
