import Foundation

public enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case one
    case all
}

/// An occurrence, not a track identity. Duplicate tracks have different entry IDs.
public struct QueueEntry: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let mediaID: MediaID
    public let provider: String?

    public init(id: UUID, mediaID: MediaID, provider: String? = nil) {
        self.id = id
        self.mediaID = mediaID
        self.provider = provider
    }
}
