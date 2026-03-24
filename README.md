# Dictation

A lightweight macOS menu bar app for push-to-talk speech-to-text. Hold a hotkey, speak, release — your words are transcribed locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit) and pasted into whatever app you're using. No cloud APIs, fully private.

## Features

- **Push-to-talk** — Hold `Option + `` ` to record, release to transcribe and paste
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
3. Hold **Option + `` ` ``** and speak
4. Release the hotkey — the transcription is pasted automatically

The menu bar icon reflects the current state:
| Icon | State |
|------|-------|
| 🎙 | Idle / ready |
| 🎙 (filled) | Recording |
| ⏳ | Transcribing |
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
│   └── AudioRecorder.swift      # AVAudioRecorder wrapper
├── Transcription/
│   └── TranscriptionService.swift   # WhisperKit model loading & transcription
├── Paste/
│   └── PasteService.swift       # Multi-method text insertion
├── Permissions/
│   └── PermissionChecker.swift  # Microphone & Accessibility checks
├── Updates/
│   └── CheckForUpdatesViewModel.swift  # Sparkle update checking
└── Views/
    └── SettingsView.swift       # Settings window UI
```

## Customization

**Change the hotkey** — Edit `HotkeyNames.swift` and `AppDelegate.swift` where the shortcut is registered.

**Change the default model** — In `AppState.swift`, modify the default value of the `selectedModel` property.

## Dependencies

| Package | Purpose |
|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text using Whisper |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-update framework |

## License

MIT
