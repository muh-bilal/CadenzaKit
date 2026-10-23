#if os(iOS)
import UIKit
import CarPlay
import CadenzaCarPlay
import CadenzaDomain

/// The scene supplies presentation only; the SDK owns catalog and playback policy.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var library: CarPlayLibrary?
    private var connection: Task<Void, Never>?
    private var navigation: Task<Void, Never>?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        connection?.cancel()
        connection = Task { [weak self] in
            guard let self else { return }
            let shared = Showcase.shared
            await shared.start()
            guard let model = shared.model else {
                await showFailure(interfaceController, message: demoText("Unable to open demo"))
                return
            }
            let tracks = model.tracks.map { media in
                CarPlayTrack(entry: .init(id: UUID(), mediaID: media.id), title: media.title, subtitle: media.artist)
            }
            let catalog = [CarPlaySection(title: demoText("Original demo audio"), tracks: tracks)]
            let library = CarPlayLibrary(player: model.player) { catalog }
            self.library = library
            do {
                try await library.reload()
                try Task.checkCancellation()
                let template = library.makeTemplate(title: "CadenzaDemo", emptyTitle: demoText("No music"),
                    emptySubtitle: demoText("Add tracks to your source"),
                    onPlaybackStarted: { [weak self, weak interfaceController] in
                        guard let self, let interfaceController else { return }
                        self.navigation?.cancel()
                        self.navigation = Task {
                            do { _ = try await interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) }
                            catch { await self.showFailure(interfaceController, message: self.message(for: error)) }
                        }
                    }, onFailure: { [weak self, weak interfaceController] error in
                        guard let self, let interfaceController else { return }
                        self.navigation = Task { await self.showFailure(interfaceController, message: self.message(for: error)) }
                    })
                _ = try await interfaceController.setRootTemplate(template, animated: false)
            } catch is CancellationError { }
            catch { await showFailure(interfaceController, message: message(for: error)) }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        connection?.cancel(); navigation?.cancel(); library?.disconnect()
        connection = nil; navigation = nil; library = nil
    }

    private func showFailure(_ controller: CPInterfaceController, message: String) async {
        guard !Task.isCancelled else { return }
        if controller.rootTemplate == nil {
            let empty = CPListTemplate(title: "CadenzaDemo", sections: [])
            empty.emptyViewTitleVariants = [demoText("Playback unavailable")]
            empty.emptyViewSubtitleVariants = [message]
            do { _ = try await controller.setRootTemplate(empty, animated: false) }
            catch { Showcase.shared.reportCarPlayFailure(String(describing: error)) }
            return
        }
        let dismiss = CPAlertAction(title: demoText("Done"), style: .default) { _ in
            controller.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [dismiss])
        do { _ = try await controller.presentTemplate(alert, animated: true) }
        catch { Showcase.shared.reportCarPlayFailure(String(describing: error)) }
    }

    private func message(for error: any Error) -> String {
        switch error {
        case CadenzaError.carPlayDisabled: demoText("CarPlay is disabled in this app.")
        case CadenzaError.featureUnavailable(_, .disabled): demoText("System playback is disabled in this app.")
        default: demoText("Music is unavailable. Reconnect to try again.")
        }
    }
}
#endif
