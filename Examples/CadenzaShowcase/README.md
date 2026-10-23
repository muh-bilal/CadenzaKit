# CadenzaKit Xcode examples

Open **CadenzaShowcase.xcodeproj** in Xcode 16 or later. It references the root
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

`App/CadenzaShowcase.swift` contains SwiftUI layouts and app lifecycle handling.
The project compiles the same `DemoModel.swift` as the standalone macOS example:

- `Cadenza` configures the source provider and creates SDK services.
- `LocalFileSource` resolves demo tracks; `AVPlayerBackend` plays them.
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

## Audio

Three original synthesized arpeggios are generated in the app cache at launch.
They belong to the examples and are dedicated to **CC0-1.0**. No media, artwork,
fonts or custom icons are added to SDK products. Playback uses system output
volume. No network access is required.

Set `CADENZA_DEMO_CACHE_DIRECTORY` in the scheme environment to override the
generated-audio directory. Invalid or unwritable locations produce a visible
startup error; bookmark storage remains in the app's normal persistent store.

## Tests and maintenance

Each shared scheme includes a UI test exercising real AVPlayer playback, queue
navigation, shuffle/repeat, seeking, saving and resume across relaunch. Apple TV
uses directional remote events and Select. Run the iOS scheme on both iPhone and
iPad. The shared model also has deterministic and real-adapter tests:

```sh
swift test --package-path ../CadenzaDemo --enable-code-coverage
xcodebuild test -project CadenzaShowcase.xcodeproj -scheme CadenzamacOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```

Simulator tests do not establish physical audio routes, VoiceOver quality or Siri
Remote hardware behavior. The demo presents local playback and bookmarks; other
SDK services have examples in the [integration guide](../../Documentation/Integration.md).

To change target settings or file membership, edit `GenerateProject.swift`, run
`swift GenerateProject.swift` here, and commit the regenerated project. Build
outputs and test results belong outside this tracked directory.
