import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaAVPlayback

@MainActor
struct LocalPlaybackIntegrationTests {
    func fixture() throws -> MediaResource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050))
        buffer.frameLength = 22050
        let samples = try #require(buffer.floatChannelData?[0])
        // Original deterministic test signal, generated at runtime, no media resource.
        for index in 0..<22050 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.01) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return MediaResource(id: try MediaID("tone"), url: url, title: "Generated test tone")
    }

    @Test func localCatalogChecksIdentityLocationExistenceAndCancellation() async throws {
        let media = try fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        #expect(throws: CadenzaError.resourceIdentityMismatch) {
            try LocalFileSource(resources: [MediaID("wrong"): media])
        }
        let remote = MediaResource(id: media.id, url: try #require(URL(string: "https://example.invalid/tone.wav")), title: "Remote")
        #expect(throws: CadenzaError.unsupportedURL) { try LocalFileSource(resources: [media.id: remote]) }
        let source = try LocalFileSource(resources: [media.id: media])
        #expect(source.identifier == "local")
        #expect(source.supportedFeatures == [.sourceResolution, .playback, .seeking])
        #expect(try await source.resolve(media.id) == media)
        let missing = try MediaID("missing")
        await #expect(throws: CadenzaError.resourceNotFound(missing)) { try await source.resolve(missing) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.resolve(media.id)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try FileManager.default.removeItem(at: media.url)
        await #expect(throws: CadenzaError.unreadableFile) { try await source.resolve(media.id) }
        let directory = MediaResource(id: media.id, url: FileManager.default.temporaryDirectory, title: "Directory")
        let directories = try LocalFileSource(resources: [media.id: directory])
        await #expect(throws: CadenzaError.unreadableFile) { try await directories.resolve(media.id) }
    }

    @Test func avPlayerLoadsSeeksPlaysToEndAndStops() async throws {
        let media = try fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let source = try LocalFileSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let backend = AVPlayerBackend()
        #expect(throws: CadenzaError.noMediaLoaded) { try backend.play() }
        #expect(throws: CadenzaError.noMediaLoaded) { try backend.status() }
        await #expect(throws: CadenzaError.noMediaLoaded) { try await backend.seek(to: 0) }
        let session = kit.makeSession(backend: backend)
        try await session.load(media.id)
        #expect(abs(session.snapshot.duration - 0.5) < 0.01)
        await #expect(throws: CadenzaError.invalidPosition) { try await backend.seek(to: .nan) }
        try await session.seek(to: 0.1)
        try session.pause()
        #expect(abs(session.snapshot.position - 0.1) < 0.02)
        try await session.play()
        // Real adapter integration uses a bounded wall-clock deadline; deterministic
        // state tests use injected backends. This is not an audibility/device test.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while session.snapshot.state != .ended, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
            try session.refresh()
        }
        #expect(session.snapshot.state == .ended)
        #expect(session.snapshot.position >= 0.49)
        session.stop()
        #expect(throws: CadenzaError.noMediaLoaded) { try backend.status() }
    }

    @Test func realAdapterRejectsRemoteMissingAndMalformedMedia() async throws {
        let backend = AVPlayerBackend()
        let id = try MediaID("bad")
        let remote = MediaResource(id: id, url: try #require(URL(string: "https://example.invalid/track")), title: "Remote")
        await #expect(throws: CadenzaError.unsupportedURL) { try await backend.load(remote) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let invalid = MediaResource(id: id, url: url, title: "Invalid")
        await #expect(throws: (any Error).self) { try await backend.load(invalid) }
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await backend.load(invalid) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.load(invalid)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        backend.stop()
    }
}
