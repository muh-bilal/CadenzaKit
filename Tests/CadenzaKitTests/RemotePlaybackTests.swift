import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting
import CadenzaAVPlayback
import CadenzaRemoteSources

@MainActor
struct RemotePlaybackTests {
    func media() throws -> MediaResource {
        MediaResource(id: try MediaID("remote"), url: URL(string: "https://samplelib.com/mp3/sample-3s.mp3")!, title: "Samplelib 3-second synth")
    }

    @Test func catalogValidatesURLsIdentitiesAndCancellation() async throws {
        let resource = try media()
        let source = try HTTPSCatalogSource(resources: [resource.id: resource])
        #expect(try await source.resolve(resource.id) == resource)
        #expect(source.supportedFeatures.contains(.remotePlayback))
        let missing = try MediaID("missing")
        await #expect(throws: CadenzaError.resourceNotFound(missing)) { try await source.resolve(missing) }
        #expect(throws: CadenzaError.resourceIdentityMismatch) { try HTTPSCatalogSource(resources: [missing: resource]) }
        for string in ["http://example.com/a.mp3", "file:///a.mp3", "https://user:password@example.com/a.mp3", "https://example.com/a.mp3#fragment", "https:/path"] {
            #expect(throws: CadenzaError.unsupportedURL) { try RemoteMediaURL(URL(string: string)!) }
        }
        let task = Task { try await source.resolve(resource.id) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CadenzaError.unsupportedURL) { try await AVPlayerBackend().load(resource) }
        let invalid = MediaResource(id: resource.id, url: URL(string: "http://example.com/a.mp3")!, title: "Invalid")
        await #expect(throws: CadenzaError.unsupportedURL) { try await AVPlayerBackend(allowRemote: true).load(invalid) }
    }

    @Test func remotePolicyIntersectionAndRuntimeRevocation() async throws {
        let resource = try media()
        let source = try HTTPSCatalogSource(resources: [resource.id: resource])
        let backend = PlaybackTests.Backend()
        backend.supportedFeatures.insert(.remotePlayback)
        let disabled = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source]).makeSession(backend: backend)
        await #expect(throws: CadenzaError.featureUnavailable(.remotePlayback, .disabled)) { try await disabled.load(resource.id) }
        for (runtime, reason) in [
            (RuntimeCapabilities(backend: [.sourceResolution, .playback, .seeking]), UnavailabilityReason.backend),
            (.init(platform: [.sourceResolution, .playback, .seeking]), .platform),
            (.init(outputRoute: [.sourceResolution, .playback, .seeking]), .outputRoute)
        ] {
            let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: .init(remotePlayback: true)), providers: [source], runtimeCapabilities: { runtime })
            await #expect(throws: CadenzaError.featureUnavailable(.remotePlayback, reason)) { try await kit.makeSession(backend: backend).load(resource.id) }
        }
        let lacking = ClosureSourceProvider(identifier: "limited", supportedFeatures: [.sourceResolution, .playback, .seeking]) { _ in resource }
        let limited = try Cadenza(configuration: .init(defaultProvider: "limited", features: .init(remotePlayback: true)), providers: [lacking])
        await #expect(throws: CadenzaError.featureUnavailable(.remotePlayback, .source)) { try await limited.makeSession(backend: backend).load(resource.id) }
        let context = CapabilityTests.Context()
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: .init(remotePlayback: true)), providers: [source], runtimeCapabilities: { await context.value })
        await #expect(throws: CadenzaError.featureUnavailable(.remotePlayback, .backend)) { try await kit.makeSession(backend: PlaybackTests.Backend()).load(resource.id) }
        let session = kit.makeSession(backend: backend)
        try await session.load(resource.id, autoplay: true)
        try await session.seek(to: 1)
        try session.pause()
        try await session.play()
        await context.denyRoute()
        await #expect(throws: CadenzaError.featureUnavailable(.remotePlayback, .outputRoute)) { try await session.play() }
        try session.pause()
        session.stop()
        #expect(session.snapshot.state == .idle)
    }

    // Required real-network integration, never silently skipped when offline.
    // Samplelib declares its original samples unrestricted: see Documentation/Media.md.
    @Test(.timeLimit(.minutes(1))) func realHTTPSMediaLoadsSeeksAndReachesEnd() async throws {
        let resource = try media()
        let source = try HTTPSCatalogSource(resources: [resource.id: resource])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier, features: .init(remotePlayback: true)), providers: [source])
        let session = kit.makeSession(backend: AVPlayerBackend(allowRemote: true))
        defer { session.stop() }
        try await session.load(resource.id)
        #expect(session.snapshot.duration > 2 && session.snapshot.duration < 5)
        try await session.seek(to: 1)
        try await session.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while session.snapshot.state != .ended, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            try await session.refresh()
        }
        #expect(session.snapshot.state == .ended)
        #expect(session.snapshot.position > 2)
    }
}
