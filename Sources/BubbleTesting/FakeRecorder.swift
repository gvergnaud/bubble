// Owner: QA track. A Recorder that records nothing: drives the UI, previews and snapshot tests.
import BubbleCore
import CoreGraphics
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

    /// Window mode: windows that are gone (closed, or not on screen) at start: start() throws
    /// `.windowNotFound` for them.
    public var goneWindows: Set<CGWindowID> = []

    public func start(_ options: RecordingOptions) async throws -> URL {
        if let startError { throw startError }
        guard state == .idle else { throw RecorderError.alreadyRecording }
        if case .window(let id) = options.source, goneWindows.contains(id) { throw RecorderError.windowNotFound }
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

    // MARK: window mode (CaptureSource.window), like LiveRecorder

    /// The recorded window moved or resized (AppKit global points).
    public func simulateWindowMoved(to frame: CGRect) { onEvent?(.recordedAreaChanged(frame)) }
    /// Hidden (⌘H), minimized or on another Space, moved to another display: the take pauses
    /// itself, then says why.
    public func simulateWindowHidden(_ reason: WindowHiddenReason = .notOnScreen) {
        if state == .recording { state = .paused }
        onEvent?(.recordedWindowHidden(reason))
    }
    /// Visible again: the take stays paused until the app calls resume().
    public func simulateWindowShown() { onEvent?(.recordedWindowShown) }
    /// The window closed or its app quit: the take ends, the file is kept.
    public func simulateWindowClosed() { simulateStopOnItsOwn(.windowClosed) }
}
