import SwiftUI
import AVFoundation
import CadenzaDomain
import CadenzaKit
import CadenzaAudioEngine
import CadenzaPersistence
import CadenzaSystemPlayback

func demoText(_ key: String) -> String { NSLocalizedString(key, tableName: "Showcase", comment: "") }

@main
struct CadenzaDemo: App {
    @StateObject private var player = Showcase.shared
    var body: some Scene {
        WindowGroup("CadenzaKit") { ShowcaseView(player: player) }
        #if os(macOS)
        .defaultSize(width: 1200, height: 820)
        #endif
    }
}

/// Observes SDK objects; never duplicates playback or equalizer policy.
@MainActor
final class Showcase: ObservableObject {
    static let shared = Showcase()
    func reportCarPlayFailure(_ message: String) { failure = message }
    @Published private(set) var model: DemoModel?
    @Published private(set) var failure: String?
    @Published private(set) var revision = 0
    @Published private(set) var busy = false
    @Published private(set) var soundMessage = ""
    @Published private(set) var soundSettings = EqualizerSettings()
    @Published private(set) var soundBusy = false
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
            soundSettings = try services.equalizer.settings
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
            let engine = AVAudioEngineBackend()
            let model = try DemoModel(tracks: tracks, backend: engine, store: store, features: .init(systemPlayback: ProcessInfo.processInfo.environment["CADENZA_SYSTEM_PLAYBACK"] != "0", carPlay: true, equalizer: true), systemPlayback: AppleSystemPlaybackController())
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
        await updateSound { service in
            if bass {
                try await service.apply(EqualizerSettings(bands: [EqualizerBand(frequency: 120, gain: 4)], preamp: -4))
            } else { try service.bypass() }
        }
    }

    func adjustSound(frequency: Float?, delta: Float) async {
        await updateSound { service in
            let current = try service.settings
            var bands = current.bands
            var preamp = current.preamp
            if let frequency {
                let gain = bands.first { $0.frequency == frequency }?.gain ?? 0
                bands.removeAll { $0.frequency == frequency }
                bands.append(try EqualizerBand(frequency: frequency, gain: min(24, max(-24, gain + delta))))
            } else { preamp = min(24, max(-24, preamp + delta)) }
            try await service.apply(EqualizerSettings(bands: bands, preamp: preamp))
        }
    }

    private func updateSound(_ operation: (EqualizerService) async throws -> Void) async {
        guard !soundBusy, let equalizer else { return }
        soundBusy = true
        defer { soundBusy = false }
        do {
            try await operation(equalizer)
            soundSettings = try equalizer.settings
            soundMessage = demoText(soundSettings.isBypassed ? "Equalizer bypassed" : "Equalizer enabled")
        } catch { soundMessage = String(describing: error) }
    }

    func setBackgrounded(_ value: Bool) {
        model?.player.setBackgrounded(value)
        revision += 1
    }

    func stop() {
        generation += 1; action?.cancel(); action = nil
        model?.player.stop(); busy = false; revision += 1
    }
}

struct ShowcaseView: View {
    @ObservedObject var player: Showcase
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let model = player.model { DemoPlayerScreen(player: player, model: model) }
            else if let failure = player.failure {
                ContentUnavailableView("Unable to open demo", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else { ProgressView("Preparing original demo audio…") }
        }
        .task { await player.start() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in player.setBackgrounded(true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in updateWindowVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in updateWindowVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in updateWindowVisibility() }
        #else
        .onChange(of: phase) { _, phase in player.setBackgrounded(phase == .background) }
        #endif
    }
    #if os(macOS)
    private func updateWindowVisibility() {
        player.setBackgrounded(NSApp.isHidden || NSApp.windows.filter { $0.canBecomeMain }.allSatisfy { $0.isMiniaturized || !$0.isVisible })
    }
    #endif
}
