import Foundation

public struct Playlist: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let name: String
    public let updatedAt: Date

    public init(id: UUID, name: String, updatedAt: Date) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, updatedAt.timeIntervalSince1970.isFinite else { throw CadenzaError.invalidPlaylist }
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      name: container.decode(String.self, forKey: .name),
                      updatedAt: container.decode(Date.self, forKey: .updatedAt))
    }
}
