import SwiftUI

/// The menu shown from the menu bar icon.
struct MenuBarContent: View {
    let app: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !app.hasPermission {
            Button("Grant Screen Recording Permission…") {
                ScreenCapturer.requestPermission()
                ScreenCapturer.openPermissionSettings()
                app.refreshPermission()
            }
            Divider()
        }

        captureButton("Capture Area", systemImage: "rectangle.dashed", action: .captureArea) { app.captureArea() }
        captureButton("Capture Window", systemImage: "macwindow", action: .captureWindow) { app.captureWindow() }
        captureButton("Capture Fullscreen", systemImage: "display", action: .captureFullscreen) { app.captureFullscreen() }
        if NSScreen.screens.count > 1 {
            captureButton("Capture All Screens", systemImage: "display.2", action: .captureAllScreens) { app.captureAllScreens() }
        }
        captureButton("Capture Previous Area", systemImage: "arrow.counterclockwise", action: .capturePreviousArea) { app.capturePreviousArea() }
        Menu {
            ForEach([3, 5, 10], id: \.self) { seconds in
                Button("\(seconds) Seconds") { app.captureFullscreen(delay: seconds) }
            }
        } label: {
            Label("Self-Timer", systemImage: "timer")
        }
        Button("Capture Text", systemImage: "text.viewfinder") { app.captureText() }

        Divider()

        Menu {
            let recent = Array(app.history.items.prefix(10))
            if recent.isEmpty {
                Text("No Captures Yet")
            }
            ForEach(recent) { item in
                Button {
                    app.openEditor(item)
                } label: {
                    if let thumbnail = app.history.thumbnail(for: item) {
                        Image(nsImage: menuThumbnail(thumbnail))
                    }
                    Text("\(item.kind.displayName) — \(item.date.formatted(date: .omitted, time: .shortened))")
                }
            }
        } label: {
            Label("Recent Captures", systemImage: "clock")
        }
        hotKeyButton("Capture History…", systemImage: "square.grid.2x2", action: .openHistory) { app.showHistory() }
        Button("Open Image…", systemImage: "photo") { app.openImageFile() }
        if app.pins.count > 0 {
            Button("Close All Pins", systemImage: "pin.slash") { app.pins.closeAll() }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Clip") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func captureButton(_ title: String, systemImage: String, action: HotKeyAction, perform: @escaping () -> Void) -> some View {
        hotKeyButton(title, systemImage: systemImage, action: action, perform: perform)
    }

    @ViewBuilder
    private func hotKeyButton(_ title: String, systemImage: String, action: HotKeyAction, perform: @escaping () -> Void) -> some View {
        let button = Button(title, systemImage: systemImage, action: perform)
        if let hotKey = app.preferences.hotKeys[action], let shortcut = hotKey.keyboardShortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private func menuThumbnail(_ image: NSImage) -> NSImage {
        let height: CGFloat = 28
        let width = min(56, height * image.size.width / max(1, image.size.height))
        return NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}

extension HotKey {
    /// A SwiftUI shortcut for displaying the global hot key in menus.
    var keyboardShortcut: KeyboardShortcut? {
        let name = HotKey.keyName(for: keyCode)
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        var modifiers: EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}
