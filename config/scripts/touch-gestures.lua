-- touch-gestures 1.1.0 - 2023-Feb-03
-- https://github.com/christoph-heinrich/mpv-touch-gestures
--
-- Touch gestures for mpv
--
-- Modified 2026-10-23 by Seifelden Abdelmonem: the left-half vertical swipe changes the screen brightness
-- instead of the playback speed (backends kde, logind and mpv; options brightness_min and
-- brightness_backend). Licensed under the GNU General Public License version 2, like the original;
-- see LICENSES/GPL-2.0-only.txt and THIRD_PARTY_NOTICES.md.

local assdraw = require('mp.assdraw')
local options = require('mp.options')
local msg = require('mp.msg')
local utils = require('mp.utils')

local opts = {
    horizontal_drag = 'playlist',
    proportional_seek = true,
    seek_scale = 1,
    -- lowest screen brightness the left-side swipe can reach, in percent, so one swipe cannot black out the screen
    brightness_min = 5,
    -- where the brightness comes from: 'auto' (KDE's service if there is one, else the backlight through
    -- systemd-logind), 'kde', 'logind', or 'mpv' (mpv's own picture brightness, works anywhere)
    brightness_backend = 'auto',
}
options.read_options(opts, 'touch-gestures')

if opts.horizontal_drag ~= 'playlist' and opts.horizontal_drag ~= 'seek' then
    msg.error('The option "horizontal_drag" supports the values "playlist" and "seek"')
end

local osd = mp.create_osd_overlay('ass-events')

local uosc = false
local osd_pref = 'osd-auto'

local scale = 1
mp.observe_property('display-hidpi-scale', 'number', function(_, val)
    if val == nil then scale = 1
    else scale = val end
end)

local drag_total = 0
-- ds is short for drag_start
local ds_w = nil
local ds_h = nil
local ds_time = nil
local ds_dur = nil
local ds_vol = nil
local ds_vol_max = nil
local ds_bright = nil
local ds_bright_max = nil

function opacity_to_alpha(opacity)
	return 255 - math.ceil(255 * math.min(opacity, 1))
end

local function render_playlist()
    local ass = assdraw.ass_new()

    local height = 720
    local width = ds_w/ds_h * height

    local vert_pos, rotation
    if drag_total > 0 then
        vert_pos = 0.1
        rotation = 180
    else
        vert_pos = 0.9
        rotation = 0
    end

    local opacity = math.max((math.abs(drag_total) - 80 * scale) / 100, 0)

    ass:pos(width * vert_pos, 360)
    local f = '{\\fnmonospace\\fs200\\bord2\\an6\\frz%d\\alpha&H%X&}\226\158\156'
    ass:append(string.format(f , rotation, opacity_to_alpha(opacity)))

    if osd.res_x == width and osd.data == ass.text then
        return
    end
    osd.res_x = width
    osd.res_y = height
    osd.data = ass.text
    osd.hidden = false
    osd.z = 1000
    osd:update()
end

local function drag_playlist(dx)
    drag_total = drag_total + dx
    render_playlist()
end
local function drag_playlist_end()
    if math.abs(drag_total) < (80 * scale) then return end
    if drag_total > 0 then
        mp.command(uosc and 'script-binding uosc/prev' or 'playlist-prev')
    else
        mp.command(uosc and 'script-binding uosc/next' or 'playlist-next')
    end
end

local time = nil
local function seek(fast)
    if not time then return end
    mp.commandv(osd_pref, 'seek', time, fast and 'absolute+keyframes' or 'absolute+exact')
end
seek_timer = mp.add_timeout(0.05, seek)
seek_timer:kill()
local function drag_seek(dx)
    if not ds_dur then return end
    drag_total = drag_total + dx

    if opts.proportional_seek then
        time = math.max(drag_total / ds_w * ds_dur * opts.seek_scale + ds_time, 0)
    else
        time = math.max(drag_total * opts.seek_scale / scale + ds_time, 0)
    end

    if ds_w / ds_dur < 10 then
        -- Perform a fast seek while moving around and an exact seek afterwards
        seek(true)
        seek_timer:kill()
        seek_timer:resume()
    else
        seek()
    end
    if uosc then mp.commandv('script-binding', 'uosc/flash-timeline') end
end

local function drag_volume(dy)
    drag_total = drag_total + dy
    local vol = math.floor(-drag_total / ds_h * 100 + ds_vol + 0.5)
    mp.commandv(osd_pref, 'set', 'volume', math.max(math.min(vol, ds_vol_max), 0))
    if uosc then mp.commandv('script-binding', 'uosc/flash-volume') end
end

-- Screen brightness. How to change it depends on the desktop, so there are three backends, picked once
-- (option brightness_backend; 'auto' takes the first of kde, logind that works):
--   kde     KDE's own brightness service (org.kde.ScreenBrightness): the same value as KDE's slider. In HDR
--           mode KDE keeps the backlight at full and applies the slider value itself, so on KDE use this one.
--   logind  any systemd desktop: the backlight in /sys/class/backlight, set through systemd-logind's
--           Session.SetBrightness (allowed for the logged-in user, no extra package needed).
--   mpv     mpv's own picture brightness (-100..100): works anywhere, but changes the video, not the screen.
-- A backend is a table: read() -> value, max;  set(value, done) calls done() when it is finished;
-- lowest(max) -> the smallest value a swipe may reach.

local function capture(args)   -- stdout of a command, or nil when it failed
    local res = mp.command_native({name = 'subprocess', args = args, capture_stdout = true, playback_only = false})
    if not res or res.status ~= 0 then return nil end
    return res.stdout
end

local function read_number(path)   -- the first number in a small file, or nil
    local f = io.open(path)
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return tonumber(text:match('%d+'))
end

local function percent_floor(max) return max * opts.brightness_min / 100 end

local function kde_backend()
    local target = {'org.kde.ScreenBrightness', '/org/kde/ScreenBrightness/display0', 'org.kde.ScreenBrightness.Display'}
    local function busctl(verb, ...) return {'busctl', '--user', verb, target[1], target[2], target[3], ...} end
    local function property(name)
        local out = capture(busctl('get-property', name))
        return out and tonumber(out:match('%d+'))
    end
    if not property('MaxBrightness') then return nil end   -- not KDE, or the service is not running
    return {
        name = 'kde',
        read = function() return property('Brightness'), property('MaxBrightness') end,
        set = function(value, done)
            mp.command_native_async({name = 'subprocess', args = busctl('call', 'SetBrightness', 'iu', tostring(value), '0'),
                                     playback_only = false}, function() done() end)
        end,
        lowest = percent_floor,
    }
end

local function logind_backend()
    local dir = '/sys/class/backlight'
    -- the kernel documentation's order of preference when a machine lists several backlights
    local rank = {firmware = 1, platform = 2, raw = 3}
    local best, best_rank
    for _, name in ipairs(utils.readdir(dir, 'all') or {}) do
        local f = io.open(dir .. '/' .. name .. '/type')
        local kind = f and f:read('*l') or ''
        if f then f:close() end
        local r = rank[kind] or 4
        if not best or r < best_rank then best, best_rank = name, r end
    end
    local max = best and read_number(dir .. '/' .. best .. '/max_brightness')
    if not max then return nil end
    return {
        name = 'logind (' .. best .. ')',
        read = function() return read_number(dir .. '/' .. best .. '/brightness'), max end,
        set = function(value, done)
            mp.command_native_async({name = 'subprocess', playback_only = false, args = {
                'busctl', '--system', 'call', 'org.freedesktop.login1', '/org/freedesktop/login1/session/auto',
                'org.freedesktop.login1.Session', 'SetBrightness', 'ssu', 'backlight', best, tostring(value)},
            }, function() done() end)
        end,
        lowest = percent_floor,
    }
end

local function mpv_backend()
    return {
        name = 'mpv picture',
        read = function() return (mp.get_property_number('brightness') or 0) + 100, 200 end,   -- -100..100 as 0..200
        set = function(value, done)
            mp.set_property_number('brightness', value - 100)
            done()
        end,
        lowest = function() return 0 end,   -- a picture setting cannot black out the screen's backlight
    }
end

local backend = nil   -- nil: not looked for yet; false: nothing found
local function get_backend()
    if backend == nil then
        local makers = {kde = kde_backend, logind = logind_backend, mpv = mpv_backend}
        if opts.brightness_backend == 'auto' then
            backend = kde_backend() or logind_backend() or false
        elseif makers[opts.brightness_backend] then
            backend = makers[opts.brightness_backend]() or false
        else
            msg.error('The option "brightness_backend" supports auto, kde, logind and mpv')
            backend = false
        end
        if backend then msg.info('screen brightness backend: ' .. backend.name)
        else msg.warn('no way to control the screen brightness found') end
    end
    return backend or nil
end

-- Dragging produces many events. Only one call is in flight at a time; when it finishes, the newest
-- value that arrived meanwhile is sent, so the screen follows the finger without one process per event.
local bright_busy = false
local bright_pending = nil
local function send_brightness(value)
    if bright_busy then
        bright_pending = value
        return
    end
    bright_busy = true
    backend.set(value, function()
        bright_busy = false
        if bright_pending then
            local next_value = bright_pending
            bright_pending = nil
            send_brightness(next_value)
        end
    end)
end

local function drag_brightness(dy)
    drag_total = drag_total + dy
    -- a swipe over the full height of the window covers the whole range
    local value = -drag_total / ds_h * ds_bright_max + ds_bright
    local lowest = backend.lowest(ds_bright_max)
    value = math.floor(math.max(math.min(value, ds_bright_max), lowest) + 0.5)
    send_brightness(value)
    mp.osd_message(string.format('Brightness: %d%%', math.floor(value / ds_bright_max * 100 + 0.5)), 1)
end

local function drag_init(dx, dy)
    ds_w, ds_h, _ = mp.get_osd_size()
    local vertical = dx * dx < dy * dy
    if vertical then
        local mouse = mp.get_property_native('mouse-pos')
        if mouse.x > ds_w / 2 then
            ds_vol = mp.get_property_number('volume')
            ds_vol_max = mp.get_property_number('volume-max')
            return 'volume'
        else
            local b = get_backend()
            if b then ds_bright, ds_bright_max = b.read() end
            if not (b and ds_bright and ds_bright_max) then
                if not b then mp.osd_message('No screen brightness control found', 2) end
                return 'none'   -- a kind nothing handles, so the rest of this swipe is ignored
            end
            return 'brightness'
        end
    else
        if opts.horizontal_drag == 'playlist' then
            return 'playlist'
        elseif opts.horizontal_drag == 'seek' then
            ds_time = mp.get_property_number('playback-time')
            ds_dur = mp.get_property_number('duration')
            return 'seek'
        end
    end
end

local drag_kind = nil
local function drag(dx, dy)
    if not drag_kind then drag_kind = drag_init(dx, dy) end
    if drag_kind == 'volume' then drag_volume(dy)
    elseif drag_kind == 'brightness' then drag_brightness(dy)
    elseif drag_kind == 'playlist' then drag_playlist(dx)
    elseif drag_kind == 'seek' then drag_seek(dx)
    end
end

local function drag_start()
    drag_total = 0
    drag_kind = nil
end

local function drag_end()
    if drag_kind == 'playlist' then drag_playlist_end() end
    drag_total = 0
    ds_vol = nil
    ds_vol_max = nil
    ds_bright = nil
    ds_bright_max = nil
    ds_time = nil
    ds_dur = nil
    osd.data = ''
    osd.hidden = true
    osd:update()
end

local function double()
    w, _, _ = mp.get_osd_size()
    local mouse = mp.get_property_native('mouse-pos')
    if mouse.x < w / 3  then
        mp.commandv(osd_pref, 'seek', -10, 'relative+exact')
        if uosc then mp.commandv('script-binding', 'uosc/flash-timeline') end
    elseif mouse.x < w * 2 / 3 then
        mp.commandv('cycle', 'fullscreen')
    else
        mp.commandv(osd_pref, 'seek', 10, 'relative+exact')
        if uosc then mp.commandv('script-binding', 'uosc/flash-timeline') end
    end
end

mp.register_script_message('drag', drag)
mp.register_script_message('drag_start', drag_start)
mp.register_script_message('drag_end', drag_end)
mp.register_script_message('double', double)

-- check if uosc is running
mp.register_script_message('uosc-version', function(version)
    version = tonumber((version:gsub('%.', '')))
    ---@diagnostic disable-next-line: cast-local-type
    uosc = version and version >= 400
    if uosc then osd_pref = 'no-osd' end
end)
mp.commandv('script-message-to', 'uosc', 'get-version', mp.get_script_name())
