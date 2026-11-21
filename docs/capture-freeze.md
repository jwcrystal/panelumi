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
   The view is drawn once into a bitmap — frozen frame, dim, the pointer's
   window left out of the dim, hints, colour readout — and that bitmap is the
   window's first composite. A view's own first draw is a display cycle later,
   and the live desktop would be the first thing the window showed.
4. A region is cut from that frame (`captureRegion` → `ScreenCaptureService.crop`).
   If a display produced no frame, that display falls back to a live capture,
   exactly as before.

A second press during the freeze cancels it, the same way a second press
cancels the countdown. The frames are dropped on cancel and on finish.

## One appearance, then still

The overlay changes the screen exactly once: from the live desktop to its
finished look. Three things would make it change a second time, and all three
are off:

- **No window fade.** `NSWindow.animationBehavior = .none`; the system's default
  fades a new window in, and the live desktop shows through it for ~150 ms.
- **No redraw on the entering-mouse event.** The window under the pointer is
  picked before the window is ordered front, and the entering event only
  redraws when the answer changed. A move of the pointer still redraws, because
  the colour readout follows it.
- **No late hints.** The sample and the colour readout come from the frozen
  frame synchronously, not from a capture that lands after the window is up.

Measured: the first still that shows the overlay is identical to one from a
second later, and a display changing on every refresh shows one transition frame
and no live frame after it.

## What stays live

- **Picks are matched against the list taken at the press.** Activating the
  overlay dismisses menus, popovers and menu bar panels before it can look, so
  every pickable window is listed once at the press and asked first; a window
  that appeared after that still comes from the live list. The list covers the
  windows on layers 0–8, the Dock and layers 25–1000, minus the menu bar.
- **Window clicks are still captured per window** with
  `SCContentFilter(desktopIndependentWindow:)`. Cutting a window out of the
  frozen display would put occluding windows and their shadows into the shot,
  and composing several windows needs each window's own image. A window that
  moved between the press and the click is captured at its click-time state;
  one that closed has its pixels cut from the frozen frame, at the rect it was
  picked at.
- **Status items and menus are captured at the press.** They are gone by the
  click, so each is captured window by window at the press and cropped to the
  part that is actually drawn: a panel like Control Center lives in a window far
  larger than itself, with the rest transparent.
- **The Dock is a strip, not a window.** Its window covers the whole display
  rather than the strip it draws, so the pick is the part of the screen its
  `visibleFrame` gives up, and its pixels are cut from the frozen frame. Nothing
  about it is captured on every press, and a hidden Dock is simply not there.
- **The menu bar stays out.** It is a 33-point strip across the top, which is
  where the pointer rests right after its icon was clicked to open a panel, so
  it would answer instead of the panel the user is aiming at. Drag a region for
  it.
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
  a few tens of milliseconds apart. Measured: the second display follows the
  first by 37–39 ms; worth revisiting before making the captures concurrent.
- From the shortcut to the overlay on screen: 100–170 ms — 80–125 ms of capture,
  then 21–46 ms to draw the view and order the window front.

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
9. A window with a menu open: picking the window gives the window without the
   menu; picking the menu itself gives the menu. The same for a status item
   popover (pointer inside the popover, not on its icon), for a menu bar panel
   such as Stats' CPU module, and for the Dock.
