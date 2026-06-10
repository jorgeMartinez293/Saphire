import AppKit

/// Floating, non-activating panel used for the compact overlay.
/// Can become key (so the text field accepts input) but never main,
/// and joins all Spaces / full-screen apps so ⌥Space works anywhere.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes the overlay.
    override func cancelOperation(_ sender: Any?) {
        fadeOut()
    }

    /// Show with a quick fade + slight rise from below the resting position.
    func fadeIn() {
        let target = frame.origin
        setFrameOrigin(NSPoint(x: target.x, y: target.y - 10))
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrameOrigin(target)
        }
    }

    /// Hide with a quick fade, then order out and restore alpha for next show.
    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
                self?.alphaValue = 1
            }
        })
    }
}
