import Foundation

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case correcting
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
    var selectedModel: WhisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "selectedModel") ?? "") ?? .small {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedModel") }
    }
    var autoCorrect = UserDefaults.standard.bool(forKey: "autoCorrect") {
        didSet { UserDefaults.standard.set(autoCorrect, forKey: "autoCorrect") }
    }
    var correctionUnavailableReason: String? = CorrectionService.unavailableReason
    var lastRawTranscription: String?
    var liveTranscript = ""
    var audioLevels = [Float](repeating: 0, count: 24)
    var recordingDuration: TimeInterval = 0

    var isBusy: Bool {
        switch state {
        case .recording, .transcribing, .correcting: return true
        default: return false
        }
    }
    var lastTranscription: String?
    var isModelLoaded: Bool = false
    var isLoadingModel: Bool = true

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = state { return true }
        return false
    }
}
