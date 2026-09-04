import SwiftUI
import ReminderCore

@main
struct PauseletApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Registration must happen before the app finishes launching, and the
        // shared model must exist before any App Intent (an alarm's Stop or
        // Open button) tries to reach it.
        let model = AppModel.shared
        _model = StateObject(wrappedValue: model)
        AppModel.registerBackgroundRefresh()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.engine)
                .environmentObject(model.speech)
                .environmentObject(model.ai)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
