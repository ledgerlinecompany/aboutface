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

  /// Thresholds and performance knobs for `LightingAnalyzer`'s computation
  /// of `LightingMetrics` (§3.3). Per §6.2, lighting is a discrete,
  /// dwell-and-hysteresis-gated state rather than part of the continuous
  /// positional loop, but the raw signals it is derived from still need
  /// their own tunable numbers (§0), which live here.
  public var lighting: Lighting

  /// Thresholds `AnalysisEngine` uses to classify `SignalState` (§3.3).
  public var signal: Signal

  /// Thresholds `AnalysisEngine` uses to derive `FramingState.gazeOnCamera`
  /// from head-pose magnitude (§3.3: "from yaw/pitch magnitude, or true
  /// gaze if available").
  public var gaze: Gaze

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

  public struct Lighting: Codable, Sendable, Equatable {
    /// Luma (0...1) at or above this fraction of full brightness counts
    /// toward `LightingMetrics.clippedHighlightFraction`.
    public var clippedHighlightThreshold: Double
    /// Luma (0...1) at or below this fraction of full brightness counts
    /// toward `LightingMetrics.clippedShadowFraction`.
    public var clippedShadowThreshold: Double
    /// `LightingAnalyzer` downsamples the captured frame to at most this
    /// many pixels wide (aspect-preserving) before doing any per-pixel
    /// work, so lighting analysis stays cheap at up to 30 Hz on 720p
    /// capture (§13, Phase 1 acceptance).
    public var maxAnalysisWidth: Int
    /// Divisor `LightingAnalyzer` uses to map its raw Laplacian-of-luma
    /// variance (the classic "variance of Laplacian" blur metric) onto an
    /// approximately 0...1 `LightingMetrics.sharpness` range:
    /// `sharpness = rawVariance / sharpnessNormalizationDivisor`. The
    /// default is a starting-point estimate scaled for 0...1 luma (blur
    /// literature usually works on a 0...255 scale) — tune against the test
    /// corpus (§14) once real clips exist.
    public var sharpnessNormalizationDivisor: Double

    public init(
      clippedHighlightThreshold: Double,
      clippedShadowThreshold: Double,
      maxAnalysisWidth: Int,
      sharpnessNormalizationDivisor: Double
    ) {
      self.clippedHighlightThreshold = clippedHighlightThreshold
      self.clippedShadowThreshold = clippedShadowThreshold
      self.maxAnalysisWidth = maxAnalysisWidth
      self.sharpnessNormalizationDivisor = sharpnessNormalizationDivisor
    }
  }

  public struct Signal: Codable, Sendable, Equatable {
    /// Below this `LightingMetrics.frameLumaVariance`, the frame is treated
    /// as near-uniform regardless of what the backend reports — lens
    /// covered, camera asleep, or a dead feed (§3.3 `SignalState.noSignal`).
    /// Starting point chosen relative to `LightingAnalyzerTests`' measured
    /// reference points: a genuinely uniform frame measures well under
    /// `1e-6`, while a half-black/half-white scene measures ~0.25; ordinary
    /// (non-uniform) real content sits far above this threshold.
    public var noSignalLumaVarianceThreshold: Double
    /// A face detected with backend confidence below this is reported as
    /// `SignalState.lowConfidence` rather than `.ok` (§3.3: "probably
    /// there, detector unsure — often too dark").
    public var lowConfidenceThreshold: Double

    public init(noSignalLumaVarianceThreshold: Double, lowConfidenceThreshold: Double) {
      self.noSignalLumaVarianceThreshold = noSignalLumaVarianceThreshold
      self.lowConfidenceThreshold = lowConfidenceThreshold
    }
  }

  public struct Gaze: Codable, Sendable, Equatable {
    /// `FramingState.gazeOnCamera` requires `|yaw|` at or below this many
    /// degrees.
    public var maxYawDegrees: Double
    /// `FramingState.gazeOnCamera` requires `|pitch|` at or below this many
    /// degrees.
    public var maxPitchDegrees: Double

    public init(maxYawDegrees: Double, maxPitchDegrees: Double) {
      self.maxYawDegrees = maxYawDegrees
      self.maxPitchDegrees = maxPitchDegrees
    }
  }

  public init(
    version: Int,
    targetFraming: TargetFraming,
    deadZone: DeadZone,
    hysteresisExitRatio: Double,
    dwellMs: Int,
    smoothingWindow: Int,
    lighting: Lighting,
    signal: Signal,
    gaze: Gaze
  ) {
    self.version = version
    self.targetFraming = targetFraming
    self.deadZone = deadZone
    self.hysteresisExitRatio = hysteresisExitRatio
    self.dwellMs = dwellMs
    self.smoothingWindow = smoothingWindow
    self.lighting = lighting
    self.signal = signal
    self.gaze = gaze
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
    smoothingWindow: 8,
    lighting: Lighting(
      clippedHighlightThreshold: 0.98,
      clippedShadowThreshold: 0.02,
      maxAnalysisWidth: 320,
      sharpnessNormalizationDivisor: 0.02
    ),
    signal: Signal(
      noSignalLumaVarianceThreshold: 0.0005,
      lowConfidenceThreshold: 0.5
    ),
    gaze: Gaze(
      maxYawDegrees: 15,
      maxPitchDegrees: 15
    )
  )
}
