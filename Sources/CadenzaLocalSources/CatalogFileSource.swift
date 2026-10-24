import Foundation
import CadenzaDomain

/// A live catalog lookup, with local-file access validated after lookup.
public struct CatalogFileSource: SourceProvider {
    public let identifier: String
    public let supportedFeatures: Set<Feature> = [.sourceResolution, .playback, .systemPlayback, .seeking, .equalizer, .spectrum]
    private let lookup: @Sendable (MediaID) async throws -> MediaResource

    public init(identifier: String, lookup: @escaping @Sendable (MediaID) async throws -> MediaResource) {
        self.identifier = identifier
        self.lookup = lookup
    }

    public func resolve(_ id: MediaID) async throws -> MediaResource {
        try Task.checkCancellation()
        let media = try await lookup(id)
        let source = try LocalFileSource(identifier: identifier, resources: [id: media])
        return try await source.resolve(id)
    }
}
