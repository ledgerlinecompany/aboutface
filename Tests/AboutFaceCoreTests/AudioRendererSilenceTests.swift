import Testing

@testable import AboutFaceCore

/// §7.5: "⌘⌃⇧/ silences all feedback immediately... MUST take effect within
/// one audio buffer — cut the render, do not wait for the current utterance
/// to finish." These tests exercise `setSilenced(_:)` against a renderer
/// with active continuous tone and/or an active earcon voice, and assert
/// the very next rendered buffer is exactly zero — not merely quieter, not
/// faded, exactly zero, matching `RenderState.render`'s unconditional
/// zero-fill on the silenced path.
struct AudioRendererSilenceTests {

  @Test("setSilenced(true) zeroes the next buffer even mid-positional-tone")
  func silencedCutsPositionalToneWithinOneBuffer() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.update(
        SonificationTarget(errorX: 0.3, errorY: 0.3, distanceError: 0, inDeadZone: false))
    }

    // Sanity check: unsilenced output is actually audible first.
    let (before, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 512)
    #expect(AudioRendererTestSupport.rms(before) > 0)

    await renderer.setSilenced(true)

    let (after, afterRight) = try await AudioRendererTestSupport.renderFrames(renderer, total: 512)
    #expect(after.allSatisfy { $0 == 0 })
    #expect(afterRight.allSatisfy { $0 == 0 })
  }

  @Test(
    "setSilenced(true) zeroes the next buffer mid-earcon, and does not resume it once unsilenced")
  func silencedDropsInFlightEarcon() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { renderer in
      await renderer.play(.enteredGoodZone)
    }

    // Let the earcon start playing (its envelope is silent at sample 0, so
    // render a little into it first).
    _ = try await AudioRendererTestSupport.renderFrames(renderer, total: 512)

    await renderer.setSilenced(true)
    let (silent, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 512)
    #expect(silent.allSatisfy { $0 == 0 })

    await renderer.setSilenced(false)
    // §7.5 doesn't require resuming a cut earcon, and `RenderState` is
    // documented to drop in-flight voices on silence rather than pause
    // them — assert that documented behavior: no earcon tail leaks out
    // once unsilenced, even though the event was never re-`play`ed.
    let (afterUnsilence, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 4096)
    #expect(afterUnsilence.allSatisfy { $0 == 0 })
  }

  @Test("setSilenced(false) after silence allows a freshly-played event to sound")
  func unsilencingAllowsNewEventsToSound() async throws {
    let renderer = try await AudioRendererTestSupport.makeRenderer { _ in }

    await renderer.setSilenced(true)
    let (silent, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 256)
    #expect(silent.allSatisfy { $0 == 0 })

    await renderer.setSilenced(false)
    await renderer.play(.faceReacquired)
    let (audible, _) = try await AudioRendererTestSupport.renderFrames(renderer, total: 12000)
    #expect(AudioRendererTestSupport.rms(audible) > 0)
  }
}
