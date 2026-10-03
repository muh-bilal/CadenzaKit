import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

@MainActor
struct PlaylistEntryTests {
    @Test func occurrenceEditingPreservesDuplicatesAndRenamePreservesEntries() async throws {
        let store = BookmarkTestStore()
        let service = try PlaylistTests().service(store: store)
        let playlist = try await service.create(id: UUID(), name: "Duplicates")
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2), c = try QueueTests().entry(3)
        try await service.insert(a, into: playlist.id, at: 0)
        try await service.insert(b, into: playlist.id, at: 1)
        try await service.insert(c, into: playlist.id, at: 1)
        #expect(try await service.playlist(playlist.id).entries == [a, c, b])
        try await service.moveEntry(b.id, in: playlist.id, to: 0)
        try await service.rename(playlist.id, to: "Renamed")
        #expect(try await service.playlist(playlist.id).entries == [b, a, c])
        try await service.removeEntry(a.id, from: playlist.id)
        #expect(try await service.playlist(playlist.id).entries == [b, c])
        #expect(try await service.playlist(playlist.id).name == "Renamed")
    }

    @Test func invalidEditsLeavePersistedDocumentUnchanged() async throws {
        let store = BookmarkTestStore()
        let service = try PlaylistTests().service(store: store)
        let playlist = try await service.create(id: UUID(), name: "List")
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try await service.insert(a, into: playlist.id, at: 0)
        let before = await store.data
        await #expect(throws: CadenzaError.invalidPlaylistIndex) { try await service.insert(b, into: playlist.id, at: -1) }
        await #expect(throws: CadenzaError.duplicatePlaylistEntry) { try await service.insert(a, into: playlist.id, at: 1) }
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.insert(b, into: UUID(), at: 0) }
        await #expect(throws: CadenzaError.invalidPlaylistIndex) { try await service.moveEntry(a.id, in: playlist.id, to: 1) }
        await #expect(throws: CadenzaError.playlistEntryNotFound) { try await service.moveEntry(b.id, in: playlist.id, to: 0) }
        await #expect(throws: CadenzaError.playlistEntryNotFound) { try await service.removeEntry(b.id, from: playlist.id) }
        #expect(await store.data == before)
        let disabled = try PlaylistTests().service(store: store, flags: .init(playlists: false))
        await #expect(throws: CadenzaError.playlistsDisabled) { try await disabled.insert(b, into: playlist.id, at: 1) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.insert(b, into: playlist.id, at: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await store.data == before)
        await store.setFailure(.storageFailure("full"))
        await #expect(throws: CadenzaError.storageFailure("full")) { try await service.removeEntry(a.id, from: playlist.id) }
        #expect(await store.data == before)
    }

    @Test func versionOneMigratesOnMutationAndDuplicateDecodedEntriesAreRejected() async throws {
        let id = UUID()
        let json = "{\"version\":1,\"playlists\":[{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\",\"updatedAt\":0}]}"
        let bytes = Data(json.utf8)
        let store = BookmarkTestStore(data: bytes)
        let service = try PlaylistTests().service(store: store)
        #expect(try await service.playlist(id).entries.isEmpty)
        #expect(await store.data == bytes)
        let entry = try QueueTests().entry(1)
        try await service.insert(entry, into: id, at: 0)
        let updated = try #require(await store.data)
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        #expect(try await service.playlist(id).entries == [entry])
        #expect(throws: CadenzaError.duplicatePlaylistEntry) {
            try Playlist(id: id, name: "Duplicate", updatedAt: .now, entries: [entry, entry])
        }
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(try await service.playlist(id))) as? [String: Any])
        let encodedEntry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
        record["entries"] = [encodedEntry, encodedEntry]
        let malformed = try JSONSerialization.data(withJSONObject: ["version": 2, "playlists": [record]])
        let invalid = try PlaylistTests().service(store: BookmarkTestStore(data: malformed))
        await #expect(throws: CadenzaError.duplicatePlaylistEntry) { try await invalid.all() }
    }

    @Test func concurrentEntryInsertionsAreNotLost() async throws {
        let store = BookmarkTestStore()
        let service = try PlaylistTests().service(store: store)
        let playlist = try await service.create(id: UUID(), name: "Concurrent")
        let entries = try (1...20).map { try QueueTests().entry($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries { group.addTask { try await service.insert(entry, into: playlist.id, at: 0) } }
            try await group.waitForAll()
        }
        #expect(Set(try await service.playlist(playlist.id).entries.map(\.id)) == Set(entries.map(\.id)))
    }

    @Test(arguments: [false, true]) func orderAndDuplicatesSurviveRealStoreRecreation(preferences: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CadenzaEntries." + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        func store() throws -> any DocumentStore {
            if preferences { return try PreferencesDocumentStore(suiteName: suite, key: "playlists") }
            return try AtomicFileStore(fileURL: url)
        }
        let service = try PlaylistTests().service(store: store())
        let playlist = try await service.create(id: UUID(), name: "Order")
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try await service.insert(a, into: playlist.id, at: 0)
        try await service.insert(b, into: playlist.id, at: 1)
        try await service.moveEntry(b.id, in: playlist.id, to: 0)
        let reopened = try PlaylistTests().service(store: store())
        #expect(try await reopened.playlist(playlist.id).entries == [b, a])
        try await reopened.removeEntry(b.id, from: playlist.id)
        #expect(try await PlaylistTests().service(store: store()).playlist(playlist.id).entries == [a])
    }
}
