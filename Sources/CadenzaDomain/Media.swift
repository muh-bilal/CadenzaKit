import Foundation

/// Provider-owned stable identity. Occurrences in queues and playlists use separate IDs.
public struct MediaID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CadenzaError.invalidIdentifier
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A resolved location, not a promise that a backend can decode its contents.
public struct MediaResource: Equatable, Sendable {
    public let id: MediaID
    public let url: URL
    public let title: String

    public init(id: MediaID, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

public enum CadenzaError: Error, Equatable, Sendable {
    case invalidIdentifier
    case duplicateProvider(String)
    case providerNotFound(String)
    case resourceIdentityMismatch
    case sourceFailure(provider: String, message: String)
    case featureUnavailable(Feature, UnavailabilityReason)
    case resourceNotFound(MediaID)
    case unsupportedURL
    case unreadableFile
    case unsupportedMedia
    case playbackFailure(String)
    case invalidPosition
    case invalidDuration
    case noMediaLoaded
    case operationInProgress
    case queueDisabled
    case duplicateQueueEntry
    case queueEntryNotFound
    case invalidQueueIndex
    case emptyQueue
    case noNextEntry
    case noPreviousEntry
    case shuffleDisabled
    case repeatDisabled
    case loopingDisabled
    case invalidLoopRange
    case bookmarksDisabled
    case persistenceDisabled
    case invalidBookmark
    case bookmarkNotFound
    case corruptStore
    case unsupportedStoreVersion(Int)
    case storageFailure(String)
    case storageLimitExceeded
    case invalidStorageConfiguration
    case playlistsDisabled
    case invalidPlaylist
    case playlistNotFound
    case duplicatePlaylist
    case duplicatePlaylistEntry
    case playlistEntryNotFound
    case invalidPlaylistIndex
    case playlistInterchangeDisabled
    case playlistArchiveTooLarge
    case invalidPlaylistArchive
    case unsupportedPlaylistFormatVersion(Int)
    case libraryDisabled
    case smartPlaylistsDisabled
    case invalidSmartPlaylist
    case artworkDisabled
    case invalidArtwork
    case artworkTooLarge
    case artworkFailure(String)
    case invalidLibraryItem
    case libraryFailure(String)
    case libraryNamespaceMismatch
    case libraryChangedDuringScan
}

/// Implementations must cooperate with task cancellation and support concurrent calls.
public protocol SourceProvider: Sendable {
    var identifier: String { get }
    var supportedFeatures: Set<Feature> { get }
    func resolve(_ id: MediaID) async throws -> MediaResource
}

extension SourceProvider {
    public var supportedFeatures: Set<Feature> { [.sourceResolution] }
}
