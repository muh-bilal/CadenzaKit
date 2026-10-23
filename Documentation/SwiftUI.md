# Customizable SwiftUI player

Select the optional **CadenzaSwiftUI** product. It depends on CadenzaDomain and the
UI-independent **CadenzaPresentation** snapshot projection. CadenzaKit and its
playback backends do not depend on SwiftUI. Supports iOS/iPadOS
17+, macOS 14+, and tvOS 17+.

The view receives a `PlayerContext`: a snapshot of SDK state, presentation data,
and host action handlers. It does not create an engine, own a queue, persist state,
or bypass service-layer feature/capability checks. Refresh its state when your
presentation model receives new SDK snapshots.

```swift
import SwiftUI
import CadenzaDomain
import CadenzaSwiftUI

struct HostPlayer: View {
    let snapshot: PlaybackSnapshot
    let playPause: () -> Void

    var body: some View {
        CadenzaPlayerView(context: PlayerContext(
            state: PlayerState(snapshot: snapshot),
            actions: PlayerActions(controls: [.playPause: playPause])
        ))
    }
}
```

Handlers should call your SDK-backed presentation model and surface any errors.
Missing handlers hide optional controls and disable essential transport controls.
The UI cannot authorize an unavailable source, output, backend, or feature.

## Defaults and customization

All built-in appearance values have defaults in `PlayerAppearance`. Change them
individually without copying the layout:

```swift
var appearance = PlayerAppearance()
appearance.fonts.title = .system(size: 28, weight: .medium, design: .rounded)
appearance.metrics.iconSize = 22
appearance.light.accent = .orange
appearance.dark.accent = .yellow
appearance.light.onAccent = .black
appearance.metrics.primarySize = 72
appearance.metrics.primaryRadius = 16
appearance.metrics.spacing = 20
```

Light/dark palettes, typography, spacing, padding, artwork bounds/aspect ratio,
corners, shadows, control sizes and responsive layout thresholds are configurable.
Fonts are SwiftUI `Font` values, so hosts can use system or their own bundled fonts.
Use `.vertical`, `.horizontal` or `.automatic` for `arrangement`.

Replace icon images, including Play and Pause, with assets in **your** bundle:

```swift
let images = PlayerImages { icon in
    switch icon {
    case .play: Image("MyPlayAsset", bundle: .main).resizable()
    case .pause: Image("MyPauseAsset", bundle: .main).resizable()
    default: Image(systemName: icon.systemName)
    }
}
```

Replace every static and accessibility label using `PlayerStrings.resolve` and
replace time formatting using `PlayerStrings.time`. Defaults use the SDK's
English/German localization resources. Track titles, subtitle, context and footer
come from host data; no sample artists, durations, route names or quality claims
are embedded in the SDK UI.

```swift
let strings = PlayerStrings(
    resolve: { key in key == .play ? "Start listening" : PlayerStrings.localized(key) },
    time: { seconds in "\(Int(seconds))s" }
)
```

## Replace components or the entire layout

Design tokens are conveniences, not limits. `PlayerComponents` can replace the
background, header, artwork, metadata, progress control, transport, accessories
or footer with arbitrary SwiftUI views:

```swift
var components = PlayerComponents()
components.set(.artwork) { _ in
    Image("AlbumCover", bundle: .main).resizable().scaledToFit()
}
components.setButton { button in
    Button(action: button.perform) {
        Text(button.label).font(.headline).padding()
    }
    .disabled(!button.enabled)
    .accessibilityLabel(button.label)
}
```

The button context includes its role, current icon (including Play/Pause),
selection state, availability, label and action. A custom button owns its own
colors, dimensions, shape, focus/pressed feedback and accessibility. The same
applies to custom sections; preserve useful labels, touch targets and TV focus.

For complete layout ownership, use `components.setLayout { context in ... }`.
This replaces all SDK chrome, sizing and styling. Alternatively,
`CadenzaPlayerView(context: context, layout: .empty)` renders **nothing**: no
placeholder, controls, background or padding. Compose your own views around the
same state/actions. Switching layouts does not change the playback session.

The SDK includes no artwork, fonts, audio or icon packs. SF Symbols are the default
icons; hosts provide media visuals. The default player uses a compact artwork-led
layout or a wide artwork/detail arrangement, with system accessibility and focus
behavior. tvOS exposes progress as a read-only indicator; replace the progress
component to add a host-specific remote scrubbing interaction.
