--// Executor Function Watcher --------------------------------------------------
-- Run THIS first, then run whatever script you actually want to inspect. For the
-- next 30 seconds it records every executor global function that gets *called*
-- (not what exists - that's ExecutorTest.lua's job), then copies the list of
-- used functions to your clipboard.
--
-- How it works: it walks the executor global environment (getgenv) and replaces
-- every function-valued global with a thin wrapper that bumps a counter and then
-- calls the real one. Because game/DataModel stuff (game:GetService, :FireServer,
-- instance methods, etc.) is reached through the `game` object and metamethods -
-- not through global functions - none of that shows up here. Only the executor's
-- own API globals get watched.
--
-- Caveat worth knowing: this hooks the GLOBAL names. If the script you're testing
-- grabs `local setclipboard = setclipboard` BEFORE this watcher runs, that cached
-- reference bypasses the wrapper. Run this watcher first and you're fine, since
-- the script then caches the already-wrapped version.

local WATCH_SECONDS = 30

-- Grab the clipboard writer up front, before we hook anything, so (a) our own
-- final copy uses the real function and (b) it never registers as a call the
-- watched script made.
local clipboard = setclipboard or toclipboard or writeclipboard
    or (syn and syn.write_clipboard)
    or (Clipboard and Clipboard.set)

local genv = (getgenv and getgenv()) or getfenv(0)

-- Standard Lua + Roblox globals we DON'T consider "executor functions". These
-- are the function-valued globals that ship with vanilla Luau/Roblox; everything
-- else that's a function in the global env is treated as executor-provided and
-- gets watched. (Library tables like string/table/math/task/debug/os are tables,
-- not functions, so they're skipped automatically and aren't listed here.)
local VANILLA = {
    -- Lua base
    print = true, warn = true, error = true, assert = true, select = true,
    pcall = true, xpcall = true, ypcall = true, type = true, typeof = true,
    tostring = true, tonumber = true, pairs = true, ipairs = true, next = true,
    rawget = true, rawset = true, rawequal = true, rawlen = true, unpack = true,
    setmetatable = true, getmetatable = true, newproxy = true, require = true,
    collectgarbage = true, gcinfo = true,
    -- Roblox globals
    wait = true, spawn = true, delay = true, tick = true, time = true,
    elapsedTime = true, DebuggerManager = true, settings = true,
    UserSettings = true, PluginManager = true, version = true, Version = true,
    printidentity = true,
}

local used = {}           -- name -> { count = n, firstOrder = k }
local order = 0           -- running counter so the report can show call order
local originals = {}      -- name -> original function (to restore afterwards)
local watchedCount = 0

-- Replacing values during a pairs() walk is fine in Luau as long as we don't add
-- or remove keys, which we don't.
for name, value in pairs(genv) do
    if type(value) == "function" and not VANILLA[name] then
        local original = value
        local fname = name
        originals[fname] = original
        watchedCount = watchedCount + 1

        genv[fname] = function(...)
            local entry = used[fname]
            if entry then
                entry.count = entry.count + 1
            else
                order = order + 1
                used[fname] = { count = 1, firstOrder = order }
            end
            return original(...)
        end
    end
end

warn(("[ExecWatcher] Watching %d executor functions for %d seconds - go run your script now."):format(
    watchedCount, WATCH_SECONDS))

local function finish()
    -- Put the real functions back so the watcher leaves no lasting hooks.
    for name, fn in pairs(originals) do
        genv[name] = fn
    end

    -- Order the results by when each function was first called.
    local lines = {}
    for name, entry in pairs(used) do
        lines[#lines + 1] = { name = name, count = entry.count, order = entry.firstOrder }
    end
    table.sort(lines, function(a, b) return a.order < b.order end)

    local report
    if #lines == 0 then
        report = ("[ExecWatcher] No executor functions were called in %d seconds."):format(WATCH_SECONDS)
    else
        local body = {}
        for i, line in ipairs(lines) do
            body[i] = ("%2d. %s  x%d"):format(i, line.name, line.count)
        end
        report = ("[ExecWatcher] Executor functions called in %d seconds (%d unique):\n%s"):format(
            WATCH_SECONDS, #lines, table.concat(body, "\n"))
    end

    print(report)
    if clipboard then
        local ok = pcall(clipboard, report)
        warn(ok and "[ExecWatcher] Report copied to clipboard." or "[ExecWatcher] setclipboard failed - report is above.")
    else
        warn("[ExecWatcher] No clipboard function on this executor - report is above.")
    end
end

-- task.delay where available, otherwise fall back to the legacy scheduler.
if task and task.delay then
    task.delay(WATCH_SECONDS, finish)
elseif delay then
    delay(WATCH_SECONDS, finish)
else
    coroutine.wrap(function()
        wait(WATCH_SECONDS)
        finish()
    end)()
end
