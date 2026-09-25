/// Cases are added only alongside their implemented service operation.
public enum Feature: String, CaseIterable, Hashable, Sendable {
    case sourceResolution
}

public struct FeatureFlags: Equatable, Sendable {
    public var sourceResolution: Bool

    public init(sourceResolution: Bool = true) {
        self.sourceResolution = sourceResolution
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .sourceResolution: sourceResolution
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
        backend: Set<Feature> = [.sourceResolution],
        platform: Set<Feature> = [.sourceResolution],
        outputRoute: Set<Feature> = [.sourceResolution]
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
