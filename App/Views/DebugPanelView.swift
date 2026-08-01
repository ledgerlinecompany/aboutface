import AboutFaceCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The debug / advanced panel (spec §9): "Every threshold, dead zone, dwell
/// time, and mapping curve is a live slider bound to `Config`." One
/// `Section` per group the task brief names — Target framing, Dead zone &
/// hysteresis, Smoothing, Signal thresholds, Gaze, Lighting — covering
/// every numeric `Config` field except `version` (schema versioning, not a
/// tuning knob).
struct DebugPanelView: View {
  @Bindable var model: PipelineModel

  @State private var showingGlobalResetConfirmation = false
  @State private var importErrorMessage: String?

  var body: some View {
    Form {
      exportImportSection

      ConfigSection(title: "Target framing") {
        ConfigSliderRow(
          title: "Eye midpoint, horizontal",
          value: model.binding(\.targetFraming.eyeMidpointX),
          range: 0...1, step: 0.01, format: Format.percent)
        ConfigSliderRow(
          title: "Eye midpoint, from top",
          value: model.binding(\.targetFraming.eyeMidpointY),
          range: 0...1, step: 0.01, format: Format.percent)
        ConfigSliderRow(
          title: "Interocular width",
          value: model.binding(\.targetFraming.interocularWidth),
          range: 0.02...0.5, step: 0.005, format: Format.percent)
      } onReset: {
        model.resetToDefault(\.targetFraming)
      }

      ConfigSection(title: "Dead zone & hysteresis") {
        ConfigSliderRow(
          title: "Dead zone, horizontal",
          value: model.binding(\.deadZone.horizontal),
          range: 0...0.3, step: 0.005, format: Format.percent)
        ConfigSliderRow(
          title: "Dead zone, vertical",
          value: model.binding(\.deadZone.vertical),
          range: 0...0.3, step: 0.005, format: Format.percent)
        ConfigSliderRow(
          title: "Hysteresis exit ratio",
          value: model.binding(\.hysteresisExitRatio),
          range: 1...3, step: 0.05, format: Format.ratio)
        ConfigSliderRow(
          title: "Dwell time",
          value: model.intBinding(\.dwellMs),
          range: 0...3000, step: 50, format: Format.milliseconds)
      } onReset: {
        model.resetToDefault(\.deadZone)
        model.resetToDefault(\.hysteresisExitRatio)
        model.resetToDefault(\.dwellMs)
      }

      ConfigSection(title: "Smoothing") {
        ConfigSliderRow(
          title: "Smoothing window",
          value: model.intBinding(\.smoothingWindow),
          range: 1...30, step: 1, format: Format.frames)
      } onReset: {
        model.resetToDefault(\.smoothingWindow)
      }

      ConfigSection(title: "Signal thresholds") {
        ConfigSliderRow(
          title: "No-signal luma variance threshold",
          value: model.binding(\.signal.noSignalLumaVarianceThreshold),
          range: 0...0.01, step: 0.0001, format: Format.rawFourDecimals)
        ConfigSliderRow(
          title: "Low-confidence threshold",
          value: model.binding(\.signal.lowConfidenceThreshold),
          range: 0...1, step: 0.01, format: Format.percent)
      } onReset: {
        model.resetToDefault(\.signal)
      }

      ConfigSection(title: "Gaze") {
        ConfigSliderRow(
          title: "Max yaw for gaze-on-camera",
          value: model.binding(\.gaze.maxYawDegrees),
          range: 0...45, step: 1, format: Format.degrees)
        ConfigSliderRow(
          title: "Max pitch for gaze-on-camera",
          value: model.binding(\.gaze.maxPitchDegrees),
          range: 0...45, step: 1, format: Format.degrees)
      } onReset: {
        model.resetToDefault(\.gaze)
      }

      ConfigSection(title: "Lighting") {
        ConfigSliderRow(
          title: "Clipped highlight threshold",
          value: model.binding(\.lighting.clippedHighlightThreshold),
          range: 0...1, step: 0.01, format: Format.percent)
        ConfigSliderRow(
          title: "Clipped shadow threshold",
          value: model.binding(\.lighting.clippedShadowThreshold),
          range: 0...1, step: 0.01, format: Format.percent)
        ConfigSliderRow(
          title: "Max analysis width",
          value: model.intBinding(\.lighting.maxAnalysisWidth),
          range: 64...960, step: 16, format: Format.pixels)
        ConfigSliderRow(
          title: "Sharpness normalization divisor",
          value: model.binding(\.lighting.sharpnessNormalizationDivisor),
          range: 0.001...0.1, step: 0.001, format: Format.rawFourDecimals)
      } onReset: {
        model.resetToDefault(\.lighting)
      }

      ConfigSection(title: "Display quantization") {
        ConfigSliderRow(
          title: "Degrees step",
          value: model.binding(\.display.degreesStep),
          range: 1...10, step: 1, format: Format.rawDegreesStep)
        ConfigSliderRow(
          title: "Percent step",
          value: model.binding(\.display.percentStep),
          range: 1...10, step: 1, format: Format.rawPercentStep)
        ConfigSliderRow(
          title: "Normalized step",
          value: model.binding(\.display.normalizedStep),
          range: 0.005...0.1, step: 0.005, format: Format.rawFourDecimals)
      } onReset: {
        model.resetToDefault(\.display)
      }

      Section {
        Button("Reset all to defaults", role: .destructive) {
          showingGlobalResetConfirmation = true
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("About Face — Debug Panel")
    .confirmationDialog(
      "Reset every setting to its default value?",
      isPresented: $showingGlobalResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset All", role: .destructive) {
        model.resetAllToDefaults()
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      "Couldn't import configuration",
      isPresented: Binding(
        get: { importErrorMessage != nil },
        set: { if !$0 { importErrorMessage = nil } }
      )
    ) {
      Button("OK") { importErrorMessage = nil }
    } message: {
      Text(importErrorMessage ?? "")
    }
  }

  // MARK: - Export / import (§9: "This matters more than it sounds")

  private var exportImportSection: some View {
    Section("Tuning profile") {
      HStack {
        Button("Export…") { exportConfig() }
        Button("Import…") { importConfig() }
        Spacer()
      }
    }
  }

  /// `NSSavePanel` (task brief: "sandbox-safe, user-selected file access").
  private func exportConfig() {
    let panel = NSSavePanel()
    panel.title = "Export About Face Configuration"
    panel.nameFieldStringValue = "AboutFace-config.json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try model.exportConfig(to: url)
    } catch {
      importErrorMessage = PipelineModel.describe(error)
    }
  }

  /// `NSOpenPanel`, surfacing `importConfig` errors — including the
  /// `newerVersion` message — as an alert (task brief).
  private func importConfig() {
    let panel = NSOpenPanel()
    panel.title = "Import About Face Configuration"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try model.importConfig(from: url)
    } catch {
      importErrorMessage = PipelineModel.describe(error)
    }
  }
}

/// A titled group of `ConfigSliderRow`s plus a per-section "Reset to
/// defaults" button (spec §9: "Reset-to-default per section and
/// globally").
private struct ConfigSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  let onReset: () -> Void

  var body: some View {
    Section {
      content
      Button("Reset \(title.lowercased()) to defaults") {
        onReset()
      }
      .buttonStyle(.borderless)
    } header: {
      Text(title)
    }
  }
}

/// One live slider bound to a single `Config` field (spec §9: "All sliders
/// MUST be accessible with proper value descriptions and increment
/// actions"). The `Slider` itself carries the accessibility label and
/// value — SwiftUI's `Slider` is natively `.adjustable`, so VoiceOver's
/// swipe-up/down increment/decrement gestures work for free; this view's
/// job is only to make sure `.accessibilityValue` reads as a real unit
/// ("42 percent") rather than a bare number ("0.42", task brief's explicit
/// example of what NOT to do).
private struct ConfigSliderRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let format: (Double) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
          .accessibilityHidden(true)
        Spacer()
        Text(format(value))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityHidden(true)
      }
      Slider(value: $value, in: range, step: step)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
  }
}

/// Unit-aware value formatting for `ConfigSliderRow` (task brief: "42
/// percent," not "0.42").
private enum Format {
  static func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded())) percent"
  }

  static func rawDegreesStep(_ value: Double) -> String {
    "\(Int(value.rounded())) degrees per step"
  }

  static func rawPercentStep(_ value: Double) -> String {
    "\(Int(value.rounded())) percent per step"
  }

  static func degrees(_ value: Double) -> String {
    "\(Int(value.rounded())) degrees"
  }

  static func milliseconds(_ value: Double) -> String {
    "\(Int(value.rounded())) milliseconds"
  }

  static func frames(_ value: Double) -> String {
    let count = Int(value.rounded())
    return "\(count) \(count == 1 ? "frame" : "frames")"
  }

  static func pixels(_ value: Double) -> String {
    "\(Int(value.rounded())) pixels"
  }

  static func ratio(_ value: Double) -> String {
    String(format: "%.2f times", value)
  }

  static func rawFourDecimals(_ value: Double) -> String {
    String(format: "%.4f", value)
  }
}
