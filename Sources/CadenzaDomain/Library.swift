import Foundation

public struct FileFingerprint: Equatable, Sendable, Codable {
    public let byteCount: Int
    public let modifiedAt: Date

    public init(byteCount: Int, modifiedAt: Date) throws {
        guard byteCount >= 0, modifiedAt.timeIntervalSince1970.isFinite else { throw CadenzaError.invalidLibraryItem }
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey { case byteCount, modifiedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(byteCount: c.decode(Int.self, forKey: .byteCount), modifiedAt: c.decode(Date.self, forKey: .modifiedAt))
    }
}

public struct LibraryFile: Equatable, Sendable {
    public let id: MediaID
    public let url: URL
    public let fingerprint: FileFingerprint

    public init(id: MediaID, url: URL, fingerprint: FileFingerprint) {
        self.id = id
        self.url = url
        self.fingerprint = fingerprint
    }
}

public struct MediaMetadata: Equatable, Sendable, Codable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: Double

    public init(title: String, artist: String? = nil, album: String? = nil, duration: Double) throws {
        guard duration.isFinite, duration > 0 else { throw CadenzaError.invalidDuration }
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case title, artist, album, duration }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(title: c.decode(String.self, forKey: .title), artist: c.decodeIfPresent(String.self, forKey: .artist),
                      album: c.decodeIfPresent(String.self, forKey: .album), duration: c.decode(Double.self, forKey: .duration))
    }
}

public enum LibraryAvailability: String, Codable, Sendable {
    case available, missing, unreadable
}

public struct LibraryItem: Identifiable, Equatable, Sendable, Codable {
    public let id: MediaID
    public let url: URL
    public let fingerprint: FileFingerprint
    public let metadata: MediaMetadata?
    public let availability: LibraryAvailability

    public init(id: MediaID, url: URL, fingerprint: FileFingerprint, metadata: MediaMetadata?, availability: LibraryAvailability) throws {
        guard url.isFileURL, availability != .available || metadata != nil else { throw CadenzaError.invalidLibraryItem }
        self.id = id
        self.url = url
        self.fingerprint = fingerprint
        self.metadata = metadata
        self.availability = availability
    }

    private enum CodingKeys: String, CodingKey { case id, url, fingerprint, metadata, availability }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(MediaID.self, forKey: .id), url: c.decode(URL.self, forKey: .url),
                      fingerprint: c.decode(FileFingerprint.self, forKey: .fingerprint), metadata: c.decodeIfPresent(MediaMetadata.self, forKey: .metadata),
                      availability: c.decode(LibraryAvailability.self, forKey: .availability))
    }
}

public protocol FileCatalog: Sendable {
    func files(at root: URL, namespace: MediaID) async throws -> [LibraryFile]
}

public protocol MetadataReader: Sendable {
    func metadata(at url: URL) async throws -> MediaMetadata
}

public struct LibraryScanFailure: Equatable, Sendable {
    public let id: MediaID
    public let error: CadenzaError
    public init(id: MediaID, error: CadenzaError) { self.id = id; self.error = error }
}

public struct LibraryScanReport: Equatable, Sendable {
    public let scanned: Int
    public let updated: Int
    public let reused: Int
    public let missing: Int
    public let failures: [LibraryScanFailure]
    public init(scanned: Int, updated: Int, reused: Int, missing: Int, failures: [LibraryScanFailure]) {
        self.scanned = scanned
        self.updated = updated
        self.reused = reused
        self.missing = missing
        self.failures = failures
    }
}
