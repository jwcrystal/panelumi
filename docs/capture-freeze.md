# Capture freezes before the overlay opens

A screenshot is one frame of the screen, taken when the shortcut is pressed.
Everything the user does afterwards — picking a region, a window, mosaic, blur,
the final output — is done on that frame.

## Why a freeze at all

The overlay activates the app. On macOS that dismisses whatever the frontmost
app had open: menus, popovers, tooltips, notification banners. Capturing at the
end of the gesture therefore loses exactly the transient UI a screenshot is
often for, and a region dragged over a playing video or a spinner is cut from a
later frame than the one the user aimed at.

Freezing first keeps the selection and the pixels on the same instant, which is
also what makes the editor honest: mosaic and blur land on the pixels they are
drawn over.

## Where it happens

1. `ScreenshotCoordinator.begin` calls `startFrozen` instead of opening the
   overlay directly. A delayed capture runs the same path after its countdown.
2. `captureEveryScreen` takes one frame per display through
   `ScreenCaptureService.captureDisplay`. No overlay window exists yet, so the
   exclusion set is empty and the shareable-content cache can serve the call.
3. `start` hands the frames to `SelectionController`, which gives each
   `SelectionView` its own display's frame. The view paints it under the dim
   layer, so the whole desktop is still and the frame is what the user sees.
4. A region is cut from that frame (`captureRegion` → `ScreenCaptureService.crop`).
   If a display produced no frame, that display falls back to a live capture,
   exactly as before.

A second press during the freeze cancels it, the same way a second press
cancels the countdown. The frames are dropped on cancel and on finish.

## What stays live

- **Window clicks** are still captured per window with
  `SCContentFilter(desktopIndependentWindow:)`. Cutting a window out of the
  frozen display would put occluding windows and their shadows into the shot,
  and composing several windows needs each window's own image. A window that
  moved or closed between the press and the click is captured at its click-time
  state.
- **Extension live captures** (`CaptureContext.captureLive`) are live by
  contract; a takeover that needs several frames of a changing screen keeps
  getting them.
- **The debug demos** (`--selection-demo`) keep the live desktop.

## Costs

- The overlay appears after the freeze rather than immediately. The first
  capture after an idle period pays for `SCShareableContent` (a few hundred
  milliseconds, which the 20 s cache already exists to soften); later ones pay
  for one `captureImage` per display.
- All displays' frames are held until the capture finishes: roughly 31 MB for a
  16-inch Retina display and 81 MB for a 6K display, dropped on finish or
  cancel.
- Multi-display setups are frozen one display at a time, so the displays can be
  a few tens of milliseconds apart. Invisible on a single display; worth
  measuring before making the captures concurrent.

## Manual checks (needs a real Mac)

1. Open a menu, press the capture shortcut: the menu is in the frozen overlay
   and in the result.
2. Hover a tooltip or a popover, capture, confirm it stays.
3. Play a video, capture, drag: the picture does not move, and the result is
   the frame that was on screen when the shortcut was pressed.
4. Delay of 3 s: the countdown runs, the screen freezes afterwards, and a
   second press during the freeze cancels without opening the overlay.
5. Two displays: both freeze; a region on the second display keeps its size and
   its pixels.
6. Text recognition over transient text (a hover popover) reads the frozen text.
7. `Esc` mid-selection: no full-screen frame is left held.
8. No Screen Recording grant: the checklist opens and no overlay appears.
