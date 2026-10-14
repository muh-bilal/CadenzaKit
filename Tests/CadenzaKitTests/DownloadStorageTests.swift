import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaPersistence

@MainActor
struct DownloadStorageTests {
    func add(_ id: String, to store: FileOfflineAudioStore, time: Double = 1, data: Data = Data([1, 2])) async throws -> OfflineAudio {
        let source = MediaResource(id: try MediaID("remote"), url: URL(string: "https://example.com/a.wav")!, title: "Track")
        return try await store.save(data, id: MediaID(id), source: source, provider: "https", createdAt: Date(timeIntervalSince1970: time), metadata: DownloadValidationReader(action: {}))
    }

    func service(_ store: FileOfflineAudioStore, flags: FeatureFlags = .init(downloads: true, storageManagement: true)) throws -> DownloadStorageService {
        try PlaybackTests().kit(flags: flags).makeDownloadStorage(store: store)
    }

    @Test func quotasDeterministicEvictionAndProtectedIDs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder, maximumStoredBytes: 6)
        let manager = try service(store)
        #expect(try await manager.usage() == OfflineStorageUsage(catalogBytes: 0, availableBytes: 0, orphanBytes: 0, missingIDs: []))
        _ = try await add("c", to: store, time: 2)
        _ = try await add("b", to: store)
        _ = try await add("a", to: store)
        await #expect(throws: CadenzaError.storageLimitExceeded) { try await add("d", to: store) }
        #expect(try await manager.usage().availableBytes == 6)
        let protected = try MediaID("b")
        let result = try await manager.trim(to: 2, protecting: [protected])
        #expect(result.removedIDs.map(\.rawValue) == ["a", "c"])
        #expect(result.remainingCatalogBytes == 2)
        #expect(result.retainedFiles.isEmpty)
        let impossible = try await manager.trim(to: 0, protecting: [protected])
        #expect(impossible.removedIDs.isEmpty && impossible.remainingCatalogBytes == 2)
        #expect(try await manager.remove(protected).remainingCatalogBytes == 0)
        await #expect(throws: CadenzaError.resourceNotFound(protected)) { try await manager.remove(protected) }
        await #expect(throws: CadenzaError.invalidStorageConfiguration) { try await manager.trim(to: -1) }
        #expect(throws: CadenzaError.invalidStorageConfiguration) { try FileOfflineAudioStore(directory: folder, maximumStoredBytes: -1) }
        _ = try await add("after-delete", to: store)
        #expect(try await store.all().count == 1)
    }

    @Test func reconciliationPrunesMissingAndOwnedOrphansPreservingUnrelatedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        _ = try await add("missing", to: store)
        _ = try await add("missing-two", to: store)
        _ = try await add("available", to: store)
        let missing = try MediaID("missing")
        let missingURL = try await store.resource(missing).url
        try FileManager.default.removeItem(at: missingURL)
        let missingTwo = try MediaID("missing-two")
        let missingTwoURL = try await store.resource(missingTwo).url
        try FileManager.default.removeItem(at: missingTwoURL)
        let orphan = String(repeating: "a", count: 64) + ".wav"
        let staging = "." + String(repeating: "b", count: 64) + ".wav"
        try Data([1, 2]).write(to: folder.appendingPathComponent(orphan))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(staging))
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data([7]).write(to: unrelated)
        let symlink = folder.appendingPathComponent(String(repeating: "c", count: 64) + ".wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
        let directory = folder.appendingPathComponent(String(repeating: "d", count: 64) + ".wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let manager = try service(store)
        #expect(try await manager.usage() == OfflineStorageUsage(catalogBytes: 6, availableBytes: 2, orphanBytes: 5, missingIDs: [missing, missingTwo]))
        let report = try await manager.reconcile()
        #expect(report.missingIDs == [missing, missingTwo])
        #expect(report.removedOrphans == [staging, orphan].sorted())
        #expect(report.retainedOrphans.isEmpty)
        #expect(try await store.all().map(\.id.rawValue) == ["available"])
        #expect(try Data(contentsOf: unrelated) == Data([7]))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try await manager.reconcile().removedOrphans.isEmpty)
        let available = try MediaID("available")
        let availableURL = try await store.resource(available).url
        try FileManager.default.removeItem(at: availableURL)
        #expect(try await manager.remove(available).retainedFiles.isEmpty)
    }

    @Test func cleanupFailuresAreReportedAndIndexFailurePreservesAudio() async throws {
        struct Failure: Error {}
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        _ = try await add("keep", to: store)
        let id = try MediaID("keep")
        let file = try await store.resource(id).url
        let index = folder.appendingPathComponent("index.json")
        let original = try Data(contentsOf: index)
        let failedCommit = try FileOfflineAudioStore(directory: folder, commitIndex: { _, _ in throw Failure() })
        await #expect(throws: CadenzaError.self) { try await failedCommit.remove(id) }
        #expect(try Data(contentsOf: index) == original)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let failedCleanup = try FileOfflineAudioStore(directory: folder, removeFile: { _ in throw Failure() })
        let removal = try await failedCleanup.remove(id)
        #expect(removal.retainedFiles == [file.lastPathComponent])
        #expect(try await failedCleanup.all().isEmpty)
        #expect(try await failedCleanup.reconcile().retainedOrphans == [file.lastPathComponent])
        let reopened = try FileOfflineAudioStore(directory: folder)
        #expect(try await reopened.reconcile().removedOrphans == [file.lastPathComponent])
        #expect(try await reopened.usage().orphanBytes == 0)
        _ = try await add("replaced-by-directory", to: reopened)
        let replacedID = try MediaID("replaced-by-directory")
        let replaced = try await reopened.resource(replacedID).url
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
        let child = replaced.appendingPathComponent("unrelated.txt")
        try Data([7]).write(to: child)
        #expect(try await reopened.remove(replacedID).retainedFiles == [replaced.lastPathComponent])
        #expect(try Data(contentsOf: child) == Data([7]))
    }

    @Test func flagsCancellationBusyStoreAndInvalidInventoryAreExplicit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        let id = try MediaID("id")
        for (flags, error) in [(FeatureFlags(downloads: true), CadenzaError.storageManagementDisabled), (.init(storageManagement: true), .downloadsDisabled), (.init(persistence: false, downloads: true, storageManagement: true), .persistenceDisabled)] {
            let manager = try service(store, flags: flags)
            await #expect(throws: error) { try await manager.usage() }
            await #expect(throws: error) { try await manager.remove(id) }
            await #expect(throws: error) { try await manager.trim(to: 0) }
            await #expect(throws: error) { try await manager.reconcile() }
        }
        let gate = PlaybackTests.Gate()
        let source = MediaResource(id: id, url: URL(string: "https://example.com/a.wav")!, title: "A")
        let task = Task { try await store.save(Data([1]), id: id, source: source, provider: "https", createdAt: Date(timeIntervalSince1970: 1), metadata: DownloadValidationReader { await gate.wait() }) }
        await gate.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await store.reconcile() }
        gate.open()
        _ = try await task.value
        let manager = try service(store)
        let cancelled = Task { try await manager.remove(id) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.all().count == 1)
        let badFolder = folder.appendingPathComponent("not-directory")
        try Data([1]).write(to: badFolder)
        let invalidStore = try FileOfflineAudioStore(directory: badFolder)
        await #expect(throws: CadenzaError.self) { try await invalidStore.usage() }
    }

    @Test func corruptAndOverflowingCatalogsNeverTriggerCleanup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        let orphan = folder.appendingPathComponent(String(repeating: "a", count: 64) + ".wav")
        try Data([9]).write(to: orphan)
        let index = folder.appendingPathComponent("index.json")
        try Data("corrupt".utf8).write(to: index)
        await #expect(throws: CadenzaError.corruptStore) { try await store.reconcile() }
        #expect(try Data(contentsOf: orphan) == Data([9]))
        let metadata = try MediaMetadata(title: "A", duration: 1)
        let objects = try ["a", "b"].map { name in
            let id = try MediaID(name)
            let item = try OfflineAudio(id: id, sourceMediaID: id, sourceProvider: "source", metadata: metadata,
                                        byteCount: Int.max, fileExtension: "wav", createdAt: Date(timeIntervalSince1970: 1))
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "items": objects]).write(to: index)
        await #expect(throws: CadenzaError.storageLimitExceeded) { try await store.usage() }
        await #expect(throws: CadenzaError.storageLimitExceeded) { try await store.trim(to: 0, protecting: []) }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }
}
