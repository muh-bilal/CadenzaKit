import Foundation
import CadenzaDomain

public struct AudioDownloadService: Sendable {
    private let kit: Cadenza
    private let transfer: any AudioTransfer
    private let store: any OfflineAudioStore
    private let metadata: any MetadataReader
    private let maximumBytes: Int
    private let now: @Sendable () -> Date

    init(kit: Cadenza, transfer: any AudioTransfer, store: any OfflineAudioStore, metadata: any MetadataReader, maximumBytes: Int, now: @escaping @Sendable () -> Date) throws {
        guard (1...67_108_864).contains(maximumBytes) else { throw CadenzaError.invalidDownload }
        self.kit = kit; self.transfer = transfer; self.store = store; self.metadata = metadata
        self.maximumBytes = maximumBytes; self.now = now
    }

    public func download(_ mediaID: MediaID, provider: String? = nil, as id: MediaID) async throws -> OfflineAudio {
        try authorize()
        if case let .unavailable(reason) = try await kit.availability(for: .downloads, provider: provider) { throw CadenzaError.featureUnavailable(.downloads, reason) }
        let media = try await kit.resolve(mediaID, provider: provider)
        _ = try RemoteMediaURL(media.url)
        guard OfflineAudio.supportedExtensions.contains(media.url.pathExtension.lowercased()) else { throw CadenzaError.invalidDownload }
        let data: Data
        do { data = try await transfer.fetch(media.url, maximumBytes: maximumBytes) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { try Task.checkCancellation(); throw CadenzaError.downloadFailure(String(describing: error)) }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw CadenzaError.downloadTooLarge }
        return try await store.save(data, id: id, source: media, provider: provider ?? kit.configuration.defaultProvider,
                                    createdAt: now(), metadata: DownloadMetadataReader(reader: metadata, fallbackTitle: media.title))
    }

    public func all() async throws -> [OfflineAudio] { try authorize(); return try await store.all() }
    public func resource(_ id: MediaID) async throws -> MediaResource { try authorize(); return try await store.resource(id) }

    private func authorize() throws {
        try Task.checkCancellation()
        guard kit.configuration.features.downloads else { throw CadenzaError.downloadsDisabled }
        guard kit.configuration.features.persistence else { throw CadenzaError.persistenceDisabled }
    }
}

private struct DownloadMetadataReader: MetadataReader {
    let reader: any MetadataReader
    let fallbackTitle: String
    func metadata(at url: URL) async throws -> MediaMetadata {
        let details = try await reader.metadata(at: url)
        let title = details.title == url.deletingPathExtension().lastPathComponent ? fallbackTitle : details.title
        return try MediaMetadata(title: title, artist: details.artist, album: details.album, duration: details.duration)
    }
}
