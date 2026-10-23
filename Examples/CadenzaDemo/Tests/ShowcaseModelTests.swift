import XCTest
import CadenzaDomain
import CadenzaKit
@testable import CadenzamacOS

@MainActor final class ShowcaseModelTests: XCTestCase {
    final class Backend: EqualizerBackend {
        let supportedFeatures: Set<Feature> = [.playback, .seeking, .equalizer]
        var equalizerSettings = EqualizerSettings()
        var fail = false
        var held = false
        var loading: CheckedContinuation<Void, Never>?
        var observed: CheckedContinuation<Void, Never>?
        func load(_ resource: MediaResource) async throws -> Double {
            if held { await withCheckedContinuation { loading = $0; observed?.resume(); observed = nil } }
            try Task.checkCancellation(); return 24
        }
        func waitForLoad() async { if loading == nil { await withCheckedContinuation { observed = $0 } } }
        func play() {}
        func pause() {}
        func stop() {}
        func seek(to position: Double) {}
        func status() -> BackendStatus { .init(position: 0, isPlaying: false, ended: false) }
        func applyEqualizer(_ settings: EqualizerSettings) throws {
            if fail { throw CadenzaError.unsupportedMedia }
            equalizerSettings = settings
        }
    }
    actor Store: DocumentStore {
        var data: Data?
        func read() -> Data? { data }
        func update(_ transform: @Sendable (Data?) throws -> Data?) throws -> Data? { data = try transform(data); return data }
    }
    func testServiceFailuresAndCancelledGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = Backend(), store = Store()
        let model = try DemoModel(tracks: DemoAudio.create(in: directory), backend: backend, store: store, features: .init(equalizer: true))
        var calls = 0
        let controller = Showcase { calls += 1; return .init(model: model, equalizer: model.cadenza.makeEqualizer(backend: backend, store: store)) }
        controller.setBackgrounded(true)
        controller.send(.next); controller.stop(); await controller.setSound(bass: true)
        XCTAssertNil(controller.model)
        await controller.start(); await controller.start(); XCTAssertEqual(calls, 1)
        backend.fail = true; await controller.setSound(bass: true)
        XCTAssertTrue(controller.soundMessage.contains("unsupportedMedia"))
        backend.fail = false; await controller.setSound(bass: true)
        XCTAssertEqual(backend.equalizerSettings.bands.first?.gain, 4)
        await controller.setSound(bass: false); XCTAssertTrue(backend.equalizerSettings.isBypassed)
        XCTAssertEqual(controller.soundSettings, backend.equalizerSettings)
        await controller.adjustSound(frequency: 1000, delta: 3)
        XCTAssertFalse(controller.soundSettings.isBypassed)
        XCTAssertEqual(controller.soundSettings.bands.first { $0.frequency == 1000 }?.gain, 3)
        await controller.adjustSound(frequency: 1000, delta: 100)
        XCTAssertEqual(controller.soundSettings.bands.first { $0.frequency == 1000 }?.gain, 24)
        await controller.adjustSound(frequency: nil, delta: -100)
        XCTAssertEqual(controller.soundSettings.preamp, -24)
        let beforeFailure = controller.soundSettings
        backend.fail = true
        await controller.adjustSound(frequency: 120, delta: -1)
        XCTAssertEqual(controller.soundSettings, beforeFailure)
        XCTAssertFalse(controller.soundBusy)
        backend.fail = false
        let cancellation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.adjustSound(frequency: nil, delta: 1)
        }
        await cancellation.value
        XCTAssertEqual(controller.soundSettings, beforeFailure)
        XCTAssertFalse(controller.soundBusy)
        controller.send(.select(0)); controller.send(.next)
        let cancelled = controller.action
        controller.stop()
        backend.held = true
        controller.send(.select(1))
        let current = controller.action
        await cancelled?.value
        await backend.waitForLoad()
        XCTAssertTrue(controller.busy, "Cancelled work must not clear the new operation's busy flag")
        backend.loading?.resume(); backend.loading = nil
        await current?.value
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(model.queue.snapshot.resource?.id, model.tracks[1].id)
        controller.setBackgrounded(true)
        XCTAssertEqual(model.queue.snapshot.state, .paused)
        controller.setBackgrounded(false)
        XCTAssertEqual(model.queue.snapshot.state, .paused)
        controller.stop()
        let failed = Showcase { throw CadenzaError.corruptStore }
        await failed.start(); XCTAssertNotNil(failed.failure)
    }
}
