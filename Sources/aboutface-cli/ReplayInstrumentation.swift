import AboutFaceCore

/// `Replay --audio`'s one-shot, timestamp-triggered instrumentation:
/// `--silence-at` (§7.5) and `--query-at` (§5.3). Split out of
/// `ReplayCommand.swift` purely to keep that file's
/// `runWithAudio(source:engine:)` under SwiftLint's
/// `function_body_length`/`type_body_length` limits — same reasoning
/// `ReplayTruth.swift`'s own doc comment gives for its split.
extension Replay {
  /// Engages §7.5 manual silence exactly once, the first time `--audio`'s
  /// per-frame loop reaches `silenceAt` (`Replay`'s own `@Option`) seconds
  /// into the clip. `engaged` is the caller's loop-local flag, threaded
  /// through by `inout` for the same reason `maybeFireQuery(router
  /// :timestampSeconds:fired:)` below is.
  func maybeEngageSilence(
    router: FeedbackRouter, timestampSeconds: Double, engaged: inout Bool
  ) async {
    guard let silenceAt, !engaged, timestampSeconds >= silenceAt else { return }
    engaged = true
    await router.setSilenced(true)
    print("-- §7.5 manual silence engaged at t=\(String(format: "%.2f", silenceAt))s --")
  }

  /// Fires §5.3 Query exactly once, the first time `--audio`'s per-frame
  /// loop reaches `queryAt` (`Replay`'s own `@Option`) seconds into the
  /// clip. `fired` is the caller's loop-local flag, threaded through by
  /// `inout` rather than stored on `self` — `Replay` is a value-type
  /// `ParsableCommand` re-parsed fresh per invocation, but `run()`'s
  /// loop-local `var`s are the idiomatic place for this codebase to keep
  /// one-shot-per-run state (see `lastReportedSecond` right next to it in
  /// `runWithAudio`).
  func maybeFireQuery(
    router: FeedbackRouter, timestampSeconds: Double, fired: inout Bool
  ) async {
    guard let queryAt, !fired, timestampSeconds >= queryAt else { return }
    fired = true
    let stamp = String(format: "%.2f", queryAt)
    if let composed = await router.performQuery(at: .now) {
      print("-- §5.3 Query at t=\(stamp)s: \(composed.text) --")
    } else {
      print("-- §5.3 Query at t=\(stamp)s: (nothing to say) --")
    }
  }

  /// Shared trailing summary block for both `runPlain(source:engine:)` and
  /// `runWithAudio(source:engine:)` — moved here (rather than staying a
  /// `private` method on `Replay` itself) purely to keep
  /// `ReplayCommand.swift` under SwiftLint's `type_body_length`; it has no
  /// connection to the `--silence-at`/`--query-at` instrumentation above
  /// beyond living in the same size-driven split.
  func printSummary(
    frameCount: Int,
    stateHistogram: [String: Int],
    absErrorXSum: Float,
    absErrorYSum: Float,
    errorSampleCount: Int
  ) {
    print("")
    print("frames=\(frameCount)")
    for (state, count) in stateHistogram.sorted(by: { $0.key < $1.key }) {
      print("  \(state)=\(count)")
    }
    if errorSampleCount > 0 {
      let meanAbsX = absErrorXSum / Float(errorSampleCount)
      let meanAbsY = absErrorYSum / Float(errorSampleCount)
      print(
        "meanAbsError x=\(String(format: "%.4f", meanAbsX)) y=\(String(format: "%.4f", meanAbsY)) "
          + "(over \(errorSampleCount) frames with a detected face)")
    } else {
      print("meanAbsError: no frames with a detected face")
    }
  }
}
