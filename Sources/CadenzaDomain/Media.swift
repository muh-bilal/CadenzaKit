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
}

/// Implementations must cooperate with task cancellation and support concurrent calls.
public protocol SourceProvider: Sendable {
    var identifier: String { get }
    func resolve(_ id: MediaID) async throws -> MediaResource
}
