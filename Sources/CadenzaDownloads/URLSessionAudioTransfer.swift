import Foundation
import CadenzaDomain

public final class URLSessionAudioTransfer: AudioTransfer {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        _ = try RemoteMediaURL(url)
        guard (1...67_108_864).contains(maximumBytes) else { throw CadenzaError.invalidDownload }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, let finalURL = response.url else { throw CadenzaError.invalidDownload }
            _ = try RemoteMediaURL(finalURL)
            guard response.statusCode == 200 else { throw CadenzaError.downloadHTTPStatus(response.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw CadenzaError.downloadTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw CadenzaError.downloadTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { throw CadenzaError.invalidDownload }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as CadenzaError { throw error }
        catch { try Task.checkCancellation(); throw CadenzaError.downloadFailure(String(describing: error)) }
    }
}

private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url.flatMap { try? RemoteMediaURL($0) } != nil
        completionHandler(allowed ? request : nil)
    }
}
