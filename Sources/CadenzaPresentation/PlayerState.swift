import CadenzaDomain

/// Display data only. Playback, queue policy and feature enforcement stay in CadenzaKit.
public struct PlayerState: Equatable, Sendable {
    public var snapshot: PlaybackSnapshot
    public var subtitle: String
    public var context: String
    public var footer: String
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    public init(snapshot: PlaybackSnapshot, subtitle: String = "", context: String = "", footer: String = "", shuffle: Bool = false, repeatMode: RepeatMode = .off) {
        self.snapshot = snapshot; self.subtitle = subtitle; self.context = context; self.footer = footer
        self.shuffle = shuffle; self.repeatMode = repeatMode
    }
    public var isPlaying: Bool { snapshot.state == .playing }
    public var duration: Double { snapshot.duration.isFinite ? max(0, snapshot.duration) : 0 }
    public var position: Double { snapshot.position.isFinite ? min(duration, max(0, snapshot.position)) : 0 }
}
