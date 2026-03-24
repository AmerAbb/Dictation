import AppKit
import ApplicationServices

@MainActor
class PasteService {
    /// Returns a diagnostic message about what happened
    func paste(text: String) -> String {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            copyToClipboard(text)
            return "AX not trusted - copied to clipboard"
        }

        // Try direct AX text insertion first (no clipboard needed)
        let axResult = tryAccessibilityInsert(text)
        if axResult == nil {
            return "Pasted via AX"
        }

        // AX failed - put on clipboard for Cmd+V methods
        copyToClipboard(text)

        // Try CGEvent (works in Terminal and most apps)
        let cgResult = tryCGEvent()
        if cgResult == nil {
            return "Pasted via CGEvent"
        }

        // Fallback: osascript
        let osResult = tryOsascript()
        if osResult == nil {
            return "Pasted via osascript"
        }

        // All paste methods failed - text is on clipboard as fallback
        return "Copied to clipboard (paste failed: AX=\(axResult!), CG=\(cgResult!), OS=\(osResult!))"
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func tryAccessibilityInsert(_ text: String) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        guard copyResult == .success, let element = focusedElement else {
            return "no-focus(\(copyResult.rawValue))"
        }

        let axElement = element as! AXUIElement
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if setResult != .success {
            return "set-failed(\(setResult.rawValue))"
        }

        // Verify it actually worked (some apps like Terminal report success but ignore it)
        // Only distrust AX if we can positively confirm the text isn't there
        var readBack: AnyObject?
        let readResult = AXUIElementCopyAttributeValue(
            axElement, kAXValueAttribute as CFString, &readBack
        )
        if readResult == .success, let value = readBack as? String, !value.contains(text) {
            return "set-ignored"
        }
        return nil // success (or can't verify, trust the set result)
    }

    private func tryOsascript() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            tell application "System Events" to keystroke "v" using command down
        """]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : "exit(\(process.terminationStatus))"
        } catch {
            return error.localizedDescription
        }
    }

    private func tryCGEvent() -> String? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return "create-failed"
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgSessionEventTap)
        return nil
    }
}
