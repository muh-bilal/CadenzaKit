import SwiftUI
import CadenzaDomain
import CadenzaPresentation

/// Convenience alias; the projection is independently available without SwiftUI.
public typealias PlayerState = CadenzaPresentation.PlayerState

public enum PlayerControl: String, CaseIterable, Sendable {
    case back, more, favorite, previous, playPause, next, shuffle, repeatMode, queue, equalizer
}

public enum PlayerIcon: String, CaseIterable, Sendable {
    case back, more, favorite, previous, play, pause, next, shuffle, repeatAll, repeatOne, artwork
    public var systemName: String {
        switch self {
        case .back: "chevron.down"
        case .more: "ellipsis"
        case .favorite: "heart"
        case .previous: "backward.end"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .next: "forward.end"
        case .shuffle: "shuffle"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .artwork: "music.note"
        }
    }
}

public enum PlayerText: String, CaseIterable, Sendable {
    case nowPlaying = "Now playing", untitled = "Choose a track", back = "Back", more = "More"
    case favorite = "Favorite", previous = "Previous", play = "Play", pause = "Pause", next = "Next"
    case shuffleOn = "Shuffle on", shuffleOff = "Shuffle off"
    case repeatOff = "Repeat off", repeatAll = "Repeat all", repeatOne = "Repeat one"
    case queue = "Up next", equalizer = "Equalizer"
    case spectrum = "Audio spectrum"
    case position = "Playback position", artwork = "Album artwork"
}

@MainActor
public struct PlayerStrings {
    /// Resolve every UI/accessibility label in the host's preferred table or locale.
    public var resolve: (PlayerText) -> String
    public var time: (Double) -> String
    nonisolated public static func localized(_ text: PlayerText) -> String { NSLocalizedString(text.rawValue, bundle: .module, comment: "") }
    public init(resolve: @escaping (PlayerText) -> String = PlayerStrings.localized, time: @escaping (Double) -> String = { Duration.seconds($0.isFinite ? max(0, $0) : 0).formatted(.time(pattern: .minuteSecond)) }) {
        self.resolve = resolve; self.time = time
    }
}

@MainActor
public struct PlayerImages {
    /// Supports SF Symbols, Image("asset", bundle: hostBundle), or decoded host images.
    public var resolve: (PlayerIcon) -> Image
    public init(resolve: @escaping (PlayerIcon) -> Image = { Image(systemName: $0.systemName) }) { self.resolve = resolve }
}

public struct PlayerColors {
    public var background: Color
    public var foreground: Color = .primary
    public var secondary: Color = .secondary
    public var accent: Color
    public var onAccent: Color = .white
    public var progressTrack: Color = .primary.opacity(0.22)
    public var focusRing: Color = .primary
    public var controlBackground: Color = .primary.opacity(0.08)
    public var artworkBackground: Color = .secondary.opacity(0.08)
    public var artworkShadow: Color = .black.opacity(0.16)
    public init(background: Color = Color(red: 0.975, green: 0.974, blue: 0.961), accent: Color = Color(red: 0.13, green: 0.40, blue: 0.34), onAccent: Color = .white) {
        self.background = background; self.accent = accent; self.onAccent = onAccent
    }
}

public struct PlayerFonts {
    public var title: Font = .system(.title2, design: .default).weight(.semibold)
    public var subtitle: Font = .subheadline
    public var context: Font = .system(.caption2).weight(.semibold)
    public var caption: Font = .caption
    public var button: Font = .subheadline
    public init() {}
}

/// All dimensions used by the built-in layout. Custom component/layout builders
/// can replace any behavior that is not expressible as a design token.
public struct PlayerMetrics {
    public var padding: CGFloat = 24
    public var spacing: CGFloat = 24
    public var detailSpacing: CGFloat = 8
    public var contextTracking: CGFloat = 2
    public var artworkRadius: CGFloat = 12
    public var artworkAspectRatio: CGFloat = 1
    public var artworkMaximum: CGFloat = 420
    public var artworkShadowRadius: CGFloat = 24
    public var artworkShadowY: CGFloat = 16
    public var seekIncrement: Double = 5
    public var controlHorizontalPadding: CGFloat = 16
    public var progressHeight: CGFloat = 8
    public var focusRingWidth: CGFloat = 4
    public var focusRingPadding: CGFloat = 6
    #if os(tvOS)
    public var targetSize: CGFloat = 80
    public var iconSize: CGFloat = 36
    public var primarySize: CGFloat = 96
    public var primaryRadius: CGFloat = 48
    #else
    public var targetSize: CGFloat = 44
    public var iconSize: CGFloat = 18
    public var primarySize: CGFloat = 58
    public var primaryRadius: CGFloat = 29
    #endif
    public var maximumWidth: CGFloat = 480
    public var wideBreakpoint: CGFloat = 750
    public var wideArtworkWidth: CGFloat = 460
    public var wideContentWidth: CGFloat = 600
    public init() {}
}

public struct PlayerAppearance {
    public var light = PlayerColors()
    public var dark = PlayerColors(background: Color(red: 0.055, green: 0.075, blue: 0.07), accent: Color(red: 0.40, green: 0.76, blue: 0.64), onAccent: .black)
    public var fonts = PlayerFonts()
    public var metrics = PlayerMetrics()
    public init() {}
    public func colors(for scheme: ColorScheme) -> PlayerColors { scheme == .dark ? dark : light }
}

@MainActor
public struct PlayerActions {
    /// Missing handlers hide optional controls and disable essential controls.
    /// Supplying a handler never grants a capability; the service must authorize it.
    public var controls: [PlayerControl: () -> Void]
    public var seek: ((Double) -> Void)?
    public init(controls: [PlayerControl: () -> Void] = [:], seek: ((Double) -> Void)? = nil) { self.controls = controls; self.seek = seek }
    public func callback(for control: PlayerControl) -> () -> Void { controls[control] ?? Self.unavailable }
    nonisolated public static func unavailable() {}
    public func positionBinding(_ state: PlayerState) -> Binding<Double> {
        Binding(get: { state.position }, set: { value in
            guard value.isFinite else { return }
            seek?(min(state.duration, max(0, value)))
        })
    }
}

public enum PlayerArrangement: Sendable { case automatic, vertical, horizontal }
public enum PlayerLayout: Sendable { case standard, empty }
public enum PlayerPart: CaseIterable, Sendable { case background, header, artwork, metadata, progress, transport, accessories, footer }

@MainActor
public struct PlayerContext {
    public var state: PlayerState
    public var appearance: PlayerAppearance
    public var strings: PlayerStrings
    public var images: PlayerImages
    public var actions: PlayerActions
    public init(state: PlayerState, appearance: PlayerAppearance = .init(), strings: PlayerStrings = .init(), images: PlayerImages = .init(), actions: PlayerActions = .init()) {
        self.state = state; self.appearance = appearance; self.strings = strings; self.images = images; self.actions = actions
    }
}

@MainActor
public struct PlayerButtonContext {
    public let control: PlayerControl
    public let label: String
    public let icon: PlayerIcon?
    public let selected: Bool
    public let enabled: Bool
    public let perform: () -> Void
}

@MainActor
public struct PlayerComponents {
    public var layout: ((PlayerContext) -> AnyView)?
    public var parts: [PlayerPart: (PlayerContext) -> AnyView] = [:]
    public var button: ((PlayerButtonContext) -> AnyView)?
    public init() {}
    public mutating func setLayout<Content: View>(@ViewBuilder content: @escaping (PlayerContext) -> Content) {
        layout = { AnyView(content($0)) }
    }
    public mutating func set<Content: View>(_ part: PlayerPart, @ViewBuilder content: @escaping (PlayerContext) -> Content) {
        parts[part] = { AnyView(content($0)) }
    }
    public mutating func setButton<Content: View>(@ViewBuilder content: @escaping (PlayerButtonContext) -> Content) {
        button = { AnyView(content($0)) }
    }
}
