import CoreGraphics
import AppKit

nonisolated extension CGRect {
    /// A normalized rect spanning two points.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rounds the rect outward to whole pixels.
    var pixelAligned: CGRect {
        CGRect(x: floor(minX), y: floor(minY), width: ceil(maxX) - floor(minX), height: ceil(maxY) - floor(minY))
    }
}

nonisolated extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }

    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }

    /// Shortest distance from this point to the segment `a`–`b`.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Snaps `self` relative to `origin` to the nearest 45° angle (Shift-constrain for lines).
    func snapped45(from origin: CGPoint) -> CGPoint {
        let dx = x - origin.x, dy = y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Constrains `self` relative to `origin` so the spanned rect is square (Shift-constrain for shapes).
    func squared(from origin: CGPoint) -> CGPoint {
        let dx = x - origin.x, dy = y - origin.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }
}

nonisolated extension CGSize {
    var aspectRatio: CGFloat { height == 0 ? 1 : width / height }

    func scaled(by factor: CGFloat) -> CGSize { CGSize(width: width * factor, height: height * factor) }
}

/// Converts between AppKit's global screen space (origin bottom-left of the
/// primary display) and Quartz / ScreenCaptureKit global space (origin top-left).
enum ScreenSpace {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func quartzRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}
