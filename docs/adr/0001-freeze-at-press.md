# ADR-0001: Freeze at the keypress with an on-demand capture

Status: accepted (2026-11-19)
Date: 2026-11-19
Scope: the screenshot overlay

## Context

A screenshot is one frame of the screen at the instant the shortcut is pressed.
The overlay activates the app, which dismisses menus, popovers and tooltips, so
the pixels have to be taken before the overlay exists; a region dragged over a
playing video would otherwise be cut from a later frame than the one the user
aimed at. See `docs/capture-freeze.md`.

Three ways to get that frame:

1. **On-demand** — `SCScreenshotManager.captureImage` per display at the
   keypress (what the app does now).
2. **Persistent stream** — an `SCStream` kept running, keeping the newest
   frame, so the freeze is already in hand when the key arrives.
3. **Legacy display APIs** — `CGDisplayCreateImage` and friends, deprecated and
   unable to exclude the overlay's own windows.

## Decision

On-demand capture. Every display is frozen before the overlay is created, and
regions are cropped from those frames. Nothing captures the screen while the
app is idle.

Measured on a two-display setup (one 6K, one built-in), sampling the screen at
~77 ms: the overlay is up and complete one sample after the keypress, which is
one frame plus the capture itself. A stream would move that to roughly one
frame, and cost continuous capture to do it.

## Consequences

- No continuous capture: no battery cost, no screen-capture indicator in the
  menu bar, no stream to rebuild across sleep, display changes or a revoked
  grant.
- The frame is what the user saw when pressing, and it does not move while the
  region is chosen.
- **Cost:** 50–150 ms of live screen between the keypress and the freeze. On a
  moving display the change is visible. Once the overlay is up, its appearance
  does not change again (see "The first composite is the final appearance").
- **Cost:** full-resolution frames for every display are held until the capture
  finishes (roughly 31 MB per 16-inch Retina display, 81 MB per 6K display).
- Delaying the capture remains the tool for "wait until the screen looks like
  this": the countdown, then the same freeze.

## Alternatives considered

- **Persistent stream.** Would remove the 50–150 ms, at the price of capturing
  continuously: battery, a permanent capture indicator, a stream that has to be
  torn down and rebuilt when displays change, the app sleeps or the grant is
  revoked. Not worth it for a gap of one to two frames.
- **Window-level fade-in.** Tried; a window whose alpha animates is not picked
  up by window selection in its first frames, which breaks clicking a window
  right after the shortcut. Rejected.
- **Capturing the displays concurrently.** Tried; no measurable gain, because
  the cost is starting the capture, not doing it per display. Reverted.

## What a persistent stream costs, measured

M5 Pro, macOS 27, a 3024×1964 display and a 5120×2880 display. The stream kept
only the newest frame and encoded nothing, which is what "keep a frame ready"
means for a screenshot; the numbers are the app's own CPU.

| setting | frames in 8 s | CPU per frame |
| --- | --- | --- |
| 1 fps, 3024×1964 | 9 | 2.1 ms |
| 10 fps, 3024×1964, still screen | 58 | 0.7 ms |
| 30 fps, 3024×1964, still screen | 53 | 1.0 ms |
| 30 fps, 3024×1964, whole screen changing | 344 | 0.4 ms |
| 30 fps, 5120×2880 | 53 | 1.1 ms |

So the capture itself is cheap: about 1% of one core at 30 fps, 13 MB of the
app's memory, and no measurable change in system or WindowServer CPU. A static
screen produces far fewer frames than the requested rate, because only changed
frames are delivered.

What is not cheap:

- **Memory**, if frames are kept rather than one. One frame is 22.7 MB at
  3024×1964 and 56.2 MB at 5120×2880 — the same amount a capture already holds
  while it runs. Keeping every frame for 15 s at 15 fps on the 5K display would
  be about 12.6 GB, so a buffer has to be encoded: 15 s of 5K at 30 Mbps is
  about 56 MB.
- **The state itself**: a capture indicator stays in the menu bar for as long
  as the stream runs, and the stream has to be rebuilt across sleep, display
  changes and a revoked grant.
- **Energy in the GPU pipeline**, which process CPU does not show. Measuring it
  needs `powermetrics` as root and has not been done.

An idle stream is visible from outside, which makes the claim testable:
`CGWindowListCopyWindowInfo` lists an on-screen window named `StatusIndicator`,
owned by WindowServer, while a stream runs, and none while the app is idle.

## The first composite is the final appearance

A freeze is the last picture the user sees before the selection UI, so the
overlay may change the screen **once**: from the live desktop to its finished
look. Everything the overlay shows — the frozen frame, the 45 % dim, the window
under the pointer left out of the dim and outlined, the hint line, the colour
readout — is composed before the window is ordered front, and nothing redraws
it afterwards until the pointer moves.

Five things broke that, and each was measured:

1. **A transparent first frame.** A view's first draw lands a display cycle
   after the window is on screen, so the first composite was the live desktop.
   The window's layer is now given the finished picture before it is ordered
   front.
2. **The dim without the window cut-out.** The first version baked the dim over
   the whole frame, and the view's first draw then removed it from the pointer's
   window: a full-screen brightness step (median 128 → 70 → 128) about 30 ms
   after the overlay appeared.
3. **The window fade.** `NSWindow` fades a new window in unless told otherwise,
   so the live desktop showed through the overlay for about 150 ms. The window
   now sets `animationBehavior = .none`; two stills taken 1 s apart no longer
   differ by even one pixel.
4. **A draw after the overlay was up.** The entering-mouse event recomputed the
   window under the pointer and requested a redraw, which landed as a second
   change. The hover state is computed before the window appears, and the
   entering event no longer redraws when the value it computes is the one
   already set. Moving the pointer still redraws, because the colour readout
   follows it.
5. **Hints arriving late.** The sample and the colour readout were filled by an
   asynchronous capture ~100–150 ms after the window appeared. Both are now
   taken from the frozen frame synchronously.

Measured: with a still desktop and a fixed 800 × 500 window under the pointer,
the first still showing the overlay is identical to one taken a second later
(0 of 5.9 M pixels differ), and the patches read 14.5 → 7.9 outside the window
and 140.0 → 139.9 inside it — one step, then still. With a screen that changes
on every refresh, the stream shows one transition frame (~11 ms) and no frame
of live picture afterwards.

Timing from the shortcut to the overlay on screen, measured with timestamps
inside the app: 100–170 ms, of which 80–125 ms is the screen capture and 21–46 ms
is rendering the view and ordering the window front; the second display follows
37–39 ms later. The render-and-show part is inside one frame band; the capture
is the cost this ADR already accepts.

## What would reopen this

A capture mode that needs a frame from *before* the keypress — a rolling buffer
that hands over the last N seconds — or a measured requirement for a freeze
under one frame. Either moves the cost to continuous capture and needs its own
decision and its own ADR.

A user choice between freezing at the keypress and capturing when the region is
chosen would not change this decision: both paths capture on demand. It is a
product switch, and where it lives is a placement decision, not an engineering
one.
