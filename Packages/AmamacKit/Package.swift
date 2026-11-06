// swift-tools-version: 6.2
// Amamac's core, one module per layer. Each module may only import the ones listed in its
// dependencies, so the layering is checked by the compiler:
//
//   Base ← Models ← Query ← Database ← Library ← Playlist
//                              ↑  ↖ Dynamic, Web ← Podcasts
//   Playback (Models only)          TestSupport (Debug and tests)
//   TagLib (Objective-C++, TagLib only) ← Library
import PackageDescription

/// Matches the app project's Swift 6 mode with Approachable Concurrency; the other features it
/// enables are already part of Swift 6. Default isolation stays nonisolated.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let grdb = Target.Dependency.product(name: "GRDB", package: "GRDB.swift")
let sfbAudioEngine = Target.Dependency.product(name: "SFBAudioEngine", package: "SFBAudioEngine")
let tagLib = Target.Dependency.product(name: "taglib", package: "CXXTagLib")

func module(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .target(name: name, dependencies: dependencies, swiftSettings: swiftSettings)
}

let modules: [Target] = [
    module("AmamacBase", []),
    module("AmamacModels", ["AmamacBase"]),
    module("AmamacQuery", ["AmamacBase", "AmamacModels"]),
    module("AmamacDatabase", ["AmamacBase", "AmamacModels", "AmamacQuery", grdb]),
    module("AmamacLibrary", ["AmamacBase", "AmamacModels", "AmamacDatabase", "AmamacTagLib", grdb, sfbAudioEngine]),
    module("AmamacPlaylist", ["AmamacBase", "AmamacModels", "AmamacDatabase", "AmamacLibrary", grdb]),
    module("AmamacDynamic", ["AmamacBase", "AmamacModels", "AmamacQuery", "AmamacDatabase", grdb]),
    module("AmamacPlayback", ["AmamacModels", sfbAudioEngine]),
    module("AmamacWeb", ["AmamacBase", "AmamacModels", "AmamacDatabase", grdb]),
    module("AmamacPodcasts", ["AmamacBase", "AmamacModels", "AmamacDatabase", "AmamacWeb", grdb,
                              .product(name: "FeedKit", package: "FeedKit")]),
    module("AmamacTestSupport", ["AmamacBase", "AmamacModels", "AmamacDatabase", "AmamacLibrary", grdb, sfbAudioEngine]),
]

/// Exact dates (ID3v2, MP4) and MP4 ISRCs, written with the TagLib that
/// SFBAudioEngine already links (see `AMTFields`). Objective-C++, so it is not a Swift module above.
let tagLibHelper = Target.target(name: "AmamacTagLib", dependencies: [tagLib],
                                 linkerSettings: [.linkedFramework("Foundation")])

let package = Package(
    name: "AmamacKit",
    platforms: [.macOS("26.0")],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) },
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.14.0"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/nmdias/FeedKit", .upToNextMinor(from: "10.10.0")),
        // Already resolved through SFBAudioEngine; pinned to the same version.
        .package(url: "https://github.com/sbooth/CXXTagLib", exact: "2.3.2"),
    ],
    targets: modules + [tagLibHelper],
    cxxLanguageStandard: .cxx20
)
