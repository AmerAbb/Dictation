import Foundation
import WhisperKit

/// Keeps older segments fixed while allowing the last two segments to be revised.
struct StreamingTranscript {
    private(set) var confirmedText: [String] = []
    private(set) var confirmedEnd: Float = 0

    mutating func update(segments: [(text: String, end: Float)]) -> String {
        let newSegments = segments.filter { $0.end > confirmedEnd }
        let stableCount = max(0, newSegments.count - 2)
        let stable = newSegments.prefix(stableCount)
        let preview = (confirmedText + newSegments.map(\.text)).joined(separator: " ")
        confirmedText.append(contentsOf: stable.map(\.text))
        if let last = stable.last { confirmedEnd = last.end }
        return TranscriptText.clean(preview)
    }
}

enum TranscriptText {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[.*?\]|\(.*?\)|<\|.*?\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor TranscriptionService {
    private var whisperKit: WhisperKit?
    private var currentModel: String?
    private var streamingTranscript = StreamingTranscript()

    private static var modelBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictation/Models")
    }

    func loadModel(_ model: String) async throws {
        if currentModel == model && whisperKit != nil { return }
        let config = WhisperKitConfig(
            model: model, downloadBase: Self.modelBase, verbose: false,
            prewarm: true, load: true, download: true
        )
        whisperKit = try await WhisperKit(config)
        currentModel = model
    }

    func resetStreaming() {
        streamingTranscript = StreamingTranscript()
    }

    func preview(audio: AudioSnapshot, updates: AsyncStream<String>.Continuation? = nil) async throws -> String {
        defer { updates?.finish() }
        guard audio.canTranscribe else { return "" }
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(
            task: .transcribe, language: "en", temperatureFallbackCount: 1,
            skipSpecialTokens: true, wordTimestamps: false,
            clipTimestamps: [streamingTranscript.confirmedEnd], concurrentWorkerCount: 1
        )
        let confirmedPrefix = streamingTranscript.confirmedText.joined(separator: " ")
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audio.samples, decodeOptions: options,
            callback: { progress in
                // Later windows require segment stitching; their complete results are reconciled below.
                guard progress.windowId == 0, (progress.avgLogprob ?? 0) >= -1 else { return nil }
                let text = TranscriptText.clean(confirmedPrefix + " " + progress.text)
                if !text.isEmpty, text != confirmedPrefix { updates?.yield(text) }
                return nil
            }
        )
        try Task.checkCancellation()
        return streamingTranscript.update(segments: results.flatMap(\.segments).map { ($0.text, $0.end) })
    }

    func transcribe(audio: AudioSnapshot) async throws -> String {
        guard audio.canTranscribe else { return "" }
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(
            task: .transcribe, language: "en", skipSpecialTokens: true,
            wordTimestamps: false, concurrentWorkerCount: 1
        )
        // One final pass includes the tail of the recording and reconciles provisional words.
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: audio.samples, decodeOptions: options
        )
        return TranscriptText.clean(results.map(\.text).joined(separator: " "))
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? { "Whisper model not loaded" }
}
