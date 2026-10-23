import Foundation
import AVFAudio
import CadenzaDomain

/// Prepares the process audio session immediately before playback. The host must
/// declare UIBackgroundModes/audio on iOS, iPadOS and tvOS and retain its player.
/// macOS playback does not require an AVAudioSession or background entitlement.
@MainActor
public final class AppleSystemPlaybackController: SystemPlaybackController {
    private let prepare: () throws -> Void

    public convenience init(bundle: Bundle = .main) {
        self.init {
            #if os(iOS) || os(tvOS)
            guard (bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true else {
                throw CadenzaError.featureUnavailable(.systemPlayback, .platform)
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            #endif
        }
    }

    // Injection exercises session failures without modifying global OS state.
    init(prepare: @escaping () throws -> Void) { self.prepare = prepare }

    public func prepareForPlayback() throws {
        try Task.checkCancellation()
        do { try prepare() }
        catch let error as CadenzaError { throw error }
        catch { throw CadenzaError.playbackFailure(String(describing: error)) }
    }
}
