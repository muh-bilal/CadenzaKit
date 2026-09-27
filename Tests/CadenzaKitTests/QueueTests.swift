import Foundation
import Testing
import CadenzaDomain
import CadenzaKit

@MainActor
struct QueueTests {
    func entry(_ number: Int, media: String = "track") throws -> QueueEntry {
        QueueEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!, mediaID: try MediaID(media))
    }

    @Test func duplicateTracksHaveIndependentOccurrencesAndHistory() async throws {
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let a = try entry(1), b = try entry(2), c = try entry(3)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try queue.insert(c, at: 2)
        #expect(try JSONDecoder().decode(QueueEntry.self, from: JSONEncoder().encode(a)) == a)
        try await queue.play()
        #expect(queue.currentEntryID == a.id)
        try await queue.next()
        #expect(queue.currentEntryID == b.id)
        try await queue.previous()
        #expect(queue.currentEntryID == a.id)
        try await queue.next()
        #expect(queue.history == [a.id, b.id])
        try queue.move(b.id, to: 0)
        #expect(queue.currentEntryID == b.id)
        #expect(queue.entries.map(\.id) == [b.id, a.id, c.id])
        try queue.pause()
        #expect(queue.snapshot.state == .paused)
        try await queue.seek(to: 2)
        #expect(queue.snapshot.position == 2)
        try await queue.play()
        #expect(queue.snapshot.position == 2)
        #expect(queue.history == [a.id, b.id])
        try await queue.play(c.id)
        #expect(queue.history == [a.id, b.id, c.id])
        try await queue.previous()
        try await queue.play(a.id)
        #expect(queue.history == [a.id, b.id, a.id])
        queue.stop()
        try await queue.previous()
        #expect(queue.currentEntryID == a.id)
    }

    @Test func removalBeforeHistoryCursorRetainsCorrectBackwardNavigation() async throws {
        let queue = try PlaybackTests().kit().makeQueue(backend: PlaybackTests.Backend())
        let a = try entry(1), b = try entry(2), c = try entry(3)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try queue.insert(c, at: 2)
        try await queue.play()
        try await queue.next()
        try await queue.next()
        try queue.remove(b.id)
        try await queue.previous()
        #expect(queue.currentEntryID == a.id)
        #expect(queue.history == [a.id, c.id])
    }

    @Test func editingValidatesWithoutPartialMutationAndRemovingCurrentStops() async throws {
        let queue = try PlaybackTests().kit().makeQueue(backend: PlaybackTests.Backend())
        let a = try entry(1), b = try entry(2)
        #expect(throws: CadenzaError.invalidQueueIndex) { try queue.insert(a, at: 1) }
        try queue.insert(a, at: 0)
        #expect(throws: CadenzaError.duplicateQueueEntry) { try queue.insert(a, at: 1) }
        #expect(throws: CadenzaError.invalidQueueIndex) { try queue.move(a.id, to: 1) }
        #expect(throws: CadenzaError.queueEntryNotFound) { try queue.move(b.id, to: 0) }
        #expect(throws: CadenzaError.queueEntryNotFound) { try queue.remove(b.id) }
        await #expect(throws: CadenzaError.queueEntryNotFound) { try await queue.play(b.id) }
        try queue.insert(b, at: 1)
        try queue.remove(b.id)
        #expect(queue.history.isEmpty)
        #expect(queue.entries == [a])
        try queue.insert(b, at: 1)
        try await queue.play(a.id)
        try await queue.next()
        try queue.remove(a.id)
        #expect(queue.currentEntryID == b.id)
        #expect(queue.history == [b.id])
        try queue.remove(b.id)
        #expect(queue.snapshot.state == .idle)
        #expect(queue.entries.isEmpty)
        #expect(queue.history.isEmpty)
        #expect(queue.currentEntryID == nil)
    }

    @Test func eofAdvancesAndFinalItemRemainsEnded() async throws {
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.play() }
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.next() }
        await #expect(throws: CadenzaError.noPreviousEntry) { try await queue.previous() }
        try await queue.refresh()
        let a = try entry(1), b = try entry(2)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try await queue.next()
        await #expect(throws: CadenzaError.noPreviousEntry) { try await queue.previous() }
        try await queue.refresh()
        #expect(queue.currentEntryID == a.id)
        backend.ended = true
        try await queue.refresh()
        #expect(queue.currentEntryID == b.id)
        try await queue.refresh()
        #expect(queue.snapshot.state == .ended)
        await #expect(throws: CadenzaError.noNextEntry) { try await queue.next() }
    }

    @Test func disabledQueueAndFailedSelectionDoNotProduceHistory() async throws {
        let disabled = try PlaybackTests().kit(flags: .init(queueManagement: false)).makeQueue(backend: PlaybackTests.Backend())
        #expect(throws: CadenzaError.queueDisabled) { try disabled.insert(entry(1), at: 0) }
        await #expect(throws: CadenzaError.queueDisabled) { try await disabled.play() }
        disabled.stop()
        let backend = PlaybackTests.Backend()
        backend.failure = CadenzaError.unreadableFile
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        try queue.insert(entry(1), at: 0)
        await #expect(throws: CadenzaError.unreadableFile) { try await queue.play() }
        #expect(queue.history.isEmpty)
        #expect(queue.currentEntryID == nil)
        #expect(queue.entries.count == 1)
    }

    @Test func pendingSelectionRejectsEditsAndStopCancelsWithoutStaleHistory() async throws {
        let backend = PlaybackTests.Backend()
        let gate = PlaybackTests.Gate()
        backend.gate = gate
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let a = try entry(1), b = try entry(2)
        try queue.insert(a, at: 0)
        let task = Task { try await queue.play() }
        await gate.waitUntilEntered()
        #expect(throws: CadenzaError.operationInProgress) { try queue.insert(b, at: 1) }
        queue.stop()
        backend.gate = nil
        try queue.insert(b, at: 1)
        try await queue.play(b.id)
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(queue.history == [b.id])
        #expect(queue.currentEntryID == b.id)
    }
}
