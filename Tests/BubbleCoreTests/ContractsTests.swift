// Owner: QA track.
import BubbleCore
import BubbleTesting
import Testing

@MainActor @Test func fakeRecorderGoesThroughStates() async throws {
    let recorder = FakeRecorder()
    var states: [RecorderState] = []
    recorder.onEvent = { if case .stateChanged(let s) = $0 { states.append(s) } }
    let options = RecordingOptions(displayID: 1, bubbleWindowID: nil, microphoneID: nil,
                                   captureComputerSound: false, showClicks: true, folder: RecordingFiles.defaultFolder)
    _ = try await recorder.start(options)
    recorder.pause(); recorder.resume()
    _ = await recorder.stop()
    #expect(states == [.starting, .recording, .paused, .recording, .finishing, .idle])
}
