# CadenzaKit maintenance guide

These instructions apply throughout this repository. Read the relevant source,
tests and documentation before changing behavior; preserve unrelated work.

## Product and architecture

CadenzaKit is a modular Swift 6 audio SDK for iOS/iPadOS 17+, macOS 14+ and tvOS
17+. `Package.swift` defines independently selectable products. The single Xcode
example project consumes this checkout through a relative package reference.

Keep these responsibilities separate:

| Module | Responsibility |
| --- | --- |
| `CadenzaDomain` | Value types, errors, capability contracts and dependency protocols |
| `CadenzaKit` | Service composition, playback session/queue, playlists, bookmarks and feature policy |
| `CadenzaPlayer` | App-facing facade, automatic progress and system playback coordination |
| `CadenzaAVPlayback`, `CadenzaAudioEngine` | Apple playback backends; native equalization belongs to the audio-engine backend |
| `CadenzaLocalSources`, `CadenzaRemoteSources` | Source resolution and catalog/metadata adapters |
| `CadenzaPersistence`, `CadenzaDownloads`, `CadenzaArtwork` | Storage, transfer and artwork adapters |
| `CadenzaSystemPlayback` | Apple audio-session, Now Playing and remote-command integration |
| `CadenzaCarPlay` | Host catalog lifecycle and optional native iOS CarPlay templates |
| `CadenzaPresentation`, `CadenzaSwiftUI` | UI-independent presentation state and optional configurable views |
| `CadenzaTesting` | Reusable deterministic testing dependencies |

- Author implementation and tooling in Swift. Keep domain/service logic independent
  of UI frameworks; avoid dependency cycles and abstractions without consumers.
- Apps supply their catalog, media identifiers, accessible URLs, authorization and
  credentials. Do not assume an arbitrary website URL is playable audio.
- App transport commands should use the retained `CadenzaPlayer` so phone, system
  and CarPlay controls share queue state and immediately publish system metadata.
  Lower-level services remain available for explicit custom orchestration.
- Enforce optional flags in services, with current source, backend, platform and
  output-route capabilities. Hiding a button is not enforcement. Keep optional
  system playback and CarPlay opt-in; test disabled and revoked capabilities.
- Preserve structured errors, cooperative cancellation, actor isolation and
  generation checks against stale async results. Inject clocks, randomness,
  storage, networking and playback dependencies for deterministic tests.
- Hosts own lifecycle forwarding, background modes, entitlements and provisioning.
  The SDK cannot grant CarPlay entitlements or guarantee playback after force-quit.
- Preserve customizable UI defaults, host-supplied assets/text, localization,
  accessibility, Dynamic Type, light/dark appearance and platform layouts.
- Use SF Symbols by default. SDK products must not bundle demo audio, artwork,
  fonts or custom icon packs. Keep appropriately licensed media in examples.
- No mandatory third-party playback engine. Document Apple-framework codec,
  streaming, DRM and output limitations instead of exposing placeholder APIs.

## Implementing a change

Finish one coherent capability at a time: define acceptance criteria, implement
the vertical slice, add meaningful tests, validate affected dependencies, review
the diff, then commit when authorized. Include persistence and real integration
where the capability requires them. Do not start dependent work while a required
gate is failing or unavailable.

Cover success, failure, cancellation, concurrent operations, state transitions,
feature-disabled behavior and persistence. Mock tests alone do not validate Apple
adapters; retain native integration tests and affected platform checks. Do not
disable, weaken or skip failing tests to obtain a green result.

## Validation

Run from the repository root with a full Xcode installation selected:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift Tools/SimulatorDestination.swift --self-test
swift Tools/Validate.swift UniqueRunName
swift Tools/ValidateConsumers.swift
```

Use a new run name each time. `Validate.swift` runs SwiftPM tests/coverage and
native package tests on macOS, iPhone, iPad and tvOS. An optional second argument
selects one platform for iteration. Run the full required SDK regression before
committing implementation changes. `ValidateConsumers.swift` checks each product
can be selected independently. Inspect failures and the actual coverage report.

Test success and coverage are separate gates. Require 100% executable-line
coverage for owned SDK code, including new lines. The validator inventories every
Swift source under `Sources/`; it also checks native CarPlay adapter coverage on
each platform. Do not exclude adapters, presentation or error paths, lower the
threshold, or add assertion-free tests to satisfy the metric. Explicitly document
any generated or third-party exclusions; none justify blanket SDK exclusions.

Run affected demo model and UI tests for changes to views, focus, interaction,
app lifecycle or system integration. During iteration select only the relevant
tests; do not repeatedly run unchanged UI suites. Do not run competing UI suites
in the same graphical session. Documentation-only changes need link/path and diff
checks, not an unchanged UI regression. See [Testing.md](Documentation/Testing.md)
for commands and CI behavior.

Keep test logs, coverage, derived data and result bundles in ignored
`.build/validation/` or temporary directories. Report commands, results and
limitations accurately. Simulator success does not establish physical lock-screen,
Bluetooth/AirPlay, interruption or in-car behavior. The native iOS lock-screen
test is device-only and physical validation remains outstanding; do not report it
as passed based on simulator results. Obtain authorization before using a device.

## Example project and documentation

- Maintain one project: `Examples/CadenzaDemo/CadenzaDemo.xcodeproj`.
  Its schemes are `CadenzaiOS` (iPhone/iPad), `CadenzamacOS` and `CadenzatvOS`.
- Change project membership/settings in `Examples/CadenzaDemo/GenerateProject.swift`,
  run `swift GenerateProject.swift` from that directory, and commit regenerated
  project/scheme files. Do not hand-edit generated project settings alone.
- Keep demo transport and policy in the SDK. Demo code composes services, provides
  original media and demonstrates default, empty and customized layouts.
- Keep README concise. Put public API examples and limitations in
  [Integration.md](Documentation/Integration.md), UI configuration in
  [SwiftUI.md](Documentation/SwiftUI.md), and media attribution in
  [Media.md](Documentation/Media.md). Update documentation with behavior changes.
- Distinguish actual app screenshots from design concepts. Do not present
  unimplemented design features as working SDK capabilities.

## Git and delivery

- Review `git status` and the diff; stage only intended files. Preserve unrelated
  user changes and existing commits. Do not rewrite history without authorization.
- Commit only when authorized and required gates pass. Never push, publish,
  create a release or alter remote history without explicit authorization.
- Do not commit credentials, local signing identities, build/test artifacts,
  internal conversation notes or private planning ledgers.
- Keep GitHub Actions superseded-run cancellation enabled. Local checks are not
  evidence that hosted CI, a release or a device validation has run.
