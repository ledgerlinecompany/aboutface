# About Face

About Face provides real-time non-visual feedback about webcam framing, lighting, head orientation, and who else is visible in the frame. Designed for blind and low-vision users, it allows positioning for video calls without sighted assistance. The app targets macOS 15+, uses SwiftUI, and is planned for distribution on the Mac App Store.

## Why

- **Runs during the call.** macOS permits concurrent camera access by multiple processes, so About Face can run alongside your video conferencing app without interruption.
- **Non-speech continuous feedback.** Real-time sonification (~100ms loop) is faster than spoken phrases (~1s), enabling rapid correction cycles.
- **Inspectable state.** Every underlying measurement is exposed as a precise value in a VoiceOver-navigable window, not just an inferred summary.

## Privacy

About Face contains no network entitlements whatsoever. There is no analytics, no crash reporting, and no telemetry of any kind. Video never leaves the device. This privacy guarantee is verifiable via `codesign -d --entitlements`.

## Status

About Face is in early development. Phase 1 (headless core library) is currently in progress per [docs/spec.md](docs/spec.md) §13. The app is not yet usable for real-world video calls.

## Building

Requires Xcode 16+ and Swift 6.

```sh
swift build          # core library + CLI harness
swift test
```

The Mac app shell is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`); the `.xcodeproj` is not checked in:

```sh
xcodegen generate
xcodebuild -project AboutFace.xcodeproj -scheme AboutFaceApp build
```

## Speech voices (spec §6.3 finding)

Measured 2026-08-01 on macOS 26 via `AVSpeechSynthesisVoice.speechVoices()`:

- **Eloquence voices are available** to the app's own speech synthesis — all
  eight classic personas (Eddy, Flo, Grandma, Grandpa, Reed, Rocko, Sandy,
  Shelley) as `com.apple.eloquence.*`, across ~14 languages. Users who want
  Eloquence at very high speech rates can have it.
- **Vocalizer/Nuance voices are not exposed** by the public API — they remain
  VoiceOver-exclusive. This is a known platform limitation, not an app bug.
- Enhanced/Premium Apple voices appear only after the user downloads them in
  System Settings.
- Voice-picker consideration: because Eloquence is also a popular VoiceOver
  voice, defaulting to it could remove the timbral separation between the
  app's speech and VoiceOver's (spec §6.3). The default voice should be
  chosen to contrast with the user's VoiceOver voice, whatever it is.

## Contributing

Contributions are welcome. Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. Commits must include a Signed-off-by line per the Developer Certificate of Origin (DCO).

The authoritative design document is [docs/spec.md](docs/spec.md). Please read the relevant section before implementing any feature.

## License

About Face is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
