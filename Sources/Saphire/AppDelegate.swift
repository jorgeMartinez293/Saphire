import AppKit
import SwiftUI
import Carbon
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    private var panel: OverlayPanel?
    private var mainWindow: NSWindow?

    private let overlayWidth: CGFloat = 560

    // Push-to-talk: holding ⌥Space past this threshold starts voice dictation;
    // a quicker tap just toggles the overlay.
    private let holdThreshold: TimeInterval = 1.0
    private var holdTimer: Timer?
    private var keyIsDown = false
    private var voiceActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        // Let the model layer surface the overlay (e.g. to show the question
        // inbox) and route notification taps back to us.
        state.onShowOverlay = { [weak self] in self?.showOverlay() }
        UNUserNotificationCenter.current().delegate = self

        // ⌥Space: quick tap toggles the overlay; hold ≥1s dictates by voice.
        hotKey = HotKey(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey),
            onKeyDown: { [weak self] in self?.hotKeyDown() },
            onKeyUp: { [weak self] in self?.hotKeyUp() }
        )

        Task { await state.loadModels() }
    }

    // MARK: - Hot-key press/hold handling

    private func hotKeyDown() {
        // Carbon may repeat the press while held; only react to the first edge.
        guard !keyIsDown else { return }
        keyIsDown = true
        voiceActive = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.beginVoice() }
        }
    }

    private func hotKeyUp() {
        keyIsDown = false
        holdTimer?.invalidate()
        holdTimer = nil
        if voiceActive {
            // Finalize only once the mic is actually live. If the user released
            // before it came up, the start Task (see beginVoice) sends instead.
            if state.isListening {
                voiceActive = false
                state.stopVoiceInput(send: true)   // release → send dictated question
            }
        } else {
            toggleOverlay()                        // quick tap → show/hide overlay
        }
    }

    /// Fired when ⌥Space has been held past the threshold: open the overlay and
    /// start listening.
    private func beginVoice() {
        guard keyIsDown else { return }
        voiceActive = true
        // Show the overlay if hidden; if already open, just focus it (don't
        // yank it back to the top-center if the user dragged it elsewhere).
        if !(panel?.isVisible ?? false) {
            showOverlay()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        }
        Task {
            await state.startVoiceInput()
            // The key may already be up by the time the mic is ready; if so,
            // send now (covers both a fast release and a denied permission).
            if !self.keyIsDown && self.voiceActive {
                self.voiceActive = false
                self.state.stopVoiceInput(send: true)
            }
        }
    }

    // MARK: - Main menu

    /// The app runs as an accessory (no visible menu bar most of the time), but
    /// macOS still routes ⌘-key equivalents through `NSApp.mainMenu`. Without an
    /// Edit menu the standard copy/cut/paste/select-all/undo shortcuts never
    /// reach the first responder (text fields, the WKWebView chat), so the only
    /// way to copy was the right-click context menu. This wires them up.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — provides ⌘Z/⌘X/⌘C/⌘V/⌘A via the responder chain.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: "Saphire")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Overlay  (⌥Space)", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Abrir ventana", action: #selector(showMainWindow), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(quit), keyEquivalent: "q")
        for i in menu.items { i.target = self }
        item.menu = menu
        statusItem = item
    }

    // MARK: - Overlay

    @objc func toggleOverlay() {
        // Window open → collapse it back into the overlay.
        if let w = mainWindow, w.isVisible {
            returnToOverlay()
            return
        }
        if let p = panel, p.isVisible {
            p.fadeOut()
            return
        }
        showOverlay()
    }

    /// Hide the main window and bring the overlay back (drops to accessory so
    /// the app returns to its background-agent state).
    private func returnToOverlay() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        showOverlay()
    }

    private func showOverlay() {
        let p = panel ?? makeOverlayPanel()
        panel = p
        positionOverlayTopCenter(p)
        NSApp.activate(ignoringOtherApps: true)
        p.fadeIn()
    }

    private func makeOverlayPanel() -> OverlayPanel {
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: 64))
        let root = OverlayView(
            onSubmitExpand: { [weak self] in self?.resizeOverlay(to: $0) },
            onOpenWindow: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.showMainWindow()
            }
        ).environmentObject(state)
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// Resize keeping the top edge fixed (overlay grows downward), with a
    /// short ease-out so expansion feels fluid instead of snapping.
    private func resizeOverlay(to height: CGFloat) {
        guard let p = panel else { return }
        let h = min(max(height, 64), 640)
        var frame = p.frame
        guard abs(frame.height - h) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = h
        frame.origin.y = top - h
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
        }
    }

    private func positionOverlayTopCenter(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - overlayWidth / 2
        let y = vf.maxY - 160 - p.frame.height
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Main window

    @objc func showMainWindow() {
        if let w = mainWindow {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.center()
        w.setFrameAutosaveName("SaphireMain")
        w.isReleasedWhenClosed = false
        let root = MainView(onReturnToOverlay: { [weak self] in self?.returnToOverlay() })
            .environmentObject(state)
        w.contentView = NSHostingView(rootView: root)

        // Model picker + settings live in the title bar (trailing), so they sit
        // above the window's drag region and stay clickable.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let controls = NSHostingView(rootView: TitlebarControls().environmentObject(state))
        controls.frame.size = controls.fittingSize
        accessory.view = controls
        w.addTitlebarAccessoryViewController(accessory)

        w.delegate = self
        mainWindow = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show the banner even when Saphire is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Tapping an inbox notification opens the overlay inbox.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isInbox = response.notification.request.content.categoryIdentifier
            == AppState.questionCategoryID
        Task { @MainActor in
            if isInbox { self.state.showInbox() }
        }
        completionHandler()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Back to background agent when the main window closes.
        if (notification.object as? NSWindow) === mainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
