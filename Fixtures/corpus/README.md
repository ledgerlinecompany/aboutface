# Test corpus (spec §14)

This directory holds the fixture manifest for the test corpus described in
spec §14. The corpus is the primary tuning and regression instrument for
About Face: replaying identical recorded input is the only way to A/B two
signal-processing or feedback changes without the noise of a live camera
(subject movement, lighting drift, etc.).

## Layout

```
Fixtures/corpus/
  README.md         This file.
  manifest.json      Schema-by-example: one entry per clip, expected dominant
                      condition, and notes. See below.
  clips/             The actual video clips. NOT committed to git — see below.
```

## Clips are not committed

The clips themselves (`Fixtures/corpus/clips/*`) are **not** checked into this
repository. They are:

- Large binary media, unsuited to git history.
- Identifiable video of real people (recording subjects), which should not be
  distributed as part of an open-source repository by default.

`Fixtures/corpus/clips/` is expected to be excluded via `.gitignore` (owned
elsewhere in this repo). Contributors who need to run the full corpus
regression suite should record or obtain the 20 clips described in
`manifest.json` and place them at the `file` path listed for each entry,
relative to `Fixtures/corpus/clips/`.

Tests that depend on actual clip files being present MUST skip gracefully
(not fail) when a clip is missing, so that `swift test` remains green in any
checkout that doesn't have the corpus populated. Per `CLAUDE.md`'s testing
conventions, no test may require a live camera to pass in CI, and by the same
principle no test may hard-fail merely because corpus media hasn't been
recorded yet.

## Manifest schema

`manifest.json` is an array of objects:

```json
{
  "file": "01-reference.mov",
  "description": "Well-lit, centered, looking at camera (the reference)",
  "expectedCondition": "ok",
  "notes": "Baseline clip. Every other clip is a deviation from this one."
}
```

- `file` — filename expected under `Fixtures/corpus/clips/`. Left empty
  (`""`) until a clip has actually been recorded and placed there.
- `description` — human-readable description of what the clip depicts,
  copied from spec §14's numbered list.
- `expectedCondition` — the dominant condition this clip is meant to exercise
  (framing, lighting, or state-machine behavior). This is a short slug, not a
  literal `SignalState`/`FramingState` value — see each entry's `notes` for
  what "expected" means concretely for that clip, since several clips (e.g.
  suppression tests) are about the *absence* of a state change rather than a
  single signal value.
- `notes` — anything a tuner needs to know: what "correct" behavior looks
  like, known-tricky aspects, or cross-references to spec sections.

The 20 entries pre-filled in `manifest.json` correspond 1:1 to spec §14's
numbered clip list.
