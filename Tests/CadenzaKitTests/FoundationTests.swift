import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

struct FoundationTests {
    private func provider(_ name: String = "local") -> ClosureSourceProvider {
        ClosureSourceProvider(identifier: name) { id in
            MediaResource(id: id, url: URL(fileURLWithPath: "/test.wav"), title: name)
        }
    }

    @Test func identifiersValidateOnConstructionAndDecoding() throws {
        for invalid in ["", " ", "\n\t"] {
            #expect(throws: CadenzaError.invalidIdentifier) { try MediaID(invalid) }
            let encoded = try JSONEncoder().encode(invalid)
            #expect(throws: CadenzaError.invalidIdentifier) {
                try JSONDecoder().decode(MediaID.self, from: encoded)
            }
        }
        let id = try MediaID("a/b")
        #expect(try JSONDecoder().decode(MediaID.self, from: JSONEncoder().encode(id)) == id)
        #expect(Set([id, try MediaID("a/b")]).count == 1)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MediaID.self, from: Data("17".utf8))
        }
    }

    @Test func registryRejectsAmbiguousOrMissingProviders() throws {
        #expect(throws: CadenzaError.duplicateProvider("local")) {
            try Cadenza(configuration: .init(defaultProvider: "local"), providers: [provider(), provider()])
        }
        #expect(throws: CadenzaError.providerNotFound("missing")) {
            try Cadenza(configuration: .init(defaultProvider: "missing"), providers: [])
        }
    }

    @Test func injectedProvidersResolveAndRouteConcurrently() async throws {
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [provider(), provider("remote")])
        let id = try MediaID("track")
        #expect(kit.configuration.defaultProvider == "local")
        let local = try await kit.resolve(id)
        #expect(local == MediaResource(id: id, url: URL(fileURLWithPath: "/test.wav"), title: "local"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let resource = try await kit.resolve(id, provider: "remote")
                    #expect(resource.title == "remote")
                }
            }
            try await group.waitForAll()
        }
        await #expect(throws: CadenzaError.providerNotFound("unknown")) {
            try await kit.resolve(id, provider: "unknown")
        }
    }

    @Test func sourceFailuresAreStructured() async throws {
        struct Failure: Error, CustomStringConvertible { var description: String { "transport failed" } }
        let id = try MediaID("track")
        let cases: [(any Error, any Error)] = [
            (Failure(), CadenzaError.sourceFailure(provider: "local", message: "transport failed")),
            (CadenzaError.invalidIdentifier, CadenzaError.invalidIdentifier),
            (CancellationError(), CancellationError())
        ]
        for (input, expected) in cases {
            let source = ClosureSourceProvider(identifier: "local") { _ in throw input }
            let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [source])
            do {
                _ = try await kit.resolve(id)
                Issue.record("Expected source failure")
            } catch {
                if let expected = expected as? CadenzaError {
                    #expect(error as? CadenzaError == expected)
                } else {
                    #expect(error is CancellationError)
                }
            }
        }
    }

    @Test func mismatchedIdentityIsRejected() async throws {
        let source = ClosureSourceProvider(identifier: "local") { _ in
            MediaResource(id: try MediaID("wrong"), url: URL(fileURLWithPath: "/test.wav"), title: "Wrong")
        }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [source])
        await #expect(throws: CadenzaError.resourceIdentityMismatch) { try await kit.resolve(MediaID("track")) }
    }

    @Test func cancellationBeforeResolutionAvoidsProviderSideEffects() async throws {
        let source = ClosureSourceProvider(identifier: "local") { _ in
            Issue.record("Cancelled request reached provider")
            throw CadenzaError.invalidIdentifier
        }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [source])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await kit.resolve(MediaID("track"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationAfterUncooperativeProviderDiscardsResult() async throws {
        let source = ClosureSourceProvider(identifier: "local") { id in
            withUnsafeCurrentTask { $0?.cancel() }
            return MediaResource(id: id, url: URL(fileURLWithPath: "/test.wav"), title: "Track")
        }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [source])
        let task = Task { try await kit.resolve(MediaID("track")) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
