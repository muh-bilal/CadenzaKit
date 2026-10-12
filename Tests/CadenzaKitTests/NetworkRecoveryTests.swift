import Foundation
import Network
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaAVPlayback
import CadenzaRemoteSources

actor RecoveryTestClock: PlaybackClock {
    var delays = 0
    var gate: PlaybackTests.Gate?
    func setGate(_ gate: PlaybackTests.Gate?) { self.gate = gate }
    func sleep(for duration: Duration) async throws {
        if duration == .seconds(100) { try await Task.sleep(for: .seconds(100)) }
        else {
            delays += 1
            if let gate { await gate.wait() }
            try Task.checkCancellation()
        }
    }
}

@MainActor
struct NetworkRecoveryTests {
    final class Backend: PlaybackBackend {
        let supportedFeatures = Set(Feature.allCases)
        var errors: [any Error] = []
        var loads = 0
        var slow = false
        var buffering = false
        let transport = PlaybackTests.Backend()
        func load(_ resource: MediaResource) async throws -> Double {
            loads += 1
            if slow { try await Task.sleep(for: .seconds(100)) }
            if !errors.isEmpty { throw errors.removeFirst() }
            return 10
        }
        func play() throws { try transport.play() }
        func pause() { transport.pause() }
        func seek(to position: Double) async throws { try await transport.seek(to: position) }
        func stop() { transport.stop() }
        func status() throws -> BackendStatus {
            let status = try transport.status()
            return BackendStatus(position: status.position, isPlaying: status.isPlaying, ended: status.ended, isBuffering: buffering)
        }
    }

    func kit() throws -> Cadenza {
        let media = try RemotePlaybackTests().media()
        let source = try HTTPSCatalogSource(resources: [media.id: media])
        return try Cadenza(configuration: .init(defaultProvider: source.identifier, features: .init(remotePlayback: true, networkRecovery: true)), providers: [source])
    }

    @Test func transientRetryAndBufferingTransitions() async throws {
        let backend = Backend()
        backend.errors = [URLError(.networkConnectionLost)]
        let clock = RecoveryTestClock()
        let session = try kit().makeResilientSession(backend: backend, policy: NetworkRecoveryPolicy(timeout: .seconds(100)), clock: clock)
        try await session.load(MediaID("remote"))
        #expect(backend.loads == 2)
        #expect(await clock.delays == 1)
        try await session.play()
        backend.buffering = true
        try await session.refresh()
        #expect(session.snapshot.state == .buffering)
        backend.buffering = false
        try await session.refresh()
        #expect(session.snapshot.state == .playing)
        backend.buffering = true
        try await session.refresh()
        backend.buffering = false
        backend.transport.playing = false
        try await session.refresh()
        #expect(session.snapshot.state == .paused)
        try await session.seek(to: 2)
        try session.pause()
        session.stop()
    }

    @Test func exhaustionPermanentErrorsAndValidation() async throws {
        let id = try MediaID("remote")
        for (code, reason) in [(URLError.timedOut, NetworkFailure.timeout), (.notConnectedToInternet, .offline), (.cannotConnectToHost, .connection), (.cannotFindHost, .connection), (.dnsLookupFailed, .connection)] {
            let backend = Backend()
            backend.errors = [NSError(domain: "AVFoundationErrorDomain", code: -1, userInfo: [NSUnderlyingErrorKey: URLError(code)])]
            let session = try kit().makeResilientSession(backend: backend, policy: NetworkRecoveryPolicy(maximumAttempts: 1, timeout: .seconds(100)), clock: RecoveryTestClock())
            await #expect(throws: CadenzaError.networkRecoveryExhausted(attempts: 1, reason: reason)) { try await session.load(id) }
            #expect(backend.loads == 1)
        }
        var nested = NSError(domain: "wrapper", code: 1)
        for _ in 0..<9 { nested = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: nested]) }
        for error: any Error in [URLError(.serverCertificateUntrusted), CadenzaError.unsupportedMedia, NSError(domain: "unknown", code: 1), nested] {
            let backend = Backend()
            backend.errors = [error]
            let session = try kit().makeResilientSession(backend: backend, policy: NetworkRecoveryPolicy(timeout: .seconds(100)), clock: RecoveryTestClock())
            await #expect(throws: CadenzaError.self) { try await session.load(id) }
            #expect(backend.loads == 1)
        }
        #expect(throws: CadenzaError.invalidRecoveryPolicy) { try NetworkRecoveryPolicy(maximumAttempts: 0) }
        #expect(throws: CadenzaError.invalidRecoveryPolicy) { try NetworkRecoveryPolicy(timeout: .zero) }
        #expect(throws: CadenzaError.invalidRecoveryPolicy) { try NetworkRecoveryPolicy(retryDelay: .seconds(-1)) }
        #expect(throws: CadenzaError.networkRecoveryDisabled) { try PlaybackTests().kit().makeResilientSession(backend: Backend(), policy: NetworkRecoveryPolicy()) }
        let backend = Backend()
        let local = try PlaybackTests().kit(flags: .init(networkRecovery: true)).makeResilientQueue(backend: backend, policy: NetworkRecoveryPolicy(), clock: RecoveryTestClock())
        try local.insert(QueueEntry(id: UUID(), mediaID: MediaID("local")), at: 0)
        try await local.play()
        #expect(backend.loads == 1)
    }

    @Test func timeoutCancellationAndStopDuringBackoff() async throws {
        let id = try MediaID("remote")
        let backend = Backend()
        backend.slow = true
        let session = try kit().makeResilientSession(backend: backend, policy: NetworkRecoveryPolicy(maximumAttempts: 1), clock: RecoveryTestClock())
        await #expect(throws: CadenzaError.networkRecoveryExhausted(attempts: 1, reason: .timeout)) { try await session.load(id) }
        for cancel in [false, true] {
            let backend = Backend()
            backend.errors = [URLError(.notConnectedToInternet)]
            let clock = RecoveryTestClock()
            let gate = PlaybackTests.Gate()
            await clock.setGate(gate)
            let session = try kit().makeResilientSession(backend: backend, policy: NetworkRecoveryPolicy(timeout: .seconds(100)), clock: clock)
            let task = Task { try await session.load(id) }
            await gate.waitUntilEntered()
            if cancel { task.cancel() } else { session.stop() }
            gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(backend.loads == 1)
            #expect(session.snapshot.state == .idle)
        }
    }

    @Test(.timeLimit(.minutes(1))) func realAVFoundationStalledTLSLoadHasBoundedTimeout() async throws {
        let server = try StalledConnectionServer()
        let port = try await server.start()
        defer { server.stop() }
        let media = MediaResource(id: try MediaID("stalled"), url: URL(string: "https://127.0.0.1:\(port)/audio.mp3")!, title: "Stalled fixture")
        let source = try HTTPSCatalogSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: .init(remotePlayback: true, networkRecovery: true)), providers: [source])
        let session = try kit.makeResilientSession(backend: AVPlayerBackend(allowRemote: true), policy: NetworkRecoveryPolicy(maximumAttempts: 1, timeout: .milliseconds(300)))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CadenzaError.networkRecoveryExhausted(attempts: 1, reason: .timeout)) { try await session.load(media.id) }
        #expect(start.duration(to: clock.now) < .seconds(5))
        #expect(server.connections.count > 0)
        session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func directAVFoundationCancellationRetainsCancellationError() async throws {
        let server = try StalledConnectionServer()
        let port = try await server.start()
        defer { server.stop() }
        let media = MediaResource(id: try MediaID("cancelled"), url: URL(string: "https://127.0.0.1:\(port)/audio.mp3")!, title: "Cancellation fixture")
        let backend = AVPlayerBackend(allowRemote: true)
        let task = Task { try await backend.load(media) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while server.connections.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!server.connections.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        backend.stop()
    }
}

@MainActor
final class StalledConnectionServer {
    private let listener: NWListener
    private var ready: CheckedContinuation<UInt16, any Error>?
    private(set) var connections: [NWConnection] = []
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.ready?.resume(returning: self.listener.port!.rawValue)
                        self.ready = nil
                    case let .failed(error): self.ready?.resume(throwing: error); self.ready = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.connections.append(connection)
                    connection.start(queue: .global())
                }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}
