import Foundation
import Testing
@testable import Dictation

@MainActor
private final class TestTextTarget: DictationTextTarget {
    var isFocused = true
    var supportsDirectReplacement = true
    var ignoreDirectWrites = false
    var leaveCaretUnchanged = false
    var placeholderValue: String?
    var exposesContext = true
    var delayedEchoReads = 0
    private var pendingSnapshot: TextTargetSnapshot?
    private var readsRemaining = 0
    var current = TextTargetSnapshot(value: "Before [replace] after", selection: NSRange(location: 7, length: 9))
    var directWrites = 0
    var keyboardWrites = 0
    var snapshotReads = 0

    func flushEcho() {
        if let pendingSnapshot { current = pendingSnapshot }
        pendingSnapshot = nil
        readsRemaining = 0
    }

    func snapshot() -> TextTargetSnapshot {
        snapshotReads += 1
        if pendingSnapshot != nil {
            if readsRemaining > 0 { readsRemaining -= 1 } else { flushEcho() }
        }
        guard exposesContext else { return TextTargetSnapshot() }
        var snapshot = current
        if current.value == "", let placeholderValue { snapshot.value = placeholderValue }
        return snapshot
    }

    func replace(range: NSRange, with text: String, restoring selection: NSRange) -> DirectTextReplacement {
        directWrites += 1
        if !ignoreDirectWrites {
            current.value = (current.value! as NSString).replacingCharacters(in: range, with: text)
            if !leaveCaretUnchanged {
                current.selection = NSRange(location: range.location + text.utf16.count, length: 0)
            }
        }
        return .applied
    }

    func type(_ edit: LiveTextEdit) -> Bool {
        keyboardWrites += 1
        let previous = current
        let value = current.value!
        let selection = current.selection!
        var before = String(value.prefix((value as NSString).substring(to: selection.location).count))
        let after = (value as NSString).substring(from: selection.location + selection.length)
        for _ in 0..<edit.backspaces { before.removeLast() }
        before += edit.insertion
        current.value = before + after
        current.selection = NSRange(location: before.utf16.count, length: 0)
        if delayedEchoReads > 0 {
            pendingSnapshot = current
            current = previous
            readsRemaining = delayedEchoReads
        }
        return true
    }
}

@Test @MainActor func livePreviewRevisionsAndFinalCorrectionPreserveSurroundingText() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "we sea"))
    #expect(target.current.value == "Before we sea after")
    #expect(await session.update(text: "we see tomorrow"))
    #expect(target.current.value == "Before we see tomorrow after")
    #expect(await session.update(text: "We will see tomorrow."))
    #expect(target.current.value == "Before We will see tomorrow. after")
    let writes = target.directWrites
    #expect(await session.update(text: "We will see tomorrow."))
    #expect(target.directWrites == writes)
}

@Test @MainActor func keyboardFallbackRevisesTextAndReplacesInitialSelection() async {
    let target = TestTextTarget()
    target.supportsDirectReplacement = false
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello 👩🏽‍💻 cafe\u{301}"))
    #expect(await session.update(text: "Hello 👩🏽‍💻 café!"))
    #expect(target.current.value == "Before Hello 👩🏽‍💻 café! after")
    #expect(await session.update(text: "Hello 👩🏽‍💻 café!"))
    #expect(target.keyboardWrites == 2)
    #expect(target.directWrites == 0)
}

@Test @MainActor func userEditsOrCursorMovesSuspendLiveReplacement() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello"))
    target.current.selection = NSRange(location: 0, length: 0)
    #expect(await session.update(text: "Hello there") == false)
    #expect(target.current.value == "Before Hello after")
    #expect(session.suspendedReason != nil)
}

@Test @MainActor func focusChangesDoNotTypeOrPasteIntoAnotherField() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello"))
    target.isFocused = false
    #expect(await session.update(text: "Hello there") == false)
    #expect(target.current.value == "Before Hello after")
    #expect(target.directWrites == 1)
}

@Test @MainActor func ignoredAccessibilitySuccessDoesNotDuplicateViaKeyboardFallback() async {
    let target = TestTextTarget()
    target.ignoreDirectWrites = true
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello") == false)
    #expect(target.keyboardWrites == 0)
    #expect(target.current.value == "Before [replace] after")
}

@Test func revisionsRespectGraphemesAndUTF16Ranges() {
    let edit = LiveTextEdit.between("Hi 👩🏽‍💻 tomorrow", and: "Hi 👩🏽‍💻 today")
    #expect(edit.backspaces == 6)
    #expect(edit.insertion == "day")
    #expect(edit.prefixUTF16Count == "Hi 👩🏽‍💻 to".utf16.count)
    let accent = LiveTextEdit.between("e\u{301}", and: "a")
    #expect(accent.backspaces == 1)
    #expect(accent.prefixUTF16Count == 0)
    let normalized = LiveTextEdit.between("e\u{301}", and: "é")
    #expect(normalized.backspaces == 1)
    #expect(normalized.insertion == "é")
}

@Test @MainActor func noSpeechRestoresTextReplacedByAProvisionalResult() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Temporary preview"))
    await session.cancel()
    #expect(target.current.value == "Before [replace] after")
}

@Test @MainActor func ignoredAXWriteAllowsFinalPasteOnlyWhileOriginalFieldIsUnchanged() async {
    let target = TestTextTarget()
    target.ignoreDirectWrites = true
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello") == false)
    #expect(session.canPasteFinalText)
    target.isFocused = false
    #expect(!session.canPasteFinalText)
    target.isFocused = true
    target.current.selection = NSRange(location: 0, length: 0)
    #expect(!session.canPasteFinalText)
}

@Test @MainActor func partialAXWriteNeverAllowsAnAdditionalFinalPaste() async {
    let target = TestTextTarget()
    target.leaveCaretUnchanged = true
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello") == false)
    #expect(target.current.value == "Before Hello after")
    #expect(!session.canPasteFinalText)
}

@Test @MainActor func ignoredRevisionAfterSuccessfulInsertionCannotDuplicateTheTranscript() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello"))
    target.ignoreDirectWrites = true
    #expect(await session.update(text: "Hello there") == false)
    #expect(!session.canPasteFinalText)
}

@Test @MainActor func manualInputCancelsAnOtherwiseSafeFinalPasteRetry() async {
    let target = TestTextTarget()
    target.ignoreDirectWrites = true
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello") == false)
    #expect(session.canPasteFinalText)
    session.suspend("User typed or moved the cursor")
    #expect(!session.canPasteFinalText)
}

@Test @MainActor func emptyEditorPlaceholderDoesNotStopInsertionAfterTheFirstWord() async {
    let target = TestTextTarget()
    target.supportsDirectReplacement = false
    target.placeholderValue = "Message"
    target.current = TextTargetSnapshot(value: "", selection: NSRange(location: 0, length: 0))
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello"))
    #expect(await session.update(text: "Hello there"))
    #expect(await session.update(text: "Hello there!"))
    #expect(target.current.value == "Hello there!")
    #expect(session.suspendedReason == nil)
}

@Test @MainActor func actualExistingTextMatchingAPlaceholderIsStillPreserved() async {
    let target = TestTextTarget()
    target.supportsDirectReplacement = false
    target.placeholderValue = "Message"
    target.current = TextTargetSnapshot(value: "Message", selection: NSRange(location: 0, length: 0))
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Hello"))
    #expect(await session.update(text: "Hello there"))
    #expect(target.current.value == "Hello thereMessage")
}

@Test @MainActor func consecutiveDictationsAddOnlyOneBoundarySpaceAcrossPreviewAndFinalEdits() async {
    let target = TestTextTarget()
    target.supportsDirectReplacement = false
    let firstSentence = "First sentence."
    target.current = TextTargetSnapshot(value: firstSentence, selection: NSRange(location: firstSentence.utf16.count, length: 0))
    let second = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await second.update(text: "Second"))
    #expect(await second.update(text: "Second sentence."))
    #expect(await second.update(text: "Second sentence."))
    #expect(target.current.value == "First sentence. Second sentence.")
    second.end()
    let third = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await third.update(text: "Third sentence."))
    #expect(target.current.value == "First sentence. Second sentence. Third sentence.")
}

@Test func boundarySpacingRespectsWhitespaceAndPunctuation() {
    let cases: [(String, String, String)] = [
        ("Hello", "world", " world"),
        ("Hello.", "Next sentence.", " Next sentence."),
        ("Hello ", "world", "world"),
        ("Hello\n", "world", "world"),
        ("Hello", ", world", ", world"),
        ("(", "hello", "hello"),
        ("path/", "folder", "folder"),
        ("He said \"", "hello", "hello"),
        ("He said \"hello.\"", "Next sentence.", " Next sentence."),
        ("👋", "Hello", " Hello"),
        ("", "Hello", "Hello"),
        ("Hello.", "", "")
    ]
    for (existing, spoken, expected) in cases {
        let initial = TextTargetSnapshot(value: existing, selection: NSRange(location: existing.utf16.count, length: 0))
        #expect(DictationSpacing.prepare(spoken, at: initial) == expected)
    }
}

@Test func selectedTextAndMidWordDictationDoNotGetAnExtraSpace() {
    let selection = TextTargetSnapshot(value: "Hello world", selection: NSRange(location: 6, length: 5))
    #expect(DictationSpacing.prepare("there", at: selection) == "there")
    let midWord = TextTargetSnapshot(value: "Hello", selection: NSRange(location: 2, length: 0))
    #expect(DictationSpacing.prepare("y", at: midWord) == "y")
    #expect(DictationSpacing.prepare("Hello", at: TextTargetSnapshot()) == "Hello")
}

@Test func continuationHintAddsASpaceOnlyWhenTextContextIsUnavailable() {
    #expect(DictationSpacing.prepare("Next", at: TextTargetSnapshot(), assumeExistingPrecedingText: true) == " Next")
    #expect(DictationSpacing.prepare(", next", at: TextTargetSnapshot(), assumeExistingPrecedingText: true) == ", next")
    let empty = TextTargetSnapshot(value: "", selection: NSRange(location: 0, length: 0))
    #expect(DictationSpacing.prepare("First", at: empty, assumeExistingPrecedingText: true) == "First")
    let selected = TextTargetSnapshot(value: "Existing text", selection: NSRange(location: 0, length: 8))
    #expect(DictationSpacing.prepare("Replacement", at: selected, assumeExistingPrecedingText: true) == "Replacement")
}

@Test @MainActor func noSpeechRemovesTheAutomaticSeparatorAlongWithThePreview() async {
    let target = TestTextTarget()
    let existing = "First sentence."
    target.current = TextTargetSnapshot(value: existing, selection: NSRange(location: existing.utf16.count, length: 0))
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Temporary preview"))
    #expect(target.current.value == "First sentence. Temporary preview")
    await session.cancel()
    #expect(target.current.value == existing)
}

@Test @MainActor func finalPasteFallbackUsesTheSameBoundarySpacing() async {
    let target = TestTextTarget()
    let existing = "First sentence."
    target.current = TextTargetSnapshot(value: existing, selection: NSRange(location: existing.utf16.count, length: 0))
    target.ignoreDirectWrites = true
    let session = LiveTypingSession(target: target, preferKeyboard: false)
    #expect(await session.update(text: "Next sentence.") == false)
    #expect(session.canPasteFinalText)
    #expect(session.preparedText("Next sentence.") == " Next sentence.")
}

@Test @MainActor func defaultLiveInputUsesKeysEvenWhenAXAdvertisesIgnoredSetters() async {
    let target = TestTextTarget()
    target.ignoreDirectWrites = true
    let session = LiveTypingSession(target: target)
    #expect(await session.update(text: "Hello"))
    #expect(await session.update(text: "Hello there"))
    #expect(target.current.value == "Before Hello there after")
    #expect(target.directWrites == 0)
    #expect(target.keyboardWrites == 2)
}

@Test @MainActor func unchangedFinalTranscriptDoesNotRequeryTheEditor() async {
    let target = TestTextTarget()
    let session = LiveTypingSession(target: target)
    #expect(await session.update(text: "Hello"))
    let readsAfterPreview = target.snapshotReads
    #expect(await session.update(text: "Hello"))
    #expect(target.snapshotReads == readsAfterPreview)
    #expect(target.keyboardWrites == 1)
}

@Test @MainActor func slowEditorEchoDoesNotSuspendLiveInput() async {
    let target = TestTextTarget()
    target.delayedEchoReads = 2
    let session = LiveTypingSession(target: target)
    #expect(await session.update(text: "Hello"))
    #expect(await session.update(text: "Hello there"))
    #expect(target.current.value == "Before Hello there after")
    #expect(session.suspendedReason == nil)
}

@Test @MainActor func liveKeysWorkWithoutReadableOrWritableAccessibilityText() async {
    let target = TestTextTarget()
    target.exposesContext = false
    target.supportsDirectReplacement = false
    let session = LiveTypingSession(target: target)
    #expect(await session.update(text: "Hello"))
    #expect(await session.update(text: "Hello there"))
    #expect(target.current.value == "Before Hello there after")
    #expect(target.directWrites == 0)
}

@Test @MainActor func releasingDuringEchoWaitPreservesOwnershipForTheFinalPass() async {
    let target = TestTextTarget()
    target.delayedEchoReads = 4
    let session = LiveTypingSession(target: target)
    let preview = Task { await session.update(text: "Hello") }
    while target.keyboardWrites == 0 { await Task.yield() }
    preview.cancel()
    _ = await preview.value
    #expect(session.suspendedReason == nil)
    target.flushEcho()
    target.delayedEchoReads = 0
    #expect(await session.update(text: "Hello there"))
    #expect(target.current.value == "Before Hello there after")
}
