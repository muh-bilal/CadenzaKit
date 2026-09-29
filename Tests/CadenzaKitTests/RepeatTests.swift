import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

@MainActor
struct RepeatTests {
    @Test func repeatOneRestartsAtEOFButManualNextAdvances() async throws {
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try queue.setRepeat(.one)
        try await queue.play()
        backend.position = 10
        backend.ended = true
        try await queue.refresh()
        #expect(queue.currentEntryID == a.id)
        #expect(queue.snapshot.position == 0)
        #expect(queue.snapshot.state == .playing)
        #expect(queue.history == [a.id])
        try await queue.next()
        #expect(queue.currentEntryID == b.id)
        await #expect(throws: CadenzaError.noNextEntry) { try await queue.next() }
        try queue.setRepeat(.off)
        #expect(queue.repeatMode == .off)
    }

    @Test func repeatAllWrapsCanonicalOrderAndSingleton() async throws {
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        try queue.setRepeat(.all)
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.next() }
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try queue.insert(a, at: 0)
        try await queue.play()
        try await queue.next()
        #expect(queue.history == [a.id, a.id])
        try queue.insert(b, at: 1)
        try await queue.next()
        #expect(queue.currentEntryID == b.id)
        backend.ended = true
        try await queue.refresh()
        #expect(queue.currentEntryID == a.id)
        try await queue.previous()
        #expect(queue.currentEntryID == b.id)
    }

    @Test(arguments: Array(UInt64(0)..<16))
    func repeatAllShuffleCyclesContainEveryOccurrenceWithoutBoundaryRepeat(seed: UInt64) async throws {
        let queue = try ShuffleTests().queue(seed: seed)
        let entries = try (1...4).map { try QueueTests().entry($0) }
        for entry in entries { try queue.insert(entry, at: queue.entries.count) }
        try queue.setShuffle(true)
        try queue.setRepeat(.all)
        try await queue.play()
        for _ in 1..<8 { try await queue.next() }
        #expect(Set(queue.history.prefix(4)) == Set(entries.map(\.id)))
        #expect(Set(queue.history.suffix(4)) == Set(entries.map(\.id)))
        #expect(queue.history[3] != queue.history[4])
    }

    @Test func repeatFlagsAndSeekingCapabilitiesAreEnforced() async throws {
        let disabled = try PlaybackTests().kit(flags: .init(repeatPlayback: false)).makeQueue(backend: PlaybackTests.Backend())
        #expect(throws: CadenzaError.repeatDisabled) { try disabled.setRepeat(.one) }
        #expect(throws: CadenzaError.repeatDisabled) { try disabled.setRepeat(.all) }
        try disabled.setRepeat(.off)
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit(flags: .init(seeking: false)).makeQueue(backend: backend)
        try queue.insert(QueueTests().entry(1), at: 0)
        try queue.setRepeat(.one)
        try await queue.play()
        backend.ended = true
        await #expect(throws: CadenzaError.featureUnavailable(.seeking, .disabled)) { try await queue.refresh() }
        #expect(queue.snapshot.state == .ended)
        #expect(queue.history.count == 1)
    }

    @Test func singletonShuffleCanRepeatAndEmptyQueueCannot() async throws {
        let queue = try ShuffleTests().queue(seed: 0)
        try queue.setShuffle(true)
        try queue.setRepeat(.all)
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.next() }
        let entry = try QueueTests().entry(1)
        try queue.insert(entry, at: 0)
        try await queue.play()
        try await queue.next()
        #expect(queue.history == [entry.id, entry.id])
    }
}
