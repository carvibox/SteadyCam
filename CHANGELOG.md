# Changelog

## 1.1.0 (2026-10-06)

- Mounts SteadyCam doesn't know (newer than its data, or far bigger or smaller than any it has
  measured) are flagged: every time you ride one, a chat line says its framing is only approximate,
  with a link to calibrate it, until you do. On by default; a switch in the Advanced settings.
- "View my mounts" marks those mounts as "Not known yet".
- Dark text on gold buttons and tabs is bold, without the shadow that made it look doubled.

## 1.0.1 (2026-10-05)

- New Discord invite in the window's Discord button.

## 1.0.0 (2026-10-05)

First public release.

### Framing
- Horizontal framing that stays put on foot, mounted, flying and on flight paths.
- Separate vertical framing for walking and flying.
- Mounted modes: *Same as on foot*, *Centered* or a custom offset.
- Camera turn speed slider (10–200% of the game's default, 100% by default).
- Recommended values out of the box (on foot 0.80 / 0.70, mounted same as on foot, flying 0.60), and a
  "Recommended values" button next to "Restore Blizzard camera" in the Advanced settings.
- Real-time compensation during mount and dismount, including dismounts in the air.
- Handles Worgen and Dracthyr form changes, Dracthyr Soar, flight paths and mounts that hide the character.

### Data
- Built-in measurements for every playable race, both sexes and alternate forms.
- Size-based estimates for nearly 2,000 mounts; mounts that share a model share their data.

### Calibration
- Optional guided calibration, about one minute per mount, one button press per step. It says one
  line in /say per step, and can't be run in cities or inns so it never spams a crowd.
- Optional chat link that starts calibration when you ride an uncalibrated mount (off by default).
- Calibration lives in the Advanced settings, so the main window stays simple.
- "View my mounts" window: calibrated and uncalibrated mounts with search, where each mount's data comes
  from, and a click menu to ride, preview or calibrate a mount. Ctrl-click previews it in the Dressing
  Room (also in the calibration mount list). The mount you ride is highlighted, and the scroll bars can
  be clicked and dragged.
- Detects common problems (a wall behind you, movement, zooming, combat) and explains how to fix them.
- Big mounts: if the chat bubble can't be measured, the vertical framing is lowered for that calibration
  only (you're told), and your own setting comes back afterwards.

### Quality of life
- Settings window with live preview, opens automatically on first login.
- AddOns minimap button and Options panel entry.
- Combat Mode integration: Combat Mode hands its camera settings to SteadyCam (with a Combat Mode
  version that includes the handoff).
- Detects DynamicCam (which changes the same settings) and asks in a game dialog whether to disable it.
- Warns about other addons or macros changing the same settings.
- Optional respect for Blizzard's motion sickness settings.
- Turning SteadyCam off restores your original camera settings. "Restore Blizzard camera" (the game's
  own framing) and "Recommended values" ask for confirmation in a game dialog.
- "Save my preferences" keeps a copy of your framing choices (it turns green while they are saved), and
  "Load my preferences" in the Advanced settings brings them back.
- Advanced settings ask "I know what I'm doing" before opening.
- Live previews show where your character really sits on screen, on foot and mounted (measured in
  game, not a sketch).
- Sliders have an arrow on each side for fine steps (sized to each slider's range); the handle grows
  under the cursor and can be grabbed anywhere without jumping. Right-click resets to the default.
- New look: the SteadyCam wordmark and icon (also in the AddOns list and Options), rounded corners,
  a warmer gold, and roomier windows.
- Localized in English, Spanish, German, French, Italian, Brazilian Portuguese, Russian, Korean and
  Simplified / Traditional Chinese.
