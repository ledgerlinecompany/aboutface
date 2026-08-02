/// **Gaze trim (tuning round 5, maintainer-designed audition prototype —
/// `Config.AudioGazeTrim`, default OFF).** Coarse-to-fine SEQUENTIAL
/// feedback: the positional beacon (`updateContinuousSonification`'s
/// out-of-dead-zone branch) owns the continuous channel while the subject
/// is out of place; once placed, this MAY take over the channel instead of
/// pure silence-and-heartbeat (§6.1), giving a continuous fine-centering
/// cue for head pose. Split into its own file — same reasoning as
/// `FeedbackRouter+Condition.swift`/`+Announcements.swift` — because this
/// is a genuinely separate, flag-gated feature layered on top of the
/// existing good-zone handling, not a modification of it.
extension FeedbackRouter {
  /// Returns a trim-mode `SonificationTarget` when every activation
  /// condition holds, or `nil` when any one of them doesn't — the caller
  /// (`updateContinuousSonification`) falls back to the legacy
  /// stop-updates silence on `nil`, so this method is the ENTIRE gate;
  /// nothing else needs to duplicate its conditions.
  ///
  /// Conditions, in the order checked:
  ///
  /// 1. **Setup mode only** (§5.1) — Monitor's earcon-only, rate-limited
  ///    posture (§5.2) has no continuous-tone precedent to extend, and this
  ///    is explicitly an audition prototype for the Setup convergence
  ///    loop.
  /// 2. **`Config.AudioGazeTrim.enabled`** (default `false`) — the whole
  ///    feature's kill switch; the maintainer decides its fate by ear.
  /// 3. **`confirmedState == .goodZone`** — the §7.2 N-FRAME-CONFIRMED
  ///    state, not the raw per-frame `framing.inDeadZone`/`gazeOnCamera`
  ///    flags the beacon branch itself reads. Deliberately more
  ///    conservative than the beacon's real-time-first posture: trim is a
  ///    bonus layered on top of an already-settled placement, not the
  ///    primary correction loop §1 keeps fast, so waiting the extra few
  ///    frames for confirmation costs nothing perceptible and avoids
  ///    flickering into trim mode on a placement that hasn't actually
  ///    stuck yet.
  /// 4. **`output.analysis.primary` present** — needed for raw yaw/pitch;
  ///    defensively `nil`-safe even though `framing != nil` (guaranteed by
  ///    the caller) implies `analysis.primary != nil` per
  ///    `AnalysisEngine.process(_:)`'s documented invariant.
  ///
  /// ## Smoothing and dead-band placement
  ///
  /// Deviations are EMA-smoothed AND dead-banded here, in the router — not
  /// in the renderer — for the same reason `AnalysisEngine.framingState`
  /// smooths `error` before anything downstream sees it: raw Vision pose
  /// jitters ±2-3° frame to frame (field-measured, same note
  /// `Config.TargetFraming.neutralYawDegrees`'s doc comment cites), and the
  /// renderer's job should be turning an already-steady signal into sound,
  /// not re-deriving steadiness itself. Order: EMA first (`Self.ema`,
  /// identical math to `AnalysisEngine.ema`, reseeded from the first raw
  /// sample whenever `smoothedYawDeviationDegrees`/
  /// `smoothedPitchDeviationDegrees` is `nil`), THEN dead-band (snap to
  /// exactly `0` below `Config.AudioGazeTrim.deadBandDegrees`) — dead-band
  /// gates the smoothed value, not the raw one, so it is the LAST word on
  /// "is this genuinely near neutral," immune to a single noisy raw sample
  /// slipping through un-smoothed.
  func gazeTrimTarget(output: EngineOutput, framing: FramingState) -> SonificationTarget? {
    guard mode == .setup else { return nil }
    guard config.audio.gazeTrim.enabled else { return nil }
    guard case .goodZone = confirmedState else { return nil }
    guard let geometry = output.analysis.primary else { return nil }

    let cfg = config.audio.gazeTrim
    let target = config.targetFraming
    let rawYawDeviation = geometry.yaw - Float(target.neutralYawDegrees)
    let rawPitchDeviation = geometry.pitch - Float(target.neutralPitchDegrees)

    let window = cfg.smoothingWindow
    let smoothedYaw = Self.ema(
      previous: smoothedYawDeviationDegrees, sample: rawYawDeviation, window: window)
    let smoothedPitch = Self.ema(
      previous: smoothedPitchDeviationDegrees, sample: rawPitchDeviation, window: window)
    smoothedYawDeviationDegrees = smoothedYaw
    smoothedPitchDeviationDegrees = smoothedPitch

    let deadBand = Float(cfg.deadBandDegrees)
    let yawDeviation = abs(smoothedYaw) < deadBand ? 0 : smoothedYaw
    let pitchDeviation = abs(smoothedPitch) < deadBand ? 0 : smoothedPitch

    return SonificationTarget(
      errorX: framing.error.x,
      errorY: framing.error.y,
      distanceError: framing.distanceError,
      inDeadZone: framing.inDeadZone,
      gazeTrimActive: true,
      yawDeviationDegrees: yawDeviation,
      pitchDeviationDegrees: pitchDeviation
    )
  }

  /// Same exponential-moving-average shape as
  /// `AnalysisEngine.ema(previous:sample:window:)` — not shared code (that
  /// one is `private` to a different type in a different file — see
  /// `AnalysisEngine+Framing.swift`), but identical math: `alpha = 2 /
  /// (window + 1)`, seeded with the first raw sample rather than ramping
  /// up from `0` (so a freshly confirmed good zone does not read as
  /// transiently at-neutral before smoothing catches up).
  private static func ema(previous: Float?, sample: Float, window: Int) -> Float {
    guard let previous else { return sample }
    let windowCount = max(1, window)
    let alpha = 2 / (Float(windowCount) + 1)
    return alpha * sample + (1 - alpha) * previous
  }
}
