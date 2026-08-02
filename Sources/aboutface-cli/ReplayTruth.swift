import AboutFaceCore

/// Ground-truth narration for `replay --truth` (2026-08-02 task brief: "I
/// don't actually know what problems there are in the videos I recorded, so
/// I can't tell whether the audio is guiding me effectively" — a blind
/// maintainer's independent oracle for what a recorded clip contains). CLI
/// orchestration (`extension Replay`) lives in `ReplayTruthSelfCheck.swift`,
/// not here — so every function here stays a **pure** mapping from an
/// already-computed `ClipStats` (+ `Config`, for thresholds/sign
/// conventions) to a `String`: no I/O, no dwell/hysteresis judgment of its
/// own (that already happened upstream, in `AnalysisEngine`/
/// `ClipStats.record`). Mirrors `SignalFormatter`'s posture ("pure...
/// transcribing a sign convention... not inventing a new threshold") aimed
/// at a maintainer's ears instead of VoiceOver's §9 value list.
///
/// Deliberately NOT `Lexicon.swift`: `Phrase.init` is `private` (§6.3's
/// closed-vocabulary rule is a *shipping-app* requirement), and this tool
/// needs to say things Lexicon's fixed set never will — percentages,
/// clip-specific detail. The declarative "You are ___." SHAPE borrows
/// `Lexicon.State`'s framing; the phrases are defined locally, per the task
/// brief: "Lexicon is closed and this is CLI tooling, not app speech."
///
/// **Sign-convention hygiene (§3.4):** every direction word is hand-derived
/// from the SAME documented sign conventions the real renderer/router use
/// (`FramingState.error`, `FaceGeometry.yaw/pitch/roll`,
/// `RenderState+Positional.swift`'s beacon polarity) — never re-derived
/// independently. A wrong direction word here would poison the one tool this
/// maintainer has to calibrate the audio by ear — CLAUDE.md's "single worst
/// failure mode of this product." See `ReplayTruthSelfCheck.swift` for
/// scripted worked examples pinning these strings down concretely.
enum ReplayTruth {

  // MARK: - Magnitude bands (horizontal/vertical/distance/pose)

  /// Rough magnitude words for "how far outside nominal," as a ratio to some
  /// axis-appropriate "one dead-zone-width" unit (see each call site).
  /// Boundaries 2x/4x match `CorpusHeuristics.referenceCheck`'s own
  /// "clearly outside the dead zone" precedent (`xBound =
  /// deadZone.horizontal * 2`): `.nominal` <=1x (omitted by default —
  /// "problems only"), `.slightly` 1x-2x, `.clearly` 2x-4x (unremarkable —
  /// the number alone says enough, no word), `.far` beyond 4x.
  enum Magnitude: Equatable {
    case nominal
    case slightly
    case clearly
    case far
  }

  static func magnitude(ratio: Float) -> Magnitude {
    let r = abs(ratio)
    if r <= 1 { return .nominal }
    if r < 2 { return .slightly }
    if r <= 4 { return .clearly }
    return .far
  }

  // MARK: - Entry points

  /// The full spoken+printed ground-truth sentence for one clip. `stats`:
  /// aggregated from a silent replay pass (`Replay.silentClipStats`).
  /// `config`: supplies the thresholds/sign conventions THIS file's wording
  /// uses — not necessarily the `Config` the silent pass ran `AnalysisEngine`
  /// against (that pass uses `Config.defaults`, matching every other
  /// replay/verify-corpus path). `clipLabel`: e.g. "clip 7", or "this clip."
  /// `full`: `--truth-full` — report every axis, not just problems.
  static func summary(stats: ClipStats, config: Config, clipLabel: String, full: Bool) -> String {
    guard stats.frameCount > 0 else {
      return "Ground truth for \(clipLabel): no frames were read from this clip."
    }

    var sentences: [String] = []
    let everHadAFace = !stats.yaws.isEmpty

    if !everHadAFace {
      sentences.append("No face is ever detected.")
    } else {
      let offsets = offsetSummary(stats: stats, config: config, full: full)
      if !offsets.isEmpty { sentences.append(offsets) }
      sentences.append(faceCountClause(stats: stats))
    }

    sentences.append(lightingClause(stats: stats))
    sentences.append(stabilityClause(stats: stats))

    if everHadAFace {
      if let gaze = gazeClause(stats: stats, config: config, full: full) { sentences.append(gaze) }
      if let tilt = tiltClause(stats: stats, config: config, full: full) { sentences.append(tilt) }
    }

    return "Ground truth for \(clipLabel): " + sentences.joined(separator: " ")
  }

  /// The one-line "what you should hear" preview, derived from the SAME
  /// signal `summary(...)` narrates, run through the SAME sign conventions
  /// `RenderState+Positional.swift`'s `positionalSample`/`verticalTimbreMix`
  /// hard-code (hand-transcribed below, not re-derived independently — see
  /// this type's doc comment).
  static func expectedSound(stats: ClipStats, config: Config) -> String {
    guard let meanX = ClipStats.mean(stats.errorXs), let meanY = ClipStats.mean(stats.errorYs)
    else {
      return "Expect: silence — no face is ever detected, so no positional tone plays."
    }

    let deadZone = config.deadZone
    let inDeadZone =
      abs(meanX) <= Float(deadZone.horizontal) && abs(meanY) <= Float(deadZone.vertical)
    guard !inDeadZone else {
      return "Expect: no continuous tone — framing is centered, in the good zone."
    }

    var parts: [String] = []
    if let pan = panDescription(meanX: meanX, config: config) { parts.append(pan) }
    if let pitch = pitchDescription(meanY: meanY, config: config) { parts.append(pitch) }
    if let meanDistance = ClipStats.mean(stats.distanceErrors) {
      if let swell = swellDescription(distanceError: meanDistance, config: config) {
        parts.append(swell)
      }
    }

    guard !parts.isEmpty else {
      return "Expect: a faint, nearly centered tone."
    }
    return "Expect: " + parts.joined(separator: ", ") + "."
  }

  // MARK: - Horizontal / vertical / distance ("You are ___.")

  private static func offsetSummary(stats: ClipStats, config: Config, full: Bool) -> String {
    var clauses: [String] = []

    let horizontal = ClipStats.mean(stats.errorXs).flatMap {
      offsetClause(
        value: $0, deadZone: Float(config.deadZone.horizontal), positiveWord: "right",
        negativeWord: "left", appendTarget: true)
    }
    if let horizontal {
      clauses.append(horizontal)
    } else if full, ClipStats.mean(stats.errorXs) != nil {
      clauses.append("centered horizontally")
    }

    let vertical = ClipStats.mean(stats.errorYs).flatMap {
      offsetClause(
        value: $0, deadZone: Float(config.deadZone.vertical), positiveWord: "above",
        negativeWord: "below", appendTarget: horizontal == nil)
    }
    if let vertical {
      clauses.append(vertical)
    } else if full, ClipStats.mean(stats.errorYs) != nil {
      clauses.append("centered vertically")
    }

    let distance = ClipStats.mean(stats.distanceErrors).flatMap {
      distanceClause(distanceError: $0, config: config)
    }
    if let distance {
      clauses.append(distance)
    } else if full, ClipStats.mean(stats.distanceErrors) != nil {
      clauses.append("at the right distance")
    }

    guard !clauses.isEmpty else { return "" }
    return "You are " + clauses.joined(separator: ", ") + "."
  }

  /// `FramingState.error.x`: "+ = subject is right of target" (§3.3,
  /// egocentric). `value >= 0` therefore reads "right"; negative reads
  /// "left." `deadZone` is `Config.DeadZone.horizontal`/`.vertical`
  /// (whichever axis `value` is), the "one unit" `Magnitude.nominal`
  /// bucketing is relative to.
  private static func offsetClause(
    value: Float, deadZone: Float, positiveWord: String, negativeWord: String, appendTarget: Bool
  ) -> String? {
    guard deadZone > 0 else { return nil }
    let mag = magnitude(ratio: abs(value) / deadZone)
    guard mag != .nominal else { return nil }

    let direction = value >= 0 ? positiveWord : negativeWord
    let percent = Int((abs(value) * 100).rounded())
    let targetSuffix = appendTarget ? " of target" : ""
    let base = "\(percent) percent \(direction)\(targetSuffix)"
    switch mag {
    case .nominal: return nil
    case .slightly: return base + " — slightly off"
    case .clearly: return base
    case .far: return base + " — far off"
    }
  }

  /// `FramingState.distanceError`: "+ = too close" (§3.3). `unit` is
  /// `distanceDeadZoneEquivalent(config:)` — see its doc comment for why
  /// distance borrows the horizontal axis's dead-zone-to-tone-range ratio
  /// rather than using a bare, undocumented constant (`Config.DeadZone` has
  /// no distance field; only horizontal/vertical gate `FramingState.inDeadZone`
  /// per `AnalysisEngine+Framing.swift`'s `updatedDeadZoneLatch`).
  private static func distanceClause(distanceError: Float, config: Config) -> String? {
    let unit = distanceDeadZoneEquivalent(config: config)
    guard unit > 0 else { return nil }
    let mag = magnitude(ratio: abs(distanceError) / unit)
    guard mag != .nominal else { return nil }

    let direction = distanceError > 0 ? "close" : "far"
    switch mag {
    case .nominal: return nil
    case .slightly: return "slightly too \(direction)"
    case .clearly: return "too \(direction)"
    case .far: return "far too \(direction)"
    }
  }

  /// Distance has no `Config.DeadZone` field (only horizontal/vertical gate
  /// `inDeadZone`), so there is no ready-made "one unit" the way
  /// `deadZone.horizontal` is for the horizontal axis. Rather than pick an
  /// independent magic constant, this borrows the RATIO between the
  /// horizontal axis's dead zone and its tone-mapping full-scale range
  /// (`deadZone.horizontal / audio.positional.errorRange`) and applies that
  /// same relative tightness to distance's own full-scale range
  /// (`audio.distance.errorRange`, documented as the magnitude that maps to
  /// `pulseRateMaxHz` — the same ROLE `positional.errorRange` plays for
  /// horizontal/vertical). At `Config.defaults`: `(0.06/0.35)*0.3 ≈ 0.0514`.
  private static func distanceDeadZoneEquivalent(config: Config) -> Float {
    let positionalRange = Float(config.audio.positional.errorRange)
    guard positionalRange > 0 else { return 0 }
    let horizontalTightness = Float(config.deadZone.horizontal) / positionalRange
    return horizontalTightness * Float(config.audio.distance.errorRange)
  }

  // MARK: - Face count / lighting / stability (always reported — these are
  // descriptive facts about the clip, not "problems relative to a target,"
  // so they are never omitted even under the default "problems only" mode;
  // `full` has no effect on them.)

  private static func faceCountClause(stats: ClipStats) -> String {
    guard stats.multiFaceFrameCount > 0 else { return "One face." }
    // Same 50% sustained-vs-transient split `CorpusHeuristics.multiFaceCheck`
    // already uses for its `multi-face-sustained`/`multi-face-transient`
    // conditions.
    let fraction = Double(stats.multiFaceFrameCount) / Double(stats.frameCount)
    return fraction > 0.5
      ? "Two or more faces for most of the clip." : "A second face appears briefly."
  }

  /// Thresholds mirror `CorpusHeuristics.dimCheck`/`backlitCheck`'s own
  /// (mean face luma < 0.25 / mean backlight delta > 0.05) — verify-corpus's
  /// already-tuned triage bounds for exactly these two conditions, reused
  /// here rather than picked independently.
  private static func lightingClause(stats: ClipStats) -> String {
    guard let faceLuma = ClipStats.mean(stats.faceLumas) else { return "Well lit." }
    let backlightDelta = ClipStats.mean(stats.backlightDeltas) ?? 0
    let dim = faceLuma < 0.25
    let backlit = backlightDelta > 0.05
    switch (dim, backlit) {
    case (true, true): return "Dim, and backlit."
    case (true, false): return "Dim."
    case (false, true): return "Backlit."
    case (false, false): return "Well lit."
    }
  }

  /// Signal-state shape over the clip: prioritizes the two named §14 corpus
  /// shapes `ClipStats` already has helpers for (lens-covered mid-clip, face
  /// leaves-and-returns — reusing `ClipStats.hasMidClipNoSignalStreak`/
  /// `hasOkNoFaceOkPattern` verbatim, the same logic
  /// `CorpusHeuristics.lensCoveredCheck`/`leaveReturnCheck` use), then falls
  /// back to a plain transition count (a high count is the "hysteresis
  /// chattering" signature CLAUDE.md's dwell/hysteresis rule exists to
  /// prevent).
  private static func stabilityClause(stats: ClipStats) -> String {
    guard stats.frameCount > 1 else { return "Steady throughout." }

    let (noSignalFound, noSignalLength) = ClipStats.hasMidClipNoSignalStreak(stats.stateSequence)
    if noSignalFound {
      let pct = Int((Double(noSignalLength) / Double(stats.frameCount) * 100).rounded())
      return "The picture drops out for about \(pct) percent of the clip, then returns."
    }

    let minNoFaceRun = max(1, stats.frameCount / 20)
    if ClipStats.hasOkNoFaceOkPattern(stats.stateSequence, minNoFaceRun: minNoFaceRun) {
      return "The face disappears mid-clip and returns."
    }

    let transitions = ClipStats.transitionCount(stats.stateSequence)
    switch transitions {
    case 0, 1: return "Steady throughout."
    case 2...4: return "A brief flicker (\(transitions) state changes)."
    default: return "Chatters between states (\(transitions) changes) — check hysteresis."
    }
  }

  // MARK: - Gaze / pose (only when dominant — always omitted-if-nominal,
  // even under --truth-full, whose "everything" only covers the offset/
  // distance axes; see each function for its own --truth-full behavior).

  /// Mirrors `AnalysisEngine+Framing.swift`'s `gazeOnCamera` (deviation from
  /// the captured neutral pose) and `CorpusHeuristics.gazeOffCheck`'s
  /// dominant-axis pick (yaw vs. pitch, whichever deviates more).
  /// `FaceGeometry.yaw`: "+ = turned to their right." `.pitch`: "+ = chin up."
  private static func gazeClause(stats: ClipStats, config: Config, full: Bool) -> String? {
    guard let meanYaw = ClipStats.mean(stats.yaws), let meanPitch = ClipStats.mean(stats.pitches),
      stats.gazeSampledCount > 0
    else { return nil }

    let gazeOffFraction =
      Double(stats.gazeSampledCount - stats.gazeOnFrameCount) / Double(stats.gazeSampledCount)
    guard gazeOffFraction > 0.5 else {
      return full ? "Looking at the camera." : nil
    }

    let target = config.targetFraming
    let yawDeviation = meanYaw - Float(target.neutralYawDegrees)
    let pitchDeviation = meanPitch - Float(target.neutralPitchDegrees)
    let yawTolerance = Float(config.gaze.maxYawDegrees)
    let pitchTolerance = Float(config.gaze.maxPitchDegrees)
    let yawRatio = yawTolerance > 0 ? abs(yawDeviation) / yawTolerance : 0
    let pitchRatio = pitchTolerance > 0 ? abs(pitchDeviation) / pitchTolerance : 0

    if yawRatio >= pitchRatio {
      let direction = yawDeviation >= 0 ? "your own right" : "your own left"
      return "Not looking at the camera — turned toward \(direction)."
    }
    let direction = pitchDeviation >= 0 ? "up" : "down"
    return "Not looking at the camera — looking \(direction)."
  }

  /// `FaceGeometry.roll`: "+ = tilted to their right." `Config` has no
  /// dedicated roll tolerance, so this reuses `gaze.maxYawDegrees` as the
  /// closest analog (both default to 15 degrees, matching
  /// `CorpusHeuristics.rollCheck`'s own figure) rather than an independent
  /// constant.
  private static func tiltClause(stats: ClipStats, config: Config, full: Bool) -> String? {
    guard let meanRoll = ClipStats.mean(stats.rolls) else { return nil }
    let tolerance = Float(config.gaze.maxYawDegrees)
    guard tolerance > 0 else { return nil }

    let rollDeviation = meanRoll - Float(config.targetFraming.neutralRollDegrees)
    guard magnitude(ratio: abs(rollDeviation) / tolerance) != .nominal else {
      return full ? "Head level." : nil
    }
    let direction = rollDeviation >= 0 ? "your right" : "your left"
    return "Head tilted toward \(direction)."
  }

  // MARK: - Expected sound (beacon principle, hand-derived from
  // `RenderState+Positional.swift`'s `positionalSample`/`verticalTimbreMix`,
  // transcribed below). `signMultiplier = beaconPolarity ? -1 : 1` (default
  // `true`); pan/pitch encode the NEGATED error — the beacon sits at the
  // TARGET, so "toward center" also moves the subject into position. This
  // is the exact negation `FeedbackRouter+Announcements.swift` keys its
  // Instruction direction words off of (`error.x > 0 ? .left : .right`,
  // `error.y > 0 ? .down : .up`) — the tone points the same way the spoken
  // correction would, by construction: the cross-check this derivation
  // leans on.

  /// `AudioSynthesis.equalPowerPan`: "-1 full left... +1 full right."
  /// `panRaw = signMultiplier * errorX`. `errorX > 0` (right of target) =>
  /// `panRaw < 0` (default polarity) => tone from the LEFT (corrects it) —
  /// exactly `FeedbackRouter+Announcements.swift`'s `error.x > 0 ? .left :
  /// .right`.
  private static func panDescription(meanX: Float, config: Config) -> String? {
    guard abs(meanX) > Float(config.deadZone.horizontal) else { return nil }
    let signMultiplier: Float = config.audio.positional.beaconPolarity ? -1 : 1
    let panRaw = signMultiplier * meanX
    let direction = panRaw > 0 ? "right" : "left"
    return "tone from your \(direction)"
  }

  /// `AudioSynthesis.exponentialFrequency`: positive `normalized` maps
  /// toward `maxHz` (HIGH). `pitchRaw = signMultiplier * errorY`. `errorY <
  /// 0` (below target) => `pitchRaw > 0` (default polarity) => HIGH pitch —
  /// target is above, matching `FeedbackRouter+Announcements.swift`'s
  /// `error.y < 0` corrects with "Up."
  private static func pitchDescription(meanY: Float, config: Config) -> String? {
    guard abs(meanY) > Float(config.deadZone.vertical) else { return nil }
    let signMultiplier: Float = config.audio.positional.beaconPolarity ? -1 : 1
    let pitchRaw = signMultiplier * meanY
    let direction = pitchRaw > 0 ? "high" : "low"
    return "pitched \(direction)"
  }

  /// §6.2: "Distance maps to pulse rate... never volume" — magnitude only,
  /// no directional cue (too-close and too-far pulse identically; see
  /// `RenderState+Positional.swift`'s `distanceGate`, which reads
  /// `abs(currentTarget.distanceError)`). Uses the same
  /// `distanceDeadZoneEquivalent` unit `distanceClause` does, for the same
  /// reason (no `Config.DeadZone` field for distance).
  private static func swellDescription(distanceError: Float, config: Config) -> String? {
    let unit = distanceDeadZoneEquivalent(config: config)
    guard unit > 0 else { return nil }
    switch magnitude(ratio: abs(distanceError) / unit) {
    case .nominal: return nil
    case .slightly: return "gentle swell"
    case .clearly: return "steady pulse"
    case .far: return "fast, urgent pulse"
    }
  }
}
