import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Seconds since the last user input (keyboard, mouse, trackpad). Read from the
/// HID system state, so it reflects real activity regardless of which app is
/// frontmost. Returns 0 if the query fails (treated as "active").
func systemIdleSeconds() -> TimeInterval {
    let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
    let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    return idle.isFinite && idle >= 0 ? idle : 0
}

/// True when something is actively keeping the display awake — the assertion
/// apps raise while playing video or giving a presentation (Safari, QuickTime,
/// IINA, Zoom, etc.). A good proxy for "the user is watching something" even
/// when there's no keyboard/mouse input.
func displaySleepPrevented() -> Bool {
    var dict: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
          let assertions = dict?.takeRetainedValue() as? [String: Int] else { return false }
    let key = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
    return (assertions[key] ?? 0) > 0
}
