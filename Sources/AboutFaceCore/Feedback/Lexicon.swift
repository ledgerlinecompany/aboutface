/// §6.3: "Vocabulary is a small fixed closed set... Define the full lexicon
/// in one file, `Lexicon.swift`, and do not generate phrases dynamically."
/// This is THE closed vocabulary — every utterance About Face can ever
/// speak lives here as a static constant with a fixed phrase template.
///
/// ## Closure enforcement
///
/// `Phrase.init` is `private` — a `Phrase` can only be constructed inside
/// this file. That means `SpeechRendering.speak(_ phrase: Lexicon.Phrase)`
/// accepting only `Lexicon.Phrase` (never `String`) is not just an API
/// convention callers are expected to respect; it is impossible for any
/// other file in the codebase to fabricate a `Phrase` value at all, whether
/// or not it goes through `SpeechRendering`. `LexiconTests.swift`
/// demonstrates this at compile time (see the commented-out line there).
///
/// ## Two registers, two call sites (§5, §6.3)
///
/// - **`Instruction`** — imperative, fastest to act on ("Left.", "Closer."),
///   used by Setup mode (§5.1: "Speech uses instructions... faster to act
///   on"). `FeedbackRouter` speaks from this register exclusively.
/// - **`State`** — declarative ("You are left.", "You are close."), used by
///   Query mode (§5.3: "Uses state phrasing... more honest when the user
///   isn't actively correcting"). Defined now per this round's brief even
///   though nothing calls into it yet — Query mode's one-shot
///   burst-then-summary flow is Phase 4/5 scope (see `FeedbackMode.swift`'s
///   doc comment); `FeedbackRouter` never reads `Lexicon.State`.
///
/// Both registers describe the same closed set of conditions on purpose —
/// every `Instruction` case has a `State` counterpart — so Phase 4/5's Query
/// implementation only has to choose the register, never invent new
/// vocabulary.
public enum Lexicon {
  /// An utterance About Face is allowed to speak. Carries its fixed text;
  /// nothing outside this file can construct one (see the type-level doc
  /// comment above).
  public struct Phrase: Sendable, Equatable, Hashable {
    public let text: String
    private init(_ text: String) {
      self.text = text
    }
    fileprivate static func fixed(_ text: String) -> Phrase {
      Phrase(text)
    }
  }

  // MARK: - Instruction register (§5.1 Setup mode)

  public enum Instruction {
    // Horizontal (`FramingState.error.x`).
    public static let left = Phrase.fixed("Left.")
    public static let right = Phrase.fixed("Right.")

    // Vertical (`FramingState.error.y`) — not in the spec's illustrative
    // phrase list but required by the same mechanism (§4's target framing
    // has a vertical component; §9 exposes headroom as its own signal), so
    // it follows the same terse style rather than being left unspoken.
    public static let up = Phrase.fixed("Up.")
    public static let down = Phrase.fixed("Down.")

    // Distance (`FramingState.distanceError`).
    public static let closer = Phrase.fixed("Closer.")
    public static let back = Phrase.fixed("Back.")

    // Confirmation (§6.1 "entering good zone").
    public static let centered = Phrase.fixed("Centered.")

    // §6.1 silence-ambiguity rows.
    public static let noFace = Phrase.fixed("No face.")
    public static let noSignal = Phrase.fixed("No signal.")
    public static let tooDark = Phrase.fixed("Too dark.")

    // Gaze (§3.3 `FramingState.gazeOnCamera`).
    public static let lookAtCamera = Phrase.fixed("Look at camera.")

    // §7.3 face-lost recovery: "announce recovery once ('Back, centered.'
    // — or the problem, if there is one)". This is the "no problem" case;
    // the "or the problem" branch reuses the ordinary condition phrases
    // above (`FeedbackRouter` speaks whichever of those applies instead of
    // this one when recovery finds a live problem).
    public static let recovered = Phrase.fixed("Back, centered.")
  }

  // MARK: - State register (§5.3 Query mode)

  public enum State {
    public static let left = Phrase.fixed("You are left.")
    public static let right = Phrase.fixed("You are right.")
    public static let high = Phrase.fixed("You are high.")
    public static let low = Phrase.fixed("You are low.")
    public static let close = Phrase.fixed("You are close.")
    public static let far = Phrase.fixed("You are far.")
    public static let centered = Phrase.fixed("You are centered.")
    public static let noFace = Phrase.fixed("No face detected.")
    public static let noSignal = Phrase.fixed("No signal.")
    public static let tooDark = Phrase.fixed("Too dark to detect a face.")
    public static let gazeOff = Phrase.fixed("You are not looking at the camera.")
  }
}
