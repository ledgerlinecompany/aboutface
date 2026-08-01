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

  public init(errorX: Float, errorY: Float, distanceError: Float, inDeadZone: Bool) {
    self.errorX = errorX
    self.errorY = errorY
    self.distanceError = distanceError
    self.inDeadZone = inDeadZone
  }
}

/// Discrete audio events (§6.1 silence-ambiguity structure). The router
/// decides WHEN these fire; the renderer decides what they SOUND like.
public enum AudioEvent: Sendable, Equatable {
  /// Distinct confirmation earcon, once.
  case enteredGoodZone
  /// Quiet tick while holding good zone.
  case livenessHeartbeat
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
