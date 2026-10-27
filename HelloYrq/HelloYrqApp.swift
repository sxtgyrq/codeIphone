import SwiftUI

@main
@MainActor
struct HelloYrqApp: App {
    @StateObject private var model = MapViewModel.applicationModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if model.session == nil { MapLoginView(model: model) }
                else { MapScreen(model: model) }
            }
            .tint(.indigo)
        }
    }
}
