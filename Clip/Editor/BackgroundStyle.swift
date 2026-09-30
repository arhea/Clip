import CoreGraphics
import Foundation

nonisolated enum BackgroundFill: Codable, Equatable, Hashable, Sendable {
    case solid(RGBAColor)
    /// Linear gradient from top-leading to bottom-trailing.
    case gradient(RGBAColor, RGBAColor)

    static let presets: [BackgroundFill] = [
        .gradient(RGBAColor(hex: 0xFF5F6D), RGBAColor(hex: 0xFFC371)),
        .gradient(RGBAColor(hex: 0x4776E6), RGBAColor(hex: 0x8E54E9)),
        .gradient(RGBAColor(hex: 0x00C6FB), RGBAColor(hex: 0x005BEA)),
        .gradient(RGBAColor(hex: 0x11998E), RGBAColor(hex: 0x38EF7D)),
        .gradient(RGBAColor(hex: 0xFC5C7D), RGBAColor(hex: 0x6A82FB)),
        .gradient(RGBAColor(hex: 0xF7971E), RGBAColor(hex: 0xFFD200)),
        .gradient(RGBAColor(hex: 0x834D9B), RGBAColor(hex: 0xD04ED6)),
        .gradient(RGBAColor(hex: 0x232526), RGBAColor(hex: 0x414345)),
        .gradient(RGBAColor(hex: 0xE0EAFC), RGBAColor(hex: 0xCFDEF3)),
        .gradient(RGBAColor(hex: 0xFBD3E9), RGBAColor(hex: 0xBB377D)),
        .solid(.white),
        .solid(RGBAColor(hex: 0xF2F2F7)),
        .solid(RGBAColor(hex: 0x1C1C1E)),
        .solid(RGBAColor(hex: 0x007AFF)),
    ]

    var colors: [RGBAColor] {
        switch self {
        case .solid(let color): [color, color]
        case .gradient(let a, let b): [a, b]
        }
    }
}

nonisolated enum BackgroundAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, square, fourThree, sixteenNine, sixteenTen, threeFour, nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .sixteenTen: "16:10"
        case .threeFour: "3:4"
        case .nineSixteen: "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        case .sixteenTen: 16.0 / 10
        case .threeFour: 3.0 / 4
        case .nineSixteen: 9.0 / 16
        }
    }
}

/// Nine-position alignment of the screenshot within the background.
nonisolated enum BackgroundAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    var id: String { rawValue }

    /// Unit anchor (0...1) with a top-left origin.
    var anchor: CGPoint {
        switch self {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topTrailing: CGPoint(x: 1, y: 0)
        case .leading: CGPoint(x: 0, y: 0.5)
        case .center: CGPoint(x: 0.5, y: 0.5)
        case .trailing: CGPoint(x: 1, y: 0.5)
        case .bottomLeading: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomTrailing: CGPoint(x: 1, y: 1)
        }
    }
}

/// The "background" treatment: a padded canvas behind the screenshot with shadow and rounded corners.
/// Lengths are in points and multiplied by the capture scale when rendering.
nonisolated struct BackgroundStyle: Codable, Equatable, Sendable {
    var isEnabled = false
    var fill: BackgroundFill = BackgroundFill.presets[1]
    var padding: CGFloat = 64
    var inset: CGFloat = 0
    var cornerRadius: CGFloat = 12
    var shadowRadius: CGFloat = 24
    var shadowOpacity: CGFloat = 0.35
    var aspect: BackgroundAspect = .auto
    var alignment: BackgroundAlignment = .center
}
