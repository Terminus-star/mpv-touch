# Third-party notices

The `LICENSE` file (MIT, Copyright (c) 2026 Seifelden Abdelmonem) covers the files written for this
project. It does **not** cover the files listed below, which belong to other people and keep their own
licences. Full licence texts are in `LICENSES/`; where a file carries its own notice in its header, that
header is left intact.

"Unmodified" below means compared byte for byte with the copy it came from.

## mpv-touch-gestures (GPL-2.0)

- Files: `config/scripts/touch-gestures.lua`, `config/script-opts/touch-gestures.conf`
- Upstream: <https://github.com/christoph-heinrich/mpv-touch-gestures>
- Licence: GNU General Public License version 2, as shipped in the upstream `LICENSE` (copy:
  `LICENSES/GPL-2.0-only.txt`). The upstream files state no "or later" clause, so only version 2 is
  claimed here.
- **Modified.** In `touch-gestures.lua` the left-half vertical swipe no longer changes playback speed; it
  changes the screen brightness (KDE's brightness service, the backlight through systemd-logind, or mpv's
  own picture brightness), with the new option `brightness_min` and `brightness_backend`. In
  `touch-gestures.conf` `horizontal_drag` is `seek` instead of `playlist`, and the two new options are
  added. Because these files are modified GPL code, **they are distributed under the GPL-2.0**, not MIT.

## mpv-pointer-event (GPL-2.0)

- Files: `config/scripts/pointer-event.lua` (unmodified), `config/script-opts/pointer-event.conf`
- Upstream: <https://github.com/christoph-heinrich/mpv-pointer-event>
- Licence: GNU General Public License version 2 (`LICENSES/GPL-2.0-only.txt`).
- **Modified:** only `pointer-event.conf` (the `left_single` binding also flashes uosc's pause
  indicator). Distributed under the GPL-2.0.

## uosc (LGPL-2.1)

- Files: `config/scripts/uosc/` (unmodified), `config/fonts/uosc_icons.otf` and
  `config/fonts/uosc_textures.ttf` (unmodified), `config/script-opts/uosc.conf`
- Upstream: <https://github.com/tomasklaen/uosc>
- Licence: GNU Lesser General Public License version 2.1 (`LICENSES/LGPL-2.1-only.txt`, the upstream
  `LICENSE.LGPL`).
- **Modified:** only `uosc.conf` (`timeline_step`, `pause_indicator`). Distributed under the LGPL-2.1.
- Not checked: whether the icon and texture glyphs inside the font files carry a separate licence of
  their own; uosc ships them as part of its repository.

## Shaders (`config/shaders/`, all unmodified, copied from the `mpv-anime-build` release zip)

| File | Author named in the file | Licence |
|---|---|---|
| `ArtCNN_C4F16.glsl`, `ArtCNN_C4F32.glsl` | Joao Chrisostomo, Kacper Michajłow (2024) | MIT (full notice in each file's header) |
| `FSRCNNX_x2_8-0-4-1_LineArt.glsl` | igv (2017-2021) | LGPL-3.0 or later (`LICENSES/LGPL-3.0-or-later.txt`) |
| `KrigBilateral.glsl` | Shiandow | LGPL-3.0 or later (`LICENSES/LGPL-3.0-or-later.txt`) |
| `adaptive-sharpen-anime-1080p.glsl` | bacondither (2015-2021) | BSD-style (full notice in the file's header; it must stay with the file) |

## Not included, but used

- mpv, VapourSynth and MVTools (for `config/vs/pan-interp.vpy`) are not part of this repository.
- `vendor/` is listed in `.gitignore`: it held untouched clones of the three upstream projects above,
  and is not distributed here.

This file records what was found in the files and upstream licences; it is not legal advice.
