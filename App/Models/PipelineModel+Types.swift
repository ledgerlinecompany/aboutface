// swift-format and swiftlint disagree on case-sensitive vs. case-insensitive
// import ordering (see PipelineModel.swift's own import block for the same
// conflict); this order satisfies `swift format lint`, which CI also enforces.
// swiftlint:disable sorted_imports
import AVFoundation
import AboutFaceCore

// swiftlint:enable sorted_imports

/// Small value types `PipelineModel` and the views around it share. Split out
/// of `PipelineModel.swift` purely to stay under this codebase's ≤350-line
/// file-size target (see that file's own type-level doc comment for the
/// fuller "split for file size" precedent) — both types below are otherwise
/// unrelated to each other and to this file's name; they live here only
/// because `PipelineModel.swift` had no more room.

/// Camera-permission state for the Setup window's permission flow (spec
/// §9/§12). Mirrors `AVAuthorizationStatus` with a name that reads cleanly
/// in UI code; `.restricted` (parental controls / MDM) is folded in as its
/// own case because the "ask again" affordance differs from a user-chosen
/// `.denied`.
public enum CameraPermissionState: Sendable, Equatable {
  case notDetermined
  case authorized
  case denied
  case restricted

  init(_ status: AVAuthorizationStatus) {
    switch status {
    case .authorized: self = .authorized
    case .denied: self = .denied
    case .restricted: self = .restricted
    case .notDetermined: self = .notDetermined
    @unknown default: self = .denied
    }
  }
}

/// The throttled, VoiceOver-facing view of the latest engine output — the
/// "one observable accessibility snapshot struct" the Setup window's rows
/// read from (spec §9's "Post `.valueChanged` only for the currently-
/// focused element, throttled to ~2 Hz").
///
/// Deliberately just a wrapper around `[SignalFormatter.FormattedSignal]`
/// today — every row updates in lockstep, at the same ~2 Hz cadence. This
/// is a known, documented simplification for Phase 2 (see
/// `docs/acceptance/phase2-checklist.md`): the spec's stronger form of the
/// requirement is per-*focused*-element throttling, which needs
/// `NSAccessibility` focus tracking this pass deliberately does not build
/// (per the task brief: "do not attempt per-element focus tracking...
/// validated/tuned by the human pass"). Because every row already flows
/// through this one struct, adding a per-row `lastPostedAt` (or a
/// currently-focused-field flag) later is a change to this type only — no
/// view or model rewiring required.
public struct AccessibilitySnapshot: Sendable, Equatable {
  public var rows: [SignalFormatter.FormattedSignal]

  public static let empty = AccessibilitySnapshot(rows: [])

  public func value(for field: SignalFormatter.Field) -> String? {
    rows.first { $0.id == field }?.value
  }
}
