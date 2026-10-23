import Foundation
import AVFoundation
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaPersistence

/// App-owned orchestration; the SDK owns playback, queue policy and persistence.
@MainActor
public final class DemoModel {
    public enum Command: Equatable {
        case select(Int), playPause, stop, next, previous, seek(Double), shuffle, repeatMode, saveBookmark, resumeBookmark
    }
    public let tracks: [MediaResource]
    public let queue: PlaybackQueue
    public private(set) var saved: PositionBookmark?
    public private(set) var message = "Choose a track to start listening."
    private let bookmarks: BookmarkService
    public var didChange: (() -> Void)?

    public init(tracks: [MediaResource], backend: any PlaybackBackend, store: any DocumentStore) throws {
        guard Set(tracks.map(\.id)).count == tracks.count else { throw CadenzaError.resourceIdentityMismatch }
        self.tracks = tracks
        let source = try LocalFileSource(resources: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }))
        let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
        queue = kit.makeQueue(backend: backend)
        bookmarks = kit.makeBookmarks(store: store)
        for track in tracks { try queue.insert(.init(id: UUID(), mediaID: track.id), at: queue.entries.count) }
    }

    public func restore() async {
        do { saved = try await bookmarks.all().first; message = saved == nil ? "Your listening room is ready." : "Your saved position is ready to resume." }
        catch { message = "Could not read bookmarks: \(error)" }
        didChange?()
    }

    public func perform(_ command: Command) async {
        do {
            switch command {
            case .select(let index):
                guard queue.entries.indices.contains(index) else { throw CadenzaError.invalidQueueIndex }
                try await queue.play(queue.entries[index].id)
            case .playPause:
                if queue.snapshot.state == .playing { try queue.pause() } else { try await queue.play() }
            case .stop: queue.stop()
            case .next: try await queue.next()
            case .previous: try await queue.previous()
            case .seek(let position): try await queue.seek(to: position)
            case .shuffle: try queue.setShuffle(!queue.isShuffleEnabled)
            case .repeatMode:
                try queue.setRepeat(queue.repeatMode == .off ? .all : queue.repeatMode == .all ? .one : .off)
            case .saveBookmark:
                guard let media = queue.snapshot.resource else { throw CadenzaError.noMediaLoaded }
                saved = try await bookmarks.save(id: Self.bookmarkID, mediaID: media.id, provider: "local", title: media.title, position: queue.snapshot.position)
            case .resumeBookmark:
                guard let saved, let index = tracks.firstIndex(where: { $0.id == saved.mediaID }) else { throw CadenzaError.bookmarkNotFound }
                try await queue.play(queue.entries[index].id)
                try await queue.seek(to: min(saved.position, queue.snapshot.duration))
            }
            message = command == .saveBookmark ? "Position saved. It will be here next time." : "Original demo audio · Local playback"
        } catch is CancellationError { message = "Operation cancelled." }
        catch { message = "Could not complete the action: \(error)" }
        didChange?()
    }

    public func refresh() async {
        // Never poll an unloaded/failed backend. A failed refresh is visible and
        // stops the transport so the next tick cannot hide the failure message.
        guard queue.snapshot.resource != nil, queue.snapshot.state != .idle else { return }
        do { try await queue.refresh() }
        catch { queue.stop(); message = "Playback stopped: \(error)" }
        didChange?()
    }

    private static let bookmarkID = UUID(uuidString: "CADECACE-0000-4000-8000-000000000001")!
}

public enum DemoAudio {
    /// Original synthesized arpeggios, dedicated to CC0. Files belong to this
    /// example's cache, never to an SDK product. Existing files are regenerated.
    public static func create(in directory: URL) throws -> [MediaResource] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let titles = ["After the light", "Soft geometry", "Blue hour"]
        return try titles.enumerated().map { track, title in
            let url = directory.appendingPathComponent("demo-\(track).wav")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050 * 24)!
            buffer.frameLength = buffer.frameCapacity
            let samples = buffer.floatChannelData![0]
            let notes = [0.0, 4, 7, 12, 7, 4, 2, 7]
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / 22_050
                let note = notes[Int(time * 2) % notes.count]
                let frequency = 130.8128 * pow(2, (note + Double(track * 3)) / 12)
                let envelope = sin(.pi * (time * 2).truncatingRemainder(dividingBy: 1))
                samples[frame] = Float(0.12 * envelope * sin(2 * .pi * frequency * time))
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return MediaResource(id: try MediaID("demo-\(track)"), url: url, title: title)
        }
    }
}
