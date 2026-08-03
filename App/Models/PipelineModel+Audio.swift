import AboutFaceCore

/// The Setup-mode feedback chain (spec §5.1, §13 Phase 3): `AudioRenderer` +
/// `SpeechRenderer` + `FeedbackRouter(mode: .setup)`, fed from the same
/// per-frame stream that drives the UI in `PipelineModel.swift`'s
/// `start()`. Split out purely to keep file size manageable (matching the
/// `PipelineModel.swift`/`+Config.swift`/`+Target.swift` split precedent
/// documented there); everything here is still `PipelineModel`'s own
/// implementation, not a separate public surface.
///
/// ## Degradation, not crashes
///
/// `AudioRenderer.start()` can throw — no audio device, which is true of
/// every CI runner and any Mac with output disconnected. Per the task
/// brief, that MUST NOT crash the app or stop the camera/analysis pipeline:
/// `startFeedbackChain()` swallows the failure, sets
/// `audioUnavailableMessage` for the UI, and still wires up the
/// `FeedbackRouter`. An `AudioRenderer` whose `AVAudioEngine` never started
/// just holds an idle `RenderState` — the real-time render callback is
/// never invoked, so `update`/`play`/`setSilenced` are harmless no-ops —
/// meaning the rest of the chain (dwell/hysteresis/priority state machine,
/// speech) keeps running exactly as designed, it just produces no sound.
/// Speech is largely independent of `AVAudioEngine` (its own
/// `AVSpeechSynthesizer`), so it stays wired regardless of whether the
/// audio engine came up.
extension PipelineModel {

  func startFeedbackChain() async {
    audioUnavailableMessage = nil

    let audio = AudioRenderer(config: config.audio, mode: .realtime)
    let speech = SpeechRenderer(config: config.speech)
    let router = FeedbackRouter(audio: audio, speech: speech, config: config, mode: .setup)

    do {
      try await audio.start()
    } catch {
      audioUnavailableMessage =
        "Audio feedback is unavailable (\(error)). Framing, lighting, and other signals are "
        + "still visible in the Signals list below."
    }

    audioRenderer = audio
    speechRenderer = speech
    feedbackRouter = router
    await pushSilencedState()
  }

  func stopFeedbackChain() async {
    await feedbackRouter?.setSilenced(true)
    await speechRenderer?.stopSpeaking()
    await audioRenderer?.stop()
    feedbackRouter = nil
    speechRenderer = nil
    audioRenderer = nil
    audioUnavailableMessage = nil
  }

  /// Routes one frame to the feedback chain. Called from `start()`'s
  /// per-frame consume loop directly (NOT from the throttled `ingest(_:)`
  /// this file's sibling defines) — continuous sonification (§6.2) is the
  /// fast correction loop the whole feature exists for; throttling it down
  /// to the ~10 Hz/~2 Hz UI cadence would defeat that.
  func feedFeedbackChain(_ output: EngineOutput) async {
    guard let feedbackRouter else { return }
    await feedbackRouter.ingest(output, at: .now)
  }

  // MARK: - Feedback toggle / manual silence (§7.5)

  /// The Setup window's "Feedback" toggle (task brief §5.1): on by default
  /// whenever the pipeline runs, independent of the §7.5 instant-mute below.
  public func setFeedbackEnabled(_ enabled: Bool) {
    feedbackEnabled = enabled
    Task { await pushSilencedState() }
  }

  /// The in-app stand-in for §7.5's manual silence key (⌘⌃⇧/, wired as a
  /// SwiftUI `.keyboardShortcut` in `SetupWindowView`). Spec §8 wants this
  /// as a GLOBAL `RegisterEventHotKey` binding so it works while About Face
  /// isn't the focused app — that lands with the rest of §8's hotkey work
  /// in Phase 4/5. A SwiftUI keyboard shortcut only fires while one of this
  /// app's own windows has focus, which is why this is documented as a
  /// stand-in rather than the real thing. Kept as its own method (rather
  /// than a plain `Binding<Bool>`) so both the Setup window's button and
  /// its keyboard shortcut share one code path.
  public func toggleSilence() {
    isSilenced.toggle()
    Task { await pushSilencedState() }
  }

  // MARK: - §5.3 Query / §8 repeat-last (App/HotkeyCenter.swift's hotkey call sites)

  /// ⌘⌃⇧F: §5.3 Query. No-ops if the feedback chain isn't running (no
  /// camera started yet) — same "nothing to do yet" posture as
  /// `captureCurrentPositionAsTarget()`.
  public func performQuery() {
    guard let feedbackRouter else { return }
    Task { await feedbackRouter.performQuery(at: .now) }
  }

  /// ⌘⌃⇧R: §8 repeat last announcement.
  public func repeatLastAnnouncement() {
    guard let feedbackRouter else { return }
    Task { await feedbackRouter.repeatLastAnnouncement() }
  }

  /// §7.5: "MUST take effect within one audio buffer — cut the render, do
  /// not wait for the current utterance to finish." Both `feedbackEnabled`
  /// (the Setup window's master toggle) and `isSilenced` (the instant mute)
  /// collapse onto the SAME `FeedbackRouter.setSilenced(_:)` call —
  /// `FeedbackRouter`'s own doc comment guarantees analysis keeps running
  /// underneath regardless of which one is set, so "feedback off" and
  /// "manually silenced" are indistinguishable to the renderer; only the UI
  /// needs to know which of the two the user actually picked.
  func pushSilencedState() async {
    await feedbackRouter?.setSilenced(isSilenced || !feedbackEnabled)
  }

  // MARK: - Live config push (§9: "changing any slider visibly changes engine behavior")

  /// Called from `PipelineModel+Config.swift`'s `updateConfig(_:)` for the
  /// feedback-chain half of that push (the `AnalysisEngine` half stays in
  /// that file). `FeedbackRouter.updateConfig`/`updateFeedbackConfig` and
  /// `SpeechRenderer.updateConfig` are all cheap in-place `var` writes —
  /// safe to call on every keystroke of an unrelated slider.
  /// `AudioRenderer.updateConfig` briefly restarts the render engine (see
  /// its doc comment), so it is gated on the `audio` sub-struct having
  /// actually changed, to avoid an audible restart on every drag of, say, a
  /// target-framing slider that has nothing to do with audio.
  func pushConfigToFeedbackChain(old: Config, new: Config) {
    if let feedbackRouter {
      Task {
        await feedbackRouter.updateConfig(new)
        await feedbackRouter.updateFeedbackConfig(new.feedback)
      }
    }
    if let speechRenderer {
      Task { await speechRenderer.updateConfig(new.speech) }
    }
    if let audioRenderer, old.audio != new.audio {
      Task { await audioRenderer.updateConfig(new.audio) }
    }
  }
}
