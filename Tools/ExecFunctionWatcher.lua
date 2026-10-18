--// Executor Function Watcher --------------------------------------------------
-- Run THIS first, then run whatever script you actually want to inspect. For the
-- next 30 seconds it records every executor function that gets *called* (not what
-- exists - that's ExecutorTest.lua's job), then copies the list of used functions
-- to your clipboard.
--
-- Designed to be non-intrusive: it will NOT wrap functions that the executor's
-- own script loader relies on, so your other script still loads and runs normally
-- while the watcher is active. See UNSAFE below for exactly what's left alone and
-- why.
--
-- What it watches:
--   1. Every non-vanilla, safe-to-wrap function in the executor global env
--      (getgenv) - catches the whole flat list of exec globals, custom ones
--      included.
--   2. Safe member functions inside known executor namespace tables (crypt, cache,
--      Drawing, bit, WebSocket, http, ...), reported with dotted names like
--      "crypt.encrypt".
--
-- game/DataModel stuff (game:GetService, :FireServer, instance methods, ...) is
-- reached through the `game` object and metamethods, not these functions, so none
-- of it shows up here.
--
-- Caveat: it hooks the global NAMES / table FIELDS. If the script you're testing
-- caches `local setclipboard = setclipboard` BEFORE this watcher runs, that cached
-- reference bypasses the wrapper. Run this watcher first and you're fine.

local WATCH_SECONDS = 30

-- Capture a few primitives up front, before any hooking, so our own bookkeeping
-- always uses the real functions (and our final clipboard write never counts as a
-- call the watched script made).
local clipboard = setclipboard or set_clipboard or toclipboard or setrbxclipboard
    or set_rbx_clipboard or writeclipboard
    or (syn and syn.write_clipboard)
    or (Clipboard and Clipboard.set)
local mkcclosure = newcclosure  -- keep the original; wrappers are built with it

local genv = (getgenv and getgenv()) or getfenv(0)

-- Standard Lua + Roblox globals we DON'T treat as "executor functions".
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

-- Functions that are NOT safe to wrap. Wrapping any of these is what made the
-- loaded script break: our wrapper adds a Lua/C stack frame and/or changes the
-- function's closure identity, and the executor's loader leans on exactly these:
--   * closure TYPE/identity checks - a wrapper reports as the wrong closure type
--   * stack/thread/identity/env lookups - the extra frame shifts the level they read
--   * the loader/compile + hook primitives themselves - wrapping them breaks loading
--   * the env getters (getgenv/getrenv/...) and the readonly togglers
-- We leave them entirely alone; everything else is fair game.
local UNSAFE = {
    -- closure type / hook-state checks
    iscclosure = true, islclosure = true, iscustomcclosure = true, isnewcclosure = true,
    isexecutorclosure = true, isourclosure = true, is_executor_closure = true,
    is_our_closure = true, is_c_closure = true, is_l_closure = true,
    is_delta_closure = true, isdeltafunction = true, checkclosure = true,
    isfunctionhooked = true, is_function_hooked = true, ishooked = true, isprotohooked = true,
    -- closure creation / cloning
    newcclosure = true, newlclosure = true, clonefunction = true, clonefunc = true,
    cloneref = true, clonereference = true,
    -- hooking / readonly togglers
    hookfunction = true, hookfunc = true, hookmetamethod = true, hookproto = true,
    detour_function = true, detourfunction = true, replaceclosure = true,
    replacefunc = true, replacefunction = true, restoreclosure = true,
    restorefunc = true, restorefunction = true, restoreproto = true,
    make_readonly = true, make_writeable = true, makewritable = true, makereadonly = true,
    setreadonly = true, isreadonly = true, iswritable = true, setstackhidden = true,
    -- stack / thread / identity / env / namecall (all level- or context-sensitive)
    checkcaller = true, checkparallel = true, getcallingscript = true,
    getcallingfunction = true, getfenv = true, setfenv = true, getcallstack = true,
    getthreadidentity = true, get_thread_identity = true, getidentity = true,
    setthreadidentity = true, set_thread_identity = true, setidentity = true,
    getthreadcontext = true, get_thread_context = true, setthreadcontext = true,
    set_thread_context = true, getscriptfromthread = true, getscriptthread = true,
    getnamecallmethod = true, setnamecallmethod = true, getgenv = true, getrenv = true,
    getsenv = true, getmenv = true, getreg = true, getregistry = true, getgc = true,
    filtergc = true, getinfo = true, run_on_actor = true, runonactor = true,
    get_current_actor = true, getcurrentactor = true,
    -- loading / compile / bytecode
    loadstring = true, loadfile = true, dofile = true, getscriptclosure = true,
    getscriptfunction = true, getfunctionbytecode = true, dumpbytecode = true,
    getscriptbytecode = true, dumpstring = true, decompile = true,
    getfunctionhash = true, getscripthash = true,
}

-- Executor namespace tables and the safe member functions to watch inside each.
-- `debug` is deliberately NOT here: it's read-only (force-unlocking it is risky)
-- and its members are stack/upvalue/level sensitive, so wrapping them breaks
-- callers. `oth` (a hooking framework) is left out for the same reason as the
-- hook primitives above. Missing tables/members are skipped silently.
local LIBRARIES = {
    crypt = { "base64_decode", "base64_encode", "base64decode", "base64encode", "decrypt", "encrypt", "generatebytes", "generatekey", "hash", "hmac", "lz4compress", "lz4decompress", "random" },
    cache = { "invalidate", "iscached", "replace" },
    LuaStateProxy = { "new" },
    Drawing = { "clear", "new" },
    Regex = { "Escape", "new" },
    rnet = { "desync", "is_enabled" },
    RakNet = { "desync", "is_enabled" },
    Raknet = { "desync", "is_enabled" },
    raknet = { "desync", "is_enabled" },
    Stopwatch = { "new" },
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

local used = {}     -- display name -> { count, firstOrder }
local order = 0     -- running counter so the report can show call order
local hooks = {}    -- { container, key, original } entries, for restore

-- Build a transparent counting wrapper. Prefer newcclosure so the wrapper stays a
-- C closure (preserves closure-type and caller-identity checks that some exec
-- funcs run internally); fall back to a plain Lua closure if it's unavailable.
local function makeWrapper(original, displayName)
    local body = function(...)
        local entry = used[displayName]
        if entry then
            entry.count = entry.count + 1
        else
            order = order + 1
            used[displayName] = { count = 1, firstOrder = order }
        end
        return original(...)
    end
    if mkcclosure then
        local ok, c = pcall(mkcclosure, body)
        if ok then return c end
    end
    return body
end

-- Wrap container[key] if it's a function. Never force anything: if the table is
-- read-only and the write fails, we just skip it rather than unlock it (unlocking
-- loader tables is exactly the kind of thing that breaks scripts).
local function hookField(container, key, displayName)
    if type(container) ~= "table" then return end
    local original = rawget(container, key)
    if type(original) ~= "function" then return end

    local wrapper = makeWrapper(original, displayName)
    local ok = pcall(function() container[key] = wrapper end)
    if ok and rawget(container, key) == wrapper then
        hooks[#hooks + 1] = { container = container, key = key, original = original }
    end
end

-- 1) Safe non-vanilla functions directly in the global env. Snapshot names first
--    so we're not mutating the table we're iterating.
local names = {}
for name, value in pairs(genv) do
    if type(value) == "function" and not VANILLA[name] and not UNSAFE[name] then
        names[#names + 1] = name
    end
end
for _, name in ipairs(names) do
    hookField(genv, name, name)
end

-- 2) Safe namespace-table members.
for libName, members in pairs(LIBRARIES) do
    local tbl = rawget(genv, libName)
    if type(tbl) == "table" then
        for _, member in ipairs(members) do
            if not UNSAFE[member] then
                hookField(tbl, member, libName .. "." .. member)
            end
        end
    end
end

warn(("[ExecWatcher] Watching %d executor functions for %d seconds - go run your script now."):format(
    #hooks, WATCH_SECONDS))

local function finish()
    -- Put the real functions back, only where our wrapper is still in place (so we
    -- never clobber a hook the watched script installed over us).
    for _, h in ipairs(hooks) do
        pcall(function() h.container[h.key] = h.original end)
    end

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
