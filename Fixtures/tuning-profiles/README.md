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

## Round 1 (2026-08-02) — results

Full methods, the results table, and per-profile verdicts:
[`docs/tuning/2026-08-02-convergence-experiment.md`](../../docs/tuning/2026-08-02-convergence-experiment.md).
One-liner per profile below; `p0-baseline`/`p1`-`p5` were regenerated
**against the post-experiment defaults** (`errorQuantizationStep` now
`0.03`, Scheme B now a percussive click train — see that doc's "Decisions
taken") so their JSON no longer matches what was actually trialed in round
1. They're kept, patched relative to the NEW defaults, purely for
reproducibility/provenance of the ORIGINAL one-variable-each design; do not
expect a re-run to reproduce the exact round-1 numbers now that the
baseline they're patched against has changed underneath them.

**Regenerated again (roll advisory PR):** every profile below was
regenerated a second time against `Config.defaults` as of the roll-advisory
change — `Config.Gaze.maxRollDegrees` (new field) and `schemeBEnabled`
(flips to `true`, §16.2 closed — see the round-2 section below) both land
in every profile's `gaze`/`audio.scheme` blocks now. Same provenance
mechanism each time: `aboutface-cli config-defaults` for a fresh baseline,
then the one jq patch each profile's row below documents.

| Profile | Round-1 change (as trialed) | Round-1 result |
|---|---|---|
| `p0-baseline` | none | control; re-run LAST as `p0-again` to bracket practice effects — still lost to `p5` on both speed and steadiness |
| `p1-scheme-b` | zero-beat refinement ON | **unjudgeable** — the beat tone was too similar to the beacon to tell apart; see `p6`/`p7` below for the re-trial |
| `p2-fast-smoothing` | smoothing window 8→4 | **refuted** — overshoots got WORSE (15, the most of any profile), not fewer; maintainer: "less precise" |
| `p3-linear-onset` | timbre onset exponent 2→1 | **refuted** — worst hunting time of any profile; the center-crossing octave jump came back; maintainer: "less reliable" |
| `p4-quantized-coarse` | beacon quantization step 0.08 | overshoots nearly abolished (1) but steadiness worse than `p5` — maintainer: "obviously easier to land," but fine beats coarse |
| `p5-quantized-fine` | beacon quantization step 0.03 | **winner** — fastest median settle AND best steadiness of any profile, including the practiced control; now the shipped default |

Metrics compared per session (all in `aboutface-trials.json`): median
`tSettledSeconds`, settled-minus-enter (hunting time), `overshootsTotal`,
`meanAbsErrorDuringSettle` (steadiness), plus the subjective verdict —
pleasantness matters as much as speed for a tool worn hours a day (§7's
"tolerable tool" bar).

## Round 2 (2026-08-02 action round) — results, §16.2 closed

`p2`/`p3` are NOT re-added as round-2 variables — both hypotheses were
refuted, so their fields stay at whatever round 1's baseline had them at
(kept in the table above purely for reproducibility, per the maintainer's
instruction not to silently drop a refuted result). Two new profiles
reopened the one round-1 result that stayed genuinely unresolved:

| Profile | Change (relative to round-1-era defaults) | Hypothesis | Result |
|---|---|---|---|
| `p6-schemeb-continuous` | `errorQuantizationStep` forced back to `0` (continuous) + `schemeBEnabled` ON | **the fair `p1` retry.** Round 1's `p1` trial ran under a continuous beacon; the percussive click train fixes the register-collision that made `p1` unjudgeable, so re-trialing under the SAME continuous conditions isolates whether the redesign alone (not quantization too) resolves it. | **"that works."** No repeat of `p1`'s "wasn't sure if I was supposed to get it to match the other one" — the click train read as unambiguously distinct from the beacon even under continuous mapping. |
| `p7-schemeb-quantized` | quantized `0.03` (round-1's own winner) + `schemeBEnabled` ON | **the combination test.** Do the beacon's tonal-purity snap and Scheme B's rhythmic-silence null compose into a stronger "you're there," or does layering two channels clutter the signal? | **Won outright.** Tonal-purity snap + rhythmic-silence null gave the clearest "you're there" of any profile trialed across both rounds — compose, not clutter. |

**§16.2 closed** (`docs/spec.md` §16, `docs/tuning/2026-08-02-convergence-experiment.md`'s
closure note): `Config.AudioScheme.schemeBEnabled` now defaults `true`.
`p0-baseline` therefore now includes Scheme B as part of what "the
defaults" means — it is no longer a round-1-era, B-off snapshot. One
consequence, after regenerating every profile below against the new
defaults: `p1-scheme-b`, `p5-quantized-fine`, and `p7-schemeb-quantized`
each patch exactly the one field that now already matches the new
default (`schemeBEnabled`, or `errorQuantizationStep` for `p5`), so all
three are bit-identical to `p0-baseline` post-regeneration — the same
"kept as a separate file for provenance, not because the JSON differs"
situation `p7` was already in relative to `p1` before this round. `p6`
remains the one round-2 profile that still differs from the new baseline
(it deliberately forces `errorQuantizationStep` back to `0` to isolate
the continuous-mapping condition).
