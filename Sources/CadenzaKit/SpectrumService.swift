import CadenzaDomain

/// Poll at a host-selected cadence (typically 30 Hz). Each read rechecks policy;
/// revocation stops capture. No timer or UI dependency is imposed on the host.
@MainActor
public final class SpectrumService {
    private let kit: Cadenza
    private let backend: any PlaybackBackend
    private var generation: UInt64 = 0
    init(kit: Cadenza, backend: any PlaybackBackend) { self.kit = kit; self.backend = backend }

    public func read(provider: String? = nil) async throws -> SpectrumFrame {
        generation &+= 1
        let token = generation
        do {
            if case let .unavailable(reason) = try await kit.availability(for: .spectrum, provider: provider) {
                throw CadenzaError.featureUnavailable(.spectrum, reason)
            }
            guard token == generation else { throw CancellationError() }
            guard backend.supportedFeatures.contains(.spectrum), let analyzer = backend as? any SpectrumBackend else {
                throw CadenzaError.featureUnavailable(.spectrum, .backend)
            }
            analyzer.setSpectrumEnabled(true)
            return analyzer.spectrum()
        } catch {
            if token == generation { stop() }
            throw error
        }
    }

    /// Always usable, including after policy revocation; invalidates in-flight reads.
    public func stop() {
        generation &+= 1
        (backend as? any SpectrumBackend)?.setSpectrumEnabled(false)
    }
}
