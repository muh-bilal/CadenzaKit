import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaAVPlayback
import CadenzaTesting
@testable import CadenzaAudioEngine

@MainActor
struct SpectrumTests {
    @Test func normalizationAndPolicy() async throws {
        let frame = SpectrumFrame(levels: [.nan, -.infinity, -1, 2, 0.5])
        #expect(frame.levels.count == 32)
        #expect(Array(frame.levels.prefix(5)) == [0, 0, 0, 1, 0.5])
        #expect(!FeatureFlags().isEnabled(.spectrum))
        #expect(FeatureFlags(spectrum: true).isEnabled(.spectrum))
        for reason in [UnavailabilityReason.disabled, .source, .backend, .platform, .outputRoute] {
            var runtime = RuntimeCapabilities()
            if reason == .backend { runtime.backend = [] }
            if reason == .platform { runtime.platform = [] }
            if reason == .outputRoute { runtime.outputRoute = [] }
            let snapshot = runtime
            let source = ClosureSourceProvider(identifier: "test", supportedFeatures: reason == .source ? [] : [.spectrum]) { _ in throw CadenzaError.unsupportedMedia }
            let kit = try Cadenza(configuration: .init(defaultProvider: "test", features: .init(spectrum: reason != .disabled)), providers: [source], runtimeCapabilities: { snapshot })
            let service = kit.makeSpectrum(backend: AVAudioEngineBackend(output: .manual))
            await #expect(throws: CadenzaError.featureUnavailable(.spectrum, reason)) { try await service.read() }
            service.stop()
        }
        let kit = try PlaybackTests().kit(flags: .init(spectrum: true), features: [.spectrum])
        for backend in [AVPlayerBackend() as any PlaybackBackend, PlaybackTests.Backend()] {
            let service = kit.makeSpectrum(backend: backend)
            await #expect(throws: CadenzaError.featureUnavailable(.spectrum, .backend)) { try await service.read() }
        }
        let backend = AVAudioEngineBackend(output: .manual), service = kit.makeSpectrum(backend: backend)
        #expect(try await service.read() == SpectrumFrame())
        #expect(try await service.read() == SpectrumFrame())
        let task = Task { try await service.read() }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        service.stop()
    }

    @Test func nativePostEQFrequencyGainAndLifecycle() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend(output: .manual)
        let kit = try AudioEngineTests().kit(media, flags: .init(spectrum: true, equalizer: true))
        let service = kit.makeSpectrum(backend: backend)
        defer { service.stop(); backend.stop() }
        #expect(try await service.read() == SpectrumFrame())
        _ = try await backend.load(media)
        try backend.play()
        #expect(try await service.read() == SpectrumFrame())
        for _ in 0..<4 { _ = try backend.render(frames: 1024) }
        let baseline = try await service.read()
        let peak = try #require(baseline.levels.max())
        let band = try #require(baseline.levels.firstIndex(of: peak))
        #expect((13...15).contains(band)) // 440 Hz in the logarithmic band layout.
        #expect(peak > 0.2)
        try backend.applyEqualizer(EqualizerSettings(bands: [], preamp: -12))
        for _ in 0..<4 { _ = try backend.render(frames: 1024) }
        let attenuated = try await service.read()
        #expect(abs((peak - attenuated.levels[band]) - 12 / 80) < 0.015)
        backend.pause()
        #expect(try await service.read() == SpectrumFrame())
        try backend.play()
        #expect(try await service.read() == SpectrumFrame())
        _ = try backend.render(frames: 1024)
        #expect(try await service.read().levels.max()! > 0)
        try await backend.seek(to: 0.1)
        #expect(try await service.read() == SpectrumFrame())
        _ = try backend.render(frames: 1024)
        service.stop()
        #expect(backend.spectrum() == SpectrumFrame())
        #expect(try await service.read() == SpectrumFrame())
        _ = try backend.render(frames: 1024)
        backend.stop()
        #expect(try await service.read() == SpectrumFrame())
        _ = try await backend.load(media)
        #expect(try await service.read() == SpectrumFrame())
        try backend.play()
        try await backend.seek(to: 0.5)
        #expect(try await service.read() == SpectrumFrame())
    }

    @Test func mailboxSilencePartialWindowsAndNonfinitePCM() throws {
        let analyzer = SpectrumAnalyzer()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        analyzer.mailbox.capture(buffer)
        #expect(analyzer.read(sampleRate: 8000) == SpectrumFrame())
        buffer.frameLength = 512
        for channel in 0..<2 { for i in 0..<512 { buffer.floatChannelData![channel][i] = .nan } }
        analyzer.mailbox.capture(buffer)
        #expect(analyzer.read(sampleRate: 8000) == SpectrumFrame())
        analyzer.mailbox.capture(buffer)
        #expect(analyzer.read(sampleRate: 8000) == SpectrumFrame())
        for i in 0..<512 { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * Double(i) * 1000 / 8000)) * 0.1 }
        analyzer.mailbox.capture(buffer)
        analyzer.mailbox.capture(buffer)
        #expect(analyzer.read(sampleRate: 8000).levels.max()! > 0.5)
        #expect(analyzer.read(sampleRate: 8000).levels.suffix(5).allSatisfy { $0 == 0 })
        analyzer.reset()
        #expect(analyzer.read(sampleRate: 8000) == SpectrumFrame())
    }

    @Test func nativeDeviceTapAndDisable() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { try? FileManager.default.removeItem(at: media.url) }
        let backend = AVAudioEngineBackend()
        defer { backend.stop() }
        backend.setSpectrumEnabled(true)
        _ = try await backend.load(media)
        try backend.play()
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var peak: Float = 0
        while peak == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            peak = backend.spectrum().levels.max()!
        }
        #expect(peak > 0)
        try await backend.seek(to: 0.1)
        backend.setSpectrumEnabled(false)
        #expect(backend.spectrum() == SpectrumFrame())
        backend.setSpectrumEnabled(true)
        backend.stop()
        #expect(backend.spectrum() == SpectrumFrame())
    }
}

extension SpectrumTests {
    actor Gate {
        var continuation: CheckedContinuation<RuntimeCapabilities, Never>?
        func wait() async -> RuntimeCapabilities { await withCheckedContinuation { continuation = $0 } }
        var pending: Bool { continuation != nil }
        func release(_ value: RuntimeCapabilities = .init()) { continuation?.resume(returning: value); continuation = nil }
    }

    @Test func stopDuringAuthorizationAndRouteRevocation() async throws {
        let gate = Gate()
        let source = ClosureSourceProvider(identifier: "test", supportedFeatures: [.spectrum]) { _ in throw CadenzaError.unsupportedMedia }
        let kit = try Cadenza(configuration: .init(defaultProvider: "test", features: .init(spectrum: true)), providers: [source], runtimeCapabilities: { await gate.wait() })
        let backend = AVAudioEngineBackend(output: .manual)
        let service = kit.makeSpectrum(backend: backend)
        let pending = Task { try await service.read() }
        while !(await gate.pending) { await Task.yield() }
        service.stop()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(backend.spectrum() == SpectrumFrame())
        let accepted = Task { try await service.read() }
        while !(await gate.pending) { await Task.yield() }
        await gate.release()
        #expect(try await accepted.value == SpectrumFrame())
        let revoked = Task { try await service.read() }
        while !(await gate.pending) { await Task.yield() }
        await gate.release(.init(outputRoute: []))
        await #expect(throws: CadenzaError.featureUnavailable(.spectrum, .outputRoute)) { try await revoked.value }
        let dishonest = PlaybackTests.Backend(); dishonest.supportedFeatures = [.spectrum]
        let ordinary = try PlaybackTests().kit(flags: .init(spectrum: true), features: [.spectrum]).makeSpectrum(backend: dishonest)
        await #expect(throws: CadenzaError.featureUnavailable(.spectrum, .backend)) { try await ordinary.read() }
    }
}
