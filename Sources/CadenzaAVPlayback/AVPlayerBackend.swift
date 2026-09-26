import Foundation
import AVFoundation
import CadenzaDomain

/// Local-file AVPlayer backend. Remote URLs are rejected until the remote slice.
@MainActor
public final class AVPlayerBackend: PlaybackBackend {
    public let supportedFeatures: Set<Feature> = [.playback, .seeking]
    private let player = AVPlayer()
    private var generation: UInt64 = 0
    private var duration: Double = 0

    public init() {}

    public func load(_ resource: MediaResource) async throws -> Double {
        try Task.checkCancellation()
        guard resource.url.isFileURL else { throw CadenzaError.unsupportedURL }
        stop()
        let token = generation
        let asset = AVURLAsset(url: resource.url)
        let (playable, time) = try await asset.load(.isPlayable, .duration)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard playable else { throw CadenzaError.unsupportedMedia }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { throw CadenzaError.invalidDuration }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        duration = seconds
        return seconds
    }

    public func play() throws {
        guard player.currentItem != nil else { throw CadenzaError.noMediaLoaded }
        player.play()
    }

    public func pause() { player.pause() }

    public func seek(to position: Double) async throws {
        try Task.checkCancellation()
        guard player.currentItem != nil else { throw CadenzaError.noMediaLoaded }
        guard position.isFinite, position >= 0, position <= duration else { throw CadenzaError.invalidPosition }
        let token = generation
        let completed = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard completed else { throw CadenzaError.playbackFailure("seekInterrupted") }
    }

    public func stop() {
        generation &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        duration = 0
    }

    public func status() throws -> BackendStatus {
        guard let item = player.currentItem else { throw CadenzaError.noMediaLoaded }
        if let error = item.error { throw CadenzaError.playbackFailure(error.localizedDescription) }
        let position = player.currentTime().seconds
        return BackendStatus(position: position.isFinite ? max(0, position) : 0,
                             isPlaying: player.rate != 0,
                             ended: position >= duration)
    }
}
