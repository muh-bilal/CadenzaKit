public struct OfflineStorageUsage: Equatable, Sendable {
    public let catalogBytes: Int
    public let availableBytes: Int
    public let orphanBytes: Int
    public let missingIDs: [MediaID]
    public init(catalogBytes: Int, availableBytes: Int, orphanBytes: Int, missingIDs: [MediaID]) {
        self.catalogBytes = catalogBytes; self.availableBytes = availableBytes
        self.orphanBytes = orphanBytes; self.missingIDs = missingIDs
    }
}

public struct OfflineStorageChange: Equatable, Sendable {
    public let removedIDs: [MediaID]
    public let retainedFiles: [String]
    public let remainingCatalogBytes: Int
    public init(removedIDs: [MediaID], retainedFiles: [String], remainingCatalogBytes: Int) {
        self.removedIDs = removedIDs; self.retainedFiles = retainedFiles; self.remainingCatalogBytes = remainingCatalogBytes
    }
}

public struct OfflineStorageReconciliation: Equatable, Sendable {
    public let missingIDs: [MediaID]
    public let removedOrphans: [String]
    public let retainedOrphans: [String]
    public init(missingIDs: [MediaID], removedOrphans: [String], retainedOrphans: [String]) {
        self.missingIDs = missingIDs; self.removedOrphans = removedOrphans; self.retainedOrphans = retainedOrphans
    }
}

public protocol ManagedOfflineAudioStore: OfflineAudioStore {
    func usage() async throws -> OfflineStorageUsage
    func remove(_ id: MediaID) async throws -> OfflineStorageChange
    func trim(to maximumBytes: Int, protecting: Set<MediaID>) async throws -> OfflineStorageChange
    func reconcile() async throws -> OfflineStorageReconciliation
}
