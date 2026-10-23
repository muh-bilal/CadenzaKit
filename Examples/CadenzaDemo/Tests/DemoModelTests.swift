import AppKit
import AVFoundation
import Foundation
import Testing
import CadenzaDomain
import CadenzaPersistence
import CadenzaAudioEngine
@testable import CadenzamacOS

@Suite(.serialized) @MainActor
struct DemoTests {
    final class Backend: PlaybackBackend {
        let supportedFeatures: Set<Feature> = [.playback, .seeking]
        var playing = false, position = 0.0
        var failure: (any Error)?
        func load(_ resource: MediaResource) async throws -> Double {
            if let failure { throw failure }; position = 0; return 24
        }
        func play() { playing = true }
        func pause() { playing = false }
        func stop() { playing = false }
        func seek(to position: Double) { self.position = position }
        func status() throws -> BackendStatus {
            if let failure { throw failure }; return .init(position: position, isPlaying: playing, ended: position >= 24)
        }
    }
    actor Store: DocumentStore {
        var data: Data?, fails = false
        func fail() { fails = true }
        func read() throws -> Data? { if fails { throw CadenzaError.corruptStore }; return data }
        func update(_ transform: @Sendable (Data?) throws -> Data?) throws -> Data? { data = try transform(data); return data }
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatedAudioPlaysThroughRealAdapterAndBookmarksSurviveRestart() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let tracks = try DemoAudio.create(in: directory)
        #expect(tracks.count == 4)
        let audio = try AVAudioFile(forReading: tracks[0].url)
        #expect(audio.length == 24 * 22_050)
        let storeURL = directory.appendingPathComponent("bookmarks.json")
        let model = try DemoModel(tracks: tracks, backend: AVAudioEngineBackend(), store: AtomicFileStore(fileURL: storeURL))
        await model.restore(); await model.perform(.select(0))
        #expect(model.queue.snapshot.state == .playing)
        await model.perform(.seek(5)); await model.perform(.saveBookmark)
        #expect(model.saved?.position == 5)
        await model.perform(.stop)
        let reopened = try DemoModel(tracks: tracks, backend: AVAudioEngineBackend(), store: AtomicFileStore(fileURL: storeURL))
        await reopened.restore(); await reopened.perform(.resumeBookmark)
        #expect(reopened.queue.snapshot.resource?.id == tracks[0].id)
        #expect(abs(reopened.queue.snapshot.position - 5) < 0.1)
        await reopened.refresh(); await reopened.perform(.stop)
        // Reopening the example regenerates its own cache rather than accumulating files.
        #expect(try DemoAudio.create(in: directory).map(\.id) == tracks.map(\.id))
    }

    @Test func commandsFailuresCancellationAndEOF() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let tracks = try DemoAudio.create(in: directory), backend = Backend(), store = Store()
        let model = try DemoModel(tracks: tracks, backend: backend, store: store)
        #expect(throws: CadenzaError.resourceIdentityMismatch) { try DemoModel(tracks: [tracks[0], tracks[0]], backend: backend, store: store) }
        await model.restore(); await model.refresh()
        for command in [DemoModel.Command.saveBookmark, .resumeBookmark, .select(9), .previous] {
            await model.perform(command); #expect(model.message.contains("Could not complete"))
        }
        await model.perform(.playPause); #expect(backend.playing)
        await model.perform(.playPause); #expect(!backend.playing)
        await model.perform(.playPause); #expect(backend.playing)
        await model.perform(.next); #expect(model.queue.snapshot.resource?.id == tracks[1].id)
        await model.perform(.previous); #expect(model.queue.snapshot.resource?.id == tracks[0].id)
        await model.perform(.shuffle); #expect(model.queue.isShuffleEnabled)
        await model.perform(.shuffle); #expect(!model.queue.isShuffleEnabled)
        for mode in [RepeatMode.all, .one, .off] { await model.perform(.repeatMode); #expect(model.queue.repeatMode == mode) }
        backend.position = 24; await model.refresh()
        #expect(model.queue.snapshot.resource?.id == tracks[1].id)
        backend.failure = CadenzaError.unsupportedMedia
        await model.refresh(); #expect(model.message.contains("Playback error"))
        await model.refresh(); #expect(model.message.contains("Playback error"))
        backend.failure = CancellationError()
        await model.perform(.select(0)); #expect(model.message == "Operation cancelled.")
        await store.fail(); await model.restore(); #expect(model.message.contains("Could not read bookmarks"))
        let missing = directory.appendingPathComponent("file")
        try Data().write(to: missing)
        #expect(throws: (any Error).self) { try DemoAudio.create(in: missing) }
    }

}
