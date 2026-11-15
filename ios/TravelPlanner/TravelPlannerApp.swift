import SwiftUI
import TravelPlannerKit

@main
struct TravelPlannerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.backend == nil {
                    OnboardingView()
                } else {
                    MainView()
                }
            }
            .environment(model)
            // Links shared through the extension arrive while the app is in the background.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.dataChanged() }
            }
        }
    }
}
