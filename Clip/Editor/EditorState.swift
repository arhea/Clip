import CoreGraphics
import Foundation

/// The undoable part of an editor document.
struct EditorState: Equatable {
    var baseImage: CGImage
    var annotations: [Annotation] = []
    /// Crop in base-image pixel space; `nil` means uncropped.
    var crop: CGRect?
    var background = BackgroundStyle()

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height) }

    var effectiveCrop: CGRect {
        guard let crop else { return imageRect }
        let clipped = crop.intersection(imageRect)
        return clipped.isEmpty ? imageRect : clipped
    }

    static func == (lhs: EditorState, rhs: EditorState) -> Bool {
        lhs.baseImage === rhs.baseImage && lhs.annotations == rhs.annotations && lhs.crop == rhs.crop && lhs.background == rhs.background
    }

    var project: EditorProject {
        EditorProject(annotations: annotations, crop: crop, background: background)
    }
}

/// The serializable, non-destructive edits saved alongside a history item.
nonisolated struct EditorProject: Codable, Sendable {
    var annotations: [Annotation]
    var crop: CGRect?
    var background: BackgroundStyle
}

/// Where the (cropped) screenshot sits on the output canvas.
struct RenderLayout {
    /// Output canvas size in pixels.
    var canvasSize: CGSize
    /// The screenshot's frame on the canvas, in canvas pixels.
    var imageFrame: CGRect
    /// Maps base-image pixel space to canvas pixel space.
    var transform: CGAffineTransform
    /// The portion of the base image being shown, in base-image pixels.
    var sourceRect: CGRect

    static func make(for state: EditorState, scale: CGFloat, includeBackground: Bool, applyCrop: Bool) -> RenderLayout {
        let source = applyCrop ? state.effectiveCrop : state.imageRect
        let background = state.background
        guard includeBackground, background.isEnabled else {
            return RenderLayout(canvasSize: source.size,
                                imageFrame: CGRect(origin: .zero, size: source.size),
                                transform: CGAffineTransform(translationX: -source.minX, y: -source.minY),
                                sourceRect: source)
        }
        let padding = max(0, background.padding * scale)
        var canvas = CGSize(width: source.width + padding * 2, height: source.height + padding * 2)
        if let ratio = background.aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let free = CGSize(width: canvas.width - padding * 2 - source.width, height: canvas.height - padding * 2 - source.height)
        let anchor = background.alignment.anchor
        let frame = CGRect(x: padding + free.width * anchor.x, y: padding + free.height * anchor.y,
                           width: source.width, height: source.height)

        let inset = min(max(0, background.inset * scale), min(source.width, source.height) / 4)
        let k = min((frame.width - inset * 2) / frame.width, (frame.height - inset * 2) / frame.height)
        let transform = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -source.midX, y: -source.midY)
        return RenderLayout(canvasSize: canvas, imageFrame: frame, transform: transform, sourceRect: source)
    }
}
