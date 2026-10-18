--// Executor Function Watcher --------------------------------------------------
-- Run THIS first, then run whatever script you actually want to inspect. For the
-- next 30 seconds it records every executor function that gets *called* (not what
-- exists - that's ExecutorTest.lua's job), then copies the list of used functions
-- to your clipboard.
--
-- What it watches:
--   1. Every non-vanilla function sitting directly in the executor global env
--      (getgenv) - this catches the whole flat list of exec globals automatically,
--      including custom ones this file has never heard of.
--   2. Every function inside the known executor namespace tables (crypt, cache,
--      debug, Drawing, bit, WebSocket, http, ...), reported with a dotted name
--      like "crypt.encrypt" or "debug.getupvalue".
--
-- game/DataModel stuff (game:GetService, :FireServer, instance methods, ...) is
-- reached through the `game` object and metamethods, not through these functions,
-- so none of it shows up here. Only the executor's own API gets watched.
--
-- Caveat: this hooks the global NAMES / table FIELDS. If the script you're testing
-- caches `local setclipboard = setclipboard` BEFORE this watcher runs, that cached
-- reference bypasses the wrapper. Run this watcher first and you're fine.

local WATCH_SECONDS = 30

-- Clipboard writer, grabbed up front (before any hooking) so our own final copy
-- uses the real function and never counts as a call the watched script made.
local clipboard = setclipboard or set_clipboard or toclipboard or setrbxclipboard
    or set_rbx_clipboard or writeclipboard
    or (syn and syn.write_clipboard)
    or (Clipboard and Clipboard.set)

local genv = (getgenv and getgenv()) or getfenv(0)

-- Standard Lua + Roblox globals we DON'T treat as "executor functions". Every
-- other function-valued global is assumed executor-provided and gets watched.
-- (Library tables - string/table/math/os/coroutine/task/utf8/bit32 - are tables,
-- not functions, so the global sweep skips them automatically.)
local VANILLA = {
    print = true, warn = true, error = true, assert = true, select = true,
    pcall = true, xpcall = true, ypcall = true, type = true, typeof = true,
    tostring = true, tonumber = true, pairs = true, ipairs = true, next = true,
    rawget = true, rawset = true, rawequal = true, rawlen = true, unpack = true,
    setmetatable = true, getmetatable = true, newproxy = true, require = true,
    collectgarbage = true, gcinfo = true,
    wait = true, spawn = true, delay = true, tick = true, time = true,
    elapsedTime = true, DebuggerManager = true, settings = true,
    UserSettings = true, PluginManager = true, version = true, Version = true,
    printidentity = true,
}

-- Executor namespace tables and the member functions worth watching inside each.
-- A table that doesn't exist on this executor, or a member that isn't there, is
-- just skipped - no errors. (Extra top-level members a table might have are still
-- caught if they're also exposed as globals.)
local LIBRARIES = {
    crypt = { "base64_decode", "base64_encode", "base64decode", "base64encode", "decrypt", "encrypt", "generatebytes", "generatekey", "hash", "hmac", "lz4compress", "lz4decompress", "random" },
    cache = { "invalidate", "iscached", "replace" },
    LuaStateProxy = { "new" },
    Drawing = { "clear", "new" },
    Regex = { "Escape", "new" },
    rnet = { "desync", "is_enabled" },
    oth = { "get_original_thread", "get_root_callback", "hook", "is_hook_thread", "unhook" },
    RakNet = { "desync", "is_enabled" },
    Raknet = { "desync", "is_enabled" },
    raknet = { "desync", "is_enabled" },
    Stopwatch = { "new" },
    debug = { "dumpcodesize", "dumpheap", "dumprefs", "getcallstack", "getconstant", "getconstants", "getinfo", "getmemorycategory", "getmetatable", "getproto", "getprotos", "getregistry", "getstack", "getupvalue", "getupvalues", "info", "isvalidlevel", "loadmodule", "profilebegin", "profileend", "resetmemorycategory", "setconstant", "setmemorycategory", "setmetatable", "setstack", "setupvalue", "traceback", "validlevel" },
    bit = { "arshift", "band", "bnot", "bor", "btest", "bxor", "byteswap", "countlz", "countrz", "extract", "lrotate", "lshift", "replace", "rrotate", "rshift" },
    Signal = { "new" },
    Delta = { "architecture", "architecture_str", "get_platform", "is_android", "is_ios", "is_mac", "is_vng", "roblox_version", "version", "version_hash", "version_num" },
    Duration = { "FromDays", "FromHours", "FromMicroseconds", "FromMilliseconds", "FromMinutes", "FromMonths", "FromNanoseconds", "FromSeconds", "FromYears", "TimeSinceEpoch" },
    server = { "has_authority" },
    DeltaSignal = { "new" },
    WebSocket = { "connect" },
    websocket = { "connect" },
    base64 = { "decode", "encode" },
    pibble = { "getpibbles", "gmail", "is_detected", "is_pibble", "washington" },
    http = { "request" },
}

local used = {}       -- display name -> { count, firstOrder }
local order = 0       -- running counter so the report can show call order
local hooks = {}      -- { container, key, original } entries, for restore
local unlocked = {}   -- tables we had to make writable, for re-locking

-- Make a table writable if it's read-only (debug, for example, usually is).
-- Returns true if we actually changed it, so restore can lock it back.
local function tryUnlock(t)
    local ok = pcall(function() return setreadonly and setreadonly(t, false) end)
    if not ok or (isreadonly and pcall(isreadonly, t) and select(2, pcall(isreadonly, t))) then
        pcall(function() if make_writeable then make_writeable(t) elseif makewritable then makewritable(t) end end)
    end
    return true
end

-- Wrap container[key] with a counter, if it's a function. displayName is what
-- shows up in the report.
local function hookField(container, key, displayName)
    if type(container) ~= "table" then return end
    local original = rawget(container, key)
    if original == nil then
        local ok, v = pcall(function() return container[key] end)
        original = ok and v or nil
    end
    if type(original) ~= "function" then return end

    local wrapper = function(...)
        local entry = used[displayName]
        if entry then
            entry.count = entry.count + 1
        else
            order = order + 1
            used[displayName] = { count = 1, firstOrder = order }
        end
        return original(...)
    end

    local ok = pcall(function() container[key] = wrapper end)
    if not ok then
        tryUnlock(container)
        unlocked[container] = true
        ok = pcall(function() container[key] = wrapper end)
    end
    if ok then
        hooks[#hooks + 1] = { container = container, key = key, original = original }
    end
end

-- 1) Every non-vanilla function directly in the global env. Replacing values
--    during a pairs() walk is fine in Luau as long as we don't add/remove keys.
local globalSnapshot = {}
for name, value in pairs(genv) do
    if type(value) == "function" and not VANILLA[name] then
        globalSnapshot[name] = true
    end
end
for name in pairs(globalSnapshot) do
    hookField(genv, name, name)
end

-- 2) Known namespace-table members, reported with dotted names.
for libName, members in pairs(LIBRARIES) do
    local tbl = genv[libName]
    if type(tbl) == "table" then
        for _, member in ipairs(members) do
            hookField(tbl, member, libName .. "." .. member)
        end
    end
end

warn(("[ExecWatcher] Watching %d executor functions for %d seconds - go run your script now."):format(
    #hooks, WATCH_SECONDS))

local function finish()
    -- Put the real functions back and re-lock anything we unlocked.
    for _, h in ipairs(hooks) do
        pcall(function() h.container[h.key] = h.original end)
    end
    for t in pairs(unlocked) do
        pcall(function()
            if setreadonly then setreadonly(t, true)
            elseif make_readonly then make_readonly(t)
            elseif makereadonly then makereadonly(t) end
        end)
    end

    -- Order results by when each function was first called.
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
        warn(ok and "[ExecWatcher] Report copied to clipboard." or "[ExecWatcher] clipboard write failed - report is above.")
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
