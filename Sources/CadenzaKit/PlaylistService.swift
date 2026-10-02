import Foundation
import CadenzaDomain

/// Durable playlist identities and names. Use a document separate from bookmarks.
public struct PlaylistService: Sendable {
    private let flags: FeatureFlags
    private let store: any DocumentStore
    private let now: @Sendable () -> Date

    init(flags: FeatureFlags, store: any DocumentStore, now: @escaping @Sendable () -> Date) {
        self.flags = flags
        self.store = store
        self.now = now
    }

    public func all() async throws -> [Playlist] {
        try authorize()
        let data = try await store.read()
        try Task.checkCancellation()
        return try Self.decode(data).playlists.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
    }

    public func playlist(_ id: UUID) async throws -> Playlist {
        guard let playlist = try await all().first(where: { $0.id == id }) else { throw CadenzaError.playlistNotFound }
        return playlist
    }

    @discardableResult
    public func create(id: UUID, name: String) async throws -> Playlist {
        try authorize()
        let playlist = try Playlist(id: id, name: name, updatedAt: now())
        try await store.update { data in
            var archive = try Self.decode(data)
            guard !archive.playlists.contains(where: { $0.id == id }) else { throw CadenzaError.duplicatePlaylist }
            archive.playlists.append(playlist)
            return try Self.encode(archive)
        }
        return playlist
    }

    public func rename(_ id: UUID, to name: String) async throws {
        try authorize()
        let renamed = try Playlist(id: id, name: name, updatedAt: now())
        try await store.update { data in
            var archive = try Self.decode(data)
            guard let index = archive.playlists.firstIndex(where: { $0.id == id }) else { throw CadenzaError.playlistNotFound }
            archive.playlists[index] = renamed
            return try Self.encode(archive)
        }
    }

    public func delete(_ id: UUID) async throws {
        try authorize()
        try await store.update { data in
            var archive = try Self.decode(data)
            guard archive.playlists.contains(where: { $0.id == id }) else { throw CadenzaError.playlistNotFound }
            archive.playlists.removeAll { $0.id == id }
            return try Self.encode(archive)
        }
    }

    private func authorize() throws {
        try Task.checkCancellation()
        guard flags.playlists else { throw CadenzaError.playlistsDisabled }
        guard flags.persistence else { throw CadenzaError.persistenceDisabled }
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable {
        var version = 1
        var playlists: [Playlist] = []
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

    private static func encode(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }
}
