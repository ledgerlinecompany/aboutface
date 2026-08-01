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
  (`""`) in this file; not read or written by `record-corpus`/`verify-corpus`
  (see "Recording the corpus" below for why) or by any test. The actual
  filename convention is `<NN>-<slug>.mov` (e.g. `01-reference.mov`),
  determined purely by clip position — see `Sources/aboutface-cli/CorpusCatalog.swift`.
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

## Recording the corpus

`aboutface-cli record-corpus` is a guided, interactive recording session that
walks the 20-clip list one clip at a time: it prints a setup instruction,
waits for you to press Return once you're in position, does a 3-2-1
countdown, then records 15 seconds of 1280x720@30 video from the camera to
`Fixtures/corpus/clips/<NN-slug>.mov` (e.g. `01-reference.mov`).

```sh
swift run -c release aboutface-cli record-corpus
```

(`-c release` matters here: the debug build's `VisionBackend` sanity check —
run about once a second during recording — is noticeably slower and can make
the printed frame/face counts lag.)

For each clip you'll see something like:

```
------------------------------------------------------------------------
Clip 2 of 20: Backlit against a bright window
Set up: sit with a bright window or lamp BEHIND you, so the camera sees it
over your shoulder. Your face should look dark to the camera.
This will record 15 seconds, starting after a 3-second countdown.
Press Return when set up.
------------------------------------------------------------------------
```

then, after you press Return, a 3-2-1 countdown, then a recording with a 1 Hz
status line (`t=Ns frames=N faces=N`) so you know you're in frame — the face
count is a cheap sanity check, not a rehearsal of the app's real feedback.
After the take, you'll see a short report (duration, frame count, file size)
and a prompt:

```
Return: next clip. r: redo this clip. s: skip for now. q: quit, resumable.
```

**Accessible / eyes-free recording:** add `--speak` to have every
instruction, countdown beat, and prompt spoken via `AVSpeechSynthesizer`
(rate 0.55, default voice) in addition to being printed — this is meant to be
a fully usable recording path for a blind or low-vision contributor, not just
a convenience, since that's most of this app's audience. Every instruction is
phrased to be actionable without looking at the screen (e.g. clip 9, "too
high in frame," says to raise yourself or lower the laptop until your face
sits at the very top of frame, rather than something that assumes you can see
a preview).

**Resuming and redoing:** a clip whose target file already exists is skipped
automatically on the next run, so an interrupted session just needs
`record-corpus` run again to pick up where it left off. To re-record a
specific clip, pass `--redo <n>` (e.g. `--redo 7`); to re-record everything,
pass `--all`. You can also press `r` at the post-take prompt to redo the
clip you just recorded without restarting the whole session.

**Interrupting:** Ctrl-C is safe at any point — an in-progress take's file is
removed rather than left half-written, and clips you've already completed
are untouched.

Other flags: `--seconds`, `--width`, `--height`, `--fps`, `--device`
(`AVCaptureDevice.uniqueID`), `--corpus-dir` (override the auto-detected
`Fixtures/corpus` path). Run `swift run aboutface-cli record-corpus --help`
for the full list.

Some clips need staging beyond what one person alone can do:

- **Clip 14** (second person walking through) and **clip 15** (second person
  seated) need an actual second person for a faithful recording — the printed
  instructions say so, and suggest pressing `s` to skip and come back once
  one is available.
- **Clip 16** (glasses glare) needs a pair of glasses (even non-prescription)
  and a light source to angle.

## Verifying the corpus

`aboutface-cli verify-corpus` replays whatever clips have been recorded so
far and prints a triage table, checking each clip's observed signals against
its `manifest.json` `expectedCondition`:

```sh
swift run -c release aboutface-cli verify-corpus
```

```
#   slug                   expected                     status  detail
1   reference              ok                           CHECK   ok=98% meanAbsErr=(0.0041,0.0187) gazeOn=94%
2   backlit                lighting-backlit             CHECK   meanBacklightDelta=0.1823
7   off-left               framing-left                 CHECK   meanErrorX=-0.2159
17  lens-covered           noSignal                     CHECK   longestMidClipNoSignalStreak=241 of 450 frames
...
20 clips: 18 CHECK, 2 LOOK, 0 missing.
```

This is **triage for a human reviewer, not a pass/fail gate**: CHECK means
the coarse heuristic matched what the clip is supposed to show; LOOK means
either the heuristic didn't match (worth a look before re-recording) or —
for side-lit and glare, which have no single scalar that settles them — that
a still-frame look is always warranted. `verify-corpus` exits 0 regardless of
the results unless you pass `--strict`. A clip with no file recorded yet
shows as `MISSING` and isn't scored either way, so it's safe to run against a
partially-recorded corpus at any point during a session.

- `--json` prints the full per-clip aggregate (frame count, `SignalState`
  histogram, mean/median error, lighting means, first/middle/last sampled
  pose, etc.) as a JSON array instead of the table, for scripted review.
- `--stills <dir>` additionally exports each evaluated clip's first, middle,
  and last frame as JPEGs (`<NN-slug>-first.jpg` / `-middle.jpg` /
  `-last.jpg`), so you can eyeball staging without opening a video player —
  useful for the clips (side-lit, glare) that `verify-corpus` can't score on
  its own.

Run `swift run aboutface-cli verify-corpus --help` for the full flag list.
