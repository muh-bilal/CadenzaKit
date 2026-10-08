import Foundation
import AVFoundation
import ImageIO
import CadenzaDomain

/// Local-only artwork loading. Host applications retain sandbox access.
public struct AppleArtworkLoader: ArtworkLoader {
    public init() {}

    public func load(_ request: ArtworkRequest, limits: ArtworkLimits) async throws -> Artwork? {
        try Task.checkCancellation()
        do {
            let data: Data
            switch request {
            case let .embedded(url):
                guard url.isFileURL else { throw CadenzaError.unsupportedURL }
                let items = try await AVURLAsset(url: url).load(.commonMetadata)
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first else { return nil }
                guard let bytes = try await item.load(.dataValue) else { throw CadenzaError.invalidArtwork }
                data = bytes
            case let .imageFile(url):
                guard url.isFileURL else { throw CadenzaError.unsupportedURL }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw CadenzaError.unreadableFile }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var bytes = Data()
                while bytes.count <= limits.maximumBytes {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(65_536, limits.maximumBytes + 1 - bytes.count)) ?? Data()
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                }
                data = bytes
            }
            try Task.checkCancellation()
            guard data.count <= limits.maximumBytes else { throw CadenzaError.artworkTooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw CadenzaError.invalidArtwork }
            guard width <= limits.maximumPixels / height else { throw CadenzaError.artworkTooLarge }
            return try Artwork(data: data, width: width, height: height)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.artworkFailure(String(describing: error)) }
    }
}
