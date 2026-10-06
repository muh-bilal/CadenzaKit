import Foundation
import AVFoundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaPersistence
import CadenzaAVPlayback

@MainActor
struct LibraryIntegrationTests {
    @Test func multipleFilesHaveStableSortedIdentitiesAcrossScans() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: media.url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Z.wav", "A.wav"] {
            try FileManager.default.copyItem(at: media.url, to: root.appendingPathComponent(name))
        }
        let namespace = try MediaID("sorted")
        let files = try await LocalFileCatalog().files(at: root, namespace: namespace)
        #expect(files.map(\.url.lastPathComponent) == ["A.wav", "Z.wav"])
        let library = try PlaybackTests().kit().makeLibrary(root: root, namespace: namespace, store: BookmarkTestStore(), catalog: LocalFileCatalog(), metadata: AVMetadataReader())
        #expect(try await library.scan().updated == 2)
        #expect(try await library.all().map(\.id) == files.map(\.id))
        #expect(try await library.scan().reused == 2)
    }

    @Test func directoryIndexPersistsReusesMovesAndResolvesRealFiles() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for url in [root, moved, index, media.url] { try? FileManager.default.removeItem(at: url) }
        }
        let folder = root.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = folder.appendingPathComponent("Track.WAV")
        try FileManager.default.copyItem(at: media.url, to: track)
        try Data("ignore".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.wav"), withDestinationURL: track)
        let catalog = LocalFileCatalog(extensions: ["WAV"])
        let namespace = try MediaID("library")
        #expect(try await catalog.files(at: root, namespace: namespace).count == 1)
        let kit = try PlaybackTests().kit()
        let library = kit.makeLibrary(root: root, namespace: namespace, store: try AtomicFileStore(fileURL: index), catalog: LocalFileCatalog(), metadata: AVMetadataReader())
        #expect(try await library.scan().updated == 1)
        let item = try #require(try await library.all().first)
        #expect(item.metadata?.title == "Track")
        #expect(abs((item.metadata?.duration ?? 0) - 0.5) < 0.01)
        #expect(try await library.scan().reused == 1)
        try FileManager.default.moveItem(at: root, to: moved)
        let reopened = kit.makeLibrary(root: moved, namespace: namespace, store: try AtomicFileStore(fileURL: index), catalog: LocalFileCatalog(), metadata: AVMetadataReader())
        #expect(try await reopened.scan().reused == 1)
        let provider = CatalogFileSource(identifier: "indexed", lookup: { try await reopened.resource($0) })
        let playerKit = try Cadenza(configuration: .init(defaultProvider: "indexed"), providers: [provider])
        let session = playerKit.makeSession(backend: AVPlayerBackend())
        try await session.load(item.id)
        #expect(session.snapshot.resource?.url.standardizedFileURL == moved.appendingPathComponent("Album/Track.WAV").standardizedFileURL)
        #expect(session.snapshot.duration > 0)
        session.stop()
        let movedTrack = moved.appendingPathComponent("Album/Track.WAV")
        try FileManager.default.removeItem(at: movedTrack)
        #expect(try await reopened.scan().missing == 1)
        await #expect(throws: CadenzaError.resourceNotFound(item.id)) { try await playerKit.resolve(item.id) }
    }

    @Test func taggedMetadataIsExtractedByAVFoundation() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        let tagged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { for url in [media.url, tagged] { try? FileManager.default.removeItem(at: url) } }
        let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: media.url), presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = tagged
        exporter.outputFileType = .m4a
        var metadata: [AVMetadataItem] = []
        for (identifier, value) in [(AVMetadataIdentifier.commonIdentifierTitle, "Tagged title"), (.commonIdentifierArtist, "Tagged artist"), (.commonIdentifierAlbumName, "Tagged album"), (.commonIdentifierDescription, "Unused description")] {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            metadata.append(item)
        }
        exporter.metadata = metadata
        await exporter.export()
        #expect(exporter.status == .completed)
        let result = try await AVMetadataReader().metadata(at: tagged)
        #expect(result.title == "Tagged title")
        #expect(result.artist == "Tagged artist")
        #expect(result.album == "Tagged album")
        #expect(result.duration > 0)
    }

    @Test func realAdaptersRejectInvalidLocationsMediaAndCancellation() async throws {
        let catalog = LocalFileCatalog()
        let namespace = try MediaID("test")
        let remote = try #require(URL(string: "https://example.invalid/media"))
        await #expect(throws: CadenzaError.unsupportedURL) { try await catalog.files(at: remote, namespace: namespace) }
        await #expect(throws: CadenzaError.unsupportedURL) { try await AVMetadataReader().metadata(at: remote) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: CadenzaError.self) { try await catalog.files(at: missing, namespace: namespace) }
        try Data("invalid audio".utf8).write(to: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        await #expect(throws: CadenzaError.unreadableFile) { try await catalog.files(at: missing, namespace: namespace) }
        await #expect(throws: CadenzaError.self) { try await AVMetadataReader().metadata(at: missing) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.files(at: missing, namespace: namespace)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AVMetadataReader().metadata(at: missing)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
