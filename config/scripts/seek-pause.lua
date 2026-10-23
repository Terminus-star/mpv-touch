-- seek-pause: after a seek, hold playback for a short moment, then resume by itself,
-- like YouTube does. Rapid seeks keep extending the hold, so repeated key presses or a
-- drag on the timeline behave like scrubbing and playback resumes once they stop.
--
-- Never touches a video you paused yourself, and drops the hold if you un-pause during it.
-- Option (script-opts/seek-pause.conf): hold_ms, 0 turns the script off.

local options = require('mp.options')

local opts = {
    hold_ms = 250,
}
options.read_options(opts, 'seek-pause')

-- true while this script is the reason playback is paused
local holding = false

local function release()
    if not holding then return end
    -- Clear the flag first: the observer below sees our own un-pause only after this
    -- function returns, and must not take it for the user's.
    holding = false
    mp.set_property_bool('pause', false)
end

local timer = mp.add_timeout(opts.hold_ms / 1000, release)
timer:kill()

mp.register_event('seek', function()
    if opts.hold_ms <= 0 then return end
    if not holding then
        -- already paused by the user (or nothing is playing): leave it alone
        if mp.get_property_bool('pause') or mp.get_property_bool('idle-active') then return end
        holding = true
        mp.set_property_bool('pause', true)
    end
    -- (re)start the countdown, so seeks that arrive close together extend the hold
    timer:kill()
    timer:resume()
end)

-- If the user un-pauses while we are holding, they want playback now: drop the hold so
-- the timer cannot override them later. Our own pause arrives here as pause=true and is ignored.
mp.observe_property('pause', 'bool', function(_, paused)
    if holding and paused == false then
        holding = false
        timer:kill()
    end
end)
