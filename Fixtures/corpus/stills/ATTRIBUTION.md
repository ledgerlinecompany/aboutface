# Still-image fixture attribution

All images in this directory are NASA photographs obtained from the NASA Image
and Video Library (images.nasa.gov). As works of the U.S. federal government
they are in the **public domain** (17 U.S.C. § 105), which is why they can be
committed to this Apache-2.0 repository and redistributed with it. NASA's media
usage guidelines ask for credit ("NASA" plus the photographer where listed) and
do not imply NASA endorsement of this project.

These are interim stand-ins until the §14 corpus of purpose-recorded webcam
clips exists. They were selected for face-analysis properties, not for the
identity of the people in them.

| File | NASA ID | Subject / scene | Credit | Why it's here |
|---|---|---|---|---|
| `frontal-peake.jpg` | `jsc2013e079278` | Official portrait, Tim Peake (ESA) | NASA/Robert Markowitz | Clean unmasked frontal reference; primary real-face detection fixture |
| `frontal-barratt.jpg` | `jsc2010e177742` | Official portrait, Mike Barratt | NASA | Near-zero pose (measured yaw −1.8°, pitch −0.4°) — "centered, looking at camera" reference |
| `frontal-wilcutt.jpg` | `jsc2003e41874` | Official portrait, Terrence Wilcutt | NASA | Second frontal; different lighting/background than Peake |
| `turned-own-right-vandehei.jpg` | `NHQ202103240005` | Mark Vande Hei, press conference (masked) | NASA/Bill Ingalls | Head turned toward subject's own right; pose-sign ground truth; masked-face degradation case |
| `turned-own-left-mcclain.jpg` | `NHQ202103240013` | Anne McClain, press conference (masked) | NASA/Bill Ingalls | Head turned toward subject's own left, chin up; pose-sign ground truth |
| `multi-person-grissom.jpg` | `s61-03676` | Gus Grissom press conference, 1961 | NASA | Multiple faces in frame (Vision detects 4); "other people visible" case |

Source URLs follow the pattern
`https://images.nasa.gov/details/<NASA ID>`.

## Empirical Vision pose-sign findings (2026-07-31)

Measured with `Tools/pose-probe.swift` against the macOS 15 Swift-native
Vision API (`DetectFaceRectanglesRequest`), Swift 6.3.3 / Xcode 26.6, using
the two turned-head images above (ground truth established by visual
inspection) plus a horizontally flipped copy as a mirror-consistency check:

- **Yaw:** positive = subject's head turned toward **their own right**
  (face pointing toward image-left in an unmirrored image). Vande Hei
  (own right) → **+20.5°**; McClain (own left) → **−17.1°**. This
  **contradicts** the community-reported convention for the legacy
  `VNFaceObservation` API ("positive = toward the image's right edge")
  that `VisionBackend`'s doc comment records as a starting hypothesis.
- **Pitch:** positive = **chin down** (CORRECTED 2026-08-01). The original
  reading here ("positive = chin up," from McClain → +22.6°) was wrong: that
  image shows a masked subject *looking* upward, and eye gaze was conflated
  with head pitch. A controlled live-camera test (maintainer deliberately
  tilting chin up while watching the raw value fall, e.g. −20° → −26° before
  correction) has no gaze confound and supersedes the photo inference.
  Consequence: the AnalysisEngine boundary negates pitch in both mirror
  states to satisfy §3.3's "+ = chin up".
- **Mirror consistency:** horizontally flipping the Vande Hei image negates
  yaw (+20.5° → −17.0°) and roll (+5.4° → −11.3°) while leaving pitch
  essentially unchanged (+26.5° → +29.3°), exactly as mirror geometry
  requires. The flipped bounding box origin also matched
  `EgocentricTransform.egocentricRect`'s `1 − x − width` formula.

Consequence for `AnalysisEngine` (the §3.4 boundary): for **unmirrored**
frames Vision's yaw/roll signs already match `FaceGeometry`'s egocentric
conventions and pass through unchanged; for **mirrored** frames yaw and roll
must be **negated**; pitch is mirror-invariant either way.

Caveats: n=2 turned-head samples, both masked; roll ground truth is from the
synthetic flip only (no strongly head-tilted fixture yet). Re-verify with
purpose-recorded clips before Phase 3 tuning, per `VisionBackend`'s
doc-comment warning.
