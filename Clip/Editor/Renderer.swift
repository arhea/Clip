import AppKit
import CoreImage

/// Caches expensive derived images (pixelated/blurred copies of the base image).
final class RenderCache {
    private weak var source: CGImage?
    private var pixelated: CGImage?
    private var blurred: CGImage?
    private var edgeColor: CGColor?
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func reset(for image: CGImage) {
        guard source !== image else { return }
        source = image
        pixelated = nil
        blurred = nil
        edgeColor = nil
    }

    func pixelated(_ image: CGImage) -> CGImage? {
        reset(for: image)
        if let pixelated { return pixelated }
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(max(16, CGFloat(max(image.width, image.height)) / 55), forKey: kCIInputScaleKey)
        filter?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        pixelated = filter?.outputImage.flatMap { context.createCGImage($0, from: input.extent) }
        return pixelated
    }

    func blurred(_ image: CGImage) -> CGImage? {
        reset(for: image)
        if let blurred { return blurred }
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(max(12, CGFloat(image.width) / 70), forKey: kCIInputRadiusKey)
        blurred = filter?.outputImage.flatMap { context.createCGImage($0, from: input.extent) }
        return blurred
    }

    /// The color of the top-left pixel, used to fill the background "inset".
    func edgeColor(_ image: CGImage, source rect: CGRect) -> CGColor {
        reset(for: image)
        if let edgeColor { return edgeColor }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let color = pixel.withUnsafeMutableBytes { buffer -> CGColor in
            guard let sample = image.cropping(to: CGRect(x: rect.minX, y: rect.minY, width: 1, height: 1)),
                  let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
            ctx.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let b = buffer.bindMemory(to: UInt8.self)
            return CGColor(srgbRed: CGFloat(b[0]) / 255, green: CGFloat(b[1]) / 255, blue: CGFloat(b[2]) / 255, alpha: 1)
        }
        edgeColor = color
        return color
    }
}

/// Draws an editor document. Used both for the live canvas (SwiftUI `Canvas`) and
/// for export, so the preview always matches the saved file. The target context
/// must have a top-left origin (y pointing down) in canvas pixel units.
enum Renderer {
    struct Options {
        var includeBackground = true
        var applyCrop = true
        /// An annotation to skip (e.g. while its text is being edited in place).
        var hiddenAnnotation: UUID?
    }

    static func draw(_ state: EditorState, layout: RenderLayout, scale: CGFloat, options: Options, cache: RenderCache, in ctx: CGContext) {
        let background = state.background
        let showsBackground = options.includeBackground && background.isEnabled
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)

        if showsBackground {
            drawFill(background.fill, in: canvasRect, ctx: ctx)
        }

        let radius = showsBackground ? max(0, background.cornerRadius * scale) : 0
        let framePath = CGPath(roundedRect: layout.imageFrame, cornerWidth: min(radius, layout.imageFrame.width / 2),
                               cornerHeight: min(radius, layout.imageFrame.height / 2), transform: nil)

        ctx.saveGState()
        if showsBackground, background.shadowOpacity > 0, background.shadowRadius > 0 {
            ctx.setShadow(offset: .zero, blur: background.shadowRadius * scale,
                          color: CGColor(gray: 0, alpha: background.shadowOpacity))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(framePath)
        ctx.clip()
        if showsBackground, background.inset > 0 {
            ctx.setFillColor(cache.edgeColor(state.baseImage, source: layout.sourceRect))
            ctx.fill(layout.imageFrame)
        }
        ctx.concatenate(layout.transform)
        drawImage(state.baseImage, in: state.imageRect, ctx: ctx)
        for annotation in state.annotations where annotation.kind == .redact {
            drawRedaction(annotation, base: state.baseImage, cache: cache, ctx: ctx)
        }
        let spotlights = state.annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            drawSpotlight(spotlights, in: layout.sourceRect, scale: scale, ctx: ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.concatenate(layout.transform)
        for annotation in state.annotations where annotation.id != options.hiddenAnnotation {
            switch annotation.kind {
            case .redact, .spotlight: continue
            default: drawAnnotation(annotation, scale: scale, ctx: ctx)
            }
        }
        ctx.restoreGState()
    }

    /// Renders the finished image at its natural pixel size.
    static func renderImage(_ state: EditorState, scale: CGFloat, cache: RenderCache = RenderCache()) -> CGImage? {
        let layout = RenderLayout.make(for: state, scale: scale, includeBackground: true, applyCrop: true)
        let width = Int(layout.canvasSize.width.rounded()), height = Int(layout.canvasSize.height.rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(state, layout: layout, scale: scale, options: Options(), cache: cache, in: ctx)
        return ctx.makeImage()
    }

    // MARK: Primitives

    /// Draws a CGImage right side up in a flipped (top-left origin) context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    static func drawFill(_ fill: BackgroundFill, in rect: CGRect, ctx: CGContext) {
        switch fill {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let a, let b):
            let colors = [a.cgColor, b.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    private static func drawRedaction(_ annotation: Annotation, base: CGImage, cache: RenderCache, ctx: CGContext) {
        let rect = annotation.rect
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        switch annotation.style.redactStyle {
        case .pixelate:
            if let image = cache.pixelated(base) { drawImage(image, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), ctx: ctx) }
        case .blur:
            if let image = cache.blurred(base) { drawImage(image, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), ctx: ctx) }
        case .blackout:
            ctx.setFillColor(.black)
            ctx.fill(rect)
        }
        ctx.restoreGState()
    }

    private static func drawSpotlight(_ spotlights: [Annotation], in source: CGRect, scale: CGFloat, ctx: CGContext) {
        let path = CGMutablePath()
        path.addRect(source.insetBy(dx: -2, dy: -2))
        for spotlight in spotlights where spotlight.rect.width > 1 && spotlight.rect.height > 1 {
            let radius = min(8 * scale, spotlight.rect.width / 2, spotlight.rect.height / 2)
            path.addRoundedRect(in: spotlight.rect, cornerWidth: radius, cornerHeight: radius)
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    static func drawAnnotation(_ annotation: Annotation, scale: CGFloat, ctx: CGContext) {
        let style = annotation.style
        let color = style.color.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if annotation.kind != .highlighter {
            ctx.setShadow(offset: .zero, blur: 2 * scale, color: CGColor(gray: 0, alpha: 0.25))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch annotation.kind {
        case .line:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.lineWidth)
            ctx.move(to: annotation.start)
            ctx.addLine(to: annotation.end)
            ctx.strokePath()

        case .arrow:
            drawArrow(annotation, ctx: ctx)

        case .rectangle:
            let rect = annotation.rect
            let radius = min(style.lineWidth * 0.75, rect.width / 2, rect.height / 2)
            if style.filled {
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else {
                let inset = rect.insetBy(dx: min(style.lineWidth / 2, rect.width / 2), dy: min(style.lineWidth / 2, rect.height / 2))
                ctx.setStrokeColor(color)
                ctx.setLineWidth(style.lineWidth)
                ctx.addPath(CGPath(roundedRect: inset, cornerWidth: min(radius, inset.width / 2), cornerHeight: min(radius, inset.height / 2), transform: nil))
                ctx.strokePath()
            }

        case .ellipse:
            let rect = annotation.rect
            if style.filled {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(style.lineWidth)
                ctx.strokeEllipse(in: rect.insetBy(dx: min(style.lineWidth / 2, rect.width / 2), dy: min(style.lineWidth / 2, rect.height / 2)))
            }

        case .pen:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.lineWidth)
            ctx.addPath(smoothPath(annotation.points))
            ctx.strokePath()

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(style.color.withAlpha(0.45).cgColor)
            ctx.setLineWidth(style.lineWidth * 3)
            ctx.setLineCap(.butt)
            ctx.addPath(smoothPath(annotation.points))
            ctx.strokePath()

        case .counter:
            let radius = counterRadius(style)
            let circle = CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(2, radius * 0.08))
            ctx.strokeEllipse(in: circle.insetBy(dx: radius * 0.04, dy: radius * 0.04))
            let text = NSAttributedString(string: "\(annotation.number)", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.1, weight: .bold),
                .foregroundColor: style.color.contrasting.nsColor,
            ])
            let size = text.size()
            drawText(text, in: CGRect(x: annotation.start.x - size.width / 2, y: annotation.start.y - size.height / 2,
                                      width: size.width, height: size.height), ctx: ctx)

        case .text:
            drawTextAnnotation(annotation, ctx: ctx)

        case .redact, .spotlight:
            break
        }
    }

    // MARK: Arrows

    private static func drawArrow(_ annotation: Annotation, ctx: CGContext) {
        let style = annotation.style
        let start = annotation.start, end = annotation.end
        let length = start.distance(to: end)
        guard length > 1 else { return }
        // Arrows read heavier than other strokes at the same width.
        let width = style.lineWidth * Self.arrowWeight
        let headLength = min(width * 2.8, length * 0.5)
        let headWidth = headLength * 1.05

        ctx.saveGState()
        ctx.translateBy(x: start.x, y: start.y)
        ctx.rotate(by: atan2(end.y - start.y, end.x - start.x))
        ctx.setFillColor(style.color.cgColor)
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(width)

        switch style.arrowStyle {
        case .tapered:
            let tail = max(1, width * 0.45)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -tail / 2))
            path.addLine(to: CGPoint(x: length - headLength * 0.85, y: -width / 2))
            path.addLine(to: CGPoint(x: length - headLength, y: -headWidth / 2))
            path.addLine(to: CGPoint(x: length, y: 0))
            path.addLine(to: CGPoint(x: length - headLength, y: headWidth / 2))
            path.addLine(to: CGPoint(x: length - headLength * 0.85, y: width / 2))
            path.addLine(to: CGPoint(x: 0, y: tail / 2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()

        case .classic:
            let back = headLength * 0.9
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: length, y: 0))
            ctx.move(to: CGPoint(x: length - back, y: -headWidth / 2))
            ctx.addLine(to: CGPoint(x: length, y: 0))
            ctx.addLine(to: CGPoint(x: length - back, y: headWidth / 2))
            ctx.strokePath()

        case .filled, .double:
            let hasTail = style.arrowStyle == .double
            ctx.move(to: CGPoint(x: hasTail ? headLength * 0.9 : 0, y: 0))
            ctx.addLine(to: CGPoint(x: length - headLength * 0.9, y: 0))
            ctx.strokePath()
            fillHead(at: length, pointingForward: true, length: headLength, width: headWidth, ctx: ctx)
            if hasTail { fillHead(at: 0, pointingForward: false, length: headLength, width: headWidth, ctx: ctx) }
        }
        ctx.restoreGState()
    }

    private static func fillHead(at x: CGFloat, pointingForward: Bool, length: CGFloat, width: CGFloat, ctx: CGContext) {
        let direction: CGFloat = pointingForward ? -1 : 1
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x + direction * length, y: -width / 2))
        ctx.addLine(to: CGPoint(x: x + direction * length, y: width / 2))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Freehand

    /// Smooths a polyline with quadratic curves through segment midpoints.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.last ?? first)
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: Text

    /// How much thicker an arrow's shaft is than its style's line width.
    static let arrowWeight: CGFloat = 2.2

    static func counterRadius(_ style: AnnotationStyle) -> CGFloat {
        style.fontSize * 0.6
    }

    static func textAttributes(_ style: AnnotationStyle) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        switch style.textStyle {
        case .plain:
            return [.font: font, .foregroundColor: style.color.nsColor]
        case .outlined:
            return [.font: font, .foregroundColor: style.color.nsColor]
        case .background, .rounded:
            return [.font: font, .foregroundColor: style.color.contrasting.nsColor]
        }
    }

    static func textPadding(_ style: AnnotationStyle) -> CGSize {
        switch style.textStyle {
        case .plain, .outlined: CGSize(width: style.fontSize * 0.1, height: 0)
        case .background: CGSize(width: style.fontSize * 0.3, height: style.fontSize * 0.15)
        case .rounded: CGSize(width: style.fontSize * 0.55, height: style.fontSize * 0.2)
        }
    }

    /// The frame of a text annotation, anchored at its start point (top-left).
    static func textFrame(_ annotation: Annotation) -> CGRect {
        let string = annotation.text.isEmpty ? " " : annotation.text
        let size = NSAttributedString(string: string, attributes: textAttributes(annotation.style))
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let padding = textPadding(annotation.style)
        return CGRect(x: annotation.start.x, y: annotation.start.y,
                      width: ceil(size.width) + padding.width * 2, height: ceil(size.height) + padding.height * 2)
    }

    private static func drawTextAnnotation(_ annotation: Annotation, ctx: CGContext) {
        guard !annotation.text.isEmpty else { return }
        let style = annotation.style
        let frame = textFrame(annotation)
        let padding = textPadding(style)
        switch style.textStyle {
        case .background, .rounded:
            let radius = style.textStyle == .rounded ? frame.height / 2 : style.fontSize * 0.18
            ctx.setFillColor(style.color.cgColor)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: min(radius, frame.width / 2), cornerHeight: radius, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        case .plain, .outlined:
            break
        }
        let textRect = frame.insetBy(dx: padding.width, dy: padding.height)
        if style.textStyle == .outlined {
            // Stroke first, then fill on top, so the outline sits outside the glyphs.
            var outline = textAttributes(style)
            outline[.strokeColor] = style.color.contrasting.nsColor
            outline[.strokeWidth] = 16
            drawText(NSAttributedString(string: annotation.text, attributes: outline), in: textRect, ctx: ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        drawText(NSAttributedString(string: annotation.text, attributes: textAttributes(style)), in: textRect, ctx: ctx)
    }

    static func drawText(_ text: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Geometry

    /// Bounding box of an annotation in base-image pixel space.
    static func bounds(of annotation: Annotation) -> CGRect {
        let style = annotation.style
        switch annotation.kind {
        case .text:
            return textFrame(annotation)
        case .counter:
            let r = counterRadius(style)
            return CGRect(x: annotation.start.x - r, y: annotation.start.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            let width = annotation.kind == .highlighter ? style.lineWidth * 3 : style.lineWidth
            let xs = annotation.points.map(\.x), ys = annotation.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -width / 2, dy: -width / 2)
        case .line:
            return annotation.rect.insetBy(dx: -style.lineWidth * 2, dy: -style.lineWidth * 2)
        case .arrow:
            let reach = style.lineWidth * arrowWeight * 1.5
            return annotation.rect.insetBy(dx: -reach, dy: -reach)
        default:
            return annotation.rect
        }
    }

    /// Whether `point` (image pixels) hits the annotation, with `tolerance` pixels of slop.
    static func hitTest(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        let style = annotation.style
        switch annotation.kind {
        case .line:
            return point.distance(toSegment: annotation.start, annotation.end) <= style.lineWidth + tolerance
        case .arrow:
            return point.distance(toSegment: annotation.start, annotation.end) <= style.lineWidth * arrowWeight * 1.4 + tolerance
        case .pen, .highlighter:
            let width = annotation.kind == .highlighter ? style.lineWidth * 3 : style.lineWidth
            let points = annotation.points
            if points.count == 1 { return point.distance(to: points[0]) <= width + tolerance }
            return zip(points, points.dropFirst()).contains { point.distance(toSegment: $0, $1) <= width / 2 + tolerance }
        case .rectangle, .ellipse:
            let rect = annotation.rect
            if style.filled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: style.lineWidth + tolerance, dy: style.lineWidth + tolerance)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        default:
            return bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }
}
