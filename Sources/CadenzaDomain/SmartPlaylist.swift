import Foundation

public enum MetadataField: String, Codable, Sendable { case title, artist, album }
public enum SmartMatch: String, Codable, Sendable { case all, any }
public enum SmartSort: String, Codable, Sendable { case title, artist, album, duration }

public enum SmartPredicate: Equatable, Sendable, Codable {
    case contains(MetadataField, String)
    case duration(minimum: Double, maximum: Double)

    public func validate() throws {
        switch self {
        case let .contains(_, text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1024 else { throw CadenzaError.invalidSmartPlaylist }
        case let .duration(minimum, maximum):
            guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum >= minimum else { throw CadenzaError.invalidSmartPlaylist }
        }
    }
}

public struct SmartPlaylist: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let name: String
    public let predicates: [SmartPredicate]
    public let match: SmartMatch
    public let sort: SmartSort
    public let descending: Bool
    public let limit: Int?

    public init(id: UUID, name: String, predicates: [SmartPredicate], match: SmartMatch = .all,
                sort: SmartSort = .title, descending: Bool = false, limit: Int? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (1...32).contains(predicates.count), limit == nil || limit! > 0 else { throw CadenzaError.invalidSmartPlaylist }
        for predicate in predicates { try predicate.validate() }
        self.id = id
        self.name = name
        self.predicates = predicates
        self.match = match
        self.sort = sort
        self.descending = descending
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case id, name, predicates, match, sort, descending, limit }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                      predicates: c.decode([SmartPredicate].self, forKey: .predicates), match: c.decode(SmartMatch.self, forKey: .match),
                      sort: c.decode(SmartSort.self, forKey: .sort), descending: c.decode(Bool.self, forKey: .descending), limit: c.decodeIfPresent(Int.self, forKey: .limit))
    }
}
