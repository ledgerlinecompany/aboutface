import CoreMedia

/// Capture-free gaze baseline learning (§13 Phase 5 hard MUST: "Config.default
/// MUST be genuinely usable with zero calibration"; maintainer, 2026-08-02:
/// "blind users will be hesitant to capture positioning they don't know is
/// right. Can we have a default that also works?").
///
/// `AnalysisEngine+Framing.swift`'s `gazeOnCamera` used to compare the raw
/// pose against a STATIC `Config.TargetFraming.neutral*Degrees` — either an
/// explicit capture, or (default 0) absolute camera-ray angles, which read a
/// natural head position as ~30° chin-up on a laptop with a tilted-back
/// screen (see `AnalysisEngineGazeBaselineTests`'s doc comment). Requiring
/// "capture current position as target" (§4 extension) before gaze is
/// meaningful is exactly the zero-calibration MUST's failure mode, and it is
/// worse than merely inconvenient for a blind user: they have no way to
/// confirm the capture actually happened while looking at the right spot.
///
/// This file replaces that static comparison with a WORKING baseline —
/// `learnedBaselineYaw`/`Pitch`, declared on `AnalysisEngine` — that is a
/// slow exponential moving average over frames the subject spends centered.
/// The design, in the order a frame hits it:
///
/// 1. **Seed.** If `Config.TargetFraming.neutralYawDegrees`/
///    `neutralPitchDegrees` are nonzero (an explicit capture happened), the
///    working baseline seeds from them immediately — `seedBaselineFromCaptureIfNeeded(previous:new:)`,
///    called from `init` and `updateConfig(_:)`. Otherwise it seeds lazily
///    from the first eligible in-zone frame (`adapt(sample:eligible:...)`
///    below) — the rationale being your natural pose is the pose you hold
///    most while placed, so the first "settled" observation is as good a
///    starting point as any.
/// 2. **Adapt.** Every SUBSEQUENT eligible frame blends its (yaw, pitch)
///    into the working baseline with a per-frame alpha derived from
///    `Config.Gaze.baselineAdaptationSeconds` and the observed inter-frame
///    timestamp delta (not `Config.smoothingWindow`'s frame-count window —
///    frame rate is not constant across backends/thermal states/corpus
///    replay, and this knob describes wall-clock dwelling behavior).
/// 3. **Clamp.** The working baseline may not wander more than
///    `Config.Gaze.baselineClampDegrees` from its seed — see `clamped(_:seed:range:)`.
/// 4. **Compare.** `gazeOnCamera` (`AnalysisEngine+Framing.swift`) compares
///    the CURRENT frame's pose against the baseline as it stood BEFORE this
///    frame's own adaptation — i.e. adaptation lags comparison by one frame,
///    same as any online-learning gate reading its own state before updating
///    it. `effectiveBaselineYaw(target:)`/`effectiveBaselinePitch(target:)`
///    fall back to `target.neutral*Degrees` (0 if never captured) when
///    unseeded, so the very first frames of a session — before there has
///    been time to seed from an in-zone frame — degrade to exactly the old
///    absolute behavior, never to "always off camera."
///
/// `Config.Gaze.baselineLearningEnabled == false` disables all of the above:
/// `effectiveBaselineYaw`/`Pitch` return `target.neutral*Degrees` unconditionally
/// and `adapt(sample:eligible:...)` is never called, reproducing the prior
/// static behavior bit-for-bit — the pinned `AnalysisEngineGazeBaselineTests`
/// assert exactly this.
extension AnalysisEngine {

  /// One frame's learned-baseline query surface for the §9 debug panel
  /// (not wired into `App/` this round — see the task brief). `nil` fields
  /// mean "not yet seeded": no capture, and no eligible in-zone frame has
  /// been observed yet.
  public struct GazeBaseline: Sendable, Equatable {
    public let yawDegrees: Float?
    public let pitchDegrees: Float?

    public init(yawDegrees: Float?, pitchDegrees: Float?) {
      self.yawDegrees = yawDegrees
      self.pitchDegrees = pitchDegrees
    }
  }

  /// Snapshot of the current working baseline. An actor method (not a field
  /// on `EngineOutput`) — the lighter touch: every per-frame consumer of
  /// `EngineOutput` (corpus replay, `FeedbackRouter`, tests) is unaffected,
  /// and the debug panel can poll this on its own cadence rather than every
  /// caller having to thread a new field through.
  public func learnedGazeBaseline() -> GazeBaseline {
    GazeBaseline(yawDegrees: learnedBaselineYaw, pitchDegrees: learnedBaselinePitch)
  }

  /// The pose `gazeOnCamera` measures deviation FROM, this frame:
  /// the learned baseline once seeded, else `target.neutral*Degrees`
  /// (0 = old absolute behavior) — or, when baseline learning is disabled,
  /// `target.neutral*Degrees` unconditionally, matching the pre-Phase-5
  /// static comparison exactly.
  func effectiveBaselineYaw(target: Config.TargetFraming) -> Float {
    guard config.gaze.baselineLearningEnabled else { return Float(target.neutralYawDegrees) }
    return learnedBaselineYaw ?? Float(target.neutralYawDegrees)
  }

  /// See `effectiveBaselineYaw(target:)`.
  func effectiveBaselinePitch(target: Config.TargetFraming) -> Float {
    guard config.gaze.baselineLearningEnabled else { return Float(target.neutralPitchDegrees) }
    return learnedBaselinePitch ?? Float(target.neutralPitchDegrees)
  }

  /// Computes the (yaw, pitch) to (re)seed the learned baseline with, from
  /// `new.targetFraming.neutral*Degrees` — exactly when they are nonzero
  /// (an explicit capture, per `TargetFraming`'s own doc comment: "Defaults
  /// of 0 mean no baseline captured yet") AND they differ from `previous`'s
  /// value. `previous == nil` (the `init` call site) always counts as
  /// "differs," so a freshly-constructed engine whose starting `Config`
  /// already has a captured neutral (e.g. loaded from `ConfigStore`) seeds
  /// immediately rather than waiting for the first in-zone frame. Returns
  /// `nil` when no (re)seed should happen — in particular, an
  /// `updateConfig` call whose captured neutrals are unchanged (any other
  /// slider) must leave the working baseline exactly as adaptation left it.
  ///
  /// `static`/non-isolated deliberately, not an instance method: actor
  /// initializers cannot call other isolated instance methods synchronously
  /// (SE-0327) — `AnalysisEngine.init` needs this same seeding logic before
  /// it can make any isolated call, so both `init` and `updateConfig(_:)`
  /// call this pure function and assign the returned values to the stored
  /// properties directly.
  static func captureSeed(previous: Config?, new: Config) -> (yaw: Float, pitch: Float)? {
    let newYaw = new.targetFraming.neutralYawDegrees
    let newPitch = new.targetFraming.neutralPitchDegrees
    guard newYaw != 0 || newPitch != 0 else { return nil }
    // swift-format requires the brace on its own line after a multiline
    // condition; swiftlint's opening_brace rule disagrees. Format wins —
    // same conflict `ConfigStore.swift` documents at its own two call sites.
    // swiftlint:disable opening_brace
    if let previous,
      previous.targetFraming.neutralYawDegrees == newYaw,
      previous.targetFraming.neutralPitchDegrees == newPitch
    {
      // swiftlint:enable opening_brace
      return nil
    }
    return (Float(newYaw), Float(newPitch))
  }

  /// Called once per geometry-bearing frame from `framingState(for:signalState:timestamp:)`,
  /// AFTER that frame's `gazeOnCamera` has already been computed against the
  /// pre-adaptation baseline (see this file's top doc comment, point 4) —
  /// so this frame's own pose never leaks into its own gaze judgment, only
  /// into the NEXT frame's.
  ///
  /// `eligible` is the full §13 Phase 5 gate, computed by the caller:
  /// `signalState == .ok`, framing present (implied — this is only called
  /// with a real `FaceGeometry`), `inDeadZone == true`, and confidence at or
  /// above `Config.Signal.lowConfidenceThreshold`. A pose read while looking
  /// away, poorly lit, or barely detected must never count toward "this is
  /// what neutral looks like."
  func adaptLearnedBaseline(yaw: Float, pitch: Float, eligible: Bool, timestamp: CMTime) {
    defer { lastFrameTimestamp = timestamp }
    guard config.gaze.baselineLearningEnabled, eligible else { return }

    guard let currentYaw = learnedBaselineYaw, let currentPitch = learnedBaselinePitch else {
      // Never captured, never seeded — this IS the first eligible in-zone
      // frame (design point 1's "otherwise" branch). Seed and stop: there
      // is no prior value to blend with, same reasoning as
      // `AnalysisEngine+Framing.swift`'s `ema(previous:sample:window:)`
      // seeding on `previous == nil`.
      learnedBaselineYaw = yaw
      learnedBaselinePitch = pitch
      baselineSeedYaw = yaw
      baselineSeedPitch = pitch
      return
    }

    guard let previousTimestamp = lastFrameTimestamp else {
      // Seeded (by capture, or by a prior eligible frame whose own
      // `lastFrameTimestamp` update got wiped by an intervening face-loss
      // gap — `resetSmoothingState()`), but no cadence reference to size
      // this frame's alpha from yet. `defer` above still records THIS
      // frame's timestamp, so the next eligible frame has one.
      return
    }

    let deltaSeconds = max(0, CMTimeGetSeconds(timestamp) - CMTimeGetSeconds(previousTimestamp))
    let tau = max(config.gaze.baselineAdaptationSeconds, 0.001)
    let alpha = Float(min(1, deltaSeconds / tau))
    guard alpha > 0 else { return }

    let blendedYaw = alpha * yaw + (1 - alpha) * currentYaw
    let blendedPitch = alpha * pitch + (1 - alpha) * currentPitch

    let clampRange = Float(config.gaze.baselineClampDegrees)
    learnedBaselineYaw = Self.clamped(
      blendedYaw, seed: baselineSeedYaw ?? blendedYaw, range: clampRange)
    learnedBaselinePitch = Self.clamped(
      blendedPitch, seed: baselineSeedPitch ?? blendedPitch, range: clampRange)
  }

  /// Design point 3: the learned baseline may not wander more than `range`
  /// degrees from its seed, independent of how slowly `adapt` would
  /// otherwise get it there — a sustained habit of glancing away must not
  /// eventually redefine "neutral" as "off camera."
  private static func clamped(_ value: Float, seed: Float, range: Float) -> Float {
    min(max(value, seed - range), seed + range)
  }
}
