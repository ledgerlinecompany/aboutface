/// Static description of the spec §14 corpus's 20 clips: recording slugs
/// and eyes-free setup instructions, shared by `record-corpus` and
/// `verify-corpus`.
///
/// Deliberately kept independent of `Fixtures/corpus/manifest.json`'s own
/// `file`/`description`/`expectedCondition`/`notes` fields (see
/// `CorpusManifest`): a clip's on-disk filename is always
/// `<NN>-<slug>.mov`, computed the same way by both commands purely from
/// its position in this array — matching the worked example in the task
/// brief ("01-reference.mov"). Neither command reads or writes
/// `manifest.json`'s `file` field (which ships empty for every entry); that
/// avoids the two commands needing to agree on a JSON-rewrite format for a
/// shared fixture file, and keeps `manifest.json` itself untouched by
/// recording activity. `description`/`expectedCondition`/`notes` — the
/// fields that carry tuning-relevant meaning — still come from
/// `manifest.json` itself, loaded fresh each run, so editing the manifest's
/// wording (not its `file` field) is immediately reflected in both
/// commands.
enum CorpusCatalog {
  struct ClipScript: Sendable {
    /// 1-based position in the spec §14 list; matches `manifest.json`'s
    /// array order (`CorpusManifest.load` validates the counts match).
    let index: Int
    let slug: String
    /// Eyes-free setup instructions, printed/spoken IN ADDITION to the
    /// manifest entry's `description` (the action line) — see
    /// `RecordCorpus`'s instruction-block builder. Empty for clips where
    /// the description alone is fully actionable without further setup.
    let setup: [String]
    /// This clip's own recording duration, in seconds — the default for
    /// every clip is 15s; a few clips whose choreography needs more room
    /// (see each clip's own comment below) specify a longer value.
    /// `record-corpus --seconds` overrides this for every clip, but only
    /// when passed explicitly (see `RecordCorpus.seconds`'s doc comment).
    let durationSeconds: Int

    init(index: Int, slug: String, setup: [String], durationSeconds: Int = 15) {
      self.index = index
      self.slug = slug
      self.setup = setup
      self.durationSeconds = durationSeconds
    }

    var filename: String {
      "\(String(format: "%02d", index))-\(slug).mov"
    }
  }

  // swiftlint and swift-format disagree on trailing commas in multiline collection
  // literals (swift-format requires them, swiftlint's default forbids them); this
  // block satisfies `swift format lint`, which the CI gate also enforces.
  // swiftlint:disable trailing_comma
  static let clips: [ClipScript] = [
    ClipScript(
      index: 1, slug: "reference",
      setup: [
        "Set up: normal room lighting, face the camera directly, sit at a comfortable "
          + "distance, roughly arm's length away."
      ]),
    ClipScript(
      index: 2, slug: "backlit",
      setup: [
        "Set up: sit with a bright window or lamp BEHIND you, so the camera sees it over "
          + "your shoulder. Your face should look dark to the camera."
      ]),
    ClipScript(
      index: 3, slug: "side-lit",
      setup: [
        "Set up: one lamp to your left or right at head height, other lights off."
      ]),
    ClipScript(
      index: 4, slug: "dim",
      setup: [
        "Set up: lights off, blinds closed — as dark as you can get while still finding "
          + "your chair."
      ]),
    ClipScript(
      index: 5, slug: "too-close",
      setup: [
        "Lean in until your face fills the frame — closer than feels natural."
      ]),
    ClipScript(
      index: 6, slug: "too-far",
      setup: [
        "Sit or stand back — at least arm's length beyond normal, small in frame."
      ]),
    ClipScript(
      index: 7, slug: "off-left",
      setup: [
        "Set up: shift your whole body and chair to YOUR OWN left, so you end up "
          + "off-center to your own left while still facing the camera directly."
      ]),
    ClipScript(
      index: 8, slug: "off-right",
      setup: [
        "Set up: shift your whole body and chair to YOUR OWN right, so you end up "
          + "off-center to your own right while still facing the camera directly."
      ]),
    ClipScript(
      index: 9, slug: "too-high",
      setup: [
        "Set up: raise your seated position, or lower the laptop or camera, until your "
          + "face sits at the very TOP of frame — eyes near the top edge, forehead and "
          + "hairline cropped off."
      ]),
    ClipScript(
      index: 10, slug: "too-low",
      setup: [
        "Set up: lower your seated position, or raise the laptop or camera, until your "
          + "face sits at the very BOTTOM of frame — chin near the bottom edge, top of "
          + "your head cropped off."
      ]),
    ClipScript(
      index: 11, slug: "looking-down",
      setup: [
        "Keep your body centered; look DOWN at an imaginary second monitor below the "
          + "camera for the whole clip."
      ]),
    ClipScript(
      index: 12, slug: "looking-side",
      setup: [
        "Keep your shoulders and body centered and facing the camera; turn only your head "
          + "and eyes to look off to one side, as if reading a second monitor beside you, "
          + "for the whole clip."
      ]),
    ClipScript(
      index: 13, slug: "tilted",
      setup: [
        "Face the camera normally, then tilt your head toward one shoulder — ear toward "
          + "shoulder — and hold that tilt for the whole clip."
      ]),
    // 20s, not the 15s default: a second person needs time to enter frame, cross fully
    // behind the subject, and exit before the clip ends, without the walk-through feeling
    // rushed — 15s left too little margin around the crossing itself.
    ClipScript(
      index: 14, slug: "walk-through",
      setup: [
        "Have another person walk behind you once, or if alone: start centered, have the "
          + "clip run while you lean out and back to simulate — note in the report that a "
          + "real second person is preferred."
      ], durationSeconds: 20),
    ClipScript(
      index: 15, slug: "second-person-seated",
      setup: [
        "Set up: have a second person sit beside or just behind you, both of you visible "
          + "to the camera for the whole clip. If you are alone, this clip cannot be "
          + "staged solo — skip it and come back once a second person is available: "
          + "press S."
      ]),
    ClipScript(
      index: 16, slug: "glasses-glare",
      setup: [
        "Set up: wear glasses, and angle a lamp or bright window so its reflection lands "
          + "directly on a lens toward the camera. If you don't have glasses on hand, "
          + "skip it and revisit this clip later: press S."
      ]),
    ClipScript(
      index: 17, slug: "lens-covered",
      setup: [
        "After the countdown, cover the camera with your finger for the middle ~8 "
          + "seconds, then uncover it."
      ]),
    ClipScript(
      index: 18, slug: "blink-fidget",
      setup: [
        "Sit normally: blink, shift, sip a drink, scratch your nose — ordinary small "
          + "movements, nothing dramatic."
      ]),
    ClipScript(
      index: 19, slug: "hand-raised",
      setup: [
        "Sit normally, and partway through the clip raise a hand and briefly touch or "
          + "cover part of your face for a second or two, then lower it again."
      ]),
    // 25s, not the 15s default: walking fully out of frame, staying out long enough for
    // face-lost escalation to actually register, and walking back and re-centering does
    // not fit in 15s — the original duration was too short to complete the choreography.
    ClipScript(
      index: 20, slug: "leave-return",
      setup: [
        "Start centered; after about 5 seconds walk fully out of frame; stay out about 8 "
          + "seconds; return and re-center."
      ], durationSeconds: 25),
  ]
  // swiftlint:enable trailing_comma
}
