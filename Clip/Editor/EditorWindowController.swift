import AppKit
import SwiftUI

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    private let onClose: (EditorDocument) -> Void

    init(document editorDocument: EditorDocument, actions: EditorActions, onClose: @escaping (EditorDocument) -> Void) {
        self.editorDocument = editorDocument
        self.onClose = onClose

        let hosting = NSHostingController(rootView: EditorView(document: editorDocument, actions: actions))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.title = "Clip — \(editorDocument.kind.displayName)"
        window.subtitle = editorDocument.createdAt.formatted(date: .abbreviated, time: .shortened)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = CGSize(width: 820, height: 480)

        // Size to the capture (at point size), within the visible screen.
        let screen = NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let imagePoints = CGSize(width: CGFloat(editorDocument.state.baseImage.width) / editorDocument.scale,
                                 height: CGFloat(editorDocument.state.baseImage.height) / editorDocument.scale)
        let width = min(max(imagePoints.width + 120, 980), visible.width * 0.9)
        let height = min(max(imagePoints.height + 200, 620), visible.height * 0.9)
        window.setFrame(CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: false)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose(editorDocument)
    }
}
