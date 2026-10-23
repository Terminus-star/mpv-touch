-- hdr-auto: switch the display into HDR mode only while the video playing is HDR.
--
-- It talks to scripts/hdr-session.sh (the "arbiter"), which keeps a list of programs that want HDR,
-- turns HDR on for the first one and puts the display back as it was when the last one is gone. This
-- script never touches the display itself.
--
--   * HDR video (transfer function pq or hlg, or a Dolby Vision colour matrix) -> acquire HDR.
--   * SDR video, including SDR in a wide BT.2020 container -> nothing happens at all.
--   * File ends, a non-HDR file starts, or mpv quits -> release. A short grace period covers the gap
--     between two HDR files in a playlist, so the display does not flicker between episodes.
--   * Only with a real window (not --vo=null), so scripts and tests that play headless do not switch HDR.
--
-- If mpv is killed without a chance to release (crash, kill -9), the arbiter's watcher notices the dead
-- process and restores the display; without the watcher running, restore it by hand with
--   scripts/hdr-session.sh release mpv PID      (or: kscreen-doctor output.eDP-1.hdr.disable)
--
-- Options live in script-opts/hdr-auto.conf, or on the command line as --script-opts=hdr-auto-KEY=VALUE.
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    enabled = true,
    -- the arbiter script
    session_command = '/home/termis/Projects/mpv-touch/scripts/hdr-session.sh',
    -- the name this player registers under (the arbiter adds the process id)
    name = 'mpv',
    -- only ask for HDR when mpv has a real video output; set to no for headless tests
    require_vo = true,
    -- seconds with no HDR video before letting go (covers the gap between playlist items)
    release_delay = 4,
}
options.read_options(o, 'hdr-auto')

local held = false
local release_timer = nil

local function is_hdr(params)
    if not params then return false end
    return params.gamma == 'pq' or params.gamma == 'hlg' or params.colormatrix == 'dolbyvision'
end

local function has_window()
    if not o.require_vo then return true end
    local vo = mp.get_property('current-vo')
    return vo ~= nil and vo ~= '' and vo ~= 'null'
end

-- Run the arbiter. At shutdown (at_shutdown = true) it is started DETACHED: mpv cancels any command it
-- is waiting on while quitting (measured: the release was killed with status -2 after restoring SDR but
-- before it re-applied the backlight), and a detached process keeps running after mpv has gone.
local function session(action, at_shutdown)
    local args = {o.session_command, action, o.name, tostring(utils.getpid())}
    if at_shutdown then
        mp.command_native({name = 'subprocess', args = args, playback_only = false, detach = true})
    else
        mp.command_native_async({name = 'subprocess', args = args, playback_only = false}, function(ok, res)
            if not ok or (res and res.status ~= 0) then msg.warn(action .. ' failed') end
        end)
    end
end

local function cancel_release_timer()
    if release_timer then
        release_timer:kill()
        release_timer = nil
    end
end

local function release_now(at_shutdown)
    cancel_release_timer()
    if held then
        held = false
        msg.info('HDR video finished: releasing HDR')
        session('release', at_shutdown)
    end
end

-- decide from the current video colour description and output
local function evaluate()
    if not o.enabled then return end
    local params = mp.get_property_native('video-params')
    if is_hdr(params) and has_window() then
        cancel_release_timer()
        if not held then
            held = true
            msg.info('HDR video (' .. tostring(params.gamma) .. ', ' .. tostring(params.colormatrix) .. '): asking for HDR')
            session('acquire', false)
        end
    elseif held and not release_timer then
        -- not HDR now (next file is SDR, or the video ended): wait a moment before giving HDR up
        release_timer = mp.add_timeout(o.release_delay, function()
            release_timer = nil
            local again = mp.get_property_native('video-params')
            if not (is_hdr(again) and has_window()) then
                release_now(false)
            end
        end)
    end
end

mp.observe_property('video-params', 'native', evaluate)
mp.observe_property('current-vo', 'string', evaluate)

mp.register_event('shutdown', function()
    release_now(true)
end)
