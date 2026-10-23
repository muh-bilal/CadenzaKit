import SwiftUI
import AVFoundation
import CadenzaDomain
import CadenzaAVPlayback
import CadenzaPersistence

@main
struct CadenzaShowcase: App {
    var body: some Scene {
        WindowGroup { ShowcaseView() }
        #if os(macOS)
        .defaultSize(width: 1000, height: 720)
        #endif
    }
}

/// Owns only app lifecycle and observation. All transport state and policies are
/// read directly from DemoModel.queue, the CadenzaKit PlaybackQueue.
@MainActor
final class Showcase: ObservableObject {
    @Published private(set) var model: DemoModel?
    @Published private(set) var failure: String?
    @Published private(set) var revision = 0
    @Published private(set) var busy = false
    private var action: Task<Void, Never>?
    private var generation = 0

    func start() async {
        guard model == nil else { return }
        do {
            let fm = FileManager.default
            let cache = try ProcessInfo.processInfo.environment["CADENZA_DEMO_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
                ?? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("CadenzaShowcase")
            let tracks = try DemoAudio.create(in: cache)
            let store: any DocumentStore
            #if os(tvOS)
            // tvOS may purge files. Small durable bookmarks use the SDK's bounded preferences store.
            store = try PreferencesDocumentStore(suiteName: "org.cadenzakit.showcase.bookmarks", key: "positions")
            #else
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CadenzaShowcase/bookmarks.json")
            store = try AtomicFileStore(fileURL: support)
            #endif
            #if !os(macOS)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let model = try DemoModel(tracks: tracks, backend: AVPlayerBackend(), store: store)
            model.didChange = { [weak self] in self?.revision += 1 }
            self.model = model
            await model.restore()
        } catch { failure = String(describing: error) }
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

    func stop() {
        generation += 1
        action?.cancel()
        action = nil
        model?.queue.stop()
        busy = false
        revision += 1
    }
}

struct ShowcaseView: View {
    @StateObject private var player = Showcase()
    @Environment(\.scenePhase) private var phase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        Group {
            if let model = player.model {
                layout(model)
            } else if let failure = player.failure {
                ContentUnavailableView("Unable to open demo", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView("Preparing original demo audio…")
            }
        }
        .tint(.indigo)
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

    @ViewBuilder private func layout(_ model: DemoModel) -> some View {
        #if os(tvOS)
        HStack(spacing: 70) {
            library(model).frame(width: 480)
            ScrollView { nowPlaying(model) }
        }
        .padding(60)
        .background(.teal.opacity(0.06))
        .onPlayPauseCommand { player.send(.playPause) }
        #elseif os(iOS)
        if sizeClass == .compact {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 28) { nowPlaying(model); library(model) }.padding()
                }.navigationTitle("CadenzaKit")
            }
        } else {
            NavigationSplitView { ScrollView { library(model).padding() }.navigationTitle("CadenzaKit") }
            detail: { ScrollView { nowPlaying(model).padding(40) } }
        }
        #else
        NavigationSplitView {
            ScrollView { library(model).padding() }.navigationTitle("CadenzaKit")
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: { ScrollView { nowPlaying(model).padding(40) }.frame(minWidth: 480, minHeight: 600) }
        #endif
    }

    private func library(_ model: DemoModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Listening room", systemImage: "music.note.house").font(.title2.bold())
            Text("Original sounds · Made for this demo").font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                Button { player.send(.select(index)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model.queue.snapshot.resource?.id == track.id ? "waveform" : "music.note")
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(track.title).font(.headline)
                            Text("Cadenza Sessions").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(player.busy)
                .accessibilityIdentifier("track-\(index)")
            }
            Text("Powered by CadenzaKit").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func nowPlaying(_ model: DemoModel) -> some View {
        let snapshot = model.queue.snapshot
        return VStack(spacing: 22) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 100)).foregroundStyle(.indigo.gradient)
                .accessibilityHidden(true)
            Text(snapshot.resource?.title ?? String(localized: "Your next quiet moment"))
                .font(.largeTitle.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("current-title")
            Text(LocalizedStringKey(snapshot.state == .playing ? "Playing" : "Ready to listen"))
                .foregroundStyle(.secondary).accessibilityIdentifier("playback-state")
            ProgressView(value: snapshot.position, total: max(1, snapshot.duration))
                .accessibilityLabel("Playback position")
            HStack {
                Text(Duration.seconds(snapshot.position).formatted(.time(pattern: .minuteSecond)))
                Spacer()
                Text(Duration.seconds(snapshot.duration).formatted(.time(pattern: .minuteSecond)))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                control("Previous", icon: "backward.end.fill", id: "previous", command: .previous)
                control(snapshot.state == .playing ? "Pause" : "Play", icon: snapshot.state == .playing ? "pause.fill" : "play.fill", id: "play", command: .playPause)
                control("Next", icon: "forward.end.fill", id: "next", command: .next)
                Button { player.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .labelStyle(.iconOnly).accessibilityIdentifier("stop")
            }.buttonStyle(.borderedProminent).controlSize(.large)
            HStack {
                control("Back 5 seconds", icon: "gobackward.5", id: "seek-back", command: .seek(max(0, snapshot.position - 5)))
                control("Forward 5 seconds", icon: "goforward.5", id: "seek-forward", command: .seek(min(snapshot.duration, snapshot.position + 5)))
            }.disabled(snapshot.resource == nil)
            ViewThatFits(in: .horizontal) {
                HStack { modes(model) }
                VStack { modes(model) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { bookmarks(model) }
                VStack { bookmarks(model) }
            }
            Text(LocalizedStringKey(model.message)).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).accessibilityIdentifier("status")
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    private func control(_ title: String, icon: String, id: String, command: DemoModel.Command) -> some View {
        Button { player.send(command) } label: { Label(LocalizedStringKey(title), systemImage: icon) }
            .labelStyle(.iconOnly).disabled(player.busy).accessibilityIdentifier(id)
    }

    @ViewBuilder private func modes(_ model: DemoModel) -> some View {
        Button { player.send(.shuffle) } label: {
            Label(LocalizedStringKey(model.queue.isShuffleEnabled ? "Shuffle on" : "Shuffle off"), systemImage: "shuffle")
        }.disabled(player.busy).accessibilityIdentifier("shuffle")
        Button { player.send(.repeatMode) } label: {
            Label(LocalizedStringKey(model.queue.repeatMode == .off ? "Repeat off" : model.queue.repeatMode == .all ? "Repeat all" : "Repeat one"), systemImage: model.queue.repeatMode == .one ? "repeat.1" : "repeat")
        }.disabled(player.busy).accessibilityIdentifier("repeat")
    }

    @ViewBuilder private func bookmarks(_ model: DemoModel) -> some View {
        Button { player.send(.saveBookmark) } label: { Label("Save position", systemImage: "bookmark") }
            .disabled(player.busy || model.queue.snapshot.resource == nil).accessibilityIdentifier("save")
        Button { player.send(.resumeBookmark) } label: { Label("Resume saved", systemImage: "bookmark.fill") }
            .disabled(player.busy || model.saved == nil).accessibilityIdentifier("resume")
    }
}
