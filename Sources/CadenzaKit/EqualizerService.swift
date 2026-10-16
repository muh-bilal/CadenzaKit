import Foundation
import CadenzaDomain

public struct EqualizerService: Sendable {
    private let kit: Cadenza
    private let backend: any PlaybackBackend
    private let store: any DocumentStore
    init(kit: Cadenza, backend: any PlaybackBackend, store: any DocumentStore) { self.kit = kit; self.backend = backend; self.store = store }

    @MainActor
    public var settings: EqualizerSettings {
        get throws { try authorize(); return try equalizerBackend().equalizerSettings }
    }

    @MainActor
    public func apply(_ settings: EqualizerSettings, provider: String? = nil) async throws {
        try authorize()
        if case let .unavailable(reason) = try await kit.availability(for: .equalizer, provider: provider) { throw CadenzaError.featureUnavailable(.equalizer, reason) }
        guard backend.supportedFeatures.contains(.equalizer) else { throw CadenzaError.featureUnavailable(.equalizer, .backend) }
        try set(settings, on: equalizerBackend())
    }

    /// Disabling active DSP remains possible after capability/policy revocation.
    @MainActor
    public func bypass() throws {
        let backend = try equalizerBackend()
        let previous = backend.equalizerSettings
        try set(EqualizerSettings(bands: previous.bands, preamp: previous.preamp, isBypassed: true), on: backend)
    }

    @MainActor
    public func applyPreset(_ id: UUID, provider: String? = nil) async throws {
        guard let preset = try await presets().first(where: { $0.id == id }) else { throw CadenzaError.equalizerPresetNotFound }
        try await apply(preset.settings, provider: provider)
    }

    public func presets() async throws -> [EqualizerPreset] {
        try authorize(persistence: true)
        let data = try await store.read()
        try Task.checkCancellation()
        return try Self.decode(data).presets.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }

    /// Explicit upsert permits editing a preset while preserving its identity.
    public func savePreset(_ preset: EqualizerPreset) async throws {
        try authorize(persistence: true)
        try await store.update { data in
            var archive = try Self.decode(data)
            archive.presets.removeAll { $0.id == preset.id }
            archive.presets.append(preset)
            return try JSONEncoder().encode(archive)
        }
    }

    public func deletePreset(_ id: UUID) async throws {
        try authorize(persistence: true)
        try await store.update { data in
            var archive = try Self.decode(data)
            guard archive.presets.contains(where: { $0.id == id }) else { throw CadenzaError.equalizerPresetNotFound }
            archive.presets.removeAll { $0.id == id }
            return try JSONEncoder().encode(archive)
        }
    }

    @MainActor
    private func equalizerBackend() throws -> any EqualizerBackend {
        guard let value = backend as? any EqualizerBackend else { throw CadenzaError.featureUnavailable(.equalizer, .backend) }
        return value
    }

    @MainActor
    private func set(_ settings: EqualizerSettings, on backend: any EqualizerBackend) throws {
        do { try backend.applyEqualizer(settings) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.equalizerFailure(String(describing: error)) }
    }

    private func authorize(persistence: Bool = false) throws {
        try Task.checkCancellation()
        guard kit.configuration.features.equalizer else { throw CadenzaError.equalizerDisabled }
        if persistence, !kit.configuration.features.persistence { throw CadenzaError.persistenceDisabled }
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable { var version = 1; var presets: [EqualizerPreset] = [] }
    private static func decode(_ data: Data?) throws -> Archive {
        guard let data else { return Archive() }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else { throw CadenzaError.unsupportedStoreVersion(version) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard Set(archive.presets.map(\.id)).count == archive.presets.count else { throw CadenzaError.corruptStore }
            return archive
        } catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.corruptStore }
    }
}
