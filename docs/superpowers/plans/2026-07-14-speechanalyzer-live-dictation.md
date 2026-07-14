# SpeechAnalyzer Live Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Apple SpeechAnalyzer engine (macOS 26+) that types dictated text live into the frontmost app with self-correcting diffs, alongside the existing WhisperKit record-then-paste engine.

**Architecture:** A `LiveTranscriber` streams `(finalized, volatile)` text snapshots from `SpeechAnalyzer`; a `LiveTypingController` converts snapshot deltas into CGEvent keystrokes via common-prefix diffing; `AppDelegate` branches the existing hotkey pipeline on a new `TranscriptionEngine` enum. Spec: `docs/superpowers/specs/2026-07-14-speechanalyzer-live-dictation-design.md`.

**Tech Stack:** Swift 6 toolchain in language mode v5, AppKit menu-bar app, Speech.framework (SpeechAnalyzer/SpeechTranscriber), AVAudioEngine, CGEvent keystroke synthesis, WhisperKit (unchanged fallback), SPM + XcodeGen dual build.

## Global Constraints

- Deployment target stays **macOS 14.0**; every use of Speech's new API is behind `@available(macOS 26, *)` / `if #available(macOS 26, *)`.
- `import Speech` appears ONLY in `Sources/Transcription/LiveTranscriber.swift`.
- No new package dependencies.
- Swift language mode stays v5 (`.swiftLanguageMode(.v5)` in Package.swift, `SWIFT_VERSION: "5"` in project.yml) — do not change.
- Locale is hardcoded `en_US`.
- Every synthesized CGEvent MUST set `flags = []` (user is physically holding Option+` during dictation; a leaked Option flag becomes an escape sequence in Ghostty).
- Text diffing and backspace counts operate on **grapheme clusters** (`Character`), never UTF-16 units.
- Primary acceptance environment: **Ghostty at a zsh prompt**.
- Whisper pipeline (`AudioRecorder` → `TranscriptionService` → `PasteService`) must behave exactly as before when a Whisper engine is selected.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `docs/` is ignored by the user's global gitignore — plan/spec files need `git add -f`; source files are unaffected.

**Verified SDK facts (Xcode 26.6, macOS 26.5 SDK — do not re-derive):**
- `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`, reporting option `.volatileResults`
- `SpeechTranscriber.supportedLocale(equivalentTo:) async -> Locale?`
- `transcriber.results: AsyncSequence<SpeechTranscriber.Result, Error>`; `Result.text: AttributedString`; `isFinal: Bool` (via `SpeechModuleResult`)
- `SpeechAnalyzer(modules:)`, `start(inputSequence:) async throws`, `finalizeAndFinishThroughEndOfInput() async throws`
- `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:) async -> AVAudioFormat?`
- `AnalyzerInput(buffer: AVAudioPCMBuffer)`
- `AssetInventory.assetInstallationRequest(supporting: [any SpeechModule]) async throws -> AssetInstallationRequest?`; `request.downloadAndInstall() async throws`

---

### Task 1: Test target + `TextDiff` (TDD)

**Files:**
- Modify: `Package.swift` (add test target)
- Create: `Tests/DictationTests/TextDiffTests.swift`
- Create: `Sources/Paste/TextDiff.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TextDiff.edit(from typed: String, to target: String) -> TextDiff.Edit` where `Edit` has `let backspaces: Int` and `let insertion: String`, both `Equatable`. Used by Task 3.

- [ ] **Step 1: Add the test target to Package.swift**

In `Package.swift`, inside the `targets:` array after the `.executableTarget`, add:

```swift
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

(SPM supports test targets that depend on executable targets. XcodeGen's `project.yml` is untouched — tests run via `swift test` only.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/DictationTests/TextDiffTests.swift`:

```swift
import XCTest

@testable import Dictation

final class TextDiffTests: XCTestCase {
    func testPureAppend() {
        let edit = TextDiff.edit(from: "hello", to: "hello world")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 0, insertion: " world"))
    }

    func testIdenticalIsNoOp() {
        let edit = TextDiff.edit(from: "same", to: "same")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 0, insertion: ""))
    }

    func testMidHypothesisRevision() {
        // volatile "so the tea" refines to "so the idea"
        let edit = TextDiff.edit(from: "so the tea", to: "so the idea")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 3, insertion: "idea"))
    }

    func testFullReplacement() {
        let edit = TextDiff.edit(from: "abc", to: "xyz")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 3, insertion: "xyz"))
    }

    func testShrinkingHypothesis() {
        let edit = TextDiff.edit(from: "hello world", to: "hello")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 6, insertion: ""))
    }

    func testEmptyToText() {
        let edit = TextDiff.edit(from: "", to: "hi")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 0, insertion: "hi"))
    }

    func testTextToEmpty() {
        let edit = TextDiff.edit(from: "hi", to: "")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 2, insertion: ""))
    }

    func testGraphemeClusterNotSplit() {
        // Multi-scalar emoji: one backspace per grapheme, never per scalar.
        let edit = TextDiff.edit(from: "hi 👨‍👩‍👧", to: "hi 👨‍👩‍👦")
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 1, insertion: "👨‍👩‍👦"))
    }

    func testCombiningMarksComparedAsGraphemes() {
        // "é" as precomposed vs decomposed compares equal at Character level.
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let edit = TextDiff.edit(from: precomposed, to: decomposed)
        XCTAssertEqual(edit, TextDiff.Edit(backspaces: 0, insertion: ""))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter TextDiffTests 2>&1 | tail -20`
Expected: build FAILURE with `cannot find 'TextDiff' in scope`. (First run compiles WhisperKit and friends — takes several minutes; later runs are incremental.)

- [ ] **Step 4: Implement TextDiff**

Create `Sources/Paste/TextDiff.swift`:

```swift
import Foundation

/// Computes the minimal end-of-string edit that turns one string into another,
/// expressed as backspaces followed by typed insertion. Operates on grapheme
/// clusters so one backspace matches one press of the delete key.
enum TextDiff {
    struct Edit: Equatable {
        let backspaces: Int
        let insertion: String
    }

    static func edit(from typed: String, to target: String) -> Edit {
        let typedChars = Array(typed)
        let targetChars = Array(target)
        var prefix = 0
        while prefix < typedChars.count, prefix < targetChars.count,
            typedChars[prefix] == targetChars[prefix] {
            prefix += 1
        }
        return Edit(
            backspaces: typedChars.count - prefix,
            insertion: String(targetChars[prefix...])
        )
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TextDiffTests 2>&1 | tail -5`
Expected: `Test Suite 'TextDiffTests' passed` with 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Paste/TextDiff.swift Tests/DictationTests/TextDiffTests.swift
git commit -m "Add grapheme-aware TextDiff engine with test target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `KeystrokeInjector` (TDD on chunking)

**Files:**
- Create: `Sources/Paste/KeystrokeInjector.swift`
- Create: `Tests/DictationTests/KeystrokeInjectorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol KeystrokePosting { func typeText(_ text: String); func backspace(_ count: Int) }` and `final class KeystrokeInjector: KeystrokePosting` with `static func utf16Chunks(of text: String, maxUnits: Int = 20) -> [[UInt16]]`. Used by Task 3.

- [ ] **Step 1: Write the failing chunking tests**

Create `Tests/DictationTests/KeystrokeInjectorTests.swift`:

```swift
import XCTest

@testable import Dictation

final class KeystrokeInjectorTests: XCTestCase {
    func testShortAsciiIsSingleChunk() {
        let chunks = KeystrokeInjector.utf16Chunks(of: "hello")
        XCTAssertEqual(chunks, [Array("hello".utf16)])
    }

    func testLongAsciiSplitsAtMaxUnits() {
        let text = String(repeating: "a", count: 45)
        let chunks = KeystrokeInjector.utf16Chunks(of: text, maxUnits: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
    }

    func testGraphemeNeverSplitAcrossChunks() {
        // 19 ASCII chars then a surrogate-pair emoji (2 UTF-16 units):
        // splitting at exactly 20 units would break the pair.
        let text = String(repeating: "x", count: 19) + "😀"
        let chunks = KeystrokeInjector.utf16Chunks(of: text, maxUnits: 20)
        XCTAssertEqual(chunks.map(\.count), [19, 2])
        XCTAssertEqual(chunks[1], Array("😀".utf16))
    }

    func testOversizedGraphemeBecomesOwnChunk() {
        // A ZWJ family emoji is > 4 UTF-16 units; with a tiny max it must
        // still be emitted whole rather than dropped or split.
        let family = "👨‍👩‍👧‍👦"
        let chunks = KeystrokeInjector.utf16Chunks(of: family, maxUnits: 4)
        XCTAssertEqual(chunks, [Array(family.utf16)])
    }

    func testEmptyStringHasNoChunks() {
        XCTAssertEqual(KeystrokeInjector.utf16Chunks(of: ""), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeystrokeInjectorTests 2>&1 | tail -10`
Expected: build FAILURE with `cannot find 'KeystrokeInjector' in scope`.

- [ ] **Step 3: Implement KeystrokeInjector**

Create `Sources/Paste/KeystrokeInjector.swift`:

```swift
import ApplicationServices
import CoreGraphics

protocol KeystrokePosting {
    func typeText(_ text: String)
    func backspace(_ count: Int)
}

/// Posts synthesized keyboard events to the frontmost app. All events carry
/// empty modifier flags: the user is physically holding the push-to-talk
/// hotkey (Option+`) while these fire, and a leaked Option flag would turn
/// characters into escape sequences in terminals.
final class KeystrokeInjector: KeystrokePosting {
    private static let deleteKey: CGKeyCode = 51

    /// Splits text into UTF-16 chunks of at most `maxUnits`, never splitting
    /// a grapheme cluster. A single grapheme larger than `maxUnits` becomes
    /// its own oversized chunk.
    static func utf16Chunks(of text: String, maxUnits: Int = 20) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in Self.utf16Chunks(of: text) {
            var units = chunk
            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(
                stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(
                stringLength: units.count, unicodeString: &units)
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }

    func backspace(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source, virtualKey: Self.deleteKey,
                    keyDown: true),
                let keyUp = CGEvent(
                    keyboardEventSource: source, virtualKey: Self.deleteKey,
                    keyDown: false)
            else { return }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeystrokeInjectorTests 2>&1 | tail -5`
Expected: `Test Suite 'KeystrokeInjectorTests' passed`, 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Paste/KeystrokeInjector.swift Tests/DictationTests/KeystrokeInjectorTests.swift
git commit -m "Add flag-clearing CGEvent keystroke injector with grapheme-safe chunking

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `LiveTypingController` (TDD with fake injector)

**Files:**
- Create: `Sources/Paste/LiveTypingController.swift`
- Create: `Tests/DictationTests/LiveTypingControllerTests.swift`

**Interfaces:**
- Consumes: `TextDiff.edit(from:to:)` (Task 1), `KeystrokePosting` / `KeystrokeInjector` (Task 2).
- Produces (used by Task 5's AppDelegate wiring):
  - `@MainActor final class LiveTypingController`
  - `init(injector: KeystrokePosting = KeystrokeInjector())`
  - `static func environmentAllowsLiveTyping() -> Bool`
  - `func begin(enabled: Bool)`
  - `var isLiveTypingEnabled: Bool { get }`
  - `func apply(finalized: String, volatile: String)`
  - `func finish(finalText: String)`
  - `func abort()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DictationTests/LiveTypingControllerTests.swift`:

```swift
import XCTest

@testable import Dictation

private final class FakeInjector: KeystrokePosting {
    var log: [String] = []
    func typeText(_ text: String) { log.append("type(\(text))") }
    func backspace(_ count: Int) { log.append("bs(\(count))") }
}

@MainActor
final class LiveTypingControllerTests: XCTestCase {
    private var injector: FakeInjector!
    private var controller: LiveTypingController!

    override func setUp() {
        super.setUp()
        injector = FakeInjector()
        controller = LiveTypingController(injector: injector)
        controller.begin(enabled: true)
    }

    func testVolatileGrowthTypesOnlyTheDelta() {
        controller.apply(finalized: "", volatile: "hello")
        controller.apply(finalized: "", volatile: "hello world")
        XCTAssertEqual(injector.log, ["type(hello)", "type( world)"])
    }

    func testVolatileRevisionBackspacesChangedSuffix() {
        controller.apply(finalized: "", volatile: "so the tea")
        controller.apply(finalized: "", volatile: "so the idea")
        XCTAssertEqual(injector.log, ["type(so the tea)", "bs(3)", "type(idea)"])
    }

    func testFinalizedTextIsNeverEditedAgain() {
        controller.apply(finalized: "", volatile: "hello world")
        controller.apply(finalized: "hello world.", volatile: "")
        controller.apply(finalized: "hello world.", volatile: " completely different")
        // The finalized "hello world." must not be backspaced; only volatile edits.
        XCTAssertEqual(
            injector.log,
            ["type(hello world)", "type(.)", "type( completely different)"])
    }

    func testFinishReconcilesToExactFinalText() {
        controller.apply(finalized: "", volatile: "helo wrld")
        controller.finish(finalText: "hello world")
        // Common prefix "hel"; the rest is backspaced and retyped.
        XCTAssertEqual(injector.log, ["type(helo wrld)", "bs(6)", "type(lo world)"])
    }

    func testAbortRemovesOnlyVolatileText() {
        controller.apply(finalized: "done.", volatile: " maybe")
        injector.log.removeAll()
        controller.abort()
        XCTAssertEqual(injector.log, ["bs(6)"])
    }

    func testDisabledSessionPostsNothing() {
        controller.begin(enabled: false)
        controller.apply(finalized: "", volatile: "hello")
        controller.finish(finalText: "hello")
        XCTAssertEqual(injector.log, [])
        XCTAssertFalse(controller.isLiveTypingEnabled)
    }

    func testBeginResetsStateBetweenSessions() {
        controller.apply(finalized: "first.", volatile: "")
        controller.finish(finalText: "first.")
        injector.log.removeAll()
        controller.begin(enabled: true)
        controller.apply(finalized: "", volatile: "second")
        XCTAssertEqual(injector.log, ["type(second)"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveTypingControllerTests 2>&1 | tail -10`
Expected: build FAILURE with `cannot find 'LiveTypingController' in scope`.

- [ ] **Step 3: Implement LiveTypingController**

Create `Sources/Paste/LiveTypingController.swift`:

```swift
import ApplicationServices
import Carbon

/// Types streaming transcription into the frontmost app using
/// common-prefix diffs: finalized text is typed once and never edited;
/// volatile text is corrected in place with backspaces + retyping.
@MainActor
final class LiveTypingController {
    private let injector: KeystrokePosting
    /// Grapheme count of finalized text already folded into the screen.
    private var committedLength = 0
    /// The provisional suffix currently on screen after the committed text.
    private var typedVolatile = ""
    private(set) var isLiveTypingEnabled = false

    init(injector: KeystrokePosting = KeystrokeInjector()) {
        self.injector = injector
    }

    /// Injection requires Accessibility trust, and typing into a secure
    /// field (password prompt) must never happen.
    static func environmentAllowsLiveTyping() -> Bool {
        AXIsProcessTrusted() && !IsSecureEventInputEnabled()
    }

    func begin(enabled: Bool) {
        committedLength = 0
        typedVolatile = ""
        isLiveTypingEnabled = enabled
    }

    func apply(finalized: String, volatile: String) {
        guard isLiveTypingEnabled else { return }
        let finalizedDelta = String(finalized.dropFirst(committedLength))
        let target = finalizedDelta + volatile
        let edit = TextDiff.edit(from: typedVolatile, to: target)
        if edit.backspaces > 0 {
            injector.backspace(edit.backspaces)
        }
        if !edit.insertion.isEmpty {
            injector.typeText(edit.insertion)
        }
        committedLength = finalized.count
        typedVolatile = volatile
    }

    /// One last reconcile so the screen matches the definitive transcript.
    func finish(finalText: String) {
        apply(finalized: finalText, volatile: "")
        reset()
    }

    /// Remove any provisional text (error / no-speech path).
    func abort() {
        if isLiveTypingEnabled, !typedVolatile.isEmpty {
            injector.backspace(typedVolatile.count)
        }
        reset()
    }

    private func reset() {
        committedLength = 0
        typedVolatile = ""
        isLiveTypingEnabled = false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveTypingControllerTests 2>&1 | tail -5`
Expected: `Test Suite 'LiveTypingControllerTests' passed`, 7 tests, 0 failures.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all 21 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Paste/LiveTypingController.swift Tests/DictationTests/LiveTypingControllerTests.swift
git commit -m "Add LiveTypingController: common-prefix diff typing over injected keystrokes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `LiveTranscriber`

**Files:**
- Create: `Sources/Transcription/LiveTranscriber.swift`

**Interfaces:**
- Consumes: Speech.framework (macOS 26 SDK — signatures listed in Global Constraints).
- Produces (used by Task 5):
  - `@available(macOS 26, *) @MainActor final class LiveTranscriber`
  - `struct Snapshot: Equatable, Sendable { var finalized: String; var volatile: String }` (nested)
  - `func prepare() async throws` — locale check + one-time asset download
  - `func start(onSnapshot: @escaping @MainActor @Sendable (Snapshot) -> Void) async throws`
  - `func finish() async -> String` — tears down, returns full finalized transcript (untrimmed)

No unit tests (thin wrapper over hardware + system ML; exercised manually in Task 6). Verification is compilation.

- [ ] **Step 1: Implement LiveTranscriber**

Create `Sources/Transcription/LiveTranscriber.swift`:

```swift
import AVFoundation
import Foundation
import Speech

/// Streams live speech-to-text from the microphone via SpeechAnalyzer.
/// Lifecycle per dictation: `start(onSnapshot:)` on hotkey down,
/// `finish()` on hotkey up. `prepare()` runs once when the engine is
/// selected (downloads system speech assets if missing).
@available(macOS 26, *)
@MainActor
final class LiveTranscriber {
    struct Snapshot: Equatable, Sendable {
        var finalized: String
        var volatile: String
    }

    enum LiveTranscriberError: LocalizedError {
        case localeNotSupported
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeNotSupported:
                return "Apple Speech does not support English on this system"
            case .noAudioFormat:
                return "No compatible audio format for the speech analyzer"
            }
        }
    }

    private static let locale = Locale(identifier: "en_US")

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizedText = ""

    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func prepare() async throws {
        guard await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) != nil else {
            throw LiveTranscriberError.localeNotSupported
        }
        let transcriber = Self.makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
    }

    func start(
        onSnapshot: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) async throws {
        let transcriber = Self.makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        finalizedText = ""

        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
        else {
            throw LiveTranscriberError.noAudioFormat
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    var volatile = ""
                    if result.isFinal {
                        self.finalizedText += text
                    } else {
                        volatile = text
                    }
                    onSnapshot(
                        Snapshot(finalized: self.finalizedText, volatile: volatile))
                }
            } catch {
                // Result stream failed or ended; finish() returns whatever
                // was finalized up to this point.
            }
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter =
            inputFormat == analyzerFormat
            ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            buffer, _ in
            if let converter {
                guard
                    let converted = Self.convert(
                        buffer, using: converter, to: analyzerFormat)
                else { return }
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            } else {
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        try await analyzer.start(inputSequence: inputSequence)
    }

    /// Stops capture, finalizes remaining audio, and returns the complete
    /// transcript. Safe to call even if `start` failed partway.
    func finish() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        return finalizedText
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity =
            AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }
}
```

- [ ] **Step 2: Verify it compiles (both build systems)**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

Run: `swift test 2>&1 | tail -3`
Expected: all 21 tests still pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/Transcription/LiveTranscriber.swift
git commit -m "Add LiveTranscriber: SpeechAnalyzer streaming wrapper (macOS 26+)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Engine selection (`TranscriptionEngine`, menu, Settings, asset prep)

**Files:**
- Modify: `Sources/AppState.swift`
- Modify: `Sources/AppDelegate.swift` (menu building, `loadModel`, `selectModel`, new properties)
- Modify: `Sources/Views/SettingsView.swift`
- Modify: `project.yml` (Info.plist key)

**Interfaces:**
- Consumes: `LiveTranscriber.prepare()` (Task 4), `LiveTypingController` (Task 3).
- Produces (used by Task 6):
  - `enum TranscriptionEngine: Equatable, Hashable { case appleLive; case whisper(WhisperModel) }` with `var displayName: String`, `static var available: [TranscriptionEngine]`, `static var defaultEngine: TranscriptionEngine`
  - `AppState.selectedEngine: TranscriptionEngine` (replaces `selectedModel`)
  - AppDelegate properties: `typingController: LiveTypingController`, `liveTranscriber` (computed, `@available(macOS 26, *)`), `liveStartTask: Task<Void, Never>?`
  - `Notification.Name.engineSelectionChanged`

- [ ] **Step 1: Replace `selectedModel` with `selectedEngine` in AppState.swift**

In `Sources/AppState.swift`, after the `WhisperModel` enum, add:

```swift
enum TranscriptionEngine: Equatable, Hashable {
    case appleLive
    case whisper(WhisperModel)

    var displayName: String {
        switch self {
        case .appleLive: return "Apple Speech — Live"
        case .whisper(let model): return model.displayName
        }
    }

    /// Engines usable on this OS, in menu order.
    static var available: [TranscriptionEngine] {
        var engines: [TranscriptionEngine] = []
        if #available(macOS 26, *) {
            engines.append(.appleLive)
        }
        engines.append(contentsOf: WhisperModel.allCases.map(TranscriptionEngine.whisper))
        return engines
    }

    static var defaultEngine: TranscriptionEngine {
        if #available(macOS 26, *) {
            return .appleLive
        }
        return .whisper(.small)
    }
}

extension Notification.Name {
    static let engineSelectionChanged = Notification.Name("engineSelectionChanged")
}
```

In `class AppState`, replace `var selectedModel: WhisperModel = .small` with:

```swift
    var selectedEngine: TranscriptionEngine = .defaultEngine
```

- [ ] **Step 2: Update AppDelegate menu, selection, and model loading**

In `Sources/AppDelegate.swift`:

**(a)** Add properties after `private let pasteService = PasteService()`:

```swift
    let typingController = LiveTypingController()
    private var liveStartTask: Task<Void, Never>?
    private var liveTranscriberStorage: Any?

    @available(macOS 26, *)
    var liveTranscriber: LiveTranscriber {
        if let existing = liveTranscriberStorage as? LiveTranscriber {
            return existing
        }
        let transcriber = LiveTranscriber()
        liveTranscriberStorage = transcriber
        return transcriber
    }
```

**(b)** In `setupStatusItem()`, replace the model submenu block (from `// Model submenu` through `menu.addItem(modelItem)`) with:

```swift
        // Engine submenu
        let engineMenu = NSMenu()
        for engine in TranscriptionEngine.available {
            let item = NSMenuItem(
                title: engine.displayName,
                action: #selector(selectEngine(_:)),
                keyEquivalent: ""
            )
            item.representedObject = engine
            item.target = self
            if engine == appState.selectedEngine {
                item.state = .on
            }
            engineMenu.addItem(item)
        }
        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        engineItem.tag = 200
        menu.addItem(engineItem)
```

**(c)** Replace `updateModelMenu()` with:

```swift
    private func updateEngineMenu() {
        guard let engineItem = statusItem?.menu?.item(withTag: 200),
            let engineMenu = engineItem.submenu
        else { return }
        for item in engineMenu.items {
            if let engine = item.representedObject as? TranscriptionEngine {
                item.state = engine == appState.selectedEngine ? .on : .off
            }
        }
    }
```

**(d)** Replace `selectModel(_:)` with:

```swift
    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let engine = sender.representedObject as? TranscriptionEngine else { return }
        setEngine(engine)
    }

    private func setEngine(_ engine: TranscriptionEngine) {
        guard engine != appState.selectedEngine || !appState.isModelLoaded else {
            updateEngineMenu()
            return
        }
        appState.selectedEngine = engine
        appState.isModelLoaded = false
        updateEngineMenu()
        Task {
            await loadModel()
        }
    }
```

**(e)** Replace `loadModel()` with:

```swift
    private func loadModel() async {
        switch appState.selectedEngine {
        case .appleLive:
            guard #available(macOS 26, *) else {
                appState.state = .error("Apple Speech requires macOS 26")
                updateStatusText("Apple Speech requires macOS 26")
                updateIcon()
                return
            }
            updateStatusText("Preparing speech assets...")
            do {
                try await liveTranscriber.prepare()
                appState.isModelLoaded = true
                updateStatusText("Ready")
            } catch {
                appState.state = .error(error.localizedDescription)
                updateStatusText("Error: \(error.localizedDescription)")
                updateIcon()
            }
        case .whisper(let model):
            updateStatusText("Loading model...")
            do {
                try await transcriptionService.loadModel(model.rawValue)
                appState.isModelLoaded = true
                updateStatusText("Ready")
            } catch {
                appState.state = .error(error.localizedDescription)
                updateStatusText("Error: \(error.localizedDescription)")
                updateIcon()
            }
        }
    }
```

**(f)** In `applicationDidFinishLaunching`, after `setupHotkey()`, add an observer so the Settings picker also switches engines (the old picker silently did nothing):

```swift
        NotificationCenter.default.addObserver(
            forName: .engineSelectionChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let engine = notification.object as? TranscriptionEngine else { return }
            MainActor.assumeIsolated {
                self?.setEngine(engine)
            }
        }
```

Note: `setEngine` must therefore tolerate being called with the already-selected engine (the guard in (d) handles this by only refreshing checkmarks).

- [ ] **Step 3: Update SettingsView**

In `Sources/Views/SettingsView.swift`, replace the `Section("Model")` block with:

```swift
            Section("Engine") {
                Picker("Transcription Engine", selection: $appState.selectedEngine) {
                    ForEach(TranscriptionEngine.available, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: appState.selectedEngine) { _, newEngine in
                    NotificationCenter.default.post(
                        name: .engineSelectionChanged, object: newEngine)
                }

                if !appState.isModelLoaded {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing engine...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
```

- [ ] **Step 4: Add the speech-recognition usage description**

In `project.yml`, under `info.properties`, after the `NSMicrophoneUsageDescription` line, add:

```yaml
        NSSpeechRecognitionUsageDescription: "Dictation uses on-device speech recognition to transcribe your voice."
```

- [ ] **Step 5: Build and test**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (there must be no remaining references to `selectedModel` / `selectModel` / `updateModelMenu` — the compiler will catch any).

Run: `swift test 2>&1 | tail -3`
Expected: all 21 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppState.swift Sources/AppDelegate.swift Sources/Views/SettingsView.swift project.yml
git commit -m "Add TranscriptionEngine selection: Apple Speech (macOS 26+) alongside Whisper

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Hotkey pipeline wiring + manual acceptance

**Files:**
- Modify: `Sources/AppDelegate.swift` (`startRecording`, `stopRecordingAndTranscribe`, two new methods)

**Interfaces:**
- Consumes: everything from Tasks 3–5.
- Produces: complete feature; no downstream consumers.

- [ ] **Step 1: Branch the recording pipeline**

In `Sources/AppDelegate.swift`, replace `startRecording()` with:

```swift
    private func startRecording() {
        previousApp = NSWorkspace.shared.frontmostApplication

        guard appState.isModelLoaded else {
            updateStatusText("Model not loaded yet")
            return
        }

        if case .appleLive = appState.selectedEngine {
            if #available(macOS 26, *) {
                startLiveDictation()
            }
            return
        }

        do {
            _ = try audioRecorder.startRecording()
            appState.state = .recording
            updateIcon()
            updateStatusText("Recording...")
        } catch {
            appState.state = .error(error.localizedDescription)
            updateIcon()
            updateStatusText("Recording error: \(error.localizedDescription)")
        }
    }
```

At the top of `stopRecordingAndTranscribe()`, immediately after the `guard appState.isRecording else { return }` line, insert:

```swift
        if case .appleLive = appState.selectedEngine {
            if #available(macOS 26, *) {
                stopLiveDictation()
            }
            return
        }
```

(The rest of `stopRecordingAndTranscribe` — the Whisper path — is unchanged.)

- [ ] **Step 2: Add the live dictation start/stop methods**

Add to `AppDelegate` (after `stopRecordingAndTranscribe`):

```swift
    @available(macOS 26, *)
    private func startLiveDictation() {
        let liveEnabled = LiveTypingController.environmentAllowsLiveTyping()
        typingController.begin(enabled: liveEnabled)
        appState.state = .recording
        updateIcon()
        updateStatusText(liveEnabled ? "Dictating live..." : "Recording (will paste)...")

        liveStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.liveTranscriber.start { [weak self] snapshot in
                    self?.typingController.apply(
                        finalized: snapshot.finalized, volatile: snapshot.volatile)
                }
            } catch {
                self.typingController.abort()
                self.appState.state = .error(error.localizedDescription)
                self.updateIcon()
                self.updateStatusText("Speech error: \(error.localizedDescription)")

                try? await Task.sleep(for: .seconds(3))
                self.appState.state = .idle
                self.updateIcon()
                self.updateStatusText("Ready")
            }
        }
    }

    @available(macOS 26, *)
    private func stopLiveDictation() {
        appState.state = .transcribing
        updateIcon()
        updateStatusText("Finalizing...")

        Task { [weak self] in
            guard let self else { return }
            // Serialize against setup: start() may still be awaiting the
            // analyzer when the hotkey is released.
            await self.liveStartTask?.value
            self.liveStartTask = nil

            let finalText = await self.liveTranscriber.finish()
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else {
                self.typingController.abort()
                self.appState.state = .idle
                self.updateIcon()
                self.updateStatusText("No speech detected")
                return
            }

            self.appState.lastTranscription = trimmed
            let preview =
                trimmed.count > 50 ? String(trimmed.prefix(50)) + "..." : trimmed

            if self.typingController.isLiveTypingEnabled {
                self.typingController.finish(finalText: finalText)
                self.updateStatusText("Typed live | \(preview)")
            } else {
                let pasteResult = self.pasteService.paste(text: trimmed)
                self.updateStatusText("\(pasteResult) | \(preview)")
            }
            self.appState.state = .idle
            self.updateIcon()
        }
    }
```

Note the guard in `startRecording` covers the model/asset-readiness check, so `startLiveDictation` doesn't repeat it. If `start()` threw and state is `.error`, the key-up handler's `guard appState.isRecording` skips `stopLiveDictation` — the error task's 3-second reset restores idle.

- [ ] **Step 3: Build both ways**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`
Run: `swift test 2>&1 | tail -3` — Expected: all tests pass.
Run: `./bundle.sh 2>&1 | tail -15` — Expected: exported `Dictation.app` with no build errors.

- [ ] **Step 4: Manual acceptance (requires the human — pause here)**

Install the fresh build (`cp -r Dictation.app /Applications/ && open /Applications/Dictation.app`; re-grant Accessibility if the signature changed), then walk through with the user:

1. Menu bar → Engine shows "Apple Speech — Live" checked by default; status reaches "Ready" (first time may show "Preparing speech assets..." while the system model downloads).
2. **Ghostty, zsh prompt:** hold Option+`, speak a full sentence, watch words appear live and self-correct; release; final text matches speech exactly — no stray characters, no escape-sequence garbage, no doubled words.
3. Ghostty: dictate, revise mid-sentence (pause, restart phrasing) — corrections backspace cleanly.
4. Hold the hotkey, say nothing, release → any provisional text is removed, status "No speech detected".
5. TextEdit and a browser text field: same sentence, text lands correctly.
6. Engine menu → switch to "Small English", dictate in Ghostty → old record-then-paste behavior works; switch back to Apple Speech → live typing again.
7. Settings window: engine picker switches engines and shows the progress row while preparing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppDelegate.swift
git commit -m "Wire live dictation into the push-to-talk pipeline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
