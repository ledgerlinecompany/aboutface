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

- **Yaw:** positive = subject's head turned toward **their own LEFT**
  (CORRECTED 2026-08-01, second correction of the day). The original
  photo-derived reading ("positive = own right", from Vande Hei +20.5° /
  McClain −17.1°) was wrong: the masked three-quarter faces were misread
  visually. The correction comes from a controlled live test — nose turned
  deliberately toward the right shoulder read "own left" under the old
  mapping while a slide-left test confirmed horizontal position was
  correct, isolating the error to the pose convention rather than the
  capture/mirror path. LESSON (now proven twice, pitch then yaw):
  photo-inferred sign ground truth is not acceptable; only controlled
  live movement counts.
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

Roll: positive = tilt toward own RIGHT — verified by controlled live tilt
(ear toward right shoulder, 2026-08-01). Notably the OPPOSITE baseline sense
from yaw; the brief "same in-image-plane logic as yaw" assumption lasted one
commit before the live check corrected it. With this, ALL THREE axes are
established by controlled live movement. The turned-head stills above remain
useful as detection/degradation fixtures, but are explicitly NOT sign ground
truth.
