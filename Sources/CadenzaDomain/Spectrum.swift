/// A fixed, bounded spectrum: 32 logarithmic bands from 20 Hz to 20 kHz.
/// Levels map -80...0 dBFS to 0...1; bands above Nyquist remain zero.
public struct SpectrumFrame: Equatable, Sendable {
    public static let bandCount = 32
    public let levels: [Float]
    public init(levels: [Float] = Array(repeating: 0, count: bandCount)) {
        self.levels = (0..<Self.bandCount).map { index in
            let value = index < levels.count ? levels[index] : 0
            return value.isFinite ? min(1, max(0, value)) : 0
        }
    }
}

@MainActor
public protocol SpectrumBackend: PlaybackBackend {
    func setSpectrumEnabled(_ enabled: Bool)
    func spectrum() -> SpectrumFrame
}
