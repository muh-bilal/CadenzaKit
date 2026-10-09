import Foundation
import CryptoKit
import CadenzaDomain

/// Bounded LRU of encoded thumbnails, keyed by source content and requested size.
public actor ArtworkThumbnailService {
    private let flags: FeatureFlags
    private let processor: any ArtworkProcessor
    private let maximumCacheBytes: Int
    private var cache: [Key: Artwork] = [:]
    private var order: [Key] = []
    private var generation: UInt64 = 0
    public private(set) var cachedBytes = 0
    public var cachedCount: Int { cache.count }

    private struct Key: Hashable { let digest: Data; let dimension: Int }

    init(flags: FeatureFlags, processor: any ArtworkProcessor, maximumCacheBytes: Int) throws {
        guard maximumCacheBytes >= 0 else { throw CadenzaError.invalidArtwork }
        self.flags = flags
        self.processor = processor
        self.maximumCacheBytes = maximumCacheBytes
    }

    public func removeAll() {
        cache.removeAll()
        order.removeAll()
        cachedBytes = 0
        generation &+= 1
    }

    public func thumbnail(_ artwork: Artwork, maximumDimension: Int) async throws -> Artwork {
        try Task.checkCancellation()
        guard flags.artwork, flags.artworkDownsampling else { throw CadenzaError.artworkDisabled }
        guard (1...4096).contains(maximumDimension) else { throw CadenzaError.invalidArtwork }
        let key = Key(digest: Data(SHA256.hash(data: artwork.data)), dimension: maximumDimension)
        if let value = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }
        let started = generation
        let value: Artwork
        do { value = try await processor.thumbnail(artwork, maximumDimension: maximumDimension) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.artworkFailure(String(describing: error)) }
        try Task.checkCancellation()
        guard value.width <= maximumDimension, value.height <= maximumDimension else { throw CadenzaError.invalidArtwork }
        if flags.artworkCaching, started == generation, value.data.count <= maximumCacheBytes {
            if let old = cache.removeValue(forKey: key) { cachedBytes -= old.data.count }
            order.removeAll { $0 == key }
            while cachedBytes > maximumCacheBytes - value.data.count || cache.count >= 256, let oldest = order.first {
                order.removeFirst()
                if let evicted = cache.removeValue(forKey: oldest) { cachedBytes -= evicted.data.count }
            }
            cache[key] = value
            order.append(key)
            cachedBytes += value.data.count
        }
        return value
    }
}
