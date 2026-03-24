# Dictation

A lightweight macOS menu bar app for push-to-talk speech-to-text. Hold a hotkey, speak, release — your words are transcribed locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit) and pasted into whatever app you're using. No cloud APIs, fully private.

## Features

- **Push-to-talk** — Hold `Option + `` ` to record, release to transcribe and paste
- **100% local** — Speech-to-text runs on-device via OpenAI's Whisper model (no data leaves your Mac)
- **Menu bar app** — Lives in your status bar, out of the way
- **Multiple Whisper models** — Choose between Tiny (~75 MB), Base (~150 MB), or Small (~500 MB) depending on speed vs. accuracy preference
- **Smart paste** — Tries Accessibility API first, falls back to keyboard simulation, then AppleScript
- **Models downloaded on demand** — Only downloads the model you select; cached in `~/Library/Application Support/Dictation/Models/`

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Swift 6.0** toolchain (ships with Xcode 16+)
- An Apple Developer identity for code signing (needed for Accessibility permission to persist across launches)

## Getting Started

### 1. Clone and build

```bash
git clone https://github.com/amerabb/Dictation.git
cd Dictation
swift build -c release
```

### 2. Bundle into an app

The included `bundle.sh` script creates a signed `.app` bundle:

```bash
# First, edit bundle.sh line 24 and replace the signing identity with your own:
#   codesign --force --sign "Apple Development: you@example.com (TEAM_ID)" "$APP_BUNDLE"
#
# To find your signing identity:
#   security find-identity -v -p codesigning

./bundle.sh
```

### 3. Install and launch

```bash
cp -r Dictation.app /Applications/
open /Applications/Dictation.app
```

To start automatically on login: **System Settings → General → Login Items** → add Dictation.

### 4. Grant permissions

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
└── Views/
    └── SettingsView.swift       # Settings window UI
```

## Customization

**Change the hotkey** — Edit `HotkeyNames.swift` and `AppDelegate.swift` where the shortcut is registered.

**Change the default model** — In `AppState.swift`, modify the default value of the `selectedModel` property.

**Use a different signing identity** — Edit line 24 of `bundle.sh` with your own Apple Developer identity.

## Dependencies

| Package | Purpose |
|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text using Whisper |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration |

## License

MIT
