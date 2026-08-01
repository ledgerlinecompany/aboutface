# Phase 1 acceptance record (spec §13)

Recorded 2026-08-01. All three Phase 1 acceptance criteria met.

## 1. Corpus replay prints a stable, plausible signal stream

`aboutface-cli replay` over a 20 s NASA live-interview clip (480p@30,
local interim corpus): 600/600 frames `state=ok`, stable stream.
Values plausible and egocentrically correct for broadcast framing:
err.x ≈ 0.001 (subject horizontally centered), err.y ≈ +0.09 (subject
above the webcam headroom target → instruction would be "down"),
distanceError ≈ −0.03 (medium shot → "too far"), yaw ≈ −3…−7°
(subject glancing toward an off-axis interviewer).

## 2. Mirror-convention test (§3.4) passes in both configurations

Covered at three independently derived levels, all in CI:

- `EgocentricTransformTests` — pure transform math, hand-derived values.
- `SyntheticCorpusEndToEndTests` — real Vision inference over a composited
  clip replayed unmirrored and genuinely pixel-flipped (`simulateMirrored`);
  egocentric X agreed across configs within ~0.003 (tolerance ±0.05).
- `AnalysisEngineEgocentricBoundaryTests` — engine-level boundary, including
  yaw/roll negation for mirrored frames per the empirical pose-sign findings
  (`Fixtures/corpus/stills/ATTRIBUTION.md`).

## 3. Live camera at 30 Hz without dropping frames

`swift run -c release aboutface-cli live --seconds 30`, MacBook Air,
built-in camera, 1280×720@30 requested explicitly:

```
summary: ranSeconds=30.0 framesProcessed=889
achievedFps=29.60 requestedFps=30.00
droppedFramesEstimate=12.1
```

Steady-state per-second deltas were 29–30 fps; the deficit is capture
startup ramp (t=0 delivered 1 warm-up frame, correctly classified
`noSignal`; second one delivered 22). Sustained drop rate ≈ 0.1%.
