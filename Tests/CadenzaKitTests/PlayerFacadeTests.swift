import Foundation
import Testing
import CadenzaDomain
import CadenzaPlayer

@MainActor struct PlayerFacadeTests {
    struct StoppedClock: PlaybackClock {
        func sleep(for duration: Duration) throws { throw CancellationError() }
    }
    actor TickClock: PlaybackClock {
        let ready = PlaybackTests.Gate(), sampled = PlaybackTests.Gate()
        var count = 0
        func sleep(for duration: Duration) async throws {
            count += 1
            if count == 1 { await ready.wait() }
            else { await sampled.wait(); throw CancellationError() }
        }
    }
    func source() -> MediaSource {
        MediaSource { id in .init(id: id, url: URL(fileURLWithPath: "/track.wav"), title: id.rawValue) }
    }

    @Test func commandsPolicyAndProviderComposition() async throws {
        let backend = PlaybackTests.Backend()
        let player = try CadenzaPlayer(source: source(), backend: backend, clock: StoppedClock())
        var changes = 0
        player.onChange = { changes += 1 }
        await player.refresh()
        try await player.play(MediaID("a"))
        #expect(player.snapshot.state == .playing)
        #expect(player.services.configuration.defaultProvider == "app")
        let entries = try ["a", "b"].map { QueueEntry(id: UUID(), mediaID: try MediaID($0)) }
        try await player.play(entries: entries)
        try await player.next(); #expect(player.snapshot.resource?.id == entries[1].mediaID)
        try await player.previous(); #expect(player.snapshot.resource?.id == entries[0].mediaID)
        try await player.play(entryID: entries[1].id)
        try await player.previous(); #expect(player.queue.currentEntryID == entries[0].id)
        await #expect(throws: CadenzaError.queueEntryNotFound) { try await player.play(entryID: UUID()) }
        #expect(player.queue.currentEntryID == entries[0].id)
        try await player.seek(to: 3); try player.pause()
        #expect(player.snapshot.position == 3 && player.snapshot.state == .paused)
        try await player.resume()
        player.setBackgrounded(true)
        #expect(player.snapshot.state == .paused)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .disabled)) { try await player.resume() }
        player.setBackgrounded(false)
        player.stop(); #expect(player.snapshot.state == .idle && player.failure == nil && changes >= 10)
        #expect(throws: CadenzaError.duplicateProvider("app")) { try CadenzaPlayer(source: source(), additionalSources: [source()]) }
        let disabled = try CadenzaPlayer(source: source(), features: .init(playback: false), backend: backend, clock: StoppedClock())
        await #expect(throws: CadenzaError.featureUnavailable(.playback, .disabled)) { try await disabled.play(MediaID("a")) }
    }

    @Test func automaticClockSamplingAndRelease() async throws {
        let clock = TickClock(), backend = PlaybackTests.Backend()
        var player: CadenzaPlayer? = try CadenzaPlayer(source: source(), backend: backend, clock: clock)
        weak var released = player
        try await player?.play(MediaID("a"))
        await clock.ready.waitUntilEntered()
        backend.position = 4
        clock.ready.open()
        await clock.sampled.waitUntilEntered()
        #expect(player?.snapshot.position == 4)
        clock.sampled.open()
        player = nil
        #expect(released == nil)
    }

    @Test func competingCommandsCancellationAndSamplingFailure() async throws {
        let backend = PlaybackTests.Backend()
        let player = try CadenzaPlayer(source: source(), backend: backend, clock: StoppedClock())
        try await player.play(MediaID("a"))
        let gate = PlaybackTests.Gate(); backend.seekGate = gate
        let seek = Task { try await player.seek(to: 2) }
        await gate.waitUntilEntered()
        await player.refresh(); #expect(player.failure == nil)
        gate.open(); try await seek.value
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await player.refresh()
        }
        await cancelled.value
        #expect(player.failure == nil)
        backend.failure = CadenzaError.unsupportedMedia
        await player.refresh()
        #expect(player.failure == .unsupportedMedia && player.snapshot.state == .idle)
        backend.failure = nil
        try await player.play(MediaID("b"))
        #expect(player.failure == nil)
        player.stop()
    }

    @Test func defaultBackendPlaysRealFilesAndHTTPS() async throws {
        let local = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: local.url) }
        let remote = try RemotePlaybackTests().media()
        let source = MediaSource { id in id == local.id ? local : remote }
        let player = try CadenzaPlayer(source: source, features: .init(remotePlayback: true), clock: StoppedClock())
        try await player.play(local.id)
        #expect(player.snapshot.duration > 0)
        try await player.play(remote.id)
        #expect(player.snapshot.duration > 0 && player.snapshot.state == .playing)
        player.stop()
    }
}
