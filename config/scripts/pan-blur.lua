-- pan-blur: one key sets how much the camera-move filter (vs/pan-interp.vpy) softens fast pans.
--
--   Ctrl+p  ->  mix-high -> mix-max -> step -> step-adaptive -> mix-step -> double
--               -> mix-step-double -> off -> mix-high ...   (see input.conf)
--   The mix levels blur the real frames and add a blended in-between frame; step adds one
--   interpolated part of the way, and step-adaptive picks that distance from the speed of the
--   move; double is full frame doubling (no blur, the in-between frame is the true halfway
--   frame); mix-step and mix-step-double average the in-between frames of mix-high and step, or
--   of mix-high, step and double. All of them double the frame rate inside a camera move. The
--   blur-only levels (low, medium, high) and mix-low were removed as not strong enough.
--
-- Playback starts with the filter off, so the first press gives "mix-high". The level is handed to
-- the VapourSynth script as `user-data`. A running script cannot be changed, so each press
-- removes the filter and adds it again with the new level (it restarts for a moment, and the
-- first frames after a restart can be slow while MVTools warms up).
--
-- Needs a VapourSynth-enabled mpv such as cachyos/mpv-git. With the stock mpv adding the filter
-- fails; this script then says so and stays off.

local msg = require('mp.msg')

local SCRIPT = '~~/vs/pan-interp.vpy'
local LABEL = 'pan'
local levels = {'mix-high', 'mix-max', 'step', 'step-adaptive', 'mix-step', 'double', 'mix-step-double', 'off'}

local index = 0  -- 0 = never pressed, which is the same as off

local function apply(level)
    mp.command_native({name = 'vf', operation = 'remove', value = '@' .. LABEL})
    if level == 'off' then return true end
    -- command_native returns (nil, error text) on failure and no second value on success
    local _, err = mp.command_native({
        name = 'vf', operation = 'add',
        value = '@' .. LABEL .. ':vapoursynth=file=' .. SCRIPT .. ':user-data=' .. level,
    })
    if err then msg.warn('vf add failed: ' .. err) end
    return err == nil
end

mp.register_script_message('pan-blur-cycle', function()
    local next_index = index % #levels + 1
    local level = levels[next_index]
    if apply(level) then
        index = next_index
        mp.osd_message('Pan blur: ' .. level, 2)
        msg.info('pan blur level: ' .. level)
    else
        index = 0
        mp.osd_message('Pan blur unavailable (needs a VapourSynth-enabled mpv)', 4)
        msg.warn('could not add the vapoursynth filter')
    end
end)
