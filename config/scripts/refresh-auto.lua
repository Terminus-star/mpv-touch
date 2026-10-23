-- refresh-auto: switch the display to a refresh rate that fits the video, only while such a video plays.
--
-- 23.976 fps video does not divide into the panel's 180 Hz (7.5 refreshes per frame), so frames are held
-- 7 and 8 refreshes alternately. A fixed 143.856 Hz is 6 refreshes per frame. It talks to
-- scripts/refresh-session.sh (the "arbiter", same design as hdr-session.sh), which keeps a list of
-- programs that want the matched mode, switches for the first one and restores your previous mode when the
-- last one is gone. This script never touches the display itself.
--
--   * Video of about 23.976 fps (container-fps within `tolerance` of `target_fps`) -> acquire.
--   * Any other frame rate, file ends, or mpv quits -> release. A short grace period covers the gap between
--     two such files in a playlist, so the display does not switch back and forth between episodes.
--   * While the display switches (about two seconds) playback is paused if it was running, and resumed
--     afterwards, so no video is shown on the half-switched screen. If you start paused, nothing is touched.
--   * Only with a real window (not --vo=null), so scripts and tests that play headless do not switch.
--
-- If mpv is killed without a chance to release (crash, kill -9), the arbiter's watcher notices the dead
-- process and restores the mode; without the watcher running, restore it by hand with
--   scripts/refresh-session.sh release mpv PID      (or pick the mode again in System Settings)
--
-- Options live in script-opts/refresh-auto.conf, or on the command line as --script-opts=refresh-auto-KEY=VALUE.
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    enabled = true,
    -- the arbiter script
    session_command = '/home/termis/Projects/mpv-touch/scripts/refresh-session.sh',
    -- the name this player registers under (the arbiter adds the process id)
    name = 'mpv',
    -- the frame rate that triggers the switch, and how far from it still counts
    target_fps = 23.976,
    tolerance = 0.02,
    -- only ask when mpv has a real video output; set to no for headless tests
    require_vo = true,
    -- seconds without a matching video before letting go (covers the gap between playlist items)
    release_delay = 4,
    -- pause playback while the display switches, and resume afterwards
    pause_while_switching = true,
}
options.read_options(o, 'refresh-auto')

local held = false
local release_timer = nil
local paused_by_us = false

local function matches(fps)
    return fps ~= nil and math.abs(fps - o.target_fps) <= o.tolerance
end

local function has_window()
    if not o.require_vo then return true end
    local vo = mp.get_property('current-vo')
    return vo ~= nil and vo ~= '' and vo ~= 'null'
end

-- Run the arbiter. At shutdown (at_shutdown = true) it is started DETACHED: mpv cancels any command it is
-- waiting on while quitting (measured for hdr-auto: the release was cut off with status -2), and a detached
-- process keeps running after mpv has gone. on_done runs when an ordinary (not detached) call finishes.
local function session(action, at_shutdown, on_done)
    local args = {o.session_command, action, o.name, tostring(utils.getpid())}
    if at_shutdown then
        mp.command_native({name = 'subprocess', args = args, playback_only = false, detach = true})
    else
        mp.command_native_async({name = 'subprocess', args = args, playback_only = false}, function(ok, res)
            if not ok or (res and res.status ~= 0) then msg.warn(action .. ' failed') end
            if on_done then on_done() end
        end)
    end
end

local function cancel_release_timer()
    if release_timer then
        release_timer:kill()
        release_timer = nil
    end
end

local function resume_if_we_paused()
    if paused_by_us then
        paused_by_us = false
        mp.set_property_bool('pause', false)
    end
end

local function release_now(at_shutdown)
    cancel_release_timer()
    if held then
        held = false
        msg.info('no longer ' .. o.target_fps .. ' fps video: releasing the refresh rate')
        session('release', at_shutdown)
    end
end

-- decide from the current frame rate and output
local function evaluate()
    if not o.enabled then return end
    local fps = mp.get_property_number('container-fps')
    if matches(fps) and has_window() then
        cancel_release_timer()
        if not held then
            held = true
            msg.info(string.format('%.3f fps video: asking for the matched refresh rate', fps))
            -- pause only if playback is running; a player that starts paused is left alone
            if o.pause_while_switching and not mp.get_property_bool('pause') then
                paused_by_us = true
                mp.set_property_bool('pause', true)
            end
            session('acquire', false, resume_if_we_paused)
        end
    elseif held and not release_timer then
        -- not a matching video now (next file has another rate, or the video ended): wait a moment first
        release_timer = mp.add_timeout(o.release_delay, function()
            release_timer = nil
            if not (matches(mp.get_property_number('container-fps')) and has_window()) then
                release_now(false)
            end
        end)
    end
end

-- if the user resumes playback by hand during the switch, leave it running afterwards
mp.observe_property('pause', 'bool', function(_, paused)
    if paused == false then paused_by_us = false end
end)

mp.observe_property('container-fps', 'number', evaluate)
mp.observe_property('current-vo', 'string', evaluate)

mp.register_event('shutdown', function()
    release_now(true)
end)
