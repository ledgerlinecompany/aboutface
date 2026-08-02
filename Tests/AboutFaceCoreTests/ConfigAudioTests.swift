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

  @Test("Scheme B refinement fraction matches §6.2's 'inside 20% of error range'")
  func schemeBRefinementFractionMatchesSpec() {
    #expect(Config.Audio.defaults.scheme.schemeBRefinementFraction == 0.2)
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
      farPulseDepth: 0.5,
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
