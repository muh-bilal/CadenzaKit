# Build, test, and delivery automation

The root Swift package and `Examples/CadenzaDemo/CadenzaDemo.xcodeproj` are the
sources of truth. No published package is needed to build the demo.

## GitHub Actions

**SDK and demo validation** runs on pull requests, pushes to `main`, version tags
(`v*`), and manual dispatch. Four macOS runner jobs validate native macOS,
iPhone, iPad, and tvOS independently. They run the entire SDK test suite on each
platform, build the demo in Release configuration, and retain test results for
seven days. The Mac job additionally enforces 100% executable-line coverage for
every owned SDK source file, checks every independently selectable product, and
runs the demo model tests, including real playback and bookmark persistence.
Coverage and test success are separate gates. Real HTTPS and Apple audio-adapter
tests are required; unavailable network/audio infrastructure fails the job.

**Player UI validation** runs when demo, SwiftUI, presentation, player facade, system playback,
playback session/queue, UI-test, package, or UI-workflow inputs change. Documentation-only and unrelated service changes
do not trigger it. Run it manually for broader integration checks after backend
changes. Version tags also run the UI matrix. Each platform runs its full UI
suite once; local iteration should select the tests affected by the change.
Do not make this path-filtered workflow a required status check on every PR:
GitHub can leave a filtered workflow pending. Use the always-triggered SDK jobs
as required checks and review UI results when relevant.

Both workflows use `macos-15` with Xcode 26.3, read-only repository permissions,
SHA-pinned official actions, cancellation of superseded runs, and bounded job
timeouts. Simulator identifiers are discovered from installed runtimes rather
than hardcoded. Missing runtimes fail explicitly. Update the pinned Xcode path
when the hosted runner image changes; see the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

Manual or version-tag SDK runs also deliver zipped demo build artifacts. Mac
artifacts use ad-hoc signing; iPhone/iPad/TV artifacts are simulator builds.
These are development artifacts, not notarized apps or device-installable IPAs.
There is no automatic GitHub Release, package-registry, TestFlight, or App Store
publication. The workflows need no signing secrets. A distribution pipeline
requires an explicitly selected license, release policy, and signing setup.

Workflow files take effect after they are pushed. Local validation does not
establish that a GitHub-hosted run passed. Hosted UI tests require a functioning
graphical session; a runner permission or infrastructure failure must be fixed,
not converted into a skip.

## Local validation

Select a full Xcode installation, then run from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift Tools/SimulatorDestination.swift --self-test
swift Tools/Validate.swift Local
swift Tools/ValidateConsumers.swift
```

Use a fresh run name instead of `Local` on subsequent runs: the validator refuses
to overwrite evidence. Results stay in ignored `.build/validation/` directories.
Pass `macOS`, `iPhone`, `iPad`, or `tvOS` as the second argument to validate one
platform. Mac validation also runs SwiftPM coverage checks. The report inventories
all files under `Sources/`; presentation and adapters are not excluded.

For a changed demo capability, select its targeted UI test:

```sh
xcodebuild test -project Examples/CadenzaDemo/CadenzaDemo.xcodeproj \
  -scheme CadenzaiOS \
  -destination "$(swift Tools/SimulatorDestination.swift iPhone)" \
  -only-testing:CadenzaiOSUITests/ShowcaseTests/testEqualizerControlsAndCompactToolbar \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=-
```

Use `CadenzamacOS` / `platform=macOS` for native Mac tests and `CadenzatvOS` /
`tvOS` for Apple TV. Native Mac UI tests require an unlocked graphical session
and XCTest UI Automation permission. Do not run competing UI suites in the same
session. Simulator checks cannot establish physical audio routes, VoiceOver
quality, or real remote hardware behavior.

Workflow trigger and filter behavior follows [GitHub's workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).
