# CadenzaKit integration guide

[Overview and screenshots](../README.md) · [Run the Xcode example apps](../Examples/CadenzaDemo/README.md)

[Optional customizable SwiftUI player](SwiftUI.md): use the default skin, override
design tokens/assets/text/components, or supply a completely empty/custom layout.

A modular Swift music SDK for iOS/iPadOS 17+, macOS 14+, and tvOS 17+.
Swift 6 concurrency checking is enabled.

Jump to [local playback](#local-playback), [queue](#queue-and-history),
[bookmarks](#persistent-position-bookmarks), [playlists](#persistent-playlists),
[artwork](#optional-artwork-loading), [downloads](#progressive-offline-audio-downloads), or
[equalizer](#equalizer-and-presets).

## Implemented

- `CadenzaDomain`: validated media identity, resolved resources, structured errors,
  and a concurrency-safe source-provider contract.
- `CadenzaKit`: immutable, injectable provider registry and cancellable resolution.
- Initialization-time feature flags and runtime capability intersection, enforced
  by the resolution service before invoking the selected source provider.
- `CadenzaTesting`: closure-based source providers for host tests.
- `CadenzaLocalSources`: explicit local-file catalog with identity and access checks.
- `CadenzaAVPlayback`: local AVPlayer adapter, injected into a deterministic session.
- `CadenzaPersistence`: transactional atomic-file and bounded preferences stores.

Resolution alone does not assert that a URL is playable. Loading through the
backend validates media; the host owns file permissions/security-scoped access.

```swift
import CadenzaDomain
import CadenzaKit

// mySource implements SourceProvider and handles the host's media identifiers.
let kit = try Cadenza(
    configuration: .init(defaultProvider: mySource.identifier),
    providers: [mySource]
)
let resource = try await kit.resolve(MediaID("album/track-1"))
```

Providers must support concurrent calls and cancellation. A cancelled caller never
receives a successfully resolved result, including when a provider ignores
cancellation. Non-cooperative providers cannot be forcibly terminated by Swift.
Unknown source errors are wrapped in `CadenzaError.sourceFailure`; cancellation
remains `CancellationError`. Hosts decide how to localize and display errors.

`configuration.features.sourceResolution` controls the implemented resolution
operation. `availability(for:provider:)` returns a structured denial reason with
precedence: disabled, source, backend, platform, output route. The injected
`runtimeCapabilities` closure is evaluated on every query/operation, not cached.
The default snapshot permits resolution, which itself needs no audio route.
`playback` and `seeking` flags control session commands. Sessions additionally check
the actual backend's declared support. Pause/stop remain available when permission
is revoked so the host can always halt playback. Runtime snapshots are policy,
not physical route discovery. The optional system playback adapter configures the
audio session; hosts still supply route-specific policy.

## Local playback

```swift
import CadenzaDomain
import CadenzaKit
import CadenzaLocalSources
import CadenzaAVPlayback

// Execute on MainActor. Use a URL your app is permitted to read.
let id = try MediaID("track-1")
let media = MediaResource(id: id, url: fileURL, title: "Track")
let source = try LocalFileSource(resources: [id: media])
let kit = try Cadenza(configuration: .init(defaultProvider: source.identifier), providers: [source])
let session = kit.makeSession(backend: AVPlayerBackend())
try await session.load(id)
try await session.play()
try await session.refresh()
let snapshot = session.snapshot
```

Use one backend instance per session. Session and backend operations are serialized
on MainActor for Apple media APIs; they do not depend on UI frameworks. Async load
and seek reject competing commands with `operationInProgress`. `stop()` invalidates
pending work and returns to idle; stale completions cannot overwrite newer state.
Backend failures require reload. Invalid seeks and denied transport commands retain
the previous state. `refresh()` explicitly samples progress/EOF; no timer is hidden
inside the session. Loading supports finite local media only. Integration tests
validate real decode/seek/progress/EOF, not physical speaker audibility, interruptions,
background execution, or output-route behavior.

## Background audio

Select the optional `CadenzaSystemPlayback` product alongside your playback backend.
The flag defaults to `false` and is enforced by the session/queue service.

```swift
import CadenzaSystemPlayback

let kit = try Cadenza(
    configuration: .init(defaultProvider: source.identifier,
                         features: .init(systemPlayback: true)),
    providers: [source]
)
let queue = kit.makeQueue(backend: AVPlayerBackend(),
                          systemPlayback: AppleSystemPlaybackController())
// Insert entries, then start playback normally.
// Forward host lifecycle changes on MainActor:
queue.setBackgrounded(true)  // scene enters background; Mac is hidden/minimized
queue.setBackgrounded(false) // returns to foreground; never auto-resumes
```

For **iOS/iPadOS and tvOS**, enable Audio in Background Modes in the app target
(`UIBackgroundModes` must contain the string `audio`). A package cannot add this
host setting. The adapter checks the host bundle and sets the shared
`AVAudioSession` category to `.playback`, mode `.default`, then activates it just
before playback. Missing background mode or a missing adapter produces
`featureUnavailable(.systemPlayback, .platform)`; native activation errors become
`playbackFailure`. For **macOS**, no background audio entitlement or audio-session
configuration is required. Keep the owner alive independently of windows.

Retain the session/queue at app scope and continue calling `refresh()` during
playback, including in the background, so EOF, queue transitions and A–B loops
continue. Do not stop it in a view's `onDisappear`. The demo shows this ownership
and lifecycle forwarding. With the flag disabled, backgrounding pauses loaded
media and invalidates pending loads; background play is denied. Foregrounding
never resumes automatically. Foreground playback works without the adapter when
the flag is disabled.

The source, backend, platform and output-route capability intersection also applies.
Background refresh rechecks permission and pauses if revoked. Device-output
`AVAudioEngineBackend` and `AVPlayerBackend` advertise support; offline/manual
rendering does not. Inject route policy for restrictions particular to your host.
The adapter does not deactivate the process-wide session on every pause, because
other audio clients may share it; the host coordinates those clients.

Background audio is not a guarantee against force-quit, OS termination, media
unavailability, or audio interruptions. The service reflects a stopped native
backend as paused and does not implement automatic interruption recovery. Now
Playing metadata, lock-screen/Control Center transport commands, AirPlay route
selection, and Bluetooth route management are separate, unimplemented integrations.
Simulator/native-Mac checks do not establish physical-device lock-screen or route
behavior. Validate those with your app's real media and target hardware.

## Queue and history

`kit.makeQueue(backend:)` creates an in-memory playback queue. Insert `QueueEntry`
values with explicit occurrence UUIDs; duplicate media IDs are supported. Insert,
remove and move validate indices/identities before mutation. Removing the active
entry stops playback; removing an unplayed entry does not alter playback. `play()`
resumes the selected entry; `play(entryID)` explicitly selects/restarts an occurrence.
`next()` and `previous()` maintain a successful-playback history, including forward
navigation after going back. Failed selections do not create history entries.
`refresh()` samples playback and advances on EOF; the final item remains ended.
AVPlayer EOF uses its actual end notification, not a duration-equality assumption.

`FeatureFlags.queueManagement` gates queue mutations/commands. Ordering unresolved
IDs requires no audio capability; selection delegates to the session's live source,
backend, platform and route checks. History is session-local; durable history is
not claimed. The caller owns refresh cadence. Queue edits are rejected during
pending operations, and `stop()` invalidates pending selections.

`setShuffle(true)` permutes unvisited occurrence IDs without changing `entries`.
Backward/forward history takes precedence over new shuffled choices. New entries
join the remaining permutation; deletions remove them. Disabling shuffle restores
canonical next-entry ordering and preserves history. A completed cycle does not
silently restart. Explicit entry selection may intentionally replay a visited item.
Configure `FeatureFlags.shuffle` at facade initialization; inject a generator with
`makeQueue(backend:random:)` for reproducible tests. `CadenzaTesting` provides
`SeededRandomGenerator`; production defaults to `SystemRandomNumberGenerator`.

`setRepeat(.one)` restarts the selected item at EOF without adding duplicate
history entries; manual next still advances. `setRepeat(.all)` wraps canonical
order or starts a fresh shuffle cycle. Shuffle repeat avoids immediate boundary
repetition unless only one entry exists. `.off` restores finite traversal.
`FeatureFlags.repeatPlayback` gates activation. Repeat-one requires live seeking
and playback capabilities and reports a structured error if they are unavailable.

## A–B looping

`try await session.setLoop(LoopRange(start: a, end: b))` enables a finite interval
within the loaded media. The queue exposes the same operation. Pass `nil` to clear.
`FeatureFlags.abLooping` gates activation; each boundary crossing checks live
seeking/playback capabilities. A denied loop pauses safely. Paused sessions do not
restart; stop and media replacement clear the range. A loop ending at EOF takes
precedence over queue/repeat advancement. `refresh()` is async because it can seek;
hosts choose its cadence. AVPlayer looping is not sample-accurate or guaranteed
gapless: timing depends on refresh cadence and actual seek latency. Integration
tests use a 20 ms refresh interval and check landing within 20 ms of A.

The package has no external dependencies, UI requirement, bundled media, fonts,
or icon packs. SDK resources are localization and required privacy metadata.
The repository license is pending the owner's explicit choice; no distribution
license or publication permission is implied.

## Persistent position bookmarks

`kit.makeBookmarks(store:now:)` creates a service with injected document storage
and time. `save`, `all`, `bookmark`, and `remove` provide named bookmark CRUD;
`capture` saves a session's actual sampled position. `resume(_:in:autoplay:)`
loads and seeks in one serialized session operation, defaulting to no autoplay.
Multiple named bookmarks can reference the same track. A shortened/missing asset
or unavailable seeking capability produces a structured error rather than silently
clamping the bookmark. `bookmarks` and `persistence` flags are enforced before I/O.

Use `AtomicFileStore(fileURL:)` in host-selected Application Support storage on
iOS/macOS. `PreferencesDocumentStore(suiteName:key:maximumBytes:)` supports small
tvOS documents, bounding the entire named suite to at most 256 KiB. Use a dedicated
host-owned suite and budget the app's other defaults usage separately. tvOS file
cache storage is purgeable and is not a durable bookmark store. Preferences writes
flush asynchronously; neither adapter promises physical-disk fsync or survival of
device failure/uninstall. [Apple tvOS storage guidance](https://developer.apple.com/videos/play/wwdc2023/10256/)
and [defaults limits](https://developer.apple.com/documentation/foundation/userdefaults/sizelimitexceedednotification).

All services for one document must share one store actor. Transform failures and
pre-commit cancellation preserve the previous document; cancellation after the
synchronous commit boundary does not undo a successful write. Cross-process writers
are not supported. Bookmarks use a version-1 JSON archive, validate decoded values,
reject duplicate IDs/future schemas, and preserve corrupt bytes for host recovery.
Tests recreate stores/sessions and read real persisted data on every platform;
device reboot, power-loss durability, and tvOS purge behavior are not claimed tested.

## Persistent playlists

`kit.makePlaylists(store:now:)` provides `create`, `playlist`, `all`, `rename`, and
`delete`. Use a separate document/key from bookmarks. Playlist IDs are stable;
display names may repeat, while empty/whitespace-only names and duplicate IDs are
rejected. Listing uses deterministic name/UUID ordering. Transactions preserve
unrelated playlists under concurrent edits. `playlists` and `persistence` flags
gate every operation before storage access. The service reads version-1 metadata
archives and writes version 2 on mutation; unknown schemas and duplicate IDs are
rejected without resetting data. This prevents older clients from silently losing
entry content. Version-1 reads alone do not rewrite the document.

`insert(_:into:at:)`, `removeEntry(_:from:)`, and `moveEntry(_:in:to:)` edit ordered
`QueueEntry` occurrences transactionally. Duplicate media IDs are permitted; entry
UUIDs must be unique within a playlist. Rename preserves entries. Invalid indices,
missing entries, cancellation before commit, and failed writes preserve prior data.

`playlists.play(_:in:startingAt:)` starts an independent queue snapshot at the
requested occurrence (or the first/shuffled entry). Later persistent edits or
deletion do not mutate playback. Queue replacement validates IDs and empty input
before stopping existing playback; cancelled requests do not replace it. Once a
valid snapshot is installed, source/playback failure is surfaced with that snapshot
retained, no selected entry, and no successful history entry. The host owns and
cancels pending playlist-read tasks; queue stop invalidates selection once begun.

`exportPlaylist(_:)` and `importPlaylist(_:as:)` use a separate interchange envelope
`{"format":"CadenzaKit.Playlist","version":1,"playlist":…}` capped at 1 MiB.
The `playlistInterchange` flag gates both operations. Import preserves metadata,
entry order and duplicate media; an optional new UUID permits an intentional copy.
Existing playlist IDs are never overwritten implicitly. Imports validate registered
providers but leave media IDs opaque until playback; they never initiate media or
network access. Malformed/unsupported/oversized input is rejected before storage,
and each import is one atomic transaction.

## Local library indexing

`kit.makeLibrary(root:namespace:store:catalog:metadata:)` creates an actor-isolated
index. Inject `LocalFileCatalog()` and `AVMetadataReader()` for real local files.
`scan()` persists one complete snapshot, reports metadata failures per file, reuses
unchanged size/modification-time fingerprints, and retains missing records. IDs
combine the namespace and relative path, surviving root relocation; renaming a
track creates a new identity. Symlinks and hidden files are skipped. The host owns
sandbox access. Fingerprints are not content hashes, and scans do not lock files
against external edits; a subsequent scan reconciles changes.

`all()`, `search(_:includeUnavailable:)`, and `resource(_:)` read the saved index.
Search folds case/diacritics; empty queries return all eligible records. Missing
and unreadable media never resolve as playable. A `CatalogFileSource` lookup can
call `library.resource` to connect the index to existing sessions/queues. Metadata
includes title (filename fallback), artist, album, and duration through AVFoundation;
codec support is platform-dependent. No filesystem watcher or system music-library
permission is implied. `libraryIndexing` and `persistence` gate service operations.

Cancelled scans preserve the previous index; overlapping scans reject explicitly.
Concurrent writers sharing the store detect snapshot conflicts rather than lose
updates. Use a separate document/key and stable namespace per library. File storage
on tvOS remains purgeable; bounded preferences are suitable only for small indexes.

## Smart playlists

`kit.makeSmartPlaylists(store:library:)` persists `SmartPlaylist` definitions in a
separate version-1 document. `save` explicitly upserts by UUID, `all` lists definitions,
`delete` removes them, and `evaluate` returns a current library snapshot. Results
exclude unavailable items. Rules contain 1–32 typed predicates: case/diacritic-folded
title/artist/album substrings or inclusive finite duration ranges, combined with
`.all` or `.any`. Empty text is rejected. Sort by title, artist, album or duration,
ascending/descending, with media-ID tie-breaking and an optional positive limit.
Missing artist/album fields sort as empty strings. Evaluation never mutates a queue.
The `smartPlaylists`, `playlists`, and `persistence` flags gate the service; library
access also enforces its own policy. Nested expressions, play-count predicates,
automatic queue synchronization and cloud rule sharing are not implemented.

## Optional artwork loading

Select `CadenzaArtwork` and inject `AppleArtworkLoader()` through
`kit.makeArtwork(loader:limits:)`, using validated `ArtworkLimits`. `load(id)`
resolves media through the configured source and reads its embedded artwork;
`loadImage(at:)` reads a caller-selected local image. Both enforce the `artwork`
flag. Missing embedded artwork returns nil; malformed containers, inaccessible
files and exceeded limits throw structured errors. The result contains encoded
bytes and pixel dimensions, without UIKit/AppKit/SwiftUI dependencies.

The Apple loader uses [AVFoundation metadata](https://developer.apple.com/documentation/avfoundation/retrieving-media-metadata)
and [ImageIO container inspection](https://developer.apple.com/documentation/imageio/cgimagesource).
Standalone reads are bounded. Embedded metadata is materialized by AVFoundation
before the returned byte/pixel limits can be checked; no streaming extraction or
hard framework-allocation ceiling is promised. Container validation does not decode
every pixel. This loader reads local artwork; other artwork operations use separate services. Hosts retain sandbox access; no images are SDK resources.

`kit.makeArtworkThumbnails(processor:maximumCacheBytes:)` accepts the optional
`ImageIOArtworkProcessor`. `thumbnail(_:maximumDimension:)` decodes/downsamples the
first image with orientation applied, preserves aspect ratio, and returns PNG data.
Dimensions must be 1–4096 pixels. The actor's LRU cache uses SHA-256 of source bytes
plus requested size, so changed content cannot reuse stale thumbnails. It bounds
encoded payload bytes (default 16 MiB) and entries (256); this is not a hard process
memory ceiling. Oversized results remain usable but are not cached. Concurrent
misses may process independently; cache accounting remains correct.

`artworkDownsampling` gates processing; `artworkCaching = false` permits processing
without retention. `removeAll()` clears cached data and prevents already-running
requests from repopulating it. Cancelled/failed requests never insert results.
`cachedBytes`/`cachedCount` expose usage. The host can clear on memory pressure.
No disk cache, animation playback, or preemptive interruption of ImageIO's synchronous
decode call is promised; cancellation is checked before and after framework work.

`kit.makeArtworkExport(exporter: FileArtworkExporter())` exports encoded bytes to
an explicit local URL. The `artworkExport` and `artwork` flags gate access. The default
refuses existing destinations, including concurrent writers: it stages in the same
directory and publishes via a hard link. Volumes that do not support hard links fail
explicitly. `overwrite: true` requests Foundation's atomic replacement. Existing
staging-name collisions are preserved. Cancellation before publication cleans up
staging; cancellation after a completed write does not undo the export. The adapter
does not promise fsync/power-loss durability. Hosts own sandbox access and choose
the filename extension matching the encoded bytes; export performs no conversion.

## Direct HTTPS playback

Select `CadenzaRemoteSources` for `HTTPSCatalogSource`, an explicit ID-to-resource
catalog. It accepts HTTPS URLs with a host and rejects inline credentials/fragments;
resolution validates identity without requesting the network. Opt in through
`FeatureFlags(remotePlayback: true)` and `AVPlayerBackend(allowRemote: true)`.
Sessions check `.remotePlayback` against source/backend/platform/output policy before
loading and again on transport commands. Pause/stop remain available after denial.
TLS/redirect handling is owned by AVFoundation and host transport-security settings;
no custom trust bypass is installed.

The provider supports finite media playable by AVFoundation. Live/indefinite
duration streams fail explicitly. Actual seeking depends on asset/server support.
The source adds no provider authentication, custom request headers, remote artwork
or offline storage. Normal session factories have no retry/deadline policy; resilient
factories below provide explicit opt-in recovery. A required real HTTPS
integration streams a small sample; [provenance and license](Media.md)
are recorded separately from SDK resources. Network failure fails validation.

## Bounded network preparation and buffering

Enable `networkRecovery` and call `makeResilientSession` or `makeResilientQueue`
with a validated `NetworkRecoveryPolicy` and optional injected `PlaybackClock`.
For remote loads, each attempt has a timeout; only timeouts, offline and selected
connection failures retry. Attempts are bounded to 1–5, deadlines to five minutes,
and retry delay to one minute. Permanent errors (including TLS trust failures) are
not retried. Exhaustion reports attempts and a structured network reason. Local
loads use the normal backend path. Recovery is opt-in; normal factories retain
their existing behavior.

AVPlayer preparation now cancels its AVURLAsset on task cancellation or stop.
The timeout races load against the injected clock and cancels the losing task.
Custom backends must cooperate with cancellation; Swift cannot forcibly terminate
arbitrary injected code. Stop/replacement invalidates retries and stale completions.
`BackendStatus.isBuffering` maps AVPlayer's waiting state to `.buffering` on refresh;
ready-to-play and paused transitions remain explicit. This policy recovers load
preparation only: it does not automatically restart an interrupted playing item,
change networks, or promise seamless recovery from midstream outages.

## Progressive offline audio downloads

Select `CadenzaDownloads` for `URLSessionAudioTransfer`, and inject it with
`FileOfflineAudioStore` and `AVMetadataReader` through `kit.makeDownloads`.
Enable `downloads` at facade initialization and `allowsDownloads` on the HTTPS
catalog only for media the host is permitted to store. Download capability is checked
against source/runtime policy before transfer. `download(_:provider:as:)` uses a
caller-selected offline ID; duplicate IDs reject. `all()` lists persisted records,
and `resource(_:)` resolves local files for `CatalogFileSource`/normal playback.

Transfers require HTTP 200, reject HTTPS-to-HTTP redirects, enforce declared and
actual byte counts, and validate the complete audio with AVFoundation before
publishing it. The initial implementation buffers each bounded transfer in memory:
16 MiB default, configurable up to 64 MiB. Larger streaming-to-disk/background or
resumable downloads and HLS/DRM persistence are not implemented. URLs must have a
supported progressive-audio extension. URLSession request/resource timeouts are
30/120 seconds; failed/oversized requests are cancelled. No automatic download retry
is implied by playback recovery policy.

Use a dedicated store directory and one actor per directory. Imports stage audio,
validate it, publish the file, then atomically update the version-1 catalog. Failed
validation/index writes and pre-commit cancellation clean up newly created files.
Overlapping imports into one store reject explicitly. File names derive from IDs
with SHA-256, so IDs cannot traverse directories. Missing/purged files fail resolution;
catalog metadata is retained. Process termination between file publication and index
commit can leave an orphan for storage reconciliation. No fsync guarantee is made.
tvOS storage is purgeable and does not guarantee permanent offline availability.

## Offline storage management

`FileOfflineAudioStore(maximumStoredBytes:)` enforces a catalog-accounted byte quota
(default 1 GiB) before staging a new import. This quota does not count unrelated
files or crash orphans as active downloads. `kit.makeDownloadStorage(store:)` requires
`storageManagement`, `downloads`, and `persistence`. `usage()` reports catalog bytes,
actual available audio bytes, orphan bytes and missing IDs separately.

`remove(_:)` commits catalog removal before deleting the audio; any retained file
is reported explicitly. `trim(to:protecting:)` evicts oldest-created records first,
breaking ties by ID, and returns remaining catalog bytes. Protected IDs can prevent
reaching the requested target; hosts should protect active playback themselves.
`reconcile()` drops missing catalog records and removes recognized unindexed audio
or staging files. It preserves unknown names, directories and symlinks, including
an indexed audio path externally replaced by a directory. Use a dedicated directory:
recognized SHA-256-style audio filenames are treated as SDK-owned.

Mutations reject during an active import. A failed catalog commit preserves audio;
failed file cleanup leaves a reported orphan for a later reconciliation. Cancellation
is checked before the synchronous commit boundary; completed mutations are not
undone afterward. Optional `commitIndex`/`removeFile` closures support coordinated I/O
and deterministic failure testing; custom commits must preserve atomic replacement.
The host owns cleanup cadence and disk-pressure decisions. No cross-process writer,
automatic OS eviction callback or physical power-loss durability is claimed.

## Decoded local audio engine

Select `CadenzaAudioEngine` and inject `AVAudioEngineBackend()` into existing session
or queue factories. It uses AVAudioFile/AVAudioPlayerNode for finite local audio;
HTTPS and unsupported assets reject explicitly. Play, pause, frame-based seeking,
EOF and stop share the existing facade policy/state machine. Files exceeding
`UInt32.max` decoded frames are rejected because one scheduled segment is bounded
by AVAudioFrameCount. Codec/container support is whatever AVAudioFile can decode
on the current platform; no universal codec or gapless guarantee is implied.
Device-output EOF uses the native played-back completion callback; generation
tokens prevent old seek/stop callbacks from ending a replacement segment.

`AVAudioEngineBackend(output: .manual)` drives the same graph without hardware I/O.
After play, `render(frames:)` accepts 1–4096 frames and returns the native render
status plus PCM buffer; callers handle partial/retry statuses and drive progress.
This supports deterministic DSP validation and host offline processing. Device
output is the default. Tests validate actual PCM and real-time timeline/EOF on the
installed OS/simulators, not physical speaker audibility or background routes.
Local file preparation and manual render calls are synchronous framework work;
cancellation is cooperative at operation boundaries. Output mode is backend
configuration; facade playback/seeking flags still gate session/queue operations.

## Equalizer and presets

Enable `FeatureFlags(equalizer: true)` and use
`kit.makeEqualizer(backend: engineBackend, store: presetStore)`. `apply(_:provider:)`
checks source, actual backend, platform and output-route capabilities. Only the
decoded local AVAudioEngine backend implements DSP; AVPlayer and the HTTPS source
reject EQ. Runtime snapshots express host policy, not physical route verification.

`EqualizerSettings` supports up to 32 distinct parametric bands, 20–20,000 Hz,
−24…+24 dB per-band gain and preamp, and 0.05–5 octave bandwidth. Active frequencies
must be below the loaded file's Nyquist frequency. Loading a lower-rate file with
incompatible active settings fails explicitly. `bypass()` preserves settings and
remains available after policy revocation. Applying bypassed settings performs no
DSP; the backend revalidates when enabling them. No clipping prevention, loudness
normalization or processing of arbitrary system/DRM/HLS audio is provided.

`savePreset`, `presets`, `deletePreset` and `applyPreset` persist a versioned document
through the injected store. Preset IDs support explicit upsert; duplicate display
names are allowed, and listing sorts by name then ID. Use a dedicated document
store, with bounded preferences storage for durable small tvOS presets. Preset
operations additionally require `persistence`; direct settings do not. Native EQ
tests measure actual PCM gain and bypass, not just configuration values.
