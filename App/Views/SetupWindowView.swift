import AboutFaceCore
import Accessibility
import SwiftUI

/// The Setup window (spec §5.1, §9): "A real window means every signal
/// becomes a VoiceOver-navigable element with an actual value." This view
/// is the accessible value list plus the controls the task brief calls out
/// explicitly — camera picker, start/stop, current state line, and
/// "capture current position as target" (§4).
///
/// Deliberately thin (CLAUDE.md: "keep `App/` thin") — every value shown
/// here is already a formatted string from `SignalFormatter`/
/// `PipelineModel`; this view does no signal math of its own.
struct SetupWindowView: View {
  @Bindable var model: PipelineModel
  let hotkeyCenter: HotkeyCenter
  let monitorReminderController: MonitorReminderController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      Section("Camera") {
        permissionSection
        cameraPickerRow
        startStopRow
        stateLineRow
        captureTargetRow
      }

      Section("Feedback") {
        feedbackToggleRow
        silenceToggleRow
        openDebugPanelRow
        if let message = model.audioUnavailableMessage {
          Text(message)
            .foregroundStyle(.secondary)
        }
      }

      Section("Signals") {
        ForEach(model.accessibilitySnapshot.rows) { row in
          SignalRow(row: row)
        }
      }

      if let issue = model.configLoadIssue {
        Section("Configuration") {
          configLoadIssueRow(issue)
        }
      }

      if let message = model.captureErrorMessage {
        Section("Capture error") {
          Text(message)
            .foregroundStyle(.red)
        }
      }

      // §12.2/§16.4: `MonitorReminderController` couldn't resolve the
      // selected camera to a CoreMediaIO device — never a silent no-op,
      // see `PipelineModel.monitorReminderIssue`'s doc comment.
      if let message = model.monitorReminderIssue {
        Section("Camera-in-use reminder") {
          Text(message)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("About Face — Setup")
    .task {
      await model.requestCameraPermission()
    }
    .task { hotkeyBootstrap() }
    .onChange(of: model.config.hotkeys) { _, newValue in
      hotkeyCenter.updateRegistrations(newValue)
    }
    .task { monitorReminderBootstrap() }
    .onChange(of: model.selectedCameraID) { _, _ in
      monitorReminderController.deviceChanged()
    }
    .onChange(of: model.config) { oldValue, newValue in
      monitorReminderController.configChanged(old: oldValue, new: newValue)
    }
  }

  /// §8 global hotkeys: wires `hotkeyCenter` to `model` and to this view's
  /// own `@Environment(\.openWindow)` action, once, at Setup-window launch.
  /// This is the Setup `WindowGroup`'s content view specifically (rather
  /// than `AboutFaceApp` itself) because `openWindow` is a View-environment
  /// action — `HotkeyCenter`'s `setupToggle` handler needs a concrete
  /// "open/focus the Setup window" closure (§8: "opens/focuses the
  /// window"), and this is the one view guaranteed to exist by the time a
  /// global hotkey can fire (the Setup `WindowGroup` is `AboutFaceApp`'s
  /// first scene, so SwiftUI presents it automatically at launch).
  private func hotkeyBootstrap() {
    hotkeyCenter.configure(model: model, openSetupWindow: { openWindow(id: "setup") })
  }

  /// §12.2/§16.4: wires `monitorReminderController` to `model`, once, at
  /// Setup-window launch — same "first view guaranteed to exist at launch"
  /// reasoning as `hotkeyBootstrap()` above, since this reminder must work
  /// with no window focused.
  private func monitorReminderBootstrap() {
    monitorReminderController.configure(model: model)
  }

  // MARK: - Camera permission

  @ViewBuilder
  private var permissionSection: some View {
    switch model.permissionState {
    case .authorized:
      EmptyView()
    case .notDetermined:
      Text("Waiting for camera permission…")
        .foregroundStyle(.secondary)
    case .denied, .restricted:
      VStack(alignment: .leading, spacing: 6) {
        Text("About Face needs camera access to analyze your framing.")
        Button("Open System Settings") {
          model.openSystemSettingsForCameraPrivacy()
        }
      }
    }
  }

  // MARK: - Camera picker (§9: "device name + uniqueID")

  /// Bound through `PipelineModel.selectCamera(_:)`, NOT a plain
  /// `$model.selectedCameraID` binding — this Picker is the one place in
  /// the app that knows a HUMAN chose a camera (§12.1), and `selectCamera
  /// (_:)` is the only call site allowed to persist that choice into
  /// `Config.Camera.selectedCameraID` (see that method's doc comment for
  /// why `PipelineModel.init()`'s fresh-install auto-default must never go
  /// through this same path).
  private var cameraPickerRow: some View {
    Picker(
      "Camera",
      selection: Binding(
        get: { model.selectedCameraID },
        set: { model.selectCamera($0) }
      )
    ) {
      Text("Select a camera").tag(String?.none)
      ForEach(model.cameraDiscovery.devices) { device in
        Text("\(device.displayName) (\(device.id))")
          .tag(String?.some(device.id))
      }
    }
    .disabled(model.isRunning)
  }

  private var startStopRow: some View {
    HStack {
      Button(model.isRunning ? "Stop" : "Start") {
        Task {
          if model.isRunning {
            await model.stop()
          } else {
            await model.start()
          }
        }
      }
      .disabled(model.permissionState != .authorized || model.selectedCameraID == nil)

      Spacer()
    }
  }

  /// The "current state line (signalState words)" the task brief asks for.
  /// A single VoiceOver-navigable element with a label distinct from its
  /// live value, same convention as every row in `SignalRow`.
  private var stateLineRow: some View {
    HStack {
      Text("State")
      Spacer()
      Text(model.signalStateLine)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("State")
    .accessibilityValue(model.signalStateLine)
  }

  /// "Capture current position as target" (§4's v1 primitive; global
  /// hotkey ⌘⌃⇧T is out of scope for this window-focused button — see the
  /// Phase 2 checklist for what remains hotkey-wired in a later phase).
  private var captureTargetRow: some View {
    Button("Capture current position as target") {
      let captured = model.captureCurrentPositionAsTarget()
      if !captured {
        AccessibilityNotification.Announcement("No face detected — nothing to capture").post()
      }
    }
    .disabled(!model.isRunning)
  }

  // MARK: - Feedback (§5.1, §7.5, §13 Phase 3)

  /// "A 'Feedback' toggle (on by default when pipeline runs)" (task brief).
  private var feedbackToggleRow: some View {
    Toggle(
      "Feedback",
      isOn: Binding(
        get: { model.feedbackEnabled },
        set: { model.setFeedbackEnabled($0) }
      )
    )
    .accessibilityHint(
      "Turns audio and speech feedback on or off. Analysis keeps running either way."
    )
    // Field finding: controls that do nothing before Start are confusing
    // (and, for VoiceOver, actionable-sounding); dim them until running.
    .disabled(!model.isRunning)
  }

  /// §7.5's "someone just started talking to me" instant mute — cuts audio
  /// within one render buffer while analysis keeps running. ⌘⌃⇧/ here is an
  /// in-app SwiftUI `.keyboardShortcut` stand-in for the GLOBAL
  /// `RegisterEventHotKey` binding §8 requires (so this also works while
  /// About Face isn't focused) — that global binding is Phase 4/5 scope; see
  /// `PipelineModel+Audio.swift`'s `toggleSilence()` doc comment.
  private var silenceToggleRow: some View {
    Button(model.isSilenced ? "Unsilence" : "Silence") {
      model.toggleSilence()
    }
    .keyboardShortcut("/", modifiers: [.command, .control, .shift])
    .accessibilityLabel(model.isSilenced ? "Unsilence feedback" : "Silence feedback")
    .accessibilityHint(
      "Command Control Shift Slash. Immediately cuts audio and speech feedback; analysis keeps "
        + "running. This is a temporary in-app stand-in for the global shortcut planned for a "
        + "later release.")
  }

  private func configLoadIssueRow(_ issue: ConfigStore.LoadIssue) -> some View {
    Group {
      switch issue {
      case .missing:
        Text("No saved configuration found — using defaults.")
      case .corruptBackedUp(let backupURL):
        Text(
          "Your saved configuration could not be read and was reset to defaults. "
            + "The original file was kept at \(backupURL.path)."
        )
      }
    }
    .foregroundStyle(.secondary)
    .disabled(!model.isRunning)
  }
}

/// One §9 accessible value row: a single VoiceOver element
/// (`.accessibilityElement(children: .ignore)`) whose label is the field
/// name and whose value is `SignalFormatter`'s live formatted string. The
/// visual layout (label left, value right) is incidental — VoiceOver never
/// sees the two `Text`s as separate elements, only the combined
/// label/value pair set explicitly below.
private struct SignalRow: View {
  let row: SignalFormatter.FormattedSignal

  var body: some View {
    HStack {
      Text(row.label)
      Spacer()
      Text(row.value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.label)
    .accessibilityValue(row.value)
  }
}

extension SetupWindowView {
  /// Every tuning control (§9's sliders, Scheme B toggle, export/import)
  /// lives in the Debug Panel — a separate window that previously had NO
  /// in-app affordance and was reachable only through the menu bar's
  /// Window menu, which nothing announced (maintainer field finding:
  /// "there's actually no way I can find to get to the settings panel").
  /// Function-before-key phrasing per the recorder conventions.
  var openDebugPanelRow: some View {
    Button("Open tuning panel") {
      openWindow(id: "debug-panel")
    }
    .keyboardShortcut("d", modifiers: [.command])
    .accessibilityHint(
      "Opens the Debug Panel window with every tuning slider, the refinement-click toggle, and "
        + "profile export and import. Also available with Command D, or in the Window menu.")
  }
}
