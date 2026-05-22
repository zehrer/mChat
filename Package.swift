// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mChatCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "mChatCore", targets: ["mChatCore"]),
    ],
    dependencies: [
        // secp256k1 for Nostr keypairs, Schnorr signing, and ECDH
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "mChatCore",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ],
            path: "Sources/mChatCore",
            linkerSettings: [
                // CommonCrypto is used for AES-256-CBC (NIP-04 encryption)
                .linkedLibrary("CommonCrypto", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "mChatCoreTests",
            dependencies: ["mChatCore"],
            path: "Tests/mChatCoreTests"
        ),
    ]
)
