import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let app: AppState

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(preferences: app.preferences) }
            Tab("Capture", systemImage: "camera.viewfinder") { CaptureSettings(preferences: app.preferences) }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutSettings(app: app) }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var feedbackFooter: String {
        switch preferences.captureFeedback {
        case .notification: "A notification lets you open the editor, save, or copy instead of the default."
        case .quickAccess: "A floating thumbnail lets you copy, save, annotate, or pin the capture."
        case .none: "Clip shows a brief confirmation only."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default action", selection: $preferences.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)

                if preferences.afterCapture == .saveToDisk {
                    SaveLocationRow(preferences: preferences)
                }

                Picker("Then show", selection: $preferences.captureFeedback) {
                    ForEach(CaptureFeedback.allCases) { Text($0.displayName).tag($0) }
                }
                if preferences.captureFeedback == .quickAccess {
                    Picker("Close overlay", selection: $preferences.quickAccessAutoCloseSeconds) {
                        Text("Never").tag(0)
                        Text("After 5 seconds").tag(5)
                        Text("After 10 seconds").tag(10)
                        Text("After 30 seconds").tag(30)
                    }
                }
            } header: {
                Text("After Taking a Screenshot")
            } footer: {
                Text(feedbackFooter)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Play capture sound", isOn: $preferences.playSound)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section("Saving") {
                SaveLocationRow(preferences: preferences)
                TextField("File name prefix", text: $preferences.fileNamePrefix)
                LabeledContent("Example") {
                    Text(preferences.fileName(format: preferences.defaultFormat))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Picker("Format", selection: $preferences.defaultFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
                }
                if preferences.defaultFormat.supportsQuality {
                    LabeledContent("Quality") {
                        Slider(value: $preferences.jpegQuality, in: 0.1...1) {
                            Text("\(Int(preferences.jpegQuality * 100))%")
                        }
                    }
                }
                Toggle("Save Retina captures at 2×", isOn: $preferences.saveAtRetina)
            }
            Section("Capturing") {
                Toggle("Freeze screen while selecting", isOn: $preferences.freezeScreen)
                Toggle("Show magnifier", isOn: $preferences.showMagnifier)
                    .disabled(!preferences.freezeScreen)
                Toggle("Include window shadow", isOn: $preferences.includeWindowShadow)
            }
        }
        .formStyle(.grouped)
    }
}

/// Shows the save folder with a button to change it.
private struct SaveLocationRow: View {
    @Bindable var preferences: Preferences

    var body: some View {
        LabeledContent("Save to") {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: preferences.saveDirectory.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(displayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(preferences.saveDirectory.path)
                Button("Choose…", action: chooseFolder)
            }
        }
    }

    private var displayPath: String {
        (preferences.saveDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Clip saves screenshots"
        panel.directoryURL = preferences.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveDirectory = url
        }
    }
}

private struct ShortcutSettings: View {
    let app: AppState

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.displayName) {
                        HotKeyRecorder(hotKey: Binding(
                            get: { app.preferences.hotKeys[action] },
                            set: { newValue in
                                var hotKeys = app.preferences.hotKeys
                                if let newValue {
                                    // A shortcut can only be bound to one action.
                                    for (other, key) in hotKeys where key == newValue { hotKeys[other] = nil }
                                }
                                hotKeys[action] = newValue
                                app.preferences.hotKeys = hotKeys
                                app.registerHotKeys()
                            }))
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new key combination. Press ⌫ to clear, Esc to cancel.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") {
                    app.preferences.hotKeys = HotKey.defaults
                    app.registerHotKeys()
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click-to-record control for a global shortcut.
private struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press shortcut…" : (hotKey?.displayString ?? "None"))
                .monospaced()
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51 where modifiers.isEmpty: // Delete
                hotKey = nil
                stop()
            default:
                // Require at least one modifier other than Shift to avoid stealing typing keys.
                guard !modifiers.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }
                hotKey = HotKey(keyCode: Int(event.keyCode), modifiers: modifiers)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppState.shared.registerHotKeys()
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Clip").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .foregroundStyle(.secondary)
            Text("An open-source screenshot tool for macOS.\nMIT License.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}
