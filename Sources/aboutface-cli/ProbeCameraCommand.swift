import AboutFaceCore
import ArgumentParser

/// `aboutface-cli probe-camera` — the §12.6 "concurrent access test":
/// "Write an explicit test/tool that opens the selected device **while
/// another app holds it** and logs the format actually granted. Do not
/// assume the requested format is honored."
///
/// Run this while a conferencing app (Zoom, FaceTime, whatever) already has
/// the same camera open, to see whether this app still gets the exact
/// format it asked for or whether AVFoundation silently substitutes
/// something else under concurrent access.
///
/// Output is plain text, one fact per line — no tables, no ASCII art — since
/// this is meant to be run by a blind maintainer in Terminal, read line by
/// line with VoiceOver.
struct ProbeCamera: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "probe-camera",
    abstract:
      "Open a camera and report the format actually granted, plus whether another app has it open.",
    discussion: """
      Opens the selected (or --device-named) camera, requests --width x --height @ --fps \
      (default 640x480@15 -- §5.2's Monitor format), waits for one delivered frame, then prints \
      what was ACTUALLY granted: the device's own activeFormat reading, and the dimensions/pixel \
      format read directly off the first delivered frame -- these can disagree under concurrent \
      access, which is exactly what this tool exists to surface. Also prints \
      isInUseByAnotherApplication, read BEFORE this tool opens its own session, so it reflects \
      only other processes.

      Run this while another app (Zoom, FaceTime, ...) already has the same camera open, to \
      empirically check whether the requested format is honored under concurrent access (§12.6).
      """
  )

  @Option(
    help:
      "AVCaptureDevice.uniqueID of the camera to open. Defaults to the system default video device."
  )
  var device: String?

  @Option(help: "Requested capture width in pixels.")
  var width = 640

  @Option(help: "Requested capture height in pixels.")
  var height = 480

  @Option(help: "Requested capture frame rate in fps.")
  var fps: Double = 15

  @Option(help: "Seconds to wait for a delivered frame before giving up.")
  var timeout: Double = 5

  func run() async throws {
    let result: CameraFormatProbe.Result
    do {
      result = try await CameraFormatProbe.probe(
        deviceUniqueID: device, width: width, height: height, frameRate: fps,
        frameTimeoutSeconds: timeout)
    } catch {
      print("Could not probe the camera: \(Self.describe(error)).")
      throw ExitCode.failure
    }
    Self.printResult(result)
  }

  private static func printResult(_ result: CameraFormatProbe.Result) {
    print("device: \(result.deviceLocalizedName) (\(result.deviceUniqueID))")
    print(
      "requested format: \(result.requestedWidth)x\(result.requestedHeight) "
        + "at \(formatted(result.requestedFrameRate)) fps")
    print(
      "device reports an exact matching format: \(result.exactFormatMatchFound ? "yes" : "no")")
    print(
      "session preset for requested size applied: \(result.sessionPresetMatched ? "yes" : "no")")
    if !result.sessionPresetMatched {
      print(
        "note: no known session preset for this size -- used the session's default preset "
          + "instead. See below for what that actually granted.")
    }
    print(
      "device active format granted (read after start, after first frame): "
        + "\(result.deviceGrantedWidth)x\(result.deviceGrantedHeight) "
        + "at \(formatted(result.deviceGrantedFrameRate)) fps")
    print(
      "delivered frame: \(result.deliveredFrameWidth)x\(result.deliveredFrameHeight), "
        + "pixel format \(result.deliveredPixelFormat)")
    print("in use by another application: \(result.isInUseByAnotherApplication ? "yes" : "no")")

    let dimensionsDisagree =
      result.deviceGrantedWidth != result.deliveredFrameWidth
      || result.deviceGrantedHeight != result.deliveredFrameHeight
    if dimensionsDisagree {
      print(
        "note: device active format and delivered frame dimensions DISAGREE -- "
          + "the requested format was not honored as-is.")
    }

    let requestedDishonored =
      result.deviceGrantedWidth != result.requestedWidth
      || result.deviceGrantedHeight != result.requestedHeight
    if requestedDishonored {
      print(
        "note: granted format does not match the REQUESTED format -- "
          + "requested \(result.requestedWidth)x\(result.requestedHeight), "
          + "granted \(result.deviceGrantedWidth)x\(result.deviceGrantedHeight).")
    }
  }

  private static func formatted(_ value: Double) -> String {
    String(format: "%.2f", value)
  }

  private static func describe(_ error: Error) -> String {
    guard let probeError = error as? CameraFormatProbe.ProbeError else {
      return "\(error)"
    }
    switch probeError {
    case .deviceNotFound(let id):
      return "no camera with uniqueID \(id) was found"
    case .noDefaultDevice:
      return "no default video device was found (e.g. headless CI/no hardware)"
    case .noFormatsAvailable:
      return "the device reported no capture formats at all"
    case .cannotAddInput:
      return "the capture session could not add the device as an input"
    case .cannotAddOutput:
      return "the capture session could not add a video data output"
    case .noVideoConnection:
      return "the video data output has no video connection"
    case .timedOutWaitingForFrame:
      return "timed out waiting for a delivered frame -- is the camera actually producing frames?"
    }
  }
}
