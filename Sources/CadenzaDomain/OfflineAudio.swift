import Foundation

public struct OfflineAudio: Identifiable, Equatable, Sendable, Codable {
    public let id: MediaID
    public let sourceMediaID: MediaID
    public let sourceProvider: String
    public let metadata: MediaMetadata
    public let byteCount: Int
    public let fileExtension: String
    public let createdAt: Date
    public static let supportedExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "caf", "flac"]

    public init(id: MediaID, sourceMediaID: MediaID, sourceProvider: String, metadata: MediaMetadata, byteCount: Int, fileExtension: String, createdAt: Date) throws {
        guard !sourceProvider.isEmpty, byteCount > 0, Self.supportedExtensions.contains(fileExtension), createdAt.timeIntervalSince1970.isFinite else { throw CadenzaError.invalidDownload }
        self.id = id
        self.sourceMediaID = sourceMediaID
        self.sourceProvider = sourceProvider
        self.metadata = metadata
        self.byteCount = byteCount
        self.fileExtension = fileExtension
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, sourceMediaID, sourceProvider, metadata, byteCount, fileExtension, createdAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(MediaID.self, forKey: .id), sourceMediaID: c.decode(MediaID.self, forKey: .sourceMediaID),
                      sourceProvider: c.decode(String.self, forKey: .sourceProvider), metadata: c.decode(MediaMetadata.self, forKey: .metadata),
                      byteCount: c.decode(Int.self, forKey: .byteCount), fileExtension: c.decode(String.self, forKey: .fileExtension), createdAt: c.decode(Date.self, forKey: .createdAt))
    }
}

public protocol AudioTransfer: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
}

public protocol OfflineAudioStore: Sendable {
    func all() async throws -> [OfflineAudio]
    func resource(_ id: MediaID) async throws -> MediaResource
    func save(_ data: Data, id: MediaID, source: MediaResource, provider: String, createdAt: Date, metadata: any MetadataReader) async throws -> OfflineAudio
}
