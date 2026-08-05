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
| App Sandbox enabled | `com.apple.security.device.camera`, plus `com.apple.security.files.user-selected.read-write` (amended 2026-08-01: required for §9 config export/import through the sandbox's save/open panels; grants access only to files the user explicitly picks). Nothing else. |
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

- Background, no persistent window while running. **Decided (maintainer,
  2026-08-04), against this section's original `LSUIElement` prescription:**
  the app keeps its Dock icon. `LSUIElement` (menu-bar-only, no Dock icon, no
  Cmd-Tab entry) was the original plan, but removing the Dock icon also
  removes About Face from Cmd-Tab, and the Setup window (§9) is a real window
  a blind user needs a reliable, discoverable route back to — losing Cmd-Tab
  access to it in exchange for a menu-bar-only presence was judged the wrong
  trade for this audience. The `MenuBarExtra` (§16.4) ships as an
  ADDITIONAL surface alongside the Dock icon, not a replacement for it.
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

The feature this section wants is still correct and still desired: idle at
near-zero cost while the app is quiescent, and spin up Monitor mode the
instant a conferencing app grabs the camera — also a good trigger for
auto-dropping out of Setup so the app stops chirping once the call starts.
What follows is the detection mechanism, which does not work, and what to do
until it's replaced.

**Finding, 2026-08-03, macOS 26.5.2, Apple Silicon, built-in FaceTime HD
Camera:** `AVCaptureDevice.isInUseByAnotherApplication` does not detect a
conferencing app using the camera. This is the empirical verification this
section originally asked for, and the result is worse than "not
KVO-observable" — polling at 1 Hz, the prescribed fallback, does not help,
because the property never becomes true at all. Measured with a real Zoom
call live and the user's video on, both read at the same moment against the
same device:

- `AVCaptureDevice.isInUseByAnotherApplication` → **false**
- CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` → **true**

The CoreMediaIO reading is what proves Zoom was genuinely streaming at that
instant, so this is not a case of mismeasuring an idle app —
`isInUseByAnotherApplication` reads false while the camera is demonstrably in
use elsewhere.

Corroborating measurement: two separate processes captured from the same
physical camera at the same time, at different requested formats (1280×720
and 640×480), and each received exactly the format it requested — macOS
shared the device rather than granting either process exclusive access.
`isInUseByAnotherApplication` read false throughout on both sides, including
while the second process was actively capturing.

The likely explanation — an inference, not a verified mechanism — is that
this section's original premise assumed a conferencing app *grabs* the
camera in a way that produces a detectable exclusive acquisition. On current
macOS the camera is shared, so there may be no such acquisition to detect,
and `isInUseByAnotherApplication` is answering a narrower question than "is
someone else using this camera right now."

**Candidate replacement:** CoreMediaIO's
`kCMIODevicePropertyDeviceIsRunningSomewhere` — read via
`CMIOObjectGetPropertyData` against the device's `CMIOObjectID`, global
scope; it is a read with no side effects and opens no capture session of its
own. It tracked capture correctly and reversibly in testing: false when
idle, true while a process streamed, false again after that process exited.
It has an asymmetry that must be understood before anyone builds on it,
stated prominently here so it is not discovered halfway through
implementation: it reads true when **any** process is streaming, including
About Face itself. That makes it usable for detecting *activation* — "a call
started while we were idle" — but once Monitor is running and holding the
camera, the property stays true regardless of what the conferencing app
does, so it **cannot** detect *deactivation* — "the call ended." A gating
implementation built on this property needs a separate signal for noticing
the call ended; that does not fall out of this property for free.

**Direction taken (maintainer, decided and shipped 2026-08-03/04):** the
maintainer proposed reframing this feature away from auto-activation
entirely — verbatim: *"the switch from no to yes might instead be some kind
of spoken/earcon trigger to remember to turn on monitoring."* This fits the
property's actual shape better than the original design did, for a specific
reason worth recording: the deactivation asymmetry above only matters for
*auto-activation*, which needs to know when the call ends. A **reminder**
only needs the rising edge — exactly the half
`kCMIODevicePropertyDeviceIsRunningSomewhere` reports reliably. Better still,
a reminder is armed exactly when About Face is idle and not itself
capturing, which is the one state where "any process is streaming" is
unambiguous — the only process it could be is someone else's. The property's
central weakness disappears rather than needing a workaround. It also
answers the maintainer's original objection to the auto-activation design (a
trigger nobody can predict is worse than none): "when another app starts
using your camera, About Face reminds you" is a rule a user can hold in
their head, and the app never makes noise on its own.

Every behavioral detail §16.4 listed as open is now decided and shipped:

- **Spoken**, not earcon — the app's own TTS (§6.3), exactly one fixed
  phrase.
- **Exact wording: "Camera in use. Monitor is off."** — added to
  `Lexicon.swift`'s closed vocabulary (§6.3) in its own `Reminder` register,
  distinct from `Instruction` and `State` (it is neither a Setup correction
  nor a Query answer). Chosen deliberately over an instruction like "Turn on
  Monitor": this is a reminder, not a correction, and the user may
  legitimately not want Monitor on for a given call — the phrase states the
  fact and the app's own current state, and stops, rather than nagging
  toward a choice that isn't always right.
- **Not dismissible** — it is one short utterance, not a persistent alert
  with state to dismiss.
- **Delayed by `Config.Camera.reminderDelayMs` (default 1500) between the
  settled rising edge and the phrase being spoken.** Field finding
  (maintainer, 2026-08-04, after live-testing the reminder): *"Might be worth
  a 1-2 second delay just because you're usually hearing stuff right when the
  camera starts being used."* A call starting is itself an audio-busy moment
  — join tones, the app's own chime, people saying hello — and a reminder
  landing in the middle of that is easy to miss or to talk over.

  The delay makes re-validation **mandatory, not optional**: every gate is
  re-read at the deadline, not only at the edge. The likely sequence is that
  the user hears the call start, thinks "right, Monitor," and presses ⌘⌃⇧M
  *during* the delay — at which point "Monitor is off." has become false. The
  reminder exists to prompt exactly that action, so racing the user's
  response to it is the expected path, not an exotic one, and announcing
  something untrue is worse than announcing nothing. A pending reminder is
  therefore dropped if, at the deadline, About Face has started capturing,
  the user has silenced feedback, the feature has been disabled, or the
  camera is no longer busy. A dropped reminder is consumed — same rule as
  below, now applied at two evaluation points rather than one.
- **Fires once per rising edge** (false→true of the debounced busy signal),
  reusing `Config.Camera.busyDebounceMs` — no second debounce for the same
  underlying signal. It re-arms only after the signal falls back to false;
  it does not repeat while the camera stays busy.
- **Respects §7.5 manual silence** — if the user has silenced the app, the
  reminder stays silent, no exceptions. A related judgment call, decided and
  documented at the implementation (`CameraReminderStateMachine`'s doc
  comment in `AboutFaceCore`): a gate that blocks a rising edge — silenced,
  or capturing, or the feature disabled in `Config` — consumes that edge.
  Un-silencing (or stopping Monitor, or re-enabling the feature) after the
  fact does **not** retroactively speak a reminder for an edge that already
  passed; only a fresh false→true transition can fire again. The alternative
  — re-checking continuously and firing as soon as conditions turn
  favorable, however long after the actual edge — was rejected as
  disconnected from the event that justifies the announcement.

The one constraint that was never open, because it follows directly from
the property's semantics rather than being a design choice, still holds and
is enforced by the shipped implementation: the reminder is armed only while
About Face is **not** capturing (`PipelineModel.isRunning == false`), or it
would fire on itself the moment Monitor or Setup opens the camera.

**Status: shipped.** The reminder is live: `CameraReminderStateMachine`
(`AboutFaceCore`, pure, exhaustively unit-tested, no `AVFoundation`/
`CoreMediaIO` import) implements the decision logic above; the App-side
`MonitorReminderController` drives it from `CMIOCameraBusyProvider` and
speaks its decisions through a `SpeechRenderer` it owns for the app's own
lifetime (independent of `PipelineModel`'s pipeline-lifetime renderer — see
that controller's doc comment for why, and for how the two renderers are
kept from ever speaking over each other). Camera-gated **auto-activation**
remains un-shipped, exactly as before — only the reminder direction was
built. The pure decision machine (`CameraGatingStateMachine`), the
platform-probe layer (`CameraInUseMonitor`/`CameraBusyProvider`/
`AVCaptureDeviceBusyProvider`), and their tests remain in the codebase for
auto-activation specifically, unwired, per §16.4. `CameraGatingStateMachine`
is shaped for auto-activation's three-way off/setup/monitor decision table;
`CameraReminderStateMachine` is the separate, simpler machine the reminder
actually needed, per the prediction this section made before either was
built. Do not re-wire `CameraGatingStateMachine` into a live activation
path without first reading this finding.

### 12.3 Mismatch warning

The API tells you a device is busy, **not which app holds it**. So the heuristic
is: if some device other than the user's selection reports in-use while the
selected one does not, warn that the conferencing app may be using a different
camera. Warning is informational and dismissible, never blocking.

**Dependency on §12.2's finding:** as specified, this heuristic is
`isInUseByAnotherApplication` read across devices — and §12.2 found that
property never becomes true on current macOS. Built as specified, this
warning would compile, never crash, and never fire; it would look
implemented while silently doing nothing. Do not build this against
`isInUseByAnotherApplication`. `kCMIODevicePropertyDeviceIsRunningSomewhere`
is a candidate substitute: unlike `isInUseByAnotherApplication` it is read
per-device — the reference probe enumerated every device on the test
machine (the built-in camera, an iPhone Continuity camera, and a Desk View
camera) and reported each one's running state independently — which is a
natural fit for exactly this cross-device comparison. Designing and
building the replacement was separate, later work — now done; see below.

**Status: shipped, on a corrected heuristic.** Built on
`CMIOAllDevicesBusyReader.currentRunningStates()` (§12.2's per-device
signal, one reading per enumerable CoreMediaIO device). The literal rule
above — "another device running while the SELECTED one is not" — turned out
to silently assume About Face itself is not using the selected camera. It
isn't a safe assumption: `kCMIODevicePropertyDeviceIsRunningSomewhere`
reads true for **any** process streaming, including About Face's own
Setup/Monitor capture (§12.2's asymmetry), so the instant this app opens
the selected device, that device's own reading stops being "not running" —
and the literal rule can never fire in exactly the scenario it exists for:
About Face monitoring camera A while the real call is on camera B. The user
who most needs this warning is precisely the one for whom the literal rule
goes permanently silent.

**Corrected rule, implemented:** warn when any NON-selected device reads
`.running` — full stop, never consulting the selected device's own reading
in either direction. This works identically whether About Face is idle or
actively capturing, unlike the literal rule, because it never needs to
distinguish "someone else" from "us" on the selected device — it simply
never asks that question. A conferencing app is presumably on one camera;
another camera running is the only signal CoreMediaIO can actually give,
regardless of what About Face itself is doing at that moment.

Accepted false positive, stated honestly (also documented at the type
level, `CameraMismatchClassifier.swift`): this fires whenever ANY other
camera is running, not only when a conferencing app is confusably on it —
Photo Booth, a second video app, or a background utility touching a
different camera produces the identical reading. CoreMediaIO gives no way
to tell those apart ("the API tells you a device is busy, not which app
holds it," verbatim above). This is judged acceptable because the surface
was already designed for it: "informational and dismissible, never
blocking." The cost of a false positive is one dismissible notice, not a
wrong decision made on the user's behalf.

Failed reads (`.deviceNotFound`/`.propertyReadFailed`) are treated as "not
running" for the running-device comparison, but a total read failure is
never presented as an all-clear: if every device in a snapshot failed to
read (including an empty snapshot), `CameraMismatchClassifier` reports
`.unreliable`, a third classification distinct from `.clear`/`.mismatch` —
repeating §12.2's own "a signal that 'worked' while silently uncertain"
failure was the one thing this section could not also do quietly.

Structure: `CameraMismatchClassifier` (pure per-snapshot classification,
`AboutFaceCore`) → `CameraMismatchStateMachine` (debounce, reusing
`Config.Camera.busyDebounceMs` — no second debounce for one signal, and a
dismiss/re-arm discipline: dismissing suppresses the current episode;
re-arming happens only when the debounced classification settles back to
`.clear`, after which the next non-clear settle shows again with no
explicit un-dismiss) → `CameraMismatchMonitor` (Core actor, polls
`currentRunningStates()` on `Config.Camera.busyPollIntervalSeconds` — no
per-device listener exists for "every device, including ones that connect
later," so this is a poll loop, gated to run only while a camera is
selected and a Setup window exists, never an always-on background timer) →
`CameraMismatchController` (App/, thin, wires the above to
`PipelineModel.cameraMismatchWarning`). Config-keyed via
`Config.Camera.cameraMismatchWarningEnabled`, default `true`, no
`Config.version` bump. Surfaced as a dismissible, VoiceOver-readable
notice in the Setup window, next to `monitorReminderIssue`/
`hotkeyRegistrationIssue` — never spoken automatically (unlike §12.2's
reminder; this section's own wording is "informational," and a second
unprompted utterance is a product decision left to the maintainer), and
never blocking any control.

### 12.4 Virtual cameras — silent-wrongness risk

OBS, Snap Camera, and similar appear as ordinary capture devices. If the
conferencing app is on a virtual camera fed by the physical one, the far end may
be cropped, mirrored, or scene-composited, and every framing verdict is silently
wrong.

This cannot be reliably detected from device type. Match against known
virtual-camera name patterns (maintain the list in one file) and surface a
one-time acknowledgeable warning.

**Status: shipped (2026-08-04).** The list lives in
`Sources/AboutFaceCore/Capture/VirtualCameraPatterns.swift` and holds nothing
else, so it stays trivial to find and extend; each entry carries a
maintainer-facing note on what product it identifies and how confident that
entry is. `VirtualCameraClassifier` is the pure matcher over it.

**Matching is on word boundaries, not raw substrings.** The list necessarily
contains short patterns (`Camo` is four characters, `mmhmm` five), and a bare
substring test would fire on any device name that happened to contain those
letters inside a longer token or a localized name. The governing principle is
that **over-detection is worse than under-detection here**: a missed virtual
camera is silence, while a false positive tells a user their genuine physical
camera is fake — a confident, out-loud, wrong claim. Word boundaries can only
ever shrink the matching set, which is the safe direction to be wrong in.

The warning **names the matched product**, because it is only actionable if
the user can tell in one beat whether it is right ("yes, I'm on OBS") or a
false positive ("no, that's my actual webcam").

Acknowledgement is keyed **per device** by `AVCaptureDevice.uniqueID` and
persisted in `Config.Camera.acknowledgedVirtualCameraIDs`, so "one-time"
means once ever rather than once per launch. Deliberately not a single global
flag: acknowledging OBS must not suppress the warning for a different virtual
camera selected later, which would turn one acknowledgement into a permanent
blindfold against exactly this failure.

Surfaced as a VoiceOver-readable, never-blocking notice in the Setup window
alongside §12.3's. Not spoken — same posture as §12.3.

**Known and permanent limitation:** a virtual camera whose name is not in the
list produces no warning at all. New products ship, existing ones rename their
device, users run something obscure or self-built. There is no more reliable
signal available to close that gap — this section's own "cannot be reliably
detected from device type" is why it is a name list in the first place.
Padding the list with unverified guesses would trade under-detection for
over-detection, which the principle above rules out.

### 12.5 Center Stage

On Center Stage–capable cameras (Studio Display, Continuity Camera, newer Macs)
the OS already auto-frames the subject, and **it is a per-capture-session
setting** — the conferencing app's state and this app's state can differ.

- Query `AVCaptureDevice.centerStageControlMode` and `isCenterStageEnabled`.
- When Center Stage is on, **say so and shift the report**: "Center Stage is on,
  framing is automatic" plus lighting, gaze, and other-people signals.
- Silently reporting a framing problem the OS is already correcting is worse than
  reporting nothing.

**Status (2026-08-04): read layer only, nothing built on top of it yet.**
This PR added `CenterStageReading`/`CenterStageReader`/`CenterStageDeviceReading`
(`AboutFaceCore`) and wired `probe-camera` to print what these signals actually
report — on the selected device, before and after this tool opens its own
capture session, plus a per-device capability breakdown across every camera —
and nothing else: no feedback routing, no Query change, no `Config` key, no
Setup-window UI. §12.2 shipped a camera-gating feature on
`isInUseByAnotherApplication` that turned out to read `false` during a live
Zoom call, and the whole feature had to be un-shipped; this section is
deliberately sequenced so that doesn't happen again here.

**Correction to this section's own text, from `AVCaptureDevice.h` (verified
against the header, 2026-08-04):** "it is a per-capture-session setting,"
above, is not quite right. `centerStageControlMode` and `isCenterStageEnabled`
are **class** properties — process-wide, driven by the user's own Control
Center toggle, not by a capture session. What actually varies per
device/configuration is `device.isCenterStageActive`, an **instance**
property: per the header, "a particular AVCaptureDevice instance may return
YES for this property, depending whether it supports the feature in its
current configuration." `CenterStageReading.automaticFramingInEffect` is
therefore `deviceReportsActive` (`isCenterStageActive`) alone — see that
computed property's doc comment for the full "which direction is safe to be
wrong in" argument, the same reasoning §12.4 uses for word-boundary matching.

**Measured on hardware 2026-08-05 — and this section's own instruction is
wrong.** The bullet above says to query `centerStageControlMode` and
`isCenterStageEnabled`. A feature built on that instruction would never have
fired even once. With Center Stage genuinely switched ON by the user for a
Continuity Camera, and no other application holding the device (CoreMediaIO
`idle`, `isInUseByAnotherApplication` false), `probe-camera` reported:

- `AVCaptureDevice.isCenterStageEnabled` (class) — **`false`**
- `device.isCenterStageActive` (instance) — **`true`**

The process-wide class property does not track the user's per-camera toggle;
the instance property does. Confirmed as a full round trip — off → on → off —
with `isCenterStageActive` reading `no` / `yes` / `no` and
`isCenterStageEnabled` reading `false` at every one of the three points. The
class property tracked nothing at all on this hardware. The falling edge was
measured deliberately and not inferred: any behavior that suppresses framing
feedback while Center Stage is on depends on the signal actually clearing, or
the app would go permanently silent about framing with no route back.
This is §12.2's finding repeating in a new place: **the more obvious of the two
signals is the one that lies**, and only reading both side by side made it
visible. `CenterStageReading.automaticFramingInEffect` is `deviceReportsActive`
alone, which this measurement turns from a defensible design call into the only
correct one. Nothing may gate Center Stage behavior on `systemEnabled`.

**The blind spot is narrower than first documented.** `isCenterStageActive`
read `true` *before* this process opened any capture session on the device, so
the state is observable device-wide without holding the camera — which means
About Face can detect Center Stage while a conferencing app owns the device,
the case that matters most. What remains genuinely unobservable is narrower: an
app that takes `.app` or `.cooperative` control mode can override Center Stage
for its own session only, and we would still read the user-level device state.
In the ordinary `.user` control mode this Mac reports, our reading is the same
one any other capture of that device gets.

**Hardware facts from the same run** (maintainer's machine, 2026-08-05): the
built-in FaceTime HD Camera supports Center Stage in **no** format, and neither
does Desk View — the Continuity Camera is the only capable device present. Both
640×480 (Monitor) and 1280×720 (Setup) support it there, so there is no
format-dependent gotcha to design around. Unrelated finding from the same
output, not yet addressed: the Continuity Camera **ignored a 15 fps request and
delivered 30**, where the built-in camera honored 15 exactly — §5.2's Monitor
format is silently capturing at double rate on that device.

**Status (2026-08-05): core suppression behavior shipped, headless — app-side
wiring still outstanding.** Built entirely on `isCenterStageActive`, the one
signal the measurement above establishes as trustworthy; nothing in this
change consults `systemEnabled`. `FeedbackRouter.setCenterStageActive(_:at:)`
(`FeedbackRouter+CenterStage.swift`) is the rising/falling-edge latch a caller
drives from a live reading — it speaks "Center Stage is on. Framing is
automatic." / the falling-edge counterpart once per genuine transition,
routed through the router's own `fire(...)` so it inherits §7.5 manual
silence and §7.3's rung-3 `userLikelyAway` STOP for free: Center Stage is
never announced to an empty desk. Downstream, three suppression points read
the resulting `centerStageActive` flag: the continuous positional beacon
(`FeedbackRouter+Continuous.swift`) falls back to the existing gaze-trim
target rather than guiding the user toward a crop the OS is simultaneously
re-aiming; the spoken framing instruction is dropped
(`announcementPayload(for:output:centerStageActive:)`,
`FeedbackRouter+AnnouncementPayload.swift`); and good-zone entry drops its
chime and "Centered." while still running the bookkeeping that keeps §6.1's
liveness heartbeat alive for the rest of the episode. §7.3 face-lost recovery
falls back to "Back, centered." rather than announcing nothing when Center
Stage has suppressed the framing phrase recovery would otherwise speak on
reacquisition. `QueryComposer.summarize(burst:problemsOnly:centerStageActive:)`
replaces the framing field with the same phrase, including under
`problemsOnly` — omitting it there would read as a "framing is fine" claim
this app cannot back up while Center Stage owns the crop. Config-keyed via
`Config.Camera.centerStageAwarenessEnabled`, default `true`, gating the STATE
itself rather than just the notice, so none of the three suppression sites
needs its own copy of the check.

**Status (2026-08-05): app-side wiring shipped — the signal is now live.**
`CenterStageMonitor` (Core) polls `CenterStageReader.read(forUniqueID:)` for
the selected device on `Config.Camera.busyPollIntervalSeconds`; there is no
per-device listener for this property, so it is a poll loop, started only
while a camera is actually selected rather than as an always-on timer — the
same restraint and the same cadence field §12.3's monitor uses.
`CenterStageClassifier` turns each reading into a `CenterStageSignal`,
`CenterStageStateMachine` debounces it on `Config.Camera.busyDebounceMs` (§4/§7
hysteresis, and §0's "no second debounce for one underlying signal"), and the
App-side `CenterStageController` drives both
`FeedbackRouter.setCenterStageActive(_:at:)` and the Setup window's notice.

**Three states, never two.** A device that cannot be resolved is `.unknown`,
kept distinct from `.notActive` all the way out to the UI, which reports
"Center Stage status could not be determined for the selected camera" rather
than the confident "off" a two-state `Bool` would have forced. For the
router's boolean both resolve to *not active*: over-detection would silence
framing feedback on a camera nothing is auto-framing, which
`automaticFramingInEffect`'s doc comment establishes as the worse direction to
be wrong in. This is the same refusal to let "couldn't read this" masquerade
as an all-clear that §12.3's `.unreliable` classification exists for.

**Debug override.** `PipelineModel.centerStageDebugOverride` is a tri-state
(`nil` = follow the real signal), settable from the debug panel, so the
suppression behavior can be judged by ear without depending on the poller —
or on Center-Stage-capable hardware — being available. It wins over the
poller and is re-resolved on every tick, so a poll landing mid-override
cannot silently revert it. It deliberately never writes
`centerStageNotice`: the Setup window keeps reporting what the hardware
actually says even while the router is being forced, so a forced value can
only ever appear as behavior, never as a fabricated reading. Removable once
§13's Phase 4.5 presentation pass reaches this surface.

**Measured 2026-08-05: Center Stage breaks face detection under movement,
and that is worse than the problem this section was written to solve.**
`aboutface-cli live` on a Continuity Camera, 1280×720, 30s per condition,
same movement, Center Stage the only variable:

| | Center Stage off | Center Stage on |
|---|---|---|
| frames `ok` | 97.6% | **75.4%** |
| frames `noFace` | 2.4% | **24.6%** |
| face-lost episodes | 9 | **31** |
| longest episode | **169 ms** | **2,528 ms** |
| total time with no face | 0.8 s | **8.5 s** |

Sitting still with Center Stage on measured 100% `ok`, and `lowConfidence`
was zero in every run — so this is not image quality and not Center Stage
as such. Vision loses the face **while the crop is being re-aimed**. Ordinary
movement stays under §7.3's 500 ms rung-1 threshold in every episode; Center
Stage clears it constantly, and also clears Monitor's 1500 ms. The user hears
face-lost and face-reacquired earcons cycling while sitting in front of a
camera that is tracking them correctly.

**Fix: rung 1 is suppressed while Center Stage is active** (maintainer's
decision, over a longer fitted delay — a threshold tuned to one 30s sample
would still nag on a worse day). The rung still ADVANCES, silently, because
rungs 2 and 3 are reachable only through it and stranding §7.3's 30s STOP
would be far worse than the nagging. Rung 2's spoken "No face." at 5s is
untouched: no measured re-aim came close, so a five-second absence still
means what it always meant. `FeedbackRouter.faceLostEpisodeWasAudible` tracks
whether an episode ever made a sound, separately from which rung it reached,
so recovery does not fire `.faceReacquired` for an absence the user was never
told about — that would regenerate the second half of the same cycling. An
episode that reached rung 3 always recovers audibly regardless.

The Setup window's Center Stage notice states the tradeoff; it is not spoken
(maintainer's call — learned once, re-readable, rather than lengthening an
utterance heard on every toggle).

**Instrument note.** This was invisible until `live` counted EVERY frame's
`signalState` rather than sampling once per second, and reported face-lost
episode count and duration. Two earlier measurement sessions were also
invalidated by rig state — a Continuity Camera slept and silently reset
Center Stage, and a locked phone changed what was being captured — so `live`
now supports `--warmup` (analyze but exclude, for settling) and prints the
device's Center Stage state at the end, making every run label its own
condition instead of depending on someone remembering how a toggle was set.

**The arrival chime is now a toggle, defaulting ON**
(`FeedbackConfig.centerStageArrivalChimeEnabled`). It originally shipped
suppressed, on the argument that the chime marks the end of a correction the
user made and under Center Stage they made none. That was never actually
judged by ear, because the face-lost ladder was cycling over the top of it;
once that was fixed the maintainer's call (2026-08-05) was "worth trying
turned on, perhaps behind a toggle." The Debug panel exposes it beside the
Center Stage override, and `PipelineModel.pushConfigToFeedbackChain` forwards
`Config.feedback` to the live router, so it can be flipped mid-session — the
only way a question about how something SOUNDS gets answered honestly.

**The toggle governs the earcon only.** Setup's spoken "Centered." stays
suppressed under Center Stage at either position and is deliberately not
switchable: it is a framing VERDICT, and this section forbids reporting
framing while the OS owns the crop — asserting the good case is the same
claim with the sign flipped. The chime is not a verdict but a punctuation
mark ("you are placed now"), which is why whether it earns its place under
automatic framing is a question about sound rather than about truth.

**Still unverified by ear.** Two judgment calls await the maintainer's own
listening: the arrival chime is suppressed under Center Stage (it marks the
end of a correction the user did not make — but its absence may read as the
app having died), and the falling edge speaks as well as the rising one (the
beacon resumes there, and an unexplained tone reappearing is the same
disorientation inverted). Both are trivially reversible.

### 12.6 Concurrent access test

Write an explicit test/tool that opens the selected device **while another app
holds it** and logs the format actually granted. Do not assume the requested
format is honored.

**Run 2026-08-03: passed.** Two processes captured from the same physical
camera at the same time, each at a different requested format (1280×720 and
640×480), and each received exactly the format it requested; probing did not
disturb the live Zoom call already using the device. This is the same
measurement §12.2 records in full, because it also bears on the shared-camera
model behind that section's finding — the concurrent-access test itself did
not fail.

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

**Camera-in-use gating exception (2026-08-03):** the state machine and
platform probe are built and tested, but §12.2's detection mechanism does not
work on current macOS, so gating is not wired into a live activation path.
Monitor mode ships via the ⌘⌃⇧M hotkey and menu bar item instead; the rest of
this phase's scope is otherwise complete as listed.

### Phase 4.5 — Design coherence pass

Added 2026-08-02, from maintainer field experience: by this point the app's
surfaces have grown feature-by-feature ("a bit haphazard, a lot of the
wording in the settings is hard to parse"). Before first-run and packaging,
a deliberate pass over language and structure — features frozen, coherence
the only goal:

- **One vocabulary.** A written glossary: one name per concept (the beacon,
  the refinement clicks, placed/good zone, the trim, capture), used
  identically in UI labels, accessibility hints, spoken phrases, docs, and
  code comments. New strings after this pass must use glossary terms.
- **Every user-facing string reviewed spoken-first.** Labels and hints must
  parse on one listen at speed, without visual grouping to lean on.
  Function-before-key phrasing throughout (already the CLI convention).
- **Settings split by audience.** The §9 debug panel is a tuning
  instrument; end users need a small, plain-language settings surface
  (voice, speech rate, volumes, output device, scheme) with the full panel
  behind an "advanced tuning" door. §11's "everything adjustable, nothing
  required" implies this two-tier shape.
- **Structure by user need, not code history.** Window and section ordering
  reviewed against actual task flows (get positioned; check status; tune).

*Acceptance:* a fresh VoiceOver user (not the maintainer) can navigate
Setup and basic settings and correctly explain what each control does from
its label and hint alone; the glossary exists and the repo's strings match
it.

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
- [ ] Entitlements: camera and user-selected file access present (see §2); `network.client` and `network.server` **absent** (CI-enforced)
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
2. ~~Whether Scheme B (zero-beat) should be on by default once tuned.~~
   **Resolved 2026-08-02:** yes — round 2's re-trial of the percussive
   redesign came back "that works" (blind verdict), `p7-schemeb-quantized`
   won outright. `Config.AudioScheme.schemeBEnabled` now defaults `true`.
   See `docs/tuning/2026-08-02-convergence-experiment.md`'s closure note.
3. Eloquence/Vocalizer voice availability (see §6.3) — outcome affects the
   voice-picker UI.
4. Whether Monitor mode should auto-enable on camera-in-use by default, or
   require explicit opt-in per profile. **Updated 2026-08-03:** moot as
   originally framed — §12.2's proposed detection mechanism does not work, so
   there is currently no camera-in-use signal to gate on. Maintainer decision:
   do not ship camera-gated auto-activation even once a working mechanism
   exists, without also solving how to explain the trigger to a user — an
   activation trigger nobody can predict is worse than no trigger, "even if
   it's built correctly."

   **Narrowed 2026-08-03:** the maintainer proposed a direction — not
   auto-activation, but a spoken/earcon reminder to turn Monitor on by hand
   when another app starts using the camera; see §12.2's "Proposed
   direction." The trigger is now identified. What is open is what the app
   should DO on that rising edge: spoken vs. earcon, exact wording (would
   enter `Lexicon.swift`'s closed vocabulary, §6.3), whether the reminder is
   dismissible, whether it repeats or fires once per rising edge, and how it
   interacts with §7.5 manual silence. Do not re-wire §12.2's machinery into
   a live activation or reminder path until those are decided.

   **Decided and shipped 2026-08-03/04:** spoken, one fixed phrase —
   "Camera in use. Monitor is off." (`Lexicon.Reminder.cameraInUseMonitorOff`)
   — not dismissible, fires once per rising edge and re-arms only after the
   busy signal falls back to false, and respects §7.5 manual silence with no
   exceptions. See §12.2's "Direction taken" passage for the full decision
   record, including the no-retroactive-fire rule for gates (silence,
   capturing, or `Config.Camera.monitorReminderEnabled`) that block an edge.
   Camera-gated auto-activation itself remains un-shipped — only this
   reminder direction was built.
