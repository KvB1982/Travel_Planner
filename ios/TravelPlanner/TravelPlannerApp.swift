import SwiftUI
import TravelPlannerKit

@main
struct TravelPlannerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Shows the sign-in until there is a connection, then the trips.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.backend == nil {
                OnboardingView()
            } else {
                MainView()
            }
        }
        // A tap on an invitation, in a message or on its web page, opens the app with the link.
        .onOpenURL { model.open($0) }
        // Links shared through the extension arrive while the app is in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.dataChanged() }
        }
    }
}
