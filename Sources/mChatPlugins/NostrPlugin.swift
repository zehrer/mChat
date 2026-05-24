import Foundation
import AppBrickCore
import mChatCore

// MARK: - NostrPlugin

/// Registers the Nostr messaging backend into the plugin container.
///
/// Usage in the composition root (`mChatApp`):
/// ```swift
/// NostrPlugin(relays: NostrClient.defaultRelays).register(in: container)
/// ```
///
/// The `NostrBackend` is a lazy singleton — it is created only when first
/// resolved (i.e. when `ChatService.start()` is called after onboarding).
/// This means the plugin can be registered safely at app launch even before
/// the user has created an identity.
public struct NostrPlugin: AppPlugin {

    public let name = "Nostr"
    public let relays: [URL]

    public init(relays: [URL] = NostrClient.defaultRelays) {
        self.relays = relays
    }

    /// Registers `NostrBackend` as a lazy singleton.
    ///
    /// - Important: This method and the factory closure both run on the
    ///   `@MainActor` (called from `ChatService.start()`). `IdentityService`
    ///   must have a valid keypair before the factory is first invoked.
    @MainActor
    public func register(in container: PluginContainer) {
        let relays = self.relays
        container.registerSingleton(NostrBackend.self) {
            // Safe: always resolved from ChatService.start() which guards on identity
            guard let kp = IdentityService.shared.keyPair else {
                fatalError("[NostrPlugin] Cannot create NostrBackend: no identity found. " +
                           "Ensure an identity exists before calling ChatService.start().")
            }
            return NostrBackend(keyPair: kp, relays: relays)
        }
    }
}

// MARK: - Future protocol plugins (stubs)

// Each future backend gets its own file in Sources/mChatPlugins/:
//
// MatrixPlugin.swift  — matrix-ios-sdk, Olm/Megolm E2E
// XMPPPlugin.swift    — XMPPFramework + OMEMO
// SessionPlugin.swift — libsession-util Swift bindings
// SimplexPlugin.swift — SMP protocol Swift implementation
