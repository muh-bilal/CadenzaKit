import AppKit
import CadenzaAVPlayback
import CadenzaPersistence

@MainActor
public enum DemoApplication {
    /// A directory override keeps automated runs separate from personal demo data.
    /// The injected event loop lets tests validate launch and teardown synchronously.
    public static func run(directory: URL? = nil, eventLoop: () -> Void = { NSApplication.shared.run() }) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); item.submenu = submenu
        submenu.addItem(withTitle: "Quit CadenzaDemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = menu
        let support = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CadenzaDemo")
        let cache = try directory ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CadenzaDemo")
        let tracks = try DemoAudio.create(in: cache)
        let store = try AtomicFileStore(fileURL: support.appendingPathComponent("bookmarks.json"))
        let model = try DemoModel(tracks: tracks, backend: AVPlayerBackend(), store: store)
        let controller = DemoWindow(model: model)
        controller.start()
        app.activate(ignoringOtherApps: true)
        eventLoop()
        controller.shutdown()
        controller.window.close()
    }
}
