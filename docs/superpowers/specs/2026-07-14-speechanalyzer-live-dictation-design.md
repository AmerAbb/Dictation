# SpeechAnalyzer Live Dictation — Design

**Date:** 2026-07-14
**Status:** Approved for planning

## Goal

Add a second transcription engine backed by Apple's SpeechAnalyzer API (macOS 26+)
that types text into the frontmost app **live, as the user speaks**, correcting
itself as provisional results refine. Keep the existing WhisperKit
record-then-paste pipeline as the fallback engine (dual path), selectable from
the menu bar for A/B comparison.

**Primary usage environment: Ghostty (terminal).** Live typing must work
flawlessly at a shell prompt. Terminals ignore Accessibility text insertion, so
the live path is built on synthesized CGEvent keystrokes, which terminals handle
natively.

## Non-goals

- No deployment-target bump: minimum stays macOS 14.0; all new code is gated
  with `@available(macOS 26, *)`.
- No removal of WhisperKit (that decision comes after the A/B).
- No floating HUD/preview window.
- No multi-language support (locale fixed to `en_US`, matching the current
  hardcoded `language: "en"`).

## Architecture

Three pieces: an engine enum, a live transcriber (audio → text snapshots), and a
live typing controller (text snapshots → keystrokes). `AppDelegate` wires them
into the existing hotkey pipeline.

### 1. `TranscriptionEngine` (replaces `WhisperModel` as the selection type)

```swift
enum TranscriptionEngine {
    case appleLive              // macOS 26+ only
    case whisper(WhisperModel)  // existing tiny/base/small
}
```

- `AppState.selectedModel: WhisperModel` becomes
  `AppState.selectedEngine: TranscriptionEngine`.
- Default: `.appleLive` on macOS 26+, `.whisper(.small)` otherwise.
- The menu bar "Model" submenu is renamed "Engine". It lists
  "Apple Speech — Live" (hidden on macOS < 26) plus the three Whisper entries.
- Selecting a Whisper engine loads the Whisper model exactly as today.
  Selecting Apple Speech runs the asset check (below).

### 2. `LiveTranscriber` — `Sources/Transcription/LiveTranscriber.swift` (new)

`@available(macOS 26, *)` actor/class wrapping `SpeechAnalyzer` +
`SpeechTranscriber`.

- **Audio:** owns an `AVAudioEngine`, installs an input tap, converts buffers to
  the transcriber's `bestAvailableAudioFormat`, and feeds them to the analyzer
  as `AnalyzerInput` via an `AsyncStream`. The Whisper path keeps using the
  existing `AVAudioRecorder` file recording — untouched.
- **Output:** exposes `AsyncStream<Snapshot>` where
  `Snapshot = (finalized: String, volatile: String)`. Built by consuming
  `SpeechTranscriber.results`: results flagged final are appended to
  `finalized`; non-final results replace `volatile`.
- **Lifecycle:** `start()` begins capture + analysis. `finish() -> String`
  (called on hotkey release) stops the audio tap, ends the input stream,
  calls `analyzer.finalizeAndFinishThroughEndOfInput()`, drains remaining
  results, and returns the complete final transcript.
- **Assets:** `prepare()` checks `SpeechTranscriber` support for `en_US` and,
  if the model assets aren't installed, requests them via
  `AssetInventory.assetInstallationRequest(supporting:)` and awaits download.
  Menu status shows "Downloading speech assets…" during this (one-time per
  Mac; assets are system-managed and shared across apps).
- **Transcriber options:** volatile results enabled; punctuation on
  (default behavior); no audio time-range attribution needed.

### 3. `LiveTypingController` — `Sources/Paste/LiveTypingController.swift` (new)

Turns snapshots into keystrokes using **common-prefix diffing** (approach C).

- **State:** `typedVolatile: String` — the volatile suffix currently on screen.
  Finalized text, once typed, is never edited again.
- **Per snapshot:** target volatile text = (newly finalized delta) + volatile.
  Compute the longest common prefix between `typedVolatile` and the target;
  post `typedVolatile.count - prefix.count` backspaces; type the remainder.
  Newly finalized text folds into the immutable committed region.
- **Keystroke synthesis:**
  - Text: `CGEvent` + `keyboardSetUnicodeString`, chunked (~20 UTF-16 units per
    event) so all characters register; no keycode mapping, works for arbitrary
    Unicode.
  - Backspace: virtual key 51, one down/up pair per deletion.
  - **Every synthesized event sets `flags = []`** — the user is physically
    holding Option+` for push-to-talk, and without this the held modifier
    contaminates injected keystrokes (in a terminal, Option+char becomes an
    escape sequence — unacceptable in Ghostty).
  - Small inter-event pacing if needed for reliability (tune during testing;
    start with none).
- **`finish(finalText:)`:** one last reconcile so the screen matches the final
  transcript exactly, then reset state.
- **`abort()`:** backspace out any typed volatile text (used for the
  "no speech detected" case and on errors).

### Safety valve (fallback to paste-at-end)

Before starting a live-typing session, the controller checks:

- `AXIsProcessTrusted()` is false (no permission to inject), or
- `IsSecureEventInputEnabled()` is true (password field / secure input).

If either holds, live typing is skipped for that dictation: transcription still
streams (engine unchanged), but nothing is typed until release, when the final
text goes through the existing `PasteService` — i.e., exactly today's behavior.

### 4. `AppDelegate` wiring

On macOS 26 with `.appleLive` selected:

- **Key down:** `liveTranscriber.start()`, begin a `LiveTypingController`
  session, consume the snapshot stream on the main actor, state `.recording`.
- **Key up:** `let text = await liveTranscriber.finish()`;
  `typingController.finish(finalText: text)` (or `PasteService.paste` if the
  safety valve engaged); empty text → `typingController.abort()` + status
  "No speech detected"; state back to `.idle`.
- **Errors** (audio engine failure, asset download failure, analyzer error):
  `typingController.abort()`, reuse the existing `.error` status flow
  (status text + 3-second reset).

Whisper engines keep the exact current pipeline
(`AudioRecorder` → `TranscriptionService` → `PasteService`).

## Project changes

- `import Speech` only inside `@available(macOS 26, *)` files; Speech.framework
  links fine back to macOS 14 (the new symbols are availability-guarded).
- Add `NSSpeechRecognitionUsageDescription` to Info.plist defensively (harmless
  if the on-device API doesn't prompt).
- No new package dependencies. `project.yml` / `Package.swift` unchanged apart
  from any new source files being picked up automatically.

## Error handling summary

| Failure | Behavior |
|---|---|
| Assets not installed | Download on engine select with status text; engine unusable until done |
| Asset download fails | `.error` status; user can pick a Whisper engine |
| Audio engine fails to start | `.error` status, no typing session started |
| AX untrusted / secure input | Live typing skipped; paste-at-end via `PasteService` |
| Empty transcript | Volatile text backspaced out; "No speech detected" |
| Analyzer error mid-stream | Abort typing (backspace volatile), `.error` status |

## Testing

- **Unit (TDD):** the diff engine is a pure function —
  `edit(typed: String, target: String) -> (backspaces: Int, insertion: String)`
  — covering: pure append, mid-word revision, full replacement, shrinking
  hypothesis, empty→text, text→empty, emoji/multi-scalar graphemes (backspace
  count must be in the same units the keystroke layer deletes — a terminal
  backspace deletes one grapheme/cell, so diffing operates on grapheme
  boundaries and never splits a cluster).
- **Manual acceptance (in priority order):**
  1. **Ghostty at a zsh prompt** — dictate a sentence; text appears live,
     corrections are clean, no stray escape-sequence characters from held
     Option, final text matches the transcript exactly.
  2. TextEdit, a browser text field.
  3. Whisper engines still work unchanged via the menu (A/B switch).
  4. macOS < 26 behavior unchanged (code review of gating; no device needed).

## Open risk (accepted)

Live typing into an app whose input state interprets characters as commands
(vim normal mode, a terminal mid-TUI) can misfire — same class of risk as the
existing CGEvent paste fallback. The user dictates at a shell prompt; the
safety valve covers secure input; anything beyond that is user judgment, as
today.
