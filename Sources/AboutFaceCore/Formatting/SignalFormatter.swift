/// Turns one `EngineOutput` (plus the ambient facts a frame doesn't carry —
/// backend name, requested capture format, `MirrorState`) into the exact §9
/// value list: display/accessibility strings for every signal the Setup
/// window (spec §9) must expose to VoiceOver.
///
/// This type is deliberately pure and `App`-independent so it is unit
/// testable from `AboutFaceCoreTests` without a live camera or an app
/// target — see CLAUDE.md's "keep logic in `AboutFaceCore`, keep `App/`
/// thin." Every function here is a total, allocation-cheap mapping from
/// already-computed engine output to strings; it makes no threshold
/// decisions of its own (no dwell, no hysteresis, no state-machine
/// judgment) — those all already happened upstream in `AnalysisEngine`.
/// Where this file DOES choose words (e.g. "turned toward own right" for a
/// positive yaw), it is transcribing a sign convention `FaceGeometry`
/// already documents (§3.3), not inventing a new numeric threshold.
///
/// Split across two files purely to keep each one a manageable size, the
/// same way `AnalysisEngine` is split into `AnalysisEngine{,+Framing,
/// +Geometry}.swift` — everywhere below is still `SignalFormatter`'s own
/// implementation, not a separate public surface:
/// - `SignalFormatter.swift` (this file): types, the `snapshot(...)` entry
///   point, placeholders, and row construction/dispatch.
/// - `SignalFormatter+Formatting.swift`: the per-field formatting functions
///   (`formatHeadroom`, `formatYaw`, etc.) and shared numeric primitives.
public enum SignalFormatter {

  /// Stable identity for one §9 row, independent of display order — lets
  /// callers (tests, the Setup window's `ForEach`) address a specific
  /// signal without depending on array position.
  public enum Field: String, CaseIterable, Sendable, Equatable {
    case headroom
    case horizontalOffset
    case faceBox
    case interocularDistance
    case faceLuma
    case backgroundLuma
    case backlightDelta
    case clippedHighlights
    case clippedShadows
    case sharpness
    case yaw
    case pitch
    case roll
    case faceCount
    case backendConfidence
    case backendName
    case captureFormat
    case mirrorState
  }

  /// One VoiceOver-navigable row: a fixed label plus a live value, per §9
  /// ("A user can arrow through precise numbers"). Both are always
  /// non-empty — there is no blank or stale-looking state, only explicit
  /// placeholder text (§9's "never blank, never stale-looking" is this
  /// file's paraphrase of that requirement).
  public struct FormattedSignal: Sendable, Equatable, Identifiable {
    public let id: Field
    public let label: String
    public let value: String

    public init(id: Field, label: String, value: String) {
      self.id = id
      self.label = label
      self.value = value
    }
  }

  /// The capture format actually requested of the camera (§5.1/§5.2:
  /// "requested explicitly, not negotiated"), for display only — this type
  /// carries no behavior of its own.
  public struct CaptureFormatDescriptor: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double

    public init(width: Int, height: Int, frameRate: Double) {
      self.width = width
      self.height = height
      self.frameRate = frameRate
    }
  }

  // MARK: - Entry point

  /// Builds every §9 row, in the fixed order the spec lists them, from one
  /// frame's `EngineOutput`.
  ///
  /// - Parameters:
  ///   - output: The most recent frame's engine output, or `nil` if
  ///     analysis has not produced anything yet (e.g. camera not started).
  ///   - backendName: `FaceAnalysisBackend.displayName` of the active
  ///     backend.
  ///   - captureFormat: The REQUESTED capture format, or `nil` if capture
  ///     has not been configured yet.
  ///   - actualCaptureDimensions: The ACTUAL pixel dimensions the camera has
  ///     delivered this session (read from a real captured frame — see
  ///     `CapturedFrame.pixelDimensions`), or `nil` if no frame has arrived
  ///     yet. Distinct from `captureFormat` on purpose (PR #53's lesson,
  ///     `CapturedFrame.pixelDimensions`'s own doc comment): a requested
  ///     format is not proof of a delivered one, and the capture-format row
  ///     must be able to say so rather than parroting the request back.
  ///   - mirrorState: The active capture session's `MirrorState`, or `nil`
  ///     before a session exists.
  /// Everything a row needs besides the field itself — bundled so the
  /// internal helpers stay within SwiftLint's parameter-count limit as the
  /// context grows.
  struct Context {
    let output: EngineOutput?
    let backendName: String
    let captureFormat: CaptureFormatDescriptor?
    let actualCaptureDimensions: PixelDimensions?
    let mirrorState: MirrorState?
    let display: Config.Display
  }

  public static func snapshot(
    output: EngineOutput?,
    backendName: String,
    captureFormat: CaptureFormatDescriptor?,
    actualCaptureDimensions: PixelDimensions? = nil,
    mirrorState: MirrorState?,
    display: Config.Display = Config.defaults.display
  ) -> [FormattedSignal] {
    let context = Context(
      output: output, backendName: backendName, captureFormat: captureFormat,
      actualCaptureDimensions: actualCaptureDimensions, mirrorState: mirrorState, display: display)
    return Field.allCases.map { row(for: $0, context: context) }
  }

  // MARK: - Placeholders (§9: "never blank, never stale-looking")

  /// Text shown for a measured (per-frame) field when there is no
  /// `EngineOutput` at all yet — analysis has never run, as opposed to
  /// having run and found nothing. Distinct from the `SignalState`
  /// placeholders below so a genuinely idle app never reads like a dark
  /// room or a covered lens.
  static let notStartedPlaceholder = "Not started"

  /// Text for a field that depends on a detected face, when
  /// `analysis.primary == nil`. Chosen from `SignalState` so "no face" and
  /// "no signal" stay the audibly/readably distinct conditions §6.1
  /// requires even inside this read-only value list.
  static func facePlaceholder(for state: SignalState) -> String {
    switch state {
    case .noSignal: return "No signal"
    case .noFace, .lowConfidence, .ok: return "No face detected"
    }
  }

  // MARK: - Row construction
  //
  // Split into several small, single-purpose lookups (rather than one large
  // switch) purely to stay under SwiftLint's cyclomatic-complexity and
  // function-length limits — `Field` has 18 cases, and one function trying
  // to handle all of them in a single switch reads exactly as badly as it
  // lints. Each helper below owns one "tier" of §9 rows: static (no frame
  // dependency), whole-frame (always meaningful once analysis has run
  // once), and face-dependent (needs a detected face). `value(for:...)`
  // tries each tier in order and stops at the first that applies.

  private static func row(for field: Field, context: Context) -> FormattedSignal {
    FormattedSignal(id: field, label: label(for: field), value: value(for: field, context: context))
  }

  private static func value(for field: Field, context: Context) -> String {
    let output = context.output
    let display = context.display
    // swift-format requires the brace on its own line after a multiline
    // condition; swiftlint's opening_brace rule disagrees. Format wins (see
    // ConfigStore.swift for the same, pre-existing conflict).
    // swiftlint:disable opening_brace
    if let staticValue = staticValue(
      for: field, backendName: context.backendName, captureFormat: context.captureFormat,
      actualCaptureDimensions: context.actualCaptureDimensions, mirrorState: context.mirrorState)
    {
      return staticValue
    }
    guard let output else {
      return notStartedPlaceholder
    }
    if let wholeFrame = wholeFrameValue(for: field, output: output, display: display) {
      return wholeFrame
    }
    guard let geometry = output.analysis.primary, let framing = output.framing else {
      return facePlaceholder(for: output.analysis.signalState)
    }
    if let position = positionValue(
      for: field, geometry: geometry, framing: framing, display: display)
    {
      // swiftlint:enable opening_brace
      return position
    }
    return poseAndQualityValue(
      for: field, geometry: geometry, lighting: output.analysis.lighting, display: display)
  }

  /// Fields with no per-frame dependency at all: always have a value, even
  /// with no `EngineOutput` yet.
  private static func staticValue(
    for field: Field,
    backendName: String,
    captureFormat: CaptureFormatDescriptor?,
    actualCaptureDimensions: PixelDimensions?,
    mirrorState: MirrorState?
  ) -> String? {
    switch field {
    case .backendName:
      return backendName
    case .captureFormat:
      guard let captureFormat else { return notStartedPlaceholder }
      return formatCaptureFormat(captureFormat, actual: actualCaptureDimensions)
    case .mirrorState:
      return mirrorState.map(formatMirrorState) ?? notStartedPlaceholder
    default:
      return nil
    }
  }

  /// Whole-frame lighting/count fields: meaningful once analysis has run at
  /// least once, face or no face (`LightingAnalyzer` computes them from the
  /// whole frame minus whatever face ROI it was given, `nil` or not).
  private static func wholeFrameValue(
    for field: Field, output: EngineOutput, display: Config.Display
  ) -> String? {
    switch field {
    case .backgroundLuma:
      return percentString(output.analysis.lighting.backgroundLuma, display: display)
    case .clippedHighlights:
      return percentString(output.analysis.lighting.clippedHighlightFraction, display: display)
    case .clippedShadows:
      return percentString(output.analysis.lighting.clippedShadowFraction, display: display)
    case .faceCount:
      return formatFaceCount(output.analysis.faceCount)
    default:
      return nil
    }
  }

  /// Framing-position fields: need a detected face's geometry/framing.
  private static func positionValue(
    for field: Field, geometry: FaceGeometry, framing: FramingState, display: Config.Display
  ) -> String? {
    switch field {
    case .headroom:
      return formatHeadroom(geometry, display: display)
    case .horizontalOffset:
      return formatHorizontalOffset(framing, display: display)
    case .faceBox:
      return formatFaceBox(geometry, display: display)
    case .interocularDistance:
      return formatInterocularDistance(geometry, framing: framing, display: display)
    default:
      return nil
    }
  }

  /// Pose (yaw/pitch/roll), face-dependent lighting, and confidence fields:
  /// also need a detected face. `default` is a genuine "unreachable in
  /// practice" fallback — every field reaching this function was already
  /// ruled out by `staticValue`/`wholeFrameValue`/`positionValue` above.
  private static func poseAndQualityValue(
    for field: Field, geometry: FaceGeometry, lighting: LightingMetrics, display: Config.Display
  ) -> String {
    switch field {
    case .faceLuma:
      return percentString(lighting.faceLuma, display: display)
    case .backlightDelta:
      return formatBacklightDelta(lighting.backlightDelta, display: display)
    case .sharpness:
      return fixed(quantized(Double(lighting.sharpness), step: display.normalizedStep), decimals: 2)
    case .yaw:
      return formatYaw(geometry.yaw, display: display)
    case .pitch:
      return formatPitch(geometry.pitch, display: display)
    case .roll:
      return formatRoll(geometry.roll, display: display)
    case .backendConfidence:
      return percentString(geometry.confidence, display: display)
    default:
      return notStartedPlaceholder
    }
  }

  // swift-format wants a trailing comma on the last element of a multiline
  // collection literal; swiftlint's (default-on) trailing_comma rule
  // forbids one. Same tool disagreement as the `sorted_imports`/
  // `opening_brace` conflicts noted elsewhere in this codebase (see
  // FileCaptureSource.swift, ConfigStore.swift) — format wins.
  // swiftlint:disable trailing_comma
  private static let fieldLabels: [Field: String] = [
    .headroom: "Headroom",
    .horizontalOffset: "Horizontal offset",
    .faceBox: "Face box",
    .interocularDistance: "Interocular distance",
    .faceLuma: "Face brightness",
    .backgroundLuma: "Background brightness",
    .backlightDelta: "Backlight difference",
    .clippedHighlights: "Clipped highlights",
    .clippedShadows: "Clipped shadows",
    .sharpness: "Sharpness",
    .yaw: "Yaw",
    .pitch: "Pitch",
    .roll: "Roll",
    .faceCount: "Face count",
    .backendConfidence: "Backend confidence",
    .backendName: "Backend",
    .captureFormat: "Capture format",
    .mirrorState: "Mirror state",
  ]
  // swiftlint:enable trailing_comma

  private static func label(for field: Field) -> String {
    fieldLabels[field] ?? field.rawValue
  }
}
