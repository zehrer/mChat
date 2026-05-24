# mOpenChat - Xcode Setup

> Naming note: the user-facing app is **mOpenChat**, but the Xcode project (`mChat.xcodeproj`), scheme, target, and Swift modules are still named `mChat` — do not rename them.


## Prerequisites

- macOS with Xcode 15.2 or newer
- iOS 17+ simulator runtime or iOS 17+ device

## Open and Run

1. Open `mChat.xcodeproj` in Xcode.
2. Let Xcode resolve the `secp256k1.swift` package dependency.
3. Select the `mChat` scheme.
4. Select an iOS simulator or device.
5. Press Run.

## Project Layout

```
mChat/
├── mChat.xcodeproj            # iOS app project
├── Sources/
│   ├── mChat/                 # SwiftUI app, services, and SwiftData storage
│   └── mChatCore/             # Core messaging, Nostr, crypto, and models
└── REQUIREMENTS.md
```

The former `mChatCore` Swift package sources are compiled directly into the
`mChat` app target. The app target has one external Swift package dependency:
`GigaBitcoin/secp256k1.swift` pinned to `0.19.0`.

## Info.plist Permissions

The Xcode target generates its Info.plist and includes:

- `NSContactsUsageDescription`
- `NSFaceIDUsageDescription`

## Local Verification

For a simulator build on Apple Silicon:

```sh
xcodebuild -project mChat.xcodeproj \
  -scheme mChat \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

