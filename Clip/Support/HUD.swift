import AppKit
import SwiftUI

/// A brief, non-activating confirmation bubble near the bottom of the screen.
enum HUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String, duration: TimeInterval = 1.6) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: HUDView(message: message, symbol: symbol))
        hosting.setFrameSize(hosting.fittingSize)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        if let screen = NSScreen.underMouse {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - hosting.fittingSize.width / 2, y: frame.minY + 80))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
            panel.orderOut(nil)
        }
    }
}

private struct HUDView: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.body.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
    }
}
