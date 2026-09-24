import CadenzaDomain

/// UI-independent entry point. Providers are supplied by the host application.
public struct Cadenza: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let defaultProvider: String

        public init(defaultProvider: String) {
            self.defaultProvider = defaultProvider
        }
    }

    public let configuration: Configuration
    private let providers: [String: any SourceProvider]

    public init(configuration: Configuration, providers: [any SourceProvider]) throws {
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
    }

    public func resolve(_ id: MediaID, provider identifier: String? = nil) async throws -> MediaResource {
        try Task.checkCancellation()
        let identifier = identifier ?? configuration.defaultProvider
        guard let provider = providers[identifier] else {
            throw CadenzaError.providerNotFound(identifier)
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
