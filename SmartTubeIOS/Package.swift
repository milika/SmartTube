// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartTubeIOS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        // Cross-platform core: models + InnerTube/SponsorBlock services (Foundation only).
        .library(
            name: "SmartTubeIOSCore",
            targets: ["SmartTubeIOSCore"]
        ),
        // Apple-platform UI: SwiftUI views, AVKit player, AuthenticationServices.
        .library(
            name: "SmartTubeIOS",
            targets: ["SmartTubeIOS"]
        ),
    ],
    dependencies: [],
    targets: [
        // MARK: Core – builds on Linux, iOS, macOS (Foundation only)
        .target(
            name: "SmartTubeIOSCore",
            dependencies: [],
            path: "Sources/SmartTubeIOSCore"
        ),
        // MARK: UI – Apple platforms only (SwiftUI, AVKit, AuthenticationServices)
        .target(
            name: "SmartTubeIOS",
            dependencies: ["SmartTubeIOSCore"],
            path: "Sources/SmartTubeIOS"
        ),
        // MARK: Tests – only test cross-platform core so they run on Linux CI too
        .testTarget(
            name: "SmartTubeIOSTests",
            dependencies: ["SmartTubeIOSCore"],
            path: "Tests/SmartTubeIOSTests"
        ),
    ]
)
