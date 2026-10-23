import Foundation
import MediaPlayer
import CadenzaDomain

protocol PlaybackPositionEvent { var positionTime: TimeInterval { get } }
extension MPChangePlaybackPositionCommandEvent: PlaybackPositionEvent {}

/// Owns only its registrations on the process-wide MediaPlayer command center.
/// The most recently explicitly controlled player owns Now Playing information.
@MainActor
public final class AppleNowPlayingController: NowPlayingController {
    private static var owner: UUID?
    private let identity = UUID()
    private var handler: (@MainActor @Sendable (SystemPlaybackCommand) async -> Void)?
    private var last: PlaybackSnapshot?
    private var registered = false
    private var generation: UInt64 = 0
    private var cleanup: @MainActor @Sendable () -> Void = {}

    public init() {}
    deinit { let cleanup = cleanup; Task { @MainActor in cleanup() } }

    public func connect(_ handler: @escaping @MainActor @Sendable (SystemPlaybackCommand) async -> Void) { self.handler = handler }

    public func update(_ snapshot: PlaybackSnapshot, canSeek: Bool, force: Bool) {
        if case .failed = snapshot.state { clear(); return }
        guard let resource = snapshot.resource else { clear(); return }
        if !registered { install() }
        if force { Self.owner = identity }
        guard Self.owner == identity else { return }
        let old = last
        last = snapshot
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = canSeek
        // MediaPlayer extrapolates elapsed time. Publish transitions and seeks,
        // rather than resetting the system clock on every progress sample.
        if !force, let old, old.resource == snapshot.resource, old.state == snapshot.state,
           old.duration == snapshot.duration, snapshot.position >= old.position, snapshot.position - old.position < 1 { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: resource.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info[MPMediaItemPropertyArtist] = resource.artist
        info[MPMediaItemPropertyAlbumTitle] = resource.album
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = snapshot.state == .playing ? .playing : .paused
        #endif
    }

    public func clear() { generation &+= 1; cleanup(); cleanup = {}; registered = false; last = nil }

    // Also exercised independently of hardware delivery in adapter tests.
    private func receive(_ command: SystemPlaybackCommand, generation: UInt64) async {
        guard generation == self.generation, registered, Self.owner == identity else { return }
        await handler?(command)
    }

    func commandHandler(for command: SystemPlaybackCommand) -> @Sendable (Any) -> MPRemoteCommandHandlerStatus {
        let generation = generation
        return { @Sendable [weak self] event in
            let request: SystemPlaybackCommand
            if case .seek = command {
                guard let seek = event as? any PlaybackPositionEvent else { return .commandFailed }
                request = .seek(seek.positionTime)
            } else { request = command }
            Task { @MainActor [weak self] in await self?.receive(request, generation: generation) }
            // Acceptance for async execution; the facade exposes service errors.
            return .success
        }
    }

    private func install() {
        let center = MPRemoteCommandCenter.shared()
        let commands: [(MPRemoteCommand, SystemPlaybackCommand)] = [
            (center.playCommand, .play), (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .toggle), (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous), (center.changePlaybackPositionCommand, .seek(0))
        ]
        let tokens = commands.map { native, command in
            native.isEnabled = true
            let token = native.addTarget(handler: commandHandler(for: command))
            return (native, token)
        }
        let identity = identity
        cleanup = {
            for (native, token) in tokens { native.removeTarget(token) }
            if Self.owner == identity {
                Self.owner = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                #if os(macOS)
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                #endif
            }
        }
        registered = true
        Self.owner = identity
    }
}
