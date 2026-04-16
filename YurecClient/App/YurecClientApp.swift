import SwiftUI

@main
struct YurecClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — menu bar only app
        // Settings window is managed by SettingsWindowController
        Settings {
            EmptyView()
        }
    }
}
