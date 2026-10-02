import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

@MainActor
struct PlaylistTests {
    func service(store: any DocumentStore, flags: FeatureFlags = .init()) throws -> PlaylistService {
        try PlaybackTests().kit(flags: flags).makePlaylists(store: store, now: { Date(timeIntervalSince1970: 123) })
    }

    @Test func createsRenamesDeletesAndAllowsDuplicateNames() async throws {
        let store = BookmarkTestStore()
        let service = try service(store: store)
        #expect(try await service.all().isEmpty)
        let a = UUID(), b = UUID(), c = UUID()
        let created = try await service.create(id: a, name: "  Favorites \n")
        #expect(created.name == "Favorites")
        #expect(created.updatedAt == Date(timeIntervalSince1970: 123))
        try await service.create(id: b, name: "Favorites")
        try await service.create(id: c, name: "Albums")
        let playlists = try await service.all()
        #expect(playlists.map(\.name) == ["Albums", "Favorites", "Favorites"])
        #expect(playlists.dropFirst().map(\.id) == [a, b].sorted { $0.uuidString < $1.uuidString })
        try await service.rename(a, to: "New name")
        #expect(try await service.playlist(a).name == "New name")
        try await service.delete(b)
        #expect(try await service.all().count == 2)
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.playlist(b) }
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.rename(b, to: "Gone") }
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.delete(b) }
        await #expect(throws: CadenzaError.duplicatePlaylist) { try await service.create(id: a, name: "Duplicate ID") }
        await #expect(throws: CadenzaError.invalidPlaylist) { try await service.create(id: UUID(), name: " \n") }
        #expect(try await service.playlist(a).name == "New name")
    }

    @Test func corruptAndFutureSchemasAreNotOverwritten() async throws {
        for (json, error) in [("bad", CadenzaError.corruptStore), ("{\"version\":9}", .unsupportedStoreVersion(9)), ("{\"version\":1,\"playlists\":false}", .corruptStore)] {
            let bytes = Data(json.utf8)
            let store = BookmarkTestStore(data: bytes)
            let service = try service(store: store)
            await #expect(throws: error) { try await service.all() }
            await #expect(throws: error) { try await service.create(id: UUID(), name: "New") }
            #expect(await store.data == bytes)
        }
        let playlist = try Playlist(id: UUID(), name: "Duplicate", updatedAt: .now)
        var bytes = Data("{\"version\":1,\"playlists\":".utf8)
        bytes.append(try JSONEncoder().encode([playlist, playlist]))
        bytes.append(Data("}".utf8))
        let service = try service(store: BookmarkTestStore(data: bytes))
        await #expect(throws: CadenzaError.corruptStore) { try await service.all() }
    }

    @Test func flagsCancellationAndIOFailurePreserveState() async throws {
        let store = BookmarkTestStore()
        for (flags, error) in [(FeatureFlags(playlists: false), CadenzaError.playlistsDisabled), (FeatureFlags(persistence: false), .persistenceDisabled)] {
            let service = try service(store: store, flags: flags)
            await #expect(throws: error) { try await service.all() }
            await #expect(throws: error) { try await service.create(id: UUID(), name: "New") }
            await #expect(throws: error) { try await service.rename(UUID(), to: "New") }
            await #expect(throws: error) { try await service.delete(UUID()) }
        }
        #expect(await store.calls == 0)
        let service = try service(store: store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.create(id: UUID(), name: "New")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.calls == 0)
        let created = try await service.create(id: UUID(), name: "Existing")
        let original = await store.data
        await store.setFailure(.storageFailure("disk"))
        await #expect(throws: CadenzaError.storageFailure("disk")) { try await service.rename(created.id, to: "Lost") }
        #expect(await store.data == original)
    }

    @Test func concurrentCreatesDoNotLosePlaylists() async throws {
        let store = BookmarkTestStore()
        let services = try [service(store: store), service(store: store)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let service = services[index % 2]
                group.addTask { _ = try await service.create(id: UUID(), name: "List \(index)") }
            }
            try await group.waitForAll()
        }
        #expect(try await services[0].all().count == 20)
    }

    @Test(arguments: [false, true]) func realStoresSurviveRecreation(preferences: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CadenzaPlaylist." + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        func store() throws -> any DocumentStore {
            if preferences { return try PreferencesDocumentStore(suiteName: suite, key: "playlists") }
            return try AtomicFileStore(fileURL: url)
        }
        let first = try PlaybackTests().kit().makePlaylists(store: store())
        let created = try await first.create(id: UUID(), name: "Persistent")
        let second = try service(store: store())
        #expect(try await second.playlist(created.id) == created)
        try await second.rename(created.id, to: "Renamed")
        let third = try service(store: store())
        #expect(try await third.playlist(created.id).name == "Renamed")
        try await third.delete(created.id)
        #expect(try await service(store: store()).all().isEmpty)
    }
}
