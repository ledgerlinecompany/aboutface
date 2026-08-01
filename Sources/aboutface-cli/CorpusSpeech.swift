import AVFoundation

/// Thin `AVSpeechSynthesizer` wrapper for `record-corpus --speak` — the
/// accessible recording path. Per the task brief, this tool doubles as the
/// eyes-free way to run a recording session, since most of this app's
/// audience is blind or low-vision; every printed instruction has a spoken
/// equivalent via this type.
///
/// This is deliberately NOT `Lexicon.swift`'s closed spoken vocabulary
/// (§6.3, the shipping app's terse fixed phrases): the audience here is a
/// human contributor running a recording session, not an end user hearing
/// live framing feedback, so full descriptive sentences are appropriate.
/// Rate 0.55 and the system default voice, per the task brief — no attempt
/// to pick a specific voice, unlike §6.3's shipping-app requirement to pick
/// one timbrally distinct from VoiceOver defaults.
final class Speech: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let synthesizer = AVSpeechSynthesizer()

  // Guarded only by always being read/written from `speak(_:)`'s single
  // in-flight continuation at a time (see its doc comment) — this class is
  // driven strictly sequentially by `record-corpus`'s single top-level
  // command loop, never called concurrently from multiple tasks. `@unchecked
  // Sendable` reflects that usage contract, not a lock-free race.
  private var continuation: CheckedContinuation<Void, Never>?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// Speaks `text` and suspends until it finishes (or is cancelled), so
  /// sequential calls never overlap — important here since instructions,
  /// countdown beats, and menu prompts must be heard in order, not layered
  /// on top of each other.
  func speak(_ text: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      self.continuation = continuation
      let utterance = AVSpeechUtterance(string: text)
      utterance.rate = 0.55
      synthesizer.speak(utterance)
    }
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    continuation?.resume()
    continuation = nil
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    continuation?.resume()
    continuation = nil
  }
}
