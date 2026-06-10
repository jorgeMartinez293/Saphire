import AppKit

// Background agent: no Dock icon by default; switches to .regular when the
// extended window opens (see AppDelegate.showMainWindow).
@main
enum SaphireMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
