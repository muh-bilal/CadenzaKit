import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaDownloads
import CadenzaPersistence
import CadenzaLocalSources
import CadenzaRemoteSources
import CadenzaAVPlayback

actor TestAudioTransfer: AudioTransfer {
    var data: Data
    var calls = 0
    var failure: (any Error)?
    var gate: PlaybackTests.Gate?
    init(_ data: Data) { self.data = data }
    func setFailure(_ error: (any Error)?) { failure = error }
    func setGate(_ gate: PlaybackTests.Gate?) { self.gate = gate }
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        calls += 1
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return data
    }
}

struct DownloadValidationReader: MetadataReader {
    let action: @Sendable () async throws -> Void
    func metadata(at url: URL) async throws -> MediaMetadata {
        try await action()
        return try MediaMetadata(title: "Downloaded", duration: 1)
    }
}

final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/failure" { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if url.path.hasPrefix("/redirect") {
            let target = URL(string: url.path == "/redirect-http" ? "http://fixture.invalid/small" : "https://fixture.invalid/small")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response: URLResponse = url.path == "/non-http" ? URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil) :
            HTTPURLResponse(url: url, statusCode: url.path == "/missing" ? 404 : 200, httpVersion: nil,
                            headerFields: url.path == "/large-header" ? ["Content-Length": "1000"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path != "/empty" { client?.urlProtocol(self, didLoad: Data([1, 2, 3])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct AudioDownloadTests {
    func kit(flags: FeatureFlags = .init(downloads: true), allowed: Bool = true, ext: String = "wav") throws -> Cadenza {
        let media = MediaResource(id: try MediaID("remote"), url: URL(string: "https://example.com/track.\(ext)")!, title: "Track")
        let source = try HTTPSCatalogSource(resources: [media.id: media], allowsDownloads: allowed)
        return try Cadenza(configuration: .init(defaultProvider: source.identifier, features: flags), providers: [source])
    }

    @Test func boundedHTTPTransferHandlesResponsesRedirectsAndFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let transfer = URLSessionAudioTransfer(configuration: configuration)
        func url(_ path: String) -> URL { URL(string: "https://fixture.invalid/" + path)! }
        #expect(try await transfer.fetch(url("small"), maximumBytes: 3) == Data([1, 2, 3]))
        #expect(try await transfer.fetch(url("redirect-https"), maximumBytes: 3) == Data([1, 2, 3]))
        for (path, error) in [("missing", CadenzaError.downloadHTTPStatus(404)), ("redirect-http", .downloadHTTPStatus(302)), ("empty", .invalidDownload), ("non-http", .invalidDownload), ("large-header", .downloadTooLarge)] {
            await #expect(throws: error) { try await transfer.fetch(url(path), maximumBytes: 3) }
        }
        await #expect(throws: CadenzaError.downloadTooLarge) { try await transfer.fetch(url("small"), maximumBytes: 2) }
        await #expect(throws: CadenzaError.invalidDownload) { try await transfer.fetch(url("small"), maximumBytes: 0) }
        await #expect(throws: CadenzaError.self) { try await transfer.fetch(url("failure"), maximumBytes: 3) }
        let task = Task { try await transfer.fetch(url("small"), maximumBytes: 3) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func persistentDownloadRecreationAndOfflinePlayback() async throws {
        let media = try LocalPlaybackIntegrationTests().fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: media.url) }
        let transfer = TestAudioTransfer(try Data(contentsOf: media.url))
        let store = try FileOfflineAudioStore(directory: folder)
        let service = try kit().makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader(), now: { Date(timeIntervalSince1970: 1) })
        #expect(try await service.all().isEmpty)
        let id = try MediaID("offline/../safe")
        let first = try await service.download(MediaID("remote"), as: id)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1))
        #expect(first.metadata.title == "Track")
        let expectedByteCount = try Data(contentsOf: media.url).count
        #expect(first.byteCount == expectedByteCount)
        _ = try await service.download(MediaID("remote"), provider: "https", as: MediaID("another"))
        #expect(try await service.all().map(\.id.rawValue) == ["another", "offline/../safe"])
        await #expect(throws: CadenzaError.duplicateDownload) { try await service.download(MediaID("remote"), as: id) }
        let recreated = try kit().makeDownloads(transfer: transfer, store: FileOfflineAudioStore(directory: folder), metadata: AVMetadataReader())
        #expect(try await recreated.all().count == 2)
        let provider = CatalogFileSource(identifier: "offline", lookup: { try await recreated.resource($0) })
        let offlineKit = try Cadenza(configuration: .init(defaultProvider: "offline"), providers: [provider])
        let session = offlineKit.makeSession(backend: AVPlayerBackend())
        try await session.load(id)
        #expect(session.snapshot.resource?.url.isFileURL == true)
        #expect(abs(session.snapshot.duration - 0.5) < 0.01)
        session.stop()
        let resource = try await recreated.resource(id)
        try FileManager.default.removeItem(at: resource.url)
        await #expect(throws: CadenzaError.resourceNotFound(id)) { try await recreated.resource(id) }
        let absent = try MediaID("absent")
        await #expect(throws: CadenzaError.resourceNotFound(absent)) { try await recreated.resource(absent) }
    }

    @Test func flagsLimitsCancellationAndInvalidMediaDoNotPublish() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        let transfer = TestAudioTransfer(Data([1, 2]))
        let id = try MediaID("saved"), remote = try MediaID("remote")
        for (flags, error) in [(FeatureFlags(downloads: false), CadenzaError.downloadsDisabled), (.init(persistence: false, downloads: true), .persistenceDisabled)] {
            let service = try kit(flags: flags).makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader())
            await #expect(throws: error) { try await service.download(remote, as: id) }
            await #expect(throws: error) { try await service.all() }
            await #expect(throws: error) { try await service.resource(id) }
        }
        let denied = try kit(allowed: false).makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader())
        await #expect(throws: CadenzaError.featureUnavailable(.downloads, .source)) { try await denied.download(remote, as: id) }
        #expect(await transfer.calls == 0)
        let bounded = try kit().makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader(), maximumBytes: 1)
        await #expect(throws: CadenzaError.downloadTooLarge) { try await bounded.download(remote, as: id) }
        #expect(throws: CadenzaError.invalidDownload) { try kit().makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader(), maximumBytes: 0) }
        let service = try kit().makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader())
        await #expect(throws: CadenzaError.self) { try await service.download(remote, as: id) }
        #expect(try await service.all().isEmpty)
        let invalidType = try kit(ext: "m3u8").makeDownloads(transfer: transfer, store: store, metadata: AVMetadataReader())
        await #expect(throws: CadenzaError.invalidDownload) { try await invalidType.download(remote, as: id) }
        struct Failure: Error, CustomStringConvertible { var description: String { "transfer" } }
        await transfer.setFailure(Failure())
        await #expect(throws: CadenzaError.downloadFailure("transfer")) { try await service.download(remote, as: id) }
        await transfer.setFailure(CadenzaError.downloadHTTPStatus(500))
        await #expect(throws: CadenzaError.downloadHTTPStatus(500)) { try await service.download(remote, as: id) }
        await transfer.setFailure(CancellationError())
        await #expect(throws: CancellationError.self) { try await service.download(remote, as: id) }
        await transfer.setFailure(nil)
        let gate = PlaybackTests.Gate()
        await transfer.setGate(gate)
        let task = Task { try await service.download(remote, as: id) }
        await gate.waitUntilEntered()
        task.cancel(); gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func storeFailuresSchemasAndCancelledValidationPreserveFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        let source = MediaResource(id: try MediaID("remote"), url: URL(string: "https://example.com/file.wav")!, title: "Track")
        let id = try MediaID("id")
        let now = Date(timeIntervalSince1970: 1)
        let cancelReader = DownloadValidationReader { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelled = Task { try await store.save(Data([1]), id: id, source: source, provider: "https", createdAt: now, metadata: cancelReader) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let index = folder.appendingPathComponent("index.json")
        let failingCommit = DownloadValidationReader { try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false) }
        await #expect(throws: CadenzaError.self) { try await store.save(Data([1]), id: id, source: source, provider: "https", createdAt: now, metadata: failingCommit) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["index.json"])
        await #expect(throws: CadenzaError.self) { try await store.all() }
        try FileManager.default.removeItem(at: index)
        for (data, error) in [(Data("bad".utf8), CadenzaError.corruptStore), (Data(#"{"version":9,"items":[]}"#.utf8), .unsupportedStoreVersion(9))] {
            try data.write(to: index)
            await #expect(throws: error) { try await store.all() }
            #expect(try Data(contentsOf: index) == data)
        }
        let metadata = try MediaMetadata(title: "A", duration: 1)
        let item = try OfflineAudio(id: id, sourceMediaID: id, sourceProvider: "source", metadata: metadata, byteCount: 1, fileExtension: "wav", createdAt: now)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        try JSONSerialization.data(withJSONObject: ["version": 1, "items": [object, object]]).write(to: index)
        await #expect(throws: CadenzaError.corruptStore) { try await store.all() }
        #expect(throws: CadenzaError.invalidDownload) { try OfflineAudio(id: id, sourceMediaID: id, sourceProvider: "", metadata: metadata, byteCount: 0, fileExtension: "../bad", createdAt: now) }
        #expect(throws: CadenzaError.unsupportedURL) { try FileOfflineAudioStore(directory: URL(string: "https://example.com")!) }
    }

    @Test func overlappingImportsRejectAndFailedValidationLeavesNoCatalogEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FileOfflineAudioStore(directory: folder)
        let source = MediaResource(id: try MediaID("remote"), url: URL(string: "https://example.com/file.wav")!, title: "Track")
        let id = try MediaID("saved")
        let gate = PlaybackTests.Gate()
        let reader = DownloadValidationReader { await gate.wait(); throw CadenzaError.unsupportedMedia }
        let task = Task { try await store.save(Data([1]), id: id, source: source, provider: "https", createdAt: Date(timeIntervalSince1970: 1), metadata: reader) }
        await gate.waitUntilEntered()
        #expect(try await store.all().isEmpty)
        await #expect(throws: CadenzaError.operationInProgress) { try await store.save(Data([1]), id: id, source: source, provider: "https", createdAt: Date(timeIntervalSince1970: 1), metadata: reader) }
        gate.open()
        await #expect(throws: CadenzaError.unsupportedMedia) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func realHTTPSDownloadValidatesPersistsAndLoadsOffline() async throws {
        let media = try RemotePlaybackTests().media()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try HTTPSCatalogSource(resources: [media.id: media], allowsDownloads: true)
        let kit = try Cadenza(configuration: .init(defaultProvider: "https", features: .init(downloads: true)), providers: [source])
        let service = try kit.makeDownloads(transfer: URLSessionAudioTransfer(), store: FileOfflineAudioStore(directory: folder), metadata: AVMetadataReader())
        let item = try await service.download(media.id, as: MediaID("offline"))
        #expect(item.byteCount > 0 && item.metadata.duration > 2)
        let reopened = try FileOfflineAudioStore(directory: folder)
        let backend = AVPlayerBackend()
        #expect(try await backend.load(reopened.resource(item.id)) > 2)
        backend.stop()
    }

    @Test(.timeLimit(.minutes(1))) func realTransferCancellationStopsStalledRequest() async throws {
        let server = try StalledConnectionServer()
        let port = try await server.start()
        defer { server.stop() }
        let transfer = URLSessionAudioTransfer()
        let url = URL(string: "https://127.0.0.1:\(port)/audio.mp3")!
        let task = Task { try await transfer.fetch(url, maximumBytes: 1000) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while server.connections.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!server.connections.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
