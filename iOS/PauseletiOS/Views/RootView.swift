import SwiftUI
import ReminderCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack { ReminderListView() }
                .tabItem { Label("Reminders", systemImage: "bell.badge") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "chart.bar") }

            NavigationStack { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }

            NavigationStack { AboutScreen() }
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .overlay(alignment: .top) {
            if let card = model.subtleCard {
                SubtleCardView(item: card) { completed in
                    model.acknowledgeSubtle(completed: completed)
                }
                .id(card.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $model.takeover) { item in
            TakeoverView(item: item) { action in
                model.acknowledgeTakeover(item, action: action)
            }
        }
    }
}
