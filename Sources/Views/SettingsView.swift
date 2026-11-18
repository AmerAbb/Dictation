import SwiftUI

struct SettingsView: View {
    var onModelChange: (WhisperModel) -> Void
    @Environment(AppState.self) private var appState
    @State private var micPermission = false
    @State private var accessibilityPermission = false

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Shortcut") {
                HStack {
                    Text("Push-to-Talk")
                    Spacer()
                    Text("⌥`")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                Picker("Whisper Model", selection: Binding(get: { appState.selectedModel }, set: onModelChange)) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .disabled(appState.isBusy || appState.isLoadingModel)

                if appState.isLoadingModel {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Dictation") {
                Toggle("Auto-correct Dictation", isOn: $appState.autoCorrect)
                    .disabled(appState.correctionUnavailableReason != nil && !appState.autoCorrect)
                Text(appState.correctionUnavailableReason ?? "Fix grammar and obvious word mistakes on this Mac before inserting text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Text appears live in the target field. The listening pill shows only microphone levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Image(systemName: micPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(micPermission ? .green : .red)
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    if accessibilityPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant Access") {
                            PermissionChecker.requestAccessibilityPermission()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 390, height: 440)
        .onAppear {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        appState.correctionUnavailableReason = CorrectionService.unavailableReason
        micPermission = PermissionChecker.isMicrophoneAuthorized
        accessibilityPermission = PermissionChecker.isAccessibilityAuthorized
    }
}
