import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

@MainActor
struct PlaylistInterchangeTests {
    func source() async throws -> (PlaylistService, Playlist, Data) {
        let service = try PlaylistTests().service(store: BookmarkTestStore())
        let playlist = try await service.create(id: UUID(), name: "Export")
        try await service.insert(QueueTests().entry(1), into: playlist.id, at: 0)
        try await service.insert(QueueTests().entry(2), into: playlist.id, at: 1)
        return (service, try await service.playlist(playlist.id), try await service.exportPlaylist(playlist.id))
    }

    @Test func roundTripPreservesOrderDuplicatesMetadataAndExplicitNewIdentity() async throws {
        let (source, original, data) = try await source()
        let target = try PlaylistTests().service(store: BookmarkTestStore())
        #expect(try await target.importPlaylist(data) == original)
        #expect(try await target.exportPlaylist(original.id) == data)
        await #expect(throws: CadenzaError.duplicatePlaylist) { try await source.importPlaylist(data) }
        let newID = UUID()
        let copied = try await source.importPlaylist(data, as: newID)
        #expect(copied.id == newID)
        #expect(copied.entries == original.entries)
        #expect(copied.updatedAt == original.updatedAt)
        #expect(try await source.all().count == 2)
    }

    @Test func malformedUnsupportedAndOversizedInputsDoNotWrite() async throws {
        let store = BookmarkTestStore()
        let service = try PlaylistTests().service(store: store)
        for (json, error) in [
            ("bad", CadenzaError.invalidPlaylistArchive),
            ("{\"format\":\"other\",\"version\":1}", .invalidPlaylistArchive),
            ("{\"format\":\"CadenzaKit.Playlist\",\"version\":9}", .unsupportedPlaylistFormatVersion(9)),
            ("{\"format\":\"CadenzaKit.Playlist\",\"version\":1,\"playlist\":null}", .invalidPlaylistArchive)
        ] {
            await #expect(throws: error) { try await service.importPlaylist(Data(json.utf8)) }
        }
        await #expect(throws: CadenzaError.playlistArchiveTooLarge) {
            try await service.importPlaylist(Data(repeating: 32, count: PlaylistService.maximumInterchangeBytes + 1))
        }
        #expect(await store.calls == 0)
        let huge = try await service.create(id: UUID(), name: String(repeating: "x", count: PlaylistService.maximumInterchangeBytes))
        await #expect(throws: CadenzaError.playlistArchiveTooLarge) { try await service.exportPlaylist(huge.id) }
    }

    @Test func unknownProvidersFailButOpaqueMediaIDsRemainUnresolved() async throws {
        let service = try PlaylistTests().service(store: BookmarkTestStore())
        let playlist = try await service.create(id: UUID(), name: "Provider")
        let foreign = QueueEntry(id: UUID(), mediaID: try MediaID("opaque"), provider: "unregistered")
        try await service.insert(foreign, into: playlist.id, at: 0)
        let payload = try await service.exportPlaylist(playlist.id)
        let store = BookmarkTestStore()
        let target = try PlaylistTests().service(store: store)
        await #expect(throws: CadenzaError.providerNotFound("unregistered")) { try await target.importPlaylist(payload) }
        #expect(await store.calls == 0)
        try await service.removeEntry(foreign.id, from: playlist.id)
        let local = QueueEntry(id: UUID(), mediaID: try MediaID("not-resolved-until-playback"), provider: "local")
        try await service.insert(local, into: playlist.id, at: 0)
        let imported = try await target.importPlaylist(service.exportPlaylist(playlist.id))
        #expect(imported.entries == [local])
    }

    @Test func disabledCancelledAndFailedImportsPreserveTarget() async throws {
        let (_, playlist, bytes) = try await source()
        let store = BookmarkTestStore()
        let disabled = try PlaylistTests().service(store: store, flags: .init(playlistInterchange: false))
        await #expect(throws: CadenzaError.playlistInterchangeDisabled) { try await disabled.importPlaylist(bytes) }
        await #expect(throws: CadenzaError.playlistInterchangeDisabled) { try await disabled.exportPlaylist(playlist.id) }
        #expect(await store.calls == 0)
        let target = try PlaylistTests().service(store: store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await target.importPlaylist(bytes)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.calls == 0)
        let existing = try await target.create(id: UUID(), name: "Keep")
        let before = await store.data
        await store.setFailure(.storageFailure("full"))
        await #expect(throws: CadenzaError.storageFailure("full")) { try await target.importPlaylist(bytes) }
        #expect(await store.data == before)
        await store.setFailure(nil)
        #expect(try await target.all() == [existing])
    }

    @Test func importsCommitToRealStorageAndRejectDuplicateEntries() async throws {
        let (_, original, data) = try await source()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = try PlaylistTests().service(store: AtomicFileStore(fileURL: url))
        try await target.importPlaylist(data)
        let reopened = try PlaylistTests().service(store: AtomicFileStore(fileURL: url))
        #expect(try await reopened.playlist(original.id) == original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var playlist = try #require(json["playlist"] as? [String: Any])
        let entries = try #require(playlist["entries"] as? [[String: Any]])
        playlist["entries"] = [entries[0], entries[0]]
        json["playlist"] = playlist
        let invalid = try JSONSerialization.data(withJSONObject: json)
        let before = try Data(contentsOf: url)
        await #expect(throws: CadenzaError.duplicatePlaylistEntry) { try await target.importPlaylist(invalid, as: UUID()) }
        #expect(try Data(contentsOf: url) == before)
    }
}
