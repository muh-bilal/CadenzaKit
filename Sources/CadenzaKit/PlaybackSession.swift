import CadenzaDomain

/// Deterministic command state machine. Call refresh() to sample progress/EOF;
/// no hidden polling timer or playback task is started by constructing a session.
@MainActor
public final class PlaybackSession {
    public private(set) var loopRange: LoopRange?
    private let kit: Cadenza
    private let backend: any PlaybackBackend
    private var generation: UInt64 = 0
    private var busy = false
    private var provider: String?
    private var resource: MediaResource?
    private var duration: Double = 0
    private var position: Double = 0
    private var state: PlaybackState = .idle

    init(kit: Cadenza, backend: any PlaybackBackend) {
        self.kit = kit
        self.backend = backend
    }

    public var snapshot: PlaybackSnapshot {
        PlaybackSnapshot(state: state, resource: resource, position: position, duration: duration)
    }

    public var sourceProvider: String? {
        resource == nil ? nil : (provider ?? kit.configuration.defaultProvider)
    }

    /// Optional resume seek and autoplay belong to the same serialized operation.
    public func load(_ id: MediaID, provider: String? = nil, at resumePosition: Double? = nil, autoplay: Bool = false) async throws {
        try Task.checkCancellation()
        guard !busy else { throw CadenzaError.operationInProgress }
        stop()
        let token = generation
        busy = true
        state = .loading(id)
        self.provider = provider
        defer { if token == generation { busy = false } }
        do {
            try await authorize(.playback)
            try check(token)
            let media = try await kit.resolve(id, provider: provider)
            try check(token)
            let loadedDuration = try await backend.load(media)
            try check(token)
            guard loadedDuration.isFinite, loadedDuration > 0 else { throw CadenzaError.invalidDuration }
            if let resumePosition {
                guard resumePosition.isFinite, resumePosition >= 0, resumePosition <= loadedDuration else { throw CadenzaError.invalidPosition }
                try await authorize(.seeking)
                try check(token)
                try await backend.seek(to: resumePosition)
                try check(token)
                position = resumePosition
            }
            if autoplay {
                try await authorize(.playback)
                try check(token)
                try backend.play()
            }
            resource = media
            duration = loadedDuration
            state = autoplay ? .playing : .ready
        } catch {
            try fail(error, token: token)
        }
    }

    public func play() async throws {
        try await perform(.playback, also: state == .ended ? [.seeking] : []) { token in
            if self.state == .ended {
                try await self.backend.seek(to: 0)
                try self.check(token)
                self.position = 0
            }
            try self.backend.play()
            self.state = .playing
        }
    }

    /// Pause and stop remain available when policy revokes playback permission.
    public func pause() throws {
        guard !busy else { throw CadenzaError.operationInProgress }
        try requireLoaded()
        backend.pause()
        try sample()
        if state != .ended { state = .paused }
    }

    public func seek(to position: Double) async throws {
        guard position.isFinite, position >= 0, position <= duration else { throw CadenzaError.invalidPosition }
        try await perform(.seeking) { token in
            try await self.backend.seek(to: position)
            try self.check(token)
            self.position = position
            if position == self.duration {
                self.backend.pause()
                self.state = .ended
            }
            else if self.state == .ended { self.state = .paused }
        }
    }

    public func stop() {
        generation &+= 1
        backend.stop()
        busy = false
        resource = nil
        provider = nil
        duration = 0
        position = 0
        state = .idle
        loopRange = nil
    }

    public func setLoop(_ range: LoopRange?) async throws {
        try Task.checkCancellation()
        guard !busy else { throw CadenzaError.operationInProgress }
        guard let range else { loopRange = nil; return }
        guard kit.configuration.features.abLooping else { throw CadenzaError.loopingDisabled }
        try requireLoaded()
        guard range.end <= duration else { throw CadenzaError.invalidLoopRange }
        try await perform(.seeking) { _ in self.loopRange = range }
    }

    public func refresh() async throws {
        try Task.checkCancellation()
        let wasPlaying = state == .playing
        try sample()
        if let range = loopRange, wasPlaying, state == .ended || position >= range.end || position < range.start {
            let token = generation
            do {
                try await perform(.seeking, also: [.playback]) { token in
                    try await self.backend.seek(to: range.start)
                    try self.check(token)
                    self.position = range.start
                    try self.backend.play()
                    self.state = .playing
                }
            } catch {
                if token == generation {
                    backend.pause()
                    if case .failed = state { /* Preserve the structured backend failure. */ }
                    else { state = .paused }
                }
                throw error
            }
        }
    }

    private func sample() throws {
        guard !busy else { throw CadenzaError.operationInProgress }
        try requireLoaded()
        do {
            let status = try backend.status()
            guard status.position.isFinite, status.position >= 0 else { throw CadenzaError.invalidPosition }
            position = min(status.position, duration)
            if status.ended { state = .ended }
            else if status.isPlaying { state = .playing }
        } catch {
            try fail(error, token: generation)
        }
    }

    private func requireLoaded() throws {
        guard resource != nil else { throw CadenzaError.noMediaLoaded }
        if case .failed = state { throw CadenzaError.noMediaLoaded }
    }

    private func authorize(_ feature: Feature) async throws {
        if case let .unavailable(reason) = try await kit.availability(for: feature, provider: provider) {
            throw CadenzaError.featureUnavailable(feature, reason)
        }
        guard backend.supportedFeatures.contains(feature) else { throw CadenzaError.featureUnavailable(feature, .backend) }
    }

    private func perform(_ feature: Feature, also additional: [Feature] = [], action: (UInt64) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !busy else { throw CadenzaError.operationInProgress }
        try requireLoaded()
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        // Authorization failures preserve the previous usable session state.
        try await authorize(feature)
        for feature in additional { try await authorize(feature) }
        try check(token)
        do {
            try await action(token)
            try check(token)
        } catch {
            try fail(error, token: token)
        }
    }

    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func fail(_ error: any Error, token: UInt64) throws -> Never {
        guard token == generation else { throw CancellationError() }
        if error is CancellationError {
            stop()
            throw CancellationError()
        }
        let structured = (error as? CadenzaError) ?? .playbackFailure(String(describing: error))
        backend.stop()
        state = .failed(structured)
        throw structured
    }
}
