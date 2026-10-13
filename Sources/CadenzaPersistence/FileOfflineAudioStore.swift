import Foundation
import CryptoKit
import CadenzaDomain

/// One store actor per dedicated directory. tvOS storage is purgeable.
public actor FileOfflineAudioStore: OfflineAudioStore {
    private let directory: URL
    private var saving = false
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw CadenzaError.unsupportedURL }
        self.directory = directory
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
            let encoded = try JSONEncoder().encode(archive)
            try Task.checkCancellation()
            try encoded.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            committed = true
            return item
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
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
