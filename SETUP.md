# mChat – Xcode Setup Guide

## Prerequisites

- macOS 14+ (Sonoma or later)
- Xcode 15.2+
- iOS 17+ device or simulator

---

## Step 1 – Create the Xcode project

1. Open Xcode → **File → New → Project**
2. Choose **iOS → App**
3. Fill in:
   | Field | Value |
   |---|---|
   | Product Name | mChat |
   | Bundle Identifier | `net.zehrer.mChat` (or your own) |
   | Interface | SwiftUI |
   | Language | Swift |
   | Storage | None (SwiftData added manually) |
4. Save into the **mChat** repository root (where `Package.swift` lives).

---

## Step 2 – Add the mChatCore Swift Package

1. In the Xcode project navigator, select the project root.
2. **File → Add Package Dependencies…**
3. Choose **Add Local…** and select the `mChat` folder (the one containing `Package.swift`).
4. Tick **mChatCore** and add it to the **mChat** app target.

The `secp256k1.swift` dependency will be resolved automatically by Xcode.

---

## Step 3 – Add the app source files

1. In Xcode, select the `mChat` group in the navigator.
2. **File → Add Files to "mChat"…**
3. Select the entire `Sources/mChat/` folder.
4. Choose **Create groups** and ensure **Add to target: mChat** is checked.

---

## Step 4 – Capabilities & entitlements

In **Signing & Capabilities** for the mChat target, add:

| Capability | Reason |
|---|---|
| **Background Modes → Background fetch** | Relay reconnect in background |
| **Background Modes → Remote notifications** | Future push-based wake |
| **Keychain Sharing** (optional) | Share keys between app + extensions |

---

## Step 5 – Info.plist keys

Add these entries to `Info.plist` (or via the target's Info tab):

```xml
<key>NSFaceIDUsageDescription</key>
<string>mChat uses Face ID to protect your private key</string>
```

---

## Step 6 – Build and run

Select an iOS 17 simulator or device and press **Run (⌘R)**.

On first launch you'll be prompted to create a new Nostr identity (keypair generation happens on-device; the private key is stored in the Keychain and never leaves the device).

---

## Project layout

```
mChat/
├── Package.swift              # mChatCore SPM package (secp256k1 dep)
├── Sources/
│   ├── mChatCore/             # Protocol-agnostic core library
│   │   ├── Backend/
│   │   │   ├── MessagingBackend.swift   # Protocol abstraction
│   │   │   └── NostrBackend.swift       # Nostr implementation
│   │   ├── Crypto/
│   │   │   └── NIP04.swift              # AES-256-CBC encrypted DMs
│   │   ├── Models/
│   │   │   ├── ChatMessage.swift
│   │   │   ├── Contact.swift
│   │   │   └── Conversation.swift       # 1:1 + group, any protocol
│   │   └── Nostr/
│   │       ├── NostrClient.swift        # Multi-relay orchestrator
│   │       ├── NostrError.swift
│   │       ├── NostrEvent.swift         # NIP-01 event model
│   │       ├── NostrFilter.swift        # NIP-01 subscription filters
│   │       ├── NostrKeyPair.swift       # secp256k1 identity
│   │       └── NostrRelay.swift         # WebSocket relay actor
│   └── mChat/                 # iOS app (add to Xcode project)
│       ├── App/
│       │   └── mChatApp.swift
│       ├── Services/
│       │   ├── IdentityService.swift    # Keychain key management
│       │   └── ChatService.swift        # Multi-backend orchestrator
│       └── Views/
│           ├── MainTabView.swift
│           ├── OnboardingView.swift
│           ├── ConversationListView.swift
│           ├── ChatView.swift
│           ├── ContactsView.swift
│           └── ProfileView.swift
└── Tests/
    └── mChatCoreTests/        # Unit tests (run via ⌘U or swift test)
```

---

## Adding a second protocol backend (future)

To add Matrix, XMPP, or any other protocol:

1. Add a new case to `ChatProtocol` in `mChatCore/Models/Conversation.swift`
2. Create `Sources/mChatCore/Backend/MatrixBackend.swift` conforming to `MessagingBackend`
3. Register it in `ChatService.start()`:
   ```swift
   let matrix = MatrixBackend(homeserver: "matrix.org", credentials: ...)
   BackendRegistry.shared.register(matrix)
   listenForIncoming(backend: matrix)
   ```

The UI layer needs zero changes — `ChatService` routes automatically.
