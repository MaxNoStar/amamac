// swift-tools-version: 6.2
// Amamac's core: everything below the AppKit app (models, database, library, playlist, playback,
// web and podcasts). The app target in project.yml links these products.
import PackageDescription

/// Matches the app project's Swift 6 mode with Approachable Concurrency; the other features it
/// enables are already part of Swift 6. Default isolation stays nonisolated.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AmamacKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AmamacCore", targets: ["AmamacCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/nmdias/FeedKit", .upToNextMinor(from: "10.10.0")),
    ],
    targets: [
        .target(
            name: "AmamacCore",
            dependencies: [
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FeedKit", package: "FeedKit"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
