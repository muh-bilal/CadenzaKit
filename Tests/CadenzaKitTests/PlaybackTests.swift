import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

@MainActor
struct PlaybackTests {
    final class Backend: PlaybackBackend {
        var supportedFeatures: Set<Feature> = [.playback, .seeking]
        var duration = 10.0
        var position = 0.0
        var playing = false
        var ended = false
        var failure: (any Error)?
        var gate: Gate?
        var seekGate: Gate?
        var stopCount = 0
        func load(_ resource: MediaResource) async throws -> Double {
            if let gate { await gate.wait() }
            try Task.checkCancellation()
            if let failure { throw failure }
            return duration
        }
        func play() throws {
            if let failure { throw failure }
            playing = true
        }
        func pause() { playing = false }
        func seek(to position: Double) async throws {
            if let seekGate { await seekGate.wait() }
            if let failure { throw failure }
            self.position = position
            ended = position == duration
        }
        func stop() { stopCount += 1; playing = false }
        func status() throws -> BackendStatus {
            if let failure { throw failure }
            return .init(position: position, isPlaying: playing, ended: ended)
        }
    }

    /// Explicit handshakes avoid sleeps and scheduling assumptions in race tests.
    @MainActor final class Gate {
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        var started = false
        func wait() async {
            started = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { release = $0 }
        }
        func waitUntilEntered() async {
            if !started { await withCheckedContinuation { entered = $0 } }
        }
        func open() { release?.resume(); release = nil }
    }

    func kit(flags: FeatureFlags = .init(), features: Set<Feature> = [.sourceResolution, .playback, .seeking]) throws -> Cadenza {
        let source = ClosureSourceProvider(identifier: "local", supportedFeatures: features) { id in
            MediaResource(id: id, url: URL(fileURLWithPath: "/track.wav"), title: "Track")
        }
        return try Cadenza(configuration: .init(defaultProvider: "local", features: flags), providers: [source])
    }

    @Test func transportTransitionsAndEndRestart() async throws {
        let backend = Backend()
        let session = try kit().makeSession(backend: backend)
        #expect(session.snapshot == PlaybackSnapshot(state: .idle, resource: nil, position: 0, duration: 0))
        await #expect(throws: CadenzaError.noMediaLoaded) { try await session.play() }
        #expect(throws: CadenzaError.noMediaLoaded) { try session.pause() }
        #expect(throws: CadenzaError.noMediaLoaded) { try session.refresh() }
        try await session.load(MediaID("track"))
        #expect(session.snapshot.state == .ready)
        #expect(session.snapshot.duration == 10)
        try await session.play()
        #expect(session.snapshot.state == .playing)
        backend.position = 3
        try session.refresh()
        #expect(session.snapshot.position == 3)
        try session.pause()
        #expect(session.snapshot.state == .paused)
        try await session.seek(to: 6)
        #expect(session.snapshot.position == 6)
        try await session.seek(to: 10)
        #expect(session.snapshot.state == .ended)
        try session.pause()
        #expect(session.snapshot.state == .ended)
        try await session.seek(to: 1)
        #expect(session.snapshot.state == .paused)
        backend.ended = true
        backend.position = 11
        try session.refresh()
        #expect(session.snapshot.position == 10)
        try await session.play()
        #expect(session.snapshot.state == .playing)
        #expect(session.snapshot.position == 0)
        session.stop()
        #expect(session.snapshot.state == .idle)
        #expect(session.snapshot.resource == nil)
    }

    @Test func rejectsInvalidPositionsWithoutChangingState() async throws {
        let session = try kit().makeSession(backend: Backend())
        try await session.load(MediaID("track"))
        for value in [-1, 11, .infinity, .nan] {
            await #expect(throws: CadenzaError.invalidPosition) { try await session.seek(to: value) }
            #expect(session.snapshot.state == .ready)
        }
    }

    @Test func policyIsEnforcedAndBackendMustActuallySupportOperation() async throws {
        let id = try MediaID("track")
        let disabled = try kit(flags: .init(playback: false)).makeSession(backend: Backend())
        await #expect(throws: CadenzaError.featureUnavailable(.playback, .disabled)) { try await disabled.load(id) }
        let backend = Backend()
        let session = try kit(flags: .init(seeking: false)).makeSession(backend: backend)
        try await session.load(id)
        await #expect(throws: CadenzaError.featureUnavailable(.seeking, .disabled)) { try await session.seek(to: 1) }
        #expect(session.snapshot.state == .ready)
        backend.supportedFeatures = []
        await #expect(throws: CadenzaError.featureUnavailable(.playback, .backend)) { try await session.play() }
        try session.pause()
        session.stop()
    }

    @Test func backendFailuresAreStructuredAndRecoverableByReload() async throws {
        struct Failure: Error, CustomStringConvertible { var description: String { "device" } }
        let backend = Backend()
        let session = try kit().makeSession(backend: backend)
        let id = try MediaID("track")
        backend.failure = Failure()
        await #expect(throws: CadenzaError.playbackFailure("device")) { try await session.load(id) }
        #expect(session.snapshot.state == .failed(.playbackFailure("device")))
        backend.failure = nil
        backend.duration = .nan
        await #expect(throws: CadenzaError.invalidDuration) { try await session.load(id) }
        backend.duration = 10
        try await session.load(id)
        backend.failure = CadenzaError.unsupportedMedia
        await #expect(throws: CadenzaError.unsupportedMedia) { try await session.play() }
        await #expect(throws: CadenzaError.noMediaLoaded) { try await session.play() }
        backend.failure = nil
        try await session.load(id)
        backend.position = .nan
        #expect(throws: CadenzaError.invalidPosition) { try session.refresh() }
        backend.position = 0
        try await session.load(id)
        backend.failure = Failure()
        #expect(throws: CadenzaError.playbackFailure("device")) { try session.refresh() }
    }

    @Test func replayCannotBypassDisabledSeeking() async throws {
        let backend = Backend()
        let session = try kit(flags: .init(seeking: false)).makeSession(backend: backend)
        try await session.load(MediaID("track"))
        backend.ended = true
        backend.position = 10
        try session.refresh()
        await #expect(throws: CadenzaError.featureUnavailable(.seeking, .disabled)) { try await session.play() }
        #expect(session.snapshot.state == .ended)
    }

    @Test func cancellationDuringSeekStopsSessionAndOldReplayCannotStartNewMedia() async throws {
        let backend = Backend()
        let session = try kit().makeSession(backend: backend)
        try await session.load(MediaID("old"))
        let gate = Gate()
        backend.seekGate = gate
        let seek = Task { try await session.seek(to: 2) }
        await gate.waitUntilEntered()
        seek.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await seek.value }
        #expect(session.snapshot.state == .idle)
        backend.seekGate = nil
        try await session.load(MediaID("old"))
        backend.ended = true
        try session.refresh()
        let replayGate = Gate()
        backend.seekGate = replayGate
        let replay = Task { try await session.play() }
        await replayGate.waitUntilEntered()
        session.stop()
        try await session.load(MediaID("new"))
        replayGate.open()
        await #expect(throws: CancellationError.self) { try await replay.value }
        #expect(session.snapshot.state == .ready)
        #expect(!backend.playing)
    }

    @Test func competingOperationsRejectAndStopInvalidatesPendingLoad() async throws {
        let backend = Backend()
        let gate = Gate()
        backend.gate = gate
        let session = try kit().makeSession(backend: backend)
        let id = try MediaID("track")
        let first = Task { try await session.load(id) }
        await gate.waitUntilEntered()
        #expect(session.snapshot.state == .loading(id))
        await #expect(throws: CadenzaError.operationInProgress) { try await session.load(id) }
        await #expect(throws: CadenzaError.operationInProgress) { try await session.play() }
        #expect(throws: CadenzaError.operationInProgress) { try session.pause() }
        #expect(throws: CadenzaError.operationInProgress) { try session.refresh() }
        session.stop()
        backend.gate = nil
        try await session.load(MediaID("new"))
        gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(session.snapshot.resource?.id == (try MediaID("new")))
        #expect(session.snapshot.state == .ready)
    }

    @Test func cancelledLoadReturnsToIdleAndCancelledSeekCannotClobberReplacement() async throws {
        let backend = Backend()
        let gate = Gate()
        backend.gate = gate
        let session = try kit().makeSession(backend: backend)
        let task = Task { try await session.load(MediaID("old")) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(session.snapshot.state == .idle)
        backend.gate = nil
        try await session.load(MediaID("old"))
        let seekGate = Gate()
        backend.seekGate = seekGate
        let seek = Task { try await session.seek(to: 3) }
        await seekGate.waitUntilEntered()
        session.stop()
        try await session.load(MediaID("new"))
        seekGate.open()
        await #expect(throws: CancellationError.self) { try await seek.value }
        #expect(session.snapshot.position == 0)
        #expect(session.snapshot.state == .ready)
    }
}
