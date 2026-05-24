// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mChatCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "mChatCore",    targets: ["mChatCore"]),
        // mChatPlugins: one AppPlugin per protocol/storage backend.
        // Add new plugins here — no changes needed in mChatCore or the UI.
        .library(name: "mChatPlugins", targets: ["mChatPlugins"]),
    ],
    dependencies: [
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", from: "0.15.0"),
        // AppBricks: plugin system + DI container.
        // Both repos are expected to be siblings in the same parent directory:
        //   ../AppBricks/packages/AppBrickCore
        .package(path: "../AppBricks/packages/AppBrickCore"),
    ],
    targets: [
        // Core protocol-agnostic library — no UI, no app framework dependencies
        .target(
            name: "mChatCore",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ],
            path: "Sources/mChatCore",
            linkerSettings: [
                .linkedLibrary("CommonCrypto", .when(platforms: [.iOS, .macOS])),
            ]
        ),

        // One AppPlugin per chat protocol or storage backend.
        // The host app picks which plugins to load — no plugin code lives in mChatCore.
        .target(
            name: "mChatPlugins",
            dependencies: [
                "mChatCore",
                .product(name: "AppBrickCore", package: "AppBrickCore"),
            ],
            path: "Sources/mChatPlugins"
        ),

        .testTarget(
            name: "mChatCoreTests",
            dependencies: ["mChatCore"],
            path: "Tests/mChatCoreTests"
        ),
    ]
)
