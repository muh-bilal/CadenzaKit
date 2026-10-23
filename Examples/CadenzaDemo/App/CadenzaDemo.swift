import SwiftUI
import AVFoundation
import CadenzaDomain
import CadenzaKit
import CadenzaAudioEngine
import CadenzaPersistence

func demoText(_ key: String) -> String { NSLocalizedString(key, tableName: "Showcase", comment: "") }

@main
struct CadenzaDemo: App {
    var body: some Scene {
        WindowGroup("CadenzaKit") { ShowcaseView() }
        #if os(macOS)
        .defaultSize(width: 1200, height: 820)
        #endif
    }
}

/// Observes SDK objects; never duplicates playback or equalizer policy.
@MainActor
final class Showcase: ObservableObject {
    @Published private(set) var model: DemoModel?
    @Published private(set) var failure: String?
    @Published private(set) var revision = 0
    @Published private(set) var busy = false
    @Published private(set) var soundMessage = ""
    private var equalizer: EqualizerService?
    private(set) var action: Task<Void, Never>?
    struct Services { let model: DemoModel; let equalizer: EqualizerService }
    private let makeServices: @MainActor () throws -> Services
    init(makeServices: @escaping @MainActor () throws -> Services = Showcase.liveServices) { self.makeServices = makeServices }
    private var generation = 0

    func start() async {
        guard model == nil else { return }
        do {
            let services = try makeServices()
            let model = services.model
            equalizer = services.equalizer
            model.didChange = { [weak self] in self?.revision += 1 }
            self.model = model
            await model.restore()
        } catch { failure = String(describing: error) }
    }

    static func liveServices() throws -> Services {
            let fm = FileManager.default
            let cache = try ProcessInfo.processInfo.environment["CADENZA_DEMO_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
                ?? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CadenzaShowcase")
            let tracks = try DemoAudio.create(in: cache)
            let store: any DocumentStore
            #if os(tvOS)
            store = try PreferencesDocumentStore(suiteName: "org.cadenzakit.showcase.bookmarks", key: "positions")
            #else
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CadenzaShowcase/bookmarks.json")
            store = try AtomicFileStore(fileURL: support)
            #endif
            #if !os(macOS)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let engine = AVAudioEngineBackend()
            let model = try DemoModel(tracks: tracks, backend: engine, store: store, features: .init(equalizer: true))
            let equalizer = model.cadenza.makeEqualizer(backend: engine, store: try PreferencesDocumentStore(suiteName: "org.cadenzakit.showcase.equalizer", key: "presets"))
            return Services(model: model, equalizer: equalizer)
    }

    func send(_ command: DemoModel.Command) {
        guard !busy, let model else { return }
        busy = true
        let token = generation
        action = Task {
            await model.perform(command)
            if generation == token { busy = false }
        }
    }

    func setSound(bass: Bool) async {
        guard let equalizer else { return }
        do {
            let settings = bass ? try EqualizerSettings(bands: [EqualizerBand(frequency: 120, gain: 4)], preamp: -4) : EqualizerSettings()
            if bass { try await equalizer.apply(settings) } else { try equalizer.bypass() }
            soundMessage = demoText(bass ? "Warm bass enabled" : "Equalizer bypassed")
        } catch { soundMessage = String(describing: error) }
    }

    func stop() {
        generation += 1; action?.cancel(); action = nil
        model?.queue.stop(); busy = false; revision += 1
    }
}

struct ShowcaseView: View {
    @StateObject private var player = Showcase()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let model = player.model { DemoPlayerScreen(player: player, model: model) }
            else if let failure = player.failure {
                ContentUnavailableView("Unable to open demo", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else { ProgressView("Preparing original demo audio…") }
        }
        .task {
            await player.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                if !player.busy { await player.model?.refresh() }
            }
        }
        .onChange(of: phase) { _, phase in if phase == .background { player.stop() } }
        .onDisappear { player.stop() }
    }
}
