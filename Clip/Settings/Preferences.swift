import AppKit
import Observation

enum ImageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png, jpeg, heic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    var supportsQuality: Bool { self != .png }
}

/// How Clip confirms a capture and offers the actions you didn't pick by default.
enum CaptureFeedback: String, Codable, CaseIterable, Identifiable {
    case notification
    case quickAccess
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notification: "Notification"
        case .quickAccess: "Quick Access overlay"
        case .none: "Nothing"
        }
    }
}

/// What happens automatically when a screenshot is taken.
enum AfterCaptureAction: String, Codable, CaseIterable, Identifiable {
    case copyToClipboard
    case openEditor
    case saveToDisk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copyToClipboard: "Copy to clipboard"
        case .openEditor: "Open in editor"
        case .saveToDisk: "Save to disk"
        }
    }
}

enum HotKeyAction: String, Codable, CaseIterable, Identifiable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureAllScreens
    case capturePreviousArea
    case openHistory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureAllScreens: "Capture All Screens"
        case .capturePreviousArea: "Capture Previous Area"
        case .openHistory: "Open Capture History"
        }
    }
}

/// App-wide user preferences, persisted to `UserDefaults`.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    var afterCapture: AfterCaptureAction { didSet { save(afterCapture.rawValue, "afterCapture") } }
    var captureFeedback: CaptureFeedback { didSet { save(captureFeedback.rawValue, "captureFeedback") } }
    var saveDirectory: URL { didSet { defaults.set(saveDirectory.path, forKey: "saveDirectory") } }
    var fileNamePrefix: String { didSet { save(fileNamePrefix, "fileNamePrefix") } }
    var defaultFormat: ImageFormat { didSet { save(defaultFormat.rawValue, "defaultFormat") } }
    var jpegQuality: Double { didSet { save(jpegQuality, "jpegQuality") } }
    var includeWindowShadow: Bool { didSet { save(includeWindowShadow, "includeWindowShadow") } }
    var freezeScreen: Bool { didSet { save(freezeScreen, "freezeScreen") } }
    var showMagnifier: Bool { didSet { save(showMagnifier, "showMagnifier") } }
    var playSound: Bool { didSet { save(playSound, "playSound") } }
    var saveAtRetina: Bool { didSet { save(saveAtRetina, "saveAtRetina") } }
    var quickAccessAutoCloseSeconds: Int { didSet { save(quickAccessAutoCloseSeconds, "quickAccessAutoCloseSeconds") } }
    var hotKeys: [HotKeyAction: HotKey] {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeys) { defaults.set(data, forKey: "hotKeys") }
        }
    }
    /// Last selected area in Cocoa global coordinates, used by "Capture Previous Area".
    var previousArea: CGRect? {
        didSet {
            if let previousArea { defaults.set(NSStringFromRect(previousArea), forKey: "previousArea") }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "afterCapture").flatMap(AfterCaptureAction.init(rawValue:)) {
            afterCapture = stored
        } else {
            // Migrate from the earlier multi-select setting.
            let legacy = defaults.stringArray(forKey: "afterCaptureActions") ?? []
            afterCapture = legacy.contains("openEditor") ? .openEditor : legacy.contains("saveToDisk") ? .saveToDisk : .copyToClipboard
        }
        captureFeedback = defaults.string(forKey: "captureFeedback").flatMap(CaptureFeedback.init(rawValue:)) ?? .notification
        saveDirectory = defaults.string(forKey: "saveDirectory").map { URL(filePath: $0) } ?? Self.defaultSaveDirectory
        fileNamePrefix = defaults.string(forKey: "fileNamePrefix") ?? "Clip"
        defaultFormat = defaults.string(forKey: "defaultFormat").flatMap(ImageFormat.init(rawValue:)) ?? .png
        jpegQuality = defaults.object(forKey: "jpegQuality") as? Double ?? 0.85
        includeWindowShadow = defaults.object(forKey: "includeWindowShadow") as? Bool ?? true
        freezeScreen = defaults.object(forKey: "freezeScreen") as? Bool ?? true
        showMagnifier = defaults.object(forKey: "showMagnifier") as? Bool ?? true
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        saveAtRetina = defaults.object(forKey: "saveAtRetina") as? Bool ?? true
        quickAccessAutoCloseSeconds = defaults.object(forKey: "quickAccessAutoCloseSeconds") as? Int ?? 0
        if let data = defaults.data(forKey: "hotKeys"), let decoded = try? JSONDecoder().decode([HotKeyAction: HotKey].self, from: data) {
            hotKeys = decoded
        } else {
            hotKeys = HotKey.defaults
        }
        if let stored = defaults.string(forKey: "previousArea") {
            let rect = NSRectFromString(stored)
            previousArea = rect.isEmpty ? nil : rect
        } else {
            previousArea = nil
        }
    }

    /// `~/Documents/ClipScreenshots`, created on first save.
    static var defaultSaveDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Documents")
        return documents.appending(path: "ClipScreenshots", directoryHint: .isDirectory)
    }

    /// The save folder, created if it doesn't exist yet.
    func ensureSaveDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        return saveDirectory
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// A timestamped file name, e.g. `Clip 2026-09-30 at 14.53.12.png`.
    func fileName(for date: Date = .now, format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let prefix = fileNamePrefix.trimmingCharacters(in: .whitespaces)
        let stamp = formatter.string(from: date)
        return "\(prefix.isEmpty ? "" : prefix + " ")\(stamp).\(format.fileExtension)"
    }
}
