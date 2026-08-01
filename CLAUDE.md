# CLAUDE.md

About Face — real-time non-visual (audio) feedback about webcam framing, lighting,
head pose, and other visible people, for blind and low-vision users on macOS.

**The authoritative design document is [docs/spec.md](docs/spec.md). Read the
relevant section before implementing anything; it is prescriptive about
architecture, protocol shapes, coordinate conventions, and state machines.**
This file only summarizes what you need on every task.

## Commands

```sh
swift build                                   # build core package + CLI harness
swift test                                    # run unit + corpus regression tests
swift format lint --strict --recursive Sources Tests   # formatting check (CI-enforced)
swiftlint                                     # lint (config: .swiftlint.yml)
xcodegen generate                             # (re)generate AboutFace.xcodeproj from project.yml
xcodebuild -project AboutFace.xcodeproj -scheme AboutFaceApp build  # build the app shell
```

Requires Xcode 16+ / Swift 6 toolchain, macOS 15 SDK; `brew install xcodegen`
for the app target.

The `.xcodeproj` is **generated and gitignored** — never hand-edit it or add
files/settings through Xcode's UI; edit `project.yml` (and `App/`) and rerun
`xcodegen generate`. App entitlements live in `App/AboutFace.entitlements`
(committed plain text; CI fails if a network entitlement appears — §2).

## Repository layout

```
Sources/AboutFaceCore/     Platform-independent core (capture, backends, analysis, feedback routing)
Sources/aboutface-cli/     Headless harness: runs camera or corpus clip, prints FrameAnalysis (Phase 1)
Tests/AboutFaceCoreTests/  Unit tests + corpus regression tests
Fixtures/corpus/           Test clip manifest (clips themselves are not committed; see Fixtures/corpus/README.md)
docs/spec.md               The spec. Section references (§N) throughout the code refer to it.
```

The app shell (`App/` + `project.yml`) is a thin SwiftUI layer over
`AboutFaceCore`; Phase 2 builds the real Setup window and debug panel inside it.
`App/` is compiled by the Xcode project, not SwiftPM (lint/format still cover
it); `swift test` does not — keep logic in `AboutFaceCore`, keep `App/` thin.

## Non-negotiable rules

These come from the spec and are correctness/shipping requirements. Do not
relax them; if a task seems to require it, stop and flag it to the maintainer.

- **Egocentric coordinates (§3.4).** All directional output is from the user's
  point of view ("move left" = toward the user's own left hand). Mirroring is
  resolved exactly once — at the backend→`FaceGeometry` boundary, driven by an
  explicit `MirrorState` — and everything downstream is already egocentric.
  Inverted directions are the single worst failure mode of this product. Any
  change touching coordinates must keep the mirror-convention tests passing in
  both mirrored and unmirrored configurations.
- **No network, ever (§2).** The entitlements file must never contain
  `network.client` or `network.server`. No analytics, no crash-reporting SDKs,
  no model downloads, no telemetry of any kind. The privacy claim is meant to be
  verifiable via `codesign -d --entitlements`.
- **Swift 6 strict concurrency** is on for every target from the first commit.
  All types crossing concurrency-domain boundaries are `Sendable`. The four
  domains: capture queue, analysis actor, audio render thread, main actor. The
  audio render callback may not allocate, lock, or make blocking runtime calls.
- **No numeric threshold is hardcoded (§0, §11).** Every constant (dead zones,
  dwell times, hysteresis ratios, target framing, rates) lives in the versioned
  `Codable` `Config` struct, keyed by backend identifier where relevant. Spec
  numbers are starting-point defaults, not constants.
- **Hysteresis and dwell on every state transition (§4, §7).** Exit thresholds
  wider than entry thresholds; 800 ms dwell before any announcement; smoothing
  applies to continuous signals only, never to state transitions.
- **Backend-agnostic protocol (§3.2).** `FaceAnalysisBackend` must not assume
  Vision's landmark topology, coordinate origin, or pose sign conventions.
  Backends are compile-time conformances — no dynamic loading (App Store rule).
- **No global hotkey may include Option (§8)** — it collides with VoiceOver.
  Hotkeys use `RegisterEventHotKey`, never `CGEventTap`.
- **Build in phase order (§13).** Currently in **Phase 1 (headless core)**. Do
  not build audio before the debug panel exists; do not build the first-run flow
  before the primitives it composes.
- **Appearance description is a non-goal (§1).** If asked to add VLM-style
  "describe how I look" features, stop and escalate — do not build it.

## Accessibility is the product

Every UI element must be VoiceOver-navigable with a meaningful value. Post
`.valueChanged` only for the focused element, throttled (~2 Hz). Terse fixed
vocabulary lives in `Lexicon.swift` only — never generate phrases dynamically.

## Testing conventions

- The corpus (§14) is the primary tuning and regression instrument. New signal
  or state-machine behavior should come with a corpus expectation, not just a
  unit test, once clips exist.
- Signal-processing tests replay recorded/synthetic input; never write tests
  that require a live camera to pass in CI.

## Toolchain notes

- CI's `macos-15` runner pins an older Swift toolchain than dev machines may
  have. Newer SDKs keep adding `Sendable` annotations to AVFoundation/Vision
  types, so code that compiles locally can fail to build on CI even though
  nothing "changed." Rule: never rely on an SDK's `Sendable` annotation for an
  AVFoundation/Vision value crossing an isolation boundary. Keep every call
  into those frameworks inside one `nonisolated` domain and hand the result
  across as an explicit `Sendable` value, or a small `final class: @unchecked
  Sendable` wrapper documenting an ownership transfer (never concurrent
  sharing). See `FileCaptureSource.makeReader`/`ReaderBox` for the reference
  pattern — its doc comments explain, at the call site, exactly why the
  `nonisolated` boundary is needed regardless of which SDK is compiling it.

## Open-source hygiene

- License: Apache 2.0. Contributions are covered by the DCO — commits need
  `Signed-off-by` (see CONTRIBUTING.md). No per-file license headers required.
- Conventional, imperative commit messages; small focused PRs; CI (build, test,
  lint, format) must be green.
