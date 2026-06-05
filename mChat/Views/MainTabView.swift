import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            ConversationListView()
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                }

            ContactsView()
                .tabItem {
                    Label("Contacts", systemImage: "person.2")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
    }
}
