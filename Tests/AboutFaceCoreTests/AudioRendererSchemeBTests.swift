import Testing

@testable import AboutFaceCore

/// §6.2 Scheme B — ARRIVAL HERALD REDESIGN (2026-08-02 tuning round 2d,
/// maintainer-approved Option B). See `RenderState+SchemeB.swift`'s
/// top-level doc comment for the full "why": round 2c's crescendo could
/// produce a genuine zero-click arrival whenever DISTANCE happened to be
/// the last axis to settle (the old gate demanded distance be right BEFORE
/// any click could sound at all). Scheme B no longer heralds fine-XY
/// refinement alone — it heralds proximity to the FULL three-axis settle,
/// via `closeness = min(xyCloseness, distanceCloseness)`
/// (`RenderState.schemeBSampleIfActive`), with a `schemeBRateCurve`-shaped
/// ramp (`beatHz = maxBeatHz × closeness ^ rateCurve`,
/// `RenderState.schemeBSample`) pacing how that closeness maps to rate.
///
/// Every test here isolates the B-layer by zeroing
/// `positional.toneGain` (silencing Scheme A's continuous tone entirely —
/// `carrier * amplitude == 0` regardless of carrier shape), so the render
/// buffer contains ONLY Scheme B's contribution.
struct AudioRendererSchemeBTests {
  private static let sampleRate = 48000.0

  /// `refinementFraction`/`maxBeatHz`/`fullRateAtError`/`distanceEngageError`
  /// /`rateCurve` default to the SHIPPED defaults (`Config.Audio.defaults`,
  /// round-2d: `schemeBRefinementFraction` `0.8`, `schemeBDistanceEngageError`
  /// `0.15`, `schemeBRateCurve` `2.0`) so tests exercise real production
  /// numbers unless a test needs a specific override to keep its hand-derived
  /// arithmetic clean (several below use `0.5` for `refinementFraction`
  /// purely so `engageXY - fullRateXY` is a round `0.095`,  not because
  /// `0.5` is meaningful on its own).
  private func schemeBOnlyConfig(
    refinementFraction: Double = 0.8,
    maxBeatHz: Double = 10,
    fullRateAtError: Double = 0.08,
    distanceEngageError: Double = 0.15,
    rateCurve: Double = 2.0
  ) -> Config.Audio {
    var config = Config.Audio.defaults
    config.positional.toneGain = 0
    config.scheme.schemeBEnabled = true
    config.scheme.schemeBRefinementFraction = refinementFraction
    config.scheme.schemeBMaxBeatHz = maxBeatHz
    config.scheme.schemeBFullRateAtError = fullRateAtError
    config.scheme.schemeBDistanceEngageError = distanceEngageError
    config.scheme.schemeBRateCurve = rateCurve
    return config
  }

  /// Counts click transients: rising edges from (near-)exact silence to
  /// nonzero output. `RenderState.schemeBSample`'s click envelope is
  /// exactly `0` at every sample outside its own duration window (see
  /// `clickSample`'s `guard t <= durationSeconds else { return 0 }`), so
  /// unlike `AudioRendererTestSupport.envelopeDipCount` (which needs a
  /// block-RMS threshold because it's counting dips in a continuous
  /// carrier), a simple per-sample zero/nonzero transition count is exact
  /// here.
  private func clickCount(_ samples: [Float]) -> Int {
    var count = 0
    var inClick = false
    for sample in samples {
      let above = abs(sample) > 1e-6
      if above, !inClick { count += 1 }
      inClick = above
    }
    return count
  }

  /// Renders `config` against a single steady-state target and returns the
  /// left-channel click count (see `clickTrainIsCentered` for the
  /// left-equals-right invariant this relies on being safe to check on one
  /// channel only).
  private func clicks(
    config: Config.Audio, errorY: Float, distanceError: Float, total: Int = 48000
  ) async throws -> Int {
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(
          errorX: 0, errorY: errorY, distanceError: distanceError, inDeadZone: false)
      )
    }
    let (left, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: total)
    return clickCount(left)
  }

  // MARK: - Lagging-axis governance (closeness = min(xyCloseness, distanceCloseness))

  @Test("XY-perfect + distance far ⇒ silence (the smooth-gate replacement for the old binary gate)")
  func xyPerfectDistanceFarProducesSilence() async throws {
    // schemeBOnlyConfig() defaults: engageXY = 0.8 × 0.35 = 0.28,
    // fullRateXY = 0.08. XY perfect (magnitude 0) ⇒ xyCloseness clamps to 1.
    // distanceCloseness: engageDist 0.15, fullRateDist 0.02 (default
    // `distance.audibleRampStartError`), rampSpan 0.13. distanceError 0.2 is
    // beyond engageDist ⇒ (0.15 - 0.2)/0.13 < 0 ⇒ clamped to 0.
    // closeness = min(1, 0) = 0 ⇒ `schemeBSampleIfActive` returns nil ⇒
    // genuine silence, produced by the smooth min() rather than a guard.
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0, distanceError: 0.2)
    #expect(count == 0)
  }

  @Test("XY-perfect + distance mid-ramp ⇒ sparse clicks, governed by the lagging distance axis")
  func xyPerfectDistanceMidRampProducesSparseClicks() async throws {
    // Same engage/full-rate numbers as above. distanceError 0.08 is inside
    // (fullRateDist 0.02, engageDist 0.15): distanceCloseness =
    // (0.15 - 0.08)/0.13 ≈ 0.538. xyCloseness clamps to 1 (XY perfect), so
    // closeness = min(1, 0.538) = 0.538 — the DISTANCE axis governs even
    // though XY is already perfect (the whole point of the round-2d
    // redesign). Shaped by the default curve (2.0): 0.538² ≈ 0.290 ⇒
    // beatHz ≈ 2.9 Hz — a handful of clicks over 1s, not a fast train.
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0, distanceError: 0.08)
    #expect(count >= 1, "distance mid-ramp should still click, got \(count)")
    #expect(count <= 5, "distance mid-ramp should be sparse (≈2.9 Hz), got \(count)")
  }

  @Test("Both axes near their full-rate thresholds ⇒ fast click train")
  func bothAxesNearFullRateProduceFastClicks() async throws {
    // xyCloseness: magnitude 0.085 (just outside fullRateXY 0.08, well
    // inside engageXY 0.28): (0.28 - 0.085)/0.2 ≈ 0.975.
    // distanceCloseness: distanceError 0.025 (just outside fullRateDist
    // 0.02, well inside engageDist 0.15): (0.15 - 0.025)/0.13 ≈ 0.962.
    // closeness = min(0.975, 0.962) ≈ 0.962; shaped (curve 2.0):
    // 0.962² ≈ 0.925 ⇒ beatHz ≈ 9.25 Hz — near the 10 Hz ceiling.
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0.085, distanceError: 0.025)
    #expect(count >= 6, "both axes near full rate should click fast (≈9.25 Hz), got \(count)")
  }

  @Test("Distance-perfect + XY mid ⇒ rate governed by XY, not by how perfect distance is")
  func distancePerfectXYMidGovernedByXY() async throws {
    // refinementFraction 0.5 for round numbers: engageXY = 0.5 × 0.35 =
    // 0.175, fullRateXY 0.08, rampSpan 0.095. magnitude 0.13 (inside the
    // zone): xyCloseness = (0.175 - 0.13)/0.095 ≈ 0.474.
    // distanceEngageError stays default 0.15, fullRateDist 0.02, rampSpan
    // 0.13. Two distance values BOTH keep distanceCloseness above
    // xyCloseness (so XY, not distance, governs the min):
    //   distanceError 0     ⇒ distanceCloseness clamps to 1
    //   distanceError 0.05  ⇒ distanceCloseness = (0.15-0.05)/0.13 ≈ 0.769
    // Both ≥ 0.474, so closeness = min(...) = xyCloseness ≈ 0.474 in BOTH
    // cases — identical beatHz, hence identical (deterministic) click
    // counts, regardless of which "distance is fine" value is used.
    let config = schemeBOnlyConfig(refinementFraction: 0.5)
    let countA = try await clicks(config: config, errorY: 0.13, distanceError: 0)
    let countB = try await clicks(config: config, errorY: 0.13, distanceError: 0.05)
    #expect(
      countA == countB, "XY should govern regardless of distance slack: \(countA) vs \(countB)")
    #expect(countA >= 1, "mid-zone XY should still click, got \(countA)")
  }

  // MARK: - Curve pacing (beatHz = maxBeatHz × closeness ^ schemeBRateCurve)

  @Test("At closeness 0.5, curve 2.0 gives max × 0.25 — roughly half the linear (curve 1.0) rate")
  func rateCurveSquaresClosenessAtHalfway() async throws {
    // refinementFraction 0.5 ⇒ engageXY 0.175, fullRateXY 0.08, rampSpan
    // 0.095. magnitude 0.1275 ⇒ xyCloseness = (0.175 - 0.1275)/0.095 =
    // 0.0475/0.095 = 0.5 exactly. distanceError 0 ⇒ distanceCloseness
    // clamps to 1 ⇒ closeness = min(1, 0.5) = 0.5.
    // curve 2.0 (squared):  beatHz = 10 × 0.5² = 10 × 0.25 = 2.5 Hz.
    // curve 1.0 (linear):   beatHz = 10 × 0.5¹ = 10 × 0.5  = 5.0 Hz.
    // Over 2s: ≈5 clicks (squared) vs ≈10 clicks (linear) — the squared
    // curve keeps the train roughly half as dense at the halfway point,
    // exactly the "sparse longer, fast only at the very end" pacing the
    // maintainer asked for.
    let squaredConfig = schemeBOnlyConfig(refinementFraction: 0.5, rateCurve: 2.0)
    let linearConfig = schemeBOnlyConfig(refinementFraction: 0.5, rateCurve: 1.0)
    let squaredCount = try await clicks(
      config: squaredConfig, errorY: 0.1275, distanceError: 0, total: 96000)
    let linearCount = try await clicks(
      config: linearConfig, errorY: 0.1275, distanceError: 0, total: 96000)

    #expect(
      squaredCount < linearCount, "curve 2.0 should be sparser than curve 1.0 at closeness 0.5")
    #expect(
      Double(linearCount) >= Double(squaredCount) * 1.5,
      "linear (≈10 clicks/2s) should run roughly 2× squared (≈5 clicks/2s): \(linearCount) vs \(squaredCount)"
    )
  }

  @Test("curve 1.0 reproduces the linear mapping, regardless of which axis drives closeness")
  func rateCurveOfOneReproducesLinearMappingSymmetrically() async throws {
    // Two routes to the SAME closeness (0.5) with curve 1.0, one driven by
    // XY, one driven by distance — both must yield the identical beatHz
    // (10 × 0.5 = 5 Hz) since `pow(closeness, 1) == closeness` and the
    // formula treats `min(xyCloseness, distanceCloseness)` symmetrically.
    //
    // Route A (XY-driven): refinementFraction 0.5 ⇒ engageXY 0.175,
    // fullRateXY 0.08, rampSpan 0.095. magnitude 0.1275 ⇒ xyCloseness =
    // 0.5 (as above). distanceError 0 ⇒ distanceCloseness clamps to 1 ⇒
    // closeness = 0.5.
    //
    // Route B (distance-driven): XY perfect (magnitude 0) ⇒ xyCloseness
    // clamps to 1. distanceEngageError default 0.15, fullRateDist 0.02,
    // rampSpan 0.13. distanceError 0.085 ⇒ distanceCloseness =
    // (0.15 - 0.085)/0.13 = 0.065/0.13 = 0.5 exactly ⇒ closeness =
    // min(1, 0.5) = 0.5.
    let config = schemeBOnlyConfig(refinementFraction: 0.5, rateCurve: 1.0)
    let xyDrivenCount = try await clicks(
      config: config, errorY: 0.1275, distanceError: 0, total: 96000)
    let distanceDrivenCount = try await clicks(
      config: config, errorY: 0, distanceError: 0.085, total: 96000)

    #expect(
      xyDrivenCount == distanceDrivenCount,
      "same closeness via either axis, curve 1.0, must give the same rate: \(xyDrivenCount) vs \(distanceDrivenCount)"
    )
    #expect(xyDrivenCount >= 6, "5 Hz over 2s should give ≈10 clicks, got \(xyDrivenCount)")
  }

  // MARK: - Full rate at arrival (production defaults)

  @Test("Both axes at their own full-rate thresholds ⇒ ~max rate (production defaults)")
  func bothAxesAtFullRateThresholdReachMaxRate() async throws {
    // Uses the SHIPPED defaults verbatim (schemeBRefinementFraction 0.8,
    // schemeBFullRateAtError 0.08, schemeBDistanceEngageError 0.15,
    // distance.audibleRampStartError 0.02): magnitude AT fullRateXY (0.08)
    // ⇒ xyCloseness = (0.28 - 0.08)/(0.28 - 0.08) = 1 exactly.
    // distanceError AT distance.audibleRampStartError (0.02) ⇒
    // distanceCloseness = (0.15 - 0.02)/(0.15 - 0.02) = 1 exactly.
    // closeness = min(1, 1) = 1 ⇒ beatHz = 10 × 1^curve = 10 Hz — the
    // ceiling, regardless of curve — exactly where the crescendo should
    // peak just before dead-zone entry cuts everything (§6.2).
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0.08, distanceError: 0.02)
    #expect(count >= 8, "both axes at full-rate threshold should click at ≈10 Hz, got \(count)")
  }

  // MARK: - Outside engagement (either axis) ⇒ genuine silence

  @Test("XY outside its engagement envelope ⇒ silence, even with distance perfect")
  func xyOutsideEngagementProducesSilence() async throws {
    // engageXY = 0.8 × 0.35 = 0.28. magnitude 0.3 is outside it ⇒
    // xyCloseness clamps to 0 ⇒ closeness = min(0, anything) = 0, no
    // matter how good distance is (distanceError 0 ⇒ distanceCloseness
    // clamps to 1).
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0.3, distanceError: 0)
    #expect(count == 0)
  }

  @Test("Distance outside its engagement envelope ⇒ silence, even with XY perfect")
  func distanceOutsideEngagementProducesSilence() async throws {
    // engageDist = 0.15 (default schemeBDistanceEngageError). distanceError
    // 0.25 is well outside it ⇒ distanceCloseness clamps to 0 ⇒ closeness
    // = min(anything, 0) = 0. XY perfect (magnitude 0) doesn't matter —
    // this is the "distance far ⇒ silence" case from the design brief,
    // reached via the smooth min() rather than the deleted binary gate.
    let config = schemeBOnlyConfig()
    let count = try await clicks(config: config, errorY: 0, distanceError: 0.25)
    #expect(count == 0)
  }

  // MARK: - Flag off = no B-layer output (unchanged)

  @Test("schemeBEnabled = false produces no B-layer output even with both axes engaged")
  func flagOffProducesNoOutput() async throws {
    var config = schemeBOnlyConfig()
    config.scheme.schemeBEnabled = false
    let count = try await clicks(config: config, errorY: 0.03, distanceError: 0)
    #expect(count == 0)
  }

  // MARK: - Clicks are mono (identical on both channels, like the old beat tone)

  @Test("Click train is centered: identical on both channels")
  func clickTrainIsCentered() async throws {
    let config = schemeBOnlyConfig()
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.05, distanceError: 0, inDeadZone: false))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    #expect(left == right)
  }
}
