import Foundation
import CadenzaDomain

/// Explicit catalog of direct HTTPS media URLs. Resolution performs no network I/O.
public struct HTTPSCatalogSource: SourceProvider {
    public let identifier: String
    public let supportedFeatures: Set<Feature>
    private let resources: [MediaID: MediaResource]

    public init(identifier: String = "https", resources: [MediaID: MediaResource], allowsDownloads: Bool = false) throws {
        for (id, resource) in resources {
            guard id == resource.id else { throw CadenzaError.resourceIdentityMismatch }
            _ = try RemoteMediaURL(resource.url)
        }
        self.identifier = identifier
        self.resources = resources
        self.supportedFeatures = allowsDownloads ? [.sourceResolution, .playback, .systemPlayback, .seeking, .remotePlayback, .downloads] : [.sourceResolution, .playback, .systemPlayback, .seeking, .remotePlayback]
    }

    public func resolve(_ id: MediaID) async throws -> MediaResource {
        try Task.checkCancellation()
        guard let resource = resources[id] else { throw CadenzaError.resourceNotFound(id) }
        return resource
    }
}
