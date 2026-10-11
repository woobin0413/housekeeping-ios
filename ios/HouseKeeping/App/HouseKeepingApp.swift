import SwiftUI

@main
struct HouseKeepingApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .tint(Palette.action)
                #if DEBUG
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--preview-dark") ? .dark : nil)
                #endif
        }
    }
}
