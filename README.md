# CadenzaKit

A modular Swift music SDK for iOS/iPadOS 17+, macOS 14+, and tvOS 17+.
Swift 6 concurrency checking is enabled.

## Implemented

- `CadenzaDomain`: validated media identity, resolved resources, structured errors,
  and a concurrency-safe source-provider contract.
- `CadenzaKit`: immutable, injectable provider registry and cancellable resolution.
- Initialization-time feature flags and runtime capability intersection, enforced
  by the resolution service before invoking the selected source provider.
- `CadenzaTesting`: closure-based source providers for host tests.
- `CadenzaLocalSources`: explicit local-file catalog with identity and access checks.
- `CadenzaAVPlayback`: local AVPlayer adapter, injected into a deterministic session.

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
not physical route discovery; actual audio-session/route integration is later work.

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
or icon packs. SDK resources, when introduced, are limited to localization.
The repository license is pending the owner's explicit choice; no distribution
license or publication permission is implied.