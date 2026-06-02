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
        .executable(name: "mCLIChat", targets: ["mCLIChat"]),
    ],
    dependencies: [
        // secp256k1 for Nostr keypairs, Schnorr signing, and ECDH
        // Pinned to 0.19.x — v0.20+ renamed the product from secp256k1 to P256K
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", .upToNextMinor(from: "0.19.0")),
        // swift-crypto provides AES-CBC on Linux via _CryptoExtras
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "mChatCore",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            path: "Sources/mChatCore",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                // CommonCrypto is used for AES-256-CBC (NIP-04 encryption) on Apple platforms
                .linkedLibrary("CommonCrypto", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .executableTarget(
            name: "mCLIChat",
            dependencies: ["mChatCore"],
            path: "Sources/mCLIChat",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "mChatCoreTests",
            dependencies: ["mChatCore"],
            path: "Tests/mChatCoreTests"
        ),
    ]
)
