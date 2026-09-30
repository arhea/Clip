import AppKit
import SwiftUI

/// Floating, always-on-top screenshots ("pins").
final class PinManager {
    private var panels: [PinPanel] = []

    var count: Int { panels.count }

    func pin(_ image: CGImage, scale: CGFloat) {
        let panel = PinPanel(image: image, scale: scale) { [weak self] panel in
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for panel in panels { panel.close() }
        panels.removeAll()
    }
}

final class PinPanel: NSPanel {
    private let image: CGImage
    private let imageScale: CGFloat
    private let onClose: (PinPanel) -> Void
    private let baseSize: CGSize
    private(set) var zoom: CGFloat = 1

    init(image: CGImage, scale: CGFloat, onClose: @escaping (PinPanel) -> Void) {
        self.image = image
        self.imageScale = scale
        self.onClose = onClose
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let visible = NSScreen.underMouse?.visibleFrame {
            let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
            size = size.scaled(by: fit)
        }
        self.baseSize = size
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size

        let view = PinImageView(frame: CGRect(origin: .zero, size: size))
        view.image = ImageExporter.nsImage(image, scale: scale)
        view.panel = self
        contentView = view

        if let screen = NSScreen.underMouse {
            let frame = screen.visibleFrame
            setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close() // Esc
        case 123: setFrameOrigin(frame.origin + CGPoint(x: -1, y: 0))
        case 124: setFrameOrigin(frame.origin + CGPoint(x: 1, y: 0))
        case 125: setFrameOrigin(frame.origin + CGPoint(x: 0, y: -1))
        case 126: setFrameOrigin(frame.origin + CGPoint(x: 0, y: 1))
        default:
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "w": close()
                case "c": copyImage()
                case "=", "+": setZoom(zoom * 1.2)
                case "-": setZoom(zoom / 1.2)
                case "0": setZoom(1)
                default: super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 0.2), 4)
        let center = frame.center
        let size = baseSize.scaled(by: zoom)
        setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                 display: true, animate: false)
    }

    func adjustOpacity(by delta: CGFloat) {
        alphaValue = min(1, max(0.2, alphaValue + delta))
    }

    func copyImage() {
        ImageExporter.copyToPasteboard(image, scale: imageScale)
        HUD.show("Copied to Clipboard", symbol: "doc.on.doc")
    }

    func toggleLock() {
        ignoresMouseEvents.toggle()
    }
}

private final class PinImageView: NSImageView {
    weak var panel: PinPanel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { panel?.close(); return }
        window?.performDrag(with: event)
    }

    /// Two-finger scroll adjusts opacity; ⌘-scroll zooms.
    override func scrollWheel(with event: NSEvent) {
        guard let panel else { return }
        if event.modifierFlags.contains(.command) {
            panel.setZoom(panel.zoom * (1 + event.scrollingDeltaY * 0.01))
        } else {
            panel.adjustOpacity(by: event.scrollingDeltaY * 0.005)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let panel else { return }
        panel.setZoom(panel.zoom * (1 + event.magnification))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0").target = self
        menu.addItem(.separator())
        let lock = menu.addItem(withTitle: "Lock (Click Through)", action: #selector(lock), keyEquivalent: "")
        lock.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() { panel?.copyImage() }
    @objc private func actualSize() { panel?.setZoom(1) }
    @objc private func lock() {
        panel?.toggleLock()
        HUD.show("Pin locked — close it from the menu bar", symbol: "lock")
    }
    @objc private func closePin() { panel?.close() }
}
