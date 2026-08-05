import AboutFaceCore

/// Polls `FeedbackRouter.isUserLikelyAway()` at a fixed cadence and records
/// every observed VALUE CHANGE to `recorder` — the only way this instrument
/// can ever see §7.3's rung-3 STOP, which "fires NO sound at all... It is
/// detectable only as the absence of events, so it cannot be recovered from
/// an event stream" (PR brief). `isUserLikelyAway()`'s own doc comment
/// names exactly this kind of polling observer as its intended consumer.
///
/// `pollIntervalSeconds` is a caller-supplied parameter
/// (`aboutface-cli acceptance --away-poll-interval-seconds`, default ~1Hz
/// per the PR brief), not a `Config` field — it is a property of THIS
/// diagnostic instrument, not of shipping feedback behavior, the same
/// reasoning `LiveCommand`'s `watchdogGraceSeconds` doc comment gives for
/// its own non-`Config` constant.
///
/// A plain `final class`, not an actor: the only mutable state
/// (`lastObserved`) is touched exclusively from within `run()`'s own loop,
/// on whichever task calls it — there is no concurrent access to
/// synchronize against, so an actor would add isolation overhead with
/// nothing to isolate.
final class AcceptanceAwayPoller: Sendable {
  private let router: FeedbackRouter
  private let recorder: AcceptanceEventRecorder
  private let pollIntervalSeconds: Double

  init(router: FeedbackRouter, recorder: AcceptanceEventRecorder, pollIntervalSeconds: Double) {
    self.router = router
    self.recorder = recorder
    self.pollIntervalSeconds = pollIntervalSeconds
  }

  /// Runs until the enclosing `Task` is cancelled — the CLI command cancels
  /// this alongside the resource sampler once the session ends, whether it
  /// completed normally or stopped early (see `AcceptanceCommand.swift`).
  func run() async {
    var lastObserved: Bool?
    while !Task.isCancelled {
      let current = await router.isUserLikelyAway()
      if current != lastObserved {
        lastObserved = current
        await recorder.recordUserLikelyAway(current)
      }
      do {
        try await Task.sleep(for: .seconds(pollIntervalSeconds))
      } catch {
        return
      }
    }
  }
}
