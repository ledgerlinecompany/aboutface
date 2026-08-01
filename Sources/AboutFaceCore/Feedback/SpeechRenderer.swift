import AVFoundation

/// About Face's own TTS surface (§6.3). Deliberately narrow: the ONLY thing
/// callers can hand it is a closed-vocabulary `Lexicon.Phrase` — see
/// `Lexicon.swift`'s doc comment for why that is a compile-time guarantee,
/// not just a naming convention.
public protocol SpeechRendering: Sendable {
  /// Speaks `phrase`. §5.1: interrupts any in-flight utterance rather than
  /// queuing — "Setup mode is a correction loop; stale instructions are
  /// worse than clipped ones." Conforming types MUST preempt, not queue.
  func speak(_ phrase: Lexicon.Phrase) async

  /// Cancels any queued/in-flight speech immediately. §7.5: manual silence
  /// "MUST take effect within one audio buffer — cut the render, do not
  /// wait for the current utterance to finish."
  func stopSpeaking() async
}

/// `AVSpeechSynthesizer`-backed `SpeechRendering` (§6.3).
///
/// An actor, not a plain class: `AVSpeechSynthesizer` itself is touched only
/// from actor-isolated code here (constructed in `init`, used only by
/// `speak`/`stopSpeaking`), so no external synchronization is needed and no
/// non-`Sendable` AVFoundation value ever needs to cross an isolation
/// boundary — matching the pattern this codebase already uses for
/// AVFoundation ownership (see `CLAUDE.md`'s toolchain note and
/// `FileCaptureSource`'s `ReaderBox`), just simpler here because nothing
/// `async` is awaited mid-construction.
public actor SpeechRenderer: SpeechRendering {
  private let synthesizer = AVSpeechSynthesizer()
  private var config: SpeechConfig

  public init(config: SpeechConfig = .defaults) {
    self.config = config
  }

  /// Takes effect on the next `speak(_:)` call (the anticipated caller is
  /// Phase 2/5's live-slider debug panel and voice-picker UI over `Config`
  /// — not exercised by `FeedbackRouter` itself, which only ever reads
  /// `SpeechConfig` at `SpeechRenderer` construction time this phase).
  public func updateConfig(_ config: SpeechConfig) {
    self.config = config
  }

  public func speak(_ phrase: Lexicon.Phrase) async {
    // §5.1 preemption, cited in the protocol doc comment above: always cut
    // whatever is currently speaking before starting the new utterance,
    // never queue behind it.
    synthesizer.stopSpeaking(at: .immediate)

    let utterance = AVSpeechUtterance(string: phrase.text)
    utterance.rate = config.rate
    utterance.volume = config.volume
    utterance.pitchMultiplier = config.pitchMultiplier
    utterance.voice = Self.resolveVoice(identifier: config.voiceIdentifier)

    // §6.2: "Speech is never panned... Speech stays centered; tones move."
    // There is deliberately no pan/stereo configuration anywhere in this
    // method — `AVSpeechUtterance` has no pan property to begin with, and
    // that absence is the point: nothing here should ever start routing
    // this utterance through the app's own spatial/stereo mixer the way
    // `AudioRendering`'s positional tones are. If a future refactor moves
    // speech onto `AVAudioEngine` for finer control, it MUST keep the
    // output node's pan fixed at center.
    synthesizer.speak(utterance)
  }

  public func stopSpeaking() async {
    synthesizer.stopSpeaking(at: .immediate)
  }

  // MARK: - Default voice selection (§6.3)

  /// A voice's identity, stripped down to exactly what
  /// `selectDefaultVoice(from:)` needs to decide. Exists so that function
  /// can be unit-tested with synthetic data — `AVSpeechSynthesisVoice`
  /// itself has no public initializer that lets a test fabricate an
  /// arbitrary name/language/quality/gender combination; every real
  /// instance comes from the installed-voice catalog, which varies by
  /// machine and isn't something CI should depend on for a deterministic
  /// test.
  struct VoiceInfo: Sendable, Equatable {
    let identifier: String
    let name: String
    let language: String
    let isDefaultQuality: Bool
  }

  /// §6.3's default-voice requirement, applied to whatever voices are
  /// actually installed: "Default to a voice timbrally distinct from common
  /// VoiceOver defaults — different gender or accent... Do not accept
  /// whatever `speechVoices()` returns first." Per the README's 2026-08-01
  /// empirical finding: Eloquence voices ARE reachable through this same
  /// API, but are deliberately excluded from the default pool below — many
  /// VoiceOver users already run VoiceOver ON Eloquence, and defaulting to
  /// it here would erase exactly the timbral separation this logic exists
  /// to create. (The Phase 5 voice-picker UI should still surface Eloquence
  /// as a selectable option for users who don't run VO on it themselves.)
  ///
  /// Returns `nil` when no eligible voice is installed — `AVSpeechUtterance`
  /// falls back to the system default voice in that case, which is the
  /// least-wrong behavior for a machine with a minimal voice catalog (this
  /// must never crash or throw; §13 Phase 5 requires `Config.defaults` to
  /// work with zero calibration).
  static func selectDefaultVoice(from voices: [VoiceInfo]) -> String? {
    let excludedNames: Set<String> = ["samantha", "alex"]
    let eloquenceIdentifierPrefix = "com.apple.eloquence."

    let eligible = voices.filter { voice in
      guard voice.language.hasPrefix("en") else { return false }
      guard !voice.identifier.hasPrefix(eloquenceIdentifierPrefix) else { return false }
      guard !excludedNames.contains(voice.name.lowercased()) else { return false }
      return true
    }

    // Prefer default-quality voices: Enhanced/Premium voices only "appear
    // ... after the user downloads them in System Settings" (README), so
    // they cannot be relied on as the zero-calibration default.
    let compact = eligible.filter(\.isDefaultQuality)
    let pool = compact.isEmpty ? eligible : compact

    // Prefer a non-US-English accent: it reads as a different voice from
    // Samantha/Alex almost regardless of which US voice VoiceOver happens
    // to be using — a more robust distinguishing signal than guessing which
    // gender the user's VoiceOver voice is.
    if let nonUS = pool.first(where: { $0.language != "en-US" }) {
      return nonUS.identifier
    }
    return pool.first?.identifier
  }

  /// Resolves `identifier` (or, if `nil`, `selectDefaultVoice(from:)`'s
  /// pick) to a real `AVSpeechSynthesisVoice`. `nil` result means "let
  /// `AVSpeechUtterance` use the system default" — never a crash.
  private static func resolveVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
    if let identifier {
      return AVSpeechSynthesisVoice(identifier: identifier)
    }
    let available = AVSpeechSynthesisVoice.speechVoices()
    let infos = available.map {
      VoiceInfo(
        identifier: $0.identifier,
        name: $0.name,
        language: $0.language,
        isDefaultQuality: $0.quality == .default
      )
    }
    guard let picked = selectDefaultVoice(from: infos) else { return nil }
    return AVSpeechSynthesisVoice(identifier: picked)
  }
}
