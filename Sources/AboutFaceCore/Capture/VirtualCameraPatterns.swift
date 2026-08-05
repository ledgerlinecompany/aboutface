/// §12.4's "match against known virtual-camera name patterns (maintain the
/// list in one file)": the list, and nothing else. `VirtualCameraClassifier
/// .swift` is the pure matcher that consumes it; this file exists purely so
/// the list itself is trivial to find and extend without wading through
/// matching logic.
///
/// ## This list is heuristic and known-incomplete — read this before adding
/// entries or being surprised later
///
/// §12.4: "This cannot be reliably detected from device type." There is no
/// API that tells you a capture device is virtual, let alone that it is fed
/// by a physical camera rather than a synthetic source. All this file can
/// do is match the device's `localizedName` against strings known, today, to
/// belong to specific virtual-camera products. That means two failure modes
/// are permanent, not bugs to be fixed later:
///
/// - **A virtual camera not on this list produces no warning at all.** New
///   products ship, existing ones rename their device, users run something
///   obscure or self-built. This is silent under-detection, exactly the kind
///   §12.4 exists to worry about generally — but there is no more reliable
///   signal available to close the gap with (see the section's own "cannot
///   be reliably detected from device type").
/// - **An entry here is a real product's ACTUAL registered capture-device
///   name**, not a guess at one. Every entry below is something the author
///   is confident is real, in current or recent use, and macOS-capable — see
///   each entry's `note`. Padding this list with plausible-sounding names
///   nobody verified would trade under-detection for over-detection, and
///   over-detection is worse: it tells a user their genuine physical camera
///   is fake. When adding an entry, verify the actual device name (not just
///   the product name) if at all possible, and record the confidence level
///   in the note rather than silently presenting a guess as established
///   fact.
///
/// Matching itself (case-insensitive substring against the whole
/// `localizedName`) lives in `VirtualCameraClassifier.swift`, not here.
public enum VirtualCameraPatterns {
  /// One known virtual-camera product: the substring to match (against a
  /// device's `localizedName`, case-insensitively — see
  /// `VirtualCameraClassifier.matches(displayName:)`) and a human-readable
  /// note on what it identifies and how confident this list is in the entry.
  public struct Entry: Sendable, Equatable {
    public let pattern: String
    public let note: String

    public init(pattern: String, note: String) {
      self.pattern = pattern
      self.note = note
    }
  }

  // swift-format wants a trailing comma on the last element of a multiline
  // collection literal; swiftlint's trailing_comma rule forbids one. Same
  // tool disagreement noted throughout this codebase — format wins.
  // swiftlint:disable trailing_comma
  /// Seeded 2026-08-04, for §12.4. Deliberately short — see this file's doc
  /// comment on why padding this with unverified guesses is worse than
  /// leaving a gap.
  public static let known: [Entry] = [
    Entry(
      pattern: "OBS Virtual Camera",
      note: "OBS Studio's built-in virtual camera output — named explicitly in §12.4 itself. "
        + "High confidence: this is OBS's actual registered macOS device name."
    ),
    Entry(
      pattern: "Snap Camera",
      note: "Snap Inc.'s lens/filter virtual camera — also named explicitly in §12.4. "
        + "Snap discontinued it January 2023, but installs persist on machines that had it, so "
        + "the device can still appear in a picker years later. High confidence in the name."
    ),
    Entry(
      pattern: "CamTwist",
      note: "CamTwist, a long-standing macOS-only video-effects/virtual-camera utility "
        + "popular with streamers. High confidence: macOS-specific, distinctive name."
    ),
    Entry(
      pattern: "ManyCam",
      note: "ManyCam, a cross-platform (Windows/macOS) virtual camera and live-switching "
        + "tool. High confidence: distinctive name, in active use."
    ),
    Entry(
      pattern: "Camo",
      note: "Reincubate Camo — turns an iPhone/iPad into a webcam via a virtual camera "
        + "device, widely used for podcasting/streaming on macOS. Medium-high confidence: "
        + "the product and its macOS support are well established; the exact device-name "
        + "string is more likely to drift across app versions than the others in this list, "
        + "being a short common word rather than a multi-word brand name."
    ),
    Entry(
      pattern: "mmhmm",
      note: "mmhmm's virtual camera for video calls (branded backgrounds/effects). "
        + "Medium-high confidence: distinctive name, was widely adopted for video calls "
        + "specifically — the exact scenario §12.4 warns about."
    ),
    Entry(
      pattern: "EpocCam",
      note: "Kinoni EpocCam, a phone-as-webcam app with a macOS virtual camera driver. "
        + "Medium-high confidence: distinctive name, long-standing product."
    ),
  ]
  // swiftlint:enable trailing_comma
}
