-- fullscreen-align: in fullscreen, push the video down so its bottom edge sits directly above
-- the strip where uosc draws its seekbar. On a screen taller than the video (for example a
-- 16:9 video on a 16:10 display) the black space is then no longer split above and below:
-- the part under the video holds the seekbar, the rest sits above the video, and uosc's
-- control buttons still overlay the lower part of the picture as usual.
--
-- How: video-align-y places the video inside the free black space (-1 top, 0 centre,
-- 1 bottom). To leave `gap` pixels under the video out of `free` pixels of black:
--     align = 1 - 2 * gap / free        (clamped to -1..1)
-- Windowed mode keeps whatever video-align-y was set to before this script changed it.
--
-- Options (script-opts/fullscreen-align.conf):
--   reserve_px  height of the strip kept under the video, in pixels.
--               0 = automatic: what uosc's timeline covers, which is
--               round(timeline_size * scale) + round(timeline_border * scale)
--               with scale = scale_fullscreen * display hidpi scale.

local options = require('mp.options')

local opts = {
    reserve_px = 0,
}
options.read_options(opts, 'fullscreen-align')

-- uosc's own settings, read from script-opts/uosc.conf (defaults match uosc's).
-- Parsed by hand: read_options would warn about every uosc key this script doesn't use.
local uosc = {
    timeline_size = 40,
    timeline_border = 1,
    scale_fullscreen = 1.3,
}
local conf_path = mp.command_native({'expand-path', '~~/script-opts/uosc.conf'})
local conf = io.open(conf_path, 'r')
if conf then
    for line in conf:lines() do
        local key, value = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if key and uosc[key] and tonumber(value) then
            uosc[key] = tonumber(value)
        end
    end
    conf:close()
end

local base_align = mp.get_property_number('video-align-y', 0)
local applied = base_align

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- same rounding as uosc's round()
local function round(v)
    return math.floor(v + 0.5)
end

local function target_align()
    if not mp.get_property_bool('fullscreen') then return base_align end

    local dim = mp.get_property_native('osd-dimensions')
    if not dim then return base_align end
    local free = (dim.mt or 0) + (dim.mb or 0)
    if free <= 0 then return base_align end -- the video already fills the screen

    local gap = opts.reserve_px
    if gap <= 0 then
        -- the strip uosc's timeline covers: Timeline.lua puts its top edge at
        -- display.height - size - top_border, and uosc has no window border in fullscreen
        local scale = mp.get_property_number('display-hidpi-scale', 1) * uosc.scale_fullscreen
        gap = round(uosc.timeline_size * scale) + round(uosc.timeline_border * scale)
    end
    return clamp(1 - 2 * gap / free, -1, 1)
end

local function update()
    local target = target_align()
    -- changing video-align-y moves the margins but not their sum, so this settles at once
    if math.abs(target - applied) < 1e-4 then return end
    applied = target
    mp.set_property_number('video-align-y', target)
end

mp.observe_property('fullscreen', 'bool', update)
mp.observe_property('osd-dimensions', 'native', update)
mp.observe_property('display-hidpi-scale', 'number', update)
