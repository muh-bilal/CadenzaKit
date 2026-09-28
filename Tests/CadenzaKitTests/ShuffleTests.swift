import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

@MainActor
struct ShuffleTests {
    func queue(seed: UInt64, flags: FeatureFlags = .init()) throws -> PlaybackQueue {
        try PlaybackTests().kit(flags: flags).makeQueue(backend: PlaybackTests.Backend(), random: SeededRandomGenerator(seed: seed))
    }

    @Test(arguments: [UInt64(0), 1, 42, .max])
    func deterministicCyclesPreserveOccurrencesAndHistory(seed: UInt64) async throws {
        let first = try queue(seed: seed), second = try queue(seed: seed)
        let entries = try (1...8).map { try QueueTests().entry($0) }
        for queue in [first, second] {
            for entry in entries { try queue.insert(entry, at: queue.entries.count) }
            try queue.setShuffle(true)
            try queue.setShuffle(true)
            #expect(queue.isShuffleEnabled)
            try await queue.play()
            for _ in 1..<entries.count { try await queue.next() }
            #expect(Set(queue.history) == Set(entries.map(\.id)))
            #expect(queue.history.count == entries.count)
            await #expect(throws: CadenzaError.noNextEntry) { try await queue.next() }
            let last = queue.currentEntryID
            try await queue.previous()
            try await queue.next()
            #expect(queue.currentEntryID == last)
            #expect(queue.history.count == entries.count)
            queue.stop()
            await #expect(throws: CadenzaError.noNextEntry) { try await queue.play() }
        }
        #expect(first.history == second.history)
        #expect(first.entries == entries)
    }

    @Test func togglesAndEditsPreserveVisitedHistoryAndCanonicalOrder() async throws {
        let queue = try queue(seed: 42)
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2), c = try QueueTests().entry(3), d = try QueueTests().entry(4)
        for entry in [a, b, c] { try queue.insert(entry, at: queue.entries.count) }
        try await queue.play(a.id)
        try queue.setShuffle(true)
        try queue.remove(c.id)
        try queue.insert(d, at: 2)
        try queue.move(a.id, to: 1)
        try await queue.next()
        try await queue.next()
        #expect(Set(queue.history) == [a.id, b.id, d.id])
        #expect(queue.history.count == 3)
        try queue.setShuffle(false)
        #expect(!queue.isShuffleEnabled)
        #expect(queue.entries.map(\.id) == [b.id, a.id, d.id])
        try await queue.play(b.id)
        try await queue.next()
        #expect(queue.currentEntryID == a.id)
        try queue.setShuffle(true)
        await #expect(throws: CadenzaError.noNextEntry) { try await queue.next() }
    }

    @Test func featureDisabledEmptyAndSingletonQueues() async throws {
        let disabled = try queue(seed: 0, flags: .init(shuffle: false))
        #expect(throws: CadenzaError.shuffleDisabled) { try disabled.setShuffle(true) }
        try disabled.setShuffle(false)
        let queue = try queue(seed: 0)
        try queue.setShuffle(true)
        await #expect(throws: CadenzaError.emptyQueue) { try await queue.play() }
        let entry = try QueueTests().entry(1)
        try queue.insert(entry, at: 0)
        try await queue.play()
        #expect(queue.currentEntryID == entry.id)
        await #expect(throws: CadenzaError.noNextEntry) { try await queue.next() }
    }

    @Test func seededGeneratorMatchesReferenceSequence() {
        var generator = SeededRandomGenerator(seed: 0)
        #expect(generator.next() == 0xE220A8397B1DCDAF)
        #expect(generator.next() == 0x6E789E6AA1B965F4)
    }

    @Test func failedSelectionDoesNotConsumeShuffledOccurrence() async throws {
        let backend = PlaybackTests.Backend()
        let kit = try PlaybackTests().kit()
        let failing = kit.makeQueue(backend: backend, random: SeededRandomGenerator(seed: 7))
        let reference = try queue(seed: 7)
        for queue in [failing, reference] {
            for number in 1...3 { try queue.insert(QueueTests().entry(number), at: queue.entries.count) }
            try queue.setShuffle(true)
        }
        backend.failure = CadenzaError.unreadableFile
        await #expect(throws: CadenzaError.unreadableFile) { try await failing.play() }
        #expect(failing.history.isEmpty)
        backend.failure = nil
        try await failing.play()
        try await reference.play()
        #expect(failing.currentEntryID == reference.currentEntryID)
    }
}
