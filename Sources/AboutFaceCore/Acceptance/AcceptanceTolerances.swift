/// Timing slack `AcceptanceEvaluator` allows around each §7.3 rung's
/// expected elapsed time. Per §0/§11 ("no numeric threshold is hardcoded"),
/// this is never a magic number buried in the matching algorithm — every
/// field here is either a caller-supplied parameter or derived from the same
/// `Config`/`FeedbackConfig` the router being evaluated actually ran with,
/// via `derived(from:awayPollIntervalMs:)` below.
public struct AcceptanceTolerances: Sendable, Equatable {
  /// Slack allowed around a rung's expected elapsed time, milliseconds.
  /// Rung timestamps are recorded to the millisecond, but the state machine
  /// producing the underlying transition has its own real latency — §7.2's
  /// N-frame confirmation must complete before `FeedbackRouter`'s ladder
  /// timer even starts counting a frame as "the episode began" — so an
  /// on-schedule rung can legitimately land a little later than the raw
  /// configured delay without that being a behavioral bug. `default` picks
  /// a conservative flat value for callers with no `Config` to derive from
  /// (e.g. a synthetic unit test); `derived(from:awayPollIntervalMs:)` is
  /// the real run's source of truth.
  public var rungTimingToleranceMs: Int

  /// How often the recorder polls `FeedbackRouter.isUserLikelyAway()` (PR
  /// brief: "poll it (~1 Hz)"). Rung 3's recorded transition timestamp can
  /// lag the router's true internal transition by up to one poll interval,
  /// which is a DIFFERENT source of slack than `rungTimingToleranceMs`
  /// (a property of the polling mechanism itself, not of the state machine
  /// being observed) — kept as its own field rather than folded into one
  /// combined number so a report can say which kind of slack it used.
  public var awayPollIntervalMs: Int

  public init(rungTimingToleranceMs: Int, awayPollIntervalMs: Int) {
    self.rungTimingToleranceMs = rungTimingToleranceMs
    self.awayPollIntervalMs = awayPollIntervalMs
  }

  /// A caller with no `Config` in hand (e.g. a unit test asserting the
  /// evaluator's own matching logic in isolation) — 250ms flat, plus a
  /// 1000ms `awayPollIntervalMs` matching the PR brief's "~1 Hz" polling
  /// cadence. Real acceptance runs should prefer `derived(from:
  /// awayPollIntervalMs:)` instead.
  public static let conservativeDefault = AcceptanceTolerances(
    rungTimingToleranceMs: 250, awayPollIntervalMs: 1000)

  /// Derives `rungTimingToleranceMs` from the SAME `Config` the session
  /// under evaluation actually ran with: §7.2's N-frame confirmation
  /// requirement, expressed as time, at Monitor's analysis rate — e.g. 3
  /// frames at 5Hz is 600ms of latency the ladder timer cannot start
  /// counting through. `awayPollIntervalMs` is a caller-supplied parameter,
  /// not derived from `Config` — the poller's cadence is a property of the
  /// RECORDER (`aboutface-cli acceptance`'s own `--away-poll-interval-
  /// seconds`), not of the shipping app's `Config`, so there is nothing in
  /// `Config` to read it from; see that command's doc comment.
  public static func derived(from config: Config, awayPollIntervalMs: Int) -> AcceptanceTolerances {
    let analysisHz = config.camera.monitor.analysisHz ?? 5.0
    let confirmationLatencyMs =
      analysisHz > 0 ? Int((Double(config.feedback.nFrameMonitor) / analysisHz) * 1000) : 0
    // Never let a degenerate Config (e.g. nFrameMonitor: 0) collapse this to
    // zero and make ordinary jitter read as a failure — floor at the flat
    // default's own value rather than inventing a second unexplained
    // constant.
    let toleranceMs = max(confirmationLatencyMs, conservativeDefault.rungTimingToleranceMs)
    return AcceptanceTolerances(
      rungTimingToleranceMs: toleranceMs, awayPollIntervalMs: awayPollIntervalMs)
  }
}
