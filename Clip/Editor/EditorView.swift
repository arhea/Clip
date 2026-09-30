import SwiftUI
import UniformTypeIdentifiers

/// Callbacks the editor uses to reach app-level services.
struct EditorActions {
    var copy: (EditorDocument) -> Void
    var save: (EditorDocument) -> Void
    var saveAs: (EditorDocument) -> Void
    var pin: (EditorDocument) -> Void
    var close: () -> Void
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case background, export
    var id: String { rawValue }
    var title: String { self == .background ? "Background" : "Export" }
}

/// The annotation editor: a full-bleed canvas with Liquid Glass controls floating above it.
struct EditorView: View {
    @Bindable var document: EditorDocument
    let actions: EditorActions
    @State private var zoom: CGFloat?
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .background

    /// Space reserved above and below the image for the floating glass controls.
    static let controlInsets = EdgeInsets(top: 64, leading: 0, bottom: 64, trailing: 0)

    var body: some View {
        EditorCanvas(document: document, zoom: $zoom, insets: Self.controlInsets)
            .background(CanvasBackground())
            .overlay(alignment: .top) {
                OptionsBar(document: document)
                    .padding(.top, 12)
            }
            .overlay(alignment: .bottom) {
                StatusControls(document: document, zoom: $zoom)
                    .padding(12)
            }
            .animation(.smooth(duration: 0.25), value: document.tool)
            .animation(.smooth(duration: 0.25), value: document.selection)
            .inspector(isPresented: $showInspector) {
                InspectorView(document: document, tab: $inspectorTab)
                    .inspectorColumnWidth(min: 270, ideal: 290, max: 360)
            }
            .toolbar { toolbarContent }
            .background(shortcuts)
            .onChange(of: document.state.background.isEnabled) { _, enabled in
                if enabled { showInspector = true; inspectorTab = .background }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Undo", systemImage: "arrow.uturn.backward", action: document.undo)
                .disabled(!document.canUndo)
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward", action: document.redo)
                .disabled(!document.canRedo)
                .help("Redo (⇧⌘Z)")
        }

        ToolbarItem(placement: .principal) {
            ToolPicker(document: document)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            DragOutButton(document: document)
            Button("Pin to Screen", systemImage: "pin") { actions.pin(document) }
                .help("Pin to Screen")
            Button("Copy", systemImage: "doc.on.doc") { actions.copy(document) }
                .help("Copy Image (⇧⌘C)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Save", systemImage: "square.and.arrow.down") { actions.save(document) }
                .buttonStyle(.glassProminent)
                .help("Save (⌘S) · Save As (⇧⌘S)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help("Background & Export Options")
        }
    }

    // MARK: Hidden keyboard shortcuts

    private var shortcuts: some View {
        Group {
            Button("") { document.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { document.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { actions.copy(document) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { actions.save(document) }.keyboardShortcut("s", modifiers: .command)
            Button("") { actions.saveAs(document) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { document.duplicateSelection() }.keyboardShortcut("d", modifiers: .command)
            Button("") { document.bringSelectionToFront() }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { document.sendSelectionToBack() }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { document.mutate { $0.background.isEnabled.toggle() } }.keyboardShortcut("b", modifiers: .command)
            Button("") { zoom = EditorZoom.step(zoom, by: 1.25, scale: document.scale) }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoom = EditorZoom.step(zoom, by: 0.8, scale: document.scale) }.keyboardShortcut("-", modifiers: .command)
            Button("") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
            Button("") { actions.close() }.keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .disabled(document.editingTextID != nil)
    }
}

enum EditorZoom {
    static func step(_ zoom: CGFloat?, by factor: CGFloat, scale: CGFloat) -> CGFloat {
        let current = zoom ?? (1 / scale) * 0.5
        return min(max(current * factor, 0.05), 8 / scale)
    }
}

/// A soft, appearance-aware backdrop that reads as "canvas" in light and dark mode.
private struct CanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.93))
            .overlay {
                // Subtle dot grid, like a design canvas.
                Canvas { context, size in
                    let spacing: CGFloat = 22
                    let dot = Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.08)
                    for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                        for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                            context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(dot))
                        }
                    }
                }
            }
            .ignoresSafeArea()
    }
}

// MARK: - Tool picker

/// The tool palette, shown as a native segmented control (glass on macOS 26).
private struct ToolPicker: View {
    @Bindable var document: EditorDocument

    private static let groups: [[EditorTool]] = [
        [.select, .crop],
        [.arrow, .line, .rectangle, .filledRectangle, .ellipse, .text, .pen, .highlighter, .counter],
        [.redact, .spotlight],
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.groups.indices, id: \.self) { index in
                Picker("Tools", selection: selection(for: Self.groups[index])) {
                    ForEach(Self.groups[index]) { tool in
                        Image(systemName: tool.symbol)
                            .accessibilityLabel("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                            .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                            .tag(Optional(tool))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle(isOn: Binding(get: { document.state.background.isEnabled },
                                 set: { value in document.mutate { $0.background.isEnabled = value } })) {
                Image(systemName: "rectangle.inset.filled.on.rectangle")
            }
            .toggleStyle(.button)
            .help("Background (B)")
        }
    }

    /// Each segment group shows a selection only when the active tool belongs to it.
    private func selection(for group: [EditorTool]) -> Binding<EditorTool?> {
        Binding(
            get: { group.contains(document.tool) ? document.tool : nil },
            set: { if let tool = $0 { document.tool = tool } }
        )
    }
}

/// Drag the finished image straight into another app.
private struct DragOutButton: View {
    let document: EditorDocument

    var body: some View {
        Image(systemName: "hand.draw")
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
            .help("Drag the image into another app")
            .onDrag {
                guard let image = document.exportImage(),
                      let url = ImageExporter.temporaryFile(image, name: Preferences.shared.fileName(for: document.createdAt, format: document.export.format),
                                                            format: document.export.format, quality: document.export.quality,
                                                            scale: document.exportScale) else {
                    return NSItemProvider()
                }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
    }
}

// MARK: - Floating options bar

/// Context-sensitive controls for the active tool, floating in a glass capsule under the toolbar.
private struct OptionsBar: View {
    @Bindable var document: EditorDocument

    private var tool: EditorTool {
        if document.tool == .select, let selected = document.selectedAnnotation {
            return EditorTool.forKind(selected.kind)
        }
        return document.tool
    }

    private var isVisible: Bool {
        !(document.tool == .select && document.selectedAnnotation == nil)
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 14) {
                content
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var content: some View {
        if tool == .crop {
            Picker("Aspect", selection: $document.cropAspect) {
                Text("Freeform").tag(BackgroundAspect.auto)
                ForEach(BackgroundAspect.allCases.filter { $0 != .auto }) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button("Reset") { document.resetCrop() }
                .buttonStyle(.borderless)
            Button("Done") { document.tool = .select }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: [])
        } else {
            if tool.usesColor {
                ColorRow(selection: styleBinding(\.color))
            }

            if tool.usesLineWidth {
                SizeSlider(symbol: "lineweight", value: styleBinding(\.lineWidth), range: (1 * document.scale)...(20 * document.scale))
            }

            switch tool {
            case .arrow:
                Picker("Arrow Style", selection: styleBinding(\.arrowStyle)) {
                    ForEach(ArrowStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case .ellipse:
                Toggle("Fill", isOn: styleBinding(\.filled))
                    .toggleStyle(.switch)
            case .text, .counter:
                SizeSlider(symbol: "textformat.size", value: styleBinding(\.fontSize), range: (10 * document.scale)...(96 * document.scale))
                if tool == .text {
                    Picker("Text Style", selection: styleBinding(\.textStyle)) {
                        ForEach(TextStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .redact:
                Picker("Effect", selection: styleBinding(\.redactStyle)) {
                    ForEach(RedactStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            case .spotlight:
                Label("Drag to spotlight an area", systemImage: "flashlight.on.fill")
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }

            if document.selection != nil {
                Button("Delete", systemImage: "trash", role: .destructive) { document.deleteSelection() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete (⌫)")
            }
        }
    }

    /// Binds to the working style and pushes edits onto the selected annotation.
    private func styleBinding<Value>(_ keyPath: WritableKeyPath<AnnotationStyle, Value>) -> Binding<Value> {
        Binding(
            get: { document.selectedAnnotation?.style[keyPath: keyPath] ?? document.style[keyPath: keyPath] },
            set: { newValue in
                document.style[keyPath: keyPath] = newValue
                if let selection = document.selection {
                    document.mutate { state in
                        guard let index = state.annotations.firstIndex(where: { $0.id == selection }) else { return }
                        state.annotations[index].style[keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }
}

private struct SizeSlider: View {
    let symbol: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range)
                .frame(width: 110)
        }
    }
}

private struct ColorRow: View {
    @Binding var selection: RGBAColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RGBAColor.palette, id: \.self) { color in
                Button { selection = color } label: {
                    Circle()
                        .fill(color.color.gradient)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selection == color ? 0.85 : 0), lineWidth: 2))
                        .scaleEffect(selection == color ? 1.05 : 1)
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.15), value: selection)
            }
            ColorPicker("Custom Color", selection: Binding(get: { selection.color }, set: { selection = RGBAColor($0) }))
                .labelsHidden()
        }
    }
}

// MARK: - Floating status controls

private struct StatusControls: View {
    @Bindable var document: EditorDocument
    @Binding var zoom: CGFloat?

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .center) {
                sizeInfo
                Spacer()
                zoomControls
            }
        }
    }

    private var sizeInfo: some View {
        let size = document.renderedPixelSize
        return HStack(spacing: 6) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("\(Int(size.width)) × \(Int(size.height))")
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
        .help("Output size in pixels")
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Rotate Left", systemImage: "rotate.left") { document.apply(.rotateLeft) }
                Button("Rotate Right", systemImage: "rotate.right") { document.apply(.rotateRight) }
                Divider()
                Button("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { document.apply(.flipHorizontal) }
                Button("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { document.apply(.flipVertical) }
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Rotate & Flip")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            iconButton("minus", help: "Zoom Out (⌘−)") { zoom = EditorZoom.step(zoom, by: 0.8, scale: document.scale) }
            Menu {
                Button("Zoom to Fit") { zoom = nil }
                Button("Actual Size") { zoom = 1 / document.scale }
                Button("Pixel Size (1:1 pixels)") { zoom = 1 }
            } label: {
                Text(zoomLabel)
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            iconButton("plus", help: "Zoom In (⌘+)") { zoom = EditorZoom.step(zoom, by: 1.25, scale: document.scale) }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
    }

    private var zoomLabel: String {
        guard let zoom else { return "Fit" }
        return "\(Int((zoom * document.scale * 100).rounded()))%"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Inspector

private struct InspectorView: View {
    @Bindable var document: EditorDocument
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            switch tab {
            case .background: BackgroundInspector(document: document)
            case .export: ExportInspector(document: document)
            }
        }
    }
}

private struct BackgroundInspector: View {
    @Bindable var document: EditorDocument

    private func binding<Value>(_ keyPath: WritableKeyPath<BackgroundStyle, Value>) -> Binding<Value> {
        Binding(get: { document.state.background[keyPath: keyPath] },
                set: { value in document.mutate { $0.background[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Background", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
                    .font(.headline)
            }

            Group {
                Section("Fill") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(BackgroundFill.presets, id: \.self) { fill in
                            Button { document.mutate { $0.background.fill = fill } } label: {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LinearGradient(colors: fill.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                                    .padding(3)
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: document.state.background.fill == fill ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    ColorPicker("Start Color", selection: fillColorBinding(0))
                    ColorPicker("End Color", selection: fillColorBinding(1))
                }

                Section("Layout") {
                    slider("Padding", \.padding, 0...200)
                    slider("Inset", \.inset, 0...60)
                    slider("Corners", \.cornerRadius, 0...40)
                    Picker("Aspect Ratio", selection: binding(\.aspect)) {
                        ForEach(BackgroundAspect.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Alignment") {
                        AlignmentGrid(selection: binding(\.alignment))
                    }
                }

                Section("Shadow") {
                    slider("Size", \.shadowRadius, 0...80)
                    slider("Opacity", \.shadowOpacity, 0...1, format: { "\(Int($0 * 100))%" })
                }
            }
            .disabled(!document.state.background.isEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func fillColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { document.state.background.fill.colors[index].color },
            set: { color in
                var colors = document.state.background.fill.colors
                colors[index] = RGBAColor(color)
                document.mutate { $0.background.fill = colors[0] == colors[1] ? .solid(colors[0]) : .gradient(colors[0], colors[1]) }
            }
        )
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<BackgroundStyle, CGFloat>, _ range: ClosedRange<CGFloat>,
                        format: @escaping (CGFloat) -> String = { "\(Int($0))" }) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { document.state.background[keyPath: keyPath] },
                                      set: { value in
                                          document.beginChange()
                                          document.update { $0.background[keyPath: keyPath] = value }
                                      }),
                       in: range,
                       onEditingChanged: { editing in if !editing { document.endChange() } })
                .controlSize(.small)
                Text(format(document.state.background[keyPath: keyPath]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

private struct AlignmentGrid: View {
    @Binding var selection: BackgroundAlignment

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let alignment = BackgroundAlignment.allCases[row * 3 + column]
                        Button { selection = alignment } label: {
                            Circle()
                                .fill(selection == alignment ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)
                                .frame(width: 20, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
        .help("Alignment applies when an aspect ratio adds extra space")
    }
}

private struct ExportInspector: View {
    @Bindable var document: EditorDocument
    @State private var lockAspect = true
    @State private var estimatedBytes: Int?
    @State private var widthText = ""
    @State private var heightText = ""

    private var natural: CGSize { document.renderedPixelSize }

    var body: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: $document.export.format) {
                    ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if document.export.format.supportsQuality {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $document.export.quality, in: 0.1...1)
                                .controlSize(.small)
                            Text("\(Int(document.export.quality * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Size") {
                HStack(spacing: 6) {
                    TextField("Width", text: $widthText)
                        .onSubmit { commitWidth() }
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $heightText)
                        .onSubmit { commitHeight() }
                    Toggle(isOn: $lockAspect) { Image(systemName: lockAspect ? "lock.fill" : "lock.open") }
                        .toggleStyle(.button)
                        .buttonStyle(.borderless)
                        .help("Lock Aspect Ratio")
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .monospacedDigit()
                HStack {
                    ForEach(ExportSizePreset.allCases) { preset in
                        Button(preset.title) { applyScale(preset.factor) }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                if document.scale > 1 {
                    Button("Non-Retina (1×)") { applyScale(1 / document.scale) }
                        .controlSize(.small)
                        .buttonStyle(.glass)
                }
            }

            Section {
                LabeledContent("Estimated Size") {
                    Text(estimatedBytes.map(ImageExporter.formattedByteCount) ?? "Calculating…")
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: syncFields)
        .onChange(of: natural) { _, _ in
            document.export.width = nil
            document.export.height = nil
            syncFields()
        }
        .task(id: EstimateKey(export: document.export, size: natural, state: document.state.hashValueProxy)) {
            estimatedBytes = nil
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let image = document.exportImage() else { return }
            estimatedBytes = ImageExporter.encode(image, format: document.export.format, quality: document.export.quality)?.count
        }
    }

    private struct EstimateKey: Equatable {
        var export: ExportOptions
        var size: CGSize
        var state: Int
    }

    private func syncFields() {
        widthText = "\(document.export.width ?? Int(natural.width))"
        heightText = "\(document.export.height ?? Int(natural.height))"
    }

    private func applyScale(_ factor: CGFloat) {
        if factor == 1 {
            document.export.width = nil
            document.export.height = nil
        } else {
            document.export.width = max(1, Int((natural.width * factor).rounded()))
            document.export.height = max(1, Int((natural.height * factor).rounded()))
        }
        syncFields()
    }

    private func commitWidth() {
        guard let width = Int(widthText), width > 0 else { return syncFields() }
        let height = lockAspect ? Int((CGFloat(width) / natural.aspectRatio).rounded()) : (Int(heightText) ?? Int(natural.height))
        setSize(width, max(1, height))
    }

    private func commitHeight() {
        guard let height = Int(heightText), height > 0 else { return syncFields() }
        let width = lockAspect ? Int((CGFloat(height) * natural.aspectRatio).rounded()) : (Int(widthText) ?? Int(natural.width))
        setSize(max(1, width), height)
    }

    private func setSize(_ width: Int, _ height: Int) {
        if width == Int(natural.width), height == Int(natural.height) {
            document.export.width = nil
            document.export.height = nil
        } else {
            document.export.width = width
            document.export.height = height
        }
        syncFields()
    }
}

extension EditorTool {
    static func forKind(_ kind: AnnotationKind) -> EditorTool {
        switch kind {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .text: .text
        case .pen: .pen
        case .highlighter: .highlighter
        case .counter: .counter
        case .redact: .redact
        case .spotlight: .spotlight
        }
    }
}

private extension EditorState {
    /// A cheap change token for re-running the file-size estimate.
    var hashValueProxy: Int {
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(baseImage))
        hasher.combine(annotations.count)
        for annotation in annotations {
            hasher.combine(annotation.id)
            hasher.combine(annotation.start.x); hasher.combine(annotation.start.y)
            hasher.combine(annotation.end.x); hasher.combine(annotation.end.y)
            hasher.combine(annotation.points.count)
            hasher.combine(annotation.text)
        }
        hasher.combine(crop?.width); hasher.combine(crop?.height)
        hasher.combine(background.isEnabled)
        hasher.combine(background.padding)
        return hasher.finalize()
    }
}
