import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

@MainActor
struct PlaylistPlaybackTests {
    @Test func selectedOccurrenceAndIndependentSnapshotSurvivePersistentEdits() async throws {
        let service = try PlaylistTests().service(store: BookmarkTestStore())
        let playlist = try await service.create(id: UUID(), name: "Play")
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2), c = try QueueTests().entry(3)
        for (index, entry) in [a, b, c].enumerated() { try await service.insert(entry, into: playlist.id, at: index) }
        let queue = try PlaybackTests().kit().makeQueue(backend: PlaybackTests.Backend())
        try await service.play(playlist.id, in: queue, startingAt: b.id)
        #expect(queue.currentEntryID == b.id)
        #expect(queue.history == [b.id])
        try await service.removeEntry(c.id, from: playlist.id)
        try await service.delete(playlist.id)
        #expect(queue.entries == [a, b, c])
        try await queue.next()
        #expect(queue.currentEntryID == c.id)
        await #expect(throws: CadenzaError.playlistNotFound) { try await service.play(playlist.id, in: queue) }
        #expect(queue.currentEntryID == c.id)
    }

    @Test func invalidReplacementAndCancellationPreservePlayingQueue() async throws {
        let queue = try PlaybackTests().kit().makeQueue(backend: PlaybackTests.Backend())
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try await queue.playEntries([a])
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.playEntries([]) }
        await #expect(throws: CadenzaError.duplicateQueueEntry) { try await queue.playEntries([a, a]) }
        await #expect(throws: CadenzaError.queueEntryNotFound) { try await queue.playEntries([a], startingAt: b.id) }
        for operation in 0..<3 {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                switch operation {
                case 0: try await queue.playEntries([b])
                case 1: try await queue.play(b.id)
                default: try await queue.next()
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(queue.entries == [a])
        #expect(queue.currentEntryID == a.id)
        #expect(queue.history == [a.id])
        #expect(queue.snapshot.state == .playing)
        try queue.setShuffle(true)
        try await queue.playEntries([a, b])
        #expect(queue.entries == [a, b])
        #expect(queue.history.count == 1)
    }

    @Test func emptyDisabledAndUnavailableSourcesFailExplicitly() async throws {
        let store = BookmarkTestStore()
        let service = try PlaylistTests().service(store: store)
        let playlist = try await service.create(id: UUID(), name: "Empty")
        let queue = try PlaybackTests().kit().makeQueue(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.emptyQueue) { try await service.play(playlist.id, in: queue) }
        let entry = try QueueTests().entry(1)
        try await service.insert(entry, into: playlist.id, at: 0)
        let disabled = try PlaylistTests().service(store: store, flags: .init(playlists: false))
        await #expect(throws: CadenzaError.playlistsDisabled) { try await disabled.play(playlist.id, in: queue) }
        let noQueue = try PlaybackTests().kit(flags: .init(queueManagement: false)).makeQueue(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.queueDisabled) { try await service.play(playlist.id, in: noQueue) }
        let missing = ClosureSourceProvider(identifier: "local", supportedFeatures: [.sourceResolution, .playback, .seeking]) { id in throw CadenzaError.resourceNotFound(id) }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [missing])
        let failing = kit.makeQueue(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.resourceNotFound(entry.mediaID)) { try await service.play(playlist.id, in: failing) }
        #expect(failing.entries == [entry])
        #expect(failing.currentEntryID == nil)
        #expect(failing.history.isEmpty)
    }

    @Test func stopDuringPlaylistSelectionDoesNotOverwriteReplacement() async throws {
        let service = try PlaylistTests().service(store: BookmarkTestStore())
        let playlist = try await service.create(id: UUID(), name: "Pending")
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try await service.insert(a, into: playlist.id, at: 0)
        let backend = PlaybackTests.Backend()
        let gate = PlaybackTests.Gate()
        backend.gate = gate
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let task = Task { try await service.play(playlist.id, in: queue) }
        await gate.waitUntilEntered()
        queue.stop()
        backend.gate = nil
        try await queue.playEntries([b])
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(queue.currentEntryID == b.id)
        #expect(queue.entries == [b])
    }
}
