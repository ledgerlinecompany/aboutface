import AboutFaceCore

/// One place that turns an `AcceptanceEvent.Kind` into plain text, shared by
/// `AcceptanceSessionStore` (the JSON artifact) and `AcceptanceSummary` (the
/// terminal report) so the two never describe the same event differently.
enum AcceptanceDescribe {
  static func kind(_ kind: AcceptanceEvent.Kind) -> String {
    switch kind {
    case .audioEvent(let event):
      return "audio: \(event)"
    case .spokenPhrase(let phrase):
      return "spoken: \"\(phrase.text)\""
    case .userLikelyAway(let value):
      return "userLikelyAway -> \(value)"
    }
  }

  static func event(_ event: AcceptanceEvent) -> String {
    "t=\(event.elapsedMs)ms \(kind(event.kind))"
  }
}
