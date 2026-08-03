import CoreGraphics
import CoreMedia
import CoreVideo

/// The "analysis actor" domain of §3.1: turns one backend's raw, per-frame
/// output into the spec's signal types. Consumes `RawFaceObservation` (from
/// a `FaceAnalysisBackend`) and raw pixel data (via `LightingAnalyzer`), and
/// produces `FrameAnalysis` (§3.3) plus `FramingState` (§3.3), bundled as
/// `EngineOutput`.
///
/// ## Scope
///
/// This type owns:
/// - The §3.4 egocentric boundary — the ONE place a `RawFaceObservation`
///   (backend-native, pre-egocentric) becomes a `FaceGeometry` (egocentric),
///   driven by `CapturedFrame.mirrorState`. See `AnalysisEngine+Geometry.swift`
///   (`faceGeometry(from:mirror:)`, `egocentricPose(raw:mirror:)`).
/// - `SignalState` classification (§3.3), below.
/// - `FramingState` derivation: error vs. `Config.targetFraming`, EMA
///   smoothing (§4), hysteresis-latched `inDeadZone` (§4, §7.1's "hysteresis
///   on every threshold"), and `gazeOnCamera`. See
///   `AnalysisEngine+Framing.swift`.
///
/// This type deliberately does NOT own dwell timing, announcement
/// suppression, the face-lost escalation ladder, or the priority ladder
/// (§7) — those read a *stream* of `EngineOutput` over time and decide what
/// to say and when; that is `FeedbackRouter`/audio-layer work (§13, Phases
/// 3–4) and is out of scope here. `AnalysisEngine` produces continuous,
/// per-frame signals only, with no notion of "should this be announced."
///
/// ## Determinism
///
/// `process(_:)` is a pure function of (this frame, the engine's prior
/// smoothing/hysteresis state, the current `Config`) — no wall-clock reads,
/// no randomness, no hidden global state. Given an identical sequence of
/// frames through a freshly-constructed engine with an identical starting
/// `Config`, repeated runs produce byte-identical output sequences. This is
/// what makes corpus regression (§14) meaningful: replaying the same clip
/// twice must never produce different results.
///
/// ## Concurrency
///
/// An actor, per §3.1's naming of the "analysis actor" as one of the four
/// concurrency domains. Its mutable state (`smoothedError`,
/// `smoothedDistanceError`, `inDeadZoneLatched`, declared in
/// `AnalysisEngine+Framing.swift`) is only ever touched from actor-isolated
/// code, so no external synchronization is needed, and `process(_:)` calls
/// against a single engine instance are automatically serialized (which is
/// required for the smoothing/hysteresis state to make sense as a single
/// time series in the first place).
///
/// ## File layout
///
/// Split across four files purely to keep each one a manageable size, the
/// same way `LightingAnalyzer` is split into
/// `LightingAnalyzer{,Downsample,Math}.swift` — everywhere below is still
/// `AnalysisEngine`'s own implementation, not a separate public surface:
/// - `AnalysisEngine.swift` (this file): actor state, `init`, `process(_:)`,
///   `stream(from:)`, `SignalState` classification, `EngineOutput`.
/// - `AnalysisEngine+Geometry.swift`: the §3.4 egocentric boundary.
/// - `AnalysisEngine+Framing.swift`: `FramingState` derivation (smoothing,
///   hysteresis, gaze).
/// - `AnalysisEngine+GazeBaseline.swift`: the capture-free learned-baseline
///   EMA (§13 Phase 5 hard MUST) that backs `gazeOnCamera`.
public actor AnalysisEngine {
  let backend: any FaceAnalysisBackend
  var config: Config

  // MARK: - Smoothing / hysteresis state (§4, §7)
  //
  // Declared here (read/written from `AnalysisEngine+Framing.swift`) so
  // every stored property lives in one place. Reset whenever a frame
  // reports no face (see `process(_:)`'s early return): stale smoothing
  // history from before a gap must not bias the first reading after
  // reacquisition — an EMA that silently carried a pre-gap value forward
  // would report a misleadingly "already close" position for a frame or
  // two after the subject reappears somewhere completely different.
  // Likewise, a latched `inDeadZone == true` is meaningless with no subject
  // to be "in" or "out" of a zone. This is a deliberate design choice, not
  // a spec MUST; §7's face-lost escalation ladder (out of scope here) may
  // want its own, different recovery semantics once it lands — revisit
  // then if needed.
  var smoothedError: SIMD2<Float>?
  var smoothedDistanceError: Float?
  var inDeadZoneLatched = false

  // MARK: - Learned gaze baseline state (§13 Phase 5, `AnalysisEngine+GazeBaseline.swift`)
  //
  // Declared here for the same "every stored property lives in one place"
  // reason as the smoothing state above, but deliberately NOT reset by
  // `resetSmoothingState()`/on face loss — see that method's doc comment.
  // `learnedBaselineYaw`/`Pitch`/`Roll` are `nil` exactly when nothing has
  // seeded the baseline yet (no capture, no eligible in-zone frame).
  // `baselineSeed*` record the seed value the clamp is measured from
  // (capture, or the first seed from an in-zone frame) — distinct from the
  // current learned value, which drifts within the clamp as the EMA adapts.
  // `lastFrameTimestamp` is the previous geometry-bearing frame's
  // timestamp, used to convert `Config.Gaze.baselineAdaptationSeconds` into
  // a per-frame alpha from the observed frame cadence; it IS reset on face
  // loss (a stale cadence reference across a gap is meaningless — same
  // reasoning as the smoothing state, just for timing rather than
  // position), which only affects the alpha of the next adaptation, never
  // the learned value itself. Roll joined this machinery 2026-08-02
  // (maintainer: "Agreed, it's part of gaze") — see
  // `AnalysisEngine+GazeBaseline.swift`'s top-level doc comment and
  // `FramingState.headLevel`.
  var learnedBaselineYaw: Float?
  var learnedBaselinePitch: Float?
  var learnedBaselineRoll: Float?
  var baselineSeedYaw: Float?
  var baselineSeedPitch: Float?
  var baselineSeedRoll: Float?
  var lastFrameTimestamp: CMTime?

  public init(backend: any FaceAnalysisBackend, config: Config = .defaults) {
    self.backend = backend
    self.config = config
    if let seed = Self.captureSeed(previous: nil, new: config) {
      learnedBaselineYaw = seed.yaw
      learnedBaselinePitch = seed.pitch
      learnedBaselineRoll = seed.roll
      baselineSeedYaw = seed.yaw
      baselineSeedPitch = seed.pitch
      baselineSeedRoll = seed.roll
    }
  }

  /// Replaces the live `Config`. Takes effect starting with the next
  /// `process(_:)` call; already-produced `EngineOutput`s are not
  /// retroactively recomputed. (The anticipated caller is Phase 2's debug
  /// panel, §9, where every threshold is a live slider bound to `Config` —
  /// not exercised yet in Phase 1, but the actor boundary already makes
  /// this safe to call while `process(_:)`/`stream(from:)` are in flight.)
  ///
  /// Also re-seeds the learned gaze baseline (`AnalysisEngine+GazeBaseline.swift`)
  /// when — and only when — `targetFraming.neutralYawDegrees`/
  /// `neutralPitchDegrees` CHANGED to a new nonzero value: a fresh "capture
  /// current position as target" is an instant-set override of the user's
  /// neutral pose, so the learned baseline should snap to it immediately
  /// rather than crawl there over `baselineAdaptationSeconds`. An unrelated
  /// `updateConfig` call (a slider tweak elsewhere in the debug panel) must
  /// NOT re-seed — that would erase whatever the baseline had already
  /// learned since the last capture for no reason.
  public func updateConfig(_ config: Config) {
    let previous = self.config
    self.config = config
    if let seed = Self.captureSeed(previous: previous, new: config) {
      learnedBaselineYaw = seed.yaw
      learnedBaselinePitch = seed.pitch
      learnedBaselineRoll = seed.roll
      baselineSeedYaw = seed.yaw
      baselineSeedPitch = seed.pitch
      baselineSeedRoll = seed.roll
    }
  }

  /// Processes one frame end to end: backend inference, lighting analysis,
  /// the §3.4 egocentric conversion, `SignalState` classification, and
  /// `FramingState` derivation (smoothing + hysteresis).
  ///
  /// Throws only for a genuine per-frame processing failure (the backend or
  /// `LightingAnalyzer` throwing). "No face in an otherwise-healthy frame"
  /// is represented by `RawFaceObservation` being `nil` — matching
  /// `FaceAnalysisBackend.analyze(_:)`'s own contract — and produces a
  /// normal (non-throwing) `EngineOutput` with `analysis.primary == nil`
  /// and `framing == nil`.
  public func process(_ frame: CapturedFrame) async throws -> EngineOutput {
    let raw = try await backend.analyze(frame)

    guard let raw else {
      resetSmoothingState()
      let lighting = try LightingAnalyzer.analyze(
        pixelBuffer: frame.pixelBuffer,
        faceROI: nil,
        config: config
      )
      let signalState = classifySignalState(lighting: lighting, hasFace: false, confidence: nil)
      let analysis = FrameAnalysis(
        timestamp: frame.timestamp,
        signalState: signalState,
        faceCount: 0,
        primary: nil,
        lighting: lighting
      )
      return EngineOutput(analysis: analysis, framing: nil)
    }

    // Lighting wants Vision raw space, pre-egocentric (its own doc
    // comment); `raw.boundingBox` is exactly that — `RawFaceObservation`'s
    // contracted, not-yet-egocentric coordinate space.
    let lighting = try LightingAnalyzer.analyze(
      pixelBuffer: frame.pixelBuffer,
      faceROI: raw.boundingBox,
      config: config
    )
    let geometry = Self.faceGeometry(from: raw, mirror: frame.mirrorState)
    let signalState = classifySignalState(
      lighting: lighting, hasFace: true, confidence: raw.confidence)

    let analysis = FrameAnalysis(
      timestamp: frame.timestamp,
      signalState: signalState,
      faceCount: raw.faceCount,
      primary: geometry,
      lighting: lighting
    )
    let framing = framingState(for: geometry, signalState: signalState, timestamp: frame.timestamp)

    return EngineOutput(analysis: analysis, framing: framing)
  }

  /// Consumes `source.frames` and yields one `EngineOutput` per ANALYZED
  /// frame, in order — the streaming convenience over `process(_:)`.
  /// Finishes normally when `source.frames` finishes; finishes by throwing
  /// if `process(_:)` throws for some frame. Does not call `source.start()`
  /// — callers start the source themselves, same as consuming
  /// `source.frames` directly. Cancelling / abandoning the returned stream
  /// cancels the internal frame-forwarding task via `onTermination`.
  ///
  /// - Parameter targetAnalysisHz: §5.2's decimation seam. `nil` (the
  ///   default) analyzes every frame — Setup's behavior (§5.1) and every
  ///   existing caller's (corpus replay, the CLI harness) unchanged
  ///   behavior. When set, an `AnalysisRateDecimator` decides, from each
  ///   frame's own timestamp, whether to call `process(_:)` at all — a
  ///   skipped frame never reaches `backend.analyze(_:)`. This is
  ///   deliberately checked HERE, before `process(_:)`, rather than in
  ///   `PipelineModel`'s consume loop or by analyzing every frame and
  ///   discarding some `EngineOutput`s: §5.2's whole rationale is CPU and
  ///   thermal load over a two-hour Monitor session, and a
  ///   analyze-then-discard version would spend exactly the Vision inference
  ///   cost it exists to avoid while producing an output stream that looks
  ///   identical to the correct one in any test that only inspects what came
  ///   out the other end. See `AnalysisRateDecimator`'s own doc comment for
  ///   why it is time-based rather than "every Nth frame."
  ///
  /// `nonisolated`: building the `AsyncThrowingStream` itself touches no
  /// actor state directly (only the `Task` it spawns does, by `await`ing
  /// `process(_:)`, which hops onto the actor per call), so callers can get
  /// the stream back without an `await` at the call site — matching how
  /// `CaptureSource.frames` itself is a plain, non-`async` property. The
  /// `AnalysisRateDecimator` instance below lives entirely inside that one
  /// spawned `Task`'s local state — never shared, never touched from more
  /// than one place — so its `Sendable` conformance is not load-bearing for
  /// safety here, only for the type to be usable as a value at all.
  public nonisolated func stream(
    from source: some CaptureSource,
    targetAnalysisHz: Double? = nil
  ) -> AsyncThrowingStream<EngineOutput, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var decimator = AnalysisRateDecimator(targetHz: targetAnalysisHz)
        for await frame in source.frames {
          if Task.isCancelled { return }
          guard decimator.shouldAnalyze(at: frame.timestamp) else { continue }
          do {
            let output = try await process(frame)
            continuation.yield(output)
          } catch {
            continuation.finish(throwing: error)
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Resets the §4/§7 positional smoothing/hysteresis state (see the
  /// stored-property doc comment above) AND `lastFrameTimestamp` — but
  /// deliberately NOT the learned gaze baseline (`learnedBaselineYaw`/
  /// `Pitch`/`baselineSeed*`), which is long-term knowledge about the
  /// user's natural pose, not a per-session smoothing artifact. Resetting
  /// `lastFrameTimestamp` only means the next adaptation-eligible frame
  /// after a gap has no cadence reference and therefore blends nothing on
  /// that one frame (`AnalysisEngine+GazeBaseline.swift`) — it re-primes
  /// silently, it does not lose the learned value.
  func resetSmoothingState() {
    smoothedError = nil
    smoothedDistanceError = nil
    inDeadZoneLatched = false
    lastFrameTimestamp = nil
  }

  // MARK: - SignalState (§3.3)

  /// `noSignal` is checked first, regardless of face detection: a
  /// near-uniform frame (lens covered, camera asleep, dead feed) is a
  /// capture-level problem that takes priority over whatever a backend
  /// happened to report for it. In practice a real backend finds no face in
  /// a uniform frame anyway (see `VisionBackendTests.solidGrayFrameHasNoFace`),
  /// but this classification does not rely on that being true for every
  /// possible backend.
  private func classifySignalState(
    lighting: LightingMetrics,
    hasFace: Bool,
    confidence: Float?
  ) -> SignalState {
    if lighting.frameLumaVariance < Float(config.signal.noSignalLumaVarianceThreshold) {
      return .noSignal
    }
    guard hasFace else {
      return .noFace
    }
    if let confidence, confidence < Float(config.signal.lowConfidenceThreshold) {
      return .lowConfidence
    }
    return .ok
  }
}

/// The bundle of per-frame engine output: the spec's `FrameAnalysis` (§3.3)
/// plus `FramingState` (§3.3). The spec defines both types but does not
/// bundle them into a single return shape — `FrameAnalysis` itself carries
/// no `FramingState` field — so `EngineOutput` is `AnalysisEngine`'s own
/// addition, not a spec-defined type, to give `process(_:)`/`stream(from:)`
/// a single return value.
///
/// `framing` is `nil` exactly when `analysis.primary` is `nil`: there is no
/// meaningful positional error, distance error, dead-zone membership, or
/// gaze estimate without a detected face to measure.
public struct EngineOutput: Sendable {
  public let analysis: FrameAnalysis
  public let framing: FramingState?

  public init(analysis: FrameAnalysis, framing: FramingState?) {
    self.analysis = analysis
    self.framing = framing
  }
}
