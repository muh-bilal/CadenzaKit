import Foundation
import MediaPlayer
import Testing
import CadenzaDomain
import CadenzaPlayer
@testable import CadenzaSystemPlayback

@Suite(.serialized) @MainActor struct NowPlayingTests {
    final class Sink: NowPlayingController {
        var handler: (@MainActor @Sendable (SystemPlaybackCommand) async -> Void)?
        var snapshots: [PlaybackSnapshot] = []
        var clears = 0
        func connect(_ handler: @escaping @MainActor @Sendable (SystemPlaybackCommand) async -> Void) { self.handler = handler }
        func update(_ snapshot: PlaybackSnapshot, canSeek: Bool, force: Bool) { snapshots.append(snapshot) }
        func clear() { clears += 1 }
    }
    actor Policy {
        var value = RuntimeCapabilities()
        func deny() { value.outputRoute.remove(.systemPlayback) }
    }

    @Test func facadeCommandsAreAuthorizedAndDisabledHasNoEffects() async throws {
        let backend = SystemPlaybackTests.Backend(), sink = Sink(), policy = Policy()
        let source = PlayerFacadeTests().source()
        let player = try CadenzaPlayer(source: source, features: .init(systemPlayback: true), backend: backend,
            systemPlayback: SystemPlaybackTests.Platform(), clock: PlayerFacadeTests.StoppedClock(), nowPlaying: sink,
            runtimeCapabilities: { await policy.value })
        let entries = try ["a", "b"].map { QueueEntry(id: UUID(), mediaID: try MediaID($0)) }
        try await player.play(entries: entries)
        let send = try #require(sink.handler)
        await send(.pause); #expect(player.snapshot.state == .paused)
        await send(.play); #expect(player.snapshot.state == .playing)
        await send(.toggle); #expect(player.snapshot.state == .paused)
        await send(.toggle); #expect(player.snapshot.state == .playing)
        backend.buffering = true
        await player.refresh(); #expect(player.snapshot.state == .buffering)
        await send(.toggle); #expect(player.snapshot.state == .paused)
        backend.buffering = false
        await send(.play)
        await send(.seek(3)); #expect(player.snapshot.position == 3)
        await send(.next); #expect(player.snapshot.resource?.id == entries[1].mediaID)
        await send(.previous); #expect(player.snapshot.resource?.id == entries[0].mediaID)
        await send(.seek(-1)); #expect(player.failure == .invalidPosition)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await send(.next)
        }
        await cancelled.value
        #expect(player.snapshot.resource?.id == entries[0].mediaID)
        await policy.deny()
        await send(.next)
        #expect(player.failure == .featureUnavailable(.systemPlayback, .outputRoute))
        await send(.toggle); #expect(player.snapshot.state == .paused)
        await send(.pause); #expect(player.snapshot.state == .paused)
        player.stop()
        let unused = Sink()
        let disabled = try CadenzaPlayer(source: source, backend: backend, clock: PlayerFacadeTests.StoppedClock(), nowPlaying: unused)
        try await disabled.play(MediaID("a")); disabled.stop()
        #expect(unused.handler == nil && unused.snapshots.isEmpty && unused.clears == 0)
    }

    func snapshot(position: Double = 2, state: PlaybackState = .playing, title: String = "Track") throws -> PlaybackSnapshot {
        .init(state: state, resource: .init(id: try MediaID("a"), url: URL(fileURLWithPath: "/a.wav"), title: title, artist: "Artist", album: "Album"), position: position, duration: 20)
    }

    @Test func failedSystemSeekPreservesBackendErrorAcrossProgressTicks() async throws {
        let backend = PlaybackTests.Backend(), sink = Sink()
        backend.supportedFeatures.insert(.systemPlayback)
        let player = try CadenzaPlayer(source: PlayerFacadeTests().source(), features: .init(systemPlayback: true),
            backend: backend, systemPlayback: SystemPlaybackTests.Platform(), clock: PlayerFacadeTests.StoppedClock(), nowPlaying: sink)
        try await player.play(MediaID("a"))
        backend.failure = CadenzaError.unsupportedMedia
        await sink.handler?(.seek(3))
        #expect(player.failure == .unsupportedMedia)
        #expect(player.snapshot.state == .failed(.unsupportedMedia))
        await player.refresh()
        await player.refresh()
        #expect(player.failure == .unsupportedMedia)
        #expect(player.snapshot.state == .failed(.unsupportedMedia))
        backend.failure = nil
        try await player.play(MediaID("b"))
        #expect(player.failure == nil && player.snapshot.state == .playing)
        player.stop()
    }

    @Test func facadeDefaultsToNativeSystemOutput() async throws {
        let player = try CadenzaPlayer(source: PlayerFacadeTests().source(), features: .init(systemPlayback: true),
            backend: SystemPlaybackTests.Backend(), systemPlayback: SystemPlaybackTests.Platform(), clock: PlayerFacadeTests.StoppedClock())
        try await player.play(MediaID("Native metadata"))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Native metadata")
        player.stop()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @Test func nativeMetadataOwnershipAndClockExtrapolation() throws {
        let first = AppleNowPlayingController(), second = AppleNowPlayingController()
        defer { first.clear(); second.clear() }
        let center = MPNowPlayingInfoCenter.default()
        first.update(try snapshot(), canSeek: true, force: false)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Track")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 20)
        first.update(try snapshot(position: 2.25), canSeek: false, force: false)
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 2)
        #expect(!MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        first.update(try snapshot(position: 1), canSeek: true, force: false)
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 1)
        first.update(try snapshot(position: 5), canSeek: true, force: false)
        first.update(try snapshot(state: .paused), canSeek: true, force: false)
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        second.update(try snapshot(title: "Second"), canSeek: true, force: true)
        first.update(try snapshot(), canSeek: true, force: false)
        first.clear()
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Second")
        second.update(try snapshot(state: .failed(.unsupportedMedia)), canSeek: false, force: false)
        #expect(center.nowPlayingInfo == nil)
        second.update(.init(state: .idle, resource: nil, position: 0, duration: 0), canSeek: false, force: false)
    }

    struct SeekEvent: PlaybackPositionEvent {
        var positionTime: TimeInterval { 7 }
    }

    @Test func nativeEventTranslationAndStaleRegistrationRejection() async throws {
        let controller = AppleNowPlayingController()
        defer { controller.clear() }
        controller.update(try snapshot(), canSeek: true, force: true)
        let seek = controller.commandHandler(for: .seek(0))
        #expect(seek(NSObject()) == .commandFailed)
        var received: [SystemPlaybackCommand] = []
        for command in [SystemPlaybackCommand.play, .pause, .toggle, .next, .previous, .seek(7)] {
            await withCheckedContinuation { continuation in
                controller.connect { value in received.append(value); continuation.resume() }
                let event: Any = command == .seek(7) ? SeekEvent() : NSObject()
                #expect(controller.commandHandler(for: command)(event) == .success)
            }
        }
        #expect(received == [.play, .pause, .toggle, .next, .previous, .seek(7)])
        let stale = controller.commandHandler(for: .next)
        controller.clear()
        controller.update(try snapshot(), canSeek: true, force: true)
        await withCheckedContinuation { continuation in
            controller.connect { value in #expect(value == .pause); continuation.resume() }
            #expect(stale(NSObject()) == .success)
            #expect(controller.commandHandler(for: .pause)(NSObject()) == .success)
        }
    }
}
