import Foundation
import CadenzaDomain

/// Enumerates only the caller-selected root. Symlinks and hidden entries are
/// skipped; the host owns sandbox/security-scoped access throughout the scan.
public struct LocalFileCatalog: FileCatalog {
    private let extensions: Set<String>

    public init(extensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "aac", "flac", "mp4"]) {
        self.extensions = Set(extensions.map { $0.lowercased() })
    }

    public func files(at root: URL, namespace: MediaID) async throws -> [LibraryFile] {
        try Task.checkCancellation()
        guard root.isFileURL else { throw CadenzaError.unsupportedURL }
        do {
            let root = root.standardizedFileURL
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw CadenzaError.unreadableFile }
            var directories = [root]
            var result: [LibraryFile] = []
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let identityPrefix = Data(namespace.rawValue.utf8).base64EncodedString() + ":"
            while let directory = directories.popLast() {
                try Task.checkCancellation()
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                for url in urls {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true { directories.append(url); continue }
                    guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
                    guard let size = values.fileSize, let date = values.contentModificationDate else { throw CadenzaError.invalidLibraryItem }
                    let relativePath = url.standardizedFileURL.path
                    guard relativePath.hasPrefix(prefix) else { throw CadenzaError.invalidLibraryItem }
                    let id = try MediaID(identityPrefix + String(relativePath.dropFirst(prefix.count)))
                    result.append(LibraryFile(id: id, url: url, fingerprint: try FileFingerprint(byteCount: size, modifiedAt: date)))
                }
            }
            return result.sorted { $0.id.rawValue < $1.id.rawValue }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.libraryFailure(String(describing: error)) }
    }
}
