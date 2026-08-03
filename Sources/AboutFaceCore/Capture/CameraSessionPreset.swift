import AVFoundation

/// Maps a requested capture size to a concrete `AVCaptureSession.Preset` —
/// shared by `CameraCaptureSource` and `CameraFormatProbe` so both take
/// exactly the same path to a granted format.
///
/// ## Why a preset, not `AVCaptureDevice.activeFormat`
///
/// Empirically (found via `probe-camera`, §12.6 — see
/// `CameraCaptureSource.configureSession`'s doc comment for the full
/// story): setting `device.activeFormat` directly does **not** survive
/// `session.startRunning()` on macOS, regardless of when it's set relative
/// to `addInput`/`commitConfiguration`. The `AVCaptureSessionPreset` header
/// describes setting the active format on an attached device as switching
/// the session to `.inputPriority` behavior — but `.inputPriority` itself
/// is `API_UNAVAILABLE` on macOS, and no such automatic switch happens
/// there; `startRunning()` just reverts the session back to whatever
/// `sessionPreset` says (`.high` → 1920×1080 by default). Setting the
/// SESSION's `sessionPreset` instead is what actually sticks through
/// `startRunning()`.
///
/// Only the exact sizes the spec ever requests are mapped: §5.1 Setup
/// (1280×720), §5.2 Monitor (640×480). 1920×1080 is included since it's
/// `.high`'s native resolution on the reference hardware (FaceTime HD
/// Camera) and a plausible future size, not because anything currently
/// requests it. Unknown sizes have no preset to map to — callers decide how
/// to handle that: `CameraCaptureSource` throws (the spec only ever
/// requests known sizes, so this should not happen in practice);
/// `CameraFormatProbe` falls back to the session's default preset and
/// reports the resulting mismatch, since surfacing exactly that kind of
/// disagreement is the probe's whole job.
enum CameraSessionPreset {
  static func preset(forWidth width: Int, height: Int) -> AVCaptureSession.Preset? {
    switch (width, height) {
    case (640, 480): return .vga640x480
    case (1280, 720): return .hd1280x720
    case (1920, 1080): return .hd1920x1080
    default: return nil
    }
  }
}
