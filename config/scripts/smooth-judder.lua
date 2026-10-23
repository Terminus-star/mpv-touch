-- smooth-judder: remove uneven frame timing (judder) with the least work, based on the
-- display's current refresh rate. It never invents frames, so it cannot add artifacts.
--
-- Judder happens when the refresh rate is not a whole multiple of the video's frame rate:
-- 24 fps on 60 Hz shows frames for 2,3,2,3 refreshes. On a panel with VRR (variable refresh)
-- the display can match the video instead, and mpv's own smoothing (display-resample) would
-- fight that by forcing a fixed rate. So:
--
--   * refresh >= vrr_min_hz (the 180 Hz mode, VRR 48-180 Hz): leave mpv alone.
--   * refresh below it (the 60 Hz mode): if the video rate does not divide evenly into the
--     refresh rate, turn on mpv's frame smoothing with tscale=oversample, the lightest kind,
--     which blends only at the one frame boundary that would be uneven. Rates that already
--     fit (30 or 60 fps on 60 Hz) get no extra work.
--
-- It follows the display live: switching the panel between 60 and 180 Hz, or moving mpv to
-- another monitor, re-evaluates at once. Nothing else is changed, and the original
-- video-sync / interpolation / tscale values are put back when the fix is not needed.
--
-- Options (script-opts/smooth-judder.conf): enabled, vrr_min_hz, tolerance.

local options = require('mp.options')
local msg = require('mp.msg')

local opts = {
    enabled = true,
    -- refresh rates at or above this are treated as the VRR mode
    vrr_min_hz = 100,
    -- how close refresh / fps must be to a whole number to count as even (0.005 = 0.5 %)
    -- so 29.97 fps on 60 Hz counts as even
    tolerance = 0.005,
}
options.read_options(opts, 'smooth-judder')

-- the user's own settings, put back when smoothing is not needed
local base = {
    ['video-sync'] = mp.get_property('video-sync'),
    interpolation = mp.get_property('interpolation'),
    tscale = mp.get_property('tscale'),
}

-- true when frames would be shown for an uneven number of refreshes
local function needs_smoothing(refresh, fps)
    if not refresh or not fps or refresh <= 0 or fps <= 0 then return false end
    if refresh >= opts.vrr_min_hz then return false end
    local ratio = refresh / fps
    if ratio < 1 then return false end -- more video frames than refreshes: nothing to even out
    local nearest = math.floor(ratio + 0.5)
    return math.abs(ratio - nearest) > opts.tolerance * nearest
end

local active = false

local function set_active(on)
    if on == active then return end
    active = on
    if on then
        mp.set_property('video-sync', 'display-resample')
        mp.set_property('tscale', 'oversample')
        mp.set_property('interpolation', 'yes')
    else
        mp.set_property('video-sync', base['video-sync'])
        mp.set_property('tscale', base.tscale)
        mp.set_property('interpolation', base.interpolation)
    end
    msg.info('frame smoothing ' .. (on and 'on' or 'off'))
end

local warned = false

local function update()
    if not opts.enabled then
        set_active(false)
        return
    end
    local refresh = mp.get_property_number('display-fps')
    local fps = mp.get_property_number('container-fps')
    -- mpv cannot always read the refresh rate (not on every platform or output); without it
    -- the safe choice is to leave playback as it is
    if fps and not refresh and not warned then
        warned = true
        msg.warn('display-fps is not available on this output, so frame smoothing stays off')
    end
    set_active(needs_smoothing(refresh, fps))
end

mp.observe_property('display-fps', 'number', update)
mp.observe_property('container-fps', 'number', update)
