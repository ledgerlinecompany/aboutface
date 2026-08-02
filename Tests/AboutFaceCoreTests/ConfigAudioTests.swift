import Foundation
import Testing

@testable import AboutFaceCore

/// Covers `Config.Audio` (§6, §13 Phase 3), added 2026-08-01: Codable
/// round-tripping (whole struct and a couple of representative nested
/// sub-structs, mirroring `ConfigTests`' style for `Lighting`/`Signal`), the
/// §16/maintainer-decision default values, and the additive-field
/// backward-compatibility precedent already established by
/// `TargetFraming`'s `neutralYawDegrees` et al.
struct ConfigAudioTests {

  @Test("Config.Audio round-trips through Codable")
  func audioRoundTrip() throws {
    let data = try JSONEncoder().encode(Config.Audio.defaults)
    let decoded = try JSONDecoder().decode(Config.Audio.self, from: data)
    #expect(decoded == Config.Audio.defaults)
  }

  @Test("Config.defaults.audio matches Config.Audio.defaults")
  func configDefaultsIncludesAudioDefaults() {
    #expect(Config.defaults.audio == Config.Audio.defaults)
  }

  @Test("Omitting `audio:` at Config construction defaults it (additive-field precedent)")
  func omittingAudioParameterDefaultsIt() {
    let config = Config(
      version: 1,
      targetFraming: Config.defaults.targetFraming,
      deadZone: Config.defaults.deadZone,
      hysteresisExitRatio: Config.defaults.hysteresisExitRatio,
      dwellMs: Config.defaults.dwellMs,
      smoothingWindow: Config.defaults.smoothingWindow,
      lighting: Config.defaults.lighting,
      signal: Config.defaults.signal,
      gaze: Config.defaults.gaze,
      display: Config.defaults.display
    )
    #expect(config.audio == Config.Audio.defaults)
  }

  // MARK: - §16 maintainer decisions reflected in defaults

  @Test("Scheme A (pan/pitch) is the default positional scheme")
  func defaultSchemeIsPanPitch() {
    #expect(Config.Audio.defaults.scheme.positional == .panPitch)
  }

  @Test("Scheme B (zero-beat) ships disabled by default, per §16")
  func schemeBDisabledByDefault() {
    #expect(Config.Audio.defaults.scheme.schemeBEnabled == false)
  }

  @Test("Scheme B refinement fraction: 0.8, widened again by round-2d pacing feedback")
  func schemeBRefinementFractionMatchesSpec() {
    // §6.2 suggested 0.2 as a starting point (§0: every number is
    // tunable). Round-2c measurement: at 0.2 the refinement zone (0.07)
    // barely exceeded the dead-zone corner (~0.078), so the click
    // crescendo could never develop — observed ~2 clicks/sec ceiling and
    // zero-click trials, which round-2c fixed by widening to 0.5. Round-2d
    // ("arrival herald" redesign): maintainer, on hearing round-2c's
    // crescendo, "I got them almost indistinguishably fast pretty quickly
    // and didn't spend much time hearing them very slow. Maybe start even
    // further out with the clicks and converge them" — widened again to
    // 0.8 for more approach distance, paired with the new
    // `schemeBRateCurve` to pace how that distance is spent (see
    // `RenderState+SchemeB.swift`).
    #expect(Config.Audio.defaults.scheme.schemeBRefinementFraction == 0.8)
  }

  @Test("Scheme B distance-engage error: 0.15, half of distance.errorRange (round-2d)")
  func schemeBDistanceEngageErrorMatchesSpec() {
    // NEW field (round-2d "arrival herald" redesign): the distance half of
    // the lagging-axis-governance pair, `min(xyCloseness,
    // distanceCloseness)`. Default 0.15 is half of
    // `AudioDistance.errorRange` (0.3), engaging roughly as far out,
    // proportionally, as the widened XY envelope does.
    #expect(Config.Audio.defaults.scheme.schemeBDistanceEngageError == 0.15)
  }

  @Test("Scheme B rate curve: 2.0, same superlinear-onset device as timbreOnsetExponent (round-2d)")
  func schemeBRateCurveMatchesSpec() {
    // NEW field (round-2d pacing feedback): `beatHz = maxBeatHz ×
    // closeness ^ rateCurve`. Default 2.0 keeps the click rate low/
    // countable through most of the approach and compresses the
    // near-maximum blur into the final instants before arrival — the same
    // psychoacoustic lesson `Config.AudioPositional.timbreOnsetExponent`
    // already applies to the vertical-timbre crossing.
    #expect(Config.Audio.defaults.scheme.schemeBRateCurve == 2.0)
  }

  /// 2026-08-02 action round, item 3 (percussive Scheme B redesign — see
  /// `RenderState+SchemeB.swift`): the click train's own gain/duration
  /// fields, defaulted rather than left at the struct init's `0`-ish
  /// additive-field fallback.
  @Test("Scheme B click gain/duration default to an audible, percussive-length starting point")
  func schemeBClickDefaults() {
    // 0.18: rebalanced just under toneGain (0.2) — round-2b maintainer
    // finding: "the clicks were louder than the tone."
    #expect(Config.Audio.defaults.scheme.schemeBClickGain == 0.18)
    #expect(Config.Audio.defaults.scheme.schemeBClickDurationMs == 6)
  }

  @Test("Beacon polarity is enabled by default (2026-08-01 maintainer directive)")
  func beaconPolarityDefaultsTrue() {
    #expect(Config.Audio.defaults.positional.beaconPolarity == true)
  }

  @Test("Vertical timbre differentiation ships enabled, per 2026-08-02 tuning directive")
  func verticalTimbreEnabledByDefault() {
    #expect(Config.Audio.defaults.positional.verticalTimbreEnabled == true)
  }

  @Test("Brightness/darkness mix defaults are sensible fractions, not full-scale or silent")
  func timbreMixDefaultsAreModerate() {
    #expect(Config.Audio.defaults.positional.maxBrightnessMix == 0.5)
    #expect(Config.Audio.defaults.positional.maxDarknessMix == 0.5)
  }

  @Test("Brightness style defaults to .saw, chosen by ear in the 2026-08-02 A/B")
  func brightnessStyleDefaultsToOverdrive() {
    #expect(Config.Audio.defaults.positional.brightnessStyle == .saw)
  }

  @Test("Overdrive max drive default is capped, not left unbounded")
  func overdriveMaxDriveDefault() {
    #expect(Config.Audio.defaults.positional.overdriveMaxDrive == 6)
  }

  /// §6.2 extension (2026-08-02 first live convergence-trial finding: "huge
  /// jump in perceived pitch from too low to too high"). Default `2.0` is
  /// superlinear (steeper than the old linear `1.0` behavior) — see
  /// `Config.AudioPositional.timbreOnsetExponent`'s doc comment and
  /// `AudioRendererTimbreOnsetTests` for the hand-derived acceptance cases.
  @Test("Timbre onset exponent defaults to a superlinear 2.0, not the old linear 1.0")
  func timbreOnsetExponentDefaultIsSuperlinear() {
    #expect(Config.Audio.defaults.positional.timbreOnsetExponent == 2.0)
  }

  /// 2026-08-02 action round, item 1: the 2026-08-02 convergence experiment
  /// (`docs/tuning/2026-08-02-convergence-experiment.md`) found the
  /// quantized-fine profile (`p5`, step `0.03`) swept both speed and
  /// steadiness, with the practiced control run LAST and still losing on
  /// both — see `Config.AudioPositional.errorQuantizationStep`'s doc
  /// comment for the full numbers.
  @Test("Error quantization step defaults to 0.03 (fine quantized beacon), not continuous")
  func errorQuantizationStepDefaultIsQuantizedFine() {
    #expect(Config.Audio.defaults.positional.errorQuantizationStep == 0.03)
  }

  /// 2026-08-02 action round, item 2: both quantized trial profiles were
  /// "jumpy" — see `Config.AudioPositional.quantizationGlideMs`'s doc
  /// comment.
  @Test("Quantization glide defaults to 30ms per step (round-2: 80 was audibly sluggish)")
  func quantizationGlideMsDefault() {
    #expect(Config.Audio.defaults.positional.quantizationGlideMs == 30)
  }

  @Test("BrightnessStyle round-trips through Codable, including the raw value")
  func brightnessStyleRoundTripsRawValue() throws {
    for style in Config.BrightnessStyle.allCases {
      let data = try JSONEncoder().encode(style)
      let decoded = try JSONDecoder().decode(Config.BrightnessStyle.self, from: data)
      #expect(decoded == style)
    }
    // The raw values are the wire format ConfigStore persists and
    // `--brightness` accepts — pin them explicitly so a rename is a
    // deliberate, visible diff here rather than a silent format break.
    #expect(Config.BrightnessStyle.harmonics.rawValue == "harmonics")
    #expect(Config.BrightnessStyle.overdrive.rawValue == "overdrive")
    #expect(Config.BrightnessStyle.saw.rawValue == "saw")
  }

  @Test("Engine format defaults to 48kHz / 256-frame buffer")
  func engineDefaults() {
    #expect(Config.Audio.defaults.engine.sampleRate == 48000)
    #expect(Config.Audio.defaults.engine.bufferFrameSize == 256)
  }

  @Test("Distance never maps to a base amplitude change, only gate rate/depth/character")
  func distanceConfigHasNoVolumeField() {
    // Structural assertion, not a runtime one: `Config.AudioDistance` has
    // exactly `errorRange`/`pulseRateMinHz`/`pulseRateMaxHz`/the per-side depths/
    // `directionalPulseEnabled`/`closePulseSharpness` — there is no
    // "distance gain" field for a future implementer to wire up by mistake
    // in violation of §6.2 ("never volume"). Encoded here as a round-trip
    // over an independently-constructed value so a future additive field is
    // at least visible in a diff.
    let distance = Config.AudioDistance(
      errorRange: 0.4, pulseRateMinHz: 2, pulseRateMaxHz: 10, closePulseDepth: 0.9,
      farPulseDepth: 0.5, audibleRampMultiplier: 2.5, audibleRampStartError: 0.03,
      directionalPulseEnabled: false, closePulseSharpness: 4)
    #expect(distance.errorRange == 0.4)
    #expect(distance.pulseRateMinHz == 2)
    #expect(distance.pulseRateMaxHz == 10)
    #expect(distance.closePulseDepth == 0.9)
    #expect(distance.farPulseDepth == 0.5)
    #expect(distance.directionalPulseEnabled == false)
    #expect(distance.closePulseSharpness == 4)
  }

  @Test("Distance defaults enable directional pulse character with the round-4 sharpness")
  func distanceDefaultsEnableDirectionalPulse() {
    #expect(Config.Audio.defaults.distance.directionalPulseEnabled == true)
    #expect(Config.Audio.defaults.distance.closePulseSharpness == 3.5)
  }

  // MARK: - Nested sub-struct round trips (mirrors ConfigTests' Lighting/Signal/Gaze coverage)

  @Test("Positional sub-struct round-trips through Codable independently")
  func positionalRoundTrip() throws {
    let original = Config.AudioPositional(
      errorRange: 0.4,
      minToneHz: 200,
      maxToneHz: 900,
      referenceToneHz: 425,
      toneGain: 0.25,
      panSpeakerAttenuation: 0.4,
      pitchSpeakerRangeExpansion: 1.6,
      sequentialAxisThreshold: 0.12,
      beaconPolarity: false,
      verticalTimbreEnabled: false,
      maxBrightnessMix: 0.6,
      maxDarknessMix: 0.4,
      brightnessStyle: .saw,
      timbreOnsetExponent: 2.5,
      overdriveMaxDrive: 8
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.AudioPositional.self, from: data)
    #expect(decoded == original)
  }

  @Test("Earcons sub-struct round-trips through Codable independently")
  func earconsRoundTrip() throws {
    let original = Config.Audio.defaults.earcons
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.AudioEarcons.self, from: data)
    #expect(decoded == original)
  }

  @Test("Scheme sub-struct round-trips through Codable independently")
  func schemeRoundTrip() throws {
    let original = Config.AudioScheme(
      positional: .sequential, schemeBEnabled: true, schemeBRefinementFraction: 0.15,
      schemeBMaxBeatHz: 6)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.AudioScheme.self, from: data)
    #expect(decoded == original)
  }
}
