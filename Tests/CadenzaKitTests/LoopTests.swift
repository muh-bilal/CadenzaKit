import Foundation
import Testing
import CadenzaDomain
import CadenzaKit

@MainActor
struct LoopTests {
    @Test func rangesAndAssetBoundsAreValidated() async throws {
        for (start, end) in [(-1.0, 2.0), (1, 1), (2, 1), (.nan, 2), (0, .infinity)] {
            #expect(throws: CadenzaError.invalidLoopRange) { try LoopRange(start: start, end: end) }
        }
        let range = try LoopRange(start: 2, end: 4)
        let session = try PlaybackTests().kit().makeSession(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.noMediaLoaded) { try await session.setLoop(range) }
        try await session.load(MediaID("track"))
        await #expect(throws: CadenzaError.invalidLoopRange) { try await session.setLoop(LoopRange(start: 2, end: 11)) }
        try await session.setLoop(range)
        #expect(session.loopRange == range)
        try await session.setLoop(nil)
        #expect(session.loopRange == nil)
    }

    @Test func loopWrapsOnlyWhenPlayingAndResetsOnStopOrReplacement() async throws {
        let backend = PlaybackTests.Backend()
        let session = try PlaybackTests().kit().makeSession(backend: backend)
        try await session.load(MediaID("track"))
        let range = try LoopRange(start: 2, end: 4)
        try await session.setLoop(range)
        try await session.refresh()
        #expect(session.snapshot.position == 0)
        try await session.play()
        try await session.refresh()
        #expect(session.snapshot.position == 2)
        backend.position = 3
        try await session.refresh()
        #expect(session.snapshot.position == 3)
        backend.position = 4.1
        try await session.refresh()
        #expect(session.snapshot.position == 2)
        #expect(session.snapshot.state == .playing)
        try session.pause()
        backend.position = 5
        try await session.refresh()
        #expect(session.snapshot.state == .paused)
        #expect(session.snapshot.position == 5)
        try await session.load(MediaID("new"))
        #expect(session.loopRange == nil)
        try await session.setLoop(range)
        session.stop()
        #expect(session.loopRange == nil)
    }

    @Test func policyRevocationPausesAndBackendFailureRemainsStructured() async throws {
        let range = try LoopRange(start: 1, end: 2)
        let disabled = try PlaybackTests().kit(flags: .init(abLooping: false)).makeSession(backend: PlaybackTests.Backend())
        await #expect(throws: CadenzaError.loopingDisabled) { try await disabled.setLoop(range) }
        try await disabled.setLoop(nil)
        let backend = PlaybackTests.Backend()
        let session = try PlaybackTests().kit().makeSession(backend: backend)
        try await session.load(MediaID("track"))
        try await session.setLoop(range)
        try await session.play()
        backend.position = 3
        backend.supportedFeatures = [.playback]
        await #expect(throws: CadenzaError.featureUnavailable(.seeking, .backend)) { try await session.refresh() }
        #expect(session.snapshot.state == .paused)
        #expect(!backend.playing)
        backend.supportedFeatures = [.playback, .seeking]
        try await session.play()
        backend.seekFailure = CadenzaError.playbackFailure("seek")
        await #expect(throws: CadenzaError.playbackFailure("seek")) { try await session.refresh() }
        #expect(session.snapshot.state == .failed(.playbackFailure("seek")))
    }

    @Test func stoppedLoopCannotPauseReplacementAndQueueRejectsConcurrentMutation() async throws {
        let backend = PlaybackTests.Backend()
        let gate = PlaybackTests.Gate()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try await queue.play()
        let range = try LoopRange(start: 1, end: 2)
        try await queue.setLoop(range)
        #expect(queue.loopRange == range)
        backend.seekGate = gate
        backend.position = 3
        let refresh = Task { try await queue.refresh() }
        await gate.waitUntilEntered()
        #expect(throws: CadenzaError.operationInProgress) { try queue.remove(b.id) }
        queue.stop()
        backend.seekGate = nil
        try await queue.play(b.id)
        gate.open()
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(queue.currentEntryID == b.id)
        #expect(queue.snapshot.state == .playing)
        #expect(queue.loopRange == nil)
    }

    @Test func loopAtAssetEndTakesPrecedenceOverQueueAdvance() async throws {
        let backend = PlaybackTests.Backend()
        let queue = try PlaybackTests().kit().makeQueue(backend: backend)
        let a = try QueueTests().entry(1), b = try QueueTests().entry(2)
        try queue.insert(a, at: 0)
        try queue.insert(b, at: 1)
        try await queue.play()
        try await queue.setLoop(LoopRange(start: 1, end: 10))
        backend.position = 9.999
        backend.ended = true
        try await queue.refresh()
        #expect(queue.currentEntryID == a.id)
        #expect(queue.snapshot.position == 1)
        #expect(queue.history == [a.id])
        try await queue.setLoop(nil)
    }
}
