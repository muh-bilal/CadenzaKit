import Foundation
import Testing
import CadenzaDomain
@testable import CadenzaSystemPlayback
#if os(iOS) || os(tvOS)
import AVFAudio
#endif

@Suite(.serialized) @MainActor
struct AppleSystemPlaybackTests {
    @Test func nativeConfigurationAndHostRequirements() throws {
        let controller = AppleSystemPlaybackController()
        #if os(iOS) || os(tvOS)
        // Package test hosts do not declare background audio.
        #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .platform)) { try controller.prepareForPlayback() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["CFBundleIdentifier": "org.cadenzakit.background-test", "UIBackgroundModes": ["audio"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        try AppleSystemPlaybackController(bundle: bundle).prepareForPlayback()
        #expect(AVAudioSession.sharedInstance().category == .playback)
        #expect(AVAudioSession.sharedInstance().mode == .default)
        try AVAudioSession.sharedInstance().setActive(false)
        #else
        try controller.prepareForPlayback()
        #endif
    }

    @Test func errorsAndCancellation() async throws {
        let denied = AppleSystemPlaybackController { throw CadenzaError.featureUnavailable(.systemPlayback, .platform) }
        #expect(throws: CadenzaError.featureUnavailable(.systemPlayback, .platform)) { try denied.prepareForPlayback() }
        struct Failure: Error {}
        let broken = AppleSystemPlaybackController { throw Failure() }
        #expect(throws: CadenzaError.playbackFailure(String(describing: Failure()))) { try broken.prepareForPlayback() }
        var calls = 0
        let controller = AppleSystemPlaybackController { calls += 1 }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try controller.prepareForPlayback()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 0)
    }
}
