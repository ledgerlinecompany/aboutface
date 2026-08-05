import AboutFaceCore

/// Timestamps every discrete `AudioEvent`, spoken `Lexicon.Phrase`, and
/// `FeedbackRouter.isUserLikelyAway()` transition observed during an
/// `aboutface-cli acceptance` run (§13 Phase 4), for `AcceptanceEvaluator`
/// to judge afterward. An actor — the same three call sites
/// (`FeedbackRouter.addEventSubscriber(_:)`'s dispatch, the speech
/// decorator, and the away-poller Task) run concurrently, so appends to
/// `events` need real synchronization, not just single-threaded discipline.
///
/// ## Time is injected, always
///
/// `start`, an explicit `ContinuousClock.Instant` captured once by the CLI
/// command before anything is wired up, is the sole reference every
/// timestamp here is measured against — the same discipline
/// `FeedbackRouter` documents on itself (`FeedbackRouter.swift`'s
/// "Time is injected, always" section) and for the same reason: it is what
/// makes a recorded log reproducible from the sequence of calls alone, and
/// what lets `AcceptanceEvaluatorTests` build fixtures with the exact same
/// millisecond arithmetic a real run would produce.
actor AcceptanceEventRecorder: EventSubscriber {
  private let start: ContinuousClock.Instant
  private var events: [AcceptanceEvent] = []

  init(start: ContinuousClock.Instant) {
    self.start = start
  }

  /// `EventSubscriber` (§6.4): `FeedbackRouter.addEventSubscriber(_:)`
  /// notifies every registered subscriber AFTER `audio.play(_:)` for the
  /// same event, so the real `AudioRenderer` still plays the actual sound
  /// (the maintainer needs to hear rungs 1/2 and the recovery earcon to
  /// know the run is behaving, same as any other session) while this
  /// records it too.
  func handle(_ event: AudioEvent) async {
    append(.audioEvent(event))
  }

  /// Called by `AcceptanceSpeechRecorder` (its own file), which wraps the
  /// real `SpeechRendering` implementation and records BEFORE forwarding
  /// each call — see that type's doc comment for why a decorator is the
  /// only way to see spoken phrases without changing `SpeechRendering`,
  /// `FeedbackRouter`, or any renderer type in `AboutFaceCore`.
  func recordSpoken(_ phrase: Lexicon.Phrase) {
    append(.spokenPhrase(phrase))
  }

  /// Called by `AcceptanceAwayPoller` (its own file) on every observed
  /// VALUE CHANGE of `FeedbackRouter.isUserLikelyAway()` — never once per
  /// poll tick, so this log already reads as "transitions," matching
  /// `AcceptanceEvent.Kind.userLikelyAway`'s own contract.
  func recordUserLikelyAway(_ value: Bool) {
    append(.userLikelyAway(value))
  }

  func snapshot() -> [AcceptanceEvent] {
    events
  }

  private func append(_ kind: AcceptanceEvent.Kind) {
    let elapsedMs = AcceptanceElapsed.milliseconds(from: start, to: .now)
    events.append(AcceptanceEvent(elapsedMs: elapsedMs, kind: kind))
  }
}
