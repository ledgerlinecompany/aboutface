# 2026-08-02 convergence experiment

The first *measured* tuning session (as opposed to by-ear audition): a
practiced baseline plus five single-variable profiles, run through
`aboutface-cli trial`, with the maintainer blind to which profile was live
and acting as the experiment's own subject.

## Methods

- **Harness:** `aboutface-cli trial` (`Sources/aboutface-cli/TrialCommand.swift`)
  — live camera + the real audio feedback chain
  (`AudioRenderer`/`SpeechRenderer`/`FeedbackRouter(mode: .setup)`, the same
  path the shipping app uses). Per trial: "Move well out of position" (won't
  proceed until smoothed `|error|` clears a displacement multiple of the
  dead zone's diagonal, so every trial starts from a genuine correction) →
  Return → "Converge when the tone starts" → a 1s pause → the feedback goes
  live and the clock starts. SETTLED fires the instant error has stayed
  continuously inside the dead zone for the settle window (2s default); a
  trial that never settles within the timeout (45s default) is recorded as
  timed out. Face-lost pauses the clock rather than penalizing it, so a
  coincidental look-away never counts against the measurement.
- **5 trials per session**, one session per profile, same day, same seat.
- **One variable per profile** — every profile is `Config.defaults` (as of
  the pre-experiment defaults) plus exactly one changed field, so
  session-to-session comparisons isolate that one variable. See
  `Fixtures/tuning-profiles/README.md` for the exact profile definitions and
  provenance (`aboutface-cli config-defaults` + a single patch each).
- **Practiced control run LAST** (`p0-again`): the same baseline profile as
  `session3`, re-run after all five variable profiles, specifically to rule
  out "the later profiles won because of practice effects, not because of
  the variable." It still lost on both median settle time and steadiness —
  see verdicts below.
- **Snapshots:** each trial's go signal, SETTLED, and timeout/failure frames
  were saved (`--snapshots`) so framing quality at "SETTLED" could be
  audited by a sighted reviewer independently of the numbers, not just
  trusted from the metric alone.
- **Metrics per trial:** time to first dead-zone entry, time to SETTLED,
  overshoot count (sign reversals of `error.x`/`error.y` while genuinely
  outside the dead zone), path integral of `|error|` over time, mean
  `|error|` during the settle window (steadiness). Across trials:
  median/mean of settled trials' times, total overshoots, and timeout
  count.

## Results

| Profile | Median settle s | Mean s | Hunting s (med) | Overshoots | Steadiness | Timeouts |
|---|---|---|---|---|---|---|
| session3 (pre-practice baseline) | 12.7 | 17.9 | 4.9 | 10 | .0331 | 0 |
| p1 scheme-b | 10.0 | 10.8 | 2.0 | 11 | .0408 | 1 (deliberate, excluded) |
| p2 fast-smoothing | 8.8 | 13.7 | 5.9 | 15 | .0281 | 0 |
| p3 linear-onset | 13.6 | 14.5 | 7.8 | 10 | .0384 | 0 |
| p4 quantized-coarse | 10.4 | 10.4 | 2.0 | 1 | .0313 | 0 |
| p5 quantized-fine | 7.9 | 7.8 | 2.0 | 8 | .0241 | 0 |
| p0-again (practiced baseline) | 9.2 | 13.4 | 2.0 | 14 | .0431 | 1 (genuine) |

"Hunting" is settled-minus-enter: time spent bouncing around inside the
dead zone after first arriving before it actually counts as SETTLED.
"Steadiness" is mean `|error|` during the settle window — lower is
steadier. Full per-trial records live in the session's `--json` log
(not committed; regenerate via `aboutface-cli trial` per
`Fixtures/tuning-profiles/README.md`).

## Verdicts

- **p5 quantized-fine — WINNER.** Swept BOTH speed (7.9s median, fastest of
  any profile) AND steadiness (.0241, lowest of any profile). Quantization's
  snap-to-zero gives an unambiguous "you're there" that a continuous tone
  can't. The practiced control (`p0-again`) ran LAST in the order — the one
  profile with every structural advantage practice could offer — and it
  still lost on both axes. That kills the ordering objection: `p5` isn't
  winning because it happened to run when the subject was warmed up.
- **p4 quantized-coarse — partial win, wrong tradeoff.** Overshoots nearly
  abolished (1, vs. 8–15 everywhere else) — the coarse step makes it very
  hard to blow past the target without noticing. But steadiness (.0313) is
  worse than `p5`'s — a coarser step means more residual wobble once
  "close enough" is reached. Fine beats coarse once you also want
  steadiness, not just fewer overshoots.
- **p2 fast-smoothing — REFUTED.** Hypothesis was "EMA lag causes
  overshoot; snappier tracking = fewer overshoots." Overshoots came back
  WORSE (15, the most of any profile), not fewer. Maintainer's own
  subjective read: "less precise." The faster EMA wasn't cutting lag, it
  was cutting the trend-legibility the smoothing exists to provide —
  jitter, not responsiveness.
- **p3 linear-onset — REFUTED.** Hypothesis was "stronger near-center
  vertical cues = faster fine positioning." Worst hunting time of any
  profile (7.8s) — reverting the timbre onset curve to linear brought back
  exactly the center-crossing octave jump the superlinear exponent (the
  shipped default) was introduced to fix. Maintainer's subjective read:
  "less reliable."
- **p1 scheme-b — UNJUDGEABLE.** "I wasn't sure if I was supposed to get it
  to match the other one" — the zero-beat tones were too similar to the
  beacon; the subject couldn't reliably tell Scheme B's refinement layer
  apart from Scheme A's own tone. Its one timeout was deliberate (subject
  gave up mid-trial on a confusing case) and excluded from the aggregate.
  This is a register-collision finding, not evidence against zero-beat
  nulling as a concept — see Open Items.

## Decisions taken (this PR)

1. **Default `errorQuantizationStep` → `0.03`** (was continuous/`0`). `p5`'s
   step size, the profile that won on both axes.
2. **Quantization glide added** (`Config.AudioPositional
   .quantizationGlideMs`, default `80`ms/step). Both quantized profiles were
   subjectively "jumpy" — the maintainer's own design direction: "separate
   true quantization from the way the sounds output." The rendered value now
   slews between quantized levels instead of hard-stepping, while still
   converging exactly onto the quantized target (including zero) once
   settled, so the win above is preserved bit-for-bit.
3. **Scheme B redesigned as a percussive click train** (was a two-tone
   zero-beat). Directly addresses `p1`'s failure mode: non-tonal clicks
   can never be confused with Scheme A's tonal beacon the way the old beat
   tone could. Click rate still maps from the same
   `schemeBMaxBeatHz`/refinement-zone fraction the old beat frequency did;
   only what happens at that rate changed. Ships behind the same
   `schemeBEnabled` flag, still default OFF pending re-trial.

`p2`'s and `p3`'s variables (`smoothingWindow`, `timbreOnsetExponent`) are
NOT changed — both hypotheses were refuted, so the pre-experiment defaults
for those fields stand.

## Open items

- **Roll-in-settle design question.** None of the profiles addressed
  *how* a trial approaches SETTLED — e.g. whether a brief, deliberate
  "roll-in" deceleration near the dead-zone boundary would cut hunting time
  independent of the sonification scheme itself. Not trialed this round;
  candidate for a future single-variable profile.
- **Scheme B re-trial pending.** `p1`'s unjudgeable result blocks any
  default-flip decision on `schemeBEnabled` either way. Round 2 adds two
  profiles specifically to re-open this (`Fixtures/tuning-profiles/README.md`):
  `p6-schemeb-continuous` (the fair `p1` retry, now with the percussive
  redesign and continuous beacon) and `p7-schemeb-quantized` (percussive B
  layered on the new quantized-fine default, testing whether the two
  "you're there" channels — tonal purity and rhythmic silence — compose or
  clutter).
