import Foundation

public struct RemoteMediaURL: Equatable, Sendable {
    public let url: URL
    public init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { throw CadenzaError.unsupportedURL }
        self.url = url
    }
}
