import Foundation

/// All clients for one document must share a store instance. An update executes
/// its transform atomically with respect to other calls on that instance. A throw
/// must preserve the previous document. nil deletes the document.
public protocol DocumentStore: Sendable {
    func read() async throws -> Data?
    @discardableResult
    func update(_ transform: @Sendable (Data?) throws -> Data?) async throws -> Data?
}

public struct PositionBookmark: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let mediaID: MediaID
    public let provider: String
    public let title: String
    public let position: Double
    public let updatedAt: Date

    public init(id: UUID, mediaID: MediaID, provider: String, title: String, position: Double, updatedAt: Date) throws {
        guard position.isFinite, position >= 0, updatedAt.timeIntervalSince1970.isFinite,
              !provider.isEmpty else { throw CadenzaError.invalidBookmark }
        self.id = id
        self.mediaID = mediaID
        self.provider = provider
        self.title = title
        self.position = position
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, mediaID, provider, title, position, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      mediaID: container.decode(MediaID.self, forKey: .mediaID),
                      provider: container.decode(String.self, forKey: .provider),
                      title: container.decode(String.self, forKey: .title),
                      position: container.decode(Double.self, forKey: .position),
                      updatedAt: container.decode(Date.self, forKey: .updatedAt))
    }
}
