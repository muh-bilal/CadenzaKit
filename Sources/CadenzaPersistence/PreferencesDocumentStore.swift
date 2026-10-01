import Foundation
import CadenzaDomain

/// Small host-owned documents. The whole named suite is capped below tvOS's
/// warning limit. Do not share this suite with code bypassing the store budget.
/// UserDefaults flushes asynchronously; success is not an fsync guarantee.
public actor PreferencesDocumentStore: DocumentStore {
    private let defaults: UserDefaults
    private let suiteName: String
    private let key: String
    private let maximumBytes: Int

    public init(suiteName: String, key: String, maximumBytes: Int = 256 * 1024) throws {
        guard !suiteName.isEmpty, !key.isEmpty, (1...256 * 1024).contains(maximumBytes),
              let defaults = UserDefaults(suiteName: suiteName) else { throw CadenzaError.invalidStorageConfiguration }
        self.defaults = defaults
        self.suiteName = suiteName
        self.key = key
        self.maximumBytes = maximumBytes
    }

    public func read() throws -> Data? {
        try Task.checkCancellation()
        guard let value = defaults.persistentDomain(forName: suiteName)?[key] else { return nil }
        guard let data = value as? Data else { throw CadenzaError.corruptStore }
        return data
    }

    @discardableResult
    public func update(_ transform: @Sendable (Data?) throws -> Data?) throws -> Data? {
        try Task.checkCancellation()
        let next = try transform(read())
        var domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        domain[key] = next
        let encoded = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        guard encoded.count <= maximumBytes else { throw CadenzaError.storageLimitExceeded }
        try Task.checkCancellation()
        if let next { defaults.set(next, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        return next
    }
}
