import AppKit
import ApplicationServices
import Carbon

/// A suffix edit in grapheme clusters, so revisions never split an emoji or combining mark.
struct LiveTextEdit: Equatable {
    let backspaces: Int
    let insertion: String
    let prefixUTF16Count: Int

    static func between(_ previous: String, and next: String) -> Self {
        let prefix = String(zip(previous, next).prefix { $0.0.unicodeScalars.elementsEqual($0.1.unicodeScalars) }.map { $0.0 })
        return Self(backspaces: previous.count - prefix.count,
                    insertion: String(next.dropFirst(prefix.count)),
                    prefixUTF16Count: prefix.utf16.count)
    }
}

struct TextTargetSnapshot: Equatable {
    var value: String?
    var selection: NSRange?
}

/// A boundary separator belongs to this dictation, so preview and final revisions share it.
enum DictationSpacing {
    static func prepare(_ text: String, at initial: TextTargetSnapshot,
                        assumeExistingPrecedingText: Bool = false) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }
        if let value = initial.value, let selection = initial.selection {
            // A readable empty field, a selection, or a caret in the middle is
            // authoritative: never apply a continuation hint there.
            guard selection.length == 0, selection.location == value.utf16.count,
                  let previous = value.last, !previous.isWhitespace else { return text }
            return needsSeparator(after: previous, before: first, precedingText: value) ? " " + text : text
        }
        // Some web editors accept keystrokes but deliberately do not expose their
        // field value to Accessibility.  If this is a continuation of a completed
        // dictation in that same app, preserve the expected word boundary.
        if assumeExistingPrecedingText, !".,!?;:)]}…%’”".contains(first) {
            return " " + text
        }
        return text
    }

    private static func needsSeparator(after previous: Character, before first: Character,
                                       precedingText: String) -> Bool {
        // Punctuation attaches to the prior text; opening delimiters and joiners attach to the next word.
        if ".,!?;:)]}…%’”".contains(first) || "([{“‘/\\@#$€£-—".contains(previous) { return false }
        if previous == "\"" || previous == "'" {
            guard let beforeQuote = precedingText.dropLast().last,
                  !beforeQuote.isWhitespace, !"([{“‘".contains(beforeQuote) else { return false }
        }
        return true
    }
}

/// Tracks only this dictation's range, preserving text before and after the initial selection.
struct DictationTextBuffer {
    private(set) var snapshot: TextTargetSnapshot
    private(set) var text = ""
    private let anchor: Int
    private var replacedLength: Int

    init?(snapshot: TextTargetSnapshot) {
        guard let value = snapshot.value, let selection = snapshot.selection,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        self.snapshot = snapshot
        anchor = selection.location
        replacedLength = selection.length
    }

    func replacementRange(for edit: LiveTextEdit) -> NSRange {
        NSRange(location: anchor + edit.prefixUTF16Count,
                length: replacedLength - edit.prefixUTF16Count)
    }

    mutating func accept(_ next: String) {
        guard let value = snapshot.value else { return }
        snapshot.value = (value as NSString).replacingCharacters(
            in: NSRange(location: anchor, length: replacedLength), with: next)
        snapshot.selection = NSRange(location: anchor + next.utf16.count, length: 0)
        replacedLength = next.utf16.count
        text = next
    }
}

enum DirectTextReplacement {
    case applied
    case unsupported
    case uncertain
}

@MainActor
protocol DictationTextTarget: AnyObject {
    var isFocused: Bool { get }
    var supportsDirectReplacement: Bool { get }
    func snapshot() -> TextTargetSnapshot
    func replace(range: NSRange, with text: String, restoring selection: NSRange) -> DirectTextReplacement
    func type(_ edit: LiveTextEdit) -> Bool
}

/// One session owns its inserted text. Finalization reconciles that text rather than pasting again.
@MainActor
final class LiveTypingSession {
    private let target: any DictationTextTarget
    private var trackedBuffer: DictationTextBuffer?
    private var currentText = ""
    private let originalSelectionText: String
    private let spacingContext: TextTargetSnapshot
    private let assumeExistingPrecedingText: Bool
    private var useKeyboard: Bool
    private var inputMonitor: Any?
    private var safePasteFallback = false
    private var awaitingInitialKeyboardEcho = false
    private(set) var suspendedReason: String?

    init(target: any DictationTextTarget, preferKeyboard: Bool = true,
         assumeExistingPrecedingText: Bool = false) {
        self.target = target
        useKeyboard = preferKeyboard
        self.assumeExistingPrecedingText = assumeExistingPrecedingText
        let initial = target.snapshot()
        spacingContext = initial
        trackedBuffer = DictationTextBuffer(snapshot: initial)
        DictationDiagnostics.record("target.snapshot.initial", Self.describe(initial))
        if trackedBuffer != nil, let value = initial.value, let selection = initial.selection {
            originalSelectionText = (value as NSString).substring(with: selection)
        } else {
            originalSelectionText = ""
        }
    }

    func cancel() async {
        if !currentText.isEmpty { await update(text: originalSelectionText) }
        end()
    }

    /// `keyCode` raises an Objective-C exception on mouse events, so check the type first.
    /// On the main queue AppKit swallows that exception mid-drain, stalling every MainActor task.
    nonisolated static func isDictationShortcutKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 50
    }

    func monitorUserInput() {
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == NativeTextTarget.eventTag { return }
            let isShortcutKey = Self.isDictationShortcutKey(event)
            if isShortcutKey, event.modifierFlags.contains(.option) { return }
            let eventType = String(event.type.rawValue)
            Task { @MainActor [weak self] in
                DictationDiagnostics.record("input.observed", ["eventType": eventType,
                    "isShortcutKey": String(isShortcutKey)])
                self?.suspend("Typing or cursor movement interrupted live insertion")
            }
        }
    }

    func end() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    func suspend(_ reason: String) {
        safePasteFallback = false
        if suspendedReason == nil {
            suspendedReason = reason
            DictationDiagnostics.record("insertion.suspended", ["reason": reason])
        }
    }

    /// Only retry a final paste after a confirmed no-op, never after a partial live insertion.
    var canPasteFinalText: Bool {
        guard safePasteFallback, currentText.isEmpty, target.isFocused, let trackedBuffer else { return false }
        return target.snapshot() == trackedBuffer.snapshot
    }

    @discardableResult
    func update(text: String) async -> Bool {
        let next = preparedText(text)
        // The final Whisper pass commonly agrees with the last live preview.  In that
        // case there is nothing left to type, and asking a slow Accessibility client
        // to re-read the field can leave the finishing UI up indefinitely.
        guard next != currentText else { return true }
        guard await confirmCurrentSnapshot() else { return false }
        let edit = LiveTextEdit.between(currentText, and: next)
        if !useKeyboard, target.supportsDirectReplacement, let trackedBuffer,
           let selection = trackedBuffer.snapshot.selection {
            DictationDiagnostics.record("insertion.direct.attempt", ["characters": String(next.count)])
            switch target.replace(range: trackedBuffer.replacementRange(for: edit),
                                  with: edit.insertion, restoring: selection) {
            case .applied:
                var expected = trackedBuffer
                expected.accept(next)
                let observed = target.snapshot()
                guard observed == expected.snapshot else {
                    DictationDiagnostics.record("insertion.direct.unconfirmed", Self.describe(observed))
                    DictationDiagnostics.record("insertion.direct.expected", Self.describe(expected.snapshot))
                    // A reported AX success can be ignored by an app. Do not paste a second copy.
                    suspend("The app did not confirm the text update")
                    safePasteFallback = currentText.isEmpty && observed == trackedBuffer.snapshot
                    return false
                }
                self.trackedBuffer = expected
                currentText = next
                DictationDiagnostics.record("insertion.direct.confirmed")
                return true
            case .unsupported:
                guard target.snapshot() == trackedBuffer.snapshot else {
                    suspend("The target changed while switching insertion methods")
                    return false
                }
                useKeyboard = true
            case .uncertain:
                suspend("The app could not confirm the text selection")
                return false
            }
        }
        let isInitialEmptyCaret = currentText.isEmpty && trackedBuffer?.snapshot.selection == NSRange(location: 0, length: 0)
        DictationDiagnostics.record("insertion.keyboard.attempt", ["backspaces": String(edit.backspaces),
            "characters": String(edit.insertion.count)])
        guard target.type(edit) else {
            suspend("Keyboard text insertion failed")
            safePasteFallback = currentText.isEmpty && trackedBuffer.map { target.snapshot() == $0.snapshot } == true
            return false
        }
        awaitingInitialKeyboardEcho = isInitialEmptyCaret
        trackedBuffer?.accept(next)
        currentText = next
        DictationDiagnostics.record("insertion.keyboard.posted")
        return await confirmCurrentSnapshot()
    }

    /// Keyboard events and accessibility readback are asynchronous in many editors.
    /// Wait for acknowledgment instead of interpreting a delayed echo as a user edit.
    private func confirmCurrentSnapshot() async -> Bool {
        for attempt in 0...5 {
            guard !Task.isCancelled, suspendedReason == nil else { return false }
            guard target.isFocused else {
                suspend("The target field lost focus")
                return false
            }
            guard let trackedBuffer else { return true }
            let observed = target.snapshot()
            if observed == trackedBuffer.snapshot {
                awaitingInitialKeyboardEcho = false
                return true
            }
            if awaitingInitialKeyboardEcho, !currentText.isEmpty,
               observed.value == currentText,
               observed.selection == NSRange(location: currentText.utf16.count, length: 0) {
                var actual = DictationTextBuffer(snapshot: TextTargetSnapshot(value: "", selection: NSRange(location: 0, length: 0)))!
                actual.accept(currentText)
                self.trackedBuffer = actual
                awaitingInitialKeyboardEcho = false
                DictationDiagnostics.record("target.emptyBaseline.confirmed", Self.describe(observed))
                return true
            }
            if attempt == 5 {
                DictationDiagnostics.record("target.snapshot.changed", Self.describe(observed))
                DictationDiagnostics.record("target.snapshot.expected", Self.describe(trackedBuffer.snapshot))
                suspend("The target text or cursor changed")
                return false
            }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return false
    }

    func preparedText(_ text: String) -> String {
        // Never synthesize Return into a terminal. Whisper also normalizes speech whitespace.
        let normalized = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return DictationSpacing.prepare(normalized, at: spacingContext,
                                        assumeExistingPrecedingText: assumeExistingPrecedingText)
    }

    private static func describe(_ snapshot: TextTargetSnapshot) -> [String: String] {
        ["valuePresent": String(snapshot.value != nil), "valueUTF16Length": String(snapshot.value?.utf16.count ?? -1),
         "selectionLocation": String(snapshot.selection?.location ?? -1), "selectionLength": String(snapshot.selection?.length ?? -1)]
    }
}

@MainActor
final class NativeTextTarget: DictationTextTarget {
    // Distinguishes our events from the user's typing in the global input monitor.
    static let eventTag: Int64 = 0x4449_4354_4154_45
    private let application: NSRunningApplication
    private let element: AXUIElement?
    private let window: AXUIElement?

    init(application: NSRunningApplication) {
        self.application = application
        let focused = Self.focusedElement()
        element = focused
        window = focused.flatMap { Self.elementAttribute($0, kAXWindowAttribute) }
        if let focused { AXUIElementSetMessagingTimeout(focused, 0.5) }
        var focusedPID: pid_t = 0
        if let focused { AXUIElementGetPid(focused, &focusedPID) }
        let reportedValue = focused.flatMap { Self.attribute($0, kAXValueAttribute) as? String }
        let placeholder = focused.flatMap { Self.attribute($0, "AXPlaceholderValue") as? String }
        DictationDiagnostics.record("target.captured", ["pid": String(application.processIdentifier),
            "focusedPID": String(focusedPID), "role": focused.flatMap { Self.attribute($0, kAXRoleAttribute) as? String } ?? "unavailable",
            "contextReadable": String(hasEditableContext), "insertionMethod": "keyboard",
            "valueMatchesPlaceholder": String(reportedValue != nil && placeholder != nil && reportedValue == placeholder),
            "reportedCharacters": focused.flatMap { Self.attribute($0, kAXNumberOfCharactersAttribute) as? NSNumber }?.stringValue ?? "unavailable"])
    }

    var isFocused: Bool {
        let reason: String?
        if !AXIsProcessTrusted() { reason = "accessibilityNotTrusted" }
        else if IsSecureEventInputEnabled() { reason = "secureInputEnabled" }
        else if application.isTerminated { reason = "targetTerminated" }
        else if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier { reason = "frontmostAppChanged" }
        else if let element {
            if let focused = Self.focusedElement(), CFEqual(element, focused) {
                if let window, let focusedWindow = Self.elementAttribute(focused, kAXWindowAttribute), !CFEqual(window, focusedWindow) {
                    reason = "focusedWindowChanged"
                } else { reason = nil }
            } else { reason = "focusedElementChangedOrUnavailable" }
        } else { reason = nil }
        if let reason {
            DictationDiagnostics.record("focus.check.failed", ["reason": reason,
                "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unavailable"])
            return false
        }
        return true
    }

    var supportsDirectReplacement: Bool {
        guard let element else { return false }
        var textSettable = DarwinBoolean(false)
        var selectionSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success
            && AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &selectionSettable) == .success
            && textSettable.boolValue && selectionSettable.boolValue
    }

    private var hasEditableContext: Bool {
        guard let element,
              let role = Self.attribute(element, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
        return Self.isSettable(element, kAXValueAttribute) || Self.isSettable(element, kAXSelectedTextAttribute)
    }

    func snapshot() -> TextTargetSnapshot {
        // Read-only surfaces can expose scrollback or document text rather than an edit buffer.
        // Keystrokes still work there; use context only when the control exposes editable text.
        guard hasEditableContext, let element else { return TextTargetSnapshot() }
        let value = Self.attribute(element, kAXValueAttribute) as? String
        var range = CFRange()
        var selection: NSRange?
        if let wrapped = Self.attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(wrapped) == AXValueGetTypeID(),
           AXValueGetValue(wrapped as! AXValue, .cfRange, &range) {
            selection = NSRange(location: range.location, length: range.length)
        }
        return TextTargetSnapshot(value: value, selection: selection)
    }

    func replace(range: NSRange, with text: String, restoring selection: NSRange) -> DirectTextReplacement {
        guard let element, setSelection(range, on: element) else { return .unsupported }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if result == .success {
            // Leave a collapsed caret at the end, matching normal typing in native and web editors.
            guard setSelection(NSRange(location: range.location + text.utf16.count, length: 0), on: element) else { return .uncertain }
            return .applied
        }
        return setSelection(selection, on: element) ? .unsupported : .uncertain
    }

    func type(_ edit: LiveTextEdit) -> Bool {
        guard isFocused, let source = CGEventSource(stateID: .privateState) else { return false }
        source.localEventsSuppressionInterval = 0
        var events: [CGEvent] = []
        for _ in 0..<edit.backspaces {
            guard let down = makeKey(source: source, code: 51, down: true),
                  let up = makeKey(source: source, code: 51, down: false) else { return false }
            events.append(contentsOf: [down, up])
        }
        // Keep scalar pairs intact when chunking UTF-16 for Quartz text events.
        var chunks: [[UInt16]] = [[]]
        for scalar in edit.insertion.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
            chunks[chunks.count - 1].append(contentsOf: units)
        }
        for chunk in chunks where !chunk.isEmpty {
            guard let down = makeKey(source: source, code: 0, down: true),
                  let up = makeKey(source: source, code: 0, down: false) else { return false }
            for event in [down, up] {
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            events.append(contentsOf: [down, up])
        }
        // Standard foreground delivery reaches Chromium's editor input handling. The same
        // application/field focus checks above remain required immediately before posting.
        for event in events { event.post(tap: .cgSessionEventTap) }
        return true
    }

    private func makeKey(source: CGEventSource, code: CGKeyCode, down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        // The push-to-talk Option modifier must never leak into injected characters/backspaces.
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        return event
    }

    private func setSelection(_ range: NSRange, on element: AXUIElement) -> Bool {
        var range = CFRange(location: range.location, length: range.length)
        guard let wrapped = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, wrapped) == .success
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func focusedElement() -> AXUIElement? {
        elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
