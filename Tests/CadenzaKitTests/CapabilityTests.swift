import Foundation
import Testing
import CadenzaDomain
import CadenzaKit
import CadenzaTesting

struct CapabilityTests {
    actor Calls {
        var count = 0
        func increment() { count += 1 }
    }
    actor Context {
        var value = RuntimeCapabilities()
        func denyRoute() { value.outputRoute = [] }
    }

    @Test(arguments: 0..<32)
    func policyIntersectionAndPrecedence(mask: Int) async throws {
        let allowed: Set<Feature> = [.sourceResolution]
        let enabled = mask & 1 != 0
        let source = mask & 2 != 0 ? allowed : []
        let backend = mask & 4 != 0 ? allowed : []
        let platform = mask & 8 != 0 ? allowed : []
        let route = mask & 16 != 0 ? allowed : []
        let runtime = RuntimeCapabilities(backend: backend, platform: platform, outputRoute: route)
        let reasons: [UnavailabilityReason] = [.disabled, .source, .backend, .platform, .outputRoute]
        let firstDenied = (0..<5).first { mask & (1 << $0) == 0 }
        let expected: FeatureAvailability = firstDenied.map { .unavailable(reasons[$0]) } ?? .available
        let calls = Calls()
        let provider = ClosureSourceProvider(identifier: "local", supportedFeatures: source) { id in
            await calls.increment()
            return MediaResource(id: id, url: URL(fileURLWithPath: "/test.wav"), title: "Track")
        }
        let kit = try Cadenza(
            configuration: .init(defaultProvider: "local", features: .init(sourceResolution: enabled)),
            providers: [provider], runtimeCapabilities: { runtime }
        )
        #expect(try await kit.availability(for: .sourceResolution) == expected)
        let id = try MediaID("track")
        if case let .unavailable(reason) = expected {
            await #expect(throws: CadenzaError.featureUnavailable(.sourceResolution, reason)) { try await kit.resolve(id) }
            #expect(await calls.count == 0)
        } else {
            #expect(try await kit.resolve(id).id == id)
            #expect(await calls.count == 1)
        }
    }

    @Test func contextIsRefreshedForEachOperation() async throws {
        let context = Context()
        let provider = ClosureSourceProvider(identifier: "local") { id in
            MediaResource(id: id, url: URL(fileURLWithPath: "/test.wav"), title: "Track")
        }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [provider], runtimeCapabilities: { await context.value })
        #expect(try await kit.availability(for: .sourceResolution) == .available)
        await context.denyRoute()
        await #expect(throws: CadenzaError.featureUnavailable(.sourceResolution, .outputRoute)) { try await kit.resolve(MediaID("track")) }
        await #expect(throws: CadenzaError.providerNotFound("missing")) {
            try await kit.availability(for: .sourceResolution, provider: "missing")
        }
    }

    @Test func cancellationDuringCapabilityCheckDoesNotReachProvider() async throws {
        let provider = ClosureSourceProvider(identifier: "local") { _ in
            Issue.record("Provider reached after cancellation")
            throw CadenzaError.invalidIdentifier
        }
        let kit = try Cadenza(configuration: .init(defaultProvider: "local"), providers: [provider], runtimeCapabilities: {
            withUnsafeCurrentTask { $0?.cancel() }
            return .init()
        })
        let task = Task { try await kit.resolve(MediaID("track")) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func defaultProviderContractSupportsResolution() {
        struct Provider: SourceProvider {
            let identifier = "local"
            func resolve(_ id: MediaID) async throws -> MediaResource { throw CadenzaError.invalidIdentifier }
        }
        #expect(Provider().supportedFeatures == [.sourceResolution])
        #expect(Feature.allCases == [.sourceResolution, .playback, .seeking, .remotePlayback, .downloads, .equalizer])
        #expect(Feature.sourceResolution.rawValue == "sourceResolution")
    }
}
