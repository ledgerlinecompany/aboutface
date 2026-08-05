import AboutFaceCore

/// Wraps a real `SpeechRendering` implementation (the same `SpeechRenderer`
/// type `PipelineModel`/`replay --audio` construct), recording every phrase
/// spoken BEFORE forwarding the call, unchanged, to the underlying renderer.
///
/// `EventSubscriber` (§6.4) is deliberately narrow — "kept intentionally to
/// one method," discrete `AudioEvent`s only, with no notion of speech at
/// all (see that protocol's own doc comment). This decorator is therefore
/// the ONLY way `aboutface-cli acceptance` can see spoken phrases without
/// changing `SpeechRendering`, `FeedbackRouter`, or any renderer type in
/// `AboutFaceCore` — exactly what the PR brief asks for.
///
/// An actor, not a plain struct: `FeedbackRouter` holds this as `any
/// SpeechRendering` and calls `speak`/`stopSpeaking` from its own actor
/// context, so this needs the same isolation guarantee `SpeechRenderer`
/// itself provides (see that type's own doc comment on why it is an
/// actor).
actor AcceptanceSpeechRecorder: SpeechRendering {
  private let underlying: any SpeechRendering
  private let recorder: AcceptanceEventRecorder

  init(wrapping underlying: any SpeechRendering, recorder: AcceptanceEventRecorder) {
    self.underlying = underlying
    self.recorder = recorder
  }

  func speak(_ phrase: Lexicon.Phrase) async {
    // Records THEN forwards (PR brief) — the timestamp reflects the
    // instant `FeedbackRouter` decided to speak, not whenever
    // `AVSpeechSynthesizer` gets around to starting the utterance.
    await recorder.recordSpoken(phrase)
    await underlying.speak(phrase)
  }

  func stopSpeaking() async {
    await underlying.stopSpeaking()
  }
}
