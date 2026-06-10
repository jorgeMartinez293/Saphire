import AppKit
import Carbon

/// Thin wrapper around Carbon's RegisterEventHotKey for a single global shortcut.
/// Works system-wide without Accessibility permissions. Carbon hot-key events
/// are delivered on the main thread, so all state stays MainActor-isolated.
///
/// Reports both press and release so callers can tell a quick tap from a
/// press-and-hold (used for push-to-talk voice dictation).
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let onKeyDown: () -> Void
    private let onKeyUp: (() -> Void)?
    private let id: UInt32

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// - Parameters:
    ///   - keyCode: virtual key code (e.g. `UInt32(kVK_Space)`).
    ///   - modifiers: Carbon modifier mask (e.g. `UInt32(optionKey)`).
    ///   - onKeyDown: fired when the combo is pressed.
    ///   - onKeyUp: fired when the combo is released (optional).
    init?(keyCode: UInt32, modifiers: UInt32,
          onKeyDown: @escaping () -> Void,
          onKeyUp: (() -> Void)? = nil) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self
        HotKey.installHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: OSType(0x454D5244), id: id) // 'EMRD'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hkID,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        if status != noErr {
            HotKey.instances[id] = nil
            return nil
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        HotKey.instances[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                guard let event else { return noErr }
                let kind = GetEventKind(event)
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                // Carbon delivers this on the main thread.
                MainActor.assumeIsolated {
                    guard let hk = HotKey.instances[hkID.id] else { return }
                    if kind == UInt32(kEventHotKeyReleased) {
                        hk.onKeyUp?()
                    } else {
                        hk.onKeyDown()
                    }
                }
                return noErr
            },
            2, &eventTypes, nil, nil
        )
    }
}
