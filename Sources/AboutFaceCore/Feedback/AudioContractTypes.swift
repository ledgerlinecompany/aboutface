// TEMPORARY duplicate of the Audio agent's contract — the integrator
// deletes this file when merging `phase3/feedback-router` after
// `phase3/audio-renderer` lands. That branch owns the real
// `Sources/AboutFaceCore/Audio/AudioContract.swift`; this file exists only
// so `phase3/feedback-router` compiles and tests standalone without
// depending on the concurrent audio-renderer branch. The declarations below
// MUST stay byte-identical to that file's — do not "improve" them here, and
// do not add anything beyond what's below (a local `AudioRendering` mock for
// tests lives in `Tests/AboutFaceCoreTests/FeedbackRouterTestSupport.swift`,
// not in this file).

public struct SonificationTarget: Sendable, Equatable {
  public var errorX: Float
  public var errorY: Float
  public var distanceError: Float
  public var inDeadZone: Bool
  public init(errorX: Float, errorY: Float, distanceError: Float, inDeadZone: Bool) {
    self.errorX = errorX
    self.errorY = errorY
    self.distanceError = distanceError
    self.inDeadZone = inDeadZone
  }
}

public enum AudioEvent: Sendable, Equatable {
  case enteredGoodZone
  case livenessHeartbeat
  case faceLost
  case lowConfidence
  case noSignal
  case faceReacquired
}

public protocol AudioRendering: Sendable {
  func start() async throws
  func stop() async
  func update(_ target: SonificationTarget?) async
  func play(_ event: AudioEvent) async
  func setSilenced(_ silenced: Bool) async
}
