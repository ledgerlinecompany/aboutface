/// Pure decision logic for §12.3's mismatch warning: "if some device other
/// than the user's selection reports in-use while the selected one does
/// not, warn that the conferencing app may be using a different camera."
/// This file is the classification half only — turning one snapshot of
/// `CMIOAllDevicesBusyReader.currentRunningStates()` plus the selected
/// device's `uniqueID` into a `CameraMismatchClassification`. Debounce and
/// the dismiss/re-arm discipline live in `CameraMismatchStateMachine.swift`,
/// same two-file split `CameraGatingStateMachine`/`CameraGating.swift`
/// established: this file has no notion of time or of a previous call, so
/// it can be tested as a plain pure function over synthetic arrays.
///
/// ## Why §12.3's literal rule cannot fire in the case that matters most
///
/// §12.3, read literally, is "another device running while the SELECTED one
/// is not." That silently assumes About Face itself is not using the
/// selected camera. But `kCMIODevicePropertyDeviceIsRunningSomewhere`
/// (§12.2's finding) reads true for **any** process streaming, including
/// About Face's own Setup/Monitor capture — so the instant this app opens
/// the selected device, the selected device's own reading stops being
/// "not running," and the literal rule can never fire in exactly the
/// scenario the warning exists for: About Face monitoring camera A while
/// the real call is actually on camera B. A user who most needs this
/// warning — because they turned Monitor on for the wrong camera — is
/// precisely the user for whom the literal rule goes permanently silent.
///
/// ## The corrected rule
///
/// **Warn when any non-selected device is running — full stop.** The
/// selected device's own reading is not consulted at all, in either
/// direction: CoreMediaIO cannot attribute a running stream to a process,
/// so "selected device also reads running" is not evidence of anything one
/// way or the other (it is what About Face's own capture always produces
/// while active, and what a well-behaved single-camera call also produces
/// while idle). A conferencing app is presumably on exactly one camera;
/// another camera reading as running, on its own, is the only signal
/// CoreMediaIO can actually give us, regardless of whether About Face is
/// idle or itself capturing at that instant.
///
/// ## The false positive this accepts, honestly
///
/// This rule fires whenever ANY other camera is running, not only when a
/// conferencing app is confusably on it. A genuinely unrelated process —
/// Photo Booth, a second video app, a background utility — polling or
/// briefly opening a different camera while the real call sits correctly on
/// the selected device produces the exact same reading as a real mismatch.
/// CoreMediaIO's API surface gives no way to tell those apart (§12.3: "The
/// API tells you a device is busy, not which app holds it"). This is judged
/// an acceptable trade because §12.3 already designed the surface for it —
/// "informational and dismissible, never blocking" — and because the
/// scenario is unusual: most machines are not running two different
/// camera-consuming apps at once, and this heuristic's false positive costs
/// the user one dismissible notice, not a wrong decision it makes for them.
///
/// ## Failed reads are "not running," but total failure is not "all clear"
///
/// `.deviceNotFound`/`.propertyReadFailed` readings are treated as "not
/// running" for the purposes of the running-device comparison above — a
/// device this call could not read is not asserted to be running. But a
/// reading that could not be taken is not the same claim as a reading that
/// was taken and came back idle, and collapsing the two would repeat
/// exactly the failure §12.2's finding warns about: a signal that "worked"
/// (returned a plausible, non-alarming value) while silently uncertain. So
/// if **every** device in the snapshot failed to read (including an empty
/// snapshot — CoreMediaIO enumeration itself returning nothing), that is
/// reported as `.unreliable`, never silently folded into `.clear`. A single
/// non-selected device failing to read, among others that read
/// successfully, does NOT on its own force `.unreliable` — the readable
/// devices are still real evidence, and §12.3 accepted this same kind of
/// gap for the underlying property already (it reads true for "any
/// process," not just conferencing apps).
public enum CameraMismatchClassification: Sendable, Equatable {
  /// No non-selected device is reading `.running`, and at least one device
  /// in the snapshot read successfully (`.running` or `.idle`) — there is
  /// real evidence, not merely absence of evidence, behind this being
  /// reported as clear.
  case clear
  /// At least one device other than the selected one reads `.running`. See
  /// this file's doc comment for the corrected rule and its accepted false
  /// positive.
  case mismatch
  /// Every device in the snapshot failed to read (`.deviceNotFound` /
  /// `.propertyReadFailed`), including the degenerate case of an empty
  /// snapshot. There is no reliable evidence either way; this must never be
  /// presented as `.clear`.
  case unreliable
}

/// Namespace for the one pure classification function — mirrors
/// `CMIOAllDevicesBusyReader`'s enum-namespace shape (no instance state, one
/// static entry point).
public enum CameraMismatchClassifier {
  /// - Parameters:
  ///   - selectedUniqueID: `Config.Camera.selectedCameraID`. `nil` (no
  ///     camera chosen yet) always classifies as `.clear` — there is no
  ///     user selection for a conferencing app to differ from, so nothing
  ///     to warn about yet. `PipelineModel`'s startup auto-default (see its
  ///     `init` doc comment) is deliberately never routed through the
  ///     persisted selection path either, for an unrelated §16.4 reason —
  ///     both share the same "nothing chosen" starting state, and both are
  ///     handled the same way here.
  ///   - readings: One snapshot from
  ///     `CMIOAllDevicesBusyReader.currentRunningStates()` — every device
  ///     CoreMediaIO could enumerate, keyed by `uniqueID`, at one instant.
  ///     No ordering or freshness assumption is made about this array.
  public static func classify(
    selectedUniqueID: String?,
    readings: [CMIODeviceRunningState]
  ) -> CameraMismatchClassification {
    guard let selectedUniqueID else { return .clear }

    let anyOtherDeviceRunning = readings.contains { device in
      device.uniqueID != selectedUniqueID && device.reading == .running
    }
    if anyOtherDeviceRunning { return .mismatch }

    let anyDeviceReadSuccessfully = readings.contains { device in
      switch device.reading {
      case .running, .idle: return true
      case .deviceNotFound, .propertyReadFailed: return false
      }
    }
    return anyDeviceReadSuccessfully ? .clear : .unreliable
  }
}
