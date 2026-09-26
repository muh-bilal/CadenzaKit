public struct BackendStatus: Equatable, Sendable {
    public let position: Double
    public let isPlaying: Bool
    public let ended: Bool

    public init(position: Double, isPlaying: Bool, ended: Bool) {
        self.position = position
        self.isPlaying = isPlaying
        self.ended = ended
    }
}

/// Serialized on the main actor for Apple media APIs; it has no UI dependency.
/// stop() must invalidate pending load/seek operations. Methods must not publish a
/// stale result after stop or caller cancellation. Position/duration are seconds.
@MainActor
public protocol PlaybackBackend: AnyObject, Sendable {
    var supportedFeatures: Set<Feature> { get }
    func load(_ resource: MediaResource) async throws -> Double
    func play() throws
    func pause()
    func seek(to position: Double) async throws
    func stop()
    func status() throws -> BackendStatus
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading(MediaID)
    case ready
    case playing
    case paused
    case ended
    case failed(CadenzaError)
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public let state: PlaybackState
    public let resource: MediaResource?
    public let position: Double
    public let duration: Double

    public init(state: PlaybackState, resource: MediaResource?, position: Double, duration: Double) {
        self.state = state
        self.resource = resource
        self.position = position
        self.duration = duration
    }
}
