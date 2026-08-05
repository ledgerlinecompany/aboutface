/// §12.4's virtual-camera detection: the pure matcher over
/// `VirtualCameraPatterns.known`. Kept separate from the list itself so the
/// list stays trivial to find and extend (§12.4: "maintain the list in one
/// file") without wading through matching logic.
///
/// ## Why word boundaries, not plain substrings
///
/// `VirtualCameraPatterns`'s own doc comment states the governing principle:
/// over-detection is worse than under-detection, because telling a user
/// their genuine physical camera is fake is its own kind of wrong — and
/// unlike a missed detection, it is a claim the app makes confidently and
/// out loud. A plain case-insensitive substring test would undermine that
/// principle for exactly the entries most at risk from it: the list contains
/// four- and five-character patterns (`Camo`, `mmhmm`) whose letters can
/// easily fall inside a longer token in some device's name, or inside a
/// localized name in another language.
///
/// So a pattern matches only when it appears as a whole word or whole
/// multi-word phrase — bounded on both sides by a non-alphanumeric
/// character or the end of the string. "Camo" matches `Camo` and
/// `Reincubate Camo`; it does not match a hypothetical `Camouflage Cam`.
/// This is a deliberate trade: it can only ever REDUCE the set of names that
/// match, which is the safe direction to be wrong in for this particular
/// check.
///
/// Boundary detection is hand-rolled against `Character.isLetter`/
/// `isNumber` rather than a regex — the rule is small enough that a regex
/// would be harder to verify at a glance than the loop, and this runs on a
/// device list of single digits, never on a hot path.
public enum VirtualCameraClassifier {
  /// The known virtual-camera product whose pattern matched a device name,
  /// or `nil` if none did. Returns the whole `Entry` rather than a `Bool` so
  /// callers can name the matched product to the user: §12.4's warning is
  /// only actionable if the user can tell instantly whether it is right
  /// ("yes, I'm on OBS") or a false positive ("no, that's my actual
  /// webcam"), and naming what matched is what makes that judgment possible
  /// in one beat. The entry's `note` is maintainer-facing and deliberately
  /// NOT for display.
  public static func match(displayName: String) -> VirtualCameraPatterns.Entry? {
    VirtualCameraPatterns.known.first { entry in
      contains(displayName, wholeWord: entry.pattern)
    }
  }

  /// Case-insensitive whole-word/whole-phrase containment. `pattern` must
  /// appear in `name` bounded on both sides by a non-alphanumeric character
  /// or a string edge. An empty pattern never matches — a list entry with an
  /// empty pattern is a data error, and matching everything would be the
  /// worst possible interpretation of it.
  static func contains(_ name: String, wholeWord pattern: String) -> Bool {
    guard !pattern.isEmpty else { return false }
    let haystack = Array(name.lowercased())
    let needle = Array(pattern.lowercased())
    guard haystack.count >= needle.count else { return false }

    for start in 0...(haystack.count - needle.count) {
      let end = start + needle.count
      guard Array(haystack[start..<end]) == needle else { continue }
      let beforeOK = start == 0 || !isWordCharacter(haystack[start - 1])
      let afterOK = end == haystack.count || !isWordCharacter(haystack[end])
      if beforeOK && afterOK { return true }
    }
    return false
  }

  /// What counts as "inside a word" for boundary purposes. Letters and
  /// numbers only: a device name like `OBS Virtual Camera (2)` or
  /// `Camo-Camera` should still match its pattern, since punctuation and
  /// whitespace are genuine separators.
  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
  }
}
