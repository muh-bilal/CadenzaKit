import AppKit
import CadenzaDomain

/// Native example UI. No UI code or example assets are added to SDK products.
@MainActor
public final class DemoWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public let model: DemoModel
    public private(set) var buttons: [NSButton] = []
    public let position = NSSlider(value: 0, minValue: 0, maxValue: 24, target: nil, action: nil)
    public let status = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(labelWithString: "A little room to listen.")
    private let time = NSTextField(labelWithString: "0:00 / 0:24")
    private var actions: [DemoModel.Command] = []
    public private(set) var pending: Task<Void, Never>?
    private var timer: Timer?

    public init(model: DemoModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "CadenzaKit — Listening room"
        window.minSize = NSSize(width: 1000, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = NSStackView(); root.orientation = .horizontal; root.spacing = 0; root.alignment = .top
        root.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 28, right: 28)
        let sidebar = stack()
        sidebar.addArrangedSubview(label("cadenza.", size: 29, weight: .bold))
        sidebar.addArrangedSubview(label("YOUR LISTENING ROOM", size: 10, weight: .semibold, secondary: true))
        sidebar.addArrangedSubview(label("Evening rotation", size: 15, weight: .medium))
        sidebar.addArrangedSubview(label("3 original sketches\n24 seconds each\nGenerated on your Mac", size: 12, secondary: true))
        sidebar.addArrangedSubview(button("Resume bookmark", symbol: "bookmark", command: .resumeBookmark))
        sidebar.addArrangedSubview(label("Powered by CadenzaKit\nLocal playback · No account", size: 11, secondary: true))
        sidebar.widthAnchor.constraint(equalToConstant: 205).isActive = true
        let main = stack(); main.spacing = 16
        main.addArrangedSubview(label("COLLECTION / EVENING ROTATION", size: 11, weight: .semibold, secondary: true))
        main.addArrangedSubview(label("Your own rhythm.", size: 34, weight: .bold))
        main.addArrangedSubview(label("Original sounds. A small, open listening room.", size: 14, secondary: true))
        let artwork = NSImageView(); artwork.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Abstract waveform artwork")
        artwork.contentTintColor = NSColor.systemTeal; artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.heightAnchor.constraint(equalToConstant: 160).isActive = true
        artwork.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let heroText = stack(); heroText.spacing = 12
        heroText.addArrangedSubview(label("Evening rotation", size: 24, weight: .semibold))
        heroText.addArrangedSubview(label("Three short, original arpeggios.\nA quiet moment, made on your Mac.", size: 14, secondary: true))
        heroText.addArrangedSubview(label("LOCAL COLLECTION  /  01", size: 10, weight: .medium, secondary: true))
        let hero = NSStackView(views: [artwork, heroText]); hero.spacing = 24
        main.addArrangedSubview(hero)
        for (index, track) in model.tracks.enumerated() {
            let row = button("0\(index + 1)     \(track.title)                         0:24", symbol: "music.note", command: .select(index))
            row.alignment = .left; row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            main.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        title.font = .systemFont(ofSize: 19, weight: .semibold); main.addArrangedSubview(title)
        position.target = self; position.action = #selector(seek); position.isContinuous = false
        position.setAccessibilityLabel("Playback position in seconds")
        main.addArrangedSubview(position)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); time.textColor = .secondaryLabelColor
        main.addArrangedSubview(time)
        let transport = NSStackView(); transport.spacing = 10
        for (text, symbol, command) in [("Shuffle", "shuffle", DemoModel.Command.shuffle), ("Previous", "backward.end.fill", .previous), ("Play", "play.fill", .playPause), ("Next", "forward.end.fill", .next), ("Repeat", "repeat", .repeatMode), ("Save position", "bookmark.fill", .saveBookmark), ("Stop", "stop.fill", .stop)] {
            transport.addArrangedSubview(button(text, symbol: symbol, command: command))
        }
        main.addArrangedSubview(transport)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        main.addArrangedSubview(status)
        root.addArrangedSubview(sidebar); root.addArrangedSubview(main)
        window.contentView = root
        main.widthAnchor.constraint(greaterThanOrEqualToConstant: 570).isActive = true
        model.didChange = { [weak self] in self?.update() }
        update()
    }

    public func start() {
        window.makeKeyAndOrderFront(nil)
        pending = Task { await model.restore(); pending = nil }
        timer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    public func windowWillClose(_ notification: Notification) { shutdown() }

    public func shutdown() {
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
        model.queue.stop()
    }

    @objc public func tick() {
        guard pending == nil else { return }
        pending = Task { await model.refresh(); pending = nil }
    }

    @objc public func activate(_ sender: NSButton) { dispatch(actions[sender.tag]) }
    @objc public func seek(_ sender: NSSlider) { dispatch(.seek(sender.doubleValue)) }

    public func dispatch(_ command: DemoModel.Command) {
        guard pending == nil else { return }
        pending = Task { await model.perform(command); pending = nil }
    }

    public func update() {
        let snapshot = model.queue.snapshot
        title.stringValue = snapshot.resource?.title ?? "A little room to listen."
        time.stringValue = String(format: "%d:%02d / %d:%02d", Int(snapshot.position) / 60, Int(snapshot.position) % 60, Int(snapshot.duration) / 60, Int(snapshot.duration) % 60)
        position.maxValue = max(1, snapshot.duration); position.doubleValue = snapshot.position
        position.isEnabled = snapshot.resource != nil
        status.stringValue = model.message
        for (index, command) in actions.enumerated() {
            let button = buttons[index]
            switch command {
            case .playPause:
                button.title = snapshot.state == .playing ? "Pause" : "Play"
                button.image = NSImage(systemSymbolName: snapshot.state == .playing ? "pause.fill" : "play.fill", accessibilityDescription: button.title)
            case .shuffle: button.state = model.queue.isShuffleEnabled ? .on : .off
            case .repeatMode: button.title = "Repeat: \(model.queue.repeatMode.rawValue)"
            case .resumeBookmark: button.isEnabled = model.saved != nil
            case .saveBookmark, .stop: button.isEnabled = snapshot.resource != nil
            default: break
            }
            button.setAccessibilityLabel(button.title)
        }
    }

    private func button(_ text: String, symbol: String, command: DemoModel.Command) -> NSButton {
        let button = NSButton(title: text, target: self, action: #selector(activate))
        button.bezelStyle = .rounded; button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        button.imagePosition = .imageLeading; button.setAccessibilityLabel(text)
        button.tag = actions.count; actions.append(command); buttons.append(button)
        if command == .shuffle { button.setButtonType(.pushOnPushOff) }
        return button
    }

    private func stack() -> NSStackView {
        let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = 24
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }
}
