# CadenzaDemo — macOS listening room

A small native AppKit application consuming CadenzaKit through a local Swift
package dependency. Requires macOS 14+ and the Swift 6 toolchain. No signing team,
credentials, network service or third-party project generator is needed.

From the repository root:

```sh
swift run --package-path Examples/CadenzaDemo CadenzaDemo
```

Or build a local `.app` bundle:

```sh
cd Examples/CadenzaDemo
swift BuildApp.swift
open .build/CadenzaDemo.app
```

If your active developer directory points only to Command Line Tools, prefix
commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
The helper produces a development build with coverage instrumentation; it is not
a signed/notarized distribution archive. Quit with Command-Q or the app menu.

## Try it

1. Choose one of the three original arpeggios. The real AVPlayer backend plays it.
2. Pause/resume, seek with the position slider, or select another track.
3. Toggle shuffle and cycle repeat through off/all/one. EOF advances the queue.
4. Save a position, quit, relaunch, and choose **Resume bookmark**.
5. Resize the window or use your system's light/dark appearance. Controls expose
   accessibility labels and use SF Symbols.

The demo does not autoplay at launch. Each synthesized sketch is 24 seconds long
at a modest signal amplitude; playback uses your current system output volume.
The example demonstrates the implemented core SDK, not the planned full showcase
family: it has no system Now Playing/remote commands, background audio integration,
file import, lyrics, downloads UI, EQ UI or playlist editor. It is macOS-only and
does not implement system playback integration or physical remote-control support.

## Where the SDK is used

- `DemoModel.swift`: constructs a `LocalFileSource`, configures the `Cadenza` facade,
  injects a playback backend/document store, and creates the queue/bookmark services.
  Commands call SDK services; the UI does not implement queue policy or persistence.
- `DemoWindow.swift`: native presentation and controls; serializes user commands
  against the 200 ms progress refresh to avoid overlapping playback operations.
- `DemoApplication.swift`: composes the real AVPlayer and atomic-file adapters,
  owns the window lifetime, and supplies the application event loop.
- `DemoAudio.create`: generates original audio into the example app's cache. No
  example audio, artwork or UI is bundled in any SDK product.

Generated media is stored in `~/Library/Caches/CadenzaDemo`. The single saved
position is stored in `~/Library/Application Support/CadenzaDemo/bookmarks.json`.
Only this example's own demo files are regenerated on launch. Test runs use
temporary directories and injected playback/storage dependencies.

## Test

```sh
swift test --package-path Examples/CadenzaDemo --enable-code-coverage
```

Tests cover actual generated audio through AVPlayer, durable resume after service
recreation, all commands, EOF, failures/cancellation, bootstrap/storage errors,
native target/action dispatch, accessibility labels and light/dark view rendering.

## Media license

The generated arpeggios are original mathematical signals authored for this
example and dedicated to the public domain under **CC0 1.0**:
https://creativecommons.org/publicdomain/zero/1.0/
Track titles are fictional. SF Symbols are provided by the OS. This media dedication
does not choose or change the repository's software distribution license.
