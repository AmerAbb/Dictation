import AppKit
import KeyboardShortcuts
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let pasteService = PasteService()
    private let correctionService = CorrectionService()
    private let listeningOverlay = ListeningOverlay()
    private var previewTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var pushToTalkGate = PushToTalkGate()
    private var liveTyping: LiveTypingSession?
    private var activeTargetPID: pid_t?
    private var lastCompletedInsertion: (pid: pid_t, time: Date)?
    private var settingsWindow: NSWindow?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Force the shortcut to Option+` (clears any stale UserDefaults value)
        KeyboardShortcuts.setShortcut(.init(.backtick, modifiers: .option), for: .dictate)
        setupStatusItem()
        setupHotkey()

        updaterController.updater.checkForUpdatesInBackground()

        Task {
            let _ = await PermissionChecker.checkMicrophonePermission()
            await loadModel()
        }
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Status line
        let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusLine.tag = 100
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        let cancelItem = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        cancelItem.tag = 140
        cancelItem.isEnabled = false
        menu.addItem(cancelItem)
        menu.addItem(.separator())

        // Model submenu
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
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

        let correctionItem = NSMenuItem(
            title: "Auto-correct Dictation", action: #selector(toggleAutoCorrect), keyEquivalent: ""
        )
        correctionItem.target = self
        correctionItem.tag = 300
        menu.addItem(correctionItem)
        let correctionInfo = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        correctionInfo.tag = 310
        correctionInfo.isEnabled = false
        menu.addItem(correctionInfo)

        let copyOriginalItem = NSMenuItem(
            title: "Copy Original Transcript", action: #selector(copyOriginalTranscript), keyEquivalent: ""
        )
        copyOriginalItem.target = self
        copyOriginalItem.tag = 320
        menu.addItem(copyOriginalItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...", action: #selector(openSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Check for Updates
        let updateItem = NSMenuItem(
            title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Dictation", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        updateCorrectionMenu()
    }

    private func updateIcon() {
        let symbolName: String
        switch appState.state {
        case .idle:
            symbolName = "mic"
        case .recording:
            symbolName = "mic.fill"
        case .transcribing, .correcting:
            symbolName = "ellipsis.circle"
        case .error:
            symbolName = "exclamationmark.triangle"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: "Dictation"
        )
        updateModelMenu()
        statusItem?.menu?.item(withTag: 140)?.isEnabled = appState.isBusy && cleanupTask == nil
    }

    private func updateStatusText(_ text: String) {
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = text.count > 140 ? String(text.prefix(140)) + "…" : text
            item.toolTip = text
        }
    }

    private func updateModelMenu() {
        guard let modelItem = statusItem?.menu?.item(withTag: 200),
            let modelMenu = modelItem.submenu
        else { return }
        for item in modelMenu.items {
            if let model = item.representedObject as? WhisperModel {
                item.state = model == appState.selectedModel ? .on : .off
                item.isEnabled = !appState.isBusy && !appState.isLoadingModel
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCorrectionMenu()
        updateModelMenu()
    }

    private func updateCorrectionMenu() {
        appState.correctionUnavailableReason = CorrectionService.unavailableReason
        if let item = statusItem?.menu?.item(withTag: 300) {
            item.state = appState.autoCorrect ? .on : .off
            item.isEnabled = appState.correctionUnavailableReason == nil || appState.autoCorrect
            item.toolTip = appState.correctionUnavailableReason ?? "Conservatively proofread the final transcript on this Mac."
        }
        if let item = statusItem?.menu?.item(withTag: 310) {
            item.title = appState.correctionUnavailableReason ?? "Corrections run on this Mac"
        }
        statusItem?.menu?.item(withTag: 320)?.isEnabled = appState.lastRawTranscription != nil
    }

    @objc private func toggleAutoCorrect() {
        appState.autoCorrect.toggle()
        updateCorrectionMenu()
    }

    @objc private func copyOriginalTranscript() {
        guard let text = appState.lastRawTranscription else { return }
        pasteService.copy(text: text)
        updateStatusText("Original transcript copied")
    }

    // MARK: - Model

    private func loadModel() async {
        appState.isLoadingModel = true
        appState.isModelLoaded = false
        defer {
            appState.isLoadingModel = false
            updateModelMenu()
        }
        updateModelMenu()
        updateStatusText("Loading model...")
        do {
            try await transcriptionService.loadModel(appState.selectedModel.rawValue)
            appState.isModelLoaded = true
            appState.state = .idle
            updateIcon()
            updateStatusText("Ready")
            updateModelMenu()
        } catch {
            appState.state = .error(error.localizedDescription)
            updateStatusText("Error: \(error.localizedDescription)")
            updateIcon()
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? WhisperModel else { return }
        changeModel(to: model)
    }

    private func changeModel(to model: WhisperModel) {
        guard !appState.isBusy, !appState.isLoadingModel, model != appState.selectedModel else { return }
        appState.selectedModel = model
        appState.isLoadingModel = true
        appState.isModelLoaded = false
        updateModelMenu()
        Task { await loadModel() }
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
                self?.checkForPhysicalRelease()
            }
        }
    }

    // MARK: - Recording Pipeline

    private func startRecording() {
        guard !appState.isBusy else { return }
        guard appState.isModelLoaded else {
            updateStatusText("Model not loaded yet")
            return
        }
        guard PermissionChecker.isMicrophoneAuthorized else {
            showError("Allow microphone access in System Settings → Privacy & Security → Microphone.")
            return
        }
        guard PermissionChecker.isAccessibilityAuthorized else {
            PermissionChecker.requestAccessibilityPermission()
            showError("Allow Dictation in System Settings → Privacy & Security → Accessibility, then try again.")
            return
        }
        guard let targetApp = NSWorkspace.shared.frontmostApplication,
              targetApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            showError("Place your cursor in the target text field before dictating.")
            return
        }
        guard pushToTalkGate.press(physicallyHeld: isDictationShortcutPhysicallyHeld()) else { return }
        errorResetTask?.cancel()
        DictationDiagnostics.begin(target: targetApp.bundleIdentifier ?? "unknown", model: appState.selectedModel.rawValue)
        let continuesPriorDictation = lastCompletedInsertion.map {
            $0.pid == targetApp.processIdentifier && Date().timeIntervalSince($0.time) < 120
        } ?? false
        activeTargetPID = targetApp.processIdentifier
        liveTyping = LiveTypingSession(target: NativeTextTarget(application: targetApp),
                                       assumeExistingPrecedingText: continuesPriorDictation)
        liveTyping?.monitorUserInput()
        do {
            try audioRecorder.startRecording()
            DictationDiagnostics.record("capture.started")
            appState.liveTranscript = ""
            appState.audioLevels = [Float](repeating: 0, count: 24)
            appState.recordingDuration = 0
            appState.state = .recording
            updateIcon()
            updateStatusText("Listening…")
            listeningOverlay.show(appState: appState)
            startLiveUpdates()
        } catch {
            showError("Recording error: \(error.localizedDescription)")
        }
    }

    private func startLiveUpdates() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.appState.isRecording else { return }
                self.checkForPhysicalRelease()
                guard self.appState.isRecording else { return }
                if let meter = self.audioRecorder.meter() {
                    self.appState.audioLevels = meter.levels
                    self.appState.recordingDuration = meter.duration
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        previewTask = Task { [weak self] in
            guard let self else { return }
            await self.transcriptionService.resetStreaming()
            var lastSampleCount = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    guard self.appState.isRecording,
                          let audio = self.audioRecorder.snapshot(), audio.canTranscribe,
                          audio.samples.count >= 16_000,
                          audio.samples.count - lastSampleCount >= 5_600 else { continue }
                    lastSampleCount = audio.samples.count
                    DictationDiagnostics.record("preview.decode.begin", ["samples": String(audio.samples.count), "hasSpeech": String(audio.hasSpeech)])
                    let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    // Structured child ownership ensures release waits for this decoder to stop.
                    async let decoded = self.transcriptionService.preview(audio: audio, updates: continuation)
                    for await partial in updates {
                        try Task.checkCancellation()
                        guard self.appState.isRecording else { break }
                        // A fresh pass starts from its first token. Keep the existing preview until
                        // the new pass catches up, then publish incremental words as they arrive.
                        guard partial.count >= self.appState.liveTranscript.count,
                              partial != self.appState.liveTranscript else { continue }
                        await self.publishLiveText(partial)
                        DictationDiagnostics.record("preview.partial.published", ["characters": String(partial.count)])
                        // Allow the receiving editor to process its queued key events before readback.
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let text = try await decoded
                    DictationDiagnostics.record("preview.decode.end", ["characters": String(text.count)])
                    guard !Task.isCancelled, self.appState.isRecording else { return }
                    await self.publishLiveText(text)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.appState.isRecording else { return }
                    DictationDiagnostics.record("preview.decode.error", ["type": String(reflecting: type(of: error))])
                    self.updateStatusText("Live transcription delayed; finishing on release")
                }
            }
        }
    }

    private func publishLiveText(_ text: String) async {
        guard appState.isRecording, !text.isEmpty, text != appState.liveTranscript else { return }
        let inserted = await liveTyping?.update(text: text)
        guard appState.isRecording, !Task.isCancelled else { return }
        appState.liveTranscript = text
        if inserted == false {
            updateStatusText("Live insertion paused: \(liveTyping?.suspendedReason ?? "target unavailable")")
        }
    }

    private func checkForPhysicalRelease() {
        guard pushToTalkGate.release(physicallyHeld: isDictationShortcutPhysicallyHeld()) else { return }
        DictationDiagnostics.record("hotkey.physicalRelease")
        stopRecordingAndTranscribe()
    }

    @objc private func cancelDictation() {
        guard appState.isBusy, cleanupTask == nil else { return }
        pushToTalkGate.reset()
        meterTask?.cancel()
        meterTask = nil
        let oldPreview = previewTask
        let oldPipeline = pipelineTask
        oldPreview?.cancel()
        oldPipeline?.cancel()
        previewTask = nil
        _ = audioRecorder.stopRecording()
        liveTyping?.end()
        liveTyping = nil
        listeningOverlay.hide()
        appState.state = .transcribing
        DictationDiagnostics.record("pipeline.cancelled")
        updateStatusText("Cancelling…")
        cleanupTask = Task {
            await oldPreview?.value
            await oldPipeline?.value
            cleanupTask = nil
            finish(status: "Cancelled")
        }
        updateIcon()
    }

    private func stopRecordingAndTranscribe() {
        guard appState.isRecording else { return }
        pushToTalkGate.reset()
        meterTask?.cancel()
        meterTask = nil
        let pendingPreview = previewTask
        pendingPreview?.cancel()
        previewTask = nil
        let audio = audioRecorder.stopRecording()
        DictationDiagnostics.record("capture.stopped", ["samples": String(audio?.samples.count ?? 0), "hasSpeech": String(audio?.hasSpeech ?? false)])
        let shouldCorrect = appState.autoCorrect
        appState.state = .transcribing
        updateIcon()
        updateStatusText("Finishing transcript…")

        pipelineTask = Task {
            defer { pipelineTask = nil }
            // Never run two Whisper decoders against the same model at once.
            await pendingPreview?.value
            guard !Task.isCancelled else { return }
            guard let audio else {
                finish(status: "No audio captured")
                return
            }
            do {
                DictationDiagnostics.record("final.decode.begin")
                let original = try await transcriptionService.transcribe(audio: audio)
                DictationDiagnostics.record("final.decode.end", ["characters": String(original.count)])
                try Task.checkCancellation()
                guard !original.isEmpty else {
                    await liveTyping?.cancel()
                    try Task.checkCancellation()
                    finish(status: "No speech detected")
                    return
                }
                appState.lastRawTranscription = original
                appState.liveTranscript = original
                var text = original
                var correctionNotice: String?
                if shouldCorrect {
                    appState.state = .correcting
                    updateIcon()
                    updateStatusText("Polishing grammar…")
                    let correction = await correctionService.correct(original)
                    try Task.checkCancellation()
                    text = correction.text
                    correctionNotice = correction.notice
                }
                appState.lastTranscription = text
                let pasteResult: String
                if let liveTyping {
                    DictationDiagnostics.record("final.insertion.begin", ["characters": String(text.count)])
                    let inserted = await liveTyping.update(text: text)
                    DictationDiagnostics.record("final.insertion.end", ["inserted": String(inserted)])
                    try Task.checkCancellation()
                    if inserted {
                        if let activeTargetPID {
                            lastCompletedInsertion = (activeTargetPID, Date())
                        }
                        pasteResult = "Inserted into target field"
                    } else if liveTyping.canPasteFinalText {
                        DictationDiagnostics.record("final.paste.fallback", ["reason": "Confirmed no live text inserted; target unchanged"])
                        pasteResult = pasteService.paste(text: liveTyping.preparedText(text), preferKeyboard: true)
                    } else {
                        DictationDiagnostics.record("final.clipboard.fallback", ["reason": liveTyping.suspendedReason ?? "target unavailable"])
                        pasteService.copy(text: text)
                        pasteResult = "Copied to clipboard: \(liveTyping.suspendedReason ?? "target unavailable")"
                    }
                } else {
                    pasteResult = pasteService.paste(text: text)
                }
                let preview = text.count > 50 ? String(text.prefix(50)) + "…" : text
                finish(status: [correctionNotice, pasteResult, preview].compactMap { $0 }.joined(separator: " | "))
                updateCorrectionMenu()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showError(error.localizedDescription)
            }
        }
    }

    private func finish(status: String) {
        pushToTalkGate.reset()
        liveTyping?.end()
        liveTyping = nil
        activeTargetPID = nil
        DictationDiagnostics.finish()
        appState.state = .idle
        listeningOverlay.hide()
        updateIcon()
        updateStatusText(status)
    }

    private func showError(_ message: String) {
        pushToTalkGate.reset()
        DictationDiagnostics.record("pipeline.error")
        DictationDiagnostics.finish()
        liveTyping?.end()
        liveTyping = nil
        activeTargetPID = nil
        errorResetTask?.cancel()
        appState.state = .error(message)
        updateIcon()
        updateStatusText("Error: \(message)")
        listeningOverlay.show(appState: appState)
        errorResetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.finish(status: "Ready")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pushToTalkGate.reset()
        cleanupTask?.cancel()
        previewTask?.cancel()
        meterTask?.cancel()
        pipelineTask?.cancel()
        errorResetTask?.cancel()
        _ = audioRecorder.stopRecording()
        liveTyping?.end()
        listeningOverlay.hide()
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
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(onModelChange: { [weak self] model in
                self?.changeModel(to: model)
            }).environment(appState)
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
