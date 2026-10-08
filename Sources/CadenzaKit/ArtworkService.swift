import Foundation
import CadenzaDomain

public struct ArtworkService: Sendable {
    private let kit: Cadenza
    private let loader: any ArtworkLoader
    private let limits: ArtworkLimits

    init(kit: Cadenza, loader: any ArtworkLoader, limits: ArtworkLimits) {
        self.kit = kit
        self.loader = loader
        self.limits = limits
    }

    public func load(_ id: MediaID, provider: String? = nil) async throws -> Artwork? {
        try authorize()
        let media = try await kit.resolve(id, provider: provider)
        return try await loadRequest(.embedded(media.url))
    }

    public func loadImage(at url: URL) async throws -> Artwork? {
        try authorize()
        return try await loadRequest(.imageFile(url))
    }

    private func loadRequest(_ request: ArtworkRequest) async throws -> Artwork? {
        do {
            let artwork = try await loader.load(request, limits: limits)
            try Task.checkCancellation()
            if let artwork {
                guard artwork.data.count <= limits.maximumBytes, artwork.width <= limits.maximumPixels / artwork.height else { throw CadenzaError.artworkTooLarge }
            }
            return artwork
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.artworkFailure(String(describing: error)) }
    }

    private func authorize() throws {
        try Task.checkCancellation()
        guard kit.configuration.features.artwork else { throw CadenzaError.artworkDisabled }
    }
}
