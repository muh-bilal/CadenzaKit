import Foundation
import AVFoundation
import CadenzaDomain

/// Local files by default; finite HTTPS media requires explicit opt-in.
@MainActor
public final class AVPlayerBackend: PlaybackBackend {
    public let supportedFeatures: Set<Feature>
    private let player = AVPlayer()
    private var generation: UInt64 = 0
    private var duration: Double = 0
    private var reachedEnd = false
    private var endObserver: PlaybackEndObserver?
    private var loadingAsset: AVURLAsset?

    public init(allowRemote: Bool = false) {
        supportedFeatures = allowRemote ? [.playback, .systemPlayback, .seeking, .remotePlayback] : [.playback, .systemPlayback, .seeking]
    }

    public func load(_ resource: MediaResource) async throws -> Double {
        try Task.checkCancellation()
        if !resource.url.isFileURL {
            guard supportedFeatures.contains(.remotePlayback) else { throw CadenzaError.unsupportedURL }
            _ = try RemoteMediaURL(resource.url)
        }
        stop()
        let token = generation
        let asset = AVURLAsset(url: resource.url)
        loadingAsset = asset
        defer { if token == generation { loadingAsset = nil } }
        let (playable, time) = try await withTaskCancellationHandler {
            do { return try await asset.load(.isPlayable, .duration) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: { asset.cancelLoading() }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard playable else { throw CadenzaError.unsupportedMedia }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { throw CadenzaError.invalidDuration }
        let item = AVPlayerItem(asset: asset)
        let observer = PlaybackEndObserver { [weak self] in
            guard let self, self.generation == token else { return }
            self.reachedEnd = true
        }
        NotificationCenter.default.addObserver(observer, selector: #selector(PlaybackEndObserver.didEnd), name: .AVPlayerItemDidPlayToEndTime, object: item)
        endObserver = observer
        player.replaceCurrentItem(with: item)
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
        reachedEnd = position == duration
    }

    public func stop() {
        generation &+= 1
        loadingAsset?.cancelLoading()
        loadingAsset = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        reachedEnd = false
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
                             ended: reachedEnd, isBuffering: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }
}

/// Notification callbacks can arrive off-main. Only a Sendable actor-isolated
/// observer is captured by the task; no Notification or AVPlayerItem crosses actors.
@MainActor
private final class PlaybackEndObserver: NSObject {
    private let onEnd: @MainActor () -> Void

    init(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
        super.init()
    }

    @objc nonisolated func didEnd() {
        Task { @MainActor [weak self] in self?.onEnd() }
    }
}
