import Foundation
import CadenzaDomain
import CadenzaKit
import CadenzaAVPlayback
import CadenzaSystemPlayback

/// A host-supplied resolver. Catalogs, authentication and URL lifetimes belong to
/// the host; the selected playback backend still validates the resolved media.
public struct MediaSource: SourceProvider {
    public let identifier: String
    public let supportedFeatures: Set<Feature>
    private let resolver: @Sendable (MediaID) async throws -> MediaResource

    public init(identifier: String = "app", supportedFeatures: Set<Feature> = [.sourceResolution, .playback, .seeking, .remotePlayback, .systemPlayback], resolve: @escaping @Sendable (MediaID) async throws -> MediaResource) {
        self.identifier = identifier
        self.supportedFeatures = supportedFeatures
        resolver = resolve
    }
    public func resolve(_ id: MediaID) async throws -> MediaResource { try await resolver(id) }
}

/// Optional Apple composition facade. Retain at app scope, independently of UI.
/// Low-level Cadenza services remain independently selectable without this target.
@MainActor
public final class CadenzaPlayer {
    public let services: Cadenza
    public let queue: PlaybackQueue
    public var snapshot: PlaybackSnapshot { queue.snapshot }
    public private(set) var failure: CadenzaError?
    public var onChange: (() -> Void)?
    private var polling: Task<Void, Never>?

    public init(source: any SourceProvider, additionalSources: [any SourceProvider] = [], features: FeatureFlags = .init(), backend: (any PlaybackBackend)? = nil, systemPlayback: (any SystemPlaybackController)? = nil, clock: any PlaybackClock = ContinuousPlaybackClock(), runtimeCapabilities: @escaping @Sendable () async -> RuntimeCapabilities = { .init() }) throws {
        services = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: features), providers: [source] + additionalSources, runtimeCapabilities: runtimeCapabilities)
        queue = services.makeQueue(backend: backend ?? AVPlayerBackend(allowRemote: features.remotePlayback), systemPlayback: systemPlayback ?? AppleSystemPlaybackController())
        polling = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .milliseconds(250)) }
                catch { break }
                await self?.refresh()
            }
        }
    }

    deinit { polling?.cancel() }

    public func play(_ id: MediaID, provider: String? = nil) async throws {
        try await play(entries: [.init(id: UUID(), mediaID: id, provider: provider)])
    }

    public func play(entries: [QueueEntry], startingAt id: UUID? = nil) async throws {
        defer { onChange?() }
        failure = nil
        try await queue.playEntries(entries, startingAt: id)
    }

    public func resume() async throws { defer { onChange?() }; try await queue.play() }
    public func pause() throws { defer { onChange?() }; try queue.pause() }
    public func seek(to position: Double) async throws { defer { onChange?() }; try await queue.seek(to: position) }
    public func next() async throws { defer { onChange?() }; try await queue.next() }
    public func previous() async throws { defer { onChange?() }; try await queue.previous() }
    public func stop() { queue.stop(); failure = nil; onChange?() }

    /// Forward scene background/foreground (or Mac visibility) changes here.
    public func setBackgrounded(_ value: Bool) { queue.setBackgrounded(value); onChange?() }

    /// Also available for deterministic hosts/tests; automatic sampling uses the
    /// injected clock. A competing command is retried on the next tick.
    public func refresh() async {
        guard snapshot.resource != nil, snapshot.state != .idle else { return }
        do { try await queue.refresh() }
        catch is CancellationError { return }
        catch CadenzaError.operationInProgress { return }
        catch {
            // PlaybackQueue normalizes backend failures into CadenzaError.
            failure = error as? CadenzaError
            queue.stop()
        }
        onChange?()
    }
}
