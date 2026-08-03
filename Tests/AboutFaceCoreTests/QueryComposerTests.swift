import Testing

@testable import AboutFaceCore

/// `makeOutput(...)` (`FeedbackRouterTestSupport.swift`) always reports
/// `faceCount: hasFace ? 1 : 0` — there is no parameter for "more than one
/// face," which every other `makeOutput` caller in this test target is fine
/// with. Rebuilds `makeOutput`'s result with `faceCount: 2` instead, for the
/// handful of tests below that need an "other people present" reading on
/// top of whatever `makeOutput` already produced.
private func twoFaceOutput(
  errorX: Float = 0,
  inDeadZone: Bool = true
) -> EngineOutput {
  let base = makeOutput(errorX: errorX, inDeadZone: inDeadZone)
  return EngineOutput(
    analysis: FrameAnalysis(
      timestamp: base.analysis.timestamp,
      signalState: base.analysis.signalState,
      faceCount: 2,
      primary: base.analysis.primary,
      lighting: base.analysis.lighting
    ),
    framing: base.framing
  )
}

/// §5.3 Query mode's pure aggregation logic. Uses `makeOutput(...)` from
/// `FeedbackRouterTestSupport.swift` (same target) to build bursts by hand —
/// no live camera, no `AnalysisEngine`, matching CLAUDE.md's "never write
/// tests that require a live camera to pass in CI."
struct QueryComposerTests {

  // MARK: - Fixed field order (§5.3: "framing, lighting, gaze, other people")

  @Test("orderedPhrases is always framing, then lighting, then gaze, then other people")
  func fixedFieldOrder() throws {
    // Everything wrong at once so all four fields are non-empty, and the
    // "most urgent first" alternative (§5.3 explicitly rules this out) would
    // reorder them if it were driving the output instead.
    let burst = Array(
      repeating: makeOutput(
        signalState: .lowConfidence, errorX: 0.5, inDeadZone: false, gazeOnCamera: false,
        headLevel: false),
      count: 10
    ).map { output in
      // Two other people present, on top of the framing/lighting/gaze problems.
      EngineOutput(
        analysis: FrameAnalysis(
          timestamp: output.analysis.timestamp,
          signalState: output.analysis.signalState,
          faceCount: 2,
          primary: output.analysis.primary,
          lighting: output.analysis.lighting
        ),
        framing: output.framing
      )
    }

    let summary = QueryComposer.summarize(burst: burst, problemsOnly: false)
    let phrases = try #require(summary).orderedPhrases

    // framing (right, since errorX>0), lighting (tooDark), gaze (gazeOff,
    // headTilted), other people (present) — in exactly this order.
    // swift-format wants a trailing comma on the last element of a
    // multiline collection literal; swiftlint's (default-on) trailing_comma
    // rule forbids one. Format wins (see LexiconTests.swift for the same
    // disagreement noted elsewhere in this codebase).
    // swiftlint:disable trailing_comma
    #expect(
      phrases == [
        Lexicon.State.right,
        Lexicon.State.tooDark,
        Lexicon.State.gazeOff,
        Lexicon.State.headTilted,
        Lexicon.State.otherPeoplePresent,
      ])
    // swiftlint:enable trailing_comma
  }

  @Test("field order holds even when every field is fine (problemsOnly: false)")
  func fixedFieldOrderWhenFine() throws {
    let burst = Array(repeating: makeOutput(), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    // swiftlint:disable trailing_comma
    #expect(
      summary.orderedPhrases == [
        Lexicon.State.centered,
        Lexicon.State.lightingFine,
        Lexicon.State.gazeOn,
        Lexicon.State.headLevelState,
        Lexicon.State.otherPeopleNone,
      ])
    // swiftlint:enable trailing_comma
  }

  // MARK: - Aggregation: one blink frame can't lie

  @Test("a single outlier frame in a 10-frame burst is outvoted (framing stays centered)")
  func singleOutlierFrameOutvoted() throws {
    // A genuine, unrelated problem (other people present) keeps the
    // problems-only summary non-empty, so the §6.1-style all-clear fallback
    // doesn't mask what this test actually checks: that the ONE out-of-zone
    // outlier frame does not flip the framing field's own majority vote.
    var burst = Array(repeating: twoFaceOutput(inDeadZone: true), count: 9)
    burst.append(twoFaceOutput(errorX: 0.9, inDeadZone: false))

    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: true))
    #expect(summary.framing.isEmpty)  // still "fine" — omitted under problemsOnly
    #expect(summary.otherPeople == [Lexicon.State.otherPeoplePresent])
  }

  @Test("a single blink frame reporting gaze-off does not flip the gaze majority")
  func singleBlinkFrameOutvotedForGaze() throws {
    var burst = Array(repeating: makeOutput(gazeOnCamera: true), count: 9)
    burst.append(makeOutput(gazeOnCamera: false))

    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: true))
    #expect(summary.gaze.isEmpty)
  }

  @Test("a genuine majority (6 of 10) DOES flip the gaze vote")
  func genuineMajorityFlipsGazeVote() throws {
    var burst = Array(repeating: makeOutput(gazeOnCamera: false), count: 6)
    burst.append(contentsOf: Array(repeating: makeOutput(gazeOnCamera: true), count: 4))

    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.gaze == [Lexicon.State.gazeOff])
  }

  @Test("an exact tie is broken toward reporting the problem")
  func exactTieBreaksTowardProblem() throws {
    var burst = Array(repeating: makeOutput(gazeOnCamera: false), count: 5)
    burst.append(contentsOf: Array(repeating: makeOutput(gazeOnCamera: true), count: 5))

    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.gaze.contains(Lexicon.State.gazeOff))
  }

  @Test("gaze field can report both gaze-off and head-tilted at once")
  func gazeFieldCanCarryBothSubProblems() throws {
    let burst = Array(
      repeating: makeOutput(gazeOnCamera: false, headLevel: false), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.gaze == [Lexicon.State.gazeOff, Lexicon.State.headTilted])
  }

  @Test("framing axis choice uses the median error, not the mean, across the burst")
  func framingUsesMedianNotMean() throws {
    // One wild outlier plus nine consistent small values: the median sits
    // with the consistent cluster, the mean would be dragged toward the
    // outlier. Median x here is ~0.5 (out of zone, right); median y stays
    // 0 (never picked).
    var burst = Array(repeating: makeOutput(errorX: 0.5, inDeadZone: false), count: 9)
    burst.append(makeOutput(errorX: 50.0, inDeadZone: false))

    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.framing == [Lexicon.State.right])
  }

  // MARK: - problemsOnly variant

  @Test("problemsOnly omits every field that is fine, keeping only the framing problem")
  func problemsOnlyOmitsFineFields() throws {
    let burst = Array(repeating: makeOutput(errorX: 0.5, inDeadZone: false), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: true))
    #expect(summary.orderedPhrases == [Lexicon.State.right])
  }

  @Test("problemsOnly with nothing wrong speaks the all-clear fallback, never total silence")
  func problemsOnlyAllClearFallback() throws {
    let burst = Array(repeating: makeOutput(), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: true))
    #expect(summary.orderedPhrases == [Lexicon.State.allClear])
  }

  @Test("problemsOnly still reports noFace/noSignal — those are never 'fine' to omit")
  func problemsOnlyStillReportsFrameLevelProblems() throws {
    let burst = Array(repeating: faceLostOutput(), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: true))
    #expect(summary.orderedPhrases == [Lexicon.State.noFace])
  }

  // MARK: - Frame-level short-circuit (noSignal / noFace)

  @Test("a noSignal-majority burst reports only noSignal, omitting the other three fields")
  func noSignalShortCircuits() throws {
    let burst = Array(repeating: noSignalOutput(), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.orderedPhrases == [Lexicon.State.noSignal])
  }

  @Test("a noFace-majority burst reports only noFace, omitting the other three fields")
  func noFaceShortCircuits() throws {
    let burst = Array(repeating: faceLostOutput(), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.orderedPhrases == [Lexicon.State.noFace])
  }

  @Test("lowConfidence does NOT short-circuit — framing/gaze/other-people still report")
  func lowConfidenceDoesNotShortCircuit() throws {
    let burst = Array(repeating: makeOutput(signalState: .lowConfidence), count: 10)
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    // swiftlint:disable trailing_comma
    #expect(
      summary.orderedPhrases == [
        Lexicon.State.centered, Lexicon.State.tooDark, Lexicon.State.gazeOn,
        Lexicon.State.headLevelState, Lexicon.State.otherPeopleNone,
      ])
    // swiftlint:enable trailing_comma
  }

  // MARK: - Other people

  @Test("other-people field reports present when a majority of frames see 2+ faces")
  func otherPeoplePresentMajority() throws {
    let burst = (0..<10).map { index -> EngineOutput in
      let base = makeOutput()
      return EngineOutput(
        analysis: FrameAnalysis(
          timestamp: base.analysis.timestamp,
          signalState: base.analysis.signalState,
          faceCount: index < 6 ? 2 : 1,
          primary: base.analysis.primary,
          lighting: base.analysis.lighting
        ),
        framing: base.framing
      )
    }
    let summary = try #require(QueryComposer.summarize(burst: burst, problemsOnly: false))
    #expect(summary.otherPeople == [Lexicon.State.otherPeoplePresent])
  }

  // MARK: - Empty burst

  @Test("an empty burst summarizes to nil")
  func emptyBurstIsNil() {
    #expect(QueryComposer.summarize(burst: [], problemsOnly: false) == nil)
  }

  // MARK: - Shared aggregation primitives, directly

  @Test("majorityIsProblem: strict majority wins, exact tie favors true")
  func majorityIsProblemPrimitive() {
    #expect(QueryComposer.majorityIsProblem([true, true, false]))
    #expect(!QueryComposer.majorityIsProblem([true, false, false]))
    #expect(QueryComposer.majorityIsProblem([true, false]))  // tie -> problem
    #expect(!QueryComposer.majorityIsProblem([]))
  }

  @Test("median: odd count picks the middle, even count averages the two middles")
  func medianPrimitive() {
    #expect(QueryComposer.median([1, 2, 3]) == 2)
    #expect(QueryComposer.median([1, 2, 3, 4]) == 2.5)
    #expect(QueryComposer.median([5]) == 5)
    #expect(QueryComposer.median([]) == 0)
  }

  @Test("majoritySignalState: four-way tie breaks toward the most severe state")
  func majoritySignalStateSeverityTieBreak() {
    let allFour: [SignalState] = [.noSignal, .noFace, .lowConfidence, .ok]
    #expect(QueryComposer.majoritySignalState(allFour) == .noSignal)

    let threeWay: [SignalState] = [.noFace, .lowConfidence, .ok]
    #expect(QueryComposer.majoritySignalState(threeWay) == .noFace)
  }
}
