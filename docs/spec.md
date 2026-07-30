# About Face — Design & Build Specification

**Product name:** About Face
**Bundle identifier:** `com.ledgerlinecompany.aboutface`
**Status:** v1 spec, ready to build
**Target:** macOS 15.0+, Swift 6, SwiftUI
**License:** Apache 2.0
**Distribution:** Mac App Store (primary)

---

## 0. How to use this document

This spec is written to be handed to an implementation agent. It is prescriptive
about architecture, protocol shapes, coordinate conventions, and state machines,
because those are the things that are expensive to change later. It is
deliberately *not* prescriptive about exact threshold values — every numeric
constant in this document is a **starting point** that lives in a `Config` struct
and gets tuned by ear against the test corpus. Do not hardcode any of them.

Where this document says **MUST**, treat it as a correctness requirement with a
test. Where it says **SHOULD**, use judgment but document deviations.

Build in the phase order given in §13. Do not skip ahead — in particular, do not
write the audio engine before the debug panel exists, and do not write the
first-run flow before the primitives it composes are working.

---

## 1. Problem statement

Blind and low-vision users cannot tell whether they are correctly positioned in
their webcam frame. This app provides real-time non-visual feedback about camera
framing, lighting, head orientation, and who else is visible, so a user can
position themselves for a video call without sighted assistance.

Prior art is JAWS/Fusion "Face in View" (Windows, 2024). This project targets
Apple platforms and improves on it in three specific ways:

1. **Runs during the call.** macOS permits concurrent camera access by multiple
   processes; Face in View must be disabled before joining a call.
2. **Non-speech continuous feedback.** Spoken phrases are too slow (~1s) for a
   correction loop that wants ~100ms. Sonification is the primary channel.
3. **Inspectable state.** A VoiceOver-navigable window exposes every underlying
   measurement as a precise value, not just an inferred summary.

### Non-goals for v1 — do not build these

- **Appearance description** ("is my hair OK", "what's behind me"). This is a
  VLM feature with a different privacy profile, latency, failure mode, and trust
  relationship. It is architecturally blocked by having no network entitlement.
  If asked to add it, stop and escalate.
- Third-party runtime-loaded plugins (see §3.2 — incompatible with the App Store).
- Recording, streaming, or virtual-camera output.
- iOS/iPadOS app. The shared core is designed to allow it later; v1 ships Mac only.
- Apple Watch haptics. Designed for, not built.

---

## 2. Platform and distribution constraints

These constraints are settled and drive several architecture decisions. Do not
revisit them without escalating.

| Constraint | Consequence |
|---|---|
| Mac App Store distribution | Apache 2.0 license (GPL is incompatible with MAS terms) |
| App Sandbox enabled | `com.apple.security.device.camera` only |
| **No network entitlement** | `network.client` and `network.server` MUST be absent from the entitlements file. No analytics, no crash reporting SDK, no model downloads. This makes the privacy claim verifiable via `codesign -d --entitlements`. |
| Library validation / hardened runtime | Backends are **compile-time**, not loadable plugins |
| App Review 2.5.2 | No downloading or executing code that changes app features |
| Updates via App Store | No Sparkle. No in-app update check. |
| macOS 15.0 minimum | Vision's Swift-native async API; Swift 6 strict concurrency |

`NSCameraUsageDescription` MUST state that video never leaves the device.

---

## 3. Architecture

### 3.1 Layer diagram

```
CaptureSource ──> FaceAnalysisBackend ──> AnalysisEngine ──> FeedbackRouter
 (camera|file)      (Vision | ARKit |        (framing,          │
                     ONNX later)              lighting,         ├─> AudioRenderer   (primary)
                                              smoothing,        ├─> SpeechRenderer  (own TTS)
                                              state machine)    ├─> AccessibilityRenderer (VO values)
                                                                └─> HapticRenderer  (discrete only, later)
```

Four concurrency domains, each an actor or dedicated queue:

- **Capture queue** — `AVCaptureVideoDataOutput` sample buffer delivery. Serial,
  high priority, must never block.
- **Analysis actor** — backend inference plus signal derivation.
- **Audio render thread** — `AVAudioEngine` render callback. Real-time
  constraints: no allocation, no locking, no Swift runtime calls that can block.
- **Main actor** — UI, accessibility posting, hotkeys.

Swift 6 strict concurrency MUST be enabled from the first commit. All types
crossing domain boundaries MUST be `Sendable`.

### 3.2 Backend protocol

Backends are selected at runtime from a set compiled in at build time. There is
no dynamic loading.

```swift
public protocol FaceAnalysisBackend: Sendable {
    static var identifier: String { get }
    static var displayName: String { get }
    static var isAvailable: Bool { get }        // hardware/OS gated
    var capabilities: BackendCapabilities { get }

    func analyze(_ frame: CapturedFrame) async throws -> RawFaceObservation?
}

public struct BackendCapabilities: OptionSet, Sendable {
    public static let headPose        = BackendCapabilities(rawValue: 1 << 0)
    public static let gaze            = BackendCapabilities(rawValue: 1 << 1)  // true gaze, not head-pose proxy
    public static let metricDistance  = BackendCapabilities(rawValue: 1 << 2)
    public static let captureQuality  = BackendCapabilities(rawValue: 1 << 3)
    public static let multiFace       = BackendCapabilities(rawValue: 1 << 4)
}
```

v1 ships one conformance: `VisionBackend`, using the macOS 15 Swift-native Vision
API (`DetectFaceRectanglesRequest`, `DetectFaceCaptureQualityRequest`,
`DetectFaceLandmarksRequest`).

Future conformances — `ARKitBackend` (iOS, gains `.gaze` and `.metricDistance`),
`MediaPipeBackend` (statically linked, model weights **bundled** not downloaded)
— are out of v1 scope but the protocol MUST NOT be shaped in a way that assumes
Vision's specific landmark topology or coordinate origin.

**Note for whoever adds the second backend:** numeric thresholds do not transfer
between backends. Landmark topology, coordinate origin, and pose sign conventions
differ. `Config` MUST be keyed by backend identifier so each has its own tuned
defaults.

### 3.3 Signal types

```swift
public struct FrameAnalysis: Sendable {
    public let timestamp: CMTime
    public let signalState: SignalState
    public let faceCount: Int
    public let primary: FaceGeometry?
    public let lighting: LightingMetrics
}

public enum SignalState: Sendable, Equatable {
    case ok
    case lowConfidence     // face probably there, detector unsure — often = too dark
    case noFace            // frame looks normal, no face in it
    case noSignal          // near-uniform frame: lens covered, camera asleep, feed dead
}

public struct FaceGeometry: Sendable {
    public let boundingBox: CGRect      // normalized, EGOCENTRIC (see §3.4)
    public let eyeMidpoint: CGPoint     // normalized
    public let interocularDistance: CGFloat  // normalized to frame width
    public let yaw: Float               // degrees, + = subject's head turned to their right
    public let pitch: Float             // degrees, + = chin up
    public let roll: Float              // degrees, + = subject's head tilted to their right
    public let captureQuality: Float?   // Vision's scalar, 0...1, nil if unsupported
    public let confidence: Float
}

public struct LightingMetrics: Sendable {
    public let faceLuma: Float              // mean luma, face ROI, 0...1
    public let backgroundLuma: Float        // mean luma, frame minus face ROI
    public let backlightDelta: Float        // backgroundLuma - faceLuma; high = backlit
    public let clippedHighlightFraction: Float
    public let clippedShadowFraction: Float
    public let colorTempSkew: Float         // -1 (cool) ... +1 (warm)
    public let sharpness: Float             // variance of Laplacian, face ROI, normalized
    public let frameLumaVariance: Float     // for noSignal detection
}
```

Derived by `AnalysisEngine` from the above:

```swift
public struct FramingState: Sendable {
    public let error: SIMD2<Float>      // normalized offset from target, egocentric,
                                        // x: + = subject is right of target
                                        // y: + = subject is above target
    public let distanceError: Float     // + = too close
    public let inDeadZone: Bool
    public let gazeOnCamera: Bool       // from yaw/pitch magnitude, or true gaze if available
}
```

### 3.4 Coordinate convention — CRITICAL

**All directional output is egocentric from the user's point of view.** "Move
left" means the user moves toward their own left hand.

This is the single worst failure mode available to this project. A tool that
confidently gives inverted instructions is worse than no tool. Get it right and
test it.

Rules:

- `AVCaptureConnection.isVideoMirrored` MUST be set explicitly at session
  configuration. Never inherit the default; it varies by device and OS version.
- Establish a single `MirrorState` value at capture setup and thread it through.
  Every coordinate transform MUST consume it — no implicit assumptions anywhere
  downstream.
- The analysis layer normalizes to egocentric coordinates **once**, at the
  boundary between backend output and `FaceGeometry`. Everything downstream is
  already egocentric.
- **MUST have a test:** a corpus clip where the subject is unambiguously to their
  own left produces `error.x < 0` and the instruction "right", under both
  mirrored and unmirrored capture configuration.

---

## 4. Target framing

Default target is *not* geometric center. Videography convention:

- **Eye midpoint at 0.38 of frame height from top** (upper third, modest headroom)
- **Eye midpoint at 0.50 of frame width**
- **Interocular distance 0.11 of frame width** (≈ medium close-up)

These are `Config` defaults, not constants.

**Target MUST be user-settable** via ⌘⌃⇧T ("capture current position as target").
This is a v1 primitive, not a nice-to-have — it lets a sighted person position the
user once, supports deliberately off-center framing for screen-sharing, and is the
building block the first-run flow composes later.

### Dead zone and hysteresis

- Dead zone: ±0.06 frame width horizontal, ±0.05 frame height vertical.
- **Hysteresis on every threshold.** Exit thresholds are wider than entry
  thresholds by a `Config` ratio (default 1.4×). Without this the feedback
  chatters at boundaries and the tool feels broken.
- Temporal smoothing: exponential moving average over ~8 frames on `error`.
  Smoothing MUST be applied to continuous signals only, never to state
  transitions (see §7 dwell).

---

## 5. Modes

Three modes with different requirements. Transitions are explicit (hotkey) except
where noted.

### 5.1 Setup

Pre-call. User is actively moving and wants convergence in under ten seconds.

- Opens/focuses a real window (not an overlay). See §9.
- Analysis at **30 Hz**. Capture format 1280×720 @ 30fps.
- Continuous positional sonification, full bandwidth.
- Speech uses **instructions** ("left", "closer") — faster to act on.
- Interruption is the point; no rate limiting beyond the dwell time.

### 5.2 Monitor

During the call. MUST never speak over the user or anyone else.

- Background, no window. Menu bar item only (`LSUIElement`).
- Analysis at **5 Hz**. Capture format 640×480 @ 15fps — requested **explicitly**,
  not negotiated. This matters for CPU and thermals over a two-hour call, and
  because format negotiation between concurrent clients needs empirical
  verification (see §12.4).
- **Earcons only by default.** Speech is opt-in per condition, except face-lost
  which escalates to speech per §7.3.
- Hard rate limit: max 1 announcement per 20s. Same condition not repeated within
  3 minutes.
- **Camera-gated:** may auto-activate when another app opens the camera (§12.2).

### 5.3 Query

On demand, any mode, any time. Probably the most-used feature.

- One-shot burst of analysis (~10 frames, ~300ms), then a single terse spoken
  summary, then silence.
- Uses **state** phrasing ("you are left") rather than instructions — more honest
  when the user isn't actively correcting.
- **Fixed field order, always:** framing, lighting, gaze, other people. Not
  "most urgent first." Predictable order lets an experienced user stop listening
  once they've heard the field they care about.
- Config option: "problems only" variant that omits fields that are fine.

---

## 6. Feedback design

### 6.1 The silence ambiguity — solve this first

If "perfectly framed" is silence and "face lost" is also silence, the design
fails exactly when it matters most. Required structure:

| State | Output |
|---|---|
| Entering good zone | Distinct confirmation earcon, **once** |
| Holding good zone | Silence + quiet liveness heartbeat every 7s |
| Face lost | Unmistakable, **different in kind** — different timbre, not a variation on the positional tone |
| Low confidence | Audibly distinct from both. "Too dark to detect a face" ≠ "no face present" — and you will hit this constantly in a dim room, precisely when lighting feedback matters most |
| No signal | Own message. Lens covered / camera asleep is a different problem with a different fix |

The heartbeat is not optional. Users need to distinguish "good" from "the app
crashed."

### 6.2 Positional sonification

Three schemes, all implemented, user-selectable. Default is **Scheme A**.

**Scheme A — Pan/pitch (default).** Stereo pan encodes horizontal error, pitch
encodes vertical error. Both axes simultaneously; fastest convergence. Requires
stereo separation, so `Config` MUST have a headphones-vs-speakers setting —
MacBook speakers at 50cm give poor imaging and this cannot be auto-detected
reliably.

**Scheme B — Zero-beat nulling.** A fixed reference tone plus a moving tone whose
frequency tracks the error; as error approaches zero the beat frequency drops to
zero. Human hearing is extraordinarily sensitive to this (it is how instruments
are tuned) and it gives precision categorical feedback cannot. Use it for the
final approach only — inside 20% of error range — with Scheme A's coarser
feedback outside that. Schemes A and B compose; B is a refinement layer.

**Scheme C — Sequential axis (mono fallback).** Solve horizontal to completion,
then vertical. Slower, unambiguous, works on a single speaker.

**Distance** maps to pulse rate or filter brightness. **Never volume** — volume
is confounded with system output level and with the user's own attention.

**Lighting is NOT in the continuous loop.** It varies slowly, it is not something
you null by moving, and a fourth simultaneous parameter makes the whole thing
unreadable. Lighting is announced as a discrete state change only.

**Speech is never panned.** Pan encodes horizontal error; panning speech too
makes both illegible. Speech stays centered; tones move.

### 6.3 Speech (own TTS via AVSpeechSynthesizer)

Own TTS was chosen over VoiceOver announcements because a background menu-bar app
posting `announcementRequested` is unreliable when unfocused — which is exactly
its normal state. The cost is that this voice competes with VoiceOver's.
Mitigations are required, not optional:

- **Default rate well above `AVSpeechUtteranceDefaultSpeechRate`.** Apple's
  default is unusably slow for this audience. Default **0.62**, exposed as a
  slider. VoiceOver's rate is not readable programmatically, so this needs its
  own setting and its own onboarding moment.
- **Default to a voice timbrally distinct from common VoiceOver defaults** —
  different gender or accent. When both streams talk at once, timbral separation
  is what makes them parseable. Do not accept whatever `speechVoices()` returns
  first.
- **Early task:** verify empirically whether Eloquence and Vocalizer voices are
  reachable via `AVSpeechSynthesisVoice.speechVoices()` or are VoiceOver-exclusive.
  Many users will want Eloquence at 450wpm. Log the finding in the README; if
  unavailable, that is a known limitation to document, not a bug to chase.

**Vocabulary is a small fixed closed set.** Users learn it in a week and then
parse it pre-attentively. Terse to the point of feeling rude — "Left. Left.
Centered." not "You are currently positioned slightly to the left of frame
center." Define the full lexicon in one file, `Lexicon.swift`, and do not
generate phrases dynamically.

### 6.4 Haptics (designed, not built in v1)

The `FeedbackRouter` treats haptics as a **subscriber to discrete events only** —
never a renderer of the continuous error vector. Architecturally: analysis emits
a continuous vector plus discrete semantic events; audio consumes both, haptics
consumes only the events.

Rationale for later implementers: on iOS the phone is typically propped on a
stand pointed at the user's face, not held, so device haptics are dead weight.
Apple Watch via `WatchConnectivity` is the correct delivery path for discrete
events (entered good zone, face lost). Keep this partition clean so that module
drops in without entangling the audio path.

---

## 7. Suppression and event state machine

This section is most of what separates a tolerable tool from one people disable
in a week.

### 7.1 Dwell

A condition MUST hold for **800ms** before it generates any announcement. Applies
to every condition without exception.

### 7.2 Frame-level suppression

- Blink suppression: use backend eye-state where available; otherwise require
  N consecutive frames.
- General N-frame requirement (default 5 at 30Hz, 3 at 5Hz) so a hand raised to
  the face or a sip of coffee triggers nothing.

### 7.3 Face-lost escalation ladder

A single aggressive alert is either too slow or too jumpy. Escalate:

| Elapsed | Action |
|---|---|
| 0 – 1.5s | Nothing. Covers turning to a second monitor, reaching for coffee, one bad frame. |
| 1.5s | Distinct earcon. Non-positional. Clearly different timbre from framing tones. |
| ~5s | Spoken. Short. "No face." |
| ~30s | **STOP.** Go silent, set `userLikelyAway = true`. |

**The 30s stop is the requirement an implementer will forget.** After thirty
seconds the user has not misframed themselves, they have left the desk. A tool
that nags at an empty chair for the rest of a meeting gets uninstalled.

On face reacquisition while `userLikelyAway`: announce recovery **once**
("Back, centered" — or the problem, if there is one), clear the flag, resume
normal monitoring.

### 7.4 Priority ladder

When several conditions are true, announce **only the top one**:

1. No signal (lens covered / feed dead)
2. Face lost
3. Partially out of frame
4. Lighting critical (face effectively undetectable)
5. Framing error outside dead zone
6. Gaze off-camera
7. Minor lighting / other people / everything else

### 7.5 Manual silence

⌘⌃⇧/ silences all feedback immediately while leaving analysis running. This is
the "someone just started talking to me" key. It MUST be reachable without
thinking and MUST take effect within one audio buffer — cut the render, do not
wait for the current utterance to finish.

---

## 8. Hotkeys

Registered with `RegisterEventHotKey`, **not** `CGEventTap`. Event taps require
the Accessibility TCC permission and are an App Store non-starter.

**Hard rule: no global hotkey may include Option.** Every VoiceOver command
includes Option (VO is Control+Option; the Cmd variants are Control+Option+
Command), and Keyboard Commander maps Option+letter. Excluding Option eliminates
the whole VoiceOver collision surface in one stroke. Including Control eliminates
the conferencing-app surface, since Zoom, Teams, and Meet live almost entirely in
Command+Shift+letter.

Default set — all reconfigurable in settings:

| Combo | Action |
|---|---|
| ⌘⌃⇧F | **Query** — one-shot summary, then silence. The most-used key. |
| ⌘⌃⇧S | Setup mode toggle (opens/focuses window) |
| ⌘⌃⇧M | Monitor mode toggle |
| ⌘⌃⇧T | Capture current position as target |
| ⌘⌃⇧R | Repeat last announcement |
| ⌘⌃⇧/ | Silence all feedback immediately, stay running |

Inside the Setup window, use **bare single letters, no modifiers**. Window focus
means no global capture is needed, which is the reason to keep the global set
small and put everything else behind the window.

---

## 9. Setup window and accessibility

A real window means every signal becomes a VoiceOver-navigable element with an
actual value. A user can arrow through precise numbers rather than only inferring
from tones. This is strictly more information than JAWS offers and it costs
almost nothing.

Exposed as accessible values (read-only, live):

- Headroom (% of frame above eye midpoint)
- Horizontal offset (% of frame width from target, with direction word)
- Face box: origin and size, normalized
- Interocular distance / estimated distance
- Face luma, background luma, backlight delta
- Clipped highlight and shadow fractions
- Sharpness
- Yaw, pitch, roll in degrees
- Detected face count
- Backend confidence, backend name, capture format, mirror state

Two implementation requirements that will otherwise be got wrong:

- **Post `.valueChanged` only for the currently-focused element, throttled to
  ~2 Hz.** Updating every element's accessibility value at 30fps makes VoiceOver
  unusable.
- **Duck own-TTS while the user navigates.** There is no public API to know
  whether VoiceOver is currently speaking. Heuristic: any key event in the window
  pauses spoken feedback for 2s while leaving tones running. Otherwise the user
  arrows to a control, VoiceOver reads it, and the engine talks over it.

### Debug / advanced panel

The tuning panel is shipped, not stripped. Every threshold, dead zone, dwell
time, and mapping curve is a live slider bound to `Config`.

- `Config` is a versioned `Codable` struct serialized to JSON.
- Reset-to-default per section and globally.
- **Export/import.** This matters more than it sounds: it lets users share tuning
  profiles with each other, which is how a tool like this gets good across varied
  hardware and rooms.
- All sliders MUST be accessible with proper value descriptions and increment
  actions.

---

## 10. Profiles

Keyed by **(location name, camera `uniqueID`)**. Same laptop at home desk vs.
office has different lighting and camera height and needs different targets.

- Named locations, user-created. Default location "Default."
- Profile stores: target framing, chosen sonification scheme, speech settings,
  all `Config` overrides.
- Switching UI in the Setup window and the menu bar.
- Fallback chain: exact (location, camera) → any profile for this camera →
  location default → global default.
- Profiles persist by camera `uniqueID` with **graceful fallback when the device
  is absent** (Continuity Camera devices appear and vanish).

---

## 11. Configuration

One `Config` struct, versioned, `Codable`, backend-keyed where relevant. Every
number in this document lives here. Migration on version bump MUST preserve
unknown keys where possible and MUST NOT silently reset a user's tuning.

Ship exactly one carefully-tuned default scheme. **No mode-selection prompt on
first run.** Everything adjustable, nothing required.

---

## 12. Camera management

### 12.1 Selection

User explicitly selects the camera; it is stored per profile. Enumerate with an
observed `AVCaptureDevice.DiscoverySession`, **not** a snapshot at launch —
Continuity Camera devices come and go.

### 12.2 Camera-in-use gating

`AVCaptureDevice.isInUseByAnotherApplication` (macOS only) signals that a device
is busy. Use it to idle at near-zero cost and spin up Monitor mode when a
conferencing app grabs the camera; it is also a good trigger for auto-dropping
out of Setup so the app stops chirping once the call starts.

**Verify empirically whether this property is genuinely KVO-observable.** If not,
poll at 1 Hz. Document which path was taken.

### 12.3 Mismatch warning

The API tells you a device is busy, **not which app holds it**. So the heuristic
is: if some device other than the user's selection reports in-use while the
selected one does not, warn that the conferencing app may be using a different
camera. Warning is informational and dismissible, never blocking.

### 12.4 Virtual cameras — silent-wrongness risk

OBS, Snap Camera, and similar appear as ordinary capture devices. If the
conferencing app is on a virtual camera fed by the physical one, the far end may
be cropped, mirrored, or scene-composited, and every framing verdict is silently
wrong.

This cannot be reliably detected from device type. Match against known
virtual-camera name patterns (maintain the list in one file) and surface a
one-time acknowledgeable warning.

### 12.5 Center Stage

On Center Stage–capable cameras (Studio Display, Continuity Camera, newer Macs)
the OS already auto-frames the subject, and **it is a per-capture-session
setting** — the conferencing app's state and this app's state can differ.

- Query `AVCaptureDevice.centerStageControlMode` and `isCenterStageEnabled`.
- When Center Stage is on, **say so and shift the report**: "Center Stage is on,
  framing is automatic" plus lighting, gaze, and other-people signals.
- Silently reporting a framing problem the OS is already correcting is worse than
  reporting nothing.

### 12.6 Concurrent access test

Write an explicit test/tool that opens the selected device **while another app
holds it** and logs the format actually granted. Do not assume the requested
format is honored.

---

## 13. Build phases

Each phase has acceptance criteria. Do not proceed until they are met.

### Phase 1 — Headless core

Capture session (camera **and file** input), `FaceAnalysisBackend` protocol,
`VisionBackend`, `AnalysisEngine`, test corpus harness. Emits `FrameAnalysis` to
console. No UI, no audio.

*Acceptance:* replays a corpus clip and prints a stable, plausible signal stream;
mirror-convention test (§3.4) passes in both configurations; runs a live camera
at 30Hz without dropping frames.

### Phase 2 — Setup window and debug panel

Accessible value elements, live sliders over `Config`, JSON persistence,
export/import.

*Acceptance:* every signal in §9 is reachable and readable by VoiceOver with a
sensible value; changing any slider visibly changes engine behavior; VoiceOver
remains responsive with values updating live.

**Do not build audio before this exists. You cannot tune what you cannot read.**

### Phase 3 — Audio engine

Earcons, positional tones (Schemes A/B/C), own-TTS, `Lexicon.swift`, suppression
logic, silence-ambiguity structure.

*Acceptance:* tuned against the corpus, not against a live camera — replay
identical input through variant A and variant B and compare cleanly. All five
states in §6.1 are distinguishable blind. Manual silence key cuts within one
buffer.

### Phase 4 — Monitor mode

Camera-in-use gating, rate limits, face-lost escalation ladder, priority ladder,
mismatch detection, virtual camera and Center Stage warnings.

*Acceptance:* a 30-minute session with the user leaving the desk for 10 minutes
produces the correct escalate-then-stop-then-recover sequence and nothing else;
CPU and thermal impact measured and documented.

### Phase 5 — Profiles, first-run, packaging

Profile system, guided first-run calibration, MAS packaging and submission.

First-run flow is **pure composition over existing primitives** — grant camera
access, position with live tone feedback, capture target (⌘⌃⇧T), set speech rate
and voice, pick a scheme. Because §4's target-capture and §11's defaults already
work standalone, this is a sequencing task, not a new subsystem. If it starts
feeling like a new subsystem, something earlier was built wrong.

`Config.default` MUST be genuinely usable with zero calibration.

---

## 14. Test corpus

**Build this in Phase 1, before the pipeline.** It is worth more than any
prototype for the actual hard problem: tuning feedback against a live camera
means you can never A/B two schemes against identical input — the subject moves,
lighting drifts, and you are comparing noise.

Record 15–20 short clips (10–20s each):

1. Well-lit, centered, looking at camera (the reference)
2. Backlit against a bright window
3. Single lamp hard from one side
4. Dim room, overall underexposed
5. Too close
6. Too far
7. Off to the subject's left
8. Off to the subject's right
9. Too high in frame (only forehead)
10. Too low in frame
11. Looking down at a second monitor
12. Looking off to the side
13. Head tilted (roll)
14. Second person walking through behind
15. Second person seated in frame
16. Glasses with strong glare
17. Lens covered / camera asleep
18. Blinking and normal fidgeting (suppression test)
19. Hand raised to face briefly
20. Subject leaves frame entirely and returns

Store as a fixture directory with a JSON manifest of expected dominant condition
per clip. Wire into CI as regression tests: they are the only sane way to verify
hysteresis does not chatter on borderline cases, and they are what makes swapping
`VisionBackend` for `ARKitBackend` later a tractable change rather than a rewrite.

---

## 15. App Store submission checklist

- [ ] App name "About Face" reserved in App Store Connect (first-come; reserve
      early, independent of submission). Bundle ID `com.ledgerlinecompany.aboutface`.
- [ ] Subtitle carries the functional keywords — the name is not discoverable by
      function. "blind," "VoiceOver," "camera," "accessibility" belong here, not
      in the name.
- [ ] Entitlements: camera present; `network.client` and `network.server` **absent**
- [ ] No analytics or crash-reporting SDK (they pull the network entitlement back in)
- [ ] Local log file with a "reveal in Finder" affordance (replaces crash telemetry)
- [ ] `NSCameraUsageDescription` states video never leaves the device
- [ ] Apache 2.0 license file; all contributors covered before first outside PR
      (relicensing later requires consent from every copyright holder — this is a
      project-killing problem if deferred)
- [ ] **Demo video** showing misframed cases. A sighted reviewer will point a
      camera at their own well-lit face, hear a quiet tone and then nothing,
      because they are already framed correctly.
- [ ] **Reviewer notes stating in the first sentence** that this is assistive
      technology for blind and low-vision users.
- [ ] Budget for one rejection-and-appeal cycle on **Guideline 4.2 (minimum
      functionality)**. An app whose output is audio feedback plus a window of
      numbers has been rejected before by reviewers pattern-matching on visual
      sparseness. The accessibility framing is usually sufficient on appeal, but
      first-pass approval is not the plan.

---

## 16. Open questions for the maintainer

Flag these rather than deciding unilaterally:

1. Exact earcon sound design — needs to be authored by ear, not specified here.
2. Whether Scheme B (zero-beat) should be on by default once tuned.
3. Eloquence/Vocalizer voice availability (see §6.3) — outcome affects the
   voice-picker UI.
4. Whether Monitor mode should auto-enable on camera-in-use by default, or
   require explicit opt-in per profile.
