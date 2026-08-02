import Testing

@testable import AboutFaceCore

/// §6.2 Scheme B — PERCUSSIVE REDESIGN (2026-08-02 convergence-experiment
/// action round, item 3). See `RenderState+SchemeB.swift`'s type-level doc
/// comment for the full "why": round 1's two-tone beat trial
/// (`p1-scheme-b`) came back unjudgeable because it sat in the same
/// register as Scheme A's own beacon; Scheme B is now a non-tonal click
/// train at the same rate the old beat frequency would have been.
///
/// Every test here isolates the B-layer by zeroing
/// `positional.toneGain` (silencing Scheme A's continuous tone entirely —
/// `carrier * amplitude == 0` regardless of carrier shape), so the render
/// buffer contains ONLY Scheme B's contribution.
struct AudioRendererSchemeBTests {
  private static let sampleRate = 48000.0

  private func schemeBOnlyConfig(
    refinementFraction: Double = 0.2, maxBeatHz: Double = 8
  ) -> Config.Audio {
    var config = Config.Audio.defaults
    config.positional.toneGain = 0
    config.scheme.schemeBEnabled = true
    config.scheme.schemeBRefinementFraction = refinementFraction
    config.scheme.schemeBMaxBeatHz = maxBeatHz
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

  // MARK: - Click rate tracks error magnitude within the refinement zone

  @Test("Click rate increases with |error| inside the refinement zone")
  func clickRateTracksMagnitudeWithinZone() async throws {
    // errorRange 0.35, refinementFraction 0.2 ⇒ zoneLimit 0.07.
    let config = schemeBOnlyConfig()

    let nearNull = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.015, distanceError: 0, inDeadZone: false))
    }
    let (nearLeft, _) = try await AudioRendererTestSupport.renderFrames(nearNull, total: 48000)
    let nearClicks = clickCount(nearLeft)

    let nearEdge = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.065, distanceError: 0, inDeadZone: false))
    }
    let (edgeLeft, _) = try await AudioRendererTestSupport.renderFrames(nearEdge, total: 48000)
    let edgeClicks = clickCount(edgeLeft)

    #expect(edgeClicks > nearClicks)
  }

  // MARK: - Zero clicks at zero error

  @Test("Zero error produces zero clicks (true silence at the null)")
  func zeroErrorProducesZeroClicks() async throws {
    let config = schemeBOnlyConfig()
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0, distanceError: 0, inDeadZone: false))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)

    #expect(clickCount(left) == 0)
    #expect(left.allSatisfy { $0 == 0 })
    #expect(right.allSatisfy { $0 == 0 })
  }

  // MARK: - No clicks outside the refinement zone

  @Test("Error outside the refinement zone produces no B-layer output at all")
  func outsideRefinementZoneProducesNoOutput() async throws {
    // zoneLimit 0.07; 0.2 is well outside it.
    let config = schemeBOnlyConfig()
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.2, distanceError: 0, inDeadZone: false))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)

    #expect(left.allSatisfy { $0 == 0 })
    #expect(right.allSatisfy { $0 == 0 })
  }

  // MARK: - Flag off = no B-layer output (unchanged)

  @Test("schemeBEnabled = false produces no B-layer output even inside the zone")
  func flagOffProducesNoOutput() async throws {
    var config = schemeBOnlyConfig()
    config.scheme.schemeBEnabled = false
    let renderer = try await AudioRendererTestSupport.makeRenderer(config: config) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0, errorY: 0.03, distanceError: 0, inDeadZone: false))
    }
    let (left, right) = try await AudioRendererTestSupport.renderFrames(renderer, total: 48000)

    #expect(left.allSatisfy { $0 == 0 })
    #expect(right.allSatisfy { $0 == 0 })
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
