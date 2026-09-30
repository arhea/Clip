import AppKit
import Carbon.HIToolbox

/// Full-screen, multi-display picker for area and window captures.
///
/// One borderless window is placed on each screen. All of them share the state
/// held by this controller, so a selection or window highlight renders
/// consistently no matter which display the pointer is on.
final class SelectionOverlayController {
    enum Mode { case area, window }

    enum Selection {
        /// A rect in Cocoa global coordinates.
        case area(CGRect)
        case window(PickableWindow)
    }

    private(set) var mode: Mode
    private let frozenImages: [CGDirectDisplayID: CGImage]
    private let windows: [PickableWindow]
    private let showMagnifier: Bool
    private var overlayWindows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?

    // Shared interaction state, all in Cocoa global coordinates.
    fileprivate var mouseLocation: CGPoint = NSEvent.mouseLocation
    fileprivate var dragOrigin: CGPoint?
    fileprivate var selection: CGRect?
    fileprivate var hoveredWindow: PickableWindow?

    private init(mode: Mode, frozenImages: [CGDirectDisplayID: CGImage], windows: [PickableWindow], showMagnifier: Bool) {
        self.mode = mode
        self.frozenImages = frozenImages
        self.windows = windows
        self.showMagnifier = showMagnifier
    }

    /// Presents the overlay and returns the user's pick, or `nil` if cancelled.
    static func pick(mode: Mode, freeze: Bool, showMagnifier: Bool) async throws -> (Selection, [CGDirectDisplayID: CGImage])? {
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        if freeze {
            for screen in NSScreen.screens {
                frozen[screen.displayID] = try await ScreenCapturer.captureDisplay(screen.displayID)
            }
        }
        let controller = SelectionOverlayController(mode: mode, frozenImages: frozen,
                                                    windows: PickableWindow.onScreen(), showMagnifier: showMagnifier)
        guard let selection = await controller.run() else { return nil }
        return (selection, frozen)
    }

    private func run() async -> Selection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self, frozenImage: frozenImages[screen.displayID],
                                       showMagnifier: showMagnifier)
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        let active = overlayWindows.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? overlayWindows.first
        active?.makeKey()
        NSCursor.crosshair.push()
        updateHover()
        redraw()
    }

    private func finish(_ result: Selection?) {
        NSCursor.pop()
        for window in overlayWindows { window.orderOut(nil) }
        overlayWindows.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }

    // MARK: Events

    fileprivate func mouseMoved(to point: CGPoint) {
        mouseLocation = point
        updateHover()
        redraw()
    }

    fileprivate func mouseDown(at point: CGPoint) {
        mouseLocation = point
        if mode == .area { dragOrigin = point; selection = nil }
        redraw()
    }

    fileprivate func mouseDragged(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        mouseLocation = point
        guard mode == .area, let origin = dragOrigin else { return }
        var end = point
        if modifiers.contains(.shift) { end = end.squared(from: origin) }
        if modifiers.contains(.option) {
            let delta = end - origin
            selection = CGRect(from: origin - delta, to: origin + delta)
        } else {
            selection = CGRect(from: origin, to: end)
        }
        redraw()
    }

    fileprivate func mouseUp(at point: CGPoint) {
        mouseLocation = point
        switch mode {
        case .area:
            dragOrigin = nil
            if let selection, selection.width >= 2, selection.height >= 2 {
                finish(.area(selection))
            } else if let hoveredWindow = window(at: point) {
                // A click without a drag captures the window under the pointer.
                finish(.window(hoveredWindow))
            } else {
                selection = nil
                redraw()
            }
        case .window:
            if let hoveredWindow { finish(.window(hoveredWindow)) }
        }
    }

    fileprivate func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(nil)
        case kVK_Space where dragOrigin == nil:
            mode = mode == .area ? .window : .area
            selection = nil
            updateHover()
            redraw()
        case kVK_Return where selection != nil:
            finish(.area(selection!))
        default:
            break
        }
    }

    private func updateHover() {
        hoveredWindow = mode == .window ? window(at: mouseLocation) : nil
    }

    private func window(at point: CGPoint) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    private func redraw() {
        for window in overlayWindows { window.contentView?.needsDisplay = true }
    }

    // MARK: Drawing state for views

    fileprivate var highlightRect: CGRect? {
        switch mode {
        case .area: selection
        case .window: hoveredWindow?.frame
        }
    }

    fileprivate var isDragging: Bool { dragOrigin != nil }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, controller: SelectionOverlayController, frozenImage: CGImage?, showMagnifier: Bool) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = OverlayView(screen: screen, controller: controller, frozenImage: frozenImage, showMagnifier: showMagnifier)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    private let screenFrame: CGRect
    private let controller: SelectionOverlayController
    private let frozenImage: CGImage?
    private let showMagnifier: Bool

    init(screen: NSScreen, controller: SelectionOverlayController, frozenImage: CGImage?, showMagnifier: Bool) {
        self.screenFrame = screen.frame
        self.controller = controller
        self.frozenImage = frozenImage
        self.showMagnifier = showMagnifier
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private func global(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + screenFrame.minX, y: local.y + screenFrame.minY)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        controller.mouseMoved(to: global(event))
    }
    override func mouseDown(with event: NSEvent) { controller.mouseDown(at: global(event)) }
    override func mouseDragged(with event: NSEvent) { controller.mouseDragged(to: global(event), modifiers: event.modifierFlags) }
    override func mouseUp(with event: NSEvent) { controller.mouseUp(at: global(event)) }
    override func keyDown(with event: NSEvent) { controller.keyDown(event) }
    override func rightMouseDown(with event: NSEvent) { controller.keyDown(NSEvent.escapeKeyEvent) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let frozenImage {
            context.interpolationQuality = .high
            context.draw(frozenImage, in: bounds)
        }

        let highlight = controller.highlightRect.map(local)?.intersection(bounds)
        let dim = CGColor(gray: 0, alpha: 0.35)

        context.saveGState()
        context.setFillColor(dim)
        context.addRect(bounds)
        if let highlight, !highlight.isNull { context.addRect(highlight) }
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        if let highlight, !highlight.isNull, !highlight.isEmpty {
            if controller.mode == .window {
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                context.fill(highlight)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(3)
                context.stroke(highlight.insetBy(dx: 1.5, dy: 1.5))
            } else {
                context.setStrokeColor(.white)
                context.setLineWidth(1.5)
                context.stroke(highlight.insetBy(dx: 0.75, dy: 0.75))
            }
            drawSizeLabel(for: highlight, in: context)
        }

        let mouse = CGPoint(x: controller.mouseLocation.x - screenFrame.minX, y: controller.mouseLocation.y - screenFrame.minY)
        guard bounds.contains(mouse) else { return }
        if controller.mode == .area {
            if !controller.isDragging { drawCrosshair(at: mouse, in: context) }
            if showMagnifier, frozenImage != nil { drawMagnifier(at: mouse, in: context) }
        } else {
            drawHint("Click a window to capture it · Space for area · Esc to cancel", in: context)
        }
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        context.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private var pixelScale: CGFloat {
        guard let frozenImage else { return window?.backingScaleFactor ?? 2 }
        return CGFloat(frozenImage.width) / bounds.width
    }

    private func drawSizeLabel(for rect: CGRect, in context: CGContext) {
        let text = "\(Int((rect.width * pixelScale).rounded())) × \(Int((rect.height * pixelScale).rounded()))"
        var origin = CGPoint(x: rect.minX, y: rect.minY - 34)
        if origin.y < bounds.minY + 4 { origin.y = rect.minY + 6; origin.x += 6 }
        drawPill(text, at: origin)
    }

    private func drawHint(_ text: String, in context: CGContext) {
        let size = pillSize(text)
        drawPill(text, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40))
    }

    private var pillAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
    }

    private func pillSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: pillAttributes)
        return CGSize(width: size.width + 22, height: size.height + 12)
    }

    private func drawPill(_ text: String, at origin: CGPoint) {
        let size = pillSize(text)
        let rect = CGRect(origin: origin, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.set()
        NSColor(white: 0.08, alpha: 0.72).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 11, y: rect.minY + 6), withAttributes: pillAttributes)
    }

    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        guard let frozenImage else { return }
        let scale = pixelScale
        let samplePixels: CGFloat = 15
        let loupeSize: CGFloat = 120
        let px = (point.x * scale).rounded(.down)
        let py = ((bounds.height - point.y) * scale).rounded(.down)
        let sampleRect = CGRect(x: px - (samplePixels - 1) / 2, y: py - (samplePixels - 1) / 2, width: samplePixels, height: samplePixels)
        guard let sample = frozenImage.cropping(to: sampleRect) else { return }

        var loupeOrigin = CGPoint(x: point.x + 20, y: point.y - loupeSize - 20)
        if loupeOrigin.x + loupeSize > bounds.maxX { loupeOrigin.x = point.x - loupeSize - 20 }
        if loupeOrigin.y < bounds.minY { loupeOrigin.y = point.y + 20 }
        let loupe = CGRect(origin: loupeOrigin, size: CGSize(width: loupeSize, height: loupeSize))

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(.black)
        context.fillEllipse(in: loupe)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: loupe)
        context.clip()
        context.interpolationQuality = .none
        context.draw(sample, in: loupe)
        // Highlight the center pixel.
        let cell = loupeSize / samplePixels
        let centerCell = CGRect(x: loupe.midX - cell / 2, y: loupe.midY - cell / 2, width: cell, height: cell)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(centerCell)
        context.restoreGState()

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(2)
        context.strokeEllipse(in: loupe.insetBy(dx: 1, dy: 1))

        let coordinates = "\(Int(px)), \(Int(py))"
        let size = pillSize(coordinates)
        drawPill(coordinates, at: CGPoint(x: loupe.midX - size.width / 2, y: loupe.minY - size.height - 4))
    }
}

private extension NSEvent {
    static var escapeKeyEvent: NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                         keyCode: UInt16(kVK_Escape))!
    }
}
