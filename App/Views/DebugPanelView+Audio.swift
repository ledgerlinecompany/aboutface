import AboutFaceCore
import SwiftUI

extension DebugPanelView {
  /// The Audio tuning section (§6.2). Split from `DebugPanelView.swift`
  /// purely for SwiftLint's file/type-length limits — same pattern as the
  /// core's `AnalysisEngine+*.swift` splits. Everything not surfaced here
  /// (earcon envelopes, engine sample rate/buffer size, distance-pulse
  /// mapping, …) stays reachable via Export/Import.
  var audioSection: some View {
    ConfigSection(title: "Audio") {
      Picker("Positional scheme", selection: model.rawValueBinding(\.audio.scheme.positional)) {
        Text("A — Pan/pitch").tag(Config.AudioPositionalScheme.panPitch.rawValue)
        Text("C — Sequential axis").tag(Config.AudioPositionalScheme.sequential.rawValue)
      }
      .accessibilityHint(
        "Scheme A pans and pitches simultaneously. Scheme C solves horizontal, then vertical — "
          + "unambiguous on a single speaker.")

      Picker(
        "Vertical brightness style",
        selection: model.rawValueBinding(\.audio.positional.brightnessStyle)
      ) {
        Text("Saw (clearest, by-ear default)").tag(Config.BrightnessStyle.saw.rawValue)
        Text("Overdrive").tag(Config.BrightnessStyle.overdrive.rawValue)
        Text("Harmonics (subtle)").tag(Config.BrightnessStyle.harmonics.rawValue)
      }
      .accessibilityHint(
        "The added texture when the target is above you. Saw is clearest but strongest; "
          + "lower the brightness intensity below if it grates.")

      ConfigSliderRow(
        title: "Brightness intensity",
        value: model.binding(\.audio.positional.maxBrightnessMix),
        range: 0...1, step: 0.05, format: Format.percent)

      ConfigSliderRow(
        title: "Darkness intensity",
        value: model.binding(\.audio.positional.maxDarknessMix),
        range: 0...1, step: 0.05, format: Format.percent)

      Toggle(
        "Zero-beat refinement (Scheme B)",
        isOn: model.boolBinding(\.audio.scheme.schemeBEnabled)
      )
      .accessibilityHint(
        "Layers a beat tone that nulls to silence on final approach, inside the "
          + "refinement zone below. Composes with Scheme A only.")

      ConfigSliderRow(
        title: "Scheme B refinement zone",
        value: model.binding(\.audio.scheme.schemeBRefinementFraction),
        range: 0.05...0.5, step: 0.01, format: Format.percent)

      Picker("Output device", selection: model.rawValueBinding(\.audio.outputMode)) {
        Text("Headphones").tag(Config.AudioOutputMode.headphones.rawValue)
        Text("Speakers").tag(Config.AudioOutputMode.speakers.rawValue)
      }
      .accessibilityHint(
        "Speakers mode narrows stereo pan and widens the pitch range to compensate for poor "
          + "built-in-speaker imaging.")

      Toggle("Beacon polarity", isOn: model.boolBinding(\.audio.positional.beaconPolarity))
        .accessibilityHint(
          "On (default): the tone is positioned at the target, so moving toward it centers the "
            + "sound. Off: the tone marks where you currently are, for A/B tuning only.")

      ConfigSliderRow(
        title: "Master gain, positional tone",
        value: model.binding(\.audio.positional.toneGain),
        range: 0...1, step: 0.01, format: Format.percent)

      ConfigSliderRow(
        title: "Positional error range",
        value: model.binding(\.audio.positional.errorRange),
        range: 0.05...1, step: 0.01, format: Format.percent)

      ConfigSliderRow(
        title: "Heartbeat interval",
        value: model.intBinding(\.feedback.heartbeatIntervalMs),
        range: 1000...30000, step: 500, format: Format.milliseconds)
    } onReset: {
      model.resetToDefault(\.audio)
    }
  }
}
