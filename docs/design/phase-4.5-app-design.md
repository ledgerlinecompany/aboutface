# Phase 4.5 — the app's design, from first principles

Status: **proposed**, 2026-08-07. Written before any 4.5 implementation, at the
maintainer's request, deliberately reasoning from the job rather than from what
is already built. Where it contradicts the current build, the gap is listed in
the last section rather than smoothed over.

This is not a replacement for [`../spec.md`](../spec.md), which stays
authoritative. It is the argument that should shape §13's Phase 4.5 work, and
the decisions taken along the way.

---

## 1. The problem this product actually has

A sighted person glances at their self-view. The glance costs perhaps 200 ms,
happens a few times a call, and delivers *everything at once, in parallel* —
framing, lighting, what is behind them, whether someone walked in.

Audio cannot do that. It is serial, it is slow, and it **occupies** the
listener. You cannot attend to your framing while attending to a colleague.

> The design problem is compressing a parallel, instantaneous, nearly free
> perception into a serial, slow, attention-occupying one.

Almost every good decision already in this codebase is an implicit answer to
that. Making it explicit is what this document is for.

## 2. The governing principle

**Non-linguistic channels carry continuous state. Language is reserved for
discrete change.**

A tone can run underneath thought; a sentence cannot. This is why the
positional beacon beats a stream of spoken corrections, and why speech should
be rare and eventful. §6.3's terseness rules are a consequence of this
principle, not an independent style preference.

A corollary the codebase already follows and should keep following: *tones
never mean "look," direction words always mean "move"* — one channel, one
meaning.

## 3. The arc

The app is not two modes the user chooses between. It is **one job with two
phases**, plus two affordances available throughout.

| | attention | what the app owes you |
|---|---|---|
| **Get placed** | high, deliberate | continuous, fast, non-verbal; ends in arrival |
| **Stay placed** | ~zero | silence, broken only for something severe |
| **Ask** | a burst, on demand | one complete answer, then stop |
| **Hush** | instant | everything off, now |

Everything else in the product is either in service of these four or is a
maintainer tool.

### 3.1 Getting placed is the primary job

Maintainer decision, 2026-08-07: **converging is primary, monitoring second.**

This is what people reach for. "Check me before I join" and "help me get
framed" are the same job, and it is the one the app must be excellent at. The
front door should open into it.

### 3.2 Converging ends by itself

Maintainer decision, 2026-08-07: **automatic.** Once placed and settled, the
app stops guiding and starts watching, without being told.

The handoff already exists in the build and is the right shape: the arrival
earcon fires, the beacon cuts atomically with it (the atomic-arrival work), and
the liveness heartbeat begins. That sequence *is* the sentence "I am satisfied;
I am watching now." It must never be a silent stop — a system that simply goes
quiet is indistinguishable from one that died (§6.1).

**Converging does not resume by itself.** If it did, the beacon could start up
in the middle of a meeting, which is precisely what §3.3 forbids. Re-converging
mid-call is something the user asks for.

That makes converging **a request, not a mode**: you ask for it, and it
finishes on its own. This is a better primitive than a mode toggle, because it
names a verb the user actually wants.

### 3.3 Staying placed is near-silent

Maintainer decision, 2026-08-07: during a call the app should **never speak
unprompted, except for something severe.**

**Severe** means: *the app cannot see you, or cannot do its job.* Face lost.
Feed dead. Camera taken away.

Explicitly **not** severe: framing, distance, gaze, head tilt, lighting, other
people in shot. All recoverable, none urgent, all askable. In this phase they
are answers, not announcements.

One deliberate exception, maintainer decision 2026-08-07: **being partially out
of frame, held long enough, earns an earcon — never words.** A sighted person
notices instantly that they are half out of shot; a blind user has no such
signal, and an hour spent half out of frame is a genuinely bad outcome that no
amount of "you could have asked" excuses.

Its design needs care:

- Non-verbal, per the governing principle and the decision above.
- A **long** dwell before it fires — this is "you have been like this for a
  while," not "you moved."
- It should **repeat on a slow cadence** while the condition holds, for a
  reason specific to this design: outside the good zone the liveness heartbeat
  is not running, so a single earcon followed by silence recreates exactly the
  ambiguity §6.1 exists to prevent. A slow repeat is both the alert and the
  proof of life.
- §7.4 already reserves `.partiallyOutOfFrame` as an unreachable stub with no
  threshold in `Config`. This decision is what activates it.

### 3.4 Asking becomes the primary interface

If the app says almost nothing during a call, then **query is how the user
learns anything at all**. It stops being a convenience and becomes the main
event. It deserves the best key, the most design attention, and the strictest
terseness budget.

Two consequences worth noting:

- §5.2's rate limiter ("one announcement per 20 s, same condition not within
  three minutes") becomes close to vestigial. It exists to ration announcements
  that will now barely occur.
- The gaze and head-tilt advisories stop being announcements and exist only to
  answer queries.

## 4. Confidence: five notices are one idea

Camera mismatch (§12.3), virtual camera (§12.4), Center Stage (§12.5), the
camera-in-use reminder (§12.2), hotkey registration failure (§8) — each was a
sound local fix, each invented independently. They are all instances of one
question:

> **How much should you trust what I am telling you?**

Under a near-silent regime none of them can announce themselves, so they need a
home. They should be one concept — **confidence** — surfaced in one place.

This also names a pattern worth resisting in future work: the app has
accumulated many separate answers to the single question *"is this thing on,
and is it right?"* — the heartbeat, hotkey confirmations, the reminder, and the
notices above. That question deserves one systemic answer, designed once.

## 5. Two queries, not one

A blind user has no peripheral vision, so the app's own state is invisible
unless spoken. Today "how do I look?" is a first-class query while "what is the
app doing?" is scattered across notice sections the user must go and read.

Propose two, same terseness, different subject:

- **How do I look?** — framing, lighting, gaze, other people. §5.3's existing
  fixed field order.
- **What are you doing?** — mode, camera, silenced or not, and any confidence
  problem from §4.

## 6. Settings: two products, not two tiers

Maintainer decision, 2026-08-07: **the debug panel is developer-only and does
not ship.** The shipping product gets a small set of genuinely useful settings.

This is freeing. The debug panel needs *fencing*, not designing — it is a
different application with a different user (the maintainer, tuning the
product), not the deep end of one continuum. Treating it as "advanced mode" is
what made the shallow end feel like a stripped-down control room.

The shipping settings should be expressed as **outcomes, not parameters**, and
should be roughly six things:

- which camera
- how loud
- which voice, and how fast
- tones or speech
- headphones or speakers
- keyboard shortcuts

Everything tuned by ear across Phase 3 and 4 becomes a baked default the user
never meets. The test for admitting any control:

> Does this exist because a user has a goal, or because we had a parameter?

## 7. Vocabulary

Name concepts after the questions users actually ask — "Am I in frame?", "Am I
centered?", "Is my face lit?", "Is anyone behind me?" — not after the mechanism.

*Placed*, not *good zone*. *Centered*, not *inside the dead zone*. If a term
only makes sense to someone who has read the spec, it is a system term leaking
into the product.

Spoken-first, per §13's existing Phase 4.5 criteria: every label and hint must
parse on one listen, at speed, without visual grouping to lean on, and each
control must be self-describing without its section header.

## 8. Open questions

- **Does the heartbeat survive unchanged** now that it is the only sound for
  hours at a time? Maintainer decision 2026-08-07: keep as-is *for now*, and
  revisit by ear. It was designed as one signal among many and is about to
  carry the whole "still alive" burden alone, roughly a thousand times per
  two-hour call.
- **How long is "long enough"** for the partially-out-of-frame earcon, and how
  slow is its repeat? Both are by-ear questions, and both belong in `Config`
  (§0) rather than being chosen here.
- **Does converging need a dedicated key**, now that it is a request rather
  than a mode? The current ⌘⌃⇧M toggles Monitor; the verb the user wants is
  closer to "help me get placed."

## 9. Gaps between this design and the current build

Listed plainly so the work is visible, not to imply any of it is wrong today —
most of it predates these decisions.

1. **The beacon is not mode-gated.** `updateContinuousSonification` has no mode
   check (verified 2026-08-07 — the only mentions of mode in that file are
   comments). Drifting out of the dead zone during a call produces continuous
   unprompted sound, contrary to §3.3. Gaze trim *is* Setup-gated; the beacon
   is not. **This is the largest single gap.**
2. **Monitor still speaks non-severe conditions** — framing instructions, the
   gaze advisory, the head-tilt advisory — rate-limited but present. Under §3.3
   these become query-only.
3. **`.partiallyOutOfFrame` is an unreachable stub** with no `Config`
   threshold. §3.3 activates it.
4. **Monitor is entered by an explicit toggle and never ends by itself.** §3.2
   makes converging the thing that ends automatically, which inverts the
   primitive.
5. **The five notices are five surfaces.** §4 makes them one.
6. **Query answers only "how do I look."** §5 adds the second subject.
7. **The debug panel ships.** §6 fences it out of the product.
8. **The rate limiter** is sized for a chattier Monitor than §3.3 describes.

None of these should be taken as an implementation plan. They are the distance
between here and the design, for the maintainer to sequence.
