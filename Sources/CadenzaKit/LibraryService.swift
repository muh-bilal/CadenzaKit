import Foundation
import CadenzaDomain

public actor LibraryService {
    private let flags: FeatureFlags
    private let root: URL
    private let namespace: MediaID
    private let store: any DocumentStore
    private let catalog: any FileCatalog
    private let reader: any MetadataReader
    private var scanning = false

    init(flags: FeatureFlags, root: URL, namespace: MediaID, store: any DocumentStore, catalog: any FileCatalog, reader: any MetadataReader) {
        self.flags = flags
        self.root = root
        self.namespace = namespace
        self.store = store
        self.catalog = catalog
        self.reader = reader
    }

    public func all() async throws -> [LibraryItem] {
        try authorize()
        let data = try await store.read()
        try Task.checkCancellation()
        return try decode(data).items.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func search(_ query: String, includeUnavailable: Bool = false) async throws -> [LibraryItem] {
        let query = Self.fold(query)
        return try await all().filter { item in
            guard includeUnavailable || item.availability == .available else { return false }
            let text = [item.metadata?.title ?? "", item.metadata?.artist ?? "", item.metadata?.album ?? ""].joined(separator: " ")
            return query.isEmpty || Self.fold(text).contains(query)
        }
    }

    public func resource(_ id: MediaID) async throws -> MediaResource {
        guard let item = try await all().first(where: { $0.id == id }), item.availability != .missing else { throw CadenzaError.resourceNotFound(id) }
        guard item.availability == .available, let metadata = item.metadata else { throw CadenzaError.unreadableFile }
        return MediaResource(id: id, url: item.url, title: metadata.title)
    }

    public func scan() async throws -> LibraryScanReport {
        try authorize()
        guard !scanning else { throw CadenzaError.operationInProgress }
        scanning = true
        defer { scanning = false }
        let original = try await store.read()
        let prior = try decode(original)
        let files = try await catalog.files(at: root, namespace: namespace)
        guard Set(files.map(\.id)).count == files.count else { throw CadenzaError.invalidLibraryItem }
        let previous = Dictionary(uniqueKeysWithValues: prior.items.map { ($0.id, $0) })
        var items: [LibraryItem] = []
        var failures: [LibraryScanFailure] = []
        var updated = 0, reused = 0
        for file in files {
            try Task.checkCancellation()
            if let old = previous[file.id], old.fingerprint == file.fingerprint, old.metadata != nil, old.availability != .unreadable {
                items.append(try LibraryItem(id: file.id, url: file.url, fingerprint: file.fingerprint, metadata: old.metadata, availability: .available))
                reused += 1
                continue
            }
            do {
                let metadata = try await reader.metadata(at: file.url)
                try Task.checkCancellation()
                items.append(try LibraryItem(id: file.id, url: file.url, fingerprint: file.fingerprint, metadata: metadata, availability: .available))
                updated += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let error = (error as? CadenzaError) ?? .libraryFailure(String(describing: error))
                failures.append(.init(id: file.id, error: error))
                items.append(try LibraryItem(id: file.id, url: file.url, fingerprint: file.fingerprint, metadata: previous[file.id]?.metadata, availability: .unreadable))
            }
        }
        let found = Set(files.map(\.id))
        let missing = prior.items.filter { !found.contains($0.id) }
        for item in missing {
            items.append(try LibraryItem(id: item.id, url: item.url, fingerprint: item.fingerprint, metadata: item.metadata, availability: .missing))
        }
        let archive = Archive(namespace: namespace, items: items.sorted { $0.id.rawValue < $1.id.rawValue })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(archive)
        try Task.checkCancellation()
        try await store.update { current in
            guard current == original else { throw CadenzaError.libraryChangedDuringScan }
            return encoded
        }
        return LibraryScanReport(scanned: files.count, updated: updated, reused: reused, missing: missing.count, failures: failures)
    }

    private func authorize() throws {
        try Task.checkCancellation()
        guard flags.libraryIndexing else { throw CadenzaError.libraryDisabled }
        guard flags.persistence else { throw CadenzaError.persistenceDisabled }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable {
        var version = 1
        let namespace: MediaID
        let items: [LibraryItem]
    }

    private func decode(_ data: Data?) throws -> Archive {
        guard let data else { return Archive(namespace: namespace, items: []) }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else { throw CadenzaError.unsupportedStoreVersion(version) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.namespace == namespace else { throw CadenzaError.libraryNamespaceMismatch }
            guard Set(archive.items.map(\.id)).count == archive.items.count else { throw CadenzaError.corruptStore }
            return archive
        } catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.corruptStore }
    }
}
