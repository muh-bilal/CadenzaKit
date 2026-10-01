import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaAVPlayback
import CadenzaPersistence

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
            try await session.refresh()
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

    @Test func queueAdvancesRealPlaybackAcrossDuplicateOccurrences() async throws {
        let media = try fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let source = try LocalFileSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let queue = kit.makeQueue(backend: AVPlayerBackend())
        let a = QueueEntry(id: UUID(), mediaID: media.id), b = QueueEntry(id: UUID(), mediaID: media.id)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try await queue.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !(queue.currentEntryID == b.id && queue.snapshot.state == .ended), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
            try await queue.refresh()
        }
        #expect(queue.history == [a.id, b.id])
        #expect(queue.snapshot.state == .ended)
        queue.stop()
    }

    @Test func repeatOneRestartsRealPlayerWithoutDuplicateHistory() async throws {
        let media = try fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let source = try LocalFileSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let queue = kit.makeQueue(backend: AVPlayerBackend())
        try queue.insert(QueueEntry(id: UUID(), mediaID: media.id), at: 0)
        try queue.setRepeat(.one)
        try await queue.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var restarts = 0
        var lastPosition = 0.0
        while restarts < 2, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
            try await queue.refresh()
            if lastPosition - queue.snapshot.position > 0.2 { restarts += 1 }
            lastPosition = queue.snapshot.position
        }
        #expect(restarts == 2)
        #expect(queue.history.count == 1)
        #expect(queue.snapshot.state == .playing)
        queue.stop()
    }

    @Test(arguments: [0.3, 0.5]) func abLoopSeeksRealPlayerWithinRefreshTolerance(end: Double) async throws {
        let media = try fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let source = try LocalFileSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let session = kit.makeSession(backend: AVPlayerBackend())
        try await session.load(media.id)
        try await session.setLoop(LoopRange(start: 0.1, end: end))
        try await session.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var wraps = 0
        var lastPosition = 0.0
        while wraps < 3, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
            try await session.refresh()
            if lastPosition - session.snapshot.position > 0.1 {
                wraps += 1
                #expect(abs(session.snapshot.position - 0.1) < 0.02)
            }
            lastPosition = session.snapshot.position
        }
        #expect(wraps == 3)
        try session.pause()
        #expect(session.snapshot.state == .paused)
        session.stop()
    }

    @Test(arguments: [false, true]) func bookmarkResumesRealPlayerAfterStoreRecreation(preferences: Bool) async throws {
        let media = try fixture()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CadenzaResume." + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: media.url)
            try? FileManager.default.removeItem(at: fileURL)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        func makeStore() throws -> any DocumentStore {
            if preferences { return try PreferencesDocumentStore(suiteName: suite, key: "bookmarks") }
            return try AtomicFileStore(fileURL: fileURL)
        }
        let source = try LocalFileSource(resources: [media.id: media])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let session = kit.makeSession(backend: AVPlayerBackend())
        try await session.load(media.id)
        try await session.seek(to: 0.2)
        let bookmarks = kit.makeBookmarks(store: try makeStore())
        let saved = try await bookmarks.capture(id: UUID(), title: "Resume", from: session)
        session.stop()
        let restored = kit.makeSession(backend: AVPlayerBackend())
        try await kit.makeBookmarks(store: makeStore()).resume(saved.id, in: restored)
        try await restored.refresh()
        #expect(abs(restored.snapshot.position - 0.2) < 0.02)
        #expect(restored.snapshot.state == .ready)
        #expect(restored.snapshot.resource?.id == media.id)
        restored.stop()
    }
}
