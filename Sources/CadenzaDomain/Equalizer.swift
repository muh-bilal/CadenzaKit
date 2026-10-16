import Foundation

public struct EqualizerBand: Equatable, Sendable, Codable {
    public let frequency: Float
    public let gain: Float
    public let bandwidth: Float
    public init(frequency: Float, gain: Float, bandwidth: Float = 1) throws {
        guard frequency.isFinite, (20...20_000).contains(frequency), gain.isFinite, (-24...24).contains(gain),
              bandwidth.isFinite, (0.05...5).contains(bandwidth) else { throw CadenzaError.invalidEqualizerSettings }
        self.frequency = frequency; self.gain = gain; self.bandwidth = bandwidth
    }
    private enum CodingKeys: String, CodingKey { case frequency, gain, bandwidth }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(frequency: c.decode(Float.self, forKey: .frequency), gain: c.decode(Float.self, forKey: .gain), bandwidth: c.decode(Float.self, forKey: .bandwidth))
    }
}

public struct EqualizerSettings: Equatable, Sendable, Codable {
    public let bands: [EqualizerBand]
    public let preamp: Float
    public let isBypassed: Bool
    public init() { bands = []; preamp = 0; isBypassed = true }
    public init(bands: [EqualizerBand], preamp: Float = 0, isBypassed: Bool = false) throws {
        guard bands.count <= 32, Set(bands.map(\.frequency)).count == bands.count,
              preamp.isFinite, (-24...24).contains(preamp) else { throw CadenzaError.invalidEqualizerSettings }
        self.bands = bands; self.preamp = preamp; self.isBypassed = isBypassed
    }
    private enum CodingKeys: String, CodingKey { case bands, preamp, isBypassed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bands: c.decode([EqualizerBand].self, forKey: .bands), preamp: c.decode(Float.self, forKey: .preamp), isBypassed: c.decode(Bool.self, forKey: .isBypassed))
    }
}

public struct EqualizerPreset: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let name: String
    public let settings: EqualizerSettings
    public init(id: UUID, name: String, settings: EqualizerSettings) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CadenzaError.invalidEqualizerPreset }
        self.id = id; self.name = name; self.settings = settings
    }
    private enum CodingKeys: String, CodingKey { case id, name, settings }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name), settings: c.decode(EqualizerSettings.self, forKey: .settings))
    }
}

@MainActor
public protocol EqualizerBackend: PlaybackBackend {
    var equalizerSettings: EqualizerSettings { get }
    func applyEqualizer(_ settings: EqualizerSettings) throws
}
