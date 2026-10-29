import Foundation
import Synchronization

/// Waits for `operation` at most `limit`, then carries on without it. The operation is cancelled when
/// the limit wins; one that ignores cancellation keeps running unobserved. Unlike a task group, this
/// returns at the limit even if the operation never comes back.
func waitingAtMost(_ limit: Duration, for operation: @escaping @Sendable () async -> Void) async {
    let gate = Mutex(false)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let finish: @Sendable () -> Void = {
            let first = gate.withLock { was in defer { was = true }; return !was }
            if first { done.resume() }
        }
        let work = Task { await operation(); finish() }
        Task {
            try? await Task.sleep(for: limit)
            work.cancel()
            finish()
        }
    }
}
