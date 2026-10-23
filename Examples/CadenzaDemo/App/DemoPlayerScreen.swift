import SwiftUI
import CadenzaDomain
import CadenzaSwiftUI

struct DemoPlayerScreen: View {
    @ObservedObject var player: Showcase
    let model: DemoModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("showcase-appearance") private var appearanceMode = 0
    @State private var empty: Bool
    @State private var panel: Panel?
    @State private var titleSize: Double
    @State private var accent: Int
    @State private var customImages: Bool
    @State private var customText: Bool
    @State private var customButtons: Bool
    @State private var library: Bool
    @State private var search: String
    enum Panel: String, Identifiable { case options, queue, sound; var id: String { rawValue } }

    init(player: Showcase, model: DemoModel) {
        self.player = player; self.model = model
        _empty = State(initialValue: false)
        _titleSize = State(initialValue: 24)
        _accent = State(initialValue: 0)
        _customImages = State(initialValue: false)
        _customText = State(initialValue: false)
        _customButtons = State(initialValue: false)
        _library = State(initialValue: false)
        _search = State(initialValue: "")
    }

    private var appearance: PlayerAppearance {
        var value = PlayerAppearance()
        value.fonts.title = .system(size: titleSize, weight: .semibold)
        value.metrics.spacing = 16
        if accent != 0 {
            value.light.accent = accent == 1 ? .indigo : .orange
            value.dark.accent = value.light.accent
            value.dark.onAccent = .white
        }
        #if os(tvOS)
        value.fonts.title = .system(size: titleSize * 2, weight: .semibold)
        value.metrics.padding = 60; value.metrics.spacing = 44
        value.metrics.wideArtworkWidth = 620; value.metrics.wideContentWidth = 740
        value.metrics.artworkMaximum = 620
        #endif
        return value
    }
    private var colors: PlayerColors { appearance.colors(for: scheme) }
    private var currentIndex: Int { model.tracks.firstIndex { $0.id == model.queue.snapshot.resource?.id } ?? 0 }
    private var currentTitle: String { model.queue.snapshot.resource?.title ?? model.tracks[0].title }

    private var context: PlayerContext {
        var actions = PlayerActions(seek: { player.send(.seek($0)) })
        actions.controls[.back] = { panel = .queue }
        actions.controls[.more] = { panel = .options }
        actions.controls[.queue] = { panel = .queue }
        actions.controls[.equalizer] = { panel = .sound }
        actions.controls[.playPause] = { player.send(.playPause) }
        actions.controls[.previous] = { player.send(.previous) }
        actions.controls[.next] = { player.send(.next) }
        actions.controls[.shuffle] = { player.send(.shuffle) }
        actions.controls[.repeatMode] = { player.send(.repeatMode) }
        let strings = PlayerStrings(resolve: { text in
            if customText, text == .play { return demoText("Start listening") }
            if customText, text == .pause { return demoText("Take a break") }
            if text == .queue { return String(format: demoText("Up next · %d"), model.queue.entries.count) }
            return PlayerStrings.localized(text)
        })
        let images = PlayerImages { icon in
            if customImages, icon == .play { return Image("DemoPlay").renderingMode(.template) }
            if customImages, icon == .pause { return Image("DemoPause").renderingMode(.template) }
            return Image(systemName: icon.systemName)
        }
        return PlayerContext(state: PlayerState(snapshot: model.queue.snapshot,
            subtitle: demoText("Cadenza Sessions · Original demo"), context: demoText("EVENING ROTATION"),
            footer: demoText("Original WAV · Local playback"), shuffle: model.queue.isShuffleEnabled, repeatMode: model.queue.repeatMode),
            appearance: appearance, strings: strings, images: images, actions: actions)
    }

    private var components: PlayerComponents {
        var value = PlayerComponents()
        value.set(.artwork) { context in
            DemoArtwork(index: currentIndex, title: currentTitle)
                .frame(maxWidth: context.appearance.metrics.artworkMaximum)
                .clipShape(RoundedRectangle(cornerRadius: context.appearance.metrics.artworkRadius))
                .shadow(color: colors.artworkShadow, radius: context.appearance.metrics.artworkShadowRadius, y: context.appearance.metrics.artworkShadowY)
        }
        if customButtons {
            value.setButton { button in
                Button(action: button.perform) {
                    Text(button.label).font(.caption.bold()).padding(8)
                        .background(colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                #if os(tvOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.plain)
                #endif
                .disabled(!button.enabled)
                    .accessibilityIdentifier(button.control.rawValue)
            }
        }
        return value
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                chrome
                if empty {
                    CadenzaPlayerView(context: context, components: components, layout: .empty)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("empty-canvas")
                } else {
                    #if os(tvOS)
                    CadenzaPlayerView(context: context, components: components, arrangement: .horizontal)
                        .onPlayPauseCommand { player.send(.playPause) }
                    #else
                    if geometry.size.width >= 850 { desktop(width: geometry.size.width) }
                    else { CadenzaPlayerView(context: context, components: components, arrangement: .vertical) }
                    #endif
                }
            }
            .background(colors.background).foregroundStyle(colors.foreground).tint(colors.accent)
        }
        .preferredColorScheme(appearanceMode == 0 ? nil : appearanceMode == 1 ? .light : .dark)
        .sheet(item: $panel) { panel in
            let title = demoText(panel == .options ? "Customize" : panel == .queue ? "Up next" : "Equalizer")
            #if os(tvOS)
            VStack(spacing: 24) {
                HStack {
                    Text(title).font(.title2)
                    Spacer()
                    Button(demoText("Done")) { self.panel = nil }.accessibilityIdentifier("done")
                }.focusSection()
                panelContent(panel)
            }.padding(40).frame(width: 1000, height: 850)
                .background(colors.background).foregroundStyle(colors.foreground)
                .buttonStyle(.bordered)
                .onExitCommand { self.panel = nil }
            #else
            NavigationStack {
                panelContent(panel).navigationTitle(title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(demoText("Done")) { self.panel = nil }.accessibilityIdentifier("done") } }
            }
            #if os(macOS)
            .frame(width: 600, height: 650)
            #else
            .frame(minWidth: 300, minHeight: 450)
            #endif
            .tint(colors.accent)
            #endif
        }
    }

    private func panelContent(_ panel: Panel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if panel == .options { options }
                else if panel == .queue { queue }
                else { sound }
            }.padding(24)
        }
    }
    private var chrome: some View {
        ViewThatFits(in: .horizontal) {
            chromeRow(compact: false)
            chromeRow(compact: true)
        }
        .font(.caption).demoButtonStyle().padding(.horizontal, 16).padding(.vertical, 8)
        #if os(tvOS)
        .tint(colors.controlBackground)
        #endif
    }

    private func chromeRow(compact: Bool) -> some View {
        HStack(spacing: 12) {
            if !compact { Text("CadenzaKit").font(.caption.weight(.semibold)) }
            Spacer(minLength: 0)
            Button(demoText("Default")) { empty = false }.accessibilityIdentifier("layout-default")
            Button(demoText("Empty")) { empty = true }.accessibilityIdentifier("layout-empty")
            Button { panel = .options } label: {
                if compact { Image(systemName: "slider.horizontal.3").frame(minWidth: 28, minHeight: 28) }
                else { Label(demoText("Customize"), systemImage: "slider.horizontal.3") }
            }
            .accessibilityLabel(demoText("Customize")).accessibilityIdentifier("customize")
        }.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func desktop(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Text("CadenzaKit.").font(.title2.bold())
                Button(demoText("Listen now")) { library = true }.accessibilityIdentifier("library")
                Button(demoText("Evening rotation")) { library = false }.accessibilityIdentifier("collection")
                Button(demoText("Up next")) { panel = .queue }.accessibilityIdentifier("sidebar-queue")
                Spacer()
                Button(demoText("Equalizer")) { panel = .sound }.accessibilityIdentifier("sidebar-sound")
            }.buttonStyle(.plain).padding(24).frame(width: 180).frame(maxHeight: .infinity)
                .background(colors.foreground.opacity(0.035))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(demoText(library ? "YOUR OWN RHYTHM" : "YOUR COLLECTION")).font(.caption).tracking(2)
                    Text(demoText(library ? "A little room to listen." : "Evening rotation")).font(.largeTitle.weight(.semibold))
                    Text(String(format: demoText("%d original tracks"), model.tracks.count)).foregroundStyle(.secondary)
                    #if os(iOS)
                    albumGrid
                    #else
                    if library { albumGrid } else { trackRows }
                    #endif
                }.padding(24)
            }.frame(maxWidth: .infinity)
            Divider()
            CadenzaPlayerView(context: context, components: components, arrangement: .vertical)
                .frame(width: min(350, width * 0.30))
        }
    }

    private var albumGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 24) {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                Button { player.send(.select(index)) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        DemoArtwork(index: index, title: track.title).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(track.title).font(.subheadline)
                        Text(demoText("Cadenza Sessions")).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).disabled(player.busy).accessibilityIdentifier("track-\(index)")
            }
        }
    }

    private var trackRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                Button { player.send(.select(index)) } label: {
                    HStack(spacing: 14) {
                        DemoArtwork(index: index, title: track.title).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                            Text(demoText("Cadenza Sessions")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.queue.snapshot.resource?.id == track.id { Image(systemName: "waveform") }
                    }.padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(player.busy).accessibilityIdentifier("track-\(index)")
                Divider()
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(demoText("Search demo tracks"), text: $search).textFieldStyle(.plain).accessibilityIdentifier("search")
            ForEach(Array(model.tracks.enumerated()).filter { search.isEmpty || $0.element.title.localizedCaseInsensitiveContains(search) }, id: \.element.id) { index, track in
                Button(track.title) { player.send(.select(index)); panel = nil }
                    .disabled(player.busy).accessibilityIdentifier("queue-track-\(index)")
            }
            Divider()
            Button(demoText("Save position")) { player.send(.saveBookmark) }
                .disabled(model.queue.snapshot.resource == nil || player.busy).accessibilityIdentifier("save")
            Button(demoText("Resume saved")) { player.send(.resumeBookmark); panel = nil }
                .disabled(model.saved == nil || player.busy).accessibilityIdentifier("resume")
            Button(demoText("Stop")) { player.stop(); panel = nil }.accessibilityIdentifier("stop")
            Text(LocalizedStringKey(model.message)).font(.caption).accessibilityIdentifier("status")
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(demoText("Changes affect presentation only. Playback stays in CadenzaKit.")).font(.subheadline)
            HStack {
                Text(demoText("Title size")); Spacer()
                Button("−") { titleSize = max(18, titleSize - 2) }.accessibilityLabel(demoText("Smaller title"))
                Text("\(Int(titleSize))")
                Button("+") { titleSize = min(36, titleSize + 2) }.accessibilityLabel(demoText("Larger title")).accessibilityIdentifier("larger-title")
            }
            #if os(tvOS)
            .focusSection()
            #endif
            HStack {
                Button(demoText("Green")) { accent = 0 }
                Button(demoText("Indigo")) { accent = 1 }.accessibilityIdentifier("accent-indigo")
                Button(demoText("Orange")) { accent = 2 }
            }
            #if os(tvOS)
            .frame(maxWidth: .infinity, alignment: .leading).focusSection()
            #endif
            Toggle(demoText("Custom Play/Pause assets"), isOn: $customImages).accessibilityIdentifier("custom-assets")
            Toggle(demoText("Custom labels"), isOn: $customText).accessibilityIdentifier("custom-labels")
            Toggle(demoText("Replace every button"), isOn: $customButtons).accessibilityIdentifier("custom-buttons")
            Button(demoText("Reset appearance")) { titleSize = 24; accent = 0; customImages = false; customText = false; customButtons = false }.accessibilityIdentifier("reset-appearance")
            Divider()
            HStack {
                Text(demoText("Appearance"))
                Button(demoText("System")) { appearanceMode = 0 }.accessibilityIdentifier("appearance-system")
                Button(demoText("Light")) { appearanceMode = 1 }.accessibilityIdentifier("appearance-light")
                Button(demoText("Dark")) { appearanceMode = 2 }.accessibilityIdentifier("appearance-dark")
            }
            #if os(tvOS)
            .focusSection()
            #endif
            Button(demoText("Forward 5 seconds")) { player.send(.seek(min(model.queue.snapshot.duration, model.queue.snapshot.position + 5))) }
                .disabled(model.queue.snapshot.resource == nil).accessibilityIdentifier("seek-forward")
            Button(demoText("Shuffle")) { player.send(.shuffle) }.accessibilityIdentifier("settings-shuffle")
            Button(demoText("Repeat")) { player.send(.repeatMode) }.accessibilityIdentifier("settings-repeat")
            Button(demoText("Up next")) { panel = .queue }.accessibilityIdentifier("show-queue")
        }.demoButtonStyle()
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(demoText("Native AVAudioEngine equalizer · CadenzaKit capability checks")).font(.subheadline)
            HStack {
                Button(demoText("Warm bass")) { Task { await player.setSound(bass: true) } }.accessibilityIdentifier("warm-bass")
                Button(demoText("Bypass")) { Task { await player.setSound(bass: false) } }.accessibilityIdentifier("bypass")
            }.frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusSection()
            #endif
            Text(demoText(player.soundSettings.isBypassed ? "Equalizer bypassed" : "Equalizer enabled"))
                .font(.headline).accessibilityIdentifier("sound-state")
            soundControl("Preamp", frequency: nil)
            ForEach([Float(120), 1000, 8000], id: \.self) { frequency in
                soundControl("\(Int(frequency)) Hz", frequency: frequency)
            }
            Text(demoText("Adjustments enable the equalizer. Reduce preamp when boosting bands to avoid clipping."))
                .font(.caption).foregroundStyle(.secondary)
            Text(player.soundMessage).accessibilityIdentifier("sound-status")
        }.demoButtonStyle().disabled(player.soundBusy)
    }

    private func soundControl(_ title: String, frequency: Float?) -> some View {
        let gain = frequency.map { frequency in player.soundSettings.bands.first { $0.frequency == frequency }?.gain ?? 0 } ?? player.soundSettings.preamp
        let identifier = frequency.map { "eq-\(Int($0))" } ?? "eq-preamp"
        return HStack {
            Text(demoText(title)).frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await player.adjustSound(frequency: frequency, delta: -1) } } label: { Image(systemName: "minus").frame(minWidth: 28, minHeight: 28) }
                .disabled(gain <= -24).accessibilityLabel("\(demoText("Decrease")) \(demoText(title))")
                .accessibilityIdentifier(identifier + "-decrease")
            Text("\(Int(gain)) dB").monospacedDigit().frame(minWidth: 64)
                .accessibilityIdentifier(identifier + "-value")
            Button { Task { await player.adjustSound(frequency: frequency, delta: 1) } } label: { Image(systemName: "plus").frame(minWidth: 28, minHeight: 28) }
                .disabled(gain >= 24).accessibilityLabel("\(demoText("Increase")) \(demoText(title))")
                .accessibilityIdentifier(identifier + "-increase")
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

private extension View {
    @ViewBuilder func demoButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.bordered)
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}
