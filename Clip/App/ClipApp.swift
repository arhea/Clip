import SwiftUI

@main
struct ClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let app = AppState.shared

    var body: some Scene {
        MenuBarExtra("Clip", systemImage: "camera.viewfinder") {
            MenuBarContent(app: app)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(app: app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    /// Supports "Open With → Clip" and `open -a Clip image.png`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppState.shared.openImage(at: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
