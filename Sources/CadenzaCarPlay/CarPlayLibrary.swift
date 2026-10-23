import Foundation
import CadenzaDomain
import CadenzaPlayer
#if os(iOS)
import CarPlay
#endif

/// Host-owned catalog metadata. The occurrence ID permits duplicate tracks.
public struct CarPlayTrack: Equatable, Sendable {
    public let entry: QueueEntry
    public let title: String
    public let subtitle: String?
    public init(entry: QueueEntry, title: String, subtitle: String? = nil) {
        self.entry = entry; self.title = title; self.subtitle = subtitle
    }
}

public struct CarPlaySection: Equatable, Sendable {
    public let title: String
    public let tracks: [CarPlayTrack]
    public init(title: String, tracks: [CarPlayTrack]) { self.title = title; self.tracks = tracks }
}

/// UI-independent catalog lifecycle. Retain alongside the app's shared player.
/// Disconnect cancels pending work without stopping an established listening session.
@MainActor
public final class CarPlayLibrary {
    public private(set) var sections: [CarPlaySection] = []
    private let player: CadenzaPlayer
    private let catalog: @Sendable () async throws -> [CarPlaySection]
    private var loading: Task<[CarPlaySection], Error>?
    private var selecting: Task<Void, Error>?
    private var generation = 0
    private var busy = false

    public init(player: CadenzaPlayer, catalog: @escaping @Sendable () async throws -> [CarPlaySection]) {
        self.player = player; self.catalog = catalog
    }
    deinit { loading?.cancel(); selecting?.cancel() }

    public func reload() async throws {
        guard !busy else { throw CadenzaError.operationInProgress }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        try await authorize()
        guard token == generation else { throw CancellationError() }
        let task = Task { try await catalog() }
        loading = task
        defer { if token == generation { loading = nil } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let ids = result.flatMap(\.tracks).map(\.entry.id)
        guard Set(ids).count == ids.count else { throw CadenzaError.duplicateQueueEntry }
        sections = result
    }

    public func select(_ occurrence: UUID) async throws {
        guard !busy else { throw CadenzaError.operationInProgress }
        let entries = sections.flatMap(\.tracks).map(\.entry)
        guard let entry = entries.first(where: { $0.id == occurrence }) else { throw CadenzaError.queueEntryNotFound }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        try await authorize(provider: entry.provider)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let task = Task { try await player.play(entries: entries, startingAt: occurrence) }
        selecting = task
        defer { if token == generation { selecting = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard token == generation else { throw CancellationError() }
    }

    public func disconnect() {
        generation &+= 1
        loading?.cancel(); selecting?.cancel()
        loading = nil; selecting = nil; sections = []; busy = false
    }

    private func authorize(provider: String? = nil) async throws {
        try Task.checkCancellation()
        guard player.services.configuration.features.carPlay else { throw CadenzaError.carPlayDisabled }
        if case let .unavailable(reason) = try await player.services.availability(for: .systemPlayback, provider: provider) {
            throw CadenzaError.featureUnavailable(.systemPlayback, reason)
        }
    }

    #if os(iOS)
    /// Call after reload. Hosts own CPInterfaceController presentation and errors.
    /// Strings are supplied by the host so localization and branding stay flexible.
    public func makeTemplate(title: String, emptyTitle: String, emptySubtitle: String,
        onPlaybackStarted: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void) -> CPListTemplate {
        let sections = sections.map { section in
            CPListSection(items: section.tracks.map { track in
                let item = CPListItem(text: track.title, detailText: track.subtitle)
                item.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        defer { completion() }
                        guard let self else { return }
                        do { try await self.select(track.entry.id); onPlaybackStarted() }
                        catch is CancellationError { }
                        catch { onFailure(error) }
                    }
                }
                return item
            }, header: section.title, sectionIndexTitle: nil)
        }
        let template = CPListTemplate(title: title, sections: sections)
        template.emptyViewTitleVariants = [emptyTitle]
        template.emptyViewSubtitleVariants = [emptySubtitle]
        return template
    }
    #endif
}
