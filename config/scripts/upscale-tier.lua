-- upscale-tier: one key cycles named upscaling presets and says which one is active.
--
--   Ctrl+u  ->  light -> balanced -> quality -> off -> light ...   (see input.conf)
--
-- A tier is a combination of shaders, so no single shader name can stand for it; the on-screen
-- message shows the tier name instead of a list of file paths. Playback starts with no tier
-- (whatever glsl-shaders your mpv.conf sets), and the first press gives "light".
--
-- The shaders only do anything when the screen is more than 1.3x the video width, so in a
-- small window a tier can be "on" without changing the picture.
--
--   light     KrigBilateral (chroma) + adaptive-sharpen. Very cheap.
--   balanced  ArtCNN C4F16 (a small neural-network luma doubler) + the two above.
--   quality   ArtCNN C4F32 (about 3.5x the work of C4F16) + KrigBilateral.

local msg = require('mp.msg')

local KRIG = '~~/shaders/KrigBilateral.glsl'
local SHARPEN = '~~/shaders/adaptive-sharpen-anime-1080p.glsl'

local tiers = {
    {name = 'light', shaders = {KRIG, SHARPEN}},
    {name = 'balanced', shaders = {'~~/shaders/ArtCNN_C4F16.glsl', KRIG, SHARPEN}},
    {name = 'quality', shaders = {'~~/shaders/ArtCNN_C4F32.glsl', KRIG}},
    {name = 'off', shaders = {}},
}

local function basename(path)
    return path:match('([^/]+)$') or path
end

-- the file names of the shaders mpv currently has, whichever form mpv reports them in
local function current_names()
    local names = {}
    for _, entry in ipairs(mp.get_property_native('glsl-shaders') or {}) do
        local path = type(entry) == 'table' and entry.filename or entry
        if path and path ~= '' then names[#names + 1] = basename(path) end
    end
    return names
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- which tier the current shaders match, or 0 when none (the first press then gives "light")
local function current_index()
    local have = current_names()
    for i, tier in ipairs(tiers) do
        local want = {}
        for _, path in ipairs(tier.shaders) do want[#want + 1] = basename(path) end
        if i < #tiers and same(have, want) then return i end
    end
    return 0
end

mp.register_script_message('upscale-tier-cycle', function()
    local index = current_index() % #tiers + 1
    local tier = tiers[index]
    mp.set_property('glsl-shaders', table.concat(tier.shaders, ':'))
    mp.osd_message('Upscaling: ' .. tier.name, 2)
    msg.info('upscaling tier: ' .. tier.name)
end)
