import Testing
@testable import Dictation

@Test func delayedKeyDownAfterPhysicalReleaseDoesNotStartRecording() {
    var gate = PushToTalkGate()
    let releaseBeforeStart = gate.release(physicallyHeld: false)
    let delayedPress = gate.press(physicallyHeld: false)
    #expect(!releaseBeforeStart)
    #expect(!delayedPress)
    #expect(!gate.isRecording)
}

@Test func missedKeyUpIsRecoveredByPollingPhysicalState() {
    var gate = PushToTalkGate()
    let started = gate.press(physicallyHeld: true)
    let stillHeld = gate.release(physicallyHeld: true)
    let polledRelease = gate.release(physicallyHeld: false)
    let duplicateRelease = gate.release(physicallyHeld: false)
    #expect(started)
    #expect(!stillHeld)
    #expect(polledRelease)
    #expect(!duplicateRelease)
    #expect(!gate.isRecording)
}

@Test func syntheticReleaseWhileTheUserStillHoldsTheShortcutIsIgnored() {
    var gate = PushToTalkGate()
    let started = gate.press(physicallyHeld: true)
    let duplicatePress = gate.press(physicallyHeld: true)
    let syntheticRelease = gate.release(physicallyHeld: true)
    #expect(started)
    #expect(!duplicatePress)
    #expect(!syntheticRelease)
    #expect(gate.isRecording)
}

@Test func cancellingOrCaptureFailureCanResetTheRecordingGate() {
    var gate = PushToTalkGate()
    let started = gate.press(physicallyHeld: true)
    gate.reset()
    #expect(started)
    #expect(!gate.isRecording)
    let releasedPress = gate.press(physicallyHeld: false)
    let nextPress = gate.press(physicallyHeld: true)
    #expect(!releasedPress)
    #expect(nextPress)
}
