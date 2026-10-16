import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting
import CadenzaAudioEngine
import CadenzaAVPlayback
import CadenzaPersistence

@MainActor
struct EqualizerTests {
    final class Backend: EqualizerBackend {
        let supportedFeatures: Set<Feature> = [.equalizer]
        var equalizerSettings = EqualizerSettings()
        var failure: (any Error)?
        func applyEqualizer(_ settings: EqualizerSettings) throws {
            if let failure { throw failure }
            equalizerSettings = settings
        }
        func load(_ resource: MediaResource) async throws -> Double { 1 }
        func play() {}
        func pause() {}
        func stop() {}
        func seek(to position: Double) async throws {}
        func status() throws -> BackendStatus { .init(position: 0, isPlaying: false, ended: false) }
    }

    func service(_ backend: any PlaybackBackend, store: any DocumentStore = BookmarkTestStore(), flags: FeatureFlags = .init(equalizer: true)) throws -> EqualizerService {
        try PlaybackTests().kit(flags: flags, features: [.equalizer]).makeEqualizer(backend: backend, store: store)
    }

    @Test func measuredParametricGainPreampAndBypass() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend(output: .manual)
        defer { backend.stop() }
        let eq = try AudioEngineTests().kit(media, flags: .init(equalizer: true)).makeEqualizer(backend: backend, store: BookmarkTestStore())
        func rms() async throws -> Double {
            _ = try await backend.load(media)
            try backend.play()
            var sum = 0.0, count = 0
            for block in 0..<16 {
                let rendered = try backend.render(frames: 1024)
                #expect(rendered.status == .success)
                let channel = try #require(rendered.buffer.floatChannelData?[0])
                if block >= 2 {
                    for index in 0..<Int(rendered.buffer.frameLength) {
                        let value = Double(channel[index]); sum += value * value; count += 1
                    }
                }
            }
            backend.stop()
            return sqrt(sum / Double(count))
        }
        let baseline = try await rms()
        #expect(baseline > 0.001)
        try await eq.apply(EqualizerSettings(bands: [EqualizerBand(frequency: 440, gain: 12)]))
        let boosted = try await rms()
        #expect(boosted / baseline > 3.8 && boosted / baseline < 4.2)
        try await eq.apply(EqualizerSettings(bands: [EqualizerBand(frequency: 440, gain: -12)]))
        let attenuated = try await rms()
        #expect(attenuated / baseline > 0.23 && attenuated / baseline < 0.27)
        try await eq.apply(EqualizerSettings(bands: [], preamp: 6))
        let preamp = try await rms()
        #expect(preamp / baseline > 1.9 && preamp / baseline < 2.1)
        try eq.bypass()
        let bypassed = try await rms()
        #expect(abs(bypassed / baseline - 1) < 0.01)
        #expect(try eq.settings.preamp == 6)
        #expect(try eq.settings.isBypassed)
    }

    @Test func nyquistValidationBeforeAndAfterLoadingAndCancellation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let media = MediaResource(id: try MediaID("low-rate"), url: url, title: "Low rate")
        let backend = AVAudioEngineBackend(output: .manual)
        defer { backend.stop() }
        let eq = try service(backend)
        let invalid = try EqualizerSettings(bands: [EqualizerBand(frequency: 6_000, gain: 1)])
        try await eq.apply(invalid)
        await #expect(throws: CadenzaError.equalizerFrequencyUnsupported(frequency: 6_000, sampleRate: 8_000)) { try await backend.load(media) }
        try eq.bypass()
        _ = try await backend.load(media)
        await #expect(throws: CadenzaError.equalizerFrequencyUnsupported(frequency: 6_000, sampleRate: 8_000)) { try await eq.apply(invalid) }
        #expect(try eq.settings.isBypassed)
        try await eq.apply(EqualizerSettings(bands: [EqualizerBand(frequency: 1_000, gain: 1)]))
        let task = Task { try backend.applyEqualizer(invalid) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func persistentPresetsEditingOrderingAndConcurrentUpdates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AtomicFileStore(fileURL: url)
        let backend = Backend(), eq = try service(backend, store: store)
        #expect(try await eq.presets().isEmpty)
        let settings = try EqualizerSettings(bands: [EqualizerBand(frequency: 100, gain: 2)])
        let a = try EqualizerPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: " A ", settings: settings)
        let b = try EqualizerPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "A", settings: .init())
        let c = try EqualizerPreset(id: UUID(), name: "C", settings: .init())
        async let first: Void = eq.savePreset(a)
        async let second: Void = eq.savePreset(b)
        async let third: Void = eq.savePreset(c)
        _ = try await (first, second, third)
        let reopened = try service(backend, store: AtomicFileStore(fileURL: url))
        #expect(try await reopened.presets() == [a, b, c])
        try await reopened.applyPreset(a.id)
        #expect(try reopened.settings == settings)
        let edit = try EqualizerPreset(id: c.id, name: "B", settings: settings)
        try await eq.savePreset(edit)
        #expect(try await eq.presets() == [a, b, edit])
        try await eq.deletePreset(a.id)
        #expect(try await eq.presets() == [b, edit])
        await #expect(throws: CadenzaError.equalizerPresetNotFound) { try await eq.applyPreset(a.id) }
        await #expect(throws: CadenzaError.equalizerPresetNotFound) { try await eq.deletePreset(a.id) }
    }

    @Test func policyBackendFailuresAndSafeBypass() async throws {
        let backend = Backend(), store = BookmarkTestStore()
        let disabled = try service(backend, store: store, flags: .init(equalizer: false))
        let settings = try EqualizerSettings(bands: [], preamp: 2)
        await #expect(throws: CadenzaError.equalizerDisabled) { try await disabled.apply(settings) }
        #expect(throws: CadenzaError.equalizerDisabled) { try disabled.settings }
        await #expect(throws: CadenzaError.equalizerDisabled) { try await disabled.presets() }
        #expect(await store.calls == 0)
        try backend.applyEqualizer(settings)
        try disabled.bypass()
        #expect(backend.equalizerSettings.isBypassed)
        let noPersistence = try service(backend, flags: .init(persistence: false, equalizer: true))
        await #expect(throws: CadenzaError.persistenceDisabled) { try await noPersistence.presets() }
        try await noPersistence.apply(settings)
        let unsupported = try service(AVPlayerBackend())
        await #expect(throws: CadenzaError.featureUnavailable(.equalizer, .backend)) { try await unsupported.apply(settings) }
        #expect(throws: CadenzaError.featureUnavailable(.equalizer, .backend)) { try unsupported.settings }
        #expect(throws: CadenzaError.featureUnavailable(.equalizer, .backend)) { try unsupported.bypass() }
        let dishonest = PlaybackTests.Backend(); dishonest.supportedFeatures = [.equalizer]
        await #expect(throws: CadenzaError.featureUnavailable(.equalizer, .backend)) { try await service(dishonest).apply(settings) }
        let eq = try service(backend)
        backend.failure = CadenzaError.unsupportedMedia
        await #expect(throws: CadenzaError.unsupportedMedia) { try await eq.apply(settings) }
        backend.failure = CocoaError(.fileReadUnknown)
        do { try await eq.apply(settings); Issue.record("Expected wrapped backend failure") }
        catch CadenzaError.equalizerFailure(let message) { #expect(!message.isEmpty) }
        backend.failure = CancellationError()
        await #expect(throws: CancellationError.self) { try await eq.apply(settings) }
        backend.failure = nil
        for reason in [UnavailabilityReason.source, .backend, .platform, .outputRoute] {
            var runtime = RuntimeCapabilities()
            if reason == .backend { runtime.backend = [] }
            if reason == .platform { runtime.platform = [] }
            if reason == .outputRoute { runtime.outputRoute = [] }
            let snapshot = runtime
            let provider = ClosureSourceProvider(identifier: "local", supportedFeatures: reason == .source ? [] : [.equalizer]) { _ in throw CadenzaError.unsupportedMedia }
            let kit = try Cadenza(configuration: .init(defaultProvider: "local", features: .init(equalizer: true)), providers: [provider], runtimeCapabilities: { snapshot })
            await #expect(throws: CadenzaError.featureUnavailable(.equalizer, reason)) { try await kit.makeEqualizer(backend: backend, store: store).apply(settings) }
        }
        let cancelled = Task { try await eq.apply(settings) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let context = CapabilityTests.Context()
        let provider = ClosureSourceProvider(identifier: "local", supportedFeatures: [.equalizer]) { _ in throw CadenzaError.unsupportedMedia }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local", features: .init(equalizer: true)), providers: [provider], runtimeCapabilities: { await context.value })
        let live = kit.makeEqualizer(backend: backend, store: store)
        try await live.apply(settings)
        await context.denyRoute()
        await #expect(throws: CadenzaError.featureUnavailable(.equalizer, .outputRoute)) { try await live.apply(settings) }
        try live.bypass()
        #expect(backend.equalizerSettings.isBypassed)
    }

    @Test func validatedValuesAndArchivesRejectCorruptionWithoutOverwriting() async throws {
        for (frequency, gain, width): (Float, Float, Float) in [(19, 0, 1), (20_001, 0, 1), (.nan, 0, 1), (100, 25, 1), (100, .infinity, 1), (100, 0, 0), (100, 0, .nan)] {
            #expect(throws: CadenzaError.invalidEqualizerSettings) { try EqualizerBand(frequency: frequency, gain: gain, bandwidth: width) }
        }
        let band = try EqualizerBand(frequency: 100, gain: 1)
        for bands in [[band, band], Array(repeating: band, count: 33)] {
            #expect(throws: CadenzaError.invalidEqualizerSettings) { try EqualizerSettings(bands: bands) }
        }
        for gain: Float in [-25, 25, .nan, .infinity] {
            #expect(throws: CadenzaError.invalidEqualizerSettings) { try EqualizerSettings(bands: [], preamp: gain) }
        }
        #expect(throws: CadenzaError.invalidEqualizerPreset) { try EqualizerPreset(id: UUID(), name: " \n", settings: .init()) }
        #expect(throws: CadenzaError.invalidEqualizerSettings) {
            try JSONDecoder().decode(EqualizerBand.self, from: Data("{\"frequency\":0,\"gain\":0,\"bandwidth\":1}".utf8))
        }
        #expect(throws: CadenzaError.invalidEqualizerSettings) {
            try JSONDecoder().decode(EqualizerSettings.self, from: Data("{\"bands\":[],\"preamp\":100,\"isBypassed\":false}".utf8))
        }
        let preset = try EqualizerPreset(id: UUID(), name: "Valid", settings: .init())
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset))
        let duplicate = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": [object, object]])
        for (data, error) in [(Data("bad".utf8), CadenzaError.corruptStore), (Data("{\"version\":2}".utf8), .unsupportedStoreVersion(2)), (duplicate, .corruptStore)] {
            let store = BookmarkTestStore(data: data), eq = try service(Backend(), store: store)
            await #expect(throws: error) { try await eq.presets() }
            await #expect(throws: error) { try await eq.savePreset(preset) }
            #expect(await store.data == data)
        }
        let store = BookmarkTestStore(), eq = try service(Backend(), store: store)
        await store.setFailure(.storageFailure("denied"))
        await #expect(throws: CadenzaError.storageFailure("denied")) { try await eq.savePreset(preset) }
        #expect(await store.data == nil)
        let task = Task { try await eq.savePreset(preset) }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.calls == 1)
    }
}
