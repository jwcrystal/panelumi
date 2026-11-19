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
  moving display the change is visible; the overlay fades the frozen frame in
  on its first composite so the cut is not preceded by a transparent frame.
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

## What would reopen this

A capture mode that needs a frame from *before* the keypress — a rolling buffer
that hands over the last N seconds — or a measured requirement for a freeze
under one frame. Either moves the cost to continuous capture and needs its own
decision and its own ADR.
