import SwiftUI
import mChatCore

@main
struct mChatApp: App {

    @StateObject private var identity = IdentityService.shared
    @StateObject private var chat = ChatService.shared

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

/// Routes between onboarding and the main tab interface.
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
