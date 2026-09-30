import CoreGraphics
import Foundation

enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, filledRectangle, ellipse, text, pen, highlighter, counter, redact, spotlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .crop: "Crop"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .pen: "Draw"
        case .highlighter: "Highlighter"
        case .counter: "Counter"
        case .redact: "Blur / Pixelate"
        case .spotlight: "Spotlight"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .redact: "eye.slash"
        case .spotlight: "flashlight.on.fill"
        }
    }

    /// Single-key shortcut for selecting the tool in the editor.
    var shortcut: Character {
        switch self {
        case .select: "v"
        case .crop: "k"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "e"
        case .text: "t"
        case .pen: "d"
        case .highlighter: "m"
        case .counter: "c"
        case .redact: "p"
        case .spotlight: "h"
        }
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: nil
        case .arrow: .arrow
        case .line: .line
        case .rectangle, .filledRectangle: .rectangle
        case .ellipse: .ellipse
        case .text: .text
        case .pen: .pen
        case .highlighter: .highlighter
        case .counter: .counter
        case .redact: .redact
        case .spotlight: .spotlight
        }
    }

    var usesColor: Bool {
        switch self {
        case .select, .crop, .redact, .spotlight: false
        default: true
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter: true
        default: false
        }
    }
}

nonisolated enum AnnotationKind: String, Codable, Sendable {
    case arrow, line, rectangle, ellipse, text, pen, highlighter, counter, redact, spotlight

    /// Kinds defined by a start/end drag that can be resized from corner handles.
    var isBoxed: Bool {
        switch self {
        case .rectangle, .ellipse, .redact, .spotlight: true
        default: false
        }
    }

    var isLinear: Bool { self == .arrow || self == .line }
    var isFreehand: Bool { self == .pen || self == .highlighter }
}

nonisolated enum ArrowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case tapered, classic, filled, double

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tapered: "Tapered"
        case .classic: "Classic"
        case .filled: "Filled Head"
        case .double: "Double-Headed"
        }
    }
}

nonisolated enum TextStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain, outlined, background, rounded

    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: "Plain"
        case .outlined: "Outlined"
        case .background: "Background"
        case .rounded: "Pill"
        }
    }
}

nonisolated enum RedactStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case pixelate, blur, blackout

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .blackout: "Black Out"
        }
    }
}

nonisolated struct AnnotationStyle: Codable, Equatable, Sendable {
    var color: RGBAColor = RGBAColor.palette[0]
    /// Stroke width in image pixels.
    var lineWidth: CGFloat = 8
    var filled = false
    var arrowStyle: ArrowStyle = .tapered
    var textStyle: TextStyle = .outlined
    /// Font size in image pixels.
    var fontSize: CGFloat = 48
    var redactStyle: RedactStyle = .pixelate
}

/// One vector annotation. All geometry is in base-image pixel space (top-left origin),
/// so annotations stay sharp and editable regardless of zoom, crop, or background.
nonisolated struct Annotation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 1
    var style: AnnotationStyle

    var rect: CGRect { CGRect(from: start, to: end) }

    mutating func offset(by delta: CGPoint) {
        start = start + delta
        end = end + delta
        points = points.map { $0 + delta }
    }

    /// Applies an affine transform to every point (used for rotate/flip).
    mutating func apply(_ transform: CGAffineTransform) {
        start = start.applying(transform)
        end = end.applying(transform)
        points = points.map { $0.applying(transform) }
    }
}
