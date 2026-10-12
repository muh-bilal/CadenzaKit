public enum NetworkFailure: String, Equatable, Sendable { case timeout, offline, connection }

public struct NetworkRecoveryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int
    public let timeout: Duration
    public let retryDelay: Duration
    public init(maximumAttempts: Int = 2, timeout: Duration = .seconds(30), retryDelay: Duration = .seconds(1)) throws {
        guard (1...5).contains(maximumAttempts), timeout > .zero, timeout <= .seconds(300),
              retryDelay >= .zero, retryDelay <= .seconds(60) else { throw CadenzaError.invalidRecoveryPolicy }
        self.maximumAttempts = maximumAttempts
        self.timeout = timeout
        self.retryDelay = retryDelay
    }
}

public protocol PlaybackClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousPlaybackClock: PlaybackClock {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
