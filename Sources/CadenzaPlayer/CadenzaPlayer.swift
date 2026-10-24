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
    private let nowPlaying: (any NowPlayingController)?
    private let canSeek: Bool
    private let spectrumService: SpectrumService
    private var spectrumGeneration: UInt64 = 0
    private var backgrounded = false
    private var polling: Task<Void, Never>?

    public init(source: any SourceProvider, additionalSources: [any SourceProvider] = [], features: FeatureFlags = .init(), backend: (any PlaybackBackend)? = nil, systemPlayback: (any SystemPlaybackController)? = nil, clock: any PlaybackClock = ContinuousPlaybackClock(), nowPlaying: (any NowPlayingController)? = nil, runtimeCapabilities: @escaping @Sendable () async -> RuntimeCapabilities = { .init() }) throws {
        services = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: features), providers: [source] + additionalSources, runtimeCapabilities: runtimeCapabilities)
        let backend = backend ?? AVPlayerBackend(allowRemote: features.remotePlayback)
        queue = services.makeQueue(backend: backend, systemPlayback: systemPlayback ?? AppleSystemPlaybackController())
        spectrumService = services.makeSpectrum(backend: backend)
        canSeek = features.seeking && backend.supportedFeatures.contains(.seeking)
        self.nowPlaying = features.systemPlayback ? (nowPlaying ?? AppleNowPlayingController()) : nil
        self.nowPlaying?.connect { [weak self] command in await self?.receive(command) }
        polling = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .milliseconds(250)) }
                catch { break }
                await self?.refresh()
            }
        }
    }

    deinit {
        polling?.cancel()
        let nowPlaying = nowPlaying
        let spectrumService = spectrumService
        Task { @MainActor in spectrumService.stop(); nowPlaying?.clear() }
    }

    public func play(_ id: MediaID, provider: String? = nil) async throws {
        try await play(entries: [.init(id: UUID(), mediaID: id, provider: provider)])
    }

    public func play(entries: [QueueEntry], startingAt id: UUID? = nil) async throws {
        defer { notify() }
        failure = nil
        stopSpectrum()
        try await queue.playEntries(entries, startingAt: id)
    }

    /// Select an existing queue occurrence without replacing queue history.
    public func play(entryID: UUID) async throws {
        defer { notify() }
        failure = nil
        stopSpectrum()
        try await queue.play(entryID)
    }

    public func resume() async throws { defer { notify() }; stopSpectrum(); try await queue.play() }
    public func pause() throws { defer { notify() }; try queue.pause() }
    public func seek(to position: Double) async throws { defer { notify() }; stopSpectrum(); try await queue.seek(to: position) }
    public func next() async throws { defer { notify() }; stopSpectrum(); try await queue.next() }
    public func previous() async throws { defer { notify() }; stopSpectrum(); try await queue.previous() }
    public func stop() { queue.stop(); failure = nil; notify() }

    /// Forward scene background/foreground (or Mac visibility) changes here.
    public func setBackgrounded(_ value: Bool) { backgrounded = value; stopSpectrum(); queue.setBackgrounded(value); notify() }

    /// Also available for deterministic hosts/tests; automatic sampling uses the
    /// injected clock. A competing command is retried on the next tick.
    public func refresh() async {
        guard snapshot.resource != nil, snapshot.state != .idle else { return }
        // A failed transport command already contains the useful backend error.
        // Polling an unloaded failed session would replace it with noMediaLoaded.
        if case .failed(let error) = snapshot.state { failure = error; notify(force: false); return }
        do { try await queue.refresh() }
        catch is CancellationError { return }
        catch CadenzaError.operationInProgress { return }
        catch {
            // PlaybackQueue normalizes backend failures into CadenzaError.
            failure = error as? CadenzaError
            queue.stop()
        }
        notify(force: false)
    }

    /// Sample from the same backend and current source as playback. Hosts should
    /// await sequentially at about 30 Hz and stop observation when no view needs it.
    public func readSpectrum() async throws -> SpectrumFrame {
        guard !backgrounded, snapshot.state == .playing else { stopSpectrum(); return SpectrumFrame() }
        let token = spectrumGeneration
        let resource = snapshot.resource?.id
        let provider = queue.entries.first { $0.id == queue.currentEntryID }?.provider
        let frame = try await spectrumService.read(provider: provider)
        guard token == spectrumGeneration, snapshot.state == .playing, resource == snapshot.resource?.id else { throw CancellationError() }
        return frame
    }

    public func stopSpectrum() { spectrumGeneration &+= 1; spectrumService.stop() }

    private func notify(force: Bool = true) {
        if force || snapshot.state != .playing { stopSpectrum() }
        nowPlaying?.update(snapshot, canSeek: canSeek, force: force)
        onChange?()
    }

    private func receive(_ command: SystemPlaybackCommand) async {
        do {
            // Pause remains usable after policy revocation, so audio can stop.
            let active = snapshot.state == .playing || snapshot.state == .buffering
            let pauses = command == .pause || (command == .toggle && active)
            if !pauses {
                let provider = queue.entries.first { $0.id == queue.currentEntryID }?.provider
                if case let .unavailable(reason) = try await services.availability(for: .systemPlayback, provider: provider) {
                    throw CadenzaError.featureUnavailable(.systemPlayback, reason)
                }
            }
            switch command {
            case .play: try await resume()
            case .pause: try pause()
            case .toggle:
                if active { try pause() } else { try await resume() }
            case .next: try await next()
            case .previous: try await previous()
            case .seek(let position): try await seek(to: position)
            }
        } catch is CancellationError { return }
        catch { failure = error as? CadenzaError; notify() }
    }
}
