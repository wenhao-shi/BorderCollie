import Foundation

enum UsageQuotaQueryError: Error, Equatable {
    case timedOut
}

enum UsageQuotaQuery {
    /// Runs a provider query with a hard deadline.
    ///
    /// The deadline has to hold even when the provider is stuck in synchronous
    /// work it cannot cancel (a credential lookup blocked on the system, say).
    /// A task group cannot do that: leaving `withTaskGroup` waits for every
    /// child, so a blocked child keeps the caller — and its `isLoading` guard —
    /// stuck past the timeout. The provider therefore runs in an unstructured
    /// task that is abandoned (and cancelled) when the deadline wins.
    static func query(
        service: any UsageTrackingService,
        timeout: Duration = .seconds(20)
    ) async -> Result<SubscriptionQuota, UsageQuotaQueryError> {
        let outcome = FirstResult<Result<SubscriptionQuota, UsageQuotaQueryError>>()
        let work = Task {
            await service.getSubscriptionQuota()
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.install(continuation)

                let deadline = Task {
                    try? await Task.sleep(for: timeout)
                    if outcome.resume(with: .failure(.timedOut)) {
                        work.cancel()
                    }
                }

                Task {
                    let quota = await work.value
                    outcome.resume(with: .success(quota))
                    deadline.cancel()
                }
            }
        } onCancel: {
            work.cancel()
            outcome.resume(with: .failure(.timedOut))
        }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var resumed = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns true when this call delivered the result.
    @discardableResult
    func resume(with value: Value) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        guard let continuation else {
            // Cancelled before the continuation was installed.
            pending = value
            lock.unlock()
            return true
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}
