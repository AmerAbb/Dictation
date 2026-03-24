import Foundation
import WhisperKit

actor TranscriptionService {
    private var whisperKit: WhisperKit?
    private var currentModel: String?

    private static var modelBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictation/Models")
    }

    func loadModel(_ model: String) async throws {
        if currentModel == model && whisperKit != nil { return }

        let config = WhisperKitConfig(
            model: model,
            downloadBase: Self.modelBase,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        currentModel = model
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            wordTimestamps: false
        )

        let results = try await whisperKit.transcribe(
            audioPath: fileURL.path,
            decodeOptions: options
        )

        let raw = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.stripNonSpeechAnnotations(raw)
    }

    private static func stripNonSpeechAnnotations(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\[.*?\]|\(.*?\)"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isLoaded: Bool {
        whisperKit != nil
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded"
        }
    }
}
