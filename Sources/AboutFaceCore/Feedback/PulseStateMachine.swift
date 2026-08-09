/// The one bit the status pulse carries (`docs/design/phase-4.5-app-design.md`
/// §3.3.1): **is everything okay — if not, ask me.**
///
/// Pure and clock-injected, like every other state machine in this codebase:
/// `update(isCropped:now:)` takes the caller's monotonic seconds rather than
/// reading a clock, so a test replaying a scripted timeline is exactly as
/// meaningful as a live session.
///
/// ## Exactly two states, deliberately
///
/// Three or four would mean the user decoding a sound vocabulary while
/// listening to a colleague, which is precisely the serial-channel cost the
/// whole design exists to avoid. Query carries the detail; this carries
/// whether to bother asking.
///
/// ## Asymmetric dwell, and why round that way
///
/// Entering `.attention` is slow (`outOfFrameEnterMs`, default 10s) because
/// this is "you have been like this for a while," not "you moved" — a person
/// leaning aside to pick something up should never trip it. Leaving is quicker
/// (`outOfFrameExitMs`, default 3s) because a user who has just corrected
/// their position deserves to hear that it worked without serving out the full
/// entry dwell again.
///
/// That is §4's hysteresis rule oriented the way a WARNING state wants it:
/// slow to alarm, prompt to reassure. Note it is the opposite orientation from
/// §4's dead zone, where exit thresholds are WIDER than entry — there the
/// latched state is the good one, here it is the bad one, and in both cases
/// the asymmetry protects against chattering into the state the user would
/// rather not be told about repeatedly.
public struct PulseStateMachine: Sendable, Equatable {
  /// What the pulse should sound like right now.
  public enum State: Sendable, Equatable {
    /// Everything the pulse knows about is fine. The ordinary heartbeat.
    case normal
    /// Something durable and non-severe is wrong — currently only "the face
    /// is cropped by the frame edge." Same cadence, different character.
    case attention
  }

  private let enterSeconds: Double
  private let exitSeconds: Double

  private var state: State = .normal
  /// When the CANDIDATE state (the one we are not in) first began holding.
  /// `nil` whenever the observed condition agrees with the current state.
  private var pendingSince: Double?

  public init(enterMs: Int, exitMs: Int) {
    enterSeconds = Double(max(0, enterMs)) / 1000
    exitSeconds = Double(max(0, exitMs)) / 1000
  }

  /// Feeds one observation and returns the state the pulse should use now.
  ///
  /// - Parameters:
  ///   - isCropped: whether the face is currently cropped by a frame edge
  ///     (see `FrameEdgeCrop`).
  ///   - now: caller-supplied monotonic seconds.
  @discardableResult
  public mutating func update(isCropped: Bool, now: Double) -> State {
    let candidate: State = isCropped ? .attention : .normal

    guard candidate != state else {
      // Agrees with where we are: any part-served dwell is abandoned, which is
      // what makes a flicker cost nothing rather than accumulating toward a
      // transition it never sustained.
      pendingSince = nil
      return state
    }

    guard let since = pendingSince else {
      pendingSince = now
      return state
    }

    let required = candidate == .attention ? enterSeconds : exitSeconds
    guard (now - since) >= required else { return state }

    state = candidate
    pendingSince = nil
    return state
  }

  /// The state without feeding an observation.
  public var current: State { state }

  /// Forgets everything, including any part-served dwell. Used when the face
  /// is lost: §7.3's ladder owns that stretch, and the cropped/not-cropped
  /// question is meaningless with no face to ask it about. Resuming from
  /// `.normal` rather than from a stale `.attention` is deliberate — the user
  /// who walks back may be perfectly placed, and greeting them with a warning
  /// they have not yet earned would be a lie the pulse cannot explain.
  public mutating func reset() {
    state = .normal
    pendingSince = nil
  }
}
