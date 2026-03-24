import Foundation

enum DictationState {
    case idle
    case recording
    case transcribing
    case error(String)
}

enum WhisperModel: String, CaseIterable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny English (~75MB)"
        case .base: return "Base English (~150MB)"
        case .small: return "Small English (~500MB)"
        }
    }
}

@MainActor
@Observable
class AppState {
    var state: DictationState = .idle
    var selectedModel: WhisperModel = .small
    var lastTranscription: String?
    var isModelLoaded: Bool = false

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = state { return true }
        return false
    }
}
