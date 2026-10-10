import Foundation
import CadenzaDomain

/// Exports encoded bytes unchanged. The host selects an appropriate extension.
public struct FileArtworkExporter: ArtworkExporter {
    private let temporaryID: @Sendable () -> UUID
    public init(temporaryID: @escaping @Sendable () -> UUID = { UUID() }) { self.temporaryID = temporaryID }

    public func export(_ artwork: Artwork, to destination: URL, overwrite: Bool) async throws {
        try Task.checkCancellation()
        guard destination.isFileURL else { throw CadenzaError.unsupportedURL }
        do {
            if overwrite {
                try artwork.data.write(to: destination, options: .atomic)
            } else {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".CadenzaKit-\(temporaryID().uuidString).tmp")
                try artwork.data.write(to: staging, options: .withoutOverwriting)
                defer { try? FileManager.default.removeItem(at: staging) }
                try Task.checkCancellation()
                // A same-directory hard link publishes a complete file without a
                // check-then-write race or overwriting an existing destination.
                do { try FileManager.default.linkItem(at: staging, to: destination) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { throw CadenzaError.artworkDestinationExists }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.artworkFailure(String(describing: error)) }
    }
}
