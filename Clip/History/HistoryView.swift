import SwiftUI

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, area, window, fullscreen

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func includes(_ item: HistoryItem) -> Bool {
        switch self {
        case .all: true
        case .area: item.kind == .area || item.kind == .previousArea
        case .window: item.kind == .window
        case .fullscreen: item.kind == .fullscreen || item.kind == .allScreens
        }
    }
}

/// Grid of the last 50 captures.
struct HistoryView: View {
    let app: AppState
    @State private var filter: HistoryFilter = .all
    @State private var selection: UUID?
    @State private var confirmClear = false

    private var items: [HistoryItem] { app.history.items.filter(filter.includes) }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Captures Yet", systemImage: "camera.viewfinder",
                                       description: Text("Your last \(HistoryStore.limit) captures will appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            HistoryCell(item: item, app: app, isSelected: selection == item.id)
                                .onTapGesture { selection = item.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { app.openEditor(item) })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History", systemImage: "trash") { confirmClear = true }
                    .disabled(app.history.items.isEmpty)
            }
        }
        .confirmationDialog("Clear all \(app.history.items.count) captures from history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { app.history.clear() }
        } message: {
            Text("Files you saved to disk are not affected.")
        }
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    let app: AppState
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.6))
                if let image = app.history.thumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
                if hovering {
                    Rectangle().fill(.black.opacity(0.2))
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            action("doc.on.doc", "Copy") { app.copy(item) }
                            action("square.and.arrow.down", "Save") { app.save(item) }
                            action("pencil.tip.crop.circle", "Annotate") { app.openEditor(item) }
                            action("pin", "Pin") { app.pin(item) }
                        }
                    }
                }
            }
            .frame(height: 150)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1))
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 12 : 6, y: 3)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.smooth(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
            .onDrag {
                guard let url = app.dragFile(for: item) else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.date, format: .relative(presentation: .named))
                        .font(.callout.weight(.medium))
                    Text("\(item.kind.displayName) · \(item.pixelWidth) × \(item.pixelHeight)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if item.hasProject {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Has annotations")
                }
            }
        }
        .contextMenu {
            Button("Annotate") { app.openEditor(item) }
            Button("Copy") { app.copy(item) }
            Button("Save") { app.save(item) }
            Button("Save As…") { app.saveAs(item) }
            Button("Pin to Screen") { app.pin(item) }
            Button("Show in Finder") { app.revealInFinder(item) }
            Divider()
            Button("Delete", role: .destructive) { app.delete(item) }
        }
    }

    private func action(_ symbol: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(help)
    }
}
