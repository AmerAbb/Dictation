import AppKit
import SwiftUI
import Dispatch
import Foundation
import Testing
import WhisperKit
@testable import Dictation

@Test func capturePreservesAllBuffersAndIncludesTailAtStop() {
    let buffer = AudioCaptureBuffer()
    DispatchQueue.concurrentPerform(iterations: 100) { _ in
        buffer.append([Float](repeating: 0.01, count: 160))
        _ = buffer.snapshot()
    }
    let beforeTail = buffer.snapshot()
    buffer.append([Float](repeating: 0.02, count: 400))
    let finished = buffer.finish()
    // Late callbacks cannot mutate audio already handed off for the final transcription.
    buffer.append([Float](repeating: 1, count: 200))
    #expect(beforeTail.samples.count == 16_000)
    #expect(finished.samples.count == 16_400)
    #expect(finished.samples.suffix(400).allSatisfy { $0 == 0.02 })
    #expect(buffer.snapshot().samples == finished.samples)
    #expect(finished.canTranscribe)
}

@Test func silentAndAccidentalShortRecordingsAreNotTranscribed() {
    let silent = AudioCaptureBuffer()
    silent.append([Float](repeating: 0, count: 32_000))
    #expect(!silent.finish().canTranscribe)
    let short = AudioCaptureBuffer()
    short.append([Float](repeating: 0.1, count: 1_000))
    #expect(!short.finish().canTranscribe)
}

@Test func provisionalWordsCanChangeWithoutDuplicatingConfirmedText() {
    var transcript = StreamingTranscript()
    #expect(transcript.update(segments: [
        ("We should", 1), ("meet on", 2), ("Monday.", 3)
    ]) == "We should meet on Monday.")
    #expect(transcript.confirmedEnd == 1)
    #expect(transcript.update(segments: [
        ("meet on", 2), ("Tuesday.", 3), ("At noon.", 4)
    ]) == "We should meet on Tuesday. At noon.")
    #expect(transcript.confirmedEnd == 2)
    #expect(transcript.update(segments: [
        ("meet on", 2), ("Tuesday.", 3), ("At one.", 4)
    ]) == "We should meet on Tuesday. At one.")
}

@Test func nonSpeechMarkersDoNotLeakIntoPreviewOrPastedText() {
    #expect(TranscriptText.clean(" [Music]  Hello   there. <|endoftext|> ") == "Hello there.")
    #expect(TranscriptText.clean("[Silence] (noise)").isEmpty)
}

@Test func correctionRejectsMissingOrGrosslyChangedOutput() {
    let original = "Yesterday I goes to the store and buy some apples for dinner."
    #expect(CorrectionService.isPlausibleCorrection(
        "Yesterday I went to the store and bought some apples for dinner.", of: original))
    #expect(!CorrectionService.isPlausibleCorrection("", of: original))
    #expect(!CorrectionService.isPlausibleCorrection("Apples.", of: original))
    #expect(!CorrectionService.isPlausibleCorrection(
        String(repeating: "Invented extra details ", count: 20), of: original))
}

// Opt in with a synthetic audio fixture; regular tests never download or load models.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DICTATION_TEST_AUDIO"] != nil))
func cachedWhisperModelProducesPreviewAndFinalTail() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["DICTATION_TEST_AUDIO"])
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    let service = TranscriptionService()
    try await service.loadModel("base.en")
    await service.resetStreaming()
    let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(64))
    async let decoding = service.preview(audio: AudioSnapshot(
        samples: Array(samples.prefix(samples.count / 2)), hasSpeech: true), updates: continuation)
    var partials: [String] = []
    for await partial in updates { partials.append(partial) }
    let preview = try await decoding
    #expect(partials.count > 1)
    #expect(partials.contains { !$0.isEmpty && $0.count < preview.count })
    print("Partial decode updates: \(partials.count)")
    // Releasing the shortcut can cancel a preview halfway through inference.
    let pendingPreview = Task {
        try await service.preview(audio: AudioSnapshot(samples: samples, hasSpeech: true))
    }
    try await Task.sleep(for: .milliseconds(50))
    pendingPreview.cancel()
    _ = await pendingPreview.result
    let final = try await service.transcribe(audio: AudioSnapshot(samples: samples, hasSpeech: true))
    print("Synthetic speech preview: \(preview)")
    print("Synthetic speech final: \(final)")
    #expect(!preview.isEmpty)
    #expect(final.localizedCaseInsensitiveContains("tomorrow"))
    #expect(final.localizedCaseInsensitiveContains("dinner"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DICTATION_TEST_CORRECTION"] != nil))
func localCorrectionRunsOrExplainsUnavailability() async {
    let original = "Yesterday I goes to the store and buy some apples."
    let result = await CorrectionService().correct(original)
    print("Correction result: \(result.text); notice: \(result.notice ?? "none")")
    if CorrectionService.unavailableReason == nil {
        #expect(result.notice == nil)
        #expect(result.text != original)
        #expect(result.text.localizedCaseInsensitiveContains("apples"))
        #expect(result.text.localizedCaseInsensitiveContains("went"))
        #expect(result.text.localizedCaseInsensitiveContains("bought"))
    } else {
        #expect(result.text == original)
        #expect(result.notice != nil)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DICTATION_TEST_PREVIEW"] != nil))
@MainActor func renderListeningPillForInspection() throws {
    _ = NSApplication.shared
    let state = AppState()
    state.state = .recording
    state.liveTranscript = "We should meet tomorrow afternoon to discuss the project."
    state.recordingDuration = 12
    state.audioLevels = [Float](repeating: 0, count: 23) + [0.65]
    let renderer = ImageRenderer(content: ListeningPill(appState: state)
        .frame(width: 108, height: 60).background(Color.black.opacity(0.8)))
    renderer.scale = 2
    let cgImage = try #require(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: "/tmp/dictation-listening-preview.png"))
}

@Test func silentPreviewFinishesItsUpdateStreamWithoutLoadingAModel() async throws {
    let service = TranscriptionService()
    let (updates, continuation) = AsyncStream<String>.makeStream()
    async let decoding = service.preview(audio: AudioSnapshot(samples: [], hasSpeech: false), updates: continuation)
    var count = 0
    for await _ in updates { count += 1 }
    let result = try await decoding
    #expect(count == 0)
    #expect(result.isEmpty)
}
