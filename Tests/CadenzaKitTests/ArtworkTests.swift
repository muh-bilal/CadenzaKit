import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaArtwork
import CadenzaLocalSources

struct TestArtworkLoader: ArtworkLoader {
    var result: Artwork?
    var failure: (any Error)?
    var action: @Sendable () async -> Void = {}
    func load(_ request: ArtworkRequest, limits: ArtworkLimits) async throws -> Artwork? {
        await action()
        if let failure { throw failure }
        return result
    }
}

@MainActor
struct ArtworkTests {
    func png(width: Int = 4, height: Int = 2) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func realImageAndEmbeddedArtworkRoundTrip() async throws {
        let image = try png()
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let tagged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let media = try LocalPlaybackIntegrationTests().fixture()
        defer { for url in [imageURL, tagged, media.url] { try? FileManager.default.removeItem(at: url) } }
        try image.write(to: imageURL)
        let loader = AppleArtworkLoader()
        let limits = try ArtworkLimits()
        let plain = try await loader.load(.imageFile(imageURL), limits: limits)
        let expected = try Artwork(data: image, width: 4, height: 2)
        #expect(plain == expected)
        #expect(try await loader.load(.embedded(media.url), limits: limits) == nil)
        let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: media.url), presetName: AVAssetExportPresetAppleM4A))
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataCoverArt
        item.value = image as NSData
        item.dataType = kCMMetadataBaseDataType_PNG as String
        exporter.metadata = [item]
        exporter.outputURL = tagged
        exporter.outputFileType = .m4a
        await exporter.export()
        #expect(exporter.status == .completed)
        let source = try LocalFileSource(resources: [media.id: MediaResource(id: media.id, url: tagged, title: "Art")])
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        let service = kit.makeArtwork(loader: loader, limits: limits)
        #expect(try await service.load(media.id) == plain)
        #expect(try await service.loadImage(at: imageURL) == plain)
        await #expect(throws: CadenzaError.artworkTooLarge) { try await loader.load(.imageFile(imageURL), limits: ArtworkLimits(maximumBytes: 1)) }
        await #expect(throws: CadenzaError.artworkTooLarge) { try await loader.load(.imageFile(imageURL), limits: ArtworkLimits(maximumPixels: 1)) }
    }

    @Test func realLoaderRejectsInvalidFilesAndCancellation() async throws {
        let loader = AppleArtworkLoader()
        let limits = try ArtworkLimits()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for request in [ArtworkRequest.imageFile(URL(string: "https://example.com/a.png")!), .embedded(URL(string: "https://example.com/a.mp3")!)] {
            await #expect(throws: CadenzaError.unsupportedURL) { try await loader.load(request, limits: limits) }
        }
        await #expect(throws: CadenzaError.self) { try await loader.load(.imageFile(url), limits: limits) }
        await #expect(throws: CadenzaError.unreadableFile) { try await loader.load(.imageFile(FileManager.default.temporaryDirectory), limits: limits) }
        try Data("invalid".utf8).write(to: url)
        await #expect(throws: CadenzaError.invalidArtwork) { try await loader.load(.imageFile(url), limits: limits) }
        await #expect(throws: CadenzaError.self) { try await loader.load(.embedded(url), limits: limits) }
        let task = Task { try await loader.load(.imageFile(url), limits: limits) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func serviceEnforcesFlagsLimitsAndCancellationForInjectedLoaders() async throws {
        let id = try MediaID("track")
        let limits = try ArtworkLimits(maximumBytes: 1, maximumPixels: 1)
        let oversized = try Artwork(data: Data([1, 2]), width: 2, height: 2)
        let kit = try PlaybackTests().kit()
        let service = kit.makeArtwork(loader: TestArtworkLoader(result: oversized), limits: limits)
        await #expect(throws: CadenzaError.artworkTooLarge) { try await service.load(id) }
        let disabled = try PlaybackTests().kit(flags: .init(artwork: false)).makeArtwork(loader: TestArtworkLoader(), limits: limits)
        await #expect(throws: CadenzaError.artworkDisabled) { try await disabled.load(id) }
        await #expect(throws: CadenzaError.artworkDisabled) { try await disabled.loadImage(at: URL(fileURLWithPath: "/art")) }
        #expect(try await kit.makeArtwork(loader: TestArtworkLoader(), limits: limits).load(id) == nil)
        struct Failure: Error, CustomStringConvertible { var description: String { "art" } }
        let failed = kit.makeArtwork(loader: TestArtworkLoader(failure: Failure()), limits: limits)
        await #expect(throws: CadenzaError.artworkFailure("art")) { try await failed.load(id) }
        let gate = PlaybackTests.Gate()
        let delayed = kit.makeArtwork(loader: TestArtworkLoader(action: { await gate.wait() }), limits: limits)
        let task = Task { try await delayed.load(id) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(throws: CadenzaError.invalidArtwork) { try ArtworkLimits(maximumBytes: 0) }
        #expect(throws: CadenzaError.invalidArtwork) { try ArtworkLimits(maximumPixels: 0) }
        #expect(throws: CadenzaError.invalidArtwork) { try Artwork(data: Data(), width: 0, height: 0) }
    }
}
