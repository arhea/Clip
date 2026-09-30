import AppKit
import Observation

nonisolated enum ExportSizePreset: String, CaseIterable, Identifiable {
    case full, threeQuarters, half, quarter

    var id: String { rawValue }
    var factor: CGFloat {
        switch self {
        case .full: 1
        case .threeQuarters: 0.75
        case .half: 0.5
        case .quarter: 0.25
        }
    }
    var title: String {
        switch self {
        case .full: "100%"
        case .threeQuarters: "75%"
        case .half: "50%"
        case .quarter: "25%"
        }
    }
}

/// Output settings for save, copy, and drag.
struct ExportOptions: Equatable {
    var format: ImageFormat
    var quality: Double
    /// Output width in pixels; `nil` keeps the natural size.
    var width: Int?
    var height: Int?
}

/// Everything backing one editor window: undoable state plus transient UI state.
@Observable
final class EditorDocument {
    let id = UUID()
    let historyID: UUID?
    /// Pixels per point of the original capture (2 on Retina).
    let scale: CGFloat
    let kind: CaptureKind
    let createdAt: Date
    /// The pixels the document was opened with, to detect rotate/flip edits.
    let initialImage: CGImage

    private(set) var state: EditorState
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var pendingChangeStart: EditorState?

    var tool: EditorTool = .arrow {
        didSet {
            if tool != oldValue { selection = nil; finishTextEditing() }
            if tool == .crop { cropDraft = state.effectiveCrop }
            if oldValue == .crop, tool != .crop { applyCropDraft() }
        }
    }
    var style: AnnotationStyle
    var selection: UUID?
    var editingTextID: UUID?
    var cropDraft: CGRect?
    var cropAspect: BackgroundAspect = .auto
    var export: ExportOptions
    var isDirty = false

    @ObservationIgnored let cache = RenderCache()

    init(capture: Capture, historyID: UUID?, project: EditorProject? = nil, preferences: Preferences = .shared) {
        self.historyID = historyID
        self.scale = max(1, capture.scale)
        self.kind = capture.kind
        self.createdAt = capture.date
        self.initialImage = capture.image
        var state = EditorState(baseImage: capture.image)
        if let project {
            state.annotations = project.annotations
            state.crop = project.crop
            state.background = project.background
        }
        self.state = state
        // Scale default sizes with the capture so annotations stay legible on large screenshots.
        let longSide = max(capture.pointSize.width, capture.pointSize.height)
        var style = AnnotationStyle()
        style.lineWidth = max(4, longSide / 320) * max(1, capture.scale)
        style.fontSize = max(22, longSide / 55) * max(1, capture.scale)
        self.style = style
        self.export = ExportOptions(format: preferences.defaultFormat, quality: preferences.jpegQuality)
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Applies a discrete change as one undo step.
    func mutate(_ change: (inout EditorState) -> Void) {
        let before = state
        change(&state)
        guard state != before else { return }
        undoStack.append(before)
        redoStack.removeAll()
        isDirty = true
    }

    /// Starts a continuous change (e.g. a drag); call `endChange()` to record one undo step.
    func beginChange() {
        if pendingChangeStart == nil { pendingChangeStart = state }
    }

    /// Mutates live without recording undo; must be bracketed by begin/endChange.
    func update(_ change: (inout EditorState) -> Void) {
        change(&state)
    }

    func endChange() {
        guard let start = pendingChangeStart else { return }
        pendingChangeStart = nil
        guard start != state else { return }
        undoStack.append(start)
        redoStack.removeAll()
        isDirty = true
    }

    func undo() {
        finishTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        selection = nil
        isDirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        selection = nil
        isDirty = true
    }

    // MARK: Annotations

    var selectedAnnotation: Annotation? {
        guard let selection else { return nil }
        return state.annotations.first { $0.id == selection }
    }

    var nextCounterNumber: Int {
        (state.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    func deleteSelection() {
        guard let selection else { return }
        mutate { $0.annotations.removeAll { $0.id == selection } }
        self.selection = nil
    }

    func duplicateSelection() {
        guard var copy = selectedAnnotation else { return }
        copy.id = UUID()
        copy.offset(by: CGPoint(x: 20 * scale, y: 20 * scale))
        if copy.kind == .counter { copy.number = nextCounterNumber }
        mutate { $0.annotations.append(copy) }
        selection = copy.id
    }

    func bringSelectionToFront() {
        guard let selection, let index = state.annotations.firstIndex(where: { $0.id == selection }) else { return }
        mutate { $0.annotations.append($0.annotations.remove(at: index)) }
    }

    func sendSelectionToBack() {
        guard let selection, let index = state.annotations.firstIndex(where: { $0.id == selection }) else { return }
        mutate { $0.annotations.insert($0.annotations.remove(at: index), at: 0) }
    }

    /// Applies the current style to the selected annotation (when the user changes a style control).
    func applyStyleToSelection() {
        guard let selection else { return }
        mutate { state in
            guard let index = state.annotations.firstIndex(where: { $0.id == selection }) else { return }
            let filled = state.annotations[index].style.filled
            state.annotations[index].style = style
            // A rectangle's fill is part of its tool identity, so keep it.
            if state.annotations[index].kind == .rectangle { state.annotations[index].style.filled = filled }
        }
    }

    func finishTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let annotation = state.annotations.first(where: { $0.id == id }),
           annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update { $0.annotations.removeAll { $0.id == id } }
        }
        endChange()
    }

    func setText(_ text: String, for id: UUID) {
        update { state in
            guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            state.annotations[index].text = text
        }
    }

    // MARK: Crop & transforms

    func applyCropDraft() {
        guard let draft = cropDraft?.pixelAligned.intersection(state.imageRect), draft.width >= 4, draft.height >= 4 else { return }
        let newCrop: CGRect? = draft == state.imageRect ? nil : draft
        mutate { $0.crop = newCrop }
        cropDraft = nil
    }

    func resetCrop() {
        cropDraft = state.imageRect
    }

    enum Transform { case rotateLeft, rotateRight, flipHorizontal, flipVertical }

    /// Rotates or flips the base image and every annotation with it.
    func apply(_ transform: Transform) {
        finishTextEditing()
        let image = state.baseImage
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let newSize: CGSize
        // Maps old image-space points (top-left origin) to new image space.
        let pointTransform: CGAffineTransform
        switch transform {
        case .rotateRight:
            newSize = CGSize(width: h, height: w)
            pointTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .rotateLeft:
            newSize = CGSize(width: h, height: w)
            pointTransform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .flipHorizontal:
            newSize = CGSize(width: w, height: h)
            pointTransform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .flipVertical:
            newSize = CGSize(width: w, height: h)
            pointTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        }
        guard let ctx = CGContext(data: nil, width: Int(newSize.width), height: Int(newSize.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Work in a top-left-origin space so the same point transform applies to pixels.
        ctx.translateBy(x: 0, y: newSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(pointTransform)
        Renderer.drawImage(image, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
        guard let rotated = ctx.makeImage() else { return }

        mutate { state in
            state.baseImage = rotated
            for index in state.annotations.indices {
                state.annotations[index].apply(pointTransform)
                // Text and counters are anchored by a point; keep text reading upright.
                if state.annotations[index].kind == .text {
                    let frame = Renderer.textFrame(state.annotations[index])
                    let corners = [frame.origin, CGPoint(x: frame.maxX, y: frame.maxY)].map { $0.applying(pointTransform) }
                    state.annotations[index].start = CGPoint(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!)
                }
            }
            state.crop = state.crop.map { $0.applying(pointTransform).standardized }
        }
    }

    // MARK: Output

    func renderedImage() -> CGImage? {
        finishTextEditing()
        return Renderer.renderImage(state, scale: scale, cache: cache)
    }

    var renderedPixelSize: CGSize {
        RenderLayout.make(for: state, scale: scale, includeBackground: true, applyCrop: true).canvasSize
    }

    /// The final image with export sizing applied.
    func exportImage() -> CGImage? {
        guard let image = renderedImage() else { return nil }
        guard let width = export.width, let height = export.height else { return image }
        return ImageExporter.resize(image, to: CGSize(width: width, height: height))
    }

    /// Point scale of the exported image, for DPI metadata and pasteboard sizing.
    var exportScale: CGFloat {
        guard let width = export.width else { return scale }
        let natural = renderedPixelSize.width
        return natural > 0 ? scale * CGFloat(width) / natural : scale
    }
}
