import AppKit
import SwiftUI

/// Floating post-capture thumbnails (the Quick Access overlay), stacked
/// in the bottom-left corner of the screen under the pointer.
final class QuickAccessManager {
    private var panels: [(id: UUID, panel: NSPanel)] = []
    private var closeTasks: [UUID: Task<Void, Never>] = [:]
    private let cardSize = CGSize(width: 240, height: 170)
    private let margin: CGFloat = 20

    func show(_ item: HistoryItem) {
        let view = QuickAccessCard(item: item, app: AppState.shared) { [weak self] in self?.dismiss(item.id) }
        let hosting = NSHostingView(rootView: view)
        let panel = QuickAccessPanel(contentRect: CGRect(origin: .zero, size: cardSize),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKey = { [weak self] key in self?.handle(key, item: item) }

        panels.insert((item.id, panel), at: 0)
        layout(animated: false, appearing: panel)
        panel.orderFrontRegardless()
        layout(animated: true)

        let seconds = Preferences.shared.quickAccessAutoCloseSeconds
        if seconds > 0 {
            closeTasks[item.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.dismiss(item.id)
            }
        }
    }

    func dismiss(_ id: UUID) {
        closeTasks.removeValue(forKey: id)?.cancel()
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = panels.remove(at: index).panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        layout(animated: true)
    }

    func dismissAll() {
        for entry in panels { dismiss(entry.id) }
    }

    private func handle(_ key: QuickAccessPanel.Key, item: HistoryItem) {
        let app = AppState.shared
        switch key {
        case .copy: app.copy(item); dismiss(item.id)
        case .save: app.save(item); dismiss(item.id)
        case .edit: app.openEditor(item)
        case .pin: app.pin(item); dismiss(item.id)
        case .close: dismiss(item.id)
        }
    }

    private func layout(animated: Bool, appearing: NSPanel? = nil) {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        for (index, entry) in panels.enumerated() {
            let y = visible.minY + margin + CGFloat(index) * (cardSize.height + 12)
            var frame = CGRect(x: visible.minX + margin, y: y, width: cardSize.width, height: cardSize.height)
            if entry.panel === appearing {
                // Slide in from off-screen left.
                frame.origin.x = visible.minX - cardSize.width
                entry.panel.setFrame(frame, display: false)
                continue
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    entry.panel.animator().setFrame(frame, display: true)
                }
            } else {
                entry.panel.setFrame(frame, display: true)
            }
        }
    }
}

final class QuickAccessPanel: NSPanel {
    enum Key { case copy, save, edit, pin, close }
    var onKey: ((Key) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onKey?(.close); return }
        if event.keyCode == 36 { onKey?(.save); return }
        if event.keyCode == 49 { onKey?(.pin); return }
        guard event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c": onKey?(.copy)
        case "s": onKey?(.save)
        case "e": onKey?(.edit)
        case "p": onKey?(.pin)
        case "w": onKey?(.close)
        default: super.keyDown(with: event)
        }
    }
}

private struct QuickAccessCard: View {
    let item: HistoryItem
    let app: AppState
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            thumbnail
            if hovering {
                Rectangle().fill(.black.opacity(0.25))
                    .background(.ultraThinMaterial.opacity(0.6))
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        pill("Copy", "doc.on.doc") { app.copy(item); dismiss() }
                        pill("Save", "square.and.arrow.down") { app.save(item); dismiss() }
                    }
                    pill("Annotate", "pencil.tip.crop.circle") { app.openEditor(item) }
                }
                VStack {
                    HStack {
                        circleButton("xmark", help: "Close (Esc)") { dismiss() }
                        Spacer()
                        circleButton("pin", help: "Pin to Screen") { app.pin(item); dismiss() }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        circleButton("trash", help: "Delete") { app.delete(item) }
                    }
                }
                .padding(8)
            }
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .padding(6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { app.openEditor(item) }
        .onDrag {
            guard let url = app.dragFile(for: item) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy") { app.copy(item); dismiss() }
            Button("Save") { app.save(item); dismiss() }
            Button("Save As…") { app.saveAs(item) }
            Button("Annotate") { app.openEditor(item) }
            Button("Pin to Screen") { app.pin(item); dismiss() }
            Divider()
            Button("Show in Finder") { app.revealInFinder(item) }
            Button("Close") { dismiss() }
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let image = app.history.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(item.kind == .window ? 10 : 6)
            }
        }
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }
}
