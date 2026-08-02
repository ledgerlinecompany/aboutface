import CoreMedia
import Testing

@testable import AboutFaceCore

// MARK: - Mock renderers
//
// Record every call, in order, as a `Call` value — actors (not plain
// classes) purely so recording is safe under Swift 6 strict concurrency
// without a manual lock, the same reasoning `ScriptedBackend`
// (`AnalysisEngineTestSupport.swift`) uses for its own mock.

actor MockAudioRenderer: AudioRendering {
  enum Call: Equatable {
    case start
    case stop
    case update(SonificationTarget?)
    case play(AudioEvent)
    case setSilenced(Bool)
  }

  private(set) var calls: [Call] = []

  func start() async throws { calls.append(.start) }
  func stop() async { calls.append(.stop) }
  func update(_ target: SonificationTarget?) async { calls.append(.update(target)) }
  func play(_ event: AudioEvent) async { calls.append(.play(event)) }
  func setSilenced(_ silenced: Bool) async { calls.append(.setSilenced(silenced)) }
}

actor MockSpeechRenderer: SpeechRendering {
  enum Call: Equatable {
    case speak(Lexicon.Phrase)
    case stopSpeaking
  }

  private(set) var calls: [Call] = []

  func speak(_ phrase: Lexicon.Phrase) async { calls.append(.speak(phrase)) }
  func stopSpeaking() async { calls.append(.stopSpeaking) }
}

actor MockEventSubscriber: EventSubscriber {
  private(set) var events: [AudioEvent] = []

  func handle(_ event: AudioEvent) async { events.append(event) }
}

// MARK: - EngineOutput builders

/// A `LightingMetrics` value with harmless, mid-range numbers — none of
/// `FeedbackRouter`'s logic reads lighting directly (§7.4's
/// `.lightingCritical` gate is stubbed `false` this phase), so its exact
/// content never matters to these tests.
let neutralLighting = LightingMetrics(
  faceLuma: 0.5,
  backgroundLuma: 0.5,
  backlightDelta: 0,
  clippedHighlightFraction: 0,
  clippedShadowFraction: 0,
  colorTempSkew: 0,
  sharpness: 0.5,
  frameLumaVariance: 0.05
)

/// Builds one frame of `EngineOutput` directly (bypassing `AnalysisEngine`
/// entirely) — `FeedbackRouter`'s tests exercise the router in isolation
/// against hand-specified signal/framing combinations, including
/// combinations `AnalysisEngine`'s real pipeline wouldn't typically produce
/// together (e.g. `FeedbackRouterPriorityTests`' simultaneous
/// `.noSignal` + out-of-dead-zone framing) but that `EngineOutput`'s type
/// does not itself forbid, matching the real engine's actual contract: a
/// `.noSignal` classification can coexist with a detected face's `framing`
/// when a face is found on an otherwise near-uniform frame (see
/// `AnalysisEngine.process(_:)` — `classifySignalState` runs even when
/// `hasFace == true`).
func makeOutput(
  signalState: SignalState = .ok,
  hasFace: Bool = true,
  errorX: Float = 0,
  errorY: Float = 0,
  distanceError: Float = 0,
  inDeadZone: Bool = true,
  gazeOnCamera: Bool = true,
  yaw: Float = 0,
  pitch: Float = 0
) -> EngineOutput {
  let framing: FramingState? =
    hasFace
    ? FramingState(
      error: SIMD2(errorX, errorY),
      distanceError: distanceError,
      inDeadZone: inDeadZone,
      gazeOnCamera: gazeOnCamera
    ) : nil
  // `yaw`/`pitch` default to 0 and are otherwise unused by any pre-existing
  // test — only the tuning-round-5 gaze-trim tests
  // (`FeedbackRouterGazeTrimTests`) pass non-default values, to exercise
  // `FeedbackRouter.gazeTrimTarget(output:framing:)`'s
  // `output.analysis.primary.yaw`/`.pitch` reads. Every other `FaceGeometry`
  // field is a harmless placeholder — nothing else in `FeedbackRouter`
  // reads `analysis.primary` at all.
  let primary: FaceGeometry? =
    hasFace
    ? FaceGeometry(
      boundingBox: .zero, eyeMidpoint: .zero, interocularDistance: 0, yaw: yaw, pitch: pitch,
      roll: 0, captureQuality: nil, confidence: 1
    ) : nil
  let analysis = FrameAnalysis(
    timestamp: .zero,
    signalState: signalState,
    faceCount: hasFace ? 1 : 0,
    primary: primary,
    lighting: neutralLighting
  )
  return EngineOutput(analysis: analysis, framing: framing)
}

/// Convenience for `.goodZone`-classifying output: `.ok`, in dead zone,
/// gaze on camera.
func goodZoneOutput() -> EngineOutput {
  makeOutput(signalState: .ok, inDeadZone: true, gazeOnCamera: true)
}

/// Convenience for `.framingError`-classifying output: `.ok`, out of dead
/// zone. `errorX` defaults to a value larger than any single-axis default
/// dead zone so it reads unambiguously as "framing error, dominant axis
/// horizontal" in tests that don't care about the exact axis.
func framingErrorOutput(errorX: Float = 0.5) -> EngineOutput {
  makeOutput(signalState: .ok, errorX: errorX, inDeadZone: false, gazeOnCamera: true)
}

/// Convenience for `.faceLost`-classifying output: `SignalState.noFace`, no
/// framing — matching `AnalysisEngine.process(_:)`'s own contract that
/// `framing` is `nil` exactly when no face was found.
func faceLostOutput() -> EngineOutput {
  makeOutput(signalState: .noFace, hasFace: false)
}

/// Convenience for `.noSignal`-classifying output.
func noSignalOutput() -> EngineOutput {
  makeOutput(signalState: .noSignal, hasFace: false)
}

// MARK: - Time helpers

/// Feeds `output` to `router` `count` times, all at the SAME instant `time`
/// — §7.2's N-frame suppression counts CONSECUTIVE FRAMES, not elapsed wall
/// time, so a fixed test instant repeated `count` times is a faithful (and
/// much less verbose) stand-in for `count` frames arriving in quick
/// succession at whatever the mode's real analysis rate is.
func ingestRepeated(
  _ router: FeedbackRouter,
  _ output: EngineOutput,
  at time: ContinuousClock.Instant,
  count: Int
) async {
  for _ in 0..<count {
    await router.ingest(output, at: time)
  }
}

extension ContinuousClock.Instant {
  func plus(ms: Int) -> ContinuousClock.Instant {
    self.advanced(by: .milliseconds(ms))
  }
}
