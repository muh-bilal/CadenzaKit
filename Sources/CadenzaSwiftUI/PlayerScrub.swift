import CadenzaPresentation
import CadenzaDomain
import SwiftUI

/// Keeps playback polling from moving the thumb during an interactive scrub.
/// A gesture produces one seek, and cannot seek a replacement track.
struct PlayerScrub {
    private(set) var isEditing = false
    mutating func begin() { pending = false; isEditing = true }
    private var target: Double?
    private var pending = false
    private var resource: MediaID?

    func position(in state: PlayerState) -> Double {
        guard (isEditing || pending), resource == state.snapshot.resource?.id, let target else { return state.position }
        return min(target, state.duration)
    }

    mutating func update(_ value: Double, in state: PlayerState) {
        guard value.isFinite else { return }
        resource = state.snapshot.resource?.id
        target = min(state.duration, max(0, value))
    }

    mutating func finish(in state: PlayerState) -> Double? {
        isEditing = false
        guard !pending, resource == state.snapshot.resource?.id, let target else { return nil }
        pending = true
        return min(target, state.duration)
    }

    mutating func cancel() {
        isEditing = false
        pending = false
        target = nil
        resource = nil
    }
}

extension PlayerScrub {
    @MainActor static func synchronizing(_ scrub: Binding<Self>) -> (PlaybackSnapshot, PlaybackSnapshot) -> Void {
        { old, new in
            if old.resource?.id != new.resource?.id || !scrub.wrappedValue.isEditing { scrub.wrappedValue.cancel() }
        }
    }
    @MainActor static func binding(_ scrub: Binding<Self>, state: PlayerState) -> Binding<Double> {
        Binding(get: { scrub.wrappedValue.position(in: state) }, set: { value in
            guard scrub.wrappedValue.isEditing, value.isFinite else { return }
            scrub.wrappedValue.update(value, in: state)
        })
    }

    @MainActor static func editing(_ scrub: Binding<Self>, state: PlayerState, seek: ((Double) -> Void)?) -> (Bool) -> Void {
        { editing in
            if editing { scrub.wrappedValue.begin() }
            else if let target = scrub.wrappedValue.finish(in: state) { seek?(target) }
        }
    }
}

extension PlayerScrub {
    @MainActor static func adjusting(_ scrub: Binding<Self>, state: PlayerState, step: Double, seek: ((Double) -> Void)?) -> (AccessibilityAdjustmentDirection) -> Void {
        { direction in
            guard step.isFinite, step > 0 else { return }
            scrub.wrappedValue.cancel()
            if direction == .increment { seek?(min(state.duration, state.position + step)) }
            else if direction == .decrement { seek?(max(0, state.position - step)) }
        }
    }
}
