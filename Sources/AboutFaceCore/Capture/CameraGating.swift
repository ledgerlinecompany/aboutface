/// Pure state machine for §12.2's camera-in-use gating policy — deliberately
/// free of any `AVFoundation` import (per the PR brief: "no AVFoundation
/// imports") so it can be exhaustively unit-tested without a live camera,
/// independent of whether `CameraInUseMonitor`'s KVO-vs-polling path is
/// actually live. This is the second, strictly separate layer §12.2 asks
/// for: `CameraInUseMonitor` is the platform probe (raw busy/free signal,
/// `AVFoundation`-backed); this type turns that signal into mode-transition
/// decisions and knows nothing about `AVFoundation` at all. Wiring the
/// emitted `CameraGatingEvent`s to the real app mode controller is a later
/// PR — this one delivers the tested machine plus the probe.
///
/// ## Rules (§12.2, maintainer §16.4 decision)
///
/// | Busy transition | `mode` | `appConfigured` | Event |
/// |---|---|---|---|
/// | free → busy | `.off` | `true` | `.activateMonitor` |
/// | free → busy | `.off` | `false` | *(none — never auto-enable on a fresh unconfigured install)* |
/// | free → busy | `.setup` | — | `.leaveSetup` *(app stops chirping once the call starts)* |
/// | free → busy | `.monitor` | — | *(none — already active)* |
/// | busy → free | `.monitor` | — | `.deactivateMonitor` |
/// | busy → free | `.off` / `.setup` | — | *(none)* |
///
/// Every transition above is gated by `Config.Camera.busyDebounceMs` (§0: no
/// hardcoded threshold) — the busy signal must hold its new value
/// continuously for that long before an event fires, so a device flapping
/// during app startup (or a marginal USB webcam bouncing
/// `isInUseByAnotherApplication`) cannot bounce modes. This mirrors §4/§7's
/// hysteresis-and-dwell requirement applied to positional signals — same
/// shape, different signal.
public struct CameraGatingStateMachine: Sendable {
  private let debounceSeconds: Double

  private var debouncedBusy = false
  private var pendingBusy: Bool?
  private var pendingSince: Double?

  /// - Parameter debounceMs: `Config.Camera.busyDebounceMs` — how long the
  ///   raw busy signal must hold its new value before a transition fires.
  public init(debounceMs: Int) {
    self.debounceSeconds = Double(debounceMs) / 1000
  }

  /// Feeds one new observation. `now` is caller-supplied monotonic seconds
  /// — production callers derive it from e.g. `ContinuousClock`; tests pass
  /// a fully controlled fake clock. This type never reads wall-clock time
  /// itself, which is what makes it exhaustively testable with exact
  /// debounce-timing assertions rather than real sleeps.
  ///
  /// Returns the events (zero or more) to emit as a result of this
  /// observation settling past the debounce window. In practice this is
  /// always zero or one event; an array is returned rather than an optional
  /// so a future rule that legitimately wants to emit more than one event
  /// on the same tick does not need a shape change.
  @discardableResult
  public mutating func update(
    selectedDeviceBusy: Bool,
    appConfigured: Bool,
    mode: CameraGatingMode,
    now: Double
  ) -> [CameraGatingEvent] {
    if selectedDeviceBusy != (pendingBusy ?? debouncedBusy) {
      pendingBusy = selectedDeviceBusy
      pendingSince = now
    }

    guard
      let pendingBusy, let pendingSince,
      pendingBusy != debouncedBusy,
      now - pendingSince >= debounceSeconds
    else {
      return []
    }

    debouncedBusy = pendingBusy
    self.pendingBusy = nil
    self.pendingSince = nil

    return Self.events(busy: debouncedBusy, appConfigured: appConfigured, mode: mode)
  }

  private static func events(
    busy: Bool,
    appConfigured: Bool,
    mode: CameraGatingMode
  ) -> [CameraGatingEvent] {
    if busy {
      switch mode {
      case .off:
        return appConfigured ? [.activateMonitor] : []
      case .setup:
        return [.leaveSetup]
      case .monitor:
        return []
      }
    } else {
      switch mode {
      case .monitor:
        return [.deactivateMonitor]
      case .off, .setup:
        return []
      }
    }
  }
}

/// The subset of app mode state the gating machine needs to know about.
/// Deliberately not `FeedbackMode` (`.setup`/`.monitor`): this machine also
/// needs to represent "neither" (menu-bar-idle, no Setup window open,
/// Monitor not running) to decide whether Monitor may auto-activate at all.
public enum CameraGatingMode: Sendable, Equatable, CaseIterable {
  case off
  case setup
  case monitor
}

/// Mode-transition commands the gating machine emits. Applying these to the
/// real app mode controller is a later PR (see this file's type-level doc
/// comment).
public enum CameraGatingEvent: Sendable, Equatable {
  case activateMonitor
  case deactivateMonitor
  case leaveSetup
}
