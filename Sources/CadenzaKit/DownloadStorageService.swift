import CadenzaDomain

public struct DownloadStorageService: Sendable {
    private let flags: FeatureFlags
    private let store: any ManagedOfflineAudioStore
    init(flags: FeatureFlags, store: any ManagedOfflineAudioStore) { self.flags = flags; self.store = store }
    public func usage() async throws -> OfflineStorageUsage { try authorize(); return try await store.usage() }
    public func remove(_ id: MediaID) async throws -> OfflineStorageChange { try authorize(); return try await store.remove(id) }
    public func trim(to maximumBytes: Int, protecting: Set<MediaID> = []) async throws -> OfflineStorageChange {
        try authorize()
        return try await store.trim(to: maximumBytes, protecting: protecting)
    }
    public func reconcile() async throws -> OfflineStorageReconciliation { try authorize(); return try await store.reconcile() }
    private func authorize() throws {
        try Task.checkCancellation()
        guard flags.storageManagement else { throw CadenzaError.storageManagementDisabled }
        guard flags.downloads else { throw CadenzaError.downloadsDisabled }
        guard flags.persistence else { throw CadenzaError.persistenceDisabled }
    }
}
