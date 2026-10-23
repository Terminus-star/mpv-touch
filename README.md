# mpv-touch

A touch-friendly plain mpv setup, made to compare against the patched Haruna in
`../haruna-touch`. It runs from its own config folder and never reads `~/.config/mpv`.

## Run

    mpv-touch/scripts/run.sh /path/to/video.mkv

Any extra arguments go straight to mpv. Run from `/home/termis/Projects`.

The same files are also installed in the default config, `~/.config/mpv`, so plain `mpv`
now has these gestures too (installed 2026-10-14). `run.sh` still uses only this folder.
The default `mpv.conf` also turns off the window border and dragging for every mpv launch.

## Gestures (touch counts as the left mouse button)

| Gesture                      | Action                                   |
|------------------------------|------------------------------------------|
| Single tap                   | play / pause (after the double-tap wait) |
| Double tap, left third       | seek back 10 s                           |
| Double tap, middle third     | toggle fullscreen                        |
| Double tap, right third      | seek forward 10 s                        |
| Long press                   | uosc menu                                |
| Vertical swipe, right half   | volume                                   |
| Vertical swipe, left half    | screen brightness (KDE's slider on KDE, else the backlight via systemd-logind; see `brightness_backend`) |
| Horizontal swipe             | seek (proportional to the swipe width)   |

Taps inside the margins in `config/script-opts/pointer-event.conf` (top 50 px, bottom
130 px, right 80 px) are ignored by the gestures, so they reach uosc's controls instead.

## What is in here

- `config/`  the mpv config folder passed with `--config-dir`
  - `mpv.conf`  turns off mpv's own OSC, OSD bar, border and window dragging; decodes on the
    GPU with `hwdec=auto-safe` (about 10x less CPU than software in a test here; 10-bit H.264
    falls back to the CPU on its own); opens
    fullscreen and paused (`fullscreen=yes`, `pause=yes`; only the first file starts paused,
    the next playlist item plays straight away); `idle=once` so mpv stays open when started
    with no files (last-session.lua needs it) but still quits when a file it was given ends; turns on
    `save-position-on-quit` so half-watched videos resume (finished ones start over; saved
    in `~/.local/state/mpv/watch_later`); keeps `video-align-y` out of the saved options so
    the fullscreen shift is never restored in windowed mode
  - `input.conf`  arrow-key seeks are exact (`relative+exact`, like the touch gestures) and
    also flash uosc's timeline; horizontal touchpad
    scroll (`WHEEL_LEFT` / `WHEEL_RIGHT`) is turned off because it seeked 10 s per event;
    `Ctrl+q` quits, and plain `q` is unbound (`Q` and `Ctrl+w` still quit)
  - `scripts/touch-gestures.lua`, `scripts/pointer-event.lua`, `scripts/uosc/`
  - `scripts/fullscreen-align.lua`  in fullscreen only, moves the video so its bottom edge sits
    exactly on top of uosc's seekbar strip instead of being centred. With a 16:9 video on a
    16:10 screen the bottom black bar is smaller than the seekbar, which then covers a few
    pixels of picture; the video moves up by just that shortfall (never past the top).
    The strip height is read from `uosc.conf` (`timeline_size`, `timeline_border`,
    `scale_fullscreen`) and the display scale. `reserve_px` in `fullscreen-align.conf`
    overrides it if the result is off on your screen. Windowed mode is left as it was.
  - `scripts/last-session.lua`  started with no files, reopens the playlist you last had on the
    item you were watching, at the position mpv saved for it (half-watched videos continue,
    finished ones start over). Saved to `~/.local/state/mpv/last-session.json` on quit (and every
    30 s). Opening any file replaces the remembered playlist. Missing files are skipped, an empty
    playlist is never saved, and with no saved session mpv just waits idle.
  - `scripts/smooth-judder.lua`  removes uneven frame timing (judder) with the least work,
    following the display's current refresh rate. At 100 Hz or more (the 180 Hz mode, panel VRR
    48-180 Hz) it does nothing, so VRR can match the video. Below that (the 60 Hz mode) it turns
    on mpv's frame smoothing (`display-resample` + `interpolation`, `tscale=oversample`, the
    lightest kind) only when the video rate does not divide evenly into the refresh rate
    (24, 23.976, 25 fps; 30 and 60 fps need nothing). It invents no frames, so it adds no
    artifacts, and it re-checks when the panel is switched between 60 and 180 Hz. If mpv
    cannot read the refresh rate it stays off and logs why. Options in `smooth-judder.conf`.
  - `vs/pan-interp.vpy`  VapourSynth filter that softens the stepping of fast camera moves
    (about 6.4 px per frame at 1080p or more) and leaves character animation and slow drifts alone.
    Inside a detected move the output has twice the frame rate: each real frame is followed by an
    in-between frame, and outside moves by an exact repeat, so the cadence stays even. Levels,
    weakest to strongest: `mix-high` and `mix-max` blur the real frame along its motion (MVTools
    `FlowBlur`, like a camera shutter) and add a blend of it with the motion-interpolated halfway
    frame (50 % or 70 %); `step` and `step-adaptive` blur the same way but add a frame interpolated
    35 % of the way to the next one (20 %, 30 % or 40 % by the speed of the move for `step-adaptive`),
    not blended; `double` is frame doubling: no blur, and the in-between frame is the full halfway
    frame; `mix-step` and `mix-step-double` are combinations whose in-between frame is the equal
    average of the in-between frames of `mix-high` and `step`, or of `mix-high`, `step` and
    `double` (real frames blurred at 50 %). Blur only softens the steps and an in-between frame
    shrinks them; earlier versions with blur-only levels (`low`, `medium`, `high`) and `mix-low`
    were removed as not strong enough, and `double` is the old "48 fps" look kept as an option for
    the scenes where the others are not enough (it was judged too smooth when it was the only mode).
    A move is detected on a half-resolution copy: most of the picture must move,
    little of it may be left unexplained by one camera motion (this rejects dissolves and a
    character changing pose), and the decision is a vote over 11 neighbouring pairs so it cannot
    flicker. The last ~0.2 s of a file is not output (the vote needs look-ahead). Needs a
    VapourSynth-enabled mpv (`cachyos/mpv-git`) and `vapoursynth-plugin-mvtools`; with the stock mpv
    `Ctrl+p` says so on screen and does nothing. Tested here on synthetic clips with thin lines
    panning 8 px per frame: the 2x output keeps even timestamps, and clips with only local motion
    stayed byte-identical at `mix-high`, `mix-max`, `step-adaptive` and `double`. The `mix` in-between
    frame is a cross-fade, so it ghosts: `mix-high` shows a clear second copy of each line and dashed
    diagonals, `mix-max` more so. `step`, `step-adaptive` and `double` interpolate instead of blending,
    so lines move and nothing ghosts (checked on pixels for `step` and `double`); they use 16 px
    motion blocks, because with 32 px blocks the repeating thin lines matched wrongly and each
    vertical line came out twice. `step` is slightly uneven in time (content at 0, 35 %, 100 %);
    `double` is even. The combinations look different from their parents: on the thin-line test each
    line becomes a soft, slightly wider band with a faint halo and no separate doubled lines (the
    averaged frames sit only about 1 px apart at 8 px per frame, so they smear instead of splitting);
    softer than `step` or `double`, without `mix-high`'s ghosting. They interpolate two frames per
    move (the halfway frame is shared when `mix-high` and `double` are both members, so the
    three-way combination costs the same as the two-way one). Measured on the 720p test clip
    (111 flagged frames, CPU seconds above the filter-off baseline of 0.96): `mix-high` 5.4,
    `mix-step` 7.9 and `mix-step-double` 7.9, i.e. about 1.45x `mix-high`; that is roughly 0.05 CPU-s
    per flagged frame for `mix-high` and 0.07 for the combinations at 720p. At 1080p I would expect
    about 2.25x that (a scaling estimate, not measured), a few cores while a pan lasts.
    Clips with only local motion stayed untouched for both. `step-adaptive`'s 20/30/40 % are my guess
    at good values. On a 16 px/frame test
    pan the real frames of `step` get a wide soft blur while the in-between frame stays sharp, so
    the output alternates soft and sharp frames; whether that shows as pulsing I have not judged.
    The same wrong-vector risk exists on repeating thin patterns for the `mix` levels (32 px blocks).
    Not yet judged on real footage on the real screen, except that you found `mix-max`, `step` and
    `step-adaptive` better than the earlier levels but not enough in some scenes (hence `double`).
    Tunable with `PAN_*` environment variables (see the file header).
  - `scripts/pan-blur.lua`  `Ctrl+p` cycles the level mix-high, mix-max, step, step-adaptive,
    mix-step, double, mix-step-double, off (starts off) and names it on screen
    (`Pan blur: mix-high`). The level is passed
    to the filter as `user-data`; a
    running VapourSynth script cannot be changed, so each press re-adds the filter, which restarts
    it for a moment. Known limit: MVTools reads frames while the script loads and mpv answers with
    black dummy frames, so the first one or two frames after the filter starts (and after each
    seek, which reloads the script) can be black for about 40-80 ms.
  - `shaders/`  five anime upscaling shaders copied from the `mpv-anime-build` release zip, headers
    intact: `ArtCNN_C4F16` and `ArtCNN_C4F32` (MIT), `KrigBilateral` and `FSRCNNX_x2_8-0-4-1_LineArt`
    (LGPL-3.0), `adaptive-sharpen-anime-1080p` (BSD-style). `Ctrl+u` cycles light, balanced, quality,
    off (starts off) through `scripts/upscale-tier.lua`, and the on-screen message names the tier
    (`Upscaling: balanced`); the shader lists per tier are in that script. They only run when the
    screen is more than 1.3x the video width. `FSRCNNX_..._LineArt` is kept but not on a key.
  - `scripts/seek-pause.lua`  holds playback for `hold_ms` (250) after every seek, then
    resumes, like YouTube. It ignores videos you paused and drops the hold if you un-pause.
  - `scripts/hdr-auto.lua`  switches the display into HDR mode only while the video playing is HDR
    (transfer function `pq` or `hlg`, or a Dolby Vision colour matrix), and gives it up afterwards.
    SDR videos, including SDR in a wide BT.2020 container, never touch the display. It does not
    change the display itself: it asks `/home/termis/Projects/mpv-touch/scripts/hdr-session.sh`, which counts
    everything that wants HDR (mpv, a gamescope started with `--hdr-enabled`) and restores the
    previous state (HDR on or off, wide gamut, profile source, and the SDR backlight) when the last
    one is gone. Only with a real window, so headless runs (`--vo=null`) do nothing. A 4 s grace
    period keeps HDR on between two HDR files in a playlist. At shutdown the release runs detached,
    because mpv cancels a command it is waiting on while quitting (that cut the release short).
    Tested on synthetic clips (SDR, wide-gamut SDR, HDR10, HLG) with a stub, and for real on a Dolby
    Vision profile 8.1 episode (`colormatrix dolbyvision`, PQ): HDR switched on while it played, off
    when mpv closed, and the backlight returned to the slider. mpv needs no config change for this:
    with defaults it already uses `gpu-next` on Wayland/Vulkan and tells KDE the video is HDR (PQ).
    If mpv is killed (SIGKILL) the watcher service `hdr-session.service` restores the display (tested:
    within half a second). Without the service, restore by hand:
    `scripts/hdr-session.sh release mpv PID` or `kscreen-doctor output.eDP-1.hdr.disable`.
  - `scripts/refresh-auto.lua`  switches the panel to a refresh rate that fits the video while a
    23.976 fps video plays (`container-fps` within 0.02 of 23.976) and puts your previous mode back
    afterwards. 23.976 fps does not divide into 180 Hz (frames are held 7 and 8 refreshes
    alternately); at 143.87 Hz it is 6 refreshes per frame. Same design as `hdr-auto`: it asks
    `/home/termis/Projects/mpv-touch/scripts/refresh-session.sh` (counts requesters, restores the mode when the
    last is gone), 4 s grace between playlist items, detached release at shutdown, real window only.
    Playback is paused while the display switches (about 2 s) if it was running. Needs the custom
    mode once: `scripts/refresh-session.sh setup` (KDE stores it as 143.87 Hz, the closest it allows
    to 143.856). The watcher unit `scripts/refresh-session.service` restores the mode if mpv is
    killed (tested with SIGKILL). `smooth-judder` stays idle at this rate (it acts below 100 Hz).
    Measured on one pan scene (E02, SDR): 84-90 % of frames on time at the matched mode against 4 %
    at 180 Hz; with an HDR video 57 % (67 % of gaps exactly 6 refreshes). Not judged by eye.
  - `script-opts/`  options for the scripts. Changed from upstream:
    - `touch-gestures.conf`: `horizontal_drag=seek` instead of `playlist`
    - `pointer-event.conf`: `left_single` also flashes uosc's pause icon
    - `uosc.conf`: `pause_indicator=manual`, so the hold after a seek does not blink the
      icon. Pauses you make (space, `p`, media keys, right click, tap) flash it from
      `input.conf` / `pointer-event.conf` instead.
    - `uosc.conf`: `timeline_step=1!` (was `5`), so a two-finger scroll over the progress bar
      seeks 1 s (exact) per scroll event instead of 5 s; lower it (for example `0.5!`) to slow
      it further.
    - `seek-pause.conf`: new, `hold_ms=250` (0 turns the hold off)
    - `hdr-auto.conf`: new, `enabled`, `session_command` (path of `hdr-session.sh`), `require_vo`,
      `release_delay=4`
    - `refresh-auto.conf`: new, `enabled`, `session_command` (path of `refresh-session.sh`),
      `target_fps=23.976`, `tolerance=0.02`, `require_vo`, `release_delay=4`, `pause_while_switching`
  - `fonts/`  the icon fonts uosc needs
- `scripts/run.sh`  launcher
- `scripts/run-lsfg.sh`  starts mpv with lsfg-vk (Lossless Scaling frame generation) at x2, the
  lowest multiplier, only when the panel is at 100 Hz or more (the 180 Hz mode, where 23.976 fps
  becomes 47.95 fps and VRR can show it). At 60 Hz, or if `Lossless.dll` cannot be read, it starts
  plain mpv instead. It turns on the Vulkan layer for that run only (`ENABLE_LSFG=1`), makes mpv
  draw through Vulkan, and turns off `smooth-judder` so the two do not fight over timing. Your
  normal `mpv` is unchanged. `LSFG_DRY_RUN=1` prints the decision without starting anything and
  `REFRESH_HZ=60` pretends the panel is at 60 Hz.
- `lsfg/conf.toml`  the lsfg-vk settings for that launcher (through `LSFG_CONFIG`): multiplier 2,
  flow scale 0.8, performance mode off. Your own `~/.config/lsfg-vk/conf.toml` (the Decky plugin's)
  is not touched. The DLL is read from the Windows Steam library, not copied.
- `vendor/`  untouched clones the files above were copied from

## Where the code came from (read before use)

| Project | Commit | Copied |
|---|---|---|
| [mpv-touch-gestures](https://github.com/christoph-heinrich/mpv-touch-gestures) | `f4aa499f038997c1824ff3bfa64ee1d5438d72f2` (2023-02-03) | `touch-gestures.lua`, the two `.conf` files |
| [mpv-pointer-event](https://github.com/christoph-heinrich/mpv-pointer-event) | `33c5ede5977817596ace5a9942a8c801ad3b3d28` (2023-02-03) | `pointer-event.lua` |
| [uosc](https://github.com/tomasklaen/uosc) | `12b918fcbcae56ded0e073a965d769bb0c5d900e` (2026-08-30) | `src/uosc`, `uosc.conf`, the two fonts |

mpv scripts run with your user's permissions. The two gesture scripts were read in full
and use only mpv's own API. For uosc I searched for process spawning and network use.
Two things to know:

- uosc was cloned from source, not installed from its release zip, so the compiled
  `ziggy` helper is missing. Subtitle search/download and clipboard features that need it
  will not work. Playback and the UI do not need it.
- **Do not use uosc's `update` command.** It downloads and runs an install script
  from GitHub into this config folder, replacing what was reviewed.

The optional `thumbfast` helper is not installed, so uosc logs one harmless message about it.

## Known limits

- Both gesture scripts are from February 2023. They load on mpv 0.41 but I have not
  tested every gesture on touch hardware.
- Double-tap seek is a fixed 10 s in the script. Change it in
  `config/scripts/touch-gestures.lua` (the two `seek -10` / `seek 10` lines) if you want it smaller.
- Left or right half is decided when the swipe is first recognised (after about 10 px of
  movement), not at the exact point the finger touched down.
