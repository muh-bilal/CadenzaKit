import Foundation
import CadenzaDomain

/// Persistent named position bookmarks. Mutations are store transactions, so
/// concurrent services sharing one store cannot lose each other's updates.
public struct BookmarkService: Sendable {
    private let flags: FeatureFlags
    private let store: any DocumentStore
    private let now: @Sendable () -> Date

    init(flags: FeatureFlags, store: any DocumentStore, now: @escaping @Sendable () -> Date) {
        self.flags = flags
        self.store = store
        self.now = now
    }

    public func all() async throws -> [PositionBookmark] {
        try authorize()
        let data = try await store.read()
        try Task.checkCancellation()
        return try Self.decode(data).bookmarks.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func bookmark(_ id: UUID) async throws -> PositionBookmark {
        guard let bookmark = try await all().first(where: { $0.id == id }) else { throw CadenzaError.bookmarkNotFound }
        return bookmark
    }

    @discardableResult
    public func save(id: UUID, mediaID: MediaID, provider: String, title: String, position: Double) async throws -> PositionBookmark {
        try authorize()
        let bookmark = try PositionBookmark(id: id, mediaID: mediaID, provider: provider, title: title, position: position, updatedAt: now())
        try await store.update { data in
            var archive = try Self.decode(data)
            archive.bookmarks.removeAll { $0.id == id }
            archive.bookmarks.append(bookmark)
            return try Self.encode(archive)
        }
        return bookmark
    }

    public func remove(_ id: UUID) async throws {
        try authorize()
        try await store.update { data in
            var archive = try Self.decode(data)
            guard archive.bookmarks.contains(where: { $0.id == id }) else { throw CadenzaError.bookmarkNotFound }
            archive.bookmarks.removeAll { $0.id == id }
            return try Self.encode(archive)
        }
    }

    @MainActor
    @discardableResult
    public func capture(id: UUID, title: String, from session: PlaybackSession) async throws -> PositionBookmark {
        try authorize()
        try await session.refresh()
        let snapshot = session.snapshot
        guard let resource = snapshot.resource, let provider = session.sourceProvider else { throw CadenzaError.noMediaLoaded }
        return try await save(id: id, mediaID: resource.id, provider: provider, title: title, position: snapshot.position)
    }

    @MainActor
    public func resume(_ id: UUID, in session: PlaybackSession, autoplay: Bool = false) async throws {
        let bookmark = try await bookmark(id)
        try await session.load(bookmark.mediaID, provider: bookmark.provider, at: bookmark.position, autoplay: autoplay)
    }

    private func authorize() throws {
        try Task.checkCancellation()
        guard flags.bookmarks else { throw CadenzaError.bookmarksDisabled }
        guard flags.persistence else { throw CadenzaError.persistenceDisabled }
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable {
        var version = 1
        var bookmarks: [PositionBookmark] = []
    }

    private static func decode(_ data: Data?) throws -> Archive {
        guard let data else { return Archive() }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else { throw CadenzaError.unsupportedStoreVersion(version) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard Set(archive.bookmarks.map(\.id)).count == archive.bookmarks.count else { throw CadenzaError.corruptStore }
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
