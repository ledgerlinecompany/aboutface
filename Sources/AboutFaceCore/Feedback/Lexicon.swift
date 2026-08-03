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
///
/// ## Auditory contract (tuning round 5 design discussion)
///
/// Tones never mean "look"; direction words always mean "move"; the word
/// "Look" always means gaze — `Instruction.lookAtCamera` is the only phrase
/// that ever asks for a gaze correction, and it is speech, never a tone.
/// **Exception:** when `Config.AudioGazeTrim.enabled` (default `false`, an
/// audition prototype — see `FeedbackRouter+GazeTrim.swift`/
/// `RenderState+GazeTrim.swift`), the gaze-trim tone DOES mean "turn,"
/// breaking the tones-never-mean-look rule on purpose. It stays honest only
/// because it is never mistakable for the positional beacon — markedly
/// quieter, a disjoint register, Setup-mode and confirmed-good-zone only —
/// so a listener can always tell which loop they're in from the sound
/// alone, not from having to remember which mode is active.
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
    //
    // Maintainer field note (2026-08-02): a vertical correction here can
    // mean the user's own body/head height changed OR that the laptop lid
    // angle changed (tilting the camera's pitch relative to a seated user
    // who hasn't moved) — `FramingState.error.y` cannot distinguish the two
    // causes, and deliberately does not try to (no lid-angle sensor exists
    // to disambiguate, and guessing would risk telling a user to move when
    // the fix is actually "close the lid a little"). "Up."/"Down." stay
    // exactly this generic on purpose. Phase 5's first-run script (§13) is
    // the right place to teach this distinction once, as an onboarding
    // pointer ("if 'up' or 'down' doesn't match what your body is doing,
    // try the lid angle instead") — not something to encode per-utterance
    // here, which §6.3's terseness rules out anyway.
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

    // Roll (§4 extension, `FramingState.headLevel`; maintainer, 2026-08-02:
    // "Agreed, it's part of gaze" — a held head tilt while placed gets the
    // same in-zone advisory treatment as gaze-off, via
    // `FeedbackRouter.tickGoodZoneRoll`. No `AudioEvent` — same "tones never
    // mean look/tilt" contract `lookAtCamera` already keeps.
    public static let level = Phrase.fixed("Level.")

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
    public static let headTilted = Phrase.fixed("Head tilted.")

    // §5.3 Query mode additions (`QueryComposer.swift`) — the "fine" state
    // for each field that can also report a problem above, plus §5.3's
    // "other people" field (new signal this round, `FrameAnalysis
    // .faceCount > 1`) and a whole-query fallback for the "problems only"
    // variant finding literally nothing wrong (see `QueryComposer
    // .summarize(burst:problemsOnly:)`'s doc comment for why total silence
    // in response to an explicit hotkey press would itself be a §6.1-style
    // silence ambiguity — "did my hotkey even register").
    public static let lightingFine = Phrase.fixed("Lighting is fine.")
    public static let gazeOn = Phrase.fixed("You are looking at the camera.")
    public static let headLevelState = Phrase.fixed("Your head is level.")
    public static let otherPeoplePresent = Phrase.fixed("Other people are in frame.")
    public static let otherPeopleNone = Phrase.fixed("No one else in frame.")
    public static let allClear = Phrase.fixed("All good.")
  }

  /// Joins already-fixed `Phrase` values, in the order given, into ONE
  /// spoken utterance — §5.3 Query mode's "a single terse spoken summary"
  /// assembled from up to four independently aggregated fields (framing,
  /// lighting, gaze, other people; see `QueryComposer.swift`), each of which
  /// is itself one or more of this file's fixed `State` phrases.
  ///
  /// This is NOT the dynamic-phrase-generation §6.3/CLAUDE.md forbid ("do
  /// not generate phrases dynamically"): nothing here interpolates a
  /// number, a name, or any other runtime value into text — it only
  /// concatenates strings that already exist as closed-vocabulary constants
  /// declared in THIS file. The closure guarantee (`Phrase.init` private,
  /// `fixed(_:)` fileprivate to this file) still holds: `compose(_:)` lives
  /// here too, and every `Phrase` it can ever receive was itself
  /// constructed the same closed way, so the composed result is always a
  /// concatenation of vocabulary this file defines, in an order the caller
  /// chooses — never new words.
  public static func compose(_ phrases: [Phrase]) -> Phrase {
    Phrase.fixed(phrases.map(\.text).joined(separator: " "))
  }
}
