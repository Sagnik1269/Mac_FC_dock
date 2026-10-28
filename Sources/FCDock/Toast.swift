import AppKit
import SwiftUI

/// A small status pill near the bottom of the screen the cursor is on.
final class Toast {
    static let shared = Toast()

    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 2.4) {
        let host = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        let size = host.fittingSize
        let panel = self.panel ?? OverlayPanel(size: size)
        self.panel = panel
        panel.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height),
                display: true
            )
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel?.animator().alphaValue = 0 }) {
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(message).lineLimit(2)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(VisualEffectBackground(material: .hudWindow).clipShape(Capsule()))
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}

/// SwiftUI materials go flat when the app isn't active; this keeps the blur live.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    /// Below 1 the sharp background shows through the blur, making it look less frosted.
    var opacity: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = opacity
    }
}
