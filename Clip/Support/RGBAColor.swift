import AppKit
import SwiftUI

/// A Codable, Sendable color stored as sRGB components.
nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    func withAlpha(_ alpha: Double) -> RGBAColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// Relative luminance, used to pick a readable contrasting color.
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var contrasting: RGBAColor {
        luminance > 0.6 ? .black : .white
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// Annotation palette, loosely matching the system accent colors.
    static let palette: [RGBAColor] = [
        RGBAColor(hex: 0xFF3B30), // red
        RGBAColor(hex: 0xFF9500), // orange
        RGBAColor(hex: 0xFFCC00), // yellow
        RGBAColor(hex: 0x34C759), // green
        RGBAColor(hex: 0x007AFF), // blue
        RGBAColor(hex: 0xAF52DE), // purple
        RGBAColor(hex: 0xFF2D55), // pink
        .white,
        RGBAColor(hex: 0x1C1C1E), // near black
    ]
}
