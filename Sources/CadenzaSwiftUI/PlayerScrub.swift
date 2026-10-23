import CadenzaPresentation
import CadenzaDomain

/// Keeps playback polling from moving the thumb during an interactive scrub.
/// A gesture produces one seek, and cannot seek a replacement track.
struct PlayerScrub {
    private var target: Double?
    private var resource: MediaID?

    func position(in state: PlayerState) -> Double {
        guard resource == state.snapshot.resource?.id, let target else { return state.position }
        return min(target, state.duration)
    }

    mutating func update(_ value: Double, in state: PlayerState) {
        guard value.isFinite else { return }
        resource = state.snapshot.resource?.id
        target = min(state.duration, max(0, value))
    }

    mutating func finish(in state: PlayerState) -> Double? {
        defer { cancel() }
        guard resource == state.snapshot.resource?.id, let target else { return nil }
        return min(target, state.duration)
    }

    mutating func cancel() {
        target = nil
        resource = nil
    }
}

import SwiftUI

extension PlayerScrub {
    @MainActor static func binding(_ scrub: Binding<Self>, state: PlayerState) -> Binding<Double> {
        Binding(get: { scrub.wrappedValue.position(in: state) }, set: { scrub.wrappedValue.update($0, in: state) })
    }

    @MainActor static func editing(_ scrub: Binding<Self>, state: PlayerState, seek: ((Double) -> Void)?) -> (Bool) -> Void {
        { editing in
            if !editing, let target = scrub.wrappedValue.finish(in: state) { seek?(target) }
        }
    }
}
