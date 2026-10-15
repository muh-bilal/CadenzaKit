import Foundation
import AVFoundation
import CadenzaDomain

/// Decoded local audio. Manual output uses the same graph without device I/O.
@MainActor
public final class AVAudioEngineBackend: PlaybackBackend {
    public enum Output: Sendable { case device, manual }
    public struct RenderedAudio {
        public let status: AVAudioEngineManualRenderingStatus
        public let buffer: AVAudioPCMBuffer
    }

    public let supportedFeatures: Set<Feature> = [.playback, .seeking]
    public let output: Output
    public static let maximumRenderFrames: AVAudioFrameCount = 4096
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var generation: UInt64 = 0
    private var completed = false

    public init(output: Output = .device) {
        self.output = output
        engine.attach(player)
    }

    public func load(_ resource: MediaResource) async throws -> Double {
        try Task.checkCancellation()
        guard resource.url.isFileURL else { throw CadenzaError.unsupportedURL }
        stop()
        let file = try AVAudioFile(forReading: resource.url)
        guard file.length > 0, file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0 else { throw CadenzaError.invalidDuration }
        guard file.length <= AVAudioFramePosition(UInt32.max) else { throw CadenzaError.unsupportedMedia }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        if output == .manual {
            engine.disableManualRenderingMode()
            try engine.enableManualRenderingMode(.offline, format: file.processingFormat, maximumFrameCount: Self.maximumRenderFrames)
        }
        try Task.checkCancellation()
        self.file = file
        schedule(file, from: 0)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public func play() throws {
        guard file != nil else { throw CadenzaError.noMediaLoaded }
        if !engine.isRunning { try engine.start() }
        player.play()
    }

    public func pause() { player.pause() }

    public func seek(to position: Double) async throws {
        try Task.checkCancellation()
        guard let file else { throw CadenzaError.noMediaLoaded }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard position.isFinite, position >= 0, position <= duration else { throw CadenzaError.invalidPosition }
        let playing = player.isPlaying
        generation &+= 1
        player.stop()
        schedule(file, from: min(file.length, AVAudioFramePosition((position * file.processingFormat.sampleRate).rounded())))
        if playing { player.play() }
    }

    public func stop() {
        generation &+= 1
        player.stop()
        engine.stop()
        engine.reset()
        file = nil
        startFrame = 0
        completed = false
    }

    public func status() throws -> BackendStatus {
        guard let file else { throw CadenzaError.noMediaLoaded }
        let elapsed = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0)?.sampleTime } ?? 0
        let frame = min(file.length, startFrame + max(0, elapsed))
        let ended = output == .manual ? frame == file.length : completed
        return BackendStatus(position: Double(frame) / file.processingFormat.sampleRate,
                             isPlaying: player.isPlaying && !ended, ended: ended)
    }

    /// The caller drives manual output and handles retry/partial-render statuses.
    /// Device-output backends reject this operation.
    public func render(frames: AVAudioFrameCount) throws -> RenderedAudio {
        try Task.checkCancellation()
        guard output == .manual, file != nil, engine.isRunning,
              frames > 0, frames <= Self.maximumRenderFrames else { throw CadenzaError.invalidRenderRequest }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else { throw CadenzaError.invalidRenderRequest }
        let status = try engine.renderOffline(frames, to: buffer)
        return RenderedAudio(status: status, buffer: buffer)
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition) {
        startFrame = frame
        completed = frame == file.length
        if frame < file.length {
            let token = generation
            player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.completed = true
                }
            }
        }
    }
}
