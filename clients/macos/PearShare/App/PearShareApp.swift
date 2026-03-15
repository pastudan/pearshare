import SwiftUI

@main
struct PearShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — this is a menu bar app.
        // All UI is driven from AppDelegate / NSStatusItem.
        Settings {
            EmptyView()
        }
    }
}
