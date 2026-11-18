import AVFoundation
import os
import WhisperKit

/// The audio callback writes here; UI and transcription tasks read immutable snapshots.
/// Every access to mutable capture data is protected by the same lock.
final class AudioCaptureBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var levels = [Float](repeating: 0, count: 24)
        var acceptingAudio = true
        var hasSpeech = false
    }
    private let storage = OSAllocatedUnfairLock(initialState: State())

    func append(_ buffer: [Float]) {
        guard !buffer.isEmpty else { return }
        let rms = sqrt(buffer.reduce(Float.zero) { $0 + $1 * $1 } / Float(buffer.count))
        let level = min(1, max(0, (20 * log10(max(rms, 0.000_001)) + 55) / 45))
        storage.withLock { state in
            guard state.acceptingAudio else { return }
            state.samples.append(contentsOf: buffer)
            state.levels.removeFirst()
            state.levels.append(level)
            state.hasSpeech = state.hasSpeech || rms > 0.001
        }
    }

    func snapshot() -> AudioSnapshot {
        storage.withLock { AudioSnapshot(samples: $0.samples, hasSpeech: $0.hasSpeech) }
    }

    func meter() -> (levels: [Float], duration: TimeInterval) {
        storage.withLock { ($0.levels, Double($0.samples.count) / 16_000) }
    }

    func finish() -> AudioSnapshot {
        storage.withLock { state in
            state.acceptingAudio = false
            return AudioSnapshot(samples: state.samples, hasSpeech: state.hasSpeech)
        }
    }
}

struct AudioSnapshot: Sendable {
    let samples: [Float]
    let hasSpeech: Bool

    var canTranscribe: Bool { hasSpeech && samples.count >= 4_000 }
}

@MainActor
final class AudioRecorder {
    private var processor: AudioProcessor?
    private var buffer: AudioCaptureBuffer?

    func startRecording() throws {
        let capture = AudioCaptureBuffer()
        let processor = AudioProcessor()
        do {
            // WhisperKit supplies mono, 16 kHz samples regardless of the input device format.
            try processor.startRecordingLive { samples in
                capture.append(samples)
            }
        } catch {
            processor.stopRecording()
            throw error
        }
        self.processor = processor
        buffer = capture
    }

    func snapshot() -> AudioSnapshot? { buffer?.snapshot() }

    func meter() -> (levels: [Float], duration: TimeInterval)? { buffer?.meter() }

    func stopRecording() -> AudioSnapshot? {
        processor?.stopRecording()
        processor = nil
        let audio = buffer?.finish()
        buffer = nil
        return audio
    }
}
