import CadenzaDomain

/// A lightweight injected provider for tests and host-owned source integrations.
public struct ClosureSourceProvider: SourceProvider {
    public let identifier: String
    private let resolveBody: @Sendable (MediaID) async throws -> MediaResource

    public init(
        identifier: String,
        resolve: @escaping @Sendable (MediaID) async throws -> MediaResource
    ) {
        self.identifier = identifier
        self.resolveBody = resolve
    }

    public func resolve(_ id: MediaID) async throws -> MediaResource {
        try await resolveBody(id)
    }
}
