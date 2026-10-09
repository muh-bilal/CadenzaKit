import Foundation

public struct ArtworkLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumPixels: Int
    public init(maximumBytes: Int = 8_388_608, maximumPixels: Int = 32_000_000) throws {
        guard (1...67_108_864).contains(maximumBytes), (1...100_000_000).contains(maximumPixels) else { throw CadenzaError.invalidArtwork }
        self.maximumBytes = maximumBytes
        self.maximumPixels = maximumPixels
    }
}

/// Encoded image bytes. Decoding/downsampling remains an optional adapter concern.
public struct Artwork: Equatable, Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public init(data: Data, width: Int, height: Int) throws {
        guard !data.isEmpty, width > 0, height > 0 else { throw CadenzaError.invalidArtwork }
        self.data = data
        self.width = width
        self.height = height
    }
}

public enum ArtworkRequest: Equatable, Sendable {
    case embedded(URL)
    case imageFile(URL)
}

public protocol ArtworkLoader: Sendable {
    /// nil means no embedded artwork. Malformed or inaccessible data must throw.
    func load(_ request: ArtworkRequest, limits: ArtworkLimits) async throws -> Artwork?
}

public protocol ArtworkProcessor: Sendable {
    func thumbnail(_ artwork: Artwork, maximumDimension: Int) async throws -> Artwork
}
