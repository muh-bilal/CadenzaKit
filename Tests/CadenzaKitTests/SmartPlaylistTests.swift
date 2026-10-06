import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence
import CadenzaLocalSources

struct SmartMetadataReader: MetadataReader {
    func metadata(at url: URL) throws -> MediaMetadata {
        switch url.deletingPathExtension().lastPathComponent {
        case "a": try MediaMetadata(title: "Café", artist: "Z", album: "A", duration: 10)
        case "b": try MediaMetadata(title: "Beta", artist: "A", album: "Z", duration: 20)
        default: try MediaMetadata(title: "Café", duration: 10)
        }
    }
}

@MainActor
struct SmartPlaylistTests {
    func library() async throws -> (LibraryService, LibraryTestCatalog) {
        let catalog = LibraryTestCatalog(try ["c", "b", "a"].map { try LibraryTests().file($0) })
        let library = try LibraryTests().service(store: BookmarkTestStore(), catalog: catalog, reader: SmartMetadataReader())
        _ = try await library.scan()
        return (library, catalog)
    }

    @Test func predicatesSortingLimitsAndFreshIndexSnapshots() async throws {
        let (library, catalog) = try await library()
        let service = try PlaybackTests().kit().makeSmartPlaylists(store: BookmarkTestStore(), library: library)
        let id = UUID()
        func results(_ predicates: [SmartPredicate], match: SmartMatch = .all, sort: SmartSort = .title, descending: Bool = false, limit: Int? = nil) async throws -> [String] {
            try await service.save(SmartPlaylist(id: id, name: "Rules", predicates: predicates, match: match, sort: sort, descending: descending, limit: limit))
            return try await service.evaluate(id).map(\.id.rawValue)
        }
        #expect(try await results([.contains(.title, "CAFE")]) == ["a", "c"])
        #expect(try await results([.contains(.artist, "z"), .contains(.album, "a")]) == ["a"])
        #expect(try await results([.contains(.artist, "z"), .duration(minimum: 20, maximum: 20)], match: .any) == ["b", "a"])
        #expect(try await results([.duration(minimum: 0, maximum: 30)], sort: .artist) == ["c", "b", "a"])
        #expect(try await results([.duration(minimum: 0, maximum: 30)], sort: .album, descending: true) == ["b", "a", "c"])
        #expect(try await results([.duration(minimum: 0, maximum: 30)], sort: .duration) == ["a", "c", "b"])
        #expect(try await results([.duration(minimum: 0, maximum: 30)], sort: .duration, descending: true, limit: 2) == ["b", "a"])
        await catalog.set([try LibraryTests().file("c")])
        _ = try await library.scan()
        #expect(try await service.evaluate(id).map(\.id.rawValue) == ["c"])
        try await service.delete(id)
        #expect(try await service.all().isEmpty)
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.evaluate(id) }
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.delete(id) }
    }

    @Test func realStorageRecreationAndConcurrentEdits() async throws {
        let (library, _) = try await library()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let kit = try PlaybackTests().kit()
        let store = try AtomicFileStore(fileURL: url)
        let service = kit.makeSmartPlaylists(store: store, library: library)
        #expect(try await service.all().isEmpty)
        let first = try SmartPlaylist(id: UUID(), name: " First ", predicates: [.contains(.title, "cafe")])
        let second = try SmartPlaylist(id: UUID(), name: "Second", predicates: [.duration(minimum: 1, maximum: 25)])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for rule in [first, second] { group.addTask { try await service.save(rule) } }
            try await group.waitForAll()
        }
        let recreated = kit.makeSmartPlaylists(store: try AtomicFileStore(fileURL: url), library: library)
        #expect(try await recreated.all().count == 2)
        #expect(try await recreated.evaluate(first.id).count == 2)
        #expect(try await recreated.evaluate(second.id).count == 3)
        try await recreated.delete(first.id)
        #expect(try await recreated.all() == [second])
    }

    @Test func invalidRulesAndDecodedDefinitionsAreRejected() throws {
        let id = UUID()
        for predicates: [SmartPredicate] in [[], [.contains(.title, " ")], [.contains(.title, String(repeating: "x", count: 1025))], [.duration(minimum: -1, maximum: 3)], [.duration(minimum: 2, maximum: 1)], [.duration(minimum: 0, maximum: .infinity)], Array(repeating: .contains(.title, "a"), count: 33)] {
            #expect(throws: CadenzaError.invalidSmartPlaylist) { try SmartPlaylist(id: id, name: "Valid", predicates: predicates) }
        }
        #expect(throws: CadenzaError.invalidSmartPlaylist) { try SmartPlaylist(id: id, name: " ", predicates: [.contains(.title, "a")]) }
        #expect(throws: CadenzaError.invalidSmartPlaylist) { try SmartPlaylist(id: id, name: "A", predicates: [.contains(.title, "a")], limit: 0) }
        let valid = try SmartPlaylist(id: id, name: "A", predicates: [.duration(minimum: 1, maximum: 2)])
        let data = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(SmartPlaylist.self, from: data) == valid)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["limit"] = -1
        #expect(throws: CadenzaError.invalidSmartPlaylist) { try JSONDecoder().decode(SmartPlaylist.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func disabledCancellationCorruptSchemasAndWriteFailurePreserveData() async throws {
        let (library, _) = try await library()
        let rule = try SmartPlaylist(id: UUID(), name: "A", predicates: [.contains(.title, "cafe")])
        for (flags, error) in [(FeatureFlags(smartPlaylists: false), CadenzaError.smartPlaylistsDisabled), (.init(playlists: false), .playlistsDisabled), (.init(persistence: false), .persistenceDisabled)] {
            let store = BookmarkTestStore()
            let service = try PlaybackTests().kit(flags: flags).makeSmartPlaylists(store: store, library: library)
            await #expect(throws: error) { try await service.all() }
            await #expect(throws: error) { try await service.save(rule) }
            await #expect(throws: error) { try await service.delete(rule.id) }
            #expect(await store.calls == 0)
        }
        let store = BookmarkTestStore()
        let service = try PlaybackTests().kit().makeSmartPlaylists(store: store, library: library)
        try await service.save(rule)
        let original = try await store.read()
        let cancelled = Task { try Task.checkCancellation(); try await service.delete(rule.id) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.read() == original)
        await store.setFailure(.storageFailure("write"))
        await #expect(throws: CadenzaError.storageFailure("write")) { try await service.save(rule) }
        await store.setFailure(nil)
        #expect(try await store.read() == original)
        for (data, error) in [(Data("oops".utf8), CadenzaError.corruptStore), (Data(#"{"version":9,"playlists":[]}"#.utf8), .unsupportedStoreVersion(9))] {
            try await store.update { _ in data }
            await #expect(throws: error) { try await service.save(rule) }
            #expect(try await store.read() == data)
        }
        let encodedRule = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))
        let duplicate = try JSONSerialization.data(withJSONObject: ["version": 1, "playlists": [encodedRule, encodedRule]])
        try await store.update { _ in duplicate }
        await #expect(throws: CadenzaError.corruptStore) { try await service.all() }
    }
}
