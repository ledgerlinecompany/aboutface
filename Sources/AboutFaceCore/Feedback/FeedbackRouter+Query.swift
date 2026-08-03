/// §5.3 Query mode and §8 repeat-last, implemented entirely as
/// `FeedbackRouter` extension methods so the stored properties they use
/// (`recentOutputs`, `lastSpokenPhrase`) can stay declared once, in
/// `FeedbackRouter.swift`, alongside every other piece of router state (see
/// that file's own doc comment). Split out for the same file-size reason as
/// `FeedbackRouter+Announcements.swift`/`+GoodZoneAdvisories.swift` — this is
/// still `FeedbackRouter`'s own implementation, not a separate public
/// surface.
///
/// ## Where the "burst" comes from
///
/// §5.3 describes Query as "a one-shot burst of analysis (~10 frames,
/// ~300ms)". `FeedbackRouter` has no ability to trigger new capture/analysis
/// on demand — it only ever consumes whatever `ingest(_:at:)` stream is
/// already flowing from the app's capture pipeline (§3.1), in EITHER mode
/// (Setup 30Hz or Monitor 5Hz). Re-plumbing a second, on-demand capture path
/// through the App layer just for Query would duplicate machinery that
/// already exists and wasn't asked for. Resolution: `recordForQuery(_:)`
/// keeps a small ring of the most recently ingested `EngineOutput`s
/// (`Config.feedback.query.burstFrameCount`, default 10 — §0/§11
/// config-keyed), and `performQuery(at:)` summarizes whatever is currently
/// in that ring at the moment the hotkey fires. In Setup mode (30Hz) that
/// ring covers close to the spec's literal ~300ms; in Monitor mode (5Hz) it
/// covers roughly the last 2s instead — still "however many frames the
/// config asks for," still resistant to a single bad frame (§5.3's "so one
/// blink frame can't lie" motivation), just stretched over more wall-clock
/// time in the slower mode. This is a judgment call, not a spec-mandated
/// number, and is the cheapest correct way to make Query "work in any mode,
/// any time" (§5.3) without adding a second capture-triggering path.
extension FeedbackRouter {
  /// Appends `output` to the bounded query-burst ring and trims it to
  /// `feedbackConfig.query.burstFrameCount`. Called from every
  /// `ingest(_:at:)`, unconditionally — including while `isSilenced`, since
  /// silence gates renderer calls only (§7.5), never the analysis
  /// bookkeeping `ingest` otherwise keeps running.
  func recordForQuery(_ output: EngineOutput) {
    recentOutputs.append(output)
    let limit = max(1, feedbackConfig.query.burstFrameCount)
    if recentOutputs.count > limit {
      recentOutputs.removeFirst(recentOutputs.count - limit)
    }
  }

  /// §5.3 Query: the most-used hotkey action (⌘⌃⇧F). Summarizes
  /// `recentOutputs` (see the type-level doc comment above) via
  /// `QueryComposer`, in fixed field order (framing, lighting, gaze, other
  /// people — §5.3: "not most urgent first"), and speaks the result as ONE
  /// composed utterance (`Lexicon.compose(_:)` — see that function's doc
  /// comment for why joining already-fixed phrases is not "generating a
  /// phrase dynamically" in the sense CLAUDE.md/§6.3 forbid).
  ///
  /// Bypasses BOTH the §5.2 Monitor rate limit AND the dwell/N-frame
  /// pipeline entirely — this does not go through `fire(...)`,
  /// `pendingState`, or `confirmedState` at all. Same rationale as the
  /// heartbeat/face-lost ladder's `bypassRateLimit: true`: this is a
  /// "user-initiated pull," not unsolicited Monitor chatter — making the
  /// user wait out a 20s/3min throttle meant for the latter would defeat
  /// the point of a hotkey whose whole job is "on demand, any mode, any
  /// time" (§5.3).
  ///
  /// Interrupts any in-flight utterance for free: `SpeechRendering
  /// .speak(_:)`'s own contract already guarantees preemption (every
  /// conforming renderer "MUST preempt, not queue" — see that protocol's
  /// doc comment), so no extra `stopSpeaking()` call is needed here.
  ///
  /// **Respects `isSilenced`, unlike the rate limit.** §7.5 says manual
  /// silence "silences ALL feedback immediately" with no stated Query
  /// exception, whereas the rate-limit bypass above is specifically about
  /// Monitor's discretionary throttle, a different mechanism. Resolved
  /// conservatively: if the user pressed the silence hotkey, Query stays
  /// silent too, exactly like every other renderer call (`fire` applies the
  /// same `!isSilenced` guard for the same reason). A silenced Query does
  /// NOT update `lastSpokenPhrase` — nothing was actually spoken for
  /// `repeatLastAnnouncement()` to repeat.
  ///
  /// No-ops (speaks nothing, returns `nil`) if `recentOutputs` is empty —
  /// nothing has been analyzed yet (e.g. the hotkey fires before the
  /// capture pipeline has produced a single frame). This is not itself one
  /// of §6.1's silence-ambiguity states (no signal has even been
  /// attempted), so it is left as a quiet no-op rather than inventing a
  /// phrase for it.
  ///
  /// Returns the composed `Lexicon.Phrase` actually spoken (or `nil` for
  /// every no-op case above, including `isSilenced`) purely so callers that
  /// want a text record of what Query said — `replay --query-at` (§5.3's
  /// CLI exercise path) prints it to stdout — don't have to re-derive it by
  /// re-running `QueryComposer` themselves against `FeedbackRouter`'s
  /// private burst buffer. App/'s hotkey-driven call site is free to ignore
  /// the return value entirely.
  @discardableResult
  public func performQuery(at time: ContinuousClock.Instant) async -> Lexicon.Phrase? {
    guard !isSilenced else { return nil }
    guard
      let summary = QueryComposer.summarize(
        burst: recentOutputs, problemsOnly: feedbackConfig.query.problemsOnly)
    else { return nil }
    let phrases = summary.orderedPhrases
    guard !phrases.isEmpty else { return nil }

    let composed = Lexicon.compose(phrases)
    await speech.speak(composed)
    lastSpokenPhrase = composed
    return composed
  }

  /// §8 repeat-last (⌘⌃⇧R): re-speaks whatever `lastSpokenPhrase` currently
  /// holds — the last phrase this router actually spoke, whether from an
  /// ordinary dwell-fired announcement (`fire`, including good-zone entry
  /// and its gaze/roll advisories), a prior `performQuery()`, or even a
  /// prior `repeatLastAnnouncement()` call itself (repeating a repeat is
  /// harmless; there is nothing else it could meaningfully do).
  ///
  /// Bypasses the rate limit the same way `performQuery()` does, for the
  /// identical "user-initiated pull" reason — this does not go through
  /// `fire(...)` at all. Respects `isSilenced` for the same reason
  /// `performQuery()` does. No-ops if nothing has been spoken yet.
  public func repeatLastAnnouncement() async {
    guard !isSilenced, let lastSpokenPhrase else { return }
    await speech.speak(lastSpokenPhrase)
  }
}
