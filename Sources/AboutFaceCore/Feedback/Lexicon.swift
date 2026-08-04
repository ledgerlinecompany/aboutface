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
/// vocabulary. Two more registers are defined further down, each with its
/// own doc comment explaining why it did not fit here: `Reminder` (§12.2/
/// §16.4's camera-in-use notice) and `Confirmation` (§8's hotkey/button
/// action acknowledgments).
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
    public static let headLevel = Phrase.fixed("Your head is level.")
    public static let otherPeoplePresent = Phrase.fixed("Other people are in frame.")
    public static let otherPeopleNone = Phrase.fixed("No one else in frame.")
    public static let allClear = Phrase.fixed("All good.")
  }

  // MARK: - Reminder register (§12.2/§16.4 camera-in-use rising-edge reminder)

  /// A third register, deliberately distinct from `Instruction` and
  /// `State`: this phrase is neither a Setup-mode correction ("Left.") nor
  /// a Query-mode state answer ("You are left.") — it is a standing
  /// reminder fired by `CameraReminderStateMachine` (§12.2/§16.4) on the
  /// rising edge of another app's camera use, while About Face itself is
  /// idle. It shares nothing with the other two registers' vocabulary and
  /// is spoken from a different call site entirely (the App-side
  /// `MonitorReminderController`, not `FeedbackRouter`), so it gets its own
  /// clearly-named group rather than being folded into either existing one.
  public enum Reminder {
    /// The maintainer's exact, decided wording (2026-08-03/04) — chosen
    /// over an instruction like "Turn on Monitor" on purpose: this is a
    /// reminder, not a correction. The user may legitimately not want
    /// Monitor on for a given call (§12.2's own finding that camera sharing
    /// makes "someone else is using the camera" an ambiguous signal about
    /// intent, not just about detection), so the phrase states the fact
    /// ("Camera in use") plus the app's own current state ("Monitor is
    /// off") and stops — it never nags toward a choice that isn't always
    /// right. Fires once per false→true transition of the busy signal,
    /// only while About Face is not itself capturing (§12.2's asymmetry:
    /// the underlying CoreMediaIO property can't tell "someone else" from
    /// "us"), and only when the user has not manually silenced feedback
    /// (§7.5) — see `CameraReminderStateMachine`'s doc comment for the full
    /// decision logic and `MonitorReminderController`'s for how it reaches
    /// speech despite firing exactly when `PipelineModel.speechRenderer`
    /// does not exist.
    public static let cameraInUseMonitorOff = Phrase.fixed("Camera in use. Monitor is off.")
  }

  // MARK: - Confirmation register (§8 hotkey/button confirmations)

  /// A fourth register, deliberately distinct from `Instruction`, `State`,
  /// AND `Reminder`: this is a direct, one-shot acknowledgment that an
  /// explicit user action — a global hotkey press or a Setup-window button
  /// click — succeeded or failed. The distinction that earns it a separate
  /// group, matching how `Reminder` justified its own: `Reminder` fires
  /// unprompted, from the app's own inference about the world (someone else
  /// started using the camera); `Confirmation` fires only in direct
  /// response to something the user just did, synchronously with that
  /// action, and never otherwise.
  ///
  /// That distinction is also why every `Confirmation` phrase is spoken
  /// through `PipelineModel.speechRenderer` — the single app-lifetime
  /// `SpeechRenderer` it, `HotkeyCenter`, and `MonitorReminderController`
  /// all now share (see that property's doc comment) — but DELIBERATELY
  /// bypasses `FeedbackRouter` entirely, which is what its own §7.5 manual
  /// silence gate (`FeedbackRouter.setSilenced`) lives on. Manual silence is
  /// meant to suppress AUTOMATIC feedback the user did not just ask for;
  /// a confirmation is the opposite of that by construction, and a
  /// silenced confirmation would be indistinguishable from a hotkey that
  /// silently failed to register at all — precisely the "is this thing on?"
  /// bug this whole register exists to fix (maintainer, 2026-08-04: global
  /// hotkeys fired correctly while backgrounded but were inaudible because
  /// the old VoiceOver-announcement lane is suppressed for a non-frontmost
  /// app). This matters most for `silenced`/`unsilenced` themselves: if
  /// silencing were silent, a press of that one key would give no way to
  /// tell whether it just silenced or unsilenced feedback.
  public enum Confirmation {
    /// §8 ⌘⌃⇧M, `HotkeyCenter.dispatch(_:)`'s `.monitorToggle` case.
    public static let monitorOn = Phrase.fixed("Monitor on.")
    public static let monitorOff = Phrase.fixed("Monitor off.")

    /// `PipelineModel.toggleMonitor()` failed to start Monitor mode (no
    /// camera selected, permission denied, a capture error, ...).
    /// Deliberately a FIXED phrase rather than the underlying
    /// `PipelineModel.captureErrorMessage` text: that string is built at
    /// runtime from an arbitrary `Error`'s description (interpolated device
    /// names, `NSError` domains, ...), and speaking it verbatim would be
    /// exactly the dynamic phrase generation §6.3/CLAUDE.md forbid. The
    /// full detail stays available where it already was —
    /// `SetupWindowView`'s VoiceOver-readable "Capture error" section —
    /// this phrase only confirms THAT the hotkey's attempt failed, which is
    /// all a terse confirmation owes.
    public static let monitorFailedToStart = Phrase.fixed("Monitor failed to start.")

    /// §7.5 manual silence (⌘⌃⇧/), `HotkeyCenter.dispatch(_:)`'s `.silence`
    /// case. See this enum's doc comment for why these two specifically
    /// motivate bypassing `FeedbackRouter`'s silence gate.
    public static let silenced = Phrase.fixed("Silenced.")
    public static let unsilenced = Phrase.fixed("Unsilenced.")

    /// §4 "capture current position as target" — ⌘⌃⇧T and the Setup
    /// window's own button both funnel through
    /// `PipelineModel.captureCurrentPositionAsTarget()`, which speaks this
    /// on success (see that method's doc comment).
    public static let targetCaptured = Phrase.fixed("Target captured.")

    /// The failure counterpart, spoken by both call sites above when
    /// `captureCurrentPositionAsTarget()` returns `false` (no face
    /// currently detected to capture a position from).
    public static let noFaceToCapture = Phrase.fixed("No face. Nothing captured.")
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
