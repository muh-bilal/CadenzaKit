import Foundation
import CadenzaDomain

public struct ArtworkExportService: Sendable {
    private let flags: FeatureFlags
    private let exporter: any ArtworkExporter
    init(flags: FeatureFlags, exporter: any ArtworkExporter) { self.flags = flags; self.exporter = exporter }

    public func export(_ artwork: Artwork, to destination: URL, overwrite: Bool = false) async throws {
        try Task.checkCancellation()
        guard flags.artwork, flags.artworkExport else { throw CadenzaError.artworkExportDisabled }
        do { try await exporter.export(artwork, to: destination, overwrite: overwrite) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.artworkFailure(String(describing: error)) }
    }
}
