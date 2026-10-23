import Testing
import SwiftUI
import CadenzaDomain
@testable import CadenzaSwiftUI

@Suite(.serialized) @MainActor
struct PlayerTests {
    func state(_ position: Double = 5, duration: Double = 24, playing: Bool = false) -> PlayerState {
        PlayerState(snapshot: .init(state: playing ? .playing : .paused, resource: nil, position: position, duration: duration))
    }

    @Test func safeProgressAndCommandDispatch() {
        #expect(state(-1).position == 0)
        #expect(state(99).position == 24)
        #expect(state(.nan).position == 0)
        #expect(state(1, duration: .infinity).duration == 0)
        #expect(state(1, duration: -1).duration == 0)
        #expect(state(playing: true).isPlaying)
        var invoked: [PlayerControl] = [], seeks: [Double] = []
        let actions = PlayerActions(controls: Dictionary(uniqueKeysWithValues: PlayerControl.allCases.map { control in (control, { invoked.append(control) }) }), seek: { seeks.append($0) })
        for control in PlayerControl.allCases { actions.callback(for: control)() }
        #expect(invoked == PlayerControl.allCases)
        PlayerActions().callback(for: .playPause)()
        let binding = actions.positionBinding(state())
        #expect(binding.wrappedValue == 5)
        binding.wrappedValue = 7; binding.wrappedValue = -1; binding.wrappedValue = 99; binding.wrappedValue = .nan
        #expect(seeks == [7, 0, 24])
        PlayerActions().positionBinding(state()).wrappedValue = 2
    }

    @Test func everyDefaultCanBeReplaced() {
        let defaults = PlayerStrings()
        for key in PlayerText.allCases { #expect(!defaults.resolve(key).isEmpty) }
        #expect(defaults.time(65) == "1:05")
        #expect(defaults.time(.nan) == "0:00"); #expect(defaults.time(-3) == "0:00")
        for icon in PlayerIcon.allCases { #expect(!icon.systemName.isEmpty); _ = PlayerImages().resolve(icon) }
        let strings = PlayerStrings(resolve: { "host:\($0.rawValue)" }, time: { "\(Int($0)) seconds" })
        #expect(strings.resolve(.play) == "host:Play"); #expect(strings.time(3) == "3 seconds")
        var style = PlayerAppearance()
        style.fonts.title = .system(size: 37); style.metrics.iconSize = 22
        style.light.accent = .orange; style.dark.onAccent = .black; style.metrics.primarySize = 72
        #expect(style.colors(for: .light).accent == .orange)
        #expect(style.colors(for: .dark).onAccent == .black)
        #expect(style.metrics.primarySize == 72)
        var components = PlayerComponents()
        let context = PlayerContext(state: state(), appearance: style, strings: strings, images: .init { _ in Image(systemName: "star") })
        for part in PlayerPart.allCases { components.set(part) { _ in Text("Host section") }; #expect(components.parts[part] != nil) }
        components.setLayout { _ in Text("Complete host layout") }
        components.setButton { button in Text(button.label) }
        #expect(components.layout != nil); #expect(components.button != nil)
        _ = context.images.resolve(.play)
    }

    @Test func renderStandardEmptyAndHostLayouts() throws {
        func render<V: View>(_ view: V) throws {
            let renderer = ImageRenderer(content: view.frame(width: 900, height: 900))
            #expect(renderer.cgImage != nil)
        }
        let controls = PlayerControl.allCases.reduce(into: [PlayerControl: () -> Void]()) { $0[$1] = {} }
        var context = PlayerContext(state: state(), actions: .init(controls: controls, seek: { _ in }))
        try render(CadenzaPlayerView(context: context, arrangement: .vertical))
        context.state.context = "Host context"; context.state.shuffle = true; context.state.repeatMode = .one
        context.state.snapshot = .init(state: .playing, resource: .init(id: try MediaID("demo"), url: URL(fileURLWithPath: "/demo.wav"), title: "Host title"), position: 5, duration: 24)
        try render(CadenzaPlayerView(context: context, arrangement: .horizontal).environment(\.colorScheme, .dark))
        context.state.repeatMode = .all
        try render(CadenzaPlayerView(context: context))
        try render(CadenzaPlayerView(context: .init(state: state()), arrangement: .vertical))
        try render(CadenzaPlayerView(context: context, layout: .empty).background(Color.clear))
        var components = PlayerComponents()
        components.set(.artwork) { _ in Color.orange }
        components.setButton { button in Text(button.label) }
        try render(CadenzaPlayerView(context: context, components: components))
        components.setLayout { value in Text(value.state.subtitle) }
        try render(CadenzaPlayerView(context: context, components: components))
        var replaced = false
        components.setLayout { _ in replaced = true; return Text("Host layout") }
        try render(CadenzaPlayerView(context: context, components: components, layout: .empty))
        #expect(!replaced)
    }
}

@MainActor @Test func scrubbingIgnoresPollingAndCommitsOnlyFinalTarget() throws {
    func snapshot(_ id: String, _ position: Double, duration: Double = 24) throws -> PlayerState {
        .init(snapshot: .init(state: .playing, resource: .init(id: try MediaID(id), url: URL(fileURLWithPath: "/test.wav"), title: id), position: position, duration: duration))
    }
    var scrub = PlayerScrub()
    let initial = try snapshot("first", 3)
    #expect(scrub.position(in: initial) == 3)
    #expect(scrub.finish(in: initial) == nil)
    scrub.update(8, in: initial)
    scrub.update(17, in: initial)
    scrub.update(.nan, in: initial)
    let polled = try snapshot("first", 4)
    #expect(scrub.position(in: polled) == 17)
    #expect(scrub.finish(in: polled) == 17)
    #expect(scrub.finish(in: polled) == nil)
    #expect(scrub.position(in: polled) == 4)
    scrub.update(-5, in: initial)
    #expect(scrub.finish(in: initial) == 0)
    scrub.update(99, in: initial)
    let shortened = try snapshot("first", 4, duration: 10)
    #expect(scrub.position(in: shortened) == 10)
    #expect(scrub.finish(in: shortened) == 10)
    scrub.update(12, in: initial)
    let replacement = try snapshot("second", 0)
    #expect(scrub.position(in: replacement) == 0)
    #expect(scrub.finish(in: replacement) == nil)
    scrub.update(12, in: initial)
    scrub.cancel()
    #expect(scrub.finish(in: initial) == nil)
}

@MainActor @Test func scrubBindingDefersSeeksUntilEditingEnds() {
    var scrub = PlayerScrub()
    let storage = Binding(get: { scrub }, set: { scrub = $0 })
    let state = PlayerState(snapshot: .init(state: .paused, resource: nil, position: 2, duration: 24))
    var seeks: [Double] = []
    let value = PlayerScrub.binding(storage, state: state)
    let editing = PlayerScrub.editing(storage, state: state, seek: { seeks.append($0) })
    editing(true)
    value.wrappedValue = 8
    value.wrappedValue = 18
    #expect(value.wrappedValue == 18)
    #expect(seeks.isEmpty)
    editing(false)
    editing(false)
    #expect(seeks == [18])
    value.wrappedValue = 5
    PlayerScrub.editing(storage, state: state, seek: nil)(false)
    #expect(value.wrappedValue == 2)
}
