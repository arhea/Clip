import AppKit
import SwiftUI

/// The interactive drawing surface. Renders through `Renderer` and translates
/// pointer input into annotation edits in base-image pixel space.
struct EditorCanvas: View {
    @Bindable var document: EditorDocument
    @Binding var zoom: CGFloat?
    /// Extra room around the image for floating controls.
    var insets = EdgeInsets()
    @State private var interaction: Interaction?
    @State private var magnifyStart: CGFloat?
    @FocusState private var canvasFocused: Bool

    private enum Handle: Equatable { case start, end, corner(Int), edge(Int) }

    private enum Interaction {
        case create(UUID, origin: CGPoint)
        case move(UUID, last: CGPoint)
        case resize(UUID, Handle)
        case cropNew(origin: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(Handle)
    }

    private var isCropping: Bool { document.tool == .crop }

    private var layout: RenderLayout {
        RenderLayout.make(for: document.state, scale: document.scale, includeBackground: !isCropping, applyCrop: !isCropping)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = layout
            let fit = fitZoom(for: layout.canvasSize, in: geometry.size)
            let z = zoom ?? fit
            ScrollView([.horizontal, .vertical]) {
                surface(layout: layout, zoom: z)
                    .frame(width: layout.canvasSize.width * z, height: layout.canvasSize.height * z)
                    .padding(24)
                    .padding(insets)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(.automatic)
            .gesture(MagnifyGesture()
                .onChanged { value in
                    if magnifyStart == nil { magnifyStart = z }
                    zoom = clampZoom((magnifyStart ?? z) * value.magnification)
                }
                .onEnded { _ in magnifyStart = nil })
            .onAppear { canvasFocused = true }
        }
    }

    // MARK: Surface

    @ViewBuilder
    private func surface(layout: RenderLayout, zoom z: CGFloat) -> some View {
        // Read observed values here so SwiftUI tracks them for redraws.
        let state = document.state
        let scale = document.scale
        let hidden = document.editingTextID
        let selected = document.selectedAnnotation
        let cropDraft = isCropping ? document.cropDraft : nil
        let includeBackground = !isCropping
        let cache = document.cache

        Canvas { context, _ in
            context.withCGContext { cg in
                cg.scaleBy(x: z, y: z)
                cg.interpolationQuality = z * scale >= 2 ? .none : .high
                var options = Renderer.Options(includeBackground: includeBackground, applyCrop: includeBackground)
                options.hiddenAnnotation = hidden
                Renderer.draw(state, layout: layout, scale: scale, options: options, cache: cache, in: cg)
                if let selected, selected.id != hidden {
                    drawSelection(selected, layout: layout, zoom: z, in: cg)
                }
                if let cropDraft {
                    drawCropOverlay(cropDraft, layout: layout, zoom: z, in: cg)
                }
            }
        }
        .background {
            if !state.background.isEnabled || isCropping {
                CheckerboardView()
            }
        }
        .shadow(color: .black.opacity(state.background.isEnabled && !isCropping ? 0.12 : 0.22), radius: 18, y: 6)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = imagePoint(value.location, layout: layout, zoom: z)
                if interaction == nil {
                    begin(at: point, zoom: z)
                } else {
                    proceed(to: point)
                }
            }
            .onEnded { _ in end() })
        .overlay(alignment: .topLeading) {
            if let id = document.editingTextID, let annotation = document.state.annotations.first(where: { $0.id == id }) {
                TextAnnotationEditor(document: document, annotation: annotation, layout: layout, zoom: z)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .pointerStyle(document.tool == .select ? .default : .rectSelection)
    }

    private func fitZoom(for canvas: CGSize, in available: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        let width = available.width - 48 - insets.leading - insets.trailing
        let height = available.height - 48 - insets.top - insets.bottom
        let fit = min(width / canvas.width, height / canvas.height)
        return max(0.05, min(fit, 1 / document.scale))
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.05), 8 / document.scale)
    }

    private func imagePoint(_ viewPoint: CGPoint, layout: RenderLayout, zoom z: CGFloat) -> CGPoint {
        CGPoint(x: viewPoint.x / z, y: viewPoint.y / z).applying(layout.transform.inverted())
    }

    /// Pixel slop for hit testing, so targets stay ~6pt regardless of zoom.
    private func tolerance(_ z: CGFloat) -> CGFloat { 6 / max(z, 0.01) }

    // MARK: Interaction

    private var modifiers: NSEvent.ModifierFlags { NSEvent.modifierFlags }

    private func begin(at point: CGPoint, zoom z: CGFloat) {
        canvasFocused = true
        let tolerance = tolerance(z)

        if document.editingTextID != nil {
            document.finishTextEditing()
            interaction = nil
            if document.tool == .text { return }
        }

        if isCropping {
            let crop = document.cropDraft ?? document.state.imageRect
            if let handle = handle(at: point, forRect: crop, tolerance: tolerance * 1.5) {
                interaction = .cropResize(handle)
            } else if crop.contains(point) {
                interaction = .cropMove(last: point)
            } else {
                interaction = .cropNew(origin: point)
            }
            return
        }

        // Handles and body of the current selection work with every tool.
        if let selected = document.selectedAnnotation {
            if let handle = handle(at: point, for: selected, tolerance: tolerance) {
                document.beginChange()
                interaction = .resize(selected.id, handle)
                return
            }
            if Renderer.hitTest(selected, at: point, tolerance: tolerance) {
                if selected.kind == .text, NSApp.currentEvent?.clickCount == 2 {
                    startEditing(selected.id)
                    return
                }
                document.beginChange()
                interaction = .move(selected.id, last: point)
                return
            }
        }

        switch document.tool {
        case .select:
            if let hit = document.state.annotations.last(where: { Renderer.hitTest($0, at: point, tolerance: tolerance) }) {
                document.selection = hit.id
                if hit.kind == .text, NSApp.currentEvent?.clickCount == 2 {
                    startEditing(hit.id)
                    return
                }
                document.beginChange()
                interaction = .move(hit.id, last: point)
            } else {
                document.selection = nil
            }

        case .text:
            if let hit = document.state.annotations.last(where: { $0.kind == .text && Renderer.hitTest($0, at: point, tolerance: tolerance) }) {
                document.selection = hit.id
                startEditing(hit.id)
                return
            }
            var style = document.style
            style.lineWidth = document.style.lineWidth
            let annotation = Annotation(kind: .text, start: CGPoint(x: point.x, y: point.y - style.fontSize * 0.6), end: point, style: style)
            document.beginChange()
            document.update { $0.annotations.append(annotation) }
            document.selection = annotation.id
            document.editingTextID = annotation.id

        case .counter:
            let annotation = Annotation(kind: .counter, start: point, end: point, number: document.nextCounterNumber, style: document.style)
            document.mutate { $0.annotations.append(annotation) }
            document.selection = annotation.id

        default:
            guard let kind = document.tool.annotationKind else { return }
            var style = document.style
            style.filled = document.tool == .filledRectangle || (kind == .ellipse && document.style.filled)
            let annotation = Annotation(kind: kind, start: point, end: point, points: kind.isFreehand ? [point] : [], style: style)
            document.beginChange()
            document.update { $0.annotations.append(annotation) }
            document.selection = nil
            interaction = .create(annotation.id, origin: point)
        }
    }

    private func proceed(to point: CGPoint) {
        guard let interaction else { return }
        let shift = modifiers.contains(.shift)
        switch interaction {
        case .create(let id, let origin):
            document.update { state in
                guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                let kind = state.annotations[index].kind
                if kind.isFreehand {
                    if let last = state.annotations[index].points.last, last.distance(to: point) >= 1 {
                        state.annotations[index].points.append(point)
                    }
                } else if kind.isLinear {
                    state.annotations[index].end = shift ? point.snapped45(from: origin) : point
                } else {
                    state.annotations[index].end = shift ? point.squared(from: origin) : point
                }
            }

        case .move(let id, let last):
            let delta = point - last
            document.update { state in
                guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                state.annotations[index].offset(by: delta)
            }
            self.interaction = .move(id, last: point)

        case .resize(let id, let handle):
            document.update { state in
                guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
                var annotation = state.annotations[index]
                switch handle {
                case .start: annotation.start = shift ? point.snapped45(from: annotation.end) : point
                case .end: annotation.end = shift ? point.snapped45(from: annotation.start) : point
                case .corner(let corner):
                    let rect = annotation.rect
                    let opposite = corners(of: rect)[3 - corner]
                    annotation.start = opposite
                    annotation.end = shift ? point.squared(from: opposite) : point
                case .edge: break
                }
                state.annotations[index] = annotation
            }

        case .cropNew(let origin):
            document.cropDraft = constrainedCrop(from: origin, to: point)

        case .cropMove(let last):
            guard var crop = document.cropDraft else { return }
            let bounds = document.state.imageRect
            let delta = point - last
            crop.origin.x = min(max(crop.minX + delta.x, bounds.minX), bounds.maxX - crop.width)
            crop.origin.y = min(max(crop.minY + delta.y, bounds.minY), bounds.maxY - crop.height)
            document.cropDraft = crop
            self.interaction = .cropMove(last: point)

        case .cropResize(let handle):
            guard let crop = document.cropDraft else { return }
            let bounds = document.state.imageRect
            let clamped = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
            switch handle {
            case .corner(let corner):
                let opposite = corners(of: crop)[3 - corner]
                document.cropDraft = constrainedCrop(from: opposite, to: clamped)
            case .edge(let edge):
                var rect = crop
                switch edge {
                case 0: rect = CGRect(from: CGPoint(x: crop.minX, y: clamped.y), to: CGPoint(x: crop.maxX, y: crop.maxY))
                case 1: rect = CGRect(from: CGPoint(x: crop.minX, y: crop.minY), to: CGPoint(x: clamped.x, y: crop.maxY))
                case 2: rect = CGRect(from: CGPoint(x: crop.minX, y: crop.minY), to: CGPoint(x: crop.maxX, y: clamped.y))
                default: rect = CGRect(from: CGPoint(x: clamped.x, y: crop.minY), to: CGPoint(x: crop.maxX, y: crop.maxY))
                }
                document.cropDraft = rect
            default: break
            }
        }
    }

    private func end() {
        defer { interaction = nil }
        guard let interaction else { return }
        switch interaction {
        case .create(let id, _):
            let minimum: CGFloat = 3
            if let annotation = document.state.annotations.first(where: { $0.id == id }) {
                let tooSmall: Bool
                if annotation.kind.isFreehand {
                    tooSmall = annotation.points.isEmpty
                } else if annotation.kind.isLinear {
                    tooSmall = annotation.start.distance(to: annotation.end) < minimum
                } else {
                    tooSmall = annotation.rect.width < minimum || annotation.rect.height < minimum
                }
                if tooSmall {
                    document.update { $0.annotations.removeAll { $0.id == id } }
                } else if !annotation.kind.isFreehand {
                    document.selection = id
                }
            }
            document.endChange()
        case .move, .resize:
            document.endChange()
        case .cropNew, .cropMove, .cropResize:
            if let crop = document.cropDraft, crop.width < 4 || crop.height < 4 {
                document.cropDraft = document.state.effectiveCrop
            }
        }
    }

    private func startEditing(_ id: UUID) {
        document.beginChange()
        document.selection = id
        document.editingTextID = id
        interaction = nil
    }

    private func constrainedCrop(from origin: CGPoint, to point: CGPoint) -> CGRect {
        let bounds = document.state.imageRect
        var end = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        if let ratio = document.cropAspect.ratio {
            let dx = end.x - origin.x, dy = end.y - origin.y
            let width = max(abs(dx), abs(dy) * ratio)
            let height = width / ratio
            end = CGPoint(x: origin.x + (dx < 0 ? -width : width), y: origin.y + (dy < 0 ? -height : height))
        } else if modifiers.contains(.shift) {
            end = end.squared(from: origin)
        }
        return CGRect(from: origin, to: end).intersection(bounds)
    }

    // MARK: Handles

    /// Corners ordered top-left, top-right, bottom-left, bottom-right; `3 - i` is the opposite corner.
    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    private func edgeMidpoints(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    private func handlePoints(for annotation: Annotation) -> [(Handle, CGPoint)] {
        if annotation.kind.isLinear {
            return [(.start, annotation.start), (.end, annotation.end)]
        }
        if annotation.kind.isBoxed {
            return corners(of: annotation.rect).enumerated().map { (.corner($0.offset), $0.element) }
        }
        return []
    }

    private func handle(at point: CGPoint, for annotation: Annotation, tolerance: CGFloat) -> Handle? {
        handlePoints(for: annotation).first { $0.1.distance(to: point) <= tolerance * 1.5 }?.0
    }

    private func handle(at point: CGPoint, forRect rect: CGRect, tolerance: CGFloat) -> Handle? {
        if let corner = corners(of: rect).enumerated().first(where: { $0.element.distance(to: point) <= tolerance }) {
            return .corner(corner.offset)
        }
        if let edge = edgeMidpoints(of: rect).enumerated().first(where: { $0.element.distance(to: point) <= tolerance }) {
            return .edge(edge.offset)
        }
        return nil
    }

    // MARK: Overlays

    private func drawSelection(_ annotation: Annotation, layout: RenderLayout, zoom z: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.concatenate(layout.transform)
        let pixel = 1 / z
        let accent = NSColor.controlAccentColor.cgColor
        if !annotation.kind.isLinear {
            cg.setStrokeColor(accent)
            cg.setLineWidth(pixel * 1.5)
            cg.setLineDash(phase: 0, lengths: [pixel * 4, pixel * 3])
            cg.stroke(Renderer.bounds(of: annotation).insetBy(dx: -pixel * 4, dy: -pixel * 4))
            cg.setLineDash(phase: 0, lengths: [])
        }
        for (_, point) in handlePoints(for: annotation) {
            drawHandle(at: point, pixel: pixel, in: cg)
        }
        cg.restoreGState()
    }

    private func drawHandle(at point: CGPoint, pixel: CGFloat, in cg: CGContext) {
        let size = pixel * 9
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        cg.setFillColor(.white)
        cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
        cg.setLineWidth(pixel * 1.5)
        cg.fillEllipse(in: rect)
        cg.strokeEllipse(in: rect)
    }

    private func drawCropOverlay(_ crop: CGRect, layout: RenderLayout, zoom z: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.concatenate(layout.transform)
        let pixel = 1 / z
        let path = CGMutablePath()
        path.addRect(document.state.imageRect)
        path.addRect(crop)
        cg.addPath(path)
        cg.setFillColor(CGColor(gray: 0, alpha: 0.5))
        cg.fillPath(using: .evenOdd)

        cg.setStrokeColor(.white)
        cg.setLineWidth(pixel * 1.5)
        cg.stroke(crop)
        // Rule-of-thirds guides.
        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.4))
        cg.setLineWidth(pixel)
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3
            let y = crop.minY + crop.height * CGFloat(i) / 3
            cg.move(to: CGPoint(x: x, y: crop.minY)); cg.addLine(to: CGPoint(x: x, y: crop.maxY))
            cg.move(to: CGPoint(x: crop.minX, y: y)); cg.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        cg.strokePath()
        for point in corners(of: crop) + edgeMidpoints(of: crop) {
            drawHandle(at: point, pixel: pixel, in: cg)
        }
        cg.restoreGState()
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .delete, .deleteForward:
            document.deleteSelection()
            return .handled
        case .escape:
            if isCropping {
                document.cropDraft = nil
                document.tool = .select
            } else {
                document.selection = nil
            }
            return .handled
        case .return where isCropping:
            document.tool = .select
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard let selection = document.selection else { return .ignored }
            let step: CGFloat = (press.modifiers.contains(.shift) ? 10 : 1) * document.scale
            let delta: CGPoint = switch press.key {
            case .leftArrow: CGPoint(x: -step, y: 0)
            case .rightArrow: CGPoint(x: step, y: 0)
            case .upArrow: CGPoint(x: 0, y: -step)
            default: CGPoint(x: 0, y: step)
            }
            document.mutate { state in
                guard let index = state.annotations.firstIndex(where: { $0.id == selection }) else { return }
                state.annotations[index].offset(by: delta)
            }
            return .handled
        default:
            break
        }
        guard let character = press.characters.lowercased().first else { return .ignored }
        if character == "b" {
            document.mutate { $0.background.isEnabled.toggle() }
            return .handled
        }
        if let tool = EditorTool.allCases.first(where: { $0.shortcut == character }) {
            document.tool = tool
            return .handled
        }
        return .ignored
    }
}

/// In-place text field positioned over a text annotation while it is being edited.
private struct TextAnnotationEditor: View {
    let document: EditorDocument
    let annotation: Annotation
    let layout: RenderLayout
    let zoom: CGFloat
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let frame = Renderer.textFrame(annotation)
        let padding = Renderer.textPadding(annotation.style)
        let origin = CGPoint(x: frame.minX + padding.width, y: frame.minY + padding.height).applying(layout.transform)
        let k = layout.transform.a
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: annotation.style.fontSize * k * zoom, weight: .semibold))
            .foregroundStyle(annotation.style.textStyle == .background || annotation.style.textStyle == .rounded
                             ? annotation.style.color.color : annotation.style.color.color)
            .fixedSize()
            .frame(minWidth: 40 * zoom * document.scale, alignment: .leading)
            .padding(2)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3])))
            .offset(x: origin.x * zoom - 2, y: origin.y * zoom - 2)
            .focused($focused)
            .onAppear {
                text = annotation.text
                focused = true
            }
            .onChange(of: text) { _, newValue in document.setText(newValue, for: annotation.id) }
            .onSubmit { document.finishTextEditing() }
            .onKeyPress(.escape) {
                document.finishTextEditing()
                return .handled
            }
    }
}

/// Transparency checkerboard shown behind images without a background.
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.8)))
                }
            }
        }
    }
}
