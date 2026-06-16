import AppKit
import SwiftUI

// MARK: - In-app notification toasts
//
// macOS only presents UNUserNotificationCenter banners for apps whose code
// signature passes AMFI validation (notarized / Developer ID / a provisioning
// -profile dev build). Saphire is built and signed locally, so usernoted
// *accepts* every notification request but records the app as Denied and
// presents each banner "as none": no prompt ever appears, no banner is shown,
// and the only symptom in-process is UNErrorDomain Code=1 from
// requestAuthorization. (Verified on macOS 26: the requests land in
// usernoted's store with presented=0, style=0.)
//
// These toasts replicate the banner in-process — floating, non-activating
// panels in the top-right corner — so watcher/task/inbox alerts work no
// matter how the bundle is signed. `AppState.deliverUserAlert` still prefers
// real system notifications when the app is genuinely authorized.

/// Borderless, non-activating panel that hosts one toast.
private final class ToastPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovableByWindowBackground = false
    }

    // Toasts must never steal focus from whatever the user is doing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even while its window is
/// not key (it never is — the panel can't become key).
private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ToastView: View {
    let title: String
    let body_: String
    /// Called with `true` when the toast body is clicked (open the app),
    /// `false` when the ✕ is clicked (just dismiss).
    let onAction: (Bool) -> Void

    @State private var hoveringClose = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 0.478, green: 0.443, blue: 0.761),
                                            Color(red: 0.204, green: 0.600, blue: 0.867)],
                                   startPoint: .top, endPoint: .bottom))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                Text(body_)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onAction(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(hoveringClose ? 0.14 : 0.0))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onAction(true) }
    }
}

/// Shows and stacks toasts in the top-right corner of the main screen.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    private var panels: [ToastPanel] = []
    private let margin: CGFloat = 14
    private let spacing: CGFloat = 10

    /// Presents a toast for `duration` seconds. Clicking its body runs
    /// `onTap` (e.g. open the inbox); the ✕ just dismisses it.
    func show(title: String, body: String, duration: TimeInterval = 8,
              onTap: (() -> Void)? = nil) {
        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64))
        let view = ToastView(title: title, body_: body) { [weak self, weak panel] tapped in
            guard let self, let panel else { return }
            self.dismiss(panel)
            if tapped { onTap?() }
        }
        let host = ToastHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host

        panels.append(panel)
        layout(placing: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        NSSound(named: "Glass")?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.dismiss(panel)
        }
    }

    private func dismiss(_ panel: ToastPanel) {
        guard panels.contains(panel) else { return }   // already dismissed
        panels.removeAll { $0 === panel }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
        layout()
    }

    /// Re-stacks the visible toasts from the top-right corner downward.
    /// `placing` is a just-created panel that jumps straight to its slot
    /// (animating it would slide it in from the window's default origin).
    private func layout(placing newPanel: ToastPanel? = nil) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        var y = vf.maxY - margin
        for panel in panels {
            let f = panel.frame
            let origin = NSPoint(x: vf.maxX - margin - f.width, y: y - f.height)
            if panel === newPanel {
                panel.setFrameOrigin(origin)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrameOrigin(origin)
                }
            }
            y -= f.height + spacing
        }
    }
}
