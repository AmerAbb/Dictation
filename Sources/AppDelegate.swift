import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let pasteService = PasteService()
    private var previousApp: NSRunningApplication?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Force the shortcut to Option+` (clears any stale UserDefaults value)
        KeyboardShortcuts.setShortcut(.init(.backtick, modifiers: .option), for: .dictate)
        setupStatusItem()
        setupHotkey()

        Task {
            let _ = await PermissionChecker.checkMicrophonePermission()
            await loadModel()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()

        // Status line
        let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusLine.tag = 100
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Model submenu
        let modelMenu = NSMenu()
        for model in WhisperModel.allCases {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = model
            item.target = self
            if model == appState.selectedModel {
                item.state = .on
            }
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        modelItem.tag = 200
        menu.addItem(modelItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...", action: #selector(openSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Dictation", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    private func updateIcon() {
        let symbolName: String
        switch appState.state {
        case .idle:
            symbolName = "mic"
        case .recording:
            symbolName = "mic.fill"
        case .transcribing:
            symbolName = "ellipsis.circle"
        case .error:
            symbolName = "exclamationmark.triangle"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: "Dictation"
        )
    }

    private func updateStatusText(_ text: String) {
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = text
        }
    }

    private func updateModelMenu() {
        guard let modelItem = statusItem?.menu?.item(withTag: 200),
            let modelMenu = modelItem.submenu
        else { return }
        for item in modelMenu.items {
            if let model = item.representedObject as? WhisperModel {
                item.state = model == appState.selectedModel ? .on : .off
            }
        }
    }

    // MARK: - Model

    private func loadModel() async {
        updateStatusText("Loading model...")
        do {
            try await transcriptionService.loadModel(appState.selectedModel.rawValue)
            appState.isModelLoaded = true
            updateStatusText("Ready")
        } catch {
            appState.state = .error(error.localizedDescription)
            updateStatusText("Error: \(error.localizedDescription)")
            updateIcon()
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? WhisperModel else { return }
        appState.selectedModel = model
        appState.isModelLoaded = false
        updateModelMenu()
        Task {
            await loadModel()
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }
    }

    // MARK: - Recording Pipeline

    private func startRecording() {
        previousApp = NSWorkspace.shared.frontmostApplication

        guard appState.isModelLoaded else {
            updateStatusText("Model not loaded yet")
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

    private func stopRecordingAndTranscribe() {
        guard appState.isRecording else { return }

        guard let fileURL = audioRecorder.stopRecording() else {
            appState.state = .idle
            updateIcon()
            return
        }

        appState.state = .transcribing
        updateIcon()
        updateStatusText("Transcribing...")

        Task {
            defer {
                audioRecorder.cleanup()
            }

            do {
                let text = try await transcriptionService.transcribe(fileURL: fileURL)

                guard !text.isEmpty else {
                    appState.state = .idle
                    updateIcon()
                    updateStatusText("No speech detected")
                    return
                }

                appState.lastTranscription = text
                let pasteResult = pasteService.paste(text: text)

                appState.state = .idle
                updateIcon()

                let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
                updateStatusText("\(pasteResult) | \(preview)")
            } catch {
                appState.state = .error(error.localizedDescription)
                updateIcon()
                updateStatusText("Error: \(error.localizedDescription)")

                // Reset to idle after a delay
                try? await Task.sleep(for: .seconds(3))
                appState.state = .idle
                updateIcon()
            }
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        // Temporarily become a regular app so the window can receive keyboard input
        NSApp.setActivationPolicy(.regular)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView().environment(appState)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
