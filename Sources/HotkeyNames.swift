import AppKit
import CoreGraphics
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.backtick, modifiers: .option))
}

/// Callback order is not authoritative; only a physical hold can start/continue recording.
struct PushToTalkGate {
    private(set) var isRecording = false

    mutating func press(physicallyHeld: Bool) -> Bool {
        guard physicallyHeld, !isRecording else { return false }
        isRecording = true
        return true
    }

    mutating func release(physicallyHeld: Bool) -> Bool {
        guard !physicallyHeld, isRecording else { return false }
        isRecording = false
        return true
    }

    mutating func reset() { isRecording = false }
}

@MainActor
func isDictationShortcutPhysicallyHeld() -> Bool {
    guard let shortcut = KeyboardShortcuts.getShortcut(for: .dictate) else { return false }
    let key = CGKeyCode(shortcut.carbonKeyCode)
    // The shortcut callback already validates modifiers. Follow its trigger key so
    // modifier-free injected text cannot interrupt the hold. Session state also
    // supports virtual/remote keyboards that do not originate from physical HID.
    return CGEventSource.keyState(.hidSystemState, key: key)
        || CGEventSource.keyState(.combinedSessionState, key: key)
}
