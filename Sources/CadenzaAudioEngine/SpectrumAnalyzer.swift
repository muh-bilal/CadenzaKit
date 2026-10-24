import Foundation
import AVFoundation
import Accelerate
import CadenzaDomain

/// Single bounded mailbox. The audio callback never waits, allocates storage,
/// dispatches tasks, or performs FFT work. Contention drops a visualization block.
final class SpectrumMailbox: @unchecked Sendable {
    static let count = 1024
    private let lock = NSLock()
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: count)
    private var cursor = 0
    private var ready = false
    init() { samples.initialize(repeating: 0, count: Self.count) }
    deinit { samples.deinitialize(count: Self.count); samples.deallocate() }
    func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0, lock.try() else { return }
        defer { lock.unlock() }
        // Inspect at most 4096 frames regardless of device format.
        // Analyze the first channel: stable phase, no stereo cancellation or
        // nonlinear channel switching. Hosts can provide a mono mix upstream.
        for frame in 0..<min(4096, Int(buffer.frameLength)) {
            let sample = channels[0][frame * buffer.stride]
            samples[cursor] = sample.isFinite ? sample : 0
            cursor += 1
            if cursor == Self.count { cursor = 0; ready = true }
        }
    }
    func read() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard ready else { return nil }
        // Copy in chronological order on the consumer, never in the audio callback.
        return (0..<Self.count).map { samples[(cursor + $0) % Self.count] }
    }
}

final class SpectrumAnalyzer {
    private(set) var mailbox = SpectrumMailbox()
    func reset() { mailbox = SpectrumMailbox() }
    private let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    deinit { vDSP_destroy_fftsetup(setup) }
    func read(sampleRate: Double) -> SpectrumFrame {
        guard let samples = mailbox.read() else { return SpectrumFrame() }
        let count = SpectrumMailbox.count
        var real = samples.enumerated().map { index, value in
            value * Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count)))
        }
        var imaginary = Array(repeating: Float(0), count: count)
        var levels = Array(repeating: Float(0), count: SpectrumFrame.bandCount)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                for bin in 1..<(count / 2) {
                    let frequency = Double(bin) * sampleRate / Double(count)
                    guard frequency >= 20, frequency < 20_000 else { continue }
                    let band = Int(log(frequency / 20) / log(1000) * Double(SpectrumFrame.bandCount))
                    let magnitude = hypot(r[bin], i[bin]) * 4 / Float(count)
                    let level = max(0, min(1, (20 * log10(max(0.0001, magnitude)) + 80) / 80))
                    levels[band] = max(levels[band], level)
                }
            }
        }
        return SpectrumFrame(levels: levels)
    }
}
