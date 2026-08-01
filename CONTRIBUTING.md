# Contributing to About Face

About Face is an open-source macOS assistive-technology app licensed under Apache 2.0. Contributions are welcome and covered by the Developer Certificate of Origin (DCO).

## Building

Requires Xcode 16+ / Swift 6 toolchain and macOS 15 SDK.

```sh
swift build                                   # build core package + CLI harness
swift test                                    # run unit + corpus regression tests
swift format lint --strict --recursive Sources Tests   # formatting check (CI-enforced)
swiftlint                                     # lint (config: .swiftlint.yml)
```

## Before You Code

**Read [docs/spec.md](docs/spec.md) for the section relevant to your change.** Section references (§N) throughout the codebase refer to it. The spec is prescriptive about architecture, protocol shapes, coordinate conventions, and state machines. It is deliberately not prescriptive about numeric constants — those live in the versioned `Config` struct and are tuned by ear against the test corpus.

## Developer Certificate of Origin

Contributions must be signed off with `git commit -s`. This adds a `Signed-off-by` line to your commit, certifying that you have the right to contribute the work and that it is covered by the Developer Certificate of Origin. The DCO is inbound = outbound: you represent that your contribution is your original work and that you grant an unrestricted, royalty-free license to About Face under the Apache 2.0 license.

See https://developercertificate.org/ for details.

## Pull Request Guidelines

- **Small, focused PRs.** One feature or fix per PR. Easier to review, easier to bisect if issues arise.
- **CI must be green.** All checks (build, test, lint, format) pass before merging.
- **Test behavior changes.** New signal processing or state-machine behavior should include corpus expectations (see [docs/spec.md § 14](docs/spec.md)) or unit tests.
- **No hardcoded numeric thresholds.** Dead zones, dwell times, hysteresis ratios, rates, framing targets — they all belong in the versioned `Config` struct, not the source code. See [docs/spec.md § 0](docs/spec.md).

## Accessibility Expectations

Accessibility is the product. VoiceOver testing is encouraged. Any change that reduces the app's accessibility is treated as a regression and is a release blocker. When adding UI:

- All interactive elements must be VoiceOver-navigable with meaningful values.
- Post `.valueChanged` only for the focused element, throttled (~2 Hz).
- Fixed vocabulary lives in `Lexicon.swift` — never generate phrases dynamically.

## Out of Scope

The following feature requests cannot be accepted:

- **Network-dependent features.** The app has no network entitlement by design. No analytics, no crash reporting, no model downloads, no appearance description ("what do I look like"). See [docs/spec.md § 2](docs/spec.md).
- **VLM-based appearance description** ("is my hair OK", "what's behind me"). This is architecturally incompatible with the App Store sandbox and the no-network constraint. If you believe appearance description is necessary, open an issue to discuss design — do not submit a PR.

## Questions?

Open an issue or start a discussion. Thanks for contributing!
