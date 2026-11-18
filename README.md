# Dictation

A lightweight macOS menu bar app for push-to-talk speech-to-text. Hold a hotkey, watch text appear in your target field, release — your words are transcribed locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit) and pasted into whatever app you're using. No cloud APIs, fully private.

## Features

- **Push-to-talk** — Hold `Option + `` ` to dictate into the current field, release to finalize
- **Live transcript** — Text appears in the target field while speaking; revisions and the final transcript update the same dictated range
- **Listening pill** — Fixed bars pulse vertically with the current microphone level inside a compact black pill above the Dock
- **Optional auto-correction** — A saved menu bar/Settings toggle proofreads grammar and obvious recognition mistakes using Apple's on-device model; requires macOS 26+ with Apple Intelligence available
- **Automatic spacing** — Adds a single separator when appending a new phrase, including immediate follow-up dictations in editors that hide surrounding text
- **Original recovery** — Copy the most recent uncorrected transcript from the menu bar
- **100% local** — Speech-to-text runs on-device via OpenAI's Whisper model (no data leaves your Mac)
- **Menu bar app** — Lives in your status bar, out of the way
- **Auto-update** — Checks for new versions via [Sparkle](https://sparkle-project.org) and updates in-place
- **Multiple Whisper models** — Choose between Tiny (~75 MB), Base (~150 MB), or Small (~500 MB) depending on speed vs. accuracy preference
- **Smart paste** — Tries Accessibility API first, falls back to keyboard simulation, then AppleScript
- **Models downloaded on demand** — Only downloads the model you select; cached in `~/Library/Application Support/Dictation/Models/`

## Install from Release

Download the latest `Dictation.zip` from [Releases](https://github.com/amerabb/Dictation/releases), unzip, and move to `/Applications`. Future updates are delivered automatically via Sparkle.

## Build from Source

### Requirements

- **macOS 14.0** (Sonoma) or later
- **Xcode 16+** (Swift 6.0 toolchain)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

### Build and run

```bash
git clone https://github.com/amerabb/Dictation.git
cd Dictation
./bundle.sh
```

This generates the Xcode project, builds a release archive, and exports `Dictation.app`.

```bash
cp -r Dictation.app /Applications/
open /Applications/Dictation.app
```

To start automatically on login: **System Settings → General → Login Items** → add Dictation.

### Grant permissions

On first launch the app will request:

1. **Microphone** — needed to record audio (macOS will prompt you)
2. **Accessibility** — needed to paste text into other apps. Grant via **System Settings → Privacy & Security → Accessibility**, or use the button in the app's Settings window (`Cmd + ,`)

## Usage

1. Click the microphone icon in your menu bar to see status and switch models
2. Place your cursor where you want text inserted
3. Hold **Option + `` ` ``** and speak — text appears in the focused field, with a waveform pill above the Dock
4. Release the hotkey — the text is finalized in place without inserting a second copy
5. If needed, use **Cancel Dictation** in the menu to stop capture immediately and dismiss the pill
6. Enable **Auto-correct Dictation** in the menu bar or Settings to proofread the final transcript (off by default)

Recording follows the shortcut's trigger key using an independent key-state watchdog, so stopping no longer depends on receiving the shortcut's key-up callback. Queued key-down callbacks after release are ignored. Cancelling stops capture immediately and drains pending decoding before allowing another recording.

Live text is provisional and may change as more context arrives. Every app uses the same incremental foreground keyboard input path, with held shortcut modifiers cleared. Accessibility provides editable context and verifies text/cursor ownership where available; it does not select an app-specific insertion method. Read-only or unavailable Accessibility text does not disable live keyboard input. Editors get a brief acknowledgment window before delayed readback is treated as a conflicting edit. Only the dictated text is revised, preserving surrounding text. Audio is checked about every 350 ms and partial decoder output is published as it arrives, without waiting for a complete sentence. Earlier preview text stays visible while a new decoding pass catches up. Whisper still needs context, so updates are not guaranteed to arrive exactly one spoken word at a time. Latency depends on your Mac and selected Whisper model.

When the cursor is at the end of readable text, a new dictation adds a space if needed. Existing whitespace, punctuation that attaches to the previous word, selected-text replacements, and mid-word edits keep their original spacing. For editors that hide surrounding text from Accessibility, an immediate follow-up dictation in the same app receives a conservative continuation space after a completed insertion.

Auto-correction stays on-device and is available only when Apple's Foundation Models system model is ready. The menu explains why it is unavailable, such as Apple Intelligence being disabled. Correction failures, timeouts, and overly long transcripts fall back to the original transcript. Contextual word fixes are best-effort; use **Copy Original Transcript** if a correction changes your intended wording. If you switch apps, move the cursor, or type during dictation, live insertion pauses and the final result is copied to the clipboard. Nothing is automatically submitted or sent.

The menu bar icon reflects the current state:
| Icon | State |
|------|-------|
| 🎙 | Idle / ready |
| 🎙 (filled) | Recording |
| ⏳ | Finishing transcription or correcting grammar |
| ⚠️ | Error (resets after 3s) |

## Updates

The app checks for updates once every 24 hours in the background. You can also check manually via the **Check for Updates...** menu item. Whisper models are stored outside the app bundle (`~/Library/Application Support/Dictation/Models/`) so they persist across updates — no re-download needed.

## Releasing (maintainer)

Releases are automated. Bump the version and push a tag:

```bash
fastlane release bump:patch   # or minor / major
```

This updates the version in `project.yml`, commits, tags, and pushes. GitHub Actions then builds, signs, generates the Sparkle appcast, and publishes the release.

## Project Structure

```
Sources/
├── DictationApp.swift           # App entry point
├── AppDelegate.swift            # Menu bar setup, hotkey handling, orchestration
├── AppState.swift               # Observable state & enums
├── HotkeyNames.swift            # KeyboardShortcuts config
├── Audio/
│   └── AudioRecorder.swift      # Live PCM capture, synchronized snapshots, microphone levels
├── Transcription/
│   ├── TranscriptionService.swift   # WhisperKit live previews & final transcription
│   └── CorrectionService.swift      # Optional on-device proofreading & fallback
├── Paste/
│   ├── PasteService.swift       # Multi-method text insertion
│   └── LiveTypingSession.swift  # Target-bound live revisions & keyboard fallback
├── Permissions/
│   └── PermissionChecker.swift  # Microphone & Accessibility checks
├── Updates/
│   └── CheckForUpdatesViewModel.swift  # Sparkle update checking
└── Views/
    ├── SettingsView.swift       # Settings window UI
    └── ListeningOverlay.swift   # Non-activating listening pill
```

## Customization

**Change the hotkey** — Edit `HotkeyNames.swift` and `AppDelegate.swift` where the shortcut is registered.

**Change the default model** — In `AppState.swift`, modify the default value of the `selectedModel` property.

## Testing

Run the regression suite with `swift test`. It covers concurrent capture and stopping, silent input, transcript revisions, live field updates, keyboard fallback, Unicode edits, cursor/focus changes, duplicate prevention, and correction output validation.

When testing an already-authorized install, use the same code-signing identity as that install. An ad-hoc test build may not inherit Accessibility permission, even with the same bundle identifier.

Optional integration checks use an existing cached `base.en` model and a synthetic speech file (containing “tomorrow” near the beginning and “dinner” at the end):

```bash
say -v Samantha -r 150 -o /tmp/dictation-test.aiff 'We should meet tomorrow afternoon to discuss the project. After the meeting, we can buy some apples for dinner.'
DICTATION_TEST_AUDIO=/tmp/dictation-test.aiff DICTATION_TEST_CORRECTION=1 DICTATION_TEST_PREVIEW=1 swift test
```

The preview check writes `/tmp/dictation-listening-preview.png`. Integration checks can load/download the selected speech model; regular tests do not. Building auto-correction requires an SDK with Foundation Models (Xcode 26+); with an older SDK the rest of the app still builds and correction is unavailable.

## Insertion diagnostics

The latest recording writes a bounded trace to `/tmp/Dictation-session-diagnostics.json`. It contains the target app identifier, capture/sample counts, text lengths, cursor offsets, and insertion failure reasons. It contains no recorded audio or dictated text. The last five completed traces are also retained in `/tmp/Dictation-recent-sessions.json`. This distinguishes transcription failures from ignored Accessibility writes, focus changes, and keyboard insertion failures.

When an Accessibility update is confirmed to have made no change, release can retry the original paste path only if nothing was inserted and the original field, text, and cursor are unchanged. Partial live insertion never triggers a second full paste.

## Dependencies

| Package | Purpose |
|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text using Whisper |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-update framework |

## License

MIT
