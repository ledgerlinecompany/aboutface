# Tuning-profile experiments

Hypothesis-driven config profiles for convergence trials (maintainer
proposal, 2026-08-02). Each is `Config.defaults` (regenerate with
`aboutface-cli config-defaults`) with exactly one change, so trial-session
comparisons isolate one variable.

Run one session per profile (same day, same seat if possible), then compare:

```sh
swift run -c release aboutface-cli trial --trials 5 \
  --config Fixtures/tuning-profiles/p1-scheme-b.json --label p1-scheme-b
```

| Profile | Change | Hypothesis |
|---|---|---|
| `p0-baseline` | none | control; re-run LAST as `p0-again` to bracket practice effects |
| `p1-scheme-b` | zero-beat refinement ON | cuts in-zone hunting (settled minus enter) on hard trials — §16.2's open question |
| `p2-fast-smoothing` | smoothing window 8→4 | EMA lag causes overshoot; snappier tracking = fewer overshoots (risk: audible jitter) |
| `p3-linear-onset` | timbre onset exponent 2→1 | stronger near-center vertical cues = faster fine positioning (risk: center-crossing octave jump returns) |
| `p4-quantized-coarse` | beacon quantization step 0.08 (~5 levels/side) | discrete "level changed" moments make coarse centering easier; settle steadiness (`meanAbsErrorDuringSettle`) should worsen |
| `p5-quantized-fine` | beacon quantization step 0.03 | the middle ground — steps audible, precision mostly kept |

Metrics to compare per session (all in `aboutface-trials.json`): median
`tSettledSeconds`, settled-minus-enter (hunting time), `overshootsTotal`,
`meanAbsErrorDuringSettle` (steadiness), plus the subjective verdict —
pleasantness matters as much as speed for a tool worn hours a day (§7's
"tolerable tool" bar).
