# Phase 2 acceptance checklist (spec §13 Phase 2)

**For the human maintainer.** This is a step-by-step VoiceOver script, not a
report of results — Phase 2's acceptance criterion is "every signal in §9 is
reachable and readable by VoiceOver with a sensible value," which requires a
person with a screen reader running to actually confirm. An implementation
agent cannot validate this; the sections below are what to walk through, in
order, plus the specific known limitations to weigh while doing it.

Estimated time: 30–45 minutes for a full pass.

## 0. Setup

1. `xcodegen generate && xcodebuild -project AboutFace.xcodeproj -scheme AboutFaceApp -destination "generic/platform=macOS" build CODE_SIGNING_ALLOWED=NO`,
   then run the built `About Face.app` from Xcode or `open` it directly (unsigned
   local build is fine for this pass — no need to notarize).
2. Turn on VoiceOver (⌘F5) before the app launches, so the permission prompt
   and first window are both heard from the start.
3. Have a webcam available and unobstructed, with reasonable room light.

## 1. Camera permission flow

- [ ] On first launch (or after resetting privacy permissions via
      `tccutil reset Camera com.ledgerlinecompany.aboutface`), VoiceOver
      should read a sensible "waiting for camera permission" message, then
      the system permission dialog should appear and be VoiceOver-navigable
      (this is a system dialog, not app code, but confirm it isn't skipped
      or silently dismissed).
- [ ] Deny access. Confirm the Setup window now shows a clear message plus
      an "Open System Settings" button, and that the button is reachable and
      activatable by VoiceOver, and that it actually opens the Camera
      privacy pane (System Settings → Privacy & Security → Camera).
- [ ] Re-enable About Face's camera access in System Settings, relaunch, and
      confirm the message clears and the picker/Start button become usable.

## 2. Every §9 signal, read by VoiceOver

With the camera authorized, select a camera in the picker and press
**Start**. Sit in front of the camera, reasonably framed and lit.

Arrow through the Setup window's "Signals" section top to bottom (VoiceOver
Down Arrow, or swipe right in trackpad-navigation mode) and confirm **every
row below** is announced as "*label*, *value*" with a value that sounds like
a real, current measurement — never "0", never a bare unlabeled number,
never silence:

- [ ] Headroom
- [ ] Horizontal offset (say the words out loud as you deliberately lean
      left, then right, of center — confirm the announced direction word
      matches which way you actually moved, per §3.4. **This is the single
      highest-priority check in this whole document.**)
- [ ] Face box (origin + size)
- [ ] Interocular distance (lean toward/away from the camera and confirm the
      "closer than target" / "farther than target" phrase tracks correctly)
- [ ] Face brightness
- [ ] Background brightness
- [ ] Backlight difference
- [ ] Clipped highlights
- [ ] Clipped shadows
- [ ] Sharpness
- [ ] Yaw (turn your head left/right; confirm "own right"/"own left" matches
      your actual turn direction)
- [ ] Pitch (nod up/down; confirm "chin up"/"chin down" matches)
- [ ] Roll (tilt your head; confirm "own right"/"own left" matches)
- [ ] Face count
- [ ] Backend confidence
- [ ] Backend (name)
- [ ] Capture format
- [ ] Mirror state
- [ ] State line (the plain-language `signalState` summary above the
      Signals section)

Then:

- [ ] Cover the camera lens (or point it at a blank wall in a dark room) and
      confirm the face-dependent rows switch to a distinct "no signal" or
      "no face detected" placeholder — never a stale leftover number, never
      blank.
- [ ] Uncover it and confirm the rows return to real values within a few
      seconds.

## 3. Values update live, VoiceOver stays responsive

This is the §9 requirement that's easy to get backwards: fast enough to be
useful, slow enough not to make VoiceOver unusable.

- [ ] With the camera running, focus on the "Horizontal offset" row and hold
      still. Listen for whether VoiceOver's focus and reading stay
      responsive — you should be able to arrow to the next row, then back,
      without a lag or a "stuck" feeling. (Every row is throttled to the
      same ~2 Hz accessibility-snapshot cadence — see the Known Limitations
      section below for what that does and doesn't guarantee.)
- [ ] Move around in front of the camera while arrowed onto a row (e.g.
      Horizontal offset) and confirm VoiceOver periodically re-announces an
      updated value — not on every tiny movement (that would be
      unreadable), but noticeably within roughly half a second of settling
      into a new position.
- [ ] Confirm the whole window — menu, picker, buttons — stays responsive
      to keyboard/VoiceOver commands throughout; nothing should feel like it
      hangs while frames are streaming in.

## 4. Debug panel sliders visibly change engine behavior

Open the Debug Panel window (a second window/tab from the Setup window's
window menu, or `⌘\`` / Window menu depending on how you've set window
cycling up). For **three sliders**, adjust the value, then switch back to
the Setup window and confirm the Signals section visibly reflects the
change:

- [ ] **Target framing → Eye midpoint, horizontal.** Move it noticeably
      (e.g. from 50% to 30%) while sitting still. Confirm "Horizontal
      offset" changes to reflect the new target — you should now read as
      offset from the new target even though you haven't moved.
- [ ] **Dead zone & hysteresis → Dead zone, horizontal.** Widen it a lot
      (e.g. to 25%). Confirm the dead-zone-dependent behavior changes
      (framing error that used to register as "outside dead zone" now
      reads as within it — this is most directly observable once Phase 3's
      audio/state feedback exists, but for now confirm at minimum that the
      slider's own accessibility value updates and that a reset afterward
      restores prior behavior).
- [ ] **Gaze → Max yaw for gaze-on-camera.** Narrow it to a small value
      (e.g. 5°), turn your head slightly, and confirm behavior that depends
      on `gazeOnCamera` changes — again, most directly observable once
      Phase 3 lands; for this pass, confirm the value change round-trips
      (see §6 below) and the engine doesn't error out.
- [ ] For each slider touched: confirm VoiceOver reads a **unit-bearing**
      value ("50 percent," "800 milliseconds," "15 degrees" — never a bare
      "0.5" or "800"), and confirm the built-in adjustable increment/
      decrement gesture (VO + Up/Down Arrow, or swipe up/down) moves the
      value by a sensible step.

## 5. Reset to defaults

- [ ] Change several sliders in one section (e.g. Lighting), then press
      that section's "Reset … to defaults" button. Confirm the section's
      values return to `Config.defaults` and VoiceOver announces/reflects
      the change.
- [ ] Change a slider in a different section, then press "Reset all to
      defaults." Confirm a confirmation dialog appears and is itself
      VoiceOver-navigable (readable title, reachable Reset/Cancel buttons).
      Cancel once to confirm nothing changes; then confirm again and verify
      every section reverts.

## 6. Capture current position as target

- [ ] With the camera running and a face detected, deliberately sit
      off-center (e.g. lean left, higher than the default target). Press
      "Capture current position as target" in the Setup window.
- [ ] Confirm VoiceOver announces "Target captured" (via
      `AccessibilityNotification.Announcement`).
- [ ] Confirm "Horizontal offset" (and headroom) now reads close to "on
      target" for your current position, without moving — i.e. the target
      really did move to where you were sitting.
- [ ] Switch to the Debug Panel and confirm the "Target framing" sliders
      reflect the newly captured values.
- [ ] With no face in frame (step away or cover the lens), press the
      capture button again and confirm it does nothing destructive and
      (per the current implementation) VoiceOver announces a "no face
      detected — nothing to capture" message rather than silently no-op'ing.

## 7. Export / import

- [ ] In the Debug Panel, press **Export…**. Confirm the save panel is
      VoiceOver-navigable (title field, location, Save button all reachable)
      and produces a `.json` file at the chosen location.
- [ ] Change a slider (note the before/after value).
- [ ] Press **Import…**, select the exported file. Confirm the changed
      slider reverts to the exported value, and that the whole config
      round-trips without a spurious "Reset settings" notice.
- [ ] Hand-edit the exported JSON's `"version"` field to a number higher
      than the app's current schema version (see `Config.defaults.version`
      in `Sources/AboutFaceCore/Config/Config.swift`), then try importing
      it. Confirm an alert appears (VoiceOver-readable) with the
      `newerVersion` message naming both the file's version and the
      version this build supports — not a silent failure or a generic
      error.
- [ ] Try importing a non-JSON file (e.g. rename a `.txt` file to `.json`).
      Confirm the "isn't a valid About Face configuration" alert appears.

## 8. Config load issue banner

- [ ] Quit the app, corrupt `~/Library/Containers/com.ledgerlinecompany.aboutface/Data/Library/Application Support/About Face/config.json`
      (or the unsandboxed path if running unsigned outside the container —
      check `ConfigStore.defaultURL()`'s doc comment) by writing garbage
      into it, then relaunch.
- [ ] Confirm the Setup window shows a non-modal "your saved configuration
      could not be read and was reset to defaults" notice (not a blocking
      alert — §9 asks for this to be surfaced non-modally), that it names
      where the original file was backed up, and that the app is otherwise
      fully usable with defaults.

## 9. Camera enumeration: connect/disconnect (§12.1)

- [ ] With the app running and the camera picker focused, connect an
      external USB webcam (or start/stop Continuity Camera from a paired
      iPhone). Confirm the new device appears in the picker without
      restarting the app.
- [ ] Disconnect it. Confirm it disappears from the picker. If it was the
      currently selected/running device, confirm the app surfaces some
      indication (at minimum, the capture error message) rather than
      silently freezing on stale frames.
- [ ] This exercises `CameraDiscovery`'s KVO observation of
      `AVCaptureDevice.DiscoverySession.devices` — Apple documents this
      property as KVO-compliant, but per §12.1's own instruction to
      "verify empirically," this is the step that actually confirms it on
      the hardware in front of you. Note the result (worked / didn't) here
      or in a follow-up issue.

## Known limitations (read before filing a bug)

- **Per-focused-element `.valueChanged` throttling is not implemented in
  this pass.** Spec §9 asks for VoiceOver's `.valueChanged` notification to
  be posted "only for the currently-focused element, throttled to ~2 Hz."
  What's actually built: **every** row's value is recomputed from one
  `AccessibilitySnapshot` at ~2 Hz, and SwiftUI's `.accessibilityValue`
  binding takes care of posting change notifications from there — there is
  no code that tracks *which* row VoiceOver is currently focused on and
  skips posting for the rest. In practice, with ≤18 rows updating at 2 Hz,
  this has not been observed to overload VoiceOver in ad hoc testing, but
  it has not been validated against the spec's stronger, narrower
  requirement either. `PipelineModel.swift`'s doc comment on
  `AccessibilitySnapshot` explains why this was deferred and how to extend
  it (add a per-row timestamp or a currently-focused-field flag) without a
  redesign, if step 3 above surfaces real chattiness. **This is the
  primary thing this checklist's step 3 exists to actually validate** —
  if VoiceOver feels overwhelmed there, this is where to look.
- **No global hotkeys are wired yet.** §8's ⌘⌃⇧T (capture target), ⌘⌃⇧S
  (Setup toggle), etc. are Phase 3/audio-engine-adjacent wiring
  (`RegisterEventHotKey`, never built in Phase 1/2) and are out of scope
  for this pass — the Setup window's target-capture is a plain button only.
  Likewise, §8's "bare single letters inside the Setup window" convention
  has no actions to bind yet (no audio engine, no repeat-announcement, no
  mode toggle) — nothing to check here until Phase 3.
- **Duck-own-TTS-on-keypress (§9) does not apply** — there is no own-TTS
  yet (Phase 3). Nothing to check here.
- **Monitor-mode-specific behavior (§12.2 camera-in-use gating, virtual
  camera warnings, Center Stage reporting) is Phase 4 scope** and is not
  built or checked here.
- **The Dead zone/Gaze slider checks in §4 above are necessarily weak**
  without the audio/state-machine layer (Phase 3) to make dead-zone/gaze
  state changes audible or visible beyond the raw `Config` values
  round-tripping. Re-run a stronger version of those two checks once Phase
  3 lands.
