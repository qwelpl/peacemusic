import SwiftUI

@main
struct PeaceApp: App {
    @State private var store = PlayerStore()

    var body: some Scene {
        Window("Peace", id: "main") {
            NowPlayingView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
    }
}
