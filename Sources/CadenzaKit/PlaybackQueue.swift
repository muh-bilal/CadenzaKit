import Foundation
import CadenzaDomain

/// In-memory queue and successful-playback history. Mutation is rejected while a
/// selection is pending. The owner drives refresh() for progress and EOF advance.
@MainActor
public final class PlaybackQueue {
    public private(set) var entries: [QueueEntry] = []
    public private(set) var currentEntryID: UUID?
    public private(set) var history: [UUID] = []
    public private(set) var isShuffleEnabled = false
    public private(set) var repeatMode: RepeatMode = .off
    private var shuffleOrder: [UUID] = []
    private var visited: Set<UUID> = []
    private var historyIndex: Int?
    private let session: PlaybackSession
    private let flags: FeatureFlags
    private struct Randomness: RandomNumberGenerator {
        var base: any RandomNumberGenerator
        mutating func next() -> UInt64 { base.next() }
    }
    private var random: Randomness
    private var busy = false
    private var generation: UInt64 = 0

    init(session: PlaybackSession, flags: FeatureFlags, random: any RandomNumberGenerator) {
        self.session = session
        self.flags = flags
        self.random = Randomness(base: random)
    }

    public var snapshot: PlaybackSnapshot { session.snapshot }

    public func insert(_ entry: QueueEntry, at index: Int) throws {
        try checkMutation()
        guard (0...entries.count).contains(index) else { throw CadenzaError.invalidQueueIndex }
        guard !entries.contains(where: { $0.id == entry.id }) else { throw CadenzaError.duplicateQueueEntry }
        entries.insert(entry, at: index)
        if isShuffleEnabled { shuffleOrder.insert(entry.id, at: Int.random(in: 0...shuffleOrder.count, using: &random)) }
    }

    public func move(_ id: UUID, to index: Int) throws {
        try checkMutation()
        guard entries.indices.contains(index) else { throw CadenzaError.invalidQueueIndex }
        guard let old = entries.firstIndex(where: { $0.id == id }) else { throw CadenzaError.queueEntryNotFound }
        entries.insert(entries.remove(at: old), at: index)
    }

    public func remove(_ id: UUID) throws {
        try checkMutation()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw CadenzaError.queueEntryNotFound }
        entries.remove(at: index)
        shuffleOrder.removeAll { $0 == id }
        visited.remove(id)
        let visitedCount = history.prefix((historyIndex ?? -1) + 1).filter { $0 != id }.count
        history.removeAll { $0 == id }
        historyIndex = visitedCount > 0 ? visitedCount - 1 : nil
        if currentEntryID == id { stop() }
    }

    public func play(_ id: UUID? = nil) async throws {
        try checkMutation()
        if id == nil, currentEntryID != nil {
            busy = true
            let token = generation
            defer { if token == generation { busy = false } }
            try await session.play()
            return
        }
        guard !entries.isEmpty else { throw CadenzaError.emptyQueue }
        guard let selected = id ?? (isShuffleEnabled ? shuffleOrder.first : entries.first?.id) else { throw CadenzaError.noNextEntry }
        try await select(selected, historyPosition: nil)
    }

    public func setShuffle(_ enabled: Bool) throws {
        try checkMutation()
        guard !enabled || flags.shuffle else { throw CadenzaError.shuffleDisabled }
        guard enabled != isShuffleEnabled else { return }
        isShuffleEnabled = enabled
        shuffleOrder = enabled ? entries.map(\.id).filter { !visited.contains($0) }.shuffled(using: &random) : []
    }

    public func setRepeat(_ mode: RepeatMode) throws {
        try checkMutation()
        guard mode == .off || flags.repeatPlayback else { throw CadenzaError.repeatDisabled }
        repeatMode = mode
    }

    public func next() async throws {
        try checkMutation()
        guard !entries.isEmpty else { throw CadenzaError.emptyQueue }
        if let historyIndex, historyIndex + 1 < history.count {
            try await select(history[historyIndex + 1], historyPosition: historyIndex + 1)
            return
        }
        if isShuffleEnabled {
            if shuffleOrder.isEmpty, repeatMode == .all {
                visited.removeAll()
                shuffleOrder = entries.map(\.id).shuffled(using: &random)
                if shuffleOrder.count > 1, shuffleOrder.first == currentEntryID {
                    shuffleOrder.swapAt(0, Int.random(in: 1..<shuffleOrder.count, using: &random))
                }
            }
            guard let next = shuffleOrder.first else { throw CadenzaError.noNextEntry }
            try await select(next, historyPosition: nil)
            return
        }
        var index = entries.firstIndex { $0.id == currentEntryID }.map { $0 + 1 } ?? 0
        if index == entries.count, repeatMode == .all { index = 0; visited.removeAll() }
        guard entries.indices.contains(index) else { throw CadenzaError.noNextEntry }
        try await select(entries[index].id, historyPosition: nil)
    }

    public func previous() async throws {
        try checkMutation()
        guard let historyIndex else { throw CadenzaError.noPreviousEntry }
        let previous = currentEntryID == nil ? historyIndex : historyIndex - 1
        guard history.indices.contains(previous) else { throw CadenzaError.noPreviousEntry }
        try await select(history[previous], historyPosition: previous)
    }

    public func pause() throws {
        try checkMutation()
        try session.pause()
    }

    public func seek(to position: Double) async throws {
        try checkMutation()
        busy = true
        let token = generation
        defer { if token == generation { busy = false } }
        try await session.seek(to: position)
    }

    public func stop() {
        generation &+= 1
        busy = false
        session.stop()
        currentEntryID = nil
    }

    public func refresh() async throws {
        try checkMutation()
        guard currentEntryID != nil else { return }
        try session.refresh()
        if snapshot.state == .ended {
            if repeatMode == .one {
                try await play()
                return
            }
            do { try await next() }
            catch CadenzaError.noNextEntry { /* Keep the final ended item selected. */ }
        }
    }

    private func checkMutation() throws {
        guard flags.queueManagement else { throw CadenzaError.queueDisabled }
        guard !busy else { throw CadenzaError.operationInProgress }
    }

    private func select(_ id: UUID, historyPosition: Int?) async throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw CadenzaError.queueEntryNotFound }
        busy = true
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            try await session.load(entry.mediaID, provider: entry.provider)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            try await session.play()
            guard token == generation else { throw CancellationError() }
            currentEntryID = id
            visited.insert(id)
            shuffleOrder.removeAll { $0 == id }
            if let historyPosition {
                historyIndex = historyPosition
            } else {
                history = Array(history.prefix((historyIndex ?? -1) + 1))
                history.append(id)
                historyIndex = history.count - 1
            }
        } catch {
            if token == generation { currentEntryID = nil }
            throw error
        }
    }
}
