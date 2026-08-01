import Testing

@testable import AboutFaceCore

/// §6.1's silence-ambiguity earcon set, plus the confirmation/reacquisition
/// markers: each `AudioEvent` must (a) actually produce audible output, (b)
/// stop on its own once its configured duration elapses, and (c) be
/// spectrally/structurally distinguishable from the others in the specific
/// ways `Config.AudioEarcons`' doc comments claim. Assertions are
/// deliberately coarse (spectral flatness ratios, envelope-window RMS
/// comparisons, dominant-frequency contour) rather than exact-sample —
/// per §13 Phase 3 requirement 6.
struct AudioRendererEarconTests {
  private static let sampleRate = 48000.0
  private static let config = Config.Audio.defaults

  private static func totalFrames(for event: AudioEvent, marginMs: Double = 60) -> Int {
    let kind = EarconKind(event)
    let durationMs = EarconVoice.durationMs(
      for: kind, earcons: config.earcons, heartbeat: config.heartbeat)
    return EarconVoice.frameCount(durationMs: durationMs + marginMs, sampleRate: sampleRate)
  }

  // MARK: - Every event produces nonzero output, then returns to silence

  // swiftlint and swift-format disagree on trailing commas in multiline collection
  // literals (swift-format requires them, swiftlint's default forbids them); this
  // block satisfies `swift format lint`, which the CI gate also enforces.
  // swiftlint:disable trailing_comma
  @Test(
    "Every AudioEvent produces nonzero output and returns to silence once its duration elapses",
    arguments: [
      AudioEvent.enteredGoodZone, .livenessHeartbeat, .faceLost, .lowConfidence, .noSignal,
      .faceReacquired,
    ]
  )
  // swiftlint:enable trailing_comma
  func eachEventSoundsThenGoesSilent(event: AudioEvent) async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(event)
    }

    let frames = Self.totalFrames(for: event)
    let (during, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: frames)
    #expect(AudioRendererTestSupport.rms(during) > 0)

    let (after, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 4096)
    #expect(AudioRendererTestSupport.rms(after) == 0)
  }

  // MARK: - faceLost is broadband ("different in kind"); others are tonal

  @Test("faceLost (noise burst) has a flatter spectrum than lowConfidence (tonal sweep)")
  func faceLostIsFlatterSpectrumThanTonalEarcons() async throws {
    let faceLostRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.faceLost)
    }
    let (faceLostSamples, _) = try await AudioRendererTestSupport.renderFrames(
      faceLostRenderer, total: Self.totalFrames(for: .faceLost))
    let faceLostFlatness = AudioRendererTestSupport.spectralFlatness(
      faceLostSamples, sampleRate: Self.sampleRate, minHz: 100, maxHz: 4000)

    let lowConfidenceRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.lowConfidence)
    }
    let (lowConfidenceSamples, _) = try await AudioRendererTestSupport.renderFrames(
      lowConfidenceRenderer, total: Self.totalFrames(for: .lowConfidence))
    let lowConfidenceFlatness = AudioRendererTestSupport.spectralFlatness(
      lowConfidenceSamples, sampleRate: Self.sampleRate, minHz: 100, maxHz: 4000)

    #expect(faceLostFlatness > lowConfidenceFlatness * 2)
  }

  @Test("faceLost (noise burst) has a flatter spectrum than the noSignal buzzer")
  func faceLostIsFlatterSpectrumThanBuzzer() async throws {
    let faceLostRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.faceLost)
    }
    let (faceLostSamples, _) = try await AudioRendererTestSupport.renderFrames(
      faceLostRenderer, total: Self.totalFrames(for: .faceLost))
    let faceLostFlatness = AudioRendererTestSupport.spectralFlatness(
      faceLostSamples, sampleRate: Self.sampleRate, minHz: 100, maxHz: 4000)

    let noSignalRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.noSignal)
    }
    let (noSignalSamples, _) = try await AudioRendererTestSupport.renderFrames(
      noSignalRenderer, total: Self.totalFrames(for: .noSignal))
    let noSignalFlatness = AudioRendererTestSupport.spectralFlatness(
      noSignalSamples, sampleRate: Self.sampleRate, minHz: 100, maxHz: 4000)

    #expect(faceLostFlatness > noSignalFlatness)
  }

  // MARK: - lowConfidence descends, faceReacquired ascends (mirror-image contours)

  @Test("lowConfidence's pitch contour descends; faceReacquired's ascends")
  func lowConfidenceDescendsAndFaceReacquiredAscends() async throws {
    let lowConfidenceRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.lowConfidence)
    }
    let (lowConfidenceSamples, _) = try await AudioRendererTestSupport.renderFrames(
      lowConfidenceRenderer, total: Self.totalFrames(for: .lowConfidence))
    let lc = Self.config.earcons.lowConfidence
    let (lcEarly, lcLate) = earlyAndLateWindows(lowConfidenceSamples)
    let lcEarlyFreq = AudioRendererTestSupport.dominantFrequency(
      lcEarly, sampleRate: Self.sampleRate, minHz: min(lc.startHz, lc.endHz),
      maxHz: max(lc.startHz, lc.endHz))
    let lcLateFreq = AudioRendererTestSupport.dominantFrequency(
      lcLate, sampleRate: Self.sampleRate, minHz: min(lc.startHz, lc.endHz),
      maxHz: max(lc.startHz, lc.endHz))
    #expect(lcEarlyFreq > lcLateFreq)

    let faceReacquiredRenderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.faceReacquired)
    }
    let (faceReacquiredSamples, _) = try await AudioRendererTestSupport.renderFrames(
      faceReacquiredRenderer, total: Self.totalFrames(for: .faceReacquired))
    let fr = Self.config.earcons.faceReacquired
    let (frEarly, frLate) = earlyAndLateWindows(faceReacquiredSamples)
    let frEarlyFreq = AudioRendererTestSupport.dominantFrequency(
      frEarly, sampleRate: Self.sampleRate, minHz: min(fr.startHz, fr.endHz),
      maxHz: max(fr.startHz, fr.endHz))
    let frLateFreq = AudioRendererTestSupport.dominantFrequency(
      frLate, sampleRate: Self.sampleRate, minHz: min(fr.startHz, fr.endHz),
      maxHz: max(fr.startHz, fr.endHz))
    #expect(frLateFreq > frEarlyFreq)
  }

  // MARK: - enteredGoodZone has a mid-envelope gap; faceReacquired does not

  @Test("enteredGoodZone's envelope dips to near-silence mid-earcon (two discrete notes)")
  func enteredGoodZoneHasMidEnvelopeGap() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.enteredGoodZone)
    }
    let (samples, _) = try await AudioRendererTestSupport.renderFrames(
      renderer, total: Self.totalFrames(for: .enteredGoodZone, marginMs: 0))
    let windows = AudioRendererTestSupport.windowedRMS(samples, windows: 10)
    guard let maxWindow = windows.max() else {
      Issue.record("expected non-empty RMS windows")
      return
    }
    let middle = Array(windows[3...6])
    guard let minMiddle = middle.min() else {
      Issue.record("expected non-empty middle window slice")
      return
    }
    #expect(minMiddle < 0.2 * maxWindow)
  }

  @Test("faceReacquired's envelope stays continuous (no mid-earcon gap)")
  func faceReacquiredHasNoMidEnvelopeGap() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.faceReacquired)
    }
    let (samples, _) = try await AudioRendererTestSupport.renderFrames(
      renderer, total: Self.totalFrames(for: .faceReacquired, marginMs: 0))
    let windows = AudioRendererTestSupport.windowedRMS(samples, windows: 10)
    guard let maxWindow = windows.max() else {
      Issue.record("expected non-empty RMS windows")
      return
    }
    let middle = Array(windows[3...6])
    guard let minMiddle = middle.min() else {
      Issue.record("expected non-empty middle window slice")
      return
    }
    #expect(minMiddle > 0.3 * maxWindow)
  }
}

/// Splits `samples` into an "early" slice (20%-40% through) and a "late"
/// slice (60%-80% through), avoiding the very start/end where every
/// earcon's sin-hump envelope is near zero and frequency detection is
/// unreliable.
private func earlyAndLateWindows(_ samples: [Float]) -> (early: [Float], late: [Float]) {
  let count = samples.count
  let early = Array(samples[(count * 2 / 10)..<(count * 4 / 10)])
  let late = Array(samples[(count * 6 / 10)..<(count * 8 / 10)])
  return (early, late)
}
