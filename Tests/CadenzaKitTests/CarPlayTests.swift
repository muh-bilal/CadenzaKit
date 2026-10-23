import Foundation
import Testing
import CadenzaDomain
import CadenzaPlayer
import CadenzaCarPlay
#if os(iOS)
import CarPlay
#endif

@MainActor struct CarPlayTests {
    func player(enabled: Bool = true, system: Bool = true, backend: SystemPlaybackTests.Backend = .init(), policy: @escaping @Sendable () async -> RuntimeCapabilities = { .init() }) throws -> CadenzaPlayer {
        try CadenzaPlayer(source: PlayerFacadeTests().source(), features: .init(systemPlayback: system, carPlay: enabled),
            backend: backend, systemPlayback: SystemPlaybackTests.Platform(), clock: PlayerFacadeTests.StoppedClock(),
            nowPlaying: NowPlayingTests.Sink(), runtimeCapabilities: policy)
    }
    func catalog() throws -> [CarPlaySection] {
        let id = try MediaID("a")
        return [.init(title: "Library", tracks: [
            .init(entry: .init(id: UUID(), mediaID: id), title: "First", subtitle: "Artist"),
            .init(entry: .init(id: UUID(), mediaID: id), title: "Duplicate")])]
    }
    @Test func catalogPlaybackDuplicatesAndFlags() async throws {
        let player = try player(), catalog = try catalog()
        let library = CarPlayLibrary(player: player) { catalog }
        try await library.reload()
        #expect(library.sections == catalog)
        try await library.select(catalog[0].tracks[1].entry.id)
        #expect(player.queue.currentEntryID == catalog[0].tracks[1].entry.id)
        #expect(player.snapshot.state == .playing && player.queue.entries.count == 2)
        library.disconnect()
        #expect(library.sections.isEmpty && player.snapshot.state == .playing)
        await #expect(throws: CadenzaError.queueEntryNotFound) { try await library.select(UUID()) }
        player.stop()
        let disabled = CarPlayLibrary(player: try self.player(enabled: false)) { Issue.record("Disabled catalog was called"); return [] }
        await #expect(throws: CadenzaError.carPlayDisabled) { try await disabled.reload() }
        let foreground = CarPlayLibrary(player: try self.player(system: false)) { [] }
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .disabled)) { try await foreground.reload() }
    }
    @Test func malformedCatalogFailureAndEmptyCatalog() async throws {
        let catalog = try catalog(), player = try player()
        let duplicate = CarPlayLibrary(player: player) { catalog + catalog }
        await #expect(throws: CadenzaError.duplicateQueueEntry) { try await duplicate.reload() }
        #expect(duplicate.sections.isEmpty)
        let failed = CarPlayLibrary(player: player) { throw CadenzaError.unsupportedMedia }
        await #expect(throws: CadenzaError.unsupportedMedia) { try await failed.reload() }
        let empty = CarPlayLibrary(player: player) { [] }
        try await empty.reload(); #expect(empty.sections.isEmpty)
    }
    @Test func loadingAndSelectionCancellation() async throws {
        let catalog = try catalog(), player = try player(), gate = PlaybackTests.Gate()
        let library = CarPlayLibrary(player: player) { await gate.wait(); return catalog }
        let load = Task { try await library.reload() }
        await gate.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await library.reload() }
        await #expect(throws: CadenzaError.operationInProgress) { try await library.select(UUID()) }
        library.disconnect(); gate.open()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(library.sections.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await library.reload()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let gate2 = PlaybackTests.Gate()
        let cancellable = CarPlayLibrary(player: player) { await gate2.wait(); try Task.checkCancellation(); return catalog }
        let outer = Task { try await cancellable.reload() }
        await gate2.waitUntilEntered(); outer.cancel(); gate2.open()
        await #expect(throws: CancellationError.self) { try await outer.value }
        let backend = SystemPlaybackTests.Backend(), preparation = PlaybackTests.Gate()
        let otherPlayer = try self.player(backend: backend)
        let selection = CarPlayLibrary(player: otherPlayer) { catalog }
        try await selection.reload()
        backend.preparation = { await preparation.wait() }
        let play = Task { try await selection.select(catalog[0].tracks[0].entry.id) }
        await preparation.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await selection.select(catalog[0].tracks[1].entry.id) }
        play.cancel(); selection.disconnect(); preparation.open()
        await #expect(throws: CancellationError.self) { try await play.value }
        #expect(otherPlayer.snapshot.state != .playing)
    }
    @Test func runtimeRevocation() async throws {
        let policy = SystemPlaybackTests.Policy(), player = try player(policy: { await policy.value }), catalog = try catalog()
        let library = CarPlayLibrary(player: player) { catalog }
        try await library.reload(); await policy.revoke()
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .outputRoute)) { try await library.select(catalog[0].tracks[0].entry.id) }
        #expect(player.snapshot.state == .idle)
    }
    @Test func disconnectInvalidatesPendingAuthorization() async throws {
        let gate = PlaybackTests.Gate(), catalog = try catalog()
        let player = try player(policy: { await gate.wait(); return .init() })
        let library = CarPlayLibrary(player: player) { catalog }
        let reload = Task { try await library.reload() }
        await gate.waitUntilEntered()
        await #expect(throws: CadenzaError.operationInProgress) { try await library.reload() }
        await #expect(throws: CadenzaError.operationInProgress) { try await library.select(catalog[0].tracks[0].entry.id) }
        library.disconnect(); gate.open()
        await #expect(throws: CancellationError.self) { try await reload.value }
        #expect(library.sections.isEmpty)
        gate.started = false
        let retry = Task { try await library.reload() }
        await gate.waitUntilEntered()
        gate.open()
        try await retry.value
        #expect(library.sections == catalog)
    }
    #if os(iOS)
    @Test func nativeTemplatesRouteSelectionsAndFailures() async throws {
        let catalog = try catalog(), player = try player()
        var library: CarPlayLibrary? = CarPlayLibrary(player: player) { catalog }
        try await library?.reload()
        var starts = 0, failures = 0
        let candidate = library?.makeTemplate(title: "Music", emptyTitle: "Empty", emptySubtitle: "Add music", onPlaybackStarted: { starts += 1 }, onFailure: { _ in failures += 1 })
        let template = try #require(candidate)
        #expect(template.title == "Music" && template.sections.count == 1)
        #expect(template.emptyViewTitleVariants == ["Empty"])
        let item = try #require(template.sections[0].items[0] as? CPListItem)
        #expect(item.text == "First" && item.detailText == "Artist")
        await withCheckedContinuation { continuation in item.handler?(item) { continuation.resume() } }
        #expect(starts == 1 && player.snapshot.state == .playing)
        library?.disconnect()
        await withCheckedContinuation { continuation in item.handler?(item) { continuation.resume() } }
        #expect(failures == 1)
        library = nil
        await withCheckedContinuation { continuation in item.handler?(item) { continuation.resume() } }
        #expect(starts == 1 && failures == 1)
        player.stop()
    }
    @Test func nativeSelectionCancellationCompletesWithoutNavigation() async throws {
        let backend = SystemPlaybackTests.Backend(), gate = PlaybackTests.Gate(), catalog = try catalog()
        let player = try player(backend: backend)
        let library = CarPlayLibrary(player: player) { catalog }
        try await library.reload()
        let template = library.makeTemplate(title: "Music", emptyTitle: "Empty", emptySubtitle: "Add music",
            onPlaybackStarted: { Issue.record("Cancelled selection navigated") }, onFailure: { _ in Issue.record("Cancellation presented an error") })
        let item = try #require(template.sections[0].items[0] as? CPListItem)
        backend.preparation = { await gate.wait() }
        let selection = Task { await withCheckedContinuation { continuation in item.handler?(item) { continuation.resume() } } }
        await gate.waitUntilEntered(); library.disconnect(); gate.open()
        await selection.value
        #expect(player.snapshot.state != .playing)
    }
    #endif
}
