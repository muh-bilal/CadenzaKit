import Foundation
import CadenzaDomain

/// Rules are durable; result snapshots always use the current library index.
public struct SmartPlaylistService: Sendable {
    private let flags: FeatureFlags
    private let store: any DocumentStore
    private let library: LibraryService

    init(flags: FeatureFlags, store: any DocumentStore, library: LibraryService) {
        self.flags = flags
        self.store = store
        self.library = library
    }

    public func all() async throws -> [SmartPlaylist] {
        try authorize()
        let data = try await store.read()
        try Task.checkCancellation()
        return try Self.decode(data).playlists.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Explicit upsert. Use the same ID to edit a saved definition atomically.
    public func save(_ playlist: SmartPlaylist) async throws {
        try authorize()
        try await store.update { data in
            var archive = try Self.decode(data)
            archive.playlists.removeAll { $0.id == playlist.id }
            archive.playlists.append(playlist)
            return try JSONEncoder().encode(archive)
        }
    }

    public func delete(_ id: UUID) async throws {
        try authorize()
        try await store.update { data in
            var archive = try Self.decode(data)
            guard archive.playlists.contains(where: { $0.id == id }) else { throw CadenzaError.playlistNotFound }
            archive.playlists.removeAll { $0.id == id }
            return try JSONEncoder().encode(archive)
        }
    }

    public func evaluate(_ id: UUID) async throws -> [LibraryItem] {
        guard let definition = try await all().first(where: { $0.id == id }) else { throw CadenzaError.playlistNotFound }
        let items = try await library.all()
        var result: [LibraryItem] = []
        for item in items {
            try Task.checkCancellation()
            guard item.availability == .available, let metadata = item.metadata else { continue }
            let matches = definition.predicates.map { Self.matches($0, metadata) }
            if definition.match == .all ? matches.allSatisfy({ $0 }) : matches.contains(true) { result.append(item) }
        }
        result.sort { left, right in
            let a = left.metadata!, b = right.metadata!
            let order: ComparisonResult
            if definition.sort == .duration {
                order = a.duration == b.duration ? .orderedSame : (a.duration < b.duration ? .orderedAscending : .orderedDescending)
            } else {
                let field: MetadataField = definition.sort == .artist ? .artist : (definition.sort == .album ? .album : .title)
                order = Self.fold(Self.text(a, field)).compare(Self.fold(Self.text(b, field)))
            }
            if order == .orderedSame { return left.id.rawValue < right.id.rawValue }
            return order == (definition.descending ? .orderedDescending : .orderedAscending)
        }
        try Task.checkCancellation()
        if let limit = definition.limit { return Array(result.prefix(limit)) }
        return result
    }

    private static func matches(_ predicate: SmartPredicate, _ metadata: MediaMetadata) -> Bool {
        switch predicate {
        case let .contains(field, query): return fold(text(metadata, field)).contains(fold(query))
        case let .duration(minimum, maximum): return (minimum...maximum).contains(metadata.duration)
        }
    }

    private static func text(_ metadata: MediaMetadata, _ field: MetadataField) -> String {
        switch field {
        case .title: metadata.title
        case .artist: metadata.artist ?? ""
        case .album: metadata.album ?? ""
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func authorize() throws {
        try Task.checkCancellation()
        guard flags.smartPlaylists else { throw CadenzaError.smartPlaylistsDisabled }
        guard flags.playlists else { throw CadenzaError.playlistsDisabled }
        guard flags.persistence else { throw CadenzaError.persistenceDisabled }
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable {
        var version = 1
        var playlists: [SmartPlaylist] = []
    }

    private static func decode(_ data: Data?) throws -> Archive {
        guard let data else { return Archive() }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else { throw CadenzaError.unsupportedStoreVersion(version) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard Set(archive.playlists.map(\.id)).count == archive.playlists.count else { throw CadenzaError.corruptStore }
            return archive
        } catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.corruptStore }
    }
}
