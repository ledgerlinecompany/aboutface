import AboutFaceCore
import Foundation

/// One line of per-frame output, shared by `replay` and available to any
/// future subcommand that wants the same fixed field set. Fields that
/// depend on a detected face (`errorX`/`errorY`/`distanceError`/
/// `inDeadZone`/`yaw`/`pitch`/`roll`/`confidence`) are `nil` on a
/// no-face/no-signal frame; the plain-text renderer spells that `-`, the
/// JSON renderer spells it `null`.
///
/// Field order here is the documented, script-friendly contract (see
/// `Replay`'s `--help` discussion) — do not reorder without updating that
/// discussion text, since scripts may parse by position.
struct OutputLine: Encodable {
  let timestampSeconds: Double
  let signalState: String
  let faceCount: Int
  let errorX: Float?
  let errorY: Float?
  let distanceError: Float?
  let inDeadZone: Bool?
  let yaw: Float?
  let pitch: Float?
  let roll: Float?
  let faceLuma: Float
  let backgroundLuma: Float
  let confidence: Float?

  init(_ output: EngineOutput) {
    timestampSeconds = output.analysis.timestamp.seconds
    signalState = "\(output.analysis.signalState)"
    faceCount = output.analysis.faceCount
    faceLuma = output.analysis.lighting.faceLuma
    backgroundLuma = output.analysis.lighting.backgroundLuma
    confidence = output.analysis.primary?.confidence
    yaw = output.analysis.primary?.yaw
    pitch = output.analysis.primary?.pitch
    roll = output.analysis.primary?.roll
    errorX = output.framing?.error.x
    errorY = output.framing?.error.y
    distanceError = output.framing?.distanceError
    inDeadZone = output.framing?.inDeadZone
  }

  // swiftlint and swift-format disagree on trailing commas in multiline collection
  // literals (swift-format requires them, swiftlint's default forbids them); this
  // block satisfies `swift format lint`, which the CI gate also enforces.
  // swiftlint:disable trailing_comma
  /// Space-separated, fixed field order; see `Replay`'s `--help` discussion
  /// for the documented format this must keep matching.
  func plainText() -> String {
    [
      String(format: "%.3f", timestampSeconds),
      signalState,
      "faces=\(faceCount)",
      "err=\(Self.fmt(errorX)),\(Self.fmt(errorY))",
      "dist=\(Self.fmt(distanceError))",
      "dz=\(Self.fmtBool(inDeadZone))",
      "ypr=\(Self.fmt(yaw)),\(Self.fmt(pitch)),\(Self.fmt(roll))",
      "luma=\(Self.fmt(faceLuma)),\(Self.fmt(backgroundLuma))",
      "conf=\(Self.fmt(confidence))",
    ].joined(separator: " ")
  }
  // swiftlint:enable trailing_comma

  /// One JSON object per line, same fields as `plainText()`, explicit
  /// `null` in place of plain text's `-`.
  ///
  /// A hand-written `encode(to:)` rather than the synthesized `Encodable`
  /// conformance: Swift's synthesized conformance calls `encodeIfPresent`
  /// for `Optional` stored properties, which OMITS the key entirely when
  /// `nil` rather than writing `null` — the opposite of what's documented
  /// above and what makes a script's per-key access reliable across every
  /// line, since every key is then guaranteed present on every line
  /// regardless of `SignalState`.
  ///
  /// Key ORDER, unlike `plainText()`'s field order, is not part of the
  /// contract and must not be relied on: `Foundation`'s `JSONEncoder` does
  /// not guarantee it matches `encode(to:)`'s call order (verified
  /// empirically — it does not, in the version this was built against),
  /// and JSON objects are unordered by spec (RFC 8259 §4) regardless. A
  /// script MUST look fields up by key, never by position, when using
  /// `--json`.
  func jsonString() -> String {
    guard let data = try? Self.jsonEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private enum CodingKeys: String, CodingKey {
    case timestampSeconds, signalState, faceCount, errorX, errorY, distanceError, inDeadZone, yaw,
      pitch, roll, faceLuma, backgroundLuma, confidence
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timestampSeconds, forKey: .timestampSeconds)
    try container.encode(signalState, forKey: .signalState)
    try container.encode(faceCount, forKey: .faceCount)
    try Self.encodeOrNull(errorX, forKey: .errorX, in: &container)
    try Self.encodeOrNull(errorY, forKey: .errorY, in: &container)
    try Self.encodeOrNull(distanceError, forKey: .distanceError, in: &container)
    try Self.encodeOrNull(inDeadZone, forKey: .inDeadZone, in: &container)
    try Self.encodeOrNull(yaw, forKey: .yaw, in: &container)
    try Self.encodeOrNull(pitch, forKey: .pitch, in: &container)
    try Self.encodeOrNull(roll, forKey: .roll, in: &container)
    try container.encode(faceLuma, forKey: .faceLuma)
    try container.encode(backgroundLuma, forKey: .backgroundLuma)
    try Self.encodeOrNull(confidence, forKey: .confidence, in: &container)
  }

  private static func encodeOrNull<T: Encodable>(
    _ value: T?,
    forKey key: CodingKeys,
    in container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    if let value {
      try container.encode(value, forKey: key)
    } else {
      try container.encodeNil(forKey: key)
    }
  }

  private static let jsonEncoder = JSONEncoder()

  private static func fmt(_ value: Float?) -> String {
    value.map { String(format: "%.4f", $0) } ?? "-"
  }

  private static func fmt(_ value: Float) -> String {
    String(format: "%.4f", value)
  }

  private static func fmtBool(_ value: Bool?) -> String {
    value.map(String.init) ?? "-"
  }
}
