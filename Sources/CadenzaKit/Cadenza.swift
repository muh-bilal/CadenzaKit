import CadenzaDomain
import Foundation

/// UI-independent entry point. Providers are supplied by the host application.
public struct Cadenza: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let defaultProvider: String
        public let features: FeatureFlags

        public init(defaultProvider: String, features: FeatureFlags = .init()) {
            self.defaultProvider = defaultProvider
            self.features = features
        }
    }

    public let configuration: Configuration
    private let providers: [String: any SourceProvider]
    private let runtimeCapabilities: @Sendable () async -> RuntimeCapabilities

    public init(
        configuration: Configuration,
        providers: [any SourceProvider],
        runtimeCapabilities: @escaping @Sendable () async -> RuntimeCapabilities = { .init() }
    ) throws {
        var registry: [String: any SourceProvider] = [:]
        for provider in providers {
            guard registry.updateValue(provider, forKey: provider.identifier) == nil else {
                throw CadenzaError.duplicateProvider(provider.identifier)
            }
        }
        guard registry[configuration.defaultProvider] != nil else {
            throw CadenzaError.providerNotFound(configuration.defaultProvider)
        }
        self.configuration = configuration
        self.providers = registry
        self.runtimeCapabilities = runtimeCapabilities
    }

    public func availability(for feature: Feature, provider identifier: String? = nil) async throws -> FeatureAvailability {
        try Task.checkCancellation()
        let identifier = identifier ?? configuration.defaultProvider
        guard let provider = providers[identifier] else { throw CadenzaError.providerNotFound(identifier) }
        let runtime = await runtimeCapabilities()
        try Task.checkCancellation()
        return runtime.availability(for: feature, flags: configuration.features, source: provider.supportedFeatures)
    }

    @MainActor
    public func makeSession(backend: any PlaybackBackend) -> PlaybackSession {
        PlaybackSession(kit: self, backend: backend)
    }

    @MainActor
    public func makeResilientSession(backend: any PlaybackBackend, policy: NetworkRecoveryPolicy, clock: any PlaybackClock = ContinuousPlaybackClock()) throws -> PlaybackSession {
        guard configuration.features.networkRecovery else { throw CadenzaError.networkRecoveryDisabled }
        return makeSession(backend: RecoveringPlaybackBackend(backend: backend, policy: policy, clock: clock))
    }

    @MainActor
    public func makeResilientQueue(backend: any PlaybackBackend, policy: NetworkRecoveryPolicy, clock: any PlaybackClock = ContinuousPlaybackClock(), random: any RandomNumberGenerator = SystemRandomNumberGenerator()) throws -> PlaybackQueue {
        let session = try makeResilientSession(backend: backend, policy: policy, clock: clock)
        return PlaybackQueue(session: session, flags: configuration.features, random: random)
    }

    public func makeBookmarks(store: any DocumentStore, now: @escaping @Sendable () -> Date = { Date() }) -> BookmarkService {
        BookmarkService(flags: configuration.features, store: store, now: now)
    }

    public func makePlaylists(store: any DocumentStore, now: @escaping @Sendable () -> Date = { Date() }) -> PlaylistService {
        PlaylistService(flags: configuration.features, store: store, now: now,
                        registeredProviders: Set(providers.keys), defaultProvider: configuration.defaultProvider)
    }

    public func makeLibrary(root: URL, namespace: MediaID, store: any DocumentStore, catalog: any FileCatalog, metadata: any MetadataReader) -> LibraryService {
        LibraryService(flags: configuration.features, root: root, namespace: namespace, store: store, catalog: catalog, reader: metadata)
    }

    public func makeSmartPlaylists(store: any DocumentStore, library: LibraryService) -> SmartPlaylistService {
        SmartPlaylistService(flags: configuration.features, store: store, library: library)
    }

    public func makeArtwork(loader: any ArtworkLoader, limits: ArtworkLimits) -> ArtworkService {
        ArtworkService(kit: self, loader: loader, limits: limits)
    }

    public func makeArtworkThumbnails(processor: any ArtworkProcessor, maximumCacheBytes: Int = 16_777_216) throws -> ArtworkThumbnailService {
        try ArtworkThumbnailService(flags: configuration.features, processor: processor, maximumCacheBytes: maximumCacheBytes)
    }

    public func makeArtworkExport(exporter: any ArtworkExporter) -> ArtworkExportService {
        ArtworkExportService(flags: configuration.features, exporter: exporter)
    }

    @MainActor
    public func makeQueue(backend: any PlaybackBackend, random: any RandomNumberGenerator = SystemRandomNumberGenerator()) -> PlaybackQueue {
        PlaybackQueue(session: makeSession(backend: backend), flags: configuration.features, random: random)
    }

    public func resolve(_ id: MediaID, provider identifier: String? = nil) async throws -> MediaResource {
        try Task.checkCancellation()
        let identifier = identifier ?? configuration.defaultProvider
        guard let provider = providers[identifier] else {
            throw CadenzaError.providerNotFound(identifier)
        }
        if case let .unavailable(reason) = try await availability(for: .sourceResolution, provider: identifier) {
            throw CadenzaError.featureUnavailable(.sourceResolution, reason)
        }
        let resource: MediaResource
        do {
            resource = try await provider.resolve(id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CadenzaError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw CadenzaError.sourceFailure(provider: identifier, message: String(describing: error))
        }
        try Task.checkCancellation()
        guard resource.id == id else { throw CadenzaError.resourceIdentityMismatch }
        return resource
    }
}
