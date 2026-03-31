// swift-tools-version:6.0
import PackageDescription

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
        // Apple-platform UI: SwiftUI views, AVKit player, AuthenticationServices.
        .library(
            name: "SmartTubeIOS",
            targets: ["SmartTubeIOS"]
        ),
    ],
    dependencies: [],
    targets: [
        // MARK: Core – iOS, macOS (Foundation only)
        .target(
            name: "SmartTubeIOSCore",
            dependencies: [],
            path: "Sources/SmartTubeIOSCore",
            swiftSettings: [.swiftLanguageVersion(.v6)]
        ),
        // MARK: UI – Apple platforms only (SwiftUI, AVKit, AuthenticationServices)
        .target(
            name: "SmartTubeIOS",
            dependencies: ["SmartTubeIOSCore"],
            path: "Sources/SmartTubeIOS",
            swiftSettings: [.swiftLanguageVersion(.v6)]
        ),
        // MARK: Tests
        .testTarget(
            name: "SmartTubeIOSTests",
            dependencies: ["SmartTubeIOSCore"],
            path: "Tests/SmartTubeIOSTests",
            swiftSettings: [.swiftLanguageVersion(.v6)]
        ),
    ]
)
