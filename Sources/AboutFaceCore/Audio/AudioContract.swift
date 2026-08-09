/// Shared contract between `AudioRenderer` (this file's types are consumed
/// by it) and `FeedbackRouter` (built concurrently by another agent against
/// this same contract, per the Phase 3 task split). Types below are
/// reproduced verbatim from that contract — do not reshape without updating
/// both sides.

/// Continuous positional signal, updated per analysis frame (§6.2).
public struct SonificationTarget: Sendable, Equatable {
  /// Egocentric, + = subject right of target.
  public var errorX: Float
  /// + = above target.
  public var errorY: Float
  /// + = too close.
  public var distanceError: Float
  public var inDeadZone: Bool

  /// **Gaze trim (tuning round 5, maintainer-designed audition prototype —
  /// see `Config.AudioGazeTrim`, default OFF).** `true` marks this as a
  /// TRIM-mode reading rather than the ordinary positional beacon: a
  /// Setup-mode-only, good-zone-only fine-centering cue for head pose that
  /// may take over the continuous channel in place of pure
  /// silence-and-heartbeat (§6.1). `yawDeviationDegrees`/
  /// `pitchDeviationDegrees` are only meaningful when this is `true`; the
  /// beacon fields above (`errorX`/`errorY`/`distanceError`) are carried
  /// through unchanged (they are near-zero anyway, since trim only ever
  /// activates inside the dead zone) purely for debugging fidelity — the
  /// renderer does not read them while `gazeTrimActive` is `true`.
  public var gazeTrimActive: Bool
  /// Head yaw minus the captured neutral baseline
  /// (`Config.TargetFraming.neutralYawDegrees`), degrees — same egocentric
  /// sign as `FaceGeometry.yaw`: + = turned right of neutral.
  public var yawDeviationDegrees: Float
  /// Head pitch minus the captured neutral baseline
  /// (`Config.TargetFraming.neutralPitchDegrees`), degrees — same sign as
  /// `FaceGeometry.pitch`: + = chin up relative to neutral.
  public var pitchDeviationDegrees: Float

  public init(
    errorX: Float, errorY: Float, distanceError: Float, inDeadZone: Bool,
    gazeTrimActive: Bool = false, yawDeviationDegrees: Float = 0,
    pitchDeviationDegrees: Float = 0
  ) {
    self.errorX = errorX
    self.errorY = errorY
    self.distanceError = distanceError
    self.inDeadZone = inDeadZone
    self.gazeTrimActive = gazeTrimActive
    self.yawDeviationDegrees = yawDeviationDegrees
    self.pitchDeviationDegrees = pitchDeviationDegrees
  }
}

/// Discrete audio events (§6.1 silence-ambiguity structure). The router
/// decides WHEN these fire; the renderer decides what they SOUND like.
public enum AudioEvent: Sendable, Equatable {
  /// Distinct confirmation earcon, once.
  case enteredGoodZone
  /// Quiet tick while holding good zone.
  case livenessHeartbeat
  /// Phase 4.5's ATTENTION pulse (`docs/design/phase-4.5-app-design.md`
  /// §3.3.1): the status pulse's other character, fired on the same cadence
  /// as `livenessHeartbeat` and in its place, when something durable and
  /// non-severe is wrong. Not an extra sound — the same slot, sounding
  /// different, so a near-silent monitoring session gains no sound at all.
  case attentionPulse
  /// Different IN KIND from positional tones.
  case faceLost
  /// Audibly distinct from faceLost AND noSignal.
  case lowConfidence
  /// Own sound: lens covered / feed dead.
  case noSignal
  case faceReacquired
}

public protocol AudioRendering: Sendable {
  func start() async throws
  func stop() async
  /// nil = no face, stop positional tones.
  func update(_ target: SonificationTarget?) async
  func play(_ event: AudioEvent) async
  /// §7.5: MUST cut within one render buffer.
  func setSilenced(_ silenced: Bool) async
}
