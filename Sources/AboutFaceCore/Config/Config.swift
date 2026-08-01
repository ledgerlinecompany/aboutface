/// The app's single source of truth for every numeric threshold, per §0 and
/// §11: "One `Config` struct, versioned, `Codable`, backend-keyed where
/// relevant. Every number in this document lives here." Nothing in this
/// codebase should hardcode a dead zone, dwell time, hysteresis ratio, target
/// framing value, or rate — every such constant is a field here, and the
/// values below are documented starting points to be tuned against the test
/// corpus (§14), not fixed constants.
///
/// This Phase-1 version is intentionally not yet backend-keyed and has no
/// migration logic: §3.2 notes that numeric thresholds do not transfer
/// between backends and that `Config` MUST eventually be keyed by backend
/// identifier, and §11 requires version-bump migration that preserves
/// unknown keys and never silently resets a user's tuning. Both arrive with
/// real backend/UI usage in a later phase — for now there is exactly one
/// backend (`VisionBackend`) and no persisted user data to migrate.
public struct Config: Codable, Sendable, Equatable {
  /// Schema version for future migration (§11). Bump when the shape of this
  /// struct changes in a way that requires migration logic.
  public var version: Int

  public var targetFraming: TargetFraming
  public var deadZone: DeadZone

  /// Exit thresholds are wider than entry thresholds by this ratio (§4, §7)
  /// so feedback does not chatter at a boundary. Applied on every
  /// hysteresis-gated state transition.
  public var hysteresisExitRatio: Double

  /// Minimum time (ms) a condition must hold before it generates any
  /// announcement (§7.1). Applies to every condition without exception.
  public var dwellMs: Int

  /// Exponential moving average window, in frames, applied to continuous
  /// signals like `FramingState.error` (§4). Never applied to state
  /// transitions — only dwell (§7.1) gates those.
  public var smoothingWindow: Int

  public struct TargetFraming: Codable, Sendable, Equatable {
    /// Eye midpoint, fraction of frame height from top (§4: "upper third,
    /// modest headroom").
    public var eyeMidpointY: Double
    /// Eye midpoint, fraction of frame width.
    public var eyeMidpointX: Double
    /// Interocular distance, fraction of frame width (§4: "medium
    /// close-up").
    public var interocularWidth: Double

    public init(eyeMidpointY: Double, eyeMidpointX: Double, interocularWidth: Double) {
      self.eyeMidpointY = eyeMidpointY
      self.eyeMidpointX = eyeMidpointX
      self.interocularWidth = interocularWidth
    }
  }

  public struct DeadZone: Codable, Sendable, Equatable {
    /// Fraction of frame width (§4).
    public var horizontal: Double
    /// Fraction of frame height (§4).
    public var vertical: Double

    public init(horizontal: Double, vertical: Double) {
      self.horizontal = horizontal
      self.vertical = vertical
    }
  }

  public init(
    version: Int,
    targetFraming: TargetFraming,
    deadZone: DeadZone,
    hysteresisExitRatio: Double,
    dwellMs: Int,
    smoothingWindow: Int
  ) {
    self.version = version
    self.targetFraming = targetFraming
    self.deadZone = deadZone
    self.hysteresisExitRatio = hysteresisExitRatio
    self.dwellMs = dwellMs
    self.smoothingWindow = smoothingWindow
  }

  /// The spec's §4 starting-point defaults. `Config.defaults` MUST remain
  /// genuinely usable with zero calibration (§13, Phase 5 acceptance).
  public static let defaults = Config(
    version: 1,
    targetFraming: TargetFraming(
      eyeMidpointY: 0.38,
      eyeMidpointX: 0.50,
      interocularWidth: 0.11
    ),
    deadZone: DeadZone(
      horizontal: 0.06,
      vertical: 0.05
    ),
    hysteresisExitRatio: 1.4,
    dwellMs: 800,
    smoothingWindow: 8
  )
}
