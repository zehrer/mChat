import SwiftUI
import AppBrickCore
import mChatCore
import mChatPlugins  // NostrPlugin and future protocol plugins

@main
struct mChatApp: App {

    // MARK: - Composition root
    //
    // This is the single place that decides which plugins are active.
    // To add a new protocol backend:
    //   1. Add its AppPlugin to Sources/mChatPlugins/
    //   2. Register it here — nothing else changes.
    //
    // To swap the storage backend:
    //   Replace SwiftDataStoragePlugin() with another StorageBackend plugin.

    private let env: AppEnvironment

    @StateObject private var identity = IdentityService.shared
    @StateObject private var chat: ChatService

    init() {
        let container = PluginContainer()

        // — Storage backend (swap to iCloud/SQLite/GraphDB by changing this line)
        SwiftDataStoragePlugin().register(in: container)

        // — Protocol backends
        NostrPlugin().register(in: container)
        // MatrixPlugin().register(in: container)   // Phase 3
        // XMPPPlugin().register(in: container)     // Phase 4

        let environment = AppEnvironment.live(
            subsystem: "net.zehrer.mChat",
            plugins: container
        )
        env = environment
        _chat = StateObject(wrappedValue: ChatService(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(identity)
                .environmentObject(chat)
                .task {
                    guard identity.keyPair != nil else { return }
                    await chat.start()
                }
        }
    }
}

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject var identity: IdentityService

    var body: some View {
        if identity.keyPair != nil {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}
