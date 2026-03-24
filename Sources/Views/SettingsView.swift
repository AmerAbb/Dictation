import SwiftUI

struct SettingsView: View {
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
                Picker("Whisper Model", selection: $appState.selectedModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                if !appState.isModelLoaded {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model...")
                            .foregroundStyle(.secondary)
                    }
                }
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
        .frame(width: 350, height: 300)
        .onAppear {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        micPermission = PermissionChecker.isMicrophoneAuthorized
        accessibilityPermission = PermissionChecker.isAccessibilityAuthorized
    }
}
