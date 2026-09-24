# CadenzaKit

A modular Swift music SDK for iOS/iPadOS 17+, macOS 14+, and tvOS 17+.
Swift 6 concurrency checking is enabled.

## Implemented

- `CadenzaDomain`: validated media identity, resolved resources, structured errors,
  and a concurrency-safe source-provider contract.
- `CadenzaKit`: immutable, injectable provider registry and cancellable resolution.
- `CadenzaTesting`: closure-based source providers for host tests.

No playback backend is implemented yet. The facade resolves media locations; it
does not assert that a URL is playable or that the host has permission to read it.

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

The package has no external dependencies, UI requirement, bundled media, fonts,
or icon packs. SDK resources, when introduced, are limited to localization.
The repository license is pending the owner's explicit choice; no distribution
license or publication permission is implied.