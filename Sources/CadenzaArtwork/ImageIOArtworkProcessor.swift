import Foundation
import ImageIO
import UniformTypeIdentifiers
import CadenzaDomain

public struct ImageIOArtworkProcessor: ArtworkProcessor {
    public init() {}

    public func thumbnail(_ artwork: Artwork, maximumDimension: Int) async throws -> Artwork {
        try Task.checkCancellation()
        guard (1...4096).contains(maximumDimension) else { throw CadenzaError.invalidArtwork }
        guard let source = CGImageSourceCreateWithData(artwork.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CadenzaError.invalidArtwork }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CadenzaError.invalidArtwork }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CadenzaError.invalidArtwork }
        try Task.checkCancellation()
        return try Artwork(data: data as Data, width: image.width, height: image.height)
    }
}
