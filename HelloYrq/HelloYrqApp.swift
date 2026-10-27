import SwiftUI

@main
struct HelloYrqApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("你好，要瑞卿")
            .font(.largeTitle.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .accessibilityIdentifier("greeting")
    }
}
