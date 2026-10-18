import Foundation

/// Owns bounded work for one physical connection. This is lifecycle control, not authorization.
/// Closing it cancels pending adapter work; durable Core obligations retain their own ownership.
public final class NativeCallRegistry: @unchecked Sendable {
    public static let maximumCalls = 32
    private let lock = NSLock()
    private var closed = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public init() {}
    public var pendingCount: Int { lock.withLock { tasks.count } }
    @discardableResult public func start(_ operation: @escaping @Sendable () async -> Void) throws -> UUID {
        try lock.withLock {
            guard !closed, tasks.count < Self.maximumCalls else { throw NativeIPCFailure.unavailable }
            let token = UUID()
            // Completion takes the same lock, so it cannot remove the token before insertion.
            tasks[token] = Task { [weak self] in
                if !Task.isCancelled { await operation() }
                self?.finished(token)
            }
            return token
        }
    }
    public func close() {
        let retained = lock.withLock {
            closed = true
            let retained = Array(tasks.values); tasks.removeAll(); return retained
        }
        for task in retained { task.cancel() }
    }
    private func finished(_ token: UUID) { _ = lock.withLock { tasks.removeValue(forKey: token) } }
    deinit { for task in tasks.values { task.cancel() } }
}
