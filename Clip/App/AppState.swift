import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Central coordinator: runs captures, records history, and owns app windows.
@Observable
final class AppState {
    static let shared = AppState()

    let preferences = Preferences.shared
    let history = HistoryStore()
    private(set) var isCapturing = false
    private(set) var hasPermission = ScreenCapturer.hasPermission

    @ObservationIgnored private var editors: [UUID: EditorWindowController] = [:]
    @ObservationIgnored private var historyWindow: NSWindow?
    @ObservationIgnored let quickAccess = QuickAccessManager()
    @ObservationIgnored let pins = PinManager()
    @ObservationIgnored let notifications = CaptureNotifications()

    private init() {}

    func start() {
        HotKeyCenter.shared.onTrigger = { [weak self] action in self?.perform(action) }
        registerHotKeys()
        startNotifications()
    }

    func registerHotKeys() {
        HotKeyCenter.shared.register(preferences.hotKeys)
    }

    func refreshPermission() {
        hasPermission = ScreenCapturer.hasPermission
    }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: captureArea()
        case .captureWindow: captureWindow()
        case .captureFullscreen: captureFullscreen()
        case .captureAllScreens: captureAllScreens()
        case .capturePreviousArea: capturePreviousArea()
        case .openHistory: showHistory()
        }
    }

    // MARK: Capture

    func captureArea() { runCapture { try await self.pick(.area) } }
    func captureWindow() { runCapture { try await self.pick(.window) } }

    func captureFullscreen(delay seconds: Int = 0) {
        runCapture {
            if seconds > 0 { try await self.countdown(seconds) }
            guard let screen = NSScreen.underMouse else { throw CaptureError.displayNotFound }
            let image = try await ScreenCapturer.captureDisplay(screen.displayID)
            return Capture(image: image, scale: CGFloat(image.width) / screen.frame.width, kind: .fullscreen)
        }
    }

    func captureAllScreens() {
        runCapture { try await ScreenCapturer.captureAllScreens() }
    }

    func capturePreviousArea() {
        guard let rect = preferences.previousArea else {
            captureArea()
            return
        }
        runCapture { try await ScreenCapturer.captureRect(rect, kind: .previousArea) }
    }

    /// Selects an area and copies the recognized text (OCR) to the clipboard.
    func captureText() {
        guard ensurePermission(), !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                guard let capture = try await pick(.area) else { return }
                let observations = try await RecognizeTextRequest().perform(on: capture.image)
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                guard !lines.isEmpty else {
                    HUD.show("No text found", symbol: "text.viewfinder")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                HUD.show("Copied \(lines.count) line\(lines.count == 1 ? "" : "s") of text", symbol: "text.viewfinder")
            } catch {
                present(error)
            }
        }
    }

    private func runCapture(_ body: @escaping () async throws -> Capture?) {
        guard ensurePermission(), !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                if let capture = try await body() { finish(capture) }
            } catch {
                present(error)
            }
        }
    }

    private func pick(_ mode: SelectionOverlayController.Mode) async throws -> Capture? {
        guard let (selection, frozen) = try await SelectionOverlayController.pick(
            mode: mode, freeze: preferences.freezeScreen, showMagnifier: preferences.showMagnifier) else { return nil }
        switch selection {
        case .area(let rect):
            preferences.previousArea = rect
            guard let screen = NSScreen.screens.max(by: { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }) else {
                throw CaptureError.displayNotFound
            }
            if let image = frozen[screen.displayID] {
                let local = rect.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                guard let cropped = ScreenCapturer.crop(image, toLocalRect: local, screenSize: screen.frame.size) else {
                    throw CaptureError.emptySelection
                }
                return Capture(image: cropped, scale: CGFloat(image.width) / screen.frame.width, kind: .area)
            }
            return try await ScreenCapturer.captureRect(rect.intersection(screen.frame), kind: .area)

        case .window(let window):
            let image = try await ScreenCapturer.captureWindow(window.id, includeShadow: preferences.includeWindowShadow)
            let screen = NSScreen.screens.first { $0.frame.contains(window.frame.center) } ?? NSScreen.main
            return Capture(image: image, scale: screen?.backingScaleFactor ?? 2, kind: .window)
        }
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    private func countdown(_ seconds: Int) async throws {
        for remaining in stride(from: seconds, to: 0, by: -1) {
            HUD.show("Capturing in \(remaining)…", symbol: "timer", duration: 0.9)
            try await Task.sleep(for: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func ensurePermission() -> Bool {
        refreshPermission()
        if hasPermission { return true }
        ScreenCapturer.requestPermission()
        refreshPermission()
        if !hasPermission {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Allow Clip in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to relaunch Clip."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { ScreenCapturer.openPermissionSettings() }
        }
        return hasPermission
    }

    private func present(_ error: Error) {
        if let captureError = error as? CaptureError, case .emptySelection = captureError { return }
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }

    // MARK: After capture

    private func finish(_ capture: Capture) {
        if preferences.playSound { Sound.shutter() }
        let item = history.add(capture)
        let feedback = preferences.captureFeedback
        let action = preferences.afterCapture
        // With a notification or overlay, the HUD would be redundant.
        let announce = feedback == .none
        var savedURL: URL?
        switch action {
        case .copyToClipboard: copy(item, announce: announce)
        case .saveToDisk: savedURL = save(item, announce: announce)
        case .openEditor: openEditor(item)
        }

        switch feedback {
        case .notification:
            Task {
                if await notifications.authorize() {
                    await notifications.post(for: item, action: action, savedURL: savedURL,
                                             thumbnail: history.thumbnailURL(for: item.id))
                } else if action != .openEditor {
                    // Notifications are off for Clip; fall back so the actions stay reachable.
                    quickAccess.show(item)
                }
            }
        case .quickAccess:
            if action != .openEditor { quickAccess.show(item) }
        case .none:
            break
        }
    }

    private func startNotifications() {
        notifications.start()
        notifications.onEdit = { [weak self] id in self?.withItem(id) { self?.openEditor($0) } }
        notifications.onSave = { [weak self] id in self?.withItem(id) { self?.save($0) } }
        notifications.onCopy = { [weak self] id in self?.withItem(id) { self?.copy($0) } }
        notifications.onReveal = { [weak self] id in self?.withItem(id) { self?.revealInFinder($0) } }
        // Ask up front so the permission prompt doesn't interrupt the first capture.
        if preferences.captureFeedback == .notification {
            Task { _ = await notifications.authorize() }
        }
    }

    private func withItem(_ id: UUID, _ body: (HistoryItem) -> Void) {
        guard let item = history.items.first(where: { $0.id == id }) else {
            HUD.show("That capture is no longer in history", symbol: "exclamationmark.triangle")
            return
        }
        body(item)
    }

    /// The image to export for a history item, honoring the Retina preference.
    func outputImage(for item: HistoryItem) -> (CGImage, CGFloat)? {
        guard let image = history.renderedImage(for: item) else { return nil }
        if !preferences.saveAtRetina, item.scale > 1,
           let small = ImageExporter.resize(image, to: CGSize(width: CGFloat(image.width) / item.scale, height: CGFloat(image.height) / item.scale)) {
            return (small, 1)
        }
        return (image, item.scale)
    }

    func copy(_ item: HistoryItem, announce: Bool = true) {
        guard let (image, scale) = outputImage(for: item) else { return }
        ImageExporter.copyToPasteboard(image, scale: scale)
        if announce { HUD.show("Copied to Clipboard", symbol: "doc.on.doc") }
    }

    @discardableResult
    func save(_ item: HistoryItem, announce: Bool = true) -> URL? {
        guard let (image, scale) = outputImage(for: item) else { return nil }
        let format = preferences.defaultFormat
        do {
            let url = ImageExporter.uniqueURL(try preferences.ensureSaveDirectory().appending(path: preferences.fileName(for: item.date, format: format)))
            try ImageExporter.write(image, to: url, format: format, quality: preferences.jpegQuality, scale: scale)
            history.markSaved(item.id, at: url)
            if announce { HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle") }
            return url
        } catch {
            present(error)
            return nil
        }
    }

    func saveAs(_ item: HistoryItem) {
        guard let (image, scale) = outputImage(for: item) else { return }
        let format = preferences.defaultFormat
        presentSavePanel(defaultName: preferences.fileName(for: item.date, format: format), format: format) { url, format in
            try ImageExporter.write(image, to: url, format: format, quality: self.preferences.jpegQuality, scale: scale)
            self.history.markSaved(item.id, at: url)
        }
    }

    func pin(_ item: HistoryItem) {
        guard let (image, scale) = outputImage(for: item) else { return }
        pins.pin(image, scale: scale)
    }

    func dragFile(for item: HistoryItem) -> URL? {
        guard let (image, scale) = outputImage(for: item) else { return nil }
        let format = preferences.defaultFormat
        return ImageExporter.temporaryFile(image, name: preferences.fileName(for: item.date, format: format), format: format,
                                           quality: preferences.jpegQuality, scale: scale)
    }

    func delete(_ item: HistoryItem) {
        quickAccess.dismiss(item.id)
        notifications.remove(item.id)
        editors.values.first { $0.editorDocument.historyID == item.id }?.window?.close()
        history.delete(item.id)
    }

    func revealInFinder(_ item: HistoryItem) {
        let url = item.savedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? history.originalURL(for: item.id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func presentSavePanel(defaultName: String, format: ImageFormat, write: @escaping (URL, ImageFormat) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = (try? preferences.ensureSaveDirectory()) ?? preferences.saveDirectory
        panel.allowedContentTypes = [ImageExporter.utType(for: format)]
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(url, format)
                HUD.show("Saved \(url.lastPathComponent)", symbol: "checkmark.circle")
            } catch {
                self.present(error)
            }
        }
    }

    // MARK: Editor

    func openEditor(_ item: HistoryItem) {
        quickAccess.dismiss(item.id)
        if let existing = editors.values.first(where: { $0.editorDocument.historyID == item.id }) {
            existing.showWindow(nil)
            NSApp.activate()
            return
        }
        guard let capture = history.capture(for: item) else { return }
        let document = EditorDocument(capture: capture, historyID: item.id, project: history.project(for: item))
        openEditor(document)
    }

    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(at: url)
    }

    /// Imports an image file into history and opens it in the editor.
    func openImage(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let item = history.add(Capture(image: image, scale: max(1, dpi / 72), kind: .imported))
        openEditor(item)
    }

    private func openEditor(_ document: EditorDocument) {
        let actions = EditorActions(
            copy: { [weak self] in self?.copy($0) },
            save: { [weak self] in self?.save($0) },
            saveAs: { [weak self] in self?.saveAs($0) },
            pin: { [weak self] document in
                guard let image = document.exportImage() else { return }
                self?.pins.pin(image, scale: document.exportScale)
            },
            close: { [weak self] in self?.editors[document.id]?.window?.performClose(nil) }
        )
        let controller = EditorWindowController(document: document, actions: actions) { [weak self] document in
            self?.persist(document)
            self?.editors[document.id] = nil
        }
        editors[document.id] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Saves non-destructive edits back to history so reopening restores them.
    func persist(_ document: EditorDocument) {
        guard let id = document.historyID, document.isDirty else { return }
        document.finishTextEditing()
        history.updateProject(id, project: document.state.project, baseImage: document.state.baseImage,
                              baseChanged: document.state.baseImage !== document.initialImage,
                              rendered: document.renderedImage())
        document.isDirty = false
    }

    private func copy(_ document: EditorDocument) {
        guard let image = document.exportImage() else { return }
        ImageExporter.copyToPasteboard(image, scale: document.exportScale)
        persist(document)
        HUD.show("Copied to Clipboard", symbol: "doc.on.doc")
    }

    private func save(_ document: EditorDocument) {
        guard let image = document.exportImage() else { return }
        let format = document.export.format
        do {
            let url = ImageExporter.uniqueURL(try preferences.ensureSaveDirectory().appending(path: preferences.fileName(for: document.createdAt, format: format)))
            try ImageExporter.write(image, to: url, format: format, quality: document.export.quality, scale: document.exportScale)
            if let id = document.historyID { history.markSaved(id, at: url) }
            persist(document)
            HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle")
        } catch {
            present(error)
        }
    }

    private func saveAs(_ document: EditorDocument) {
        guard let image = document.exportImage() else { return }
        let format = document.export.format
        presentSavePanel(defaultName: preferences.fileName(for: document.createdAt, format: format), format: format) { url, format in
            try ImageExporter.write(image, to: url, format: format, quality: document.export.quality, scale: document.exportScale)
            if let id = document.historyID { self.history.markSaved(id, at: url) }
            self.persist(document)
        }
    }

    // MARK: History window

    func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Capture History"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HistoryView(app: self))
            window.setContentSize(CGSize(width: 880, height: 600))
            window.center()
            window.setFrameAutosaveName("ClipHistoryWindow")
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum Sound {
    private static let shutterPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
    @MainActor private static var shutterSound = NSSound(contentsOfFile: shutterPath, byReference: true)

    static func shutter() {
        if let sound = shutterSound {
            sound.stop()
            sound.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }
}
