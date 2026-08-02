import CoreGraphics

/// `FramingState` derivation (§3.3, §4): error vs. `Config.targetFraming`,
/// EMA smoothing, hysteresis-latched `inDeadZone`, and `gazeOnCamera`. Split
/// out of `AnalysisEngine.swift` purely to keep each file a manageable size
/// (the same reasoning `LightingAnalyzer`'s file split uses); everything
/// here is still `AnalysisEngine`'s own implementation, not a separate
/// public surface. See `AnalysisEngine.swift` for the type's documented
/// behavior, scope, and its `smoothedError`/`smoothedDistanceError`/
/// `inDeadZoneLatched` stored properties (declared there; read and written
/// only from this file).
extension AnalysisEngine {

  func framingState(for geometry: FaceGeometry) -> FramingState {
    let target = config.targetFraming

    // Horizontal: `FaceGeometry.eyeMidpoint.x` is already egocentric
    // (§3.4), and `Config.TargetFraming.eyeMidpointX` is documented in the
    // same egocentric-X convention (0 = subject's own far left edge of
    // frame), so this is a direct subtraction.
    let rawErrorX = Float(geometry.eyeMidpoint.x - CGFloat(target.eyeMidpointX))
    let rawErrorY = Self.verticalError(eyeMidpointY: geometry.eyeMidpoint.y, targetFraming: target)

    let rawDistanceError =
      geometry.interocularDistance > 0
      ? Float(geometry.interocularDistance) - Float(target.interocularWidth)
      : nil

    let window = config.smoothingWindow
    let newSmoothedError = SIMD2<Float>(
      Self.ema(previous: smoothedError?.x, sample: rawErrorX, window: window),
      Self.ema(previous: smoothedError?.y, sample: rawErrorY, window: window)
    )
    smoothedError = newSmoothedError

    let newSmoothedDistanceError: Float
    if let rawDistanceError {
      newSmoothedDistanceError = Self.ema(
        previous: smoothedDistanceError, sample: rawDistanceError, window: window)
    } else {
      // No usable interocular measurement this frame (landmarks
      // unavailable — `faceGeometry(from:mirror:)` already reported 0 for
      // exactly this reason). Carry the previous smoothed value forward
      // rather than feeding a fabricated "very far" reading computed
      // against 0; with no prior value either, 0 ("no distance error
      // known yet") is the least-wrong default.
      newSmoothedDistanceError = smoothedDistanceError ?? 0
    }
    smoothedDistanceError = newSmoothedDistanceError

    let inDeadZone = updatedDeadZoneLatch(
      error: newSmoothedError, distanceError: newSmoothedDistanceError)

    // Deviation from the captured neutral pose (§4 extension), not
    // absolute camera-ray angles: a laptop camera views the face from off
    // the natural eyeline, so absolute pose is offset for every user (a
    // natural position read ~+30° chin-up in field testing). With no
    // captured baseline (defaults of 0) this degrades to the absolute
    // behavior.
    let gaze = config.gaze
    let gazeOnCamera =
      abs(geometry.yaw - Float(target.neutralYawDegrees)) <= Float(gaze.maxYawDegrees)
      && abs(geometry.pitch - Float(target.neutralPitchDegrees)) <= Float(gaze.maxPitchDegrees)

    return FramingState(
      error: newSmoothedError,
      distanceError: newSmoothedDistanceError,
      inDeadZone: inDeadZone,
      gazeOnCamera: gazeOnCamera
    )
  }

  /// `FaceGeometry.eyeMidpoint.y` is passed through unchanged by
  /// `EgocentricTransform` from `RawFaceObservation`'s contracted
  /// coordinate space — normalized, BOTTOM-LEFT origin (see
  /// `VisionBackend`'s coordinate-contract doc comment: every backend MUST
  /// normalize into that space). So y = 0 is the bottom of the frame,
  /// y = 1 is the top.
  ///
  /// `Config.TargetFraming.eyeMidpointY` (§4), by contrast, is documented
  /// as "fraction of frame height FROM TOP" — a top-left-origin
  /// convention (0.38 means "38% of the way down from the top edge," i.e.
  /// the upper third). These two numbers are in different coordinate
  /// systems and are NOT directly comparable as-is;
  /// `EgocentricTransform`'s own doc comment flags this exact gap
  /// ("backend-native Y-origin conventions... are a separate, per-backend
  /// normalization concern... out of scope for this pure transform") and
  /// leaves it to this call site.
  ///
  /// Converting the target into the same bottom-left-origin convention
  /// (`1 - eyeMidpointY`) before subtracting is what makes the sign come
  /// out right: a subject whose eyes sit higher up in frame has a LARGER
  /// bottom-left-origin y, and per §3.3 "+y = subject is above target,"
  /// the error must be positive in that case.
  private static func verticalError(
    eyeMidpointY: CGFloat,
    targetFraming: Config.TargetFraming
  ) -> Float {
    let targetYBottomLeftOrigin = 1 - Float(targetFraming.eyeMidpointY)
    return Float(eyeMidpointY) - targetYBottomLeftOrigin
  }

  /// Exponential moving average step. `alpha = 2 / (window + 1)` is the
  /// standard N-period EMA weighting — chosen because it gives a
  /// closed-form, hand-computable step response, which
  /// `AnalysisEngineTests` relies on to assert exact expected values for a
  /// step input. Seeded with the first raw sample (rather than ramping up
  /// from 0) so a freshly (re)acquired face does not read as transiently
  /// near-target before smoothing catches up — `previous == nil` only ever
  /// happens on the first frame after construction or after
  /// `resetSmoothingState()` (i.e. right after a face was lost), both
  /// cases where there is no meaningful prior trend to blend from.
  private static func ema(previous: Float?, sample: Float, window: Int) -> Float {
    guard let previous else { return sample }
    let windowCount = max(1, window)
    let alpha = 2 / (Float(windowCount) + 1)
    return alpha * sample + (1 - alpha) * previous
  }

  /// Hysteresis-latched dead-zone membership (§4, §7.1's "hysteresis on
  /// every threshold"): enters when ALL THREE axes — horizontal, vertical,
  /// AND distance — are within `Config.DeadZone`'s entry thresholds; exits
  /// when ANY of the three exceeds its entry threshold scaled by
  /// `Config.hysteresisExitRatio`. Stateful and monotonic between
  /// crossings — an error sequence that oscillates between the entry and
  /// exit thresholds on any single axis cannot chatter, because nothing
  /// strictly between those two thresholds on that axis can flip the latch
  /// in either direction, and the other two axes' state is untouched by it.
  ///
  /// **Distance joined this latch 2026-08-02** (§4 extension, first live
  /// convergence-trial finding): distance used to be entirely outside it —
  /// only x/y gated `inDeadZone` — so a subject who centered laterally went
  /// silent (the positional tone, and with it the ONLY distance cue §6.2
  /// has: tremolo/pulse-rate on that same tone) even when distance was still
  /// far off target. Every downstream consumer of `FramingState.inDeadZone`
  /// (the router's good-zone/`enteredGoodZone`/heartbeat/framingError/
  /// gazeOff gates, gaze-trim activation, `RenderState.mixedSample`'s
  /// tone-stop gate) inherits this automatically and gets strictly stricter:
  /// the tone (and its distance tremolo) now keeps playing until distance is
  /// ALSO within threshold, which is the whole point of this fix — see
  /// `Config.DeadZone.distance`'s doc comment.
  ///
  /// Operates on the SMOOTHED error/distance-error (`newSmoothedError`/
  /// `newSmoothedDistanceError`, computed just above in `framingState(for:)`
  /// ), not the raw per-frame values: pairing smoothing with hysteresis —
  /// both introduced together in §4 — further damps noise-driven flicker
  /// beyond what the hysteresis band alone would. This does not conflict
  /// with §4's "smoothing... never [applied] to state transitions": that
  /// clause is about dwell/announcement timing (§7.1), a downstream,
  /// explicitly out-of-scope concern here, not about which numeric signal a
  /// spatial hysteresis comparison reads.
  private func updatedDeadZoneLatch(error: SIMD2<Float>, distanceError: Float) -> Bool {
    let deadZone = config.deadZone
    let ratio = Float(config.hysteresisExitRatio)
    let entryX = Float(deadZone.horizontal)
    let entryY = Float(deadZone.vertical)
    let entryDistance = Float(deadZone.distance)

    if inDeadZoneLatched {
      let exitX = entryX * ratio
      let exitY = entryY * ratio
      let exitDistance = entryDistance * ratio
      if abs(error.x) > exitX || abs(error.y) > exitY || abs(distanceError) > exitDistance {
        inDeadZoneLatched = false
      }
    } else if abs(error.x) <= entryX, abs(error.y) <= entryY, abs(distanceError) <= entryDistance {
      inDeadZoneLatched = true
    }
    return inDeadZoneLatched
  }
}
