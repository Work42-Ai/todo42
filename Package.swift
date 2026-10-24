// swift-tools-version: 6.2
//
// todo42 — the standalone, open-source macOS CLI for Work42's To-Dos and Planned Day (WOR-382).
// It owns its own store (`~/.work42/todo42/projects/<slug>/store.db`) and has NO dependency on
// work42/Flow42Core: the domain lives in `Todo42Core`, the `todo42` executable is a thin
// ArgumentParser front-end over it, and the Work42 plugin in `work42-plugin/` is UI + orchestration.

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "todo42",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Todo42Core", targets: ["Todo42Core"]),
        .executable(name: "todo42", targets: ["todo42"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Todo42Core",
            path: "Sources/Todo42Core",
            swiftSettings: concurrencySettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "todo42",
            dependencies: [
                "Todo42Core",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/todo42",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "Todo42CoreTests",
            dependencies: ["Todo42Core"],
            path: "Tests/Todo42CoreTests",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "todo42Tests",
            dependencies: ["todo42", "Todo42Core"],
            path: "Tests/todo42Tests",
            swiftSettings: concurrencySettings
        ),
    ]
)
