import Foundation
import CadenzaDomain

/// Explicit host-owned catalog. The host retains sandbox/security-scoped access
/// for the entire playback lifetime; this provider does not invent permissions.
public struct LocalFileSource: SourceProvider {
    public let identifier: String
    public let supportedFeatures: Set<Feature> = [.sourceResolution, .playback, .systemPlayback, .seeking, .equalizer, .spectrum]
    private let resources: [MediaID: MediaResource]

    public init(identifier: String = "local", resources: [MediaID: MediaResource]) throws {
        for (id, resource) in resources {
            guard id == resource.id else { throw CadenzaError.resourceIdentityMismatch }
            guard resource.url.isFileURL else { throw CadenzaError.unsupportedURL }
        }
        self.identifier = identifier
        self.resources = resources
    }

    public func resolve(_ id: MediaID) async throws -> MediaResource {
        try Task.checkCancellation()
        guard let resource = resources[id] else { throw CadenzaError.resourceNotFound(id) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resource.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: resource.url.path) else {
            throw CadenzaError.unreadableFile
        }
        return resource
    }
}
