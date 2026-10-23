/// Cases are added only alongside their implemented service operation.
public enum Feature: String, CaseIterable, Hashable, Sendable {
    case sourceResolution
    case playback
    case seeking
    case remotePlayback
    case downloads
    case equalizer
    case systemPlayback
}

public struct FeatureFlags: Equatable, Sendable {
    public var sourceResolution: Bool
    public var playback: Bool
    public var seeking: Bool
    public var queueManagement: Bool
    public var shuffle: Bool
    public var repeatPlayback: Bool
    public var abLooping: Bool
    public var bookmarks: Bool
    public var persistence: Bool
    public var playlists: Bool
    public var playlistInterchange: Bool
    public var libraryIndexing: Bool
    public var smartPlaylists: Bool
    public var artwork: Bool
    public var artworkDownsampling: Bool
    public var artworkCaching: Bool
    public var artworkExport: Bool
    public var remotePlayback: Bool
    public var networkRecovery: Bool
    public var downloads: Bool
    public var storageManagement: Bool
    public var systemPlayback: Bool
    public var equalizer: Bool

    public init(
        sourceResolution: Bool = true,
        playback: Bool = true,
        seeking: Bool = true,
        queueManagement: Bool = true,
        shuffle: Bool = true,
        repeatPlayback: Bool = true,
        abLooping: Bool = true,
        bookmarks: Bool = true,
        persistence: Bool = true,
        playlists: Bool = true,
        playlistInterchange: Bool = true,
        libraryIndexing: Bool = true,
        smartPlaylists: Bool = true,
        artwork: Bool = true,
        artworkDownsampling: Bool = true,
        artworkCaching: Bool = true,
        artworkExport: Bool = true,
        remotePlayback: Bool = false,
        networkRecovery: Bool = false,
        downloads: Bool = false,
        storageManagement: Bool = false,
        systemPlayback: Bool = false,
        equalizer: Bool = false
    ) {
        self.sourceResolution = sourceResolution
        self.playback = playback
        self.seeking = seeking
        self.queueManagement = queueManagement
        self.shuffle = shuffle
        self.repeatPlayback = repeatPlayback
        self.abLooping = abLooping
        self.bookmarks = bookmarks
        self.persistence = persistence
        self.playlists = playlists
        self.playlistInterchange = playlistInterchange
        self.libraryIndexing = libraryIndexing
        self.smartPlaylists = smartPlaylists
        self.artwork = artwork
        self.artworkDownsampling = artworkDownsampling
        self.artworkCaching = artworkCaching
        self.artworkExport = artworkExport
        self.remotePlayback = remotePlayback
        self.networkRecovery = networkRecovery
        self.downloads = downloads
        self.storageManagement = storageManagement
        self.systemPlayback = systemPlayback
        self.equalizer = equalizer
    }

    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .sourceResolution: sourceResolution
        case .playback: playback
        case .seeking: seeking
        case .remotePlayback: remotePlayback
        case .downloads: downloads
        case .systemPlayback: systemPlayback
        case .equalizer: equalizer
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
/// Defaults permit implemented operations; hosts supply actual route/platform restrictions.
public struct RuntimeCapabilities: Equatable, Sendable {
    public var backend: Set<Feature>
    public var platform: Set<Feature>
    public var outputRoute: Set<Feature>

    public init(
        backend: Set<Feature> = [.sourceResolution, .playback, .seeking, .remotePlayback, .downloads, .equalizer, .systemPlayback],
        platform: Set<Feature> = [.sourceResolution, .playback, .seeking, .remotePlayback, .downloads, .equalizer, .systemPlayback],
        outputRoute: Set<Feature> = [.sourceResolution, .playback, .seeking, .remotePlayback, .downloads, .equalizer, .systemPlayback]
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
