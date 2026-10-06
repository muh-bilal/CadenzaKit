import Foundation
import AVFoundation
import CadenzaDomain

public struct AVMetadataReader: MetadataReader {
    public init() {}

    public func metadata(at url: URL) async throws -> MediaMetadata {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CadenzaError.unsupportedURL }
        do {
            let asset = AVURLAsset(url: url)
            let (playable, duration, items) = try await asset.load(.isPlayable, .duration, .commonMetadata)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard playable, !audio.isEmpty else { throw CadenzaError.unsupportedMedia }
            var title: String?, artist: String?, album: String?
            for item in items {
                try Task.checkCancellation()
                switch item.commonKey {
                case .commonKeyTitle: title = try await item.load(.stringValue)
                case .commonKeyArtist: artist = try await item.load(.stringValue)
                case .commonKeyAlbumName: album = try await item.load(.stringValue)
                default: break
                }
            }
            try Task.checkCancellation()
            return try MediaMetadata(title: title ?? url.deletingPathExtension().lastPathComponent, artist: artist, album: album, duration: duration.seconds)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.libraryFailure(String(describing: error)) }
    }
}
