import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaArtwork

struct FailingArtworkExporter: ArtworkExporter {
    let error: any Error
    func export(_ artwork: Artwork, to destination: URL, overwrite: Bool) throws { throw error }
}

@MainActor
struct ArtworkExportTests {
    @Test func realExportRoundTripNoOverwriteReplacementAndConcurrentCreation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("art.png")
        let art = try Artwork(data: ArtworkTests().png(), width: 4, height: 2)
        let service = try PlaybackTests().kit().makeArtworkExport(exporter: FileArtworkExporter())
        try await service.export(art, to: url)
        #expect(try await AppleArtworkLoader().load(.imageFile(url), limits: ArtworkLimits()) == art)
        let replacement = try Artwork(data: ArtworkTests().png(width: 8), width: 8, height: 2)
        await #expect(throws: CadenzaError.artworkDestinationExists) { try await service.export(replacement, to: url) }
        #expect(try Data(contentsOf: url) == art.data)
        try await service.export(replacement, to: url, overwrite: true)
        #expect(try Data(contentsOf: url) == replacement.data)
        let concurrent = folder.appendingPathComponent("concurrent.png")
        let outcomes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await service.export(art, to: concurrent); return true }
                    catch CadenzaError.artworkDestinationExists { return false }
                }
            }
            var values: [Bool] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try Data(contentsOf: concurrent) == art.data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["art.png", "concurrent.png"])
    }

    @Test func failuresCancellationAndFlagsLeaveFilesIntact() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("art.png")
        let art = try Artwork(data: ArtworkTests().png(), width: 4, height: 2)
        let writer = FileArtworkExporter()
        await #expect(throws: CadenzaError.unsupportedURL) { try await writer.export(art, to: URL(string: "https://example.com/art.png")!, overwrite: false) }
        await #expect(throws: CadenzaError.self) { try await writer.export(art, to: folder.appendingPathComponent("missing/art.png"), overwrite: false) }
        let stagingID = UUID()
        let staging = folder.appendingPathComponent(".CadenzaKit-\(stagingID.uuidString).tmp")
        try Data([9]).write(to: staging)
        let collision = FileArtworkExporter(temporaryID: { stagingID })
        await #expect(throws: CadenzaError.self) { try await collision.export(art, to: url, overwrite: false) }
        #expect(try Data(contentsOf: staging) == Data([9]))
        try FileManager.default.removeItem(at: staging)
        let task = Task { try await writer.export(art, to: url, overwrite: false) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        for flags in [FeatureFlags(artwork: false), .init(artworkExport: false)] {
            let disabled = try PlaybackTests().kit(flags: flags).makeArtworkExport(exporter: writer)
            await #expect(throws: CadenzaError.artworkExportDisabled) { try await disabled.export(art, to: url) }
        }
        struct Failure: Error, CustomStringConvertible { var description: String { "export" } }
        let kit = try PlaybackTests().kit()
        let failed = kit.makeArtworkExport(exporter: FailingArtworkExporter(error: Failure()))
        await #expect(throws: CadenzaError.artworkFailure("export")) { try await failed.export(art, to: url) }
        let cancelled = kit.makeArtworkExport(exporter: FailingArtworkExporter(error: CancellationError()))
        await #expect(throws: CancellationError.self) { try await cancelled.export(art, to: url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
