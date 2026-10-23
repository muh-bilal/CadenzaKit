import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

@Suite(.serialized) @MainActor
struct SystemPlaybackTests {
    final class Backend: PlaybackBackend {
        var supportedFeatures = Set(Feature.allCases)
        var playing = false
        var buffering = false
        var position = 0.0
        var preparation: (() async -> Void)?
        func load(_ resource: MediaResource) async throws -> Double { await preparation?(); return 20 }
        func play() { playing = true }
        func pause() { playing = false }
        func stop() { playing = false; position = 0 }
        func seek(to position: Double) { self.position = position }
        func status() -> BackendStatus { .init(position: position, isPlaying: playing, ended: position >= 20, isBuffering: buffering) }
    }
    final class Platform: SystemPlaybackController {
        var calls = 0
        var failure: (any Error)?
        func prepareForPlayback() throws { calls += 1; if let failure { throw failure } }
    }
    actor Policy {
        var value = RuntimeCapabilities()
        func revoke() { value.outputRoute.remove(.systemPlayback) }
    }
    func kit(enabled: Bool, source: Set<Feature> = Set(Feature.allCases), policy: Policy = Policy()) throws -> Cadenza {
        try Cadenza(configuration: .init(defaultProvider: "local", features: .init(systemPlayback: enabled)), providers: [
            ClosureSourceProvider(identifier: "local", supportedFeatures: source) { id in
                .init(id: id, url: URL(fileURLWithPath: "/track.wav"), title: "Track")
            }
        ], runtimeCapabilities: { await policy.value })
    }

    @Test func foregroundOnlyPausesAndRejectsBackgroundPlay() async throws {
        let backend = Backend(), platform = Platform()
        let session = try kit(enabled: false).makeSession(backend: backend, systemPlayback: platform)
        session.setBackgrounded(true)
        #expect(session.isBackgrounded)
        session.setBackgrounded(false)
        #expect(!session.isBackgrounded)
        try await session.load(MediaID("a"), autoplay: true)
        #expect(platform.calls == 0)
        backend.position = 3
        try await session.refresh()
        session.setBackgrounded(true)
        #expect(!backend.playing && session.snapshot.state == .paused && session.snapshot.position == 3)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .disabled)) { try await session.play() }
        #expect(session.snapshot.state == .paused)
        session.setBackgrounded(false)
        try await session.play()
        #expect(backend.playing)
        try await session.load(MediaID("a"), autoplay: true)
        backend.playing = false // An OS interruption must be reflected in the snapshot.
        try await session.refresh()
        #expect(session.snapshot.state == .paused)
        session.setBackgrounded(true)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .disabled)) {
            try await session.load(MediaID("a"), autoplay: true)
        }
    }

    @Test func backgroundPlaybackKeepsTimelineQueueAndLoops() async throws {
        let backend = Backend(), platform = Platform(), policy = Policy()
        let kit = try kit(enabled: true, policy: policy)
        let queue = kit.makeQueue(backend: backend, systemPlayback: platform)
        for name in ["a", "b"] { try queue.insert(.init(id: UUID(), mediaID: MediaID(name)), at: queue.entries.count) }
        try await queue.play()
        queue.setBackgrounded(true)
        backend.position = 5; try await queue.refresh()
        #expect(backend.playing && queue.snapshot.position == 5)
        backend.buffering = true
        try await queue.refresh()
        #expect(queue.snapshot.state == .buffering)
        backend.buffering = false
        try await queue.refresh()
        #expect(queue.snapshot.state == .playing)
        backend.position = 20; try await queue.refresh()
        #expect(queue.snapshot.resource?.id == (try MediaID("b")))
        try await queue.setLoop(.init(start: 2, end: 4))
        backend.position = 4; try await queue.refresh()
        #expect(queue.snapshot.position == 2 && backend.playing)
        #expect(platform.calls >= 3)
        await policy.revoke()
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .outputRoute)) { try await queue.refresh() }
        #expect(!backend.playing && queue.snapshot.state == .paused)
        queue.setBackgrounded(false)
        #expect(!backend.playing)
        queue.stop()
    }

    @Test func missingControllerAndCapabilityDenialsFailExplicitly() async throws {
        let backend = Backend(), platform = Platform()
        let missing = try kit(enabled: true).makeSession(backend: backend)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .platform)) { try await missing.load(MediaID("a"), autoplay: true) }
        let denied = try kit(enabled: true, source: [.sourceResolution, .playback]).makeSession(backend: backend, systemPlayback: platform)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .source)) { try await denied.load(MediaID("a"), autoplay: true) }
        backend.supportedFeatures.remove(.systemPlayback)
        let unsupported = try kit(enabled: true).makeSession(backend: backend, systemPlayback: platform)
        await #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .backend)) { try await unsupported.load(MediaID("a"), autoplay: true) }
        #expect(platform.calls == 0)
        backend.supportedFeatures.insert(.systemPlayback)
        platform.failure = CancellationError()
        let cancelled = try kit(enabled: true).makeSession(backend: backend, systemPlayback: platform)
        await #expect(throws: CancellationError.self) { try await cancelled.load(MediaID("a"), autoplay: true) }
        #expect(cancelled.snapshot.state == .idle)
        platform.failure = CadenzaError.unsupportedMedia
        await #expect(throws: CadenzaError.unsupportedMedia) { try await cancelled.load(MediaID("a"), autoplay: true) }
    }

    @Test func backgroundingInvalidatesPendingForegroundOnlyLoads() async throws {
        let backend = Backend()
        let session = try kit(enabled: false).makeSession(backend: backend)
        backend.preparation = { session.setBackgrounded(true) }
        await #expect(throws: CancellationError.self) { try await session.load(MediaID("a"), autoplay: true) }
        #expect(!backend.playing && session.snapshot.state == .idle)
        let queue = try kit(enabled: false).makeQueue(backend: backend)
        try queue.insert(.init(id: UUID(), mediaID: MediaID("a")), at: 0)
        backend.preparation = { queue.setBackgrounded(true) }
        await #expect(throws: CancellationError.self) { try await queue.play() }
        #expect(queue.snapshot.state == .idle && !backend.playing)
    }
}
