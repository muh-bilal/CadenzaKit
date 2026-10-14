import Foundation
import CryptoKit
import CadenzaDomain

/// One store actor per dedicated directory. tvOS storage is purgeable.
public actor FileOfflineAudioStore: ManagedOfflineAudioStore {
    private let directory: URL
    private let maximumStoredBytes: Int
    private let commitIndex: @Sendable (Data, URL) throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void
    private var saving = false
    public init(directory: URL, maximumStoredBytes: Int = 1_073_741_824,
                commitIndex: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                removeFile: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard directory.isFileURL else { throw CadenzaError.unsupportedURL }
        guard maximumStoredBytes >= 0 else { throw CadenzaError.invalidStorageConfiguration }
        self.directory = directory
        self.maximumStoredBytes = maximumStoredBytes
        self.commitIndex = commitIndex
        self.removeFile = removeFile
    }

    public func all() throws -> [OfflineAudio] {
        try Task.checkCancellation()
        return try read().items.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func resource(_ id: MediaID) throws -> MediaResource {
        guard let item = try all().first(where: { $0.id == id }) else { throw CadenzaError.resourceNotFound(id) }
        let url = fileURL(id, extension: item.fileExtension)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CadenzaError.resourceNotFound(id) }
        return MediaResource(id: id, url: url, title: item.metadata.title)
    }

    public func save(_ data: Data, id: MediaID, source: MediaResource, provider: String, createdAt: Date, metadata: any MetadataReader) async throws -> OfflineAudio {
        try Task.checkCancellation()
        guard !saving else { throw CadenzaError.operationInProgress }
        saving = true
        defer { saving = false }
        var archive = try read()
        guard !archive.items.contains(where: { $0.id == id }) else { throw CadenzaError.duplicateDownload }
        let used = try total(archive.items.map(\.byteCount))
        guard used <= maximumStoredBytes, data.count <= maximumStoredBytes - used else { throw CadenzaError.storageLimitExceeded }
        let ext = source.url.pathExtension.lowercased()
        guard !data.isEmpty, OfflineAudio.supportedExtensions.contains(ext) else { throw CadenzaError.invalidDownload }
        let final = fileURL(id, extension: ext)
        let staging = final.deletingLastPathComponent().appendingPathComponent("." + final.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staging, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: staging) }
            let details = try await metadata.metadata(at: staging)
            try Task.checkCancellation()
            let item = try OfflineAudio(id: id, sourceMediaID: source.id, sourceProvider: provider, metadata: details,
                                        byteCount: data.count, fileExtension: ext, createdAt: createdAt)
            try FileManager.default.moveItem(at: staging, to: final)
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: final) } }
            archive.items.append(item)
            try write(archive)
            committed = true
            return item
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.storageFailure(String(describing: error)) }
    }

    public func usage() throws -> OfflineStorageUsage {
        try Task.checkCancellation()
        let archive = try read()
        let files = try inventory()
        let names = Set(archive.items.map { fileURL($0.id, extension: $0.fileExtension).lastPathComponent })
        let missing = archive.items.filter { files[fileURL($0.id, extension: $0.fileExtension).lastPathComponent] == nil }.map(\.id).sorted { $0.rawValue < $1.rawValue }
        return OfflineStorageUsage(catalogBytes: try total(archive.items.map(\.byteCount)),
                                   availableBytes: try total(files.filter { names.contains($0.key) }.map(\.value)),
                                   orphanBytes: try total(files.filter { !names.contains($0.key) }.map(\.value)), missingIDs: missing)
    }

    public func remove(_ id: MediaID) throws -> OfflineStorageChange {
        try authorizeMutation()
        let archive = try read()
        guard archive.items.contains(where: { $0.id == id }) else { throw CadenzaError.resourceNotFound(id) }
        return try remove([id], from: archive)
    }

    public func trim(to maximumBytes: Int, protecting: Set<MediaID>) throws -> OfflineStorageChange {
        try authorizeMutation()
        guard maximumBytes >= 0 else { throw CadenzaError.invalidStorageConfiguration }
        let archive = try read()
        var remaining = try total(archive.items.map(\.byteCount))
        let candidates = archive.items.filter { !protecting.contains($0.id) }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
        }
        var selected = Set<MediaID>()
        for item in candidates where remaining > maximumBytes { selected.insert(item.id); remaining -= item.byteCount }
        return try remove(selected, from: archive)
    }

    public func reconcile() throws -> OfflineStorageReconciliation {
        try authorizeMutation()
        var archive = try read()
        let files = try inventory()
        let missing = archive.items.filter { files[fileURL($0.id, extension: $0.fileExtension).lastPathComponent] == nil }.map(\.id)
        let missingSet = Set(missing)
        archive.items.removeAll { missingSet.contains($0.id) }
        if !missing.isEmpty { try write(archive) }
        let retained = Set(archive.items.map { fileURL($0.id, extension: $0.fileExtension).lastPathComponent })
        var removed: [String] = [], failed: [String] = []
        for name in files.keys.sorted() where !retained.contains(name) {
            do { try removeFile(directory.appendingPathComponent(name)); removed.append(name) }
            catch { failed.append(name) }
        }
        return OfflineStorageReconciliation(missingIDs: missing.sorted { $0.rawValue < $1.rawValue }, removedOrphans: removed, retainedOrphans: failed)
    }

    private func remove(_ ids: Set<MediaID>, from original: Archive) throws -> OfflineStorageChange {
        var archive = original
        archive.items.removeAll { ids.contains($0.id) }
        if !ids.isEmpty { try write(archive) }
        var retained: [String] = []
        for item in original.items where ids.contains(item.id) {
            let url = fileURL(item.id, extension: item.fileExtension)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { retained.append(url.lastPathComponent); continue }
                try removeFile(url)
            }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { /* Already purged. */ }
            catch { retained.append(url.lastPathComponent) }
        }
        return OfflineStorageChange(removedIDs: ids.sorted { $0.rawValue < $1.rawValue }, retainedFiles: retained.sorted(), remainingCatalogBytes: try total(archive.items.map(\.byteCount)))
    }

    private func authorizeMutation() throws {
        try Task.checkCancellation()
        guard !saving else { throw CadenzaError.operationInProgress }
    }

    private func write(_ archive: Archive) throws {
        try Task.checkCancellation()
        do { try commitIndex(JSONEncoder().encode(archive), directory.appendingPathComponent("index.json")) }
        catch { throw CadenzaError.storageFailure(String(describing: error)) }
    }

    private func total(_ values: [Int]) throws -> Int {
        try values.reduce(0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { throw CadenzaError.storageLimitExceeded }
            return sum
        }
    }

    private func inventory() throws -> [String: Int] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            var result: [String: Int] = [:]
            for url in urls {
                let name = url.lastPathComponent
                let plain = name.hasPrefix(".") ? String(name.dropFirst()) : name
                let parts = plain.split(separator: ".")
                guard parts.count == 2, parts[0].count == 64, parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), OfflineAudio.supportedExtensions.contains(String(parts[1])) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize { result[name] = size }
            }
            return result
        } catch CocoaError.fileReadNoSuchFile { return [:] }
        catch { throw CadenzaError.storageFailure(String(describing: error)) }
    }

    private func fileURL(_ id: MediaID, extension ext: String) -> URL {
        let name = SHA256.hash(data: Data(id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + "." + ext)
    }

    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable { var version = 1; var items: [OfflineAudio] = [] }
    private func read() throws -> Archive {
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("index.json")) }
        catch CocoaError.fileReadNoSuchFile { return Archive() }
        catch { throw CadenzaError.storageFailure(String(describing: error)) }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else { throw CadenzaError.unsupportedStoreVersion(version) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard Set(archive.items.map(\.id)).count == archive.items.count else { throw CadenzaError.corruptStore }
            return archive
        } catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.corruptStore }
    }
}
