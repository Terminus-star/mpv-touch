-- last-session: when mpv is started with no files, reopen the playlist you last had,
-- on the item you were watching. The position inside that item comes from mpv's own resume
-- feature (save-position-on-quit in mpv.conf), so a half-watched video continues where
-- you stopped and a finished one starts again from the beginning.
--
-- Needs idle=once in mpv.conf: without it mpv quits at once when started with no files.
--
-- The playlist (as absolute paths or URLs) and the current index are written to
-- ~~state/last-session.json (~/.local/state/mpv/last-session.json) when mpv shuts down,
-- and now and then while playing, in case mpv is killed. An empty playlist is never written,
-- so quitting an empty window cannot erase the last session. Files that no longer exist
-- are skipped when restoring.
--
-- Option (script-opts/last-session.conf): session_file, to use another file.

local utils = require('mp.utils')
local options = require('mp.options')
local msg = require('mp.msg')

local opts = {
    session_file = '',
}
options.read_options(opts, 'last-session')

local function session_path()
    if opts.session_file ~= '' then
        return mp.command_native({'expand-path', opts.session_file})
    end
    return mp.command_native({'expand-path', '~~state/last-session.json'})
end

local function is_url(path)
    return path:match('^%a[%w+.-]*://') ~= nil
end

-- relative paths would mean something else next time, when mpv is started elsewhere
local function absolute(path)
    if is_url(path) or path:sub(1, 1) == '/' then return path end
    return utils.join_path(utils.getcwd(), path)
end

---------------------------------------------------------------- saving

local items = {}        -- playlist entries as absolute paths / URLs
local index = nil       -- 0-based position of the current entry, last valid one seen
local last_written = nil

mp.observe_property('playlist', 'native', function(_, list)
    items = {}
    for _, entry in ipairs(list or {}) do
        -- '-' is standard input, which cannot be reopened
        if entry.filename ~= '-' then
            items[#items + 1] = absolute(entry.filename)
        end
    end
end)

mp.observe_property('playlist-pos', 'number', function(_, pos)
    -- -1 appears when playback has ended; keep the last real item instead
    if pos and pos >= 0 then index = pos end
end)

local function save()
    if #items == 0 or index == nil then return end
    local text = utils.format_json({items = items, index = index})
    if text == last_written then return end
    local file, err = io.open(session_path(), 'w')
    if not file then
        msg.warn('could not write ' .. session_path() .. ': ' .. tostring(err))
        return
    end
    file:write(text)
    file:close()
    last_written = text
end

mp.register_event('shutdown', save)
mp.add_periodic_timer(30, save)

--------------------------------------------------------------- restoring

local function restore()
    -- started with files: do what was asked, do not replace it
    if mp.get_property_number('playlist-count', 0) > 0 then return end

    local file = io.open(session_path(), 'r')
    if not file then return end
    local session = utils.parse_json(file:read('*a'))
    file:close()
    if type(session) ~= 'table' or type(session.items) ~= 'table' then return end

    local kept, target = {}, nil
    for i, path in ipairs(session.items) do
        if is_url(path) or utils.file_info(path) then
            kept[#kept + 1] = path
            if i - 1 == session.index then target = #kept - 1 end
        end
    end
    if #kept == 0 then return end

    for _, path in ipairs(kept) do
        mp.commandv('loadfile', path, 'append')
    end
    -- the saved item may be gone; fall back to the first one
    mp.set_property_number('playlist-pos', target or 0)
end

restore()
