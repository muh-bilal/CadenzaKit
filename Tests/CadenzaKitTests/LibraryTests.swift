import Foundation
import Testing
import CadenzaDomain
import CadenzaKit

actor LibraryTestCatalog: FileCatalog {
    var values: [LibraryFile]
    var gate: PlaybackTests.Gate?
    init(_ values: [LibraryFile]) { self.values = values }
    func set(_ values: [LibraryFile]) { self.values = values }
    func setGate(_ gate: PlaybackTests.Gate?) { self.gate = gate }
    func files(at root: URL, namespace: MediaID) async throws -> [LibraryFile] {
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        return values
    }
}

actor LibraryTestReader: MetadataReader {
    var calls = 0
    var failure: (any Error)?
    func setFailure(_ failure: (any Error)?) { self.failure = failure }
    func metadata(at url: URL) throws -> MediaMetadata {
        calls += 1
        if let failure { throw failure }
        return try MediaMetadata(title: "Café", artist: "Artist", album: "Album", duration: 10)
    }
}

@MainActor
struct LibraryTests {
    func file(_ name: String = "track", size: Int = 1) throws -> LibraryFile {
        LibraryFile(id: try MediaID(name), url: URL(fileURLWithPath: "/library/\(name).wav"),
                    fingerprint: try FileFingerprint(byteCount: size, modifiedAt: Date(timeIntervalSince1970: 1)))
    }

    func service(store: any DocumentStore, catalog: any FileCatalog, reader: any MetadataReader, flags: FeatureFlags = .init(), namespace: String = "test") throws -> LibraryService {
        try PlaybackTests().kit(flags: flags).makeLibrary(root: URL(fileURLWithPath: "/library"), namespace: MediaID(namespace), store: store, catalog: catalog, metadata: reader)
    }

    @Test func incrementalScanSearchMissingAndReturningFiles() async throws {
        let store = BookmarkTestStore()
        let catalog = LibraryTestCatalog([try file()])
        let reader = LibraryTestReader()
        let library = try service(store: store, catalog: catalog, reader: reader)
        #expect(try await library.all().isEmpty)
        let first = try await library.scan()
        #expect(first == LibraryScanReport(scanned: 1, updated: 1, reused: 0, missing: 0, failures: []))
        #expect(try await library.search("cafe").count == 1)
        #expect(try await library.search("ARTIST").count == 1)
        #expect(try await library.search("album").count == 1)
        #expect(try await library.search("unmatched").isEmpty)
        #expect(try await library.resource(MediaID("track")).title == "Café")
        #expect(try await library.scan().reused == 1)
        #expect(await reader.calls == 1)
        await catalog.set([try file(size: 2)])
        #expect(try await library.scan().updated == 1)
        await catalog.set([])
        #expect(try await library.scan().missing == 1)
        #expect(try await library.all().first?.availability == .missing)
        #expect(try await library.search("cafe").isEmpty)
        #expect(try await library.search("cafe", includeUnavailable: true).count == 1)
        let id = try MediaID("track")
        await #expect(throws: CadenzaError.resourceNotFound(id)) { try await library.resource(id) }
        await catalog.set([try file(size: 2)])
        #expect(try await library.scan().reused == 1)
        #expect(try await library.all().first?.availability == .available)
    }

    @Test func metadataFailuresAreExplicitAndRecoverable() async throws {
        struct Failure: Error, CustomStringConvertible { var description: String { "metadata" } }
        let catalog = LibraryTestCatalog([try file()])
        let reader = LibraryTestReader()
        await reader.setFailure(Failure())
        let library = try service(store: BookmarkTestStore(), catalog: catalog, reader: reader)
        let report = try await library.scan()
        #expect(report.failures == [LibraryScanFailure(id: try MediaID("track"), error: .libraryFailure("metadata"))])
        #expect(try await library.all().first?.availability == .unreadable)
        await #expect(throws: CadenzaError.unreadableFile) { try await library.resource(MediaID("track")) }
        #expect(try await library.search("", includeUnavailable: true).count == 1)
        await reader.setFailure(nil)
        #expect(try await library.scan().updated == 1)
        await catalog.set([try file(size: 3)])
        await reader.setFailure(CadenzaError.unsupportedMedia)
        #expect(try await library.scan().failures.first?.error == .unsupportedMedia)
        #expect(try await library.all().first?.metadata?.title == "Café")
    }

    @Test func cancellationBusyAndCommitConflictsPreservePreviousIndex() async throws {
        let store = BookmarkTestStore()
        let catalog = LibraryTestCatalog([try file()])
        let reader = LibraryTestReader()
        let library = try service(store: store, catalog: catalog, reader: reader)
        let gate = PlaybackTests.Gate()
        await catalog.setGate(gate)
        let task = Task { try await library.scan() }
        await gate.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await library.scan() }
        #expect(try await library.all().isEmpty)
        task.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.data == nil)
        let conflictGate = PlaybackTests.Gate()
        await catalog.setGate(conflictGate)
        let conflict = Task { try await library.scan() }
        await conflictGate.waitUntilEntered()
        let changed = Data("external change".utf8)
        try await store.update { _ in changed }
        conflictGate.open()
        await #expect(throws: CadenzaError.libraryChangedDuringScan) { try await conflict.value }
        #expect(await store.data == changed)
        try await store.update { _ in nil }
        await catalog.setGate(nil)
        await reader.setFailure(CancellationError())
        await #expect(throws: CancellationError.self) { try await library.scan() }
        #expect(await store.data == nil)
        await reader.setFailure(nil)
        #expect(try await library.scan().updated == 1)
    }

    @Test func flagsNamespacesDuplicateIDsAndSchemasAreValidated() async throws {
        let store = BookmarkTestStore()
        let catalog = LibraryTestCatalog([try file()])
        let reader = LibraryTestReader()
        for (flags, error) in [(FeatureFlags(libraryIndexing: false), CadenzaError.libraryDisabled), (FeatureFlags(persistence: false), .persistenceDisabled)] {
            let library = try service(store: store, catalog: catalog, reader: reader, flags: flags)
            await #expect(throws: error) { try await library.scan() }
            await #expect(throws: error) { try await library.all() }
        }
        #expect(await store.calls == 0)
        let library = try service(store: store, catalog: catalog, reader: reader)
        await catalog.set([try file(), try file()])
        await #expect(throws: CadenzaError.invalidLibraryItem) { try await library.scan() }
        await catalog.set([try file(), try file("second")])
        _ = try await library.scan()
        let other = try service(store: store, catalog: catalog, reader: reader, namespace: "other")
        await #expect(throws: CadenzaError.libraryNamespaceMismatch) { try await other.all() }
        let valid = try #require(await store.data)
        var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        json["items"] = [items[0], items[0]]
        let duplicates = try JSONSerialization.data(withJSONObject: json)
        try await store.update { _ in duplicates }
        await #expect(throws: CadenzaError.corruptStore) { try await library.all() }
        try await store.update { _ in Data("{\"version\":9}".utf8) }
        await #expect(throws: CadenzaError.unsupportedStoreVersion(9)) { try await library.scan() }
        try await store.update { _ in Data("bad".utf8) }
        await #expect(throws: CadenzaError.corruptStore) { try await library.all() }
    }

    @Test func domainModelsRejectInvalidDecodedValues() throws {
        #expect(throws: CadenzaError.invalidLibraryItem) { try FileFingerprint(byteCount: -1, modifiedAt: .now) }
        #expect(throws: CadenzaError.invalidDuration) { try MediaMetadata(title: "Bad", duration: .nan) }
        let file = try file()
        #expect(throws: CadenzaError.invalidLibraryItem) {
            try LibraryItem(id: file.id, url: file.url, fingerprint: file.fingerprint, metadata: nil, availability: .available)
        }
        #expect(throws: CadenzaError.invalidLibraryItem) {
            try JSONDecoder().decode(FileFingerprint.self, from: Data("{\"byteCount\":-1,\"modifiedAt\":0}".utf8))
        }
    }
}
