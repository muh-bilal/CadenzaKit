import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

actor BookmarkTestStore: DocumentStore {
    var data: Data?
    var calls = 0
    var failure: CadenzaError?
    init(data: Data? = nil) { self.data = data }
    func setFailure(_ error: CadenzaError?) { failure = error }
    func read() throws -> Data? {
        calls += 1
        if let failure { throw failure }
        return data
    }
    func update(_ transform: @Sendable (Data?) throws -> Data?) throws -> Data? {
        calls += 1
        if let failure { throw failure }
        let next = try transform(data)
        try Task.checkCancellation()
        data = next
        return next
    }
}

@MainActor
struct BookmarkTests {
    func service(store: any DocumentStore, flags: FeatureFlags = .init()) throws -> BookmarkService {
        try PlaybackTests().kit(flags: flags).makeBookmarks(store: store, now: { Date(timeIntervalSince1970: 123) })
    }

    @Test func bookmarkCRUDSurvivesServiceRecreationAndUsesInjectedTime() async throws {
        let store = BookmarkTestStore()
        let bookmarks = try service(store: store)
        #expect(try await bookmarks.all().isEmpty)
        let id = UUID(), media = try MediaID("track")
        let saved = try await bookmarks.save(id: id, mediaID: media, provider: "local", title: "Verse", position: 3)
        #expect(saved.updatedAt == Date(timeIntervalSince1970: 123))
        #expect(try await bookmarks.bookmark(id) == saved)
        let reopened = try service(store: store)
        #expect(try await reopened.all() == [saved])
        try await reopened.save(id: id, mediaID: media, provider: "local", title: "Chorus", position: 5)
        #expect(try await bookmarks.all().count == 1)
        #expect(try await bookmarks.bookmark(id).position == 5)
        try await bookmarks.remove(id)
        #expect(try await bookmarks.all().isEmpty)
        await #expect(throws: CadenzaError.bookmarkNotFound) { try await bookmarks.bookmark(id) }
        await #expect(throws: CadenzaError.bookmarkNotFound) { try await bookmarks.remove(id) }
    }

    @Test func invalidBookmarksAndCorruptOrFutureArchivesArePreserved() async throws {
        let id = UUID(), media = try MediaID("track")
        let service = try service(store: BookmarkTestStore())
        for position in [-1, .nan, .infinity] {
            await #expect(throws: CadenzaError.invalidBookmark) {
                try await service.save(id: id, mediaID: media, provider: "local", title: "", position: position)
            }
        }
        #expect(throws: CadenzaError.invalidBookmark) {
            try PositionBookmark(id: id, mediaID: media, provider: "", title: "", position: 0, updatedAt: .now)
        }
        for (text, expected) in [("bad JSON", CadenzaError.corruptStore), ("{\"version\":2}", .unsupportedStoreVersion(2)), ("{\"version\":1,\"bookmarks\":17}", .corruptStore)] {
            let bytes = Data(text.utf8)
            let store = BookmarkTestStore(data: bytes)
            let service = try self.service(store: store)
            await #expect(throws: expected) { try await service.all() }
            await #expect(throws: expected) { try await service.save(id: id, mediaID: media, provider: "local", title: "", position: 1) }
            #expect(await store.data == bytes)
        }
        let bookmark = try PositionBookmark(id: id, mediaID: media, provider: "local", title: "", position: 0, updatedAt: .now)
        let duplicateRecords = try JSONEncoder().encode([bookmark, bookmark])
        var duplicateJSON = Data("{\"version\":1,\"bookmarks\":".utf8)
        duplicateJSON.append(duplicateRecords)
        duplicateJSON.append(Data("}".utf8))
        let duplicates = try self.service(store: BookmarkTestStore(data: duplicateJSON))
        await #expect(throws: CadenzaError.corruptStore) { try await duplicates.all() }
    }

    @Test func flagsCancellationAndStorageFailureDoNotSilentlySucceed() async throws {
        let store = BookmarkTestStore()
        let id = UUID(), media = try MediaID("track")
        for (flags, expected) in [(FeatureFlags(bookmarks: false), CadenzaError.bookmarksDisabled), (FeatureFlags(persistence: false), .persistenceDisabled)] {
            let service = try service(store: store, flags: flags)
            await #expect(throws: expected) { try await service.all() }
            await #expect(throws: expected) { try await service.save(id: id, mediaID: media, provider: "local", title: "", position: 0) }
            await #expect(throws: expected) { try await service.remove(id) }
        }
        #expect(await store.calls == 0)
        let service = try service(store: store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.save(id: id, mediaID: media, provider: "local", title: "", position: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.calls == 0)
        await store.setFailure(.storageFailure("disk"))
        await #expect(throws: CadenzaError.storageFailure("disk")) { try await service.save(id: id, mediaID: media, provider: "local", title: "", position: 0) }
        await #expect(throws: CadenzaError.storageFailure("disk")) { try await service.all() }
        #expect(await store.data == nil)
    }

    @Test func concurrentServicesShareAtomicTransactions() async throws {
        let store = BookmarkTestStore()
        let services = try [service(store: store), service(store: store)]
        let media = try MediaID("track")
        let identifiers = (0..<40).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in identifiers.enumerated() {
                let service = services[index % 2]
                group.addTask { _ = try await service.save(id: id, mediaID: media, provider: "local", title: "", position: Double(index)) }
            }
            try await group.waitForAll()
        }
        #expect(Set(try await services[0].all().map(\.id)) == Set(identifiers))
    }

    @Test func captureResumeAndStaleMediaRespectSessionAndCapabilities() async throws {
        let store = BookmarkTestStore()
        let service = try service(store: store)
        let backend = PlaybackTests.Backend()
        let kit = try PlaybackTests().kit()
        let session = kit.makeSession(backend: backend)
        #expect(session.sourceProvider == nil)
        await #expect(throws: CadenzaError.noMediaLoaded) { try await service.capture(id: UUID(), title: "", from: session) }
        try await session.load(MediaID("track"))
        backend.position = 4
        let saved = try await service.capture(id: UUID(), title: "Resume", from: session)
        #expect(saved.provider == "local")
        session.stop()
        try await service.resume(saved.id, in: session)
        #expect(session.snapshot.position == 4)
        #expect(session.snapshot.state == .ready)
        try await service.resume(saved.id, in: session, autoplay: true)
        #expect(session.snapshot.state == .playing)
        #expect(session.sourceProvider == "local")
        backend.duration = 2
        await #expect(throws: CadenzaError.invalidPosition) { try await service.resume(saved.id, in: session) }
        let denied = try PlaybackTests().kit(flags: .init(seeking: false)).makeSession(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.featureUnavailable(.seeking, .disabled)) { try await service.resume(saved.id, in: denied) }
        let defaultClock = kit.makeBookmarks(store: store)
        let clockBookmark = try await defaultClock.save(id: UUID(), mediaID: saved.mediaID, provider: "local", title: "", position: 0)
        #expect(clockBookmark.updatedAt.timeIntervalSince1970 > 123)
    }

    @Test func resumeSeekIsSerializedAndStopPreventsStaleAutoplay() async throws {
        let backend = PlaybackTests.Backend()
        let gate = PlaybackTests.Gate()
        backend.seekGate = gate
        let kit = try PlaybackTests().kit()
        let service = try service(store: BookmarkTestStore())
        let bookmark = try await service.save(id: UUID(), mediaID: MediaID("old"), provider: "local", title: "", position: 3)
        let session = kit.makeSession(backend: backend)
        let task = Task { try await service.resume(bookmark.id, in: session, autoplay: true) }
        await gate.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await session.load(MediaID("competing")) }
        session.stop()
        backend.seekGate = nil
        try await session.load(MediaID("new"))
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(session.snapshot.resource?.id == (try MediaID("new")))
        #expect(session.snapshot.state == .ready)
        #expect(!backend.playing)
    }
}
