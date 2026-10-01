import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

@MainActor
struct PersistenceIntegrationTests {
    @Test func fileStoreRoundTripsDeletesAndPreservesOnTransformFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/bookmarks.json")
        let store = try AtomicFileStore(fileURL: url)
        #expect(try await store.read() == nil)
        try await store.update { $0 }
        let service = try BookmarkTests().service(store: store)
        let saved = try await service.save(id: UUID(), mediaID: MediaID("track"), provider: "local", title: "Verse", position: 3)
        let reopened = try AtomicFileStore(fileURL: url)
        let second = try BookmarkTests().service(store: reopened)
        #expect(try await second.bookmark(saved.id) == saved)
        let original = try Data(contentsOf: url)
        await #expect(throws: CadenzaError.invalidBookmark) { try await store.update { _ in throw CadenzaError.invalidBookmark } }
        #expect(try Data(contentsOf: url) == original)
        try await store.update { $0 }
        try await store.update { _ in nil }
        #expect(try await store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileStoreRejectsInvalidLocationsAndIOFailures() async throws {
        #expect(throws: CadenzaError.unsupportedURL) { try AtomicFileStore(fileURL: #require(URL(string: "https://example.invalid/state"))) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryStore = try AtomicFileStore(fileURL: root)
        await #expect(throws: (any Error).self) { try await directoryStore.read() }
        // A real write failure after a successful missing-document read.
        let parent = root.appendingPathComponent("parent")
        let invalidParent = try AtomicFileStore(fileURL: parent.appendingPathComponent("state"))
        await #expect(throws: (any Error).self) {
            try await invalidParent.update { _ in
                try Data([9]).write(to: parent)
                return Data([1])
            }
        }
    }

    @Test func fileStoreCancellationBeforeCommitPreservesPreviousBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AtomicFileStore(fileURL: url)
        try await store.update { _ in Data([1]) }
        let cancelled = Task {
            try await store.update { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data([2])
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.read() == Data([1]))
    }

    @Test func preferencesAreBoundedPersistentAndRejectWrongTypes() async throws {
        let suite = "CadenzaTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try PreferencesDocumentStore(suiteName: suite, key: "bookmarks")
        #expect(try await store.read() == nil)
        let service = try BookmarkTests().service(store: store)
        let saved = try await service.save(id: UUID(), mediaID: MediaID("track"), provider: "local", title: "Verse", position: 3)
        let reopened = try PreferencesDocumentStore(suiteName: suite, key: "bookmarks")
        #expect(try await BookmarkTests().service(store: reopened).bookmark(saved.id) == saved)
        try await store.update { _ in nil }
        #expect(try await store.read() == nil)
        defaults.set("wrong type", forKey: "bookmarks")
        await #expect(throws: CadenzaError.corruptStore) { try await store.read() }
        defaults.removeObject(forKey: "bookmarks")
        let bounded = try PreferencesDocumentStore(suiteName: suite, key: "small", maximumBytes: 128)
        try await bounded.update { _ in Data([1]) }
        await #expect(throws: CadenzaError.storageLimitExceeded) { try await bounded.update { _ in Data(repeating: 1, count: 1024) } }
        #expect(try await bounded.read() == Data([1]))
        let cancelled = Task {
            try await bounded.update { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data([2])
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await bounded.read() == Data([1]))
        #expect(throws: CadenzaError.invalidStorageConfiguration) { try PreferencesDocumentStore(suiteName: "", key: "k") }
        #expect(throws: CadenzaError.invalidStorageConfiguration) { try PreferencesDocumentStore(suiteName: suite, key: "", maximumBytes: 0) }
    }
}
