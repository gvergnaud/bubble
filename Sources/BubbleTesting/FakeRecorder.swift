// Owner: QA track. A Recorder that records nothing: drives the UI, previews and snapshot tests.
import BubbleCore
import Foundation

@MainActor
public final class FakeRecorder: Recorder {
    public private(set) var state: RecorderState = .idle { didSet { onEvent?(.stateChanged(state)) } }
    public var elapsed: TimeInterval = 0
    public var onEvent: (@MainActor (RecorderEvent) -> Void)?
    /// Set to make start() throw (permission missing, disk full...).
    public var startError: RecorderError?
    public private(set) var lastOptions: RecordingOptions?
    public var fileURL = URL(fileURLWithPath: "/tmp/Bubble 2026-11-06 at 14.22.05.mp4")

    public init() {}

    public func start(_ options: RecordingOptions) async throws -> URL {
        if let startError { throw startError }
        guard state == .idle else { throw RecorderError.alreadyRecording }
        lastOptions = options
        state = .starting
        state = .recording
        return fileURL
    }
    public func pause() { if state == .recording { state = .paused } }
    public func resume() { if state == .paused { state = .recording } }
    public func stop() async -> RecordingResult {
        state = .finishing
        state = .idle
        return RecordingResult(url: fileURL, duration: elapsed, bytes: 0, reason: .user)
    }
    public func discard() async { state = .idle }

    /// Test helper: the recording ends without the app asking (display unplugged, disk full...).
    public func simulateStopOnItsOwn(_ reason: StopReason) {
        state = .idle
        onEvent?(.stoppedOnItsOwn(RecordingResult(url: fileURL, duration: elapsed, bytes: 0, reason: reason)))
    }
}
