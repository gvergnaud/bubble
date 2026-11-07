// Owner: E2 (media). docs/editor-architecture.md §4: where blocking AVFoundation reads run.
// A `copyNextSampleBuffer()` loop blocks its thread. On Swift concurrency's cooperative pool (one thread
// per core) a few at once used every thread: MediaToolbox's own read scheduler then waited forever and
// nothing else in the process could run, test time limits included (the gate's 600 s hang, 3 runs in 3
// with 3 test processes at once). So every such loop runs here, on its own dispatch thread, awaited.
import Foundation

public enum BlockingRead {
    private static let queue = DispatchQueue(label: "bubble.media.blocking-read", qos: .userInitiated, attributes: .concurrent)

    /// Runs `body` off the cooperative pool and returns its result. `body` gets a check to call between
    /// reads: it throws `CancellationError` once the awaiting task is cancelled.
    public static func run<T: Sendable>(_ body: @escaping @Sendable (_ checkCancellation: () throws -> Void) throws -> T) async throws -> T {
        let cancelled = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
                queue.async {
                    done.resume(with: Result { try body { if cancelled.isSet { throw CancellationError() } } })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
