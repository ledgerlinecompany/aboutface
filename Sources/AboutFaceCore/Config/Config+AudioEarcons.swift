/// §6.1's five-way silence-ambiguity earcon set, split out of
/// `Config+Audio.swift` for the same file-length reasons documented there.
/// Each type is a sibling of `Config.AudioEarcons` (nested directly under
/// `Config`, matching this project's one-level-of-nesting convention), not
/// nested inside `AudioEarcons` itself.
extension Config {
  /// §6.1's five-way silence-ambiguity structure, minus the heartbeat
  /// (`Config.AudioHeartbeat`) and minus lighting (§6.2: discrete state
  /// announcement is speech's job, not this renderer's). Each earcon's
  /// timbre is chosen to be a different KIND of sound, not a variation on
  /// the positional tone or on each other — see each type's doc comment for
  /// the specific reasoning, and `AudioRenderer`'s voice-synthesis code for
  /// where that reasoning becomes signal.
  public struct AudioEarcons: Codable, Sendable, Equatable {
    public var enteredGoodZone: AudioEarconEnteredGoodZone
    public var faceLost: AudioEarconFaceLost
    public var lowConfidence: AudioEarconLowConfidence
    public var noSignal: AudioEarconNoSignal
    public var faceReacquired: AudioEarconFaceReacquired

    public init(
      enteredGoodZone: AudioEarconEnteredGoodZone,
      faceLost: AudioEarconFaceLost,
      lowConfidence: AudioEarconLowConfidence,
      noSignal: AudioEarconNoSignal,
      faceReacquired: AudioEarconFaceReacquired
    ) {
      self.enteredGoodZone = enteredGoodZone
      self.faceLost = faceLost
      self.lowConfidence = lowConfidence
      self.noSignal = noSignal
      self.faceReacquired = faceReacquired
    }

    public static let defaults = AudioEarcons(
      enteredGoodZone: AudioEarconEnteredGoodZone(
        note1Hz: 660,
        note2Hz: 990,
        noteDurationMs: 70,
        gapMs: 30,
        gain: 0.35
      ),
      faceLost: AudioEarconFaceLost(
        durationMs: 300,
        gain: 0.25
      ),
      lowConfidence: AudioEarconLowConfidence(
        startHz: 520,
        endHz: 340,
        durationMs: 350,
        gain: 0.3
      ),
      noSignal: AudioEarconNoSignal(
        freqHz: 220,
        modHz: 12,
        durationMs: 500,
        gain: 0.3
      ),
      faceReacquired: AudioEarconFaceReacquired(
        startHz: 350,
        endHz: 700,
        durationMs: 250,
        gain: 0.3
      )
    )
  }

  /// §6.1: "Distinct confirmation earcon, once." Two short discrete notes,
  /// ascending (`note2Hz > note1Hz`), separated by a brief true silence
  /// (`gapMs`) — the gap is what makes this structurally distinct from
  /// `AudioEarconFaceReacquired`'s continuous sweep even though both are
  /// "rising" in a loose sense.
  public struct AudioEarconEnteredGoodZone: Codable, Sendable, Equatable {
    public var note1Hz: Double
    public var note2Hz: Double
    public var noteDurationMs: Double
    public var gapMs: Double
    public var gain: Double

    public init(
      note1Hz: Double, note2Hz: Double, noteDurationMs: Double, gapMs: Double, gain: Double
    ) {
      self.note1Hz = note1Hz
      self.note2Hz = note2Hz
      self.noteDurationMs = noteDurationMs
      self.gapMs = gapMs
      self.gain = gain
    }
  }

  /// §6.1: "Unmistakable, different in kind — different timbre, not a
  /// variation on the positional tone." The positional tone and every other
  /// earcon here are pure tonal (sine) content with a peaked spectrum; this
  /// is unfiltered white noise, which is broadband/flat-spectrum — the most
  /// different-in-kind sound available relative to a pitched tone, and
  /// cheap and robust to synthesize and test (no filter design to get
  /// subtly wrong).
  public struct AudioEarconFaceLost: Codable, Sendable, Equatable {
    public var durationMs: Double
    public var gain: Double

    public init(durationMs: Double, gain: Double) {
      self.durationMs = durationMs
      self.gain = gain
    }
  }

  /// §6.1: "Audibly distinct from both [face lost and no signal]." Tonal
  /// (like the positional tone and `AudioEarconEnteredGoodZone`/
  /// `AudioEarconFaceReacquired`) but with a falling contour, the mirror
  /// image of `AudioEarconFaceReacquired`'s rising sweep — "detector losing
  /// confidence" reads naturally as descending, and the contour is what
  /// distinguishes it from the other tonal earcons in a coarse,
  /// robustly-testable way (dominant frequency measured early vs. late in
  /// the earcon).
  public struct AudioEarconLowConfidence: Codable, Sendable, Equatable {
    public var startHz: Double
    public var endHz: Double
    public var durationMs: Double
    public var gain: Double

    public init(startHz: Double, endHz: Double, durationMs: Double, gain: Double) {
      self.startHz = startHz
      self.endHz = endHz
      self.durationMs = durationMs
      self.gain = gain
    }
  }

  /// §6.1: "Own message. Lens covered / camera asleep is a different
  /// problem with a different fix." A flat (non-swept, non-noise)
  /// amplitude-modulated square wave — a literal buzzer. Square-wave
  /// harmonic content plus AM texture (`modHz`) makes it read as
  /// mechanical/alarm-like, distinct from every other earcon here: unlike
  /// `AudioEarconFaceLost` it is pitched and flat (no frequency movement,
  /// unlike `AudioEarconLowConfidence`/`AudioEarconFaceReacquired`); unlike
  /// the noise burst it is harsh/harmonic rather than broadband.
  public struct AudioEarconNoSignal: Codable, Sendable, Equatable {
    public var freqHz: Double
    public var modHz: Double
    public var durationMs: Double
    public var gain: Double

    public init(freqHz: Double, modHz: Double, durationMs: Double, gain: Double) {
      self.freqHz = freqHz
      self.modHz = modHz
      self.durationMs = durationMs
      self.gain = gain
    }
  }

  /// Its own brief marker (§6.1 table implies this needs to be
  /// distinguishable from `AudioEarconEnteredGoodZone`'s confirmation even
  /// though both are positive events). A single continuous rising sweep —
  /// no gap, unlike `AudioEarconEnteredGoodZone`'s two discrete notes — so
  /// the two are structurally distinguishable (envelope shape), not just
  /// numerically distinguishable (exact frequencies), which holds up even
  /// after by-ear retuning of either one's frequencies.
  public struct AudioEarconFaceReacquired: Codable, Sendable, Equatable {
    public var startHz: Double
    public var endHz: Double
    public var durationMs: Double
    public var gain: Double

    public init(startHz: Double, endHz: Double, durationMs: Double, gain: Double) {
      self.startHz = startHz
      self.endHz = endHz
      self.durationMs = durationMs
      self.gain = gain
    }
  }
}
