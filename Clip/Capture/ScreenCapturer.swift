import AppKit
@preconcurrency import ScreenCaptureKit

enum CaptureKind: String, Codable, Sendable {
    case area, window, fullscreen, allScreens, previousArea, imported

    var displayName: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .fullscreen: "Fullscreen"
        case .allScreens: "All Screens"
        case .previousArea: "Previous Area"
        case .imported: "Imported"
        }
    }
}

/// A finished capture: pixels plus the point-to-pixel scale they were taken at.
struct Capture {
    let image: CGImage
    let scale: CGFloat
    let kind: CaptureKind
    let date: Date

    init(image: CGImage, scale: CGFloat, kind: CaptureKind, date: Date = .now) {
        self.image = image
        self.scale = scale
        self.kind = kind
        self.date = date
    }

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Clip needs Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .displayNotFound: "The display could not be found."
        case .windowNotFound: "The window could not be found."
        case .emptySelection: "The selection is empty."
        }
    }
}

/// Thin wrapper over ScreenCaptureKit's still-image APIs.
///
/// Screen recording will later build on the same `SCContentFilter` construction
/// here, swapping `SCScreenshotManager` for an `SCStream`.
enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures an entire display at native resolution, excluding Clip's own windows.
    static func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = makeConfiguration(for: filter)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Captures a single window independent of what overlaps it, with a transparent background.
    static func captureWindow(_ windowID: CGWindowID, includeShadow: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = makeConfiguration(for: filter)
        configuration.ignoreShadowsSingleWindow = !includeShadow
        configuration.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func makeConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    /// Captures every display and stitches them into one image using their global layout.
    static func captureAllScreens() async throws -> Capture {
        let screens = NSScreen.screens
        let scale = screens.map(\.backingScaleFactor).max() ?? 2
        let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
        let width = Int(union.width * scale), height = Int(union.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.displayNotFound
        }
        context.interpolationQuality = .high
        for screen in screens {
            let image = try await captureDisplay(screen.displayID)
            // CGContext is bottom-left origin, like Cocoa screen coordinates.
            let rect = CGRect(x: (screen.frame.minX - union.minX) * scale,
                              y: (screen.frame.minY - union.minY) * scale,
                              width: screen.frame.width * scale,
                              height: screen.frame.height * scale)
            context.draw(image, in: rect)
        }
        guard let image = context.makeImage() else { throw CaptureError.displayNotFound }
        return Capture(image: image, scale: scale, kind: .allScreens)
    }

    /// Captures a rect in Cocoa global coordinates by cropping a display capture.
    static func captureRect(_ cocoaRect: CGRect, kind: CaptureKind) async throws -> Capture {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaRect) && $0.frame.contains(cocoaRect.center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(cocoaRect) }) else {
            throw CaptureError.displayNotFound
        }
        let image = try await captureDisplay(screen.displayID)
        let local = cocoaRect.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guard let cropped = crop(image, toLocalRect: local, screenSize: screen.frame.size) else {
            throw CaptureError.emptySelection
        }
        return Capture(image: cropped, scale: CGFloat(image.width) / screen.frame.width, kind: kind)
    }

    /// Crops a full-display image to a rect in the screen's local (bottom-left origin) point space.
    static func crop(_ image: CGImage, toLocalRect rect: CGRect, screenSize: CGSize) -> CGImage? {
        let scale = CGFloat(image.width) / screenSize.width
        let pixelRect = CGRect(x: rect.minX * scale,
                               y: (screenSize.height - rect.maxY) * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}

/// An on-screen window that can be picked in window-capture mode.
struct PickableWindow: Identifiable {
    let id: CGWindowID
    /// Frame in Cocoa global coordinates.
    let frame: CGRect
    let ownerName: String
    let title: String

    /// On-screen normal-level windows ordered front to back, excluding Clip's own.
    static func onScreen() -> [PickableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            return PickableWindow(id: id,
                                  frame: ScreenSpace.cocoaRect(fromQuartz: bounds),
                                  ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                  title: entry[kCGWindowName as String] as? String ?? "")
        }
    }
}
