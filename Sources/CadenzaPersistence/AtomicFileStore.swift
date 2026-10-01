import Foundation
import CadenzaDomain

/// Use host-selected application-support storage on iOS/macOS. tvOS cache files
/// are purgeable; use a bounded PreferencesDocumentStore for small durable state.
public actor AtomicFileStore: DocumentStore {
    private let fileURL: URL

    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw CadenzaError.unsupportedURL }
        self.fileURL = fileURL
    }

    public func read() throws -> Data? {
        try Task.checkCancellation()
        return try readData()
    }

    @discardableResult
    public func update(_ transform: @Sendable (Data?) throws -> Data?) throws -> Data? {
        try Task.checkCancellation()
        let previous = try readData()
        let next = try transform(previous)
        try Task.checkCancellation()
        guard next != previous else { return next }
        do {
            if let next {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try next.write(to: fileURL, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch { throw CadenzaError.storageFailure(String(describing: error)) }
        return next
    }

    private func readData() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw CadenzaError.storageFailure(String(describing: error)) }
    }
}
