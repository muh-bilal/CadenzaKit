import Foundation
import CadenzaDomain

/// Explicit catalog of direct HTTPS media URLs. Resolution performs no network I/O.
public struct HTTPSCatalogSource: SourceProvider {
    public let identifier: String
    public let supportedFeatures: Set<Feature> = [.sourceResolution, .playback, .seeking, .remotePlayback]
    private let resources: [MediaID: MediaResource]

    public init(identifier: String = "https", resources: [MediaID: MediaResource]) throws {
        for (id, resource) in resources {
            guard id == resource.id else { throw CadenzaError.resourceIdentityMismatch }
            _ = try RemoteMediaURL(resource.url)
        }
        self.identifier = identifier
        self.resources = resources
    }

    public func resolve(_ id: MediaID) async throws -> MediaResource {
        try Task.checkCancellation()
        guard let resource = resources[id] else { throw CadenzaError.resourceNotFound(id) }
        return resource
    }
}
