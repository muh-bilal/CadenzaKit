# CadenzaKit Xcode examples

Open **CadenzaDemo.xcodeproj** in Xcode 16 or later. It references the root
Swift package by relative path. No published package or generator installation
is needed.

| Scheme | Destinations | Interface |
| --- | --- | --- |
| `CadenzaiOS` | iPhone and iPad, iOS 17+ | Compact phone player; iPad library/detail split |
| `CadenzamacOS` | Native macOS 14+ | Resizable sidebar and player; no Catalyst |
| `CadenzatvOS` | Apple TV, tvOS 17+ | Large player, focusable controls, remote Play/Pause |

Choose a scheme and simulator or **My Mac**, then Run. For a physical device,
select your development team in Signing & Capabilities. No team ID is checked in.

## CadenzaKit owns the behavior

`App/DemoPlayerScreen.swift` composes the optional `CadenzaSwiftUI` player.
`App/CadenzaDemo.swift` handles app lifecycle and service composition.
The project compiles `App/DemoModel.swift` for all three platform targets:

- `Cadenza` configures the source provider and creates SDK services.
- `LocalFileSource` resolves demo tracks; `AVAudioEngineBackend` plays them and supplies native equalizer DSP.
- `PlaybackQueue` owns transport state, seeking, EOF advancement, history, shuffle
  and repeat. The UI reads its snapshot directly.
- `BookmarkService` saves and restores positions. iOS/macOS use `AtomicFileStore`;
  tvOS uses `PreferencesDocumentStore`, independent of purgeable cached audio.
- SDK errors are displayed. The app serializes commands; Stop cancels the active
  command and stops the SDK queue.

Choose a track, seek forward, save its position, close and reopen the app, then
select **Resume saved**. The apps refresh SDK progress while visible and stop
when entering the background. There is no background-audio entitlement or system
Now Playing integration.

Controls use SF Symbols, accessible labels, system fonts, light/dark appearance,
and English/German localization. Track titles are original media metadata; SDK
error diagnostics remain verbatim. iPad split view adapts to compact windows.

## Default, Empty, and customization

**Default** presents the reference-inspired player: warm neutral surfaces, green
transport controls, original album covers, and platform-adaptive composition.
Phone uses a vertical player, iPad an album grid with a player column, Mac a
library/list with a player column, and TV a spacious horizontal player.

**Empty** removes all SDK player content without replacing or stopping the
CadenzaKit session. The small example-owned layout selector remains available.
Switch back to Default to resume interacting with the same queue and position.

**Customize** changes title size, light/dark accent colors, Play/Pause image
assets, localized labels, or the complete button implementation. Reset restores
the defaults. The demo controls a subset of the API; hosts can replace every
section or the whole layout through `PlayerComponents`, and configure fonts,
colors, dimensions, image/text resolvers and actions through `PlayerContext`.
See the [SwiftUI integration guide](../../Documentation/SwiftUI.md).

**Equalizer** applies a real warm-bass setting through `EqualizerService`, or
bypasses DSP. Capability enforcement and playback state remain in CadenzaKit.
The example does not claim the concept artwork's fictional music, lyrics,
output routes or high-resolution audio metadata are implemented services.

## Audio and artwork

Four original synthesized arpeggios are generated in the app cache at launch.
They belong to the examples and are dedicated to **CC0-1.0**, together with
the original procedural covers and example-only Play/Pause image assets.
`GenerateAssets.swift` regenerates those image assets using Apple drawing APIs. No media, artwork,
fonts or custom icons are added to SDK products. Playback uses system output
volume. No network access is required.

Set `CADENZA_DEMO_CACHE_DIRECTORY` in the scheme environment to override the
generated-audio directory. Invalid or unwritable locations produce a visible
startup error; bookmark storage remains in the app's normal persistent store.

## Tests and maintenance

Each shared scheme includes a UI test exercising real AVAudioEngine playback, queue
navigation, shuffle/repeat, seeking, saving and resume across relaunch. Apple TV
uses directional remote events and Select. Run the iOS scheme on both iPhone and
iPad. The shared model also has deterministic and real-adapter tests:

```sh
xcodebuild test -project CadenzaDemo.xcodeproj -scheme CadenzamacOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```

Simulator tests do not establish physical audio routes, VoiceOver quality or Siri
Remote hardware behavior. The demo presents local playback, bookmarks, equalizer and customizable UI; other
SDK services have examples in the [integration guide](../../Documentation/Integration.md).

To change target settings or file membership, edit `GenerateProject.swift`, run
`swift GenerateProject.swift` here, and commit the regenerated project. Build
outputs and test results belong outside this tracked directory.
