import AppKit
import AVFoundation
import Foundation
import Testing
import CadenzaDomain
import CadenzaPersistence
import CadenzaAVPlayback
@testable import DemoCore

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
        #expect(tracks.count == 3)
        let audio = try AVAudioFile(forReading: tracks[0].url)
        #expect(audio.length == 24 * 22_050)
        let storeURL = directory.appendingPathComponent("bookmarks.json")
        let model = try DemoModel(tracks: tracks, backend: AVPlayerBackend(), store: AtomicFileStore(fileURL: storeURL))
        await model.restore(); await model.perform(.select(0))
        #expect(model.queue.snapshot.state == .playing)
        await model.perform(.seek(5)); await model.perform(.saveBookmark)
        #expect(model.saved?.position == 5)
        await model.perform(.stop)
        let reopened = try DemoModel(tracks: tracks, backend: AVPlayerBackend(), store: AtomicFileStore(fileURL: storeURL))
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
        await model.refresh(); #expect(model.message.contains("Playback stopped"))
        await model.refresh(); #expect(model.message.contains("Playback stopped"))
        backend.failure = CancellationError()
        await model.perform(.select(0)); #expect(model.message == "Operation cancelled.")
        await store.fail(); await model.restore(); #expect(model.message.contains("Could not read bookmarks"))
        let missing = directory.appendingPathComponent("file")
        try Data().write(to: missing)
        #expect(throws: (any Error).self) { try DemoAudio.create(in: missing) }
    }

    @Test func applicationBootstrapAndStorageFailure() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var entered = false
        try DemoApplication.run(directory: directory) { entered = true }
        #expect(entered)
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try DemoApplication.run(directory: file) { Issue.record("Must not run after storage failure") } }
    }

    @Test func nativeControlsDriveSDKAndAdaptToLightDarkAndWindowSize() async throws {
        _ = NSApplication.shared
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = try DemoModel(tracks: DemoAudio.create(in: directory), backend: Backend(), store: Store())
        let ui = DemoWindow(model: model)
        ui.start(); await ui.pending?.value
        #expect(!ui.position.isEnabled)
        let first = ui.buttons.first { $0.title.contains("After the light") }!
        #expect(NSApplication.shared.sendAction(first.action!, to: first.target, from: first))
        await ui.pending?.value
        #expect(model.queue.snapshot.state == .playing)
        #expect(ui.position.isEnabled)
        ui.position.doubleValue = 4; ui.seek(ui.position); await ui.pending?.value
        #expect(model.queue.snapshot.position == 4)
        for name in ["Save position", "Resume bookmark", "Shuffle", "Repeat: off", "Pause", "Play", "Next", "Previous", "Stop"] {
            let button = try #require(ui.buttons.first { $0.title == name })
            #expect(button.accessibilityLabel() != nil)
            #expect(NSApplication.shared.sendAction(button.action!, to: button.target, from: button)); await ui.pending?.value
        }
        ui.tick(); ui.tick(); await ui.pending?.value
        ui.dispatch(.select(0)); ui.dispatch(.next); await ui.pending?.value
        #expect(model.queue.snapshot.resource?.title == "After the light")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            ui.window.appearance = NSAppearance(named: appearance)
            ui.window.setContentSize(NSSize(width: 1040, height: 700))
            let view = try #require(ui.window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 1040)
            let destination = ProcessInfo.processInfo.environment["CADENZA_SCREENSHOTS"]
            if let destination {
                let url = URL(fileURLWithPath: destination).appendingPathComponent(appearance == .aqua ? "demo-mac-light.png" : "demo-mac-dark.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        ui.window.close()
        #expect(model.queue.snapshot.state == .idle)
    }
}
