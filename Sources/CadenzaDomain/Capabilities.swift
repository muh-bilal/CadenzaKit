/// Cases are added only alongside their implemented service operation.
public enum Feature: String, CaseIterable, Hashable, Sendable {
    case sourceResolution
    case playback
    case seeking
}

public struct FeatureFlags: Equatable, Sendable {
    public var sourceResolution: Bool
    public var playback: Bool
    public var seeking: Bool
    public var queueManagement: Bool

    public init(sourceResolution: Bool = true, playback: Bool = true, seeking: Bool = true, queueManagement: Bool = true) {
        self.sourceResolution = sourceResolution
        self.playback = playback
        self.seeking = seeking
        self.queueManagement = queueManagement
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .sourceResolution: sourceResolution
        case .playback: playback
        case .seeking: seeking
        }
    }
}

public enum UnavailabilityReason: String, Equatable, Sendable {
    case disabled
    case source
    case backend
    case platform
    case outputRoute
}

public enum FeatureAvailability: Equatable, Sendable {
    case available
    case unavailable(UnavailabilityReason)
}

/// A fresh host/adapter snapshot. Resolution itself does not require an audio route.
/// Defaults support only the currently implemented source-resolution operation.
public struct RuntimeCapabilities: Equatable, Sendable {
    public var backend: Set<Feature>
    public var platform: Set<Feature>
    public var outputRoute: Set<Feature>

    public init(
        backend: Set<Feature> = [.sourceResolution, .playback, .seeking],
        platform: Set<Feature> = [.sourceResolution, .playback, .seeking],
        outputRoute: Set<Feature> = [.sourceResolution, .playback, .seeking]
    ) {
        self.backend = backend
        self.platform = platform
        self.outputRoute = outputRoute
    }

    /// Stable precedence makes denial reasons deterministic for clients.
    public func availability(for feature: Feature, flags: FeatureFlags, source: Set<Feature>) -> FeatureAvailability {
        guard flags.isEnabled(feature) else { return .unavailable(.disabled) }
        guard source.contains(feature) else { return .unavailable(.source) }
        guard backend.contains(feature) else { return .unavailable(.backend) }
        guard platform.contains(feature) else { return .unavailable(.platform) }
        guard outputRoute.contains(feature) else { return .unavailable(.outputRoute) }
        return .available
    }
}
