import CadenzaDomain

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
