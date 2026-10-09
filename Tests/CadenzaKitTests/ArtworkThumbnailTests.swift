import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaArtwork

actor TestArtworkProcessor: ArtworkProcessor {
    var calls = 0
    var failure: (any Error)?
    var gate: PlaybackTests.Gate?
    var output: Artwork?
    func setFailure(_ error: (any Error)?) { failure = error }
    func setGate(_ gate: PlaybackTests.Gate?) { self.gate = gate }
    func setOutput(_ output: Artwork?) { self.output = output }
    func thumbnail(_ artwork: Artwork, maximumDimension: Int) async throws -> Artwork {
        calls += 1
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return try output ?? Artwork(data: artwork.data, width: 1, height: 1)
    }
}

@MainActor
struct ArtworkThumbnailTests {
    @Test func imageIOResizesOrientsAndProducesDecodablePNG() async throws {
        let processor = ImageIOArtworkProcessor()
        let data = try ArtworkTests().png(width: 80, height: 40)
        let original = try Artwork(data: data, width: 80, height: 40)
        let thumb = try await processor.thumbnail(original, maximumDimension: 20)
        #expect(thumb.width == 20 && thumb.height == 10)
        let source = try #require(CGImageSourceCreateWithData(thumb.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        let orientedData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(orientedData, UTType.jpeg.identifier as CFString, 1, nil))
        let originalSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        CGImageDestinationAddImageFromSource(destination, originalSource, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let oriented = try Artwork(data: orientedData as Data, width: 80, height: 40)
        let rotated = try await processor.thumbnail(oriented, maximumDimension: 20)
        #expect(rotated.width == 10 && rotated.height == 20)
        let unchanged = try await processor.thumbnail(original, maximumDimension: 100)
        #expect(unchanged.width == 80 && unchanged.height == 40)
        await #expect(throws: CadenzaError.invalidArtwork) { try await processor.thumbnail(original, maximumDimension: 0) }
        let corrupt = try Artwork(data: Data([1]), width: 1, height: 1)
        await #expect(throws: CadenzaError.invalidArtwork) { try await processor.thumbnail(corrupt, maximumDimension: 20) }
        let task = Task { try await processor.thumbnail(original, maximumDimension: 20) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let service = try PlaybackTests().kit().makeArtworkThumbnails(processor: processor)
        #expect(try await service.thumbnail(original, maximumDimension: 20) == thumb)
        #expect(try await service.thumbnail(original, maximumDimension: 20) == thumb)
    }

    @Test func contentAndSizeKeysLRUEvictionAndDisabledCache() async throws {
        let processor = TestArtworkProcessor()
        let kit = try PlaybackTests().kit()
        let cache = try kit.makeArtworkThumbnails(processor: processor, maximumCacheBytes: 2)
        let a = try Artwork(data: Data([1]), width: 1, height: 1)
        let b = try Artwork(data: Data([2]), width: 1, height: 1)
        let c = try Artwork(data: Data([3]), width: 1, height: 1)
        _ = try await cache.thumbnail(a, maximumDimension: 1)
        _ = try await cache.thumbnail(b, maximumDimension: 1)
        _ = try await cache.thumbnail(a, maximumDimension: 1)
        #expect(await processor.calls == 2)
        _ = try await cache.thumbnail(c, maximumDimension: 1)
        #expect(await cache.cachedBytes == 2)
        #expect(await cache.cachedCount == 2)
        _ = try await cache.thumbnail(b, maximumDimension: 1)
        #expect(await processor.calls == 4)
        _ = try await cache.thumbnail(b, maximumDimension: 2)
        #expect(await processor.calls == 5)
        await cache.removeAll()
        #expect(await cache.cachedBytes == 0)
        let large = try Artwork(data: Data([1, 2, 3]), width: 1, height: 1)
        _ = try await cache.thumbnail(large, maximumDimension: 1)
        #expect(await cache.cachedCount == 0)
        let disabled = try PlaybackTests().kit(flags: .init(artworkCaching: false)).makeArtworkThumbnails(processor: processor)
        _ = try await disabled.thumbnail(a, maximumDimension: 1)
        _ = try await disabled.thumbnail(a, maximumDimension: 1)
        #expect(await disabled.cachedCount == 0)
        #expect(await processor.calls == 8)
        let countBound = try kit.makeArtworkThumbnails(processor: processor, maximumCacheBytes: 10_000)
        for number in 0..<257 {
            let artwork = try Artwork(data: Data(String(number).utf8), width: 1, height: 1)
            _ = try await countBound.thumbnail(artwork, maximumDimension: 1)
        }
        #expect(await countBound.cachedCount == 256)
    }

    @Test func flagsFailuresAndConcurrentInvalidationAreSafe() async throws {
        let artwork = try Artwork(data: Data([1]), width: 1, height: 1)
        let processor = TestArtworkProcessor()
        let kit = try PlaybackTests().kit()
        let service = try kit.makeArtworkThumbnails(processor: processor)
        #expect(throws: CadenzaError.invalidArtwork) { try kit.makeArtworkThumbnails(processor: processor, maximumCacheBytes: -1) }
        for flags in [FeatureFlags(artwork: false), .init(artworkDownsampling: false)] {
            let disabled = try PlaybackTests().kit(flags: flags).makeArtworkThumbnails(processor: processor)
            await #expect(throws: CadenzaError.artworkDisabled) { try await disabled.thumbnail(artwork, maximumDimension: 1) }
        }
        await #expect(throws: CadenzaError.invalidArtwork) { try await service.thumbnail(artwork, maximumDimension: 4097) }
        await processor.setOutput(try Artwork(data: Data([1]), width: 2, height: 2))
        await #expect(throws: CadenzaError.invalidArtwork) { try await service.thumbnail(artwork, maximumDimension: 1) }
        await processor.setOutput(nil)
        await processor.setFailure(CadenzaError.invalidArtwork)
        await #expect(throws: CadenzaError.invalidArtwork) { try await service.thumbnail(artwork, maximumDimension: 1) }
        struct Failure: Error, CustomStringConvertible { var description: String { "process" } }
        await processor.setFailure(Failure())
        await #expect(throws: CadenzaError.artworkFailure("process")) { try await service.thumbnail(artwork, maximumDimension: 1) }
        await processor.setFailure(CancellationError())
        await #expect(throws: CancellationError.self) { try await service.thumbnail(artwork, maximumDimension: 1) }
        await processor.setFailure(nil)
        for cancel in [false, true] {
            let gate = PlaybackTests.Gate()
            await processor.setGate(gate)
            let task = Task { try await service.thumbnail(artwork, maximumDimension: 1) }
            await gate.waitUntilEntered()
            await service.removeAll()
            if cancel { task.cancel() }
            gate.open()
            if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
            else { #expect(try await task.value == artwork) }
            #expect(await service.cachedCount == 0)
        }
        await processor.setGate(nil)
        async let first = service.thumbnail(artwork, maximumDimension: 1)
        async let second = service.thumbnail(artwork, maximumDimension: 1)
        _ = try await (first, second)
        #expect(await service.cachedBytes == 1)
        #expect(await service.cachedCount == 1)
    }
}
