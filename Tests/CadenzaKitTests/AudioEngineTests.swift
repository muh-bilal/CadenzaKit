import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaAudioEngine

@MainActor
struct AudioEngineTests {
    func kit(_ media: MediaResource, flags: FeatureFlags = .init()) throws -> Cadenza {
        let source = try LocalFileSource(resources: [media.id: media])
        return try Cadenza(configuration: .init(defaultProvider: source.identifier, features: flags), providers: [source])
    }

    @Test func manualPCMRenderingSeekPauseResumeAndEOF() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend(output: .manual)
        defer { backend.stop() }
        let session = try kit(media).makeSession(backend: backend)
        try await session.load(media.id)
        #expect(abs(session.snapshot.duration - 0.5) < 0.01)
        #expect(throws: CadenzaError.invalidRenderRequest) { try backend.render(frames: 100) }
        try await session.play()
        let first = try backend.render(frames: 1024)
        #expect(first.status == .success)
        #expect(first.buffer.frameLength == 1024)
        let samples = try #require(first.buffer.floatChannelData?[0])
        #expect((0..<1024).contains { abs(samples[$0]) > 0.001 })
        try await session.refresh()
        #expect(session.snapshot.position > 0)
        try session.pause()
        let paused = session.snapshot.position
        _ = try backend.render(frames: 1024)
        try await session.refresh()
        #expect(abs(session.snapshot.position - paused) < 0.001)
        try await session.seek(to: 0.25)
        try await session.play()
        for _ in 0..<32 where session.snapshot.state != .ended {
            _ = try backend.render(frames: 1024)
            try await session.refresh()
        }
        #expect(session.snapshot.state == .ended)
        try await session.play()
        _ = try backend.render(frames: 1024)
        try await session.refresh()
        #expect(session.snapshot.position < 0.1)
        try await session.seek(to: 0.1)
        _ = try backend.render(frames: 1024)
        try await session.refresh()
        #expect(session.snapshot.position > 0.1 && session.snapshot.position < 0.2)
        try await session.seek(to: session.snapshot.duration)
        #expect(try backend.status().ended)
        #expect(throws: CadenzaError.invalidRenderRequest) { try backend.render(frames: 0) }
        #expect(throws: CadenzaError.invalidRenderRequest) { try backend.render(frames: 4097) }
        session.stop()
        #expect(throws: CadenzaError.noMediaLoaded) { try backend.status() }
    }

    @Test(.timeLimit(.minutes(1))) func deviceOutputAdvancesAndQueueUsesEngineBackend() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend()
        defer { backend.stop() }
        let queue = try kit(media).makeQueue(backend: backend)
        try queue.insert(QueueEntry(id: UUID(), mediaID: media.id), at: 0)
        try await queue.play()
        #expect(throws: CadenzaError.invalidRenderRequest) { try backend.render(frames: 1) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while queue.snapshot.state != .ended, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            try await queue.refresh()
        }
        #expect(queue.snapshot.state == .ended)
        #expect(queue.snapshot.position > 0.49)
        queue.stop()
    }

    @Test func invalidAssetsCommandsCancellationAndFlags() async throws {
        let backend = AVAudioEngineBackend(output: .manual)
        defer { backend.stop() }
        #expect(throws: CadenzaError.noMediaLoaded) { try backend.play() }
        await #expect(throws: CadenzaError.noMediaLoaded) { try await backend.seek(to: 0) }
        let remote = try RemotePlaybackTests().media()
        await #expect(throws: CadenzaError.unsupportedURL) { try await backend.load(remote) }
        let media = try LocalPlaybackIntegrationTests().fixture()
        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { for url in [media.url, emptyURL, invalidURL] { try? FileManager.default.removeItem(at: url) } }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do { _ = try AVAudioFile(forWriting: emptyURL, settings: format.settings) }
        await #expect(throws: CadenzaError.invalidDuration) { try await backend.load(MediaResource(id: media.id, url: emptyURL, title: "Empty")) }
        try Data([1, 2]).write(to: invalidURL)
        let invalid = MediaResource(id: media.id, url: invalidURL, title: "Invalid")
        let failed = try kit(invalid).makeSession(backend: backend)
        await #expect(throws: CadenzaError.self) { try await failed.load(media.id) }
        _ = try await backend.load(media)
        for position in [-1.0, .nan, 1] {
            await #expect(throws: CadenzaError.invalidPosition) { try await backend.seek(to: position) }
        }
        let task = Task { try await backend.load(media) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let disabled = try kit(media, flags: .init(playback: false)).makeSession(backend: backend)
        await #expect(throws: CadenzaError.featureUnavailable(.playback, .disabled)) { try await disabled.load(media.id) }
    }
}

extension AudioEngineTests {
    @Test func devicePositionContinuesAfterForwardAndBackwardSeeks() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend()
        defer { backend.stop() }
        let session = try kit(media).makeSession(backend: backend)
        try await session.load(media.id)
        try await session.play()
        for target in [0.1, 0.3, 0.05] {
            try await session.seek(to: target)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            repeat {
                try await Task.sleep(for: .milliseconds(10))
                try await session.refresh()
            } while session.snapshot.position <= target + 0.02 && clock.now < deadline
            #expect(session.snapshot.position > target + 0.02)
            #expect(session.snapshot.state == .playing)
        }
    }
}
