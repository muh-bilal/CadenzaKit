import Foundation
import CadenzaDomain

@MainActor
final class RecoveringPlaybackBackend: PlaybackBackend {
    let backend: any PlaybackBackend
    let policy: NetworkRecoveryPolicy
    let clock: any PlaybackClock
    private var generation: UInt64 = 0
    var supportedFeatures: Set<Feature> { backend.supportedFeatures }

    init(backend: any PlaybackBackend, policy: NetworkRecoveryPolicy, clock: any PlaybackClock) {
        self.backend = backend
        self.policy = policy
        self.clock = clock
    }

    func load(_ resource: MediaResource) async throws -> Double {
        try Task.checkCancellation()
        if resource.url.isFileURL { return try await backend.load(resource) }
        return try await loadAttempt(resource, attempt: 1, token: generation)
    }

    private func loadAttempt(_ resource: MediaResource, attempt: Int, token: UInt64) async throws -> Double {
        do {
            let duration = try await timedLoad(resource)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            return duration
        } catch {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            guard let reason = Self.retryable(error) else { throw error }
            backend.stop()
            guard attempt < policy.maximumAttempts else { throw CadenzaError.networkRecoveryExhausted(attempts: attempt, reason: reason) }
            try await clock.sleep(for: policy.retryDelay)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            return try await loadAttempt(resource, attempt: attempt + 1, token: token)
        }
    }

    private func timedLoad(_ resource: MediaResource) async throws -> Double {
        try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask { [backend] in try await backend.load(resource) }
            group.addTask { [clock, policy] in
                try await clock.sleep(for: policy.timeout)
                throw CadenzaError.playbackTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func retryable(_ error: any Error) -> NetworkFailure? {
        if let error = error as? CadenzaError, error == .playbackTimedOut { return .timeout }
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSURLErrorDomain {
                switch current.code {
                case NSURLErrorTimedOut: return .timeout
                case NSURLErrorNotConnectedToInternet: return .offline
                case NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .connection
                default: return nil
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
            current = underlying
        }
        return nil
    }

    func play() throws { try backend.play() }
    func pause() { backend.pause() }
    func seek(to position: Double) async throws { try await backend.seek(to: position) }
    func stop() { generation &+= 1; backend.stop() }
    func status() throws -> BackendStatus { try backend.status() }
}
