# CadenzaKit

**Your music player. Your UI.**

A modular Swift music-player SDK for iOS/iPadOS 17+, macOS 14+, and tvOS 17+.
Compose local or HTTPS playback, queues, playlists, bookmarks, artwork, offline
storage, and native equalization through independently selectable package products.
Your app owns the UI; the SDK owns playback and service logic.

[Integration guide](Documentation/Integration.md) · [Xcode example apps](Examples/CadenzaDemo) · [Build and test](Documentation/Testing.md)

Optional [SwiftUI components](Documentation/SwiftUI.md) provide configurable defaults
and full component/layout replacement without coupling UI to playback services.

## Usage

Add `https://github.com/muh-bilal/CadenzaKit` in Xcode's **Add Package Dependencies**
using the `main` branch. For local playback, select `CadenzaKit`, `CadenzaDomain`,
`CadenzaLocalSources`, and `CadenzaAVPlayback`. Requires Swift 6.

```swift
import Foundation
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaAVPlayback

@MainActor
func playFile(_ url: URL) async throws -> PlaybackSession {
    let media = MediaResource(id: try MediaID("track"), url: url, title: "My track")
    let source = try LocalFileSource(resources: [media.id: media])
    let kit = try Cadenza(
        configuration: .init(defaultProvider: source.identifier),
        providers: [source]
    )
    let player = kit.makeSession(backend: AVPlayerBackend())
    try await player.load(media.id)
    try await player.play()
    return player
}
```

Pass an accessible local audio URL and retain the returned session. Your app drives
`refresh()` for progress/EOF and calls `stop()` when finished. See the
[integration guide](Documentation/Integration.md) for feature flags, optional
products, persistence, capability checks, and complete usage examples.

Open `Examples/CadenzaDemo/CadenzaDemo.xcodeproj` and select `CadenzaiOS`
(iPhone/iPad), `CadenzamacOS`, or `CadenzatvOS`. Each app uses this checkout's
CadenzaKit package for playback, queue behavior, saved positions and equalization.
Choose **Default** for the supplied player layout, **Empty** for a blank SDK view,
or **Customize** to change fonts, colors, assets, labels and button implementations.

## Screenshots

Actual Xcode example apps using the Default layout and original demo media.

<table>
<tr><th>iPhone</th><th>iPad</th></tr>
<tr>
<td align="center"><img src="Documentation/Images/showcase-iphone.png" height="380" alt="CadenzaKit iPhone player with customizable transport controls"></td>
<td align="center"><img src="Documentation/Images/showcase-ipad.png" height="380" alt="CadenzaKit iPad album grid and player"></td>
</tr>
<tr><th>Native Mac</th><th>Apple TV</th></tr>
<tr>
<td><img src="Documentation/Images/showcase-mac.png" width="480" alt="CadenzaKit native Mac library and player"></td>
<td><img src="Documentation/Images/showcase-tv.png" width="480" alt="CadenzaKit Apple TV player with remote controls"></td>
</tr>
</table>
The SDK and demos are under development. Opt-in background audio is available through `systemPlayback: true`. Lock-screen metadata and remote transport integration are not yet implemented.
[Detailed capabilities and limitations](Documentation/Integration.md)
