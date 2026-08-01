import AVFoundation
import Testing

@testable import AboutFaceCore

/// `AudioRenderer.updateConfig(_:)` (additive glue for this round's Phase 3
/// app/CLI wiring — see its doc comment): live-applies a new `Config.Audio`
/// by rebuilding `RenderState` and, if running, restarting the engine
/// around it. These tests exercise both the "never started yet" path (just
/// records config for the next `start()`) and the "already running" path
/// (stop/rebuild/restart), using the same offline-rendering harness as the
/// rest of the `AudioRenderer` test suite (§13 Phase 3 requirement 6) —
/// deterministic, no real audio device.
struct AudioRendererUpdateConfigTests {

  @Test("updateConfig before start() records the new config for the next start()")
  func updateConfigBeforeStartAppliesOnNextStart() async throws {
    let renderer = AudioRenderer(config: .defaults, mode: .offline)

    var quiet = Config.Audio.defaults
    quiet.positional.toneGain = 0.9
    await renderer.updateConfig(quiet)

    try await renderer.start()
    await renderer.update(
      SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false))

    let (samples, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 4096)
    #expect(AudioRendererTestSupport.rms(samples) > 0)
  }

  @Test("updateConfig while running changes renderer output without crashing")
  func updateConfigWhileRunningChangesOutput() async throws {
    var loud = Config.Audio.defaults
    loud.positional.toneGain = 0.8

    let renderer = try await AudioRendererTestSupport.makeRenderer(config: loud) { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false))
    }

    let (before, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 4096)
    #expect(AudioRendererTestSupport.rms(before) > 0)

    var silentGain = loud
    silentGain.positional.toneGain = 0
    await renderer.updateConfig(silentGain)

    // A fresh `RenderState` starts with no published target (§7.5-adjacent
    // "silent" initial state, matching `ParamSnapshot.silent`) — re-publish
    // the same target so this asserts the GAIN change took effect, not
    // merely that the new `RenderState` forgot the old target.
    await renderer.update(
      SonificationTarget(errorX: 0.3, errorY: 0, distanceError: 0, inDeadZone: false))
    let (after, afterRight) = try await AudioRendererTestSupport.renderFrames(
      renderer, total: 4096)
    #expect(after.allSatisfy { $0 == 0 })
    #expect(afterRight.allSatisfy { $0 == 0 })
  }

  @Test("updateConfig while running keeps the engine usable afterward")
  func updateConfigWhileRunningLeavesEngineFunctional() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { _ in }

    await renderer.updateConfig(.defaults)
    await renderer.play(.enteredGoodZone)

    let (samples, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 8192)
    #expect(AudioRendererTestSupport.rms(samples) > 0)
  }
}
