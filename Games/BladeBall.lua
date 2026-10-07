-- Blade Ball
-- UI: Ui3 (https://github.com/iamdookie1/Ui3). Menu key, accent, DPI and
-- configs (save / load / autoload) live in Ui3's settings panel (gear icon).

task.spawn(function()

-- Bumped on every change, shown in the window footer and the Status tab, so
-- you always know which build you're testing.
local SCRIPT_VERSION = "2026.10.07-29"

-- Only one copy runs. Executing the script again shuts the previous copy down
-- first (otherwise both keep auto parrying, and every pass gets two parries
-- that no fix inside one copy can stop). Every parry also goes through
-- is_live(), so a copy that's been replaced can never send one even if
-- something of it lingers.
local genv = (getgenv and getgenv()) or _G
if type(genv.__BladeBallShutdown) == 'function' then pcall(genv.__BladeBallShutdown) end
local INSTANCE = {}
local LOADED_AT = os.clock()
genv.__BladeBallInstance = INSTANCE
local function is_live() return genv.__BladeBallInstance == INSTANCE end

-- Flight recorder: a timestamped timeline of what this copy did, written to
-- BladeBall/flight.txt as it happens (a fresh file each run). When a kick comes,
-- its message lands in the same file, so the lines right above it show exactly
-- what ran before it. Writing a file is executor-side only; the game can't see it.
local flight
do
    local PATH, t0, started, buf = "BladeBall/flight.txt", os.clock(), false, {}
    flight = function(msg)
        -- getgenv().BladeBallNoLog = true: no file is touched at all.
        if genv.BladeBallNoLog then return end
        pcall(function()
            local line = ("[%9.3f] %s\n"):format(os.clock() - t0, tostring(msg))
            if not started then
                started = true
                if isfolder and makefolder and not isfolder("BladeBall") then makefolder("BladeBall") end
                writefile(PATH, line)
            elseif appendfile then
                appendfile(PATH, line)
            else
                table.insert(buf, line)
                if #buf > 400 then table.remove(buf, 1) end
                writefile(PATH, table.concat(buf))
            end
        end)
    end
end

-- Parry log: every parry this copy sends, where it came from, which pass at you
-- it was for. Spam sources are only counted (they fire hundreds a second).
local ParryLog = {entries = {}, source = nil, spam = 0, total = 0, doubles = 0, describe = nil}
local SPAM_SOURCES = {["manual spam"] = true, ["auto spam"] = true, ["slashes of fury"] = true}
local function log_send(how)
    local src = ParryLog.source or "unknown"
    if SPAM_SOURCES[src] then ParryLog.spam = ParryLog.spam + 1; return end
    ParryLog.total = ParryLog.total + 1
    flight(("send #%d (%s via %s)"):format(ParryLog.total, src, tostring(how)))
    local info = ParryLog.describe and ParryLog.describe() or {}
    local entry = {t = os.clock(), src = src, how = how, pass = info.pass, dist = info.dist, heading = info.heading}
    local last = ParryLog.entries[#ParryLog.entries]
    if entry.pass and last and last.pass == entry.pass then
        entry.double = true
        ParryLog.doubles = ParryLog.doubles + 1
    end
    table.insert(ParryLog.entries, entry)
    if #ParryLog.entries > 8 then table.remove(ParryLog.entries, 1) end
end

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/iamdookie1/Ui3/main/Ui.lua"))()
local Options = Library.Options
local Toggles = Library.Toggles

-- Ui3 autoloads the saved config as each element is created, which runs that
-- element's callback. So the window goes up first (for notifications), and
-- every tab and element is added at the bottom of this file, once everything
-- the callbacks touch exists.
local Window = Library:CreateWindow({
    Title = "Blade Ball",
    Footer = "auto parry  |  v" .. SCRIPT_VERSION,
    Icon = "swords",
    ToggleKeybind = Enum.KeyCode.LeftControl,
    ConfigFolder = "BladeBall",
})

local isMobile = Library.IsMobile
-- Set once the UI is built, so autoloaded toggles don't each fire a notification.
local UIReady = false

local function Notify(t, c, d)
    pcall(function()
        Library:Notify({Title = t or "Blade Ball", Description = c or "", Time = d or 2})
    end)
end

local function NotifyToggle(name, v)
    if UIReady then Notify(name, v and "ON" or "OFF", 1.5) end
end

-- ============================================================
-- CORE SERVICES
-- ============================================================
repeat task.wait(0.5) until game:IsLoaded()

local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService('Players'))
local ReplicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local UserInputService = cloneref(game:GetService('UserInputService'))
local RunService = cloneref(game:GetService('RunService'))
local Stats = cloneref(game:GetService('Stats'))
local Debris = cloneref(game:GetService('Debris'))
local CoreGui = cloneref(game:GetService('CoreGui'))
local HttpService = cloneref(game:GetService('HttpService'))
local Workspace = cloneref(game:GetService('Workspace'))
local VirtualInputManager = cloneref(game:GetService('VirtualInputManager'))
-- Every GUI we make goes in the executor's hidden container, never anywhere the
-- game's own scripts can look (Workspace, characters, PlayerGui).
local HUI = CoreGui
pcall(function() local h = gethui and gethui(); if typeof(h) == 'Instance' then HUI = h end end)

local LocalPlayer = Players.LocalPlayer

if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end

local Alive = Workspace:FindFirstChild("Alive") or Workspace:WaitForChild("Alive")
local Runtime = Workspace:FindFirstChild("Runtime") or Workspace:WaitForChild("Runtime")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Every file this script writes goes under one folder.
local SAVE_FOLDER = "BladeBall"
local function ensureSaveFolder()
    pcall(function()
        if isfolder and makefolder and not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
    end)
end

local function getPing()
    local ok, ping = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
    return ok and ping or 0
end

-- Ping barely moves between frames, but the parry maths reads it several times
-- per ball per frame. Cache it so the hot path does one cheap read instead of a
-- pcall into Stats every time -- keeps the per-frame decision tight.
local ping_cache = {at = -1, ms = 0}
local function pingMs()
    local now = os.clock()
    if now - ping_cache.at > 0.05 then
        ping_cache.ms = getPing()
        ping_cache.at = now
    end
    return ping_cache.ms
end

local function getRoot()
    local char = LocalPlayer.Character
    return char and char.PrimaryPart
end

-- ============================================================
-- PARRY CAPTURE (read-only, then no hooks) -- UNTRACEABLE
-- ============================================================
-- What the game's parry sender (the PRY module under SwordsController) does on
-- every block, from the dump:
--   1. its only client checks, both BEFORE it sends:
--        a. debug.info(debug.info, 's') ~= '[C]'  -- debug.info was hooked
--        b. any function within 10 stack levels runs in an env with writefile
--      Neither kicks locally. Each instead *reports home* over the parry remote
--      with a per-trip random token, and the server acts on the report.
--   2. builds the token from its key function (first function upvalue).
--   3. sends (id, uid, token, window, camera CFrame, {screen points}, {x, y},
--      flag) to that RemoteEvent, as remote:FireServer(...) or a fetched
--      remote.FireServer (50/50).
-- Why earlier builds were still caught: chasing the report token is hopeless
-- (it is random per trip) and suppressing the report treats the symptom. The
-- real trigger is check (b): our auto-parry/prime pressed block through
-- VirtualInputManager, and on executors that run VIM input on the caller's
-- thread that runs the sender SYNCHRONOUSLY ON OUR STACK -- so our
-- writefile-carrying functions sit inside the sender's 10-level getfenv scan and
-- it reports us. We don't hook debug.info, so check (a) never fires.
-- So the design here never lets the sender run on our account at all:
--   * We NEVER press block ourselves. Not to parry, not to "prime".
--   * A thin, READ-ONLY hook over FireServer (both send paths) waits for YOUR
--     own natural block press -- where our code is nowhere near the sender's
--     stack -- reads that one real packet, and then uninstalls for good. It only
--     reads; it never drops or alters a send. A send is taken only when the PRY
--     sender is on the live stack (capture() checks), so our own fireParryRemote
--     is never mistaken for it.
--   * From then on every parry is a direct remote fire that bypasses PRY
--     entirely, so neither check ever runs on our account -- nothing to report,
--     nothing to trace, whatever token BAC rotates to.
-- Keypress mode is the sole exception: it presses block on purpose, which runs
-- the sender, so it is the one mode BAC can see and it is opt-in only.
-- Each closure is a newcclosure and every capture is pcall'd, so nothing of ours
-- can error into the parry.
local Remote = {
    token = nil,        -- the game's key function, read off the sender's upvalues
    remote = nil,       -- the parry RemoteEvent
    args = nil,         -- the real parry packet the game sent
    hooked = false,
}

local hook_wrap = newcclosure or function(f) return f end
-- `installed` is true only while the read-only capture hooks are up: from load
-- until your first natural block is read, then never again.
local Hooks = {installed = false}

-- Cheap test on the raw arguments, before anything is copied: a parry packet is
-- (id, uid, token string, window number, CFrame, {points}, {x, y}, flag).
local function parry_shaped(...)
    local n = select('#', ...)
    if n < 8 or n > 9 then return false end
    local _, _, token, window, cf, points, aim = ...
    return typeof(cf) == 'CFrame' and type(token) == 'string' and type(window) == 'number'
        and type(points) == 'table' and type(aim) == 'table'
end

-- Capture is armed until we have the remote -- there is no timed window. We wait
-- for a NATURAL block press (yours, on the keyboard) to read the real packet; we
-- never press block ourselves, so our writefile-carrying functions are never on
-- the game sender's call stack when its getfenv check runs, and the check never
-- reports us. The moment a packet is read the hooks come down for good (see
-- capture()), so after one block there is nothing left hooked to find.
local function capture_armed()
    return Remote.remote == nil
end

-- The game's PRY sender if it's on the live call stack, else nil. Its chunk is
-- ReplicatedStorage.Controllers."SwordsController ".PRY. A few debug.info reads,
-- no getgc, nothing enumerated.
local function pry_sender()
    for level = 2, 16 do
        local src = debug.info(level, 's')
        if not src then return nil end
        if src:sub(-4) == '.PRY' then return debug.info(level, 'f') end
    end
    return nil
end

-- The key function is the sender's first function upvalue.
local function key_function(sender)
    if type(sender) ~= 'function' then return nil end
    local ok, ups = pcall(debug.getupvalues, sender)
    if not ok or type(ups) ~= 'table' then return nil end
    for _, v in ups do
        if type(v) == 'function' then return v end
    end
    return nil
end

-- The token only changes when the server time ticks over a centisecond, so a
-- burst of parries inside one centisecond (spam) reuses it instead of calling
-- the game's key function and rebuilding the string every time.
local token_cache = {uid = nil, time = nil, out = nil}
-- The key the game's key function gives for (uid, 'TIME'). If it gives the same
-- key three times in a row (different centiseconds), it's fixed per uid, so it's
-- kept and the game's function is never called again: no stream of calls from
-- our thread into the game's code. If it ever varies it's called every time.
local key_cache = {uid = nil, key = nil, same = 0}
local function token_key(remote_uid)
    local kc = key_cache
    if kc.uid == remote_uid and kc.same >= 2 then return kc.key end
    local key = Remote.token(remote_uid, 'TIME')
    if type(key) ~= 'string' or #key == 0 then error("bad key") end
    if kc.uid == remote_uid and kc.key == key then
        kc.same = kc.same + 1
    else
        kc.uid, kc.key, kc.same = remote_uid, key, 0
    end
    return key
end
local function tokenize(remote_uid)
    local time = tostring(math.floor(Workspace:GetServerTimeNow() * 100))
    if token_cache.uid == remote_uid and token_cache.time == time then return token_cache.out end
    local key = token_key(remote_uid)
    local characters = table.create(#time)
    for index = 1, #time do
        characters[index] = string.char(bit32.bxor(
            (string.byte(time, index) + index) % 256,
            string.byte(key, (index - 1) % #key + 1)
        ))
    end
    local out = table.concat(characters)
    token_cache.uid, token_cache.time, token_cache.out = remote_uid, time, out
    return out
end

local function restore_function(fn, old)
    if restorefunction and pcall(restorefunction, fn) then return end
    pcall(hookfunction, fn, old)
end

-- Restores every original and takes the hooks down for good. Called the instant
-- a packet is captured (so nothing stays hooked once we have what we need) and
-- again on unload, so a replaced or disabled copy leaves no trace behind.
local function uninstallRemoteHooks()
    if not Hooks.installed then return end
    Hooks.installed = false -- pass straight through even if a restore fails
    if Hooks.fire_fn and Hooks.old_fire then restore_function(Hooks.fire_fn, Hooks.old_fire) end
    Hooks.fire_fn, Hooks.old_fire = nil, nil
    Remote.hooked = false
end

local function isRemoteEvent(self)
    return typeof(self) == 'Instance' and self.ClassName == 'RemoteEvent'
end

-- Inside the hook. Only a send from the PRY sender counts. If it ever sends more
-- than one parry-shaped packet in a send, the last one (the real send) is kept.
-- Everything else happens once the send has finished.
local function capture(remote, ...)
    local sender = pry_sender()
    if not sender then return end
    Hooks.pending_remote, Hooks.pending_args, Hooks.pending_sender = remote, {...}, sender
    if Hooks.finalizing then return end
    Hooks.finalizing = true
    task.defer(function()
        Hooks.finalizing = false
        local remote_found, args_found, sender_found = Hooks.pending_remote, Hooks.pending_args, Hooks.pending_sender
        Hooks.pending_remote, Hooks.pending_args, Hooks.pending_sender = nil, nil, nil
        if not remote_found then return end
        Remote.token = Remote.token or key_function(sender_found)
        local first = Remote.remote == nil
        Remote.remote, Remote.args = remote_found, args_found
        -- Got the packet from a natural block. Tear the hooks down now -- from
        -- here we fire the remote ourselves and the game's sender (with its
        -- checks) never runs on our account, so there is nothing left to detect.
        uninstallRemoteHooks()
        if first then Notify("Blade Ball", "Parry remote armed. Remote mode is ready (hooks removed).", 3) end
    end)
end

-- The shared FireServer function, read once.
local fire_fn_cache
local function shared_fire_fn()
    if not fire_fn_cache then
        pcall(function() fire_fn_cache = Instance.new('RemoteEvent').FireServer end)
    end
    return fire_fn_cache
end

-- ONE hook, and deliberately only one: hookfunction on the shared FireServer C
-- function. Why not __namecall / __index metamethods, which earlier builds also
-- installed -- that was the bug. BAC's check (b) scans getfenv(1..10) for an
-- executor env from INSIDE the parry sender, right before it sends. A metamethod
-- hook wraps calls all over the game, so our hook closure can sit on the stack as
-- an ANCESTOR of that sender (within the 10 levels) while it scans -- and our env
-- has writefile, so it reports us "a bit after hooking". A plain function hook on
-- FireServer can't: it only ever runs DURING a FireServer call, which is a child
-- of the sender and happens AFTER the scan, so it is never on the stack while the
-- scan runs. The sender always dot-calls v663/v661.FireServer (the same C
-- function we patch) for the full packet, so this still catches a real parry
-- within a block or two. The hook is read-only (never drops/alters a send) and
-- comes down the instant a packet is captured.
local function installRemoteHooks()
    if Hooks.installed then return end
    local fire_fn = hookfunction and shared_fire_fn()
    if fire_fn then
        pcall(function()
            local old_fire
            old_fire = hookfunction(fire_fn, hook_wrap(function(self, ...)
                -- Runs only during an actual FireServer call -> never on the
                -- sender's stack during its getfenv scan. capture() further
                -- confirms the PRY sender is live, so our own fireParryRemote
                -- (which never routes through PRY) is never mistaken for a parry.
                if capture_armed() and isRemoteEvent(self) and parry_shaped(...) then
                    pcall(capture, self, ...)
                end
                return old_fire(self, ...)
            end))
            Hooks.fire_fn, Hooks.old_fire = fire_fn, old_fire
            Remote.hooked = true
        end)
    end
    -- Only count as installed if the hook actually took.
    Hooks.installed = Remote.hooked == true
end

-- Ready once we hold the game's own parry sender (see arm_sender). Sender is
-- defined further down; this only runs at call time, after it exists.
local Sender
local function remoteReady()
    return Sender ~= nil and Sender.fn ~= nil
end

-- Presses block once to get the remote captured; defined further down, once
-- System exists. Declared here so the hook watcher can call it.
local prime_remote

-- "A place where they can parry" — mirrors the game's own client parry gate. A
-- Mirrors the game's OWN parry gate (SwordsController, dump line 225837): the
-- exact conditions under which a block press actually makes the game send a
-- parry. Matching it matters for the capture burst -- we install the hook and
-- press only when a press truly fires the sender, so the hook is never left up
-- for a press the game would swallow. A send is allowed when:
--   * not DoNotParry, and not Stunned (server-set when you can't block), and
--   * not (charging adrenaline with Qi-Charge < 2) -- the game blocks it then,
--   * AND you're somewhere parrying happens: a live round (Workspace.Alive), a
--     lobby parry (LobbyParry attr, but NOT while InLobbyParryCooldown -- a press
--     then sends nothing), or training (Workspace.Dead with LobbyTraining).
local function canParryNow()
    local char = LocalPlayer.Character
    if not char then return false end
    if char:GetAttribute("Stunned") then return false end
    if char:GetAttribute("DoNotParry") then return false end
    if char:GetAttribute("ChargingAdrenaline") then
        local ok, qi = pcall(function() return LocalPlayer.Upgrades["Qi-Charge"].Value end)
        if ok and type(qi) == "number" and qi < 2 then return false end
    end
    if char.Parent == Alive then return true end
    if LocalPlayer:GetAttribute("LobbyParry") then
        -- lobby parry's own cooldown: a press during it is a no-op send
        return not LocalPlayer:GetAttribute("InLobbyParryCooldown")
    end
    if LocalPlayer:GetAttribute("LobbyTraining") then
        local Dead = Workspace:FindFirstChild("Dead")
        if Dead and char.Parent == Dead then return true end
    end
    return false
end

-- Nothing is hooked and no memory is read, ever. Remote mode gets the game's
-- own parry sender with require(PRY) and calls it on a clean thread (see "THE
-- GAME'S OWN SENDER" below). The old hook code further up is never called.

-- Presses the block key via VirtualInputManager, which makes the game run its
-- own PRY sender (and thus send a real parry). Used by Keypress mode every
-- parry, and by the fast capture burst to force the one parry we read the packet
-- from. It can't curve and pays the game's parry cooldown, so Remote mode uses
-- it only to arm, never to parry.
local function pressBlockKey()
    if not is_live() then return end
    log_send("block key")
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)
end

local CollectionService = cloneref(game:GetService('CollectionService'))

-- Screen points sent with a parry, built the way the game's own parry handler
-- builds them: everyone under Alive, or in lobby training the other trainees
-- under Workspace.Dead plus the LobbyTrainingTarget dummies.
-- Also returns `others`: everyone in that list except us, with world and screen
-- position, which is what target mode picks from.
local function build_screen_points(cam)
    local points, others = {}, {}
    local char = LocalPlayer.Character
    local function add(name, pos)
        local screen = cam:WorldToScreenPoint(pos)
        points[name] = screen
        if not (char and name == char.Name) then
            others[#others + 1] = {name = name, pos = pos, screen = screen}
        end
    end
    local dead = Workspace:FindFirstChild('Dead')
    if dead and char and char.Parent == dead and LocalPlayer:GetAttribute('LobbyTraining') then
        for _, other in ipairs(dead:GetChildren()) do
            local plr = Players:GetPlayerFromCharacter(other)
            local hrp = other:FindFirstChild('HumanoidRootPart')
            if plr and hrp and plr:GetAttribute('LobbyTraining') then add(other.Name, hrp.Position) end
        end
        for _, dummy in ipairs(CollectionService:GetTagged('LobbyTrainingTarget')) do
            if dummy:IsA('BasePart') then add(dummy.Name, dummy.Position) end
        end
    else
        for _, entity in ipairs(Alive:GetChildren()) do
            local hrp = entity:FindFirstChild('HumanoidRootPart')
            if hrp then add(entity.Name, hrp.Position) end
        end
    end
    return points, others
end

-- The game sends the mouse position every time (its keyboard/mouse check is
-- always true), so this does too.
local function aim_point(cam)
    local ok, mouse = pcall(UserInputService.GetMouseLocation, UserInputService)
    if ok and mouse then return {mouse.X, mouse.Y} end
    local vp = cam.ViewportSize
    return {vp.X / 2, vp.Y / 2}
end

-- Screen points and aim only change frame to frame, so parries fired in the
-- same frame (spam) share one copy instead of re-projecting every player.
local PACKET_TTL = 1 / 240
local packet_cache = {at = -1, points = nil, aim = nil, others = nil}
local function packet_parts(cam)
    local now = os.clock()
    if now - packet_cache.at > PACKET_TTL then
        packet_cache.points, packet_cache.others = build_screen_points(cam)
        packet_cache.aim = aim_point(cam)
        packet_cache.at = now
    end
    return packet_cache.points, packet_cache.aim, packet_cache.others
end

-- Who the ball gets sent to. Defined further down, once System exists.
local choose_target

-- Spam calls fireParryRemote hundreds of times a second, so the hot path avoids
-- per-call garbage: one shared fire function (no closure per parry), the target
-- aim table built once per frame per target, and the remote's class read once.
local function fire_event(remote, ...) remote:FireServer(...) end
local target_aim = {at = -1, name = nil, aim = nil}

-- ============================================================
-- PARRY WINDOW (packet arg 4) -- computed exactly like the game
-- ============================================================
-- The window is NOT a constant. SwordsController computes it per account on
-- every parry (dump, SwordsController parry handler):
--   n6 = 0.5; timesParried 0/1/2/3/4 -> 1.5/1.25/1.0/0.75/0.625
--   if the noob boost is on (normal servers + FFlag NoobParryEnabled):
--     TotalStats.Kills >= 20 -> boost switches off for good
--     otherwise            -> n6 = kills/20 * n6
-- The server knows your timesParried and kills too, so it knows exactly what
-- window your client is allowed to send. Every hookless build before this sent
-- a hard-coded 0.5 -- on a low-kill account that's claiming a far bigger window
-- than the game would ever send for you. We read the same replicated stats the
-- game reads (Replion "Data", via the same plain require the game's own modules
-- use -- no getgc, no hook) and reproduce its arithmetic exactly.
local Win = {data = nil, noob = false}
task.spawn(function()
    local function srv(info, name)
        local ok, r = pcall(function() return info[name]() end)
        return ok and r == true
    end
    local info, utils
    pcall(function() info = require(ReplicatedStorage:WaitForChild("ServerInfo", 10)) end)
    pcall(function() utils = require(ReplicatedStorage:WaitForChild("Common", 10):WaitForChild("Utils", 10)) end)
    local flag_on = true
    pcall(function() flag_on = utils.FFlag.GetInstantFFlag("NoobParryEnabled", true) end)
    if info then
        Win.noob = flag_on and not srv(info, "isDungeonsMatchServer") and not srv(info, "isRankedMatchServer")
            and not srv(info, "isMedalServer") and not srv(info, "isClanWarServer")
            and not srv(info, "isTournamentMatchServer") and true or false
    end
    task.spawn(function()
        pcall(function()
            local Replion = require(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Replion", 10))
            Win.data = Replion.Client:WaitReplion("Data")
        end)
        Win.done = true
    end)
    -- Never block Remote forever: if the stats can't be read within 10s, give
    -- up waiting and let fireParryRemote use its fallback.
    task.delay(10, function() Win.done = true end)
end)

local function parry_window()
    local data = Win.data
    if not data then return nil end
    local ok_tp, tp = pcall(data.Get, data, "timesParried")
    if not ok_tp or type(tp) ~= 'number' then tp = 0 end
    -- n6 = the window, n2 = the press lockout, fresh = the game's u120 (it plays
    -- the parry swing faster for its first five parries).
    local n6, n2, fresh = 0.5, 1.3, false
    if tp == 0 then n6, n2, fresh = 1.5, 1.5, true
    elseif tp == 1 then n6, n2, fresh = 1.25, 1.3, true
    elseif tp == 2 then n6, n2, fresh = 1, 1.3, true
    elseif tp == 3 then n6, fresh = 0.75, true
    elseif tp == 4 then n6, fresh = 0.625, true end
    if Win.noob then
        local ok_k, kills = pcall(data.Get, data, "TotalStats.Kills")
        if not ok_k or type(kills) ~= 'number' then kills = 0 end
        if kills >= 20 then
            Win.noob = false -- the game turns the boost off for good at 20 kills
        else
            n2 = kills / 20 * n2
            n6 = kills / 20 * n6
        end
    end
    return n6, n2, fresh, tp
end

-- ============================================================
-- THE GAME'S OWN SENDER, CALLED CLEAN -- no getgc, no upvalues, no hook
-- ============================================================
-- SwordsController gets its parry sender with a plain require(script.PRY) and
-- parries by calling it: v31(window, CurrentCamera.CFrame, points, aim, flag)
-- (UseBall2 servers: v31(cameraCF, mouseRayCF, flag)). Requiring a module that
-- is already loaded just hands back the cached function -- the exact sender the
-- game uses, with no memory scan at all. The scan is what got detected: PRY is
-- Luraph-virtualized, so its real checks run inside encrypted bytecode the dump
-- can't show, and v20's log had zero sends yet still kicked standing still.
--
-- And instead of rebuilding the packet we CALL the game's sender, so it builds
-- everything itself: the real token, the real BAC hash, the real arg 2, the
-- real remote. Nothing about the packet can differ from a real parry.
--
-- The sender's only gate is its two checks: debug.info must still be a C
-- function (we never touch it), and no function within 10 stack levels may run
-- in an environment holding writefile. We call it on a fresh thread whose
-- globals (setfenv(0, ...)) and wrapper environment are a clean game
-- environment. Luau reports a C frame's environment (the check's own pcall) as
-- the thread's globals, so every level the check walks comes back clean. Before
-- the first real call, env_is_clean() runs an exact replica of that check on
-- such a thread; if anything there still shows writefile, we never fire.
Sender = {fn = nil, info = "not armed", ball2 = nil, ball2_at = -1} -- forward-declared above remoteReady
-- Only these two leave this block (the main function is near Luau's 200-local cap).
local arm_sender, fireParryRemote
do
local CLEAN_ENV
do
    local ok, renv = pcall(function() return getrenv and getrenv() end)
    if ok and type(renv) == 'table' and renv.writefile == nil then
        CLEAN_ENV = setmetatable({}, {__index = renv})
    else
        CLEAN_ENV = {}
    end
end
-- Everything the clean-thread code touches is captured as an upvalue, so it
-- never needs a global from the clean environment.
local setfenv_, getfenv_, pcall_, spawn_, type_, debug_ = setfenv, getfenv, pcall, task.spawn, type, debug
local tostring_ = tostring
-- Game scripts run at thread identity 2; executor threads run far higher, and a
-- privileged-access probe inside the virtualized sender would see that. Threads
-- copy their parent's identity, so the launcher drops to 2 before spawning.
local setident_ = setthreadidentity or setidentity or set_thread_identity
local getident_ = getthreadidentity or getidentity or get_thread_identity

-- The launcher only prepares the thread: clean globals (setfenv(0)) and identity
-- 2. Then it task.spawns the game's sender, so the sender is the BASE frame of
-- its own new thread -- that thread copies the launcher's globals and identity,
-- and has no function of ours anywhere on its stack, at any level.
local function call_clean(fn, a, b, c, d, e)
    spawn_(function()
        if not pcall_(setfenv_, 0, CLEAN_ENV) then return end
        if setident_ then pcall_(setident_, 2) end
        spawn_(fn, a, b, c, d, e)
    end)
    return true
end

-- Replica of the sender's check, run on a thread built exactly like call_clean's,
-- with a stand-in for the sender as the base frame: anon closure -> pcall (C) ->
-- stand-in. The stand-in gets a clean env like the real sender's game env, and
-- closures it creates inherit it. Also reports what the sender will see: its
-- stack depth (1 = nothing under it) and its thread identity.
local function env_is_clean()
    local res = {done = false, clean = false, info_c = false, depth = -1, ident = "?"}
    local stand_in = function()
        local dirty = false
        for i = 1, 10 do
            local ok, r = pcall_(function() return getfenv_(i) end)
            if ok and type_(r) == 'table' and r.writefile then dirty = true end
        end
        res.clean = not dirty
        local dbg = CLEAN_ENV.debug or debug_
        local okc, isC = pcall_(function() return dbg.info(dbg.info, "s") == "[C]" end)
        res.info_c = okc and isC
        local depth = 1
        while depth < 12 and debug_.info(depth + 1, "f") do depth = depth + 1 end
        res.depth = depth
        if getident_ then
            local oki, id = pcall_(getident_)
            if oki then res.ident = tostring_(id) end
        end
        res.done = true
    end
    if not pcall_(setfenv_, stand_in, CLEAN_ENV) then return false, "setfenv blocked", res end
    call_clean(stand_in) -- task.spawn runs both threads immediately (neither yields)
    if not res.done then return false, "setfenv(0) blocked", res end
    if not res.clean then return false, "a stack level still shows writefile", res end
    if not res.info_c then return false, "debug.info isn't a C function here", res end
    return true, nil, res
end

local function find_pry_module()
    local ctrls = ReplicatedStorage:FindFirstChild("Controllers")
    if not ctrls then return nil end
    for _, c in ipairs(ctrls:GetChildren()) do
        if c.Name:match("^SwordsController") then
            local p = c:FindFirstChild("PRY")
            if p and p:IsA("ModuleScript") then return p end
        end
    end
    return nil
end

-- Arming is spread out, the way the v25 staged run did it. That run is the
-- only one that never got a reason-24 kick (the "X24" in "BAC fhb44X24774"):
-- every build that did all of arming in the first second after load got one
-- about 27s later, with or without parries. So arming waits until ARM_AFTER
-- seconds after load and leaves ARM_GAP seconds between its steps.
-- getgenv().BladeBallStageTest = true stretches the gaps to 75s for testing.
local ARM_AFTER, ARM_GAP = 40, 10
local function stage(n, what)
    local gap = genv.BladeBallStageTest and 75 or ARM_GAP
    flight(("arm step %d done: %s -- next step in %ds"):format(n, what, gap))
    Sender.info = ("arming: step %d of 3 done (%s)"):format(n, what)
    task.wait(gap)
end

arm_sender = function()
    if Sender.fn then return true end
    local wait_for = ARM_AFTER - (os.clock() - LOADED_AT)
    if wait_for > 0 then
        Sender.info = ("arming in %ds (spread out to avoid BAC reason 24)"):format(math.ceil(wait_for))
        flight(("arming waits %.0fs (starts %ds after load)"):format(wait_for, ARM_AFTER))
        task.wait(wait_for)
    end
    local mod = find_pry_module()
    if not mod then Sender.info = "PRY module not loaded yet"; return false end
    stage(1, "found the PRY ModuleScript (reads only)")
    -- A module the game already required comes back from the cache in well under
    -- a millisecond. A long require means the module body ran again (a second
    -- copy of PRY initialising), which is worth knowing if a kick follows.
    local t = os.clock()
    local ok, fn = pcall(require, mod)
    local ms = (os.clock() - t) * 1000
    flight(("require(PRY): %s in %.2f ms"):format(ok and type(fn) or ("error " .. tostring(fn)), ms))
    if not ok or type(fn) ~= 'function' then
        Sender.info = "require(PRY) gave " .. (ok and type(fn) or "an error") .. " -- not firing"
        return false
    end
    stage(2, "require(PRY)")
    CLEAN_ENV.script = mod.Parent -- game envs carry their script; the sender lives in SwordsController
    local clean, why, probe = env_is_clean()
    flight(("clean-thread probe: %s, depth=%s, identity=%s"):format(
        clean and "clean" or tostring(why), tostring(probe.depth), tostring(probe.ident)))
    if not clean then
        Sender.info = "can't make a clean call thread (" .. tostring(why) .. ") -- not firing"
        return false
    end
    stage(3, "clean-thread probe (setfenv / identity 2 on our own threads)")
    -- Nothing reads the sender itself (no debug.info on it): it was only used for
    -- this status text, so it's gone.
    Sender.fn = fn
    Sender.info = ("game sender from %s.PRY, base frame=%s, identity %s, require %.1fms"):format(
        mod.Parent.Name, probe.depth == 1 and "yes" or ("no, depth " .. tostring(probe.depth)), tostring(probe.ident), ms)
    return true
end

local function use_ball2()
    local now = os.clock()
    if Sender.ball2 ~= nil and now - Sender.ball2_at < 2 then return Sender.ball2 end
    local ok, r = pcall(function() return require(ReplicatedStorage.Shared.UseBall2)() end)
    Sender.ball2, Sender.ball2_at = (ok and r == true), now
    return Sender.ball2
end

-- The game's own press gate (SwordsController v50 / OnParrySuccess), copied
-- exactly. A press is ignored while the last one's window is open (u40) or its
-- lockout runs (u38); a landed parry clears both at once, and NoobParryHappened
-- clears everything. So a real client can never send a second parry packet
-- inside the lockout unless the first one landed -- and now neither can we,
-- spam included: every packet we send is one a real client could have sent.
local PG = {active = false, cool = false, recent = false, m1 = false, n1 = 1.3}
pcall(function()
    Remotes.ParrySuccess.OnClientEvent:Connect(function()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        PG.active, PG.cool = false, false
        task.spawn(function()
            PG.recent = true
            task.wait(PG.n1)
            PG.recent = false
        end)
    end)
end)
pcall(function()
    Remotes.NoobParryHappened.OnClientEvent:Connect(function()
        task.wait(0.11)
        PG.cool, PG.recent, PG.active = false, false, false
    end)
end)
pcall(function()
    Remotes.M1Stop.Event:Connect(function(v) PG.m1 = v end)
end)

fireParryRemote = function(curveCF)
    if not is_live() then return true end -- replaced copy: send nothing, and don't fall back to the key
    if not Sender.fn then return false end
    if PG.m1 or PG.active or PG.cool then return true end -- the game ignores this press too
    -- The game reads the window/lockout before sending; wait for the stats once.
    local window, lockout, fresh, tp = parry_window()
    if window == nil then
        if not Win.done then return false end -- stats not read yet: wait, don't guess
        window, lockout, fresh, tp = 0.5, 1.3, false, nil
    end
    -- No animator, no parry (the game returns there too). Stops the parry and
    -- success swings that are playing, exactly as the game does before sending.
    local anim = Sender.anim_pre and Sender.anim_pre()
    if not anim then return true end
    PG.active, PG.cool, PG.n1 = true, true, lockout
    task.delay(window, function()
        PG.active = false
        task.wait(math.max(0.1, lockout - window))
        if not PG.recent then PG.cool = false end
    end)
    local cam = Workspace.CurrentCamera
    local points, aim = packet_parts(cam)
    -- The server gives the ball to whoever's screen point (arg 3 here) is nearest
    -- the aim point (arg 4). For any target mode but Cursor, aim at the chosen
    -- target's own screen point so the server picks exactly them.
    if choose_target then
        local name, _, mode = choose_target(cam)
        local screen = name and points[name]
        if screen and mode ~= "Cursor" then
            if target_aim.at ~= packet_cache.at or target_aim.name ~= name then
                target_aim.at, target_aim.name, target_aim.aim = packet_cache.at, name, {screen.X, screen.Y}
            end
            aim = target_aim.aim
        end
    end
    -- The game passes CurrentCamera.CFrame. Keep the curve's direction but put it
    -- on the camera, so it's a camera CFrame like the game's.
    local cf = cam.CFrame
    if curveCF then
        local origin, look = cf.Position, curveCF.LookVector
        if look == look and look.Magnitude > 0.5 then cf = CFrame.lookAt(origin, origin + look) end
    end
    log_send("remote")
    if use_ball2() then
        -- UseBall2 servers: v31(currentCameraCFrame, mouse-ray CFrame, flag)
        local ray = cam:ScreenPointToRay(aim[1], aim[2], 0)
        call_clean(Sender.fn, cf, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
    else
        -- flag is false: every real parry calls v190() with no argument (not not nil).
        call_clean(Sender.fn, window, cf, points, aim, false)
    end
    -- Then the parry swing, as the game plays it right after sending. The server
    -- sees your character's animations, so every parry packet now comes with the
    -- swing a real block press always plays.
    if Sender.anim_post then pcall(Sender.anim_post, anim, fresh, tp) end
    return true
end
end -- sender block

-- ============================================================
-- SYSTEM
-- ============================================================
local System = {
    __properties = {
        __autoparry_enabled = false, __triggerbot_enabled = false,
        __manual_spam_enabled = false, __play_animation = false,
        __curve_mode = 1, __accuracy = 50, __accuracy_base = 50, __divisor_multiplier = 1.1,
        __random_accuracy = false, __random_accuracy_amount = 10, __frame_dt = 1/60,
        __auto_spam_enabled = false,
        __parried = false, __training_parried = false, __parries = 0,
        __grab_animation = nil, __tornado_time = tick(),
        __connections = {}, __infinity_active = false,
        __deathslash_active = false, __timehole_active = false,
        __slashesoffury_active = false, __slashesoffury_count = 0,
        __is_mobile = isMobile,
        __mobile_guis = {}, __headless_enabled = false, __korblox_enabled = false,
        __ball_velocity_gui = nil, __ball_velocity_enabled = false,
        __peak_velocity = 0, __last_ball_id = nil, __show_ping = false,
        __auto_ability_enabled = false, __cooldown_protection = false,
        __total_parries = 0, __ping_compensation = true, __extra_distance = 0,
        __curve_hotkeys = true, __target_mode = 1
    },
    __config = {
        __curve_names = {'Camera', 'Random', 'Accelerated', 'Backwards', 'Slow', 'High', 'Normal', 'Speed', 'Down', 'Left', 'Right'},
        __target_names = {'Cursor', 'Camera', 'Closest', 'Farthest', 'Random'},
        __detections = {__infinity = false, __deathslash = false, __timehole = false, __slashesoffury = false, __phantom = false}
    },
    __triggerbot = {__enabled = false, __is_parrying = false, __parries = 0, __max_parries = 10000}
}

local function update_divisor()
    System.__properties.__divisor_multiplier = 0.7 + (System.__properties.__accuracy - 1) * (0.9/99)
end
update_divisor()

-- Effective accuracy is the slider value, optionally jittered by a random amount
-- centred on that value. Re-rolled each frame while randomize is on, so the
-- parry window wanders around the chosen accuracy instead of being fixed.
local function roll_accuracy()
    local props = System.__properties
    local acc = props.__accuracy_base
    if props.__random_accuracy and props.__random_accuracy_amount > 0 then
        acc = acc + math.random(-props.__random_accuracy_amount, props.__random_accuracy_amount)
    end
    props.__accuracy = math.clamp(acc, 1, 100)
    update_divisor()
end

-- Animation
-- Mirrors the game's own block action (its parry controller, read from the game
-- source) so remote parries and spam look like real ones:
--   * which tracks: every animation in the sword's animation set tagged Parry or
--     GrabParry, picked by attribute through the game's SwordAPI:GetAnimations
--     (not by child name, which missed sets like Scissors that only have Parry);
--   * how they load: through the game's AnimationController, which copies the
--     Animation's attributes (GrabParry, PlaySpeed, PlayFadeTime, StopFadeTime...)
--     onto the track and keeps one track per animation. The game's own success
--     handler finds what to stop by those attributes, so tracks loaded straight
--     from the Animator were never stopped and the block and success swings played
--     on top of each other (and a fresh track was created on every play);
--   * how they play: stop playing Parry / SuccessParry tracks, then Play with the
--     track's own fade/weight/speed, and record ParryTime on the character;
--   * when: like the game, a new block only starts once the last one landed (our
--     ParrySuccess) or its 1.3s cooldown ran out. Held spam then reads as block,
--     success swing, block, success swing -- what spamming the key in a clash
--     looks like. The success swing itself is played by the game when it lands.
System.animation = {}
do
local SwordAPIFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SwordAPI")
local BLOCK_COOLDOWN = 1.3   -- the game's block lockout when a block doesn't land
local game_api, game_anim, modules_tried
local sword_info_cache = {}  -- sword name -> {collection, sword_type}
local own_tracks = setmetatable({}, {__mode = 'k'}) -- animator -> {[Animation] = track}
local r15_clones = {}        -- Animation -> Animation using its R15Id
local gate = {last = -math.huge, landed = true, landed_at = -math.huge}
local SWING_SHOW = 0.08      -- minimum success swing shown before the next block

-- Any match or training ball currently targeting us. (System.ball is defined
-- further down; this runs at call time, after it exists.)
local function ball_on_us()
    local me = LocalPlayer.Name
    for _, ball in ipairs(System.ball.get_all()) do
        if ball:GetAttribute('target') == me then return true end
    end
    local training = Workspace:FindFirstChild("TrainingBalls")
    if training then
        for _, ball in ipairs(training:GetChildren()) do
            if ball:GetAttribute("realBall") and ball:GetAttribute('target') == me then return true end
        end
    end
    return false
end

local function modules()
    if not modules_tried then
        modules_tried = true
        pcall(function() game_api = require(SwordAPIFolder) end)
        pcall(function() game_anim = require(ReplicatedStorage.Controllers.AnimationController) end)
        if type(game_api) ~= 'table' or type(game_api.GetAnimations) ~= 'function' then game_api = nil end
        if type(game_anim) ~= 'table' or type(game_anim.LoadAnimation) ~= 'function' then game_anim = nil end
    end
    return game_api, game_anim
end

local function current_sword(char)
    if getgenv().skinChangerEnabled then
        return (getgenv().swordAnimations ~= "" and getgenv().swordAnimations)
            or (getgenv().swordModel ~= "" and getgenv().swordModel)
            or char:GetAttribute("CurrentlyEquippedSword")
    end
    return char:GetAttribute("CurrentlyEquippedSword")
end

local function sword_info(name)
    name = name or ""
    local info = sword_info_cache[name]
    if info then return info end
    info = {collection = "Default", sword_type = "Single"}
    if name ~= "" then
        local ok, data = pcall(function()
            return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(name)
        end)
        if ok and type(data) == "table" then
            info.collection = data.AnimationType or info.collection
            info.sword_type = data.SwordType or info.sword_type
        end
    end
    sword_info_cache[name] = info
    return info
end

local function find_animations(char, names, info)
    local api = modules()
    if api then
        local ok, list = pcall(api.GetAnimations, api, char, names, info.collection, info.sword_type)
        if ok and type(list) == "table" and #list > 0 then return list end
    end
    -- Fallback: the same pick by attribute from the set's folder (or Default).
    local collection = SwordAPIFolder:FindFirstChild("Collection")
    local folder = collection and (collection:FindFirstChild(info.collection) or collection:FindFirstChild("Default"))
    local list = {}
    if folder then
        for _, anim in ipairs(folder:GetChildren()) do
            if anim:IsA("Animation") then
                for _, n in ipairs(names) do
                    if anim:GetAttribute(n) then list[#list + 1] = anim; break end
                end
            end
        end
    end
    return list
end

local function load_track(animator, humanoid, anim)
    local _, ctrl = modules()
    if ctrl then
        local ok, track = pcall(ctrl.LoadAnimation, ctrl, animator, anim, true)
        if ok and track then return track end
    end
    -- Fallback, same as the game's loader: one track per animation per
    -- animator, with the Animation's attributes copied onto it.
    local per = own_tracks[animator]
    if not per then per = {}; own_tracks[animator] = per end
    local track = per[anim]
    if track then return track end
    local source = anim
    local r15 = anim:GetAttribute("R15Id")
    if r15 and humanoid.RigType == Enum.HumanoidRigType.R15 then
        source = r15_clones[anim]
        if not source then
            source = Instance.new("Animation")
            source.AnimationId = r15
            r15_clones[anim] = source
        end
    end
    track = animator:LoadAnimation(source)
    for k, v in pairs(anim:GetAttributes()) do pcall(track.SetAttribute, track, k, v) end
    per[anim] = track
    return track
end

local function play_block()
    local char = LocalPlayer.Character
    if not char or char:GetAttribute("InOverdriveMech") then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end
    local now = os.clock()
    if not gate.landed and now - gate.last < BLOCK_COOLDOWN then return end
    -- Let the swing show the way it does in the real game. When our parry lands the
    -- game plays its success swing, and the swing lasts until the next block press
    -- cuts it (the game's block stops success swings) -- there's no fixed delay.
    -- In a clash you press as the ball comes back, so the swing runs while the ball
    -- is with the other player and the next block starts when it's on you again.
    -- Spam fires every few ms, so mirror that: after a landed parry, hold the next
    -- block until a ball is back on us (with a tiny floor so a near-instant return
    -- still shows the strike).
    if gate.landed and gate.landed_at > gate.last then
        if now - gate.landed_at < SWING_SHOW then return end
        -- (If the ball never comes back, give up waiting after the game's lockout.)
        if not ball_on_us() and now - gate.landed_at < BLOCK_COOLDOWN then return end
    end
    local playing = animator:GetPlayingAnimationTracks()
    gate.last, gate.landed = now, false
    for _, track in ipairs(playing) do
        if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then
            track:Stop(track:GetAttribute("StopFadeTime"))
        end
    end
    local parry_time = char:GetAttribute("ParryTime") or 0
    for _, anim in ipairs(find_animations(char, {"Parry", "GrabParry"}, sword_info(current_sword(char)))) do
        local ok, track = pcall(load_track, animator, humanoid, anim)
        if ok and track then
            local speed = track:GetAttribute("PlaySpeed") or 1
            track:Play(track:GetAttribute("PlayFadeTime"), track:GetAttribute("PlayWeight"), speed)
            System.__properties.__grab_animation = track
            local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
            if left > parry_time then parry_time = left end
        end
    end
    pcall(char.SetAttribute, char, "ParryTime", parry_time)
end

-- Our own block landed: the next block can start straight away (the game plays
-- the success swing itself).
pcall(function()
    Remotes.ParrySuccess.OnClientEvent:Connect(function()
        gate.landed, gate.landed_at = true, os.clock()
    end)
end)
LocalPlayer.CharacterAdded:Connect(function()
    gate.last, gate.landed, gate.landed_at = -math.huge, true, -math.huge
end)

-- The swing that goes with every remote parry (fireParryRemote), copied from the
-- game's press handler: before sending, stop the parry/success swings playing;
-- after sending, play the Parry/GrabParry swing (fast for an account's first
-- five parries, the game's u120) and stretch the ParryTime attribute over it.
Sender.anim_pre = function()
    local char = LocalPlayer.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then
            track:Stop(track:GetAttribute("StopFadeTime"))
        end
    end
    return {char = char, humanoid = humanoid, animator = animator}
end
Sender.anim_post = function(a, fresh, tp)
    local char = a.char
    if char:GetAttribute("InOverdriveMech") then return end
    for _, anim in ipairs(find_animations(char, {"Parry", "GrabParry"}, sword_info(current_sword(char)))) do
        local ok, track = pcall(load_track, a.animator, a.humanoid, anim)
        if ok and track then
            local speed = (fresh and tp and tp / 5 + 1) or track:GetAttribute("PlaySpeed") or 1
            local fade = fresh and 0.05 or track:GetAttribute("PlayFadeTime")
            local weight = fresh and 1 or track:GetAttribute("PlayWeight")
            track:Play(fade, weight, speed)
            System.__properties.__grab_animation = track
            local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
            pcall(char.SetAttribute, char, "ParryTime", math.max(char:GetAttribute("ParryTime") or 0, left))
        end
    end
end

-- Every remote parry now plays its own swing (above) and Keypress goes through
-- the game's handler, which plays it -- so the old optional extra swings are off,
-- or each parry would swing twice.
function System.animation.play_grab_parry() end
function System.animation.play_block() end
System.animation.play_grab_parry_full = System.animation.play_block
end -- animation scope

-- Ball
System.ball = {}
function System.ball.get()
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return nil end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then return ball end
    end; return nil
end
function System.ball.get_all()
    local balls_table = {}; local balls = Workspace:FindFirstChild('Balls')
    if not balls then return balls_table end
    for _, ball in pairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') then table.insert(balls_table, ball) end
    end; return balls_table
end

System.player = {}
local Closest_Entity = nil; local last_closest_check = 0
function System.player.get_closest()
    local now = tick()
    if now - last_closest_check < 0.1 then return Closest_Entity end
    last_closest_check = now
    local max_distance = math.huge; local closest_entity = nil
    if not Alive then return nil end
    for _, entity in pairs(Alive:GetChildren()) do
        if entity ~= LocalPlayer.Character and entity.PrimaryPart then
            local distance = LocalPlayer:DistanceFromCharacter(entity.PrimaryPart.Position)
            if distance < max_distance then max_distance = distance; closest_entity = entity end
        end
    end
    Closest_Entity = closest_entity; return closest_entity
end

-- Who the ball gets sent to (Target mode). Picks from the same player list the
-- parry packet sends, so it also works in lobby training against bots:
--   Cursor   -> nearest the mouse on screen (the game's normal behaviour)
--   Camera   -> nearest the middle of the screen
--   Closest  -> physically nearest you
--   Farthest -> physically farthest from you
--   Random   -> a random player
-- Cursor/Camera fall back to the nearest player when nobody's on screen.
-- Returns name, world position, mode. The pick is held for 0.1s so the curve and
-- the packet built for the same parry agree (Random would otherwise differ).
local target_hold = {at = -1, mode = nil, name = nil, pos = nil}
choose_target = function(cam)
    cam = cam or Workspace.CurrentCamera
    local mode = System.__config.__target_names[System.__properties.__target_mode] or "Cursor"
    local now = os.clock()
    if target_hold.mode == mode and now - target_hold.at < 0.1 then
        return target_hold.name, target_hold.pos, mode
    end
    local _, _, others = packet_parts(cam)
    local root = getRoot()
    local origin = root and root.Position or cam.CFrame.Position
    local name, pos
    if others and #others > 0 then
        if mode == "Random" then
            local t = others[math.random(1, #others)]
            name, pos = t.name, t.pos
        elseif mode == "Closest" or mode == "Farthest" then
            local best = (mode == "Closest") and math.huge or -1
            for _, t in ipairs(others) do
                local d = (t.pos - origin).Magnitude
                if (mode == "Closest" and d < best) or (mode == "Farthest" and d > best) then
                    best, name, pos = d, t.name, t.pos
                end
            end
        else
            local vp = cam.ViewportSize
            local anchor = Vector2.new(vp.X / 2, vp.Y / 2)
            if mode == "Cursor" and not isMobile then
                local ok, m = pcall(UserInputService.GetMouseLocation, UserInputService)
                if ok and m then anchor = m end
            end
            local best = math.huge
            for _, t in ipairs(others) do
                local s = t.screen
                if s.Z > 0 and s.X >= 0 and s.Y >= 0 and s.X <= vp.X and s.Y <= vp.Y then
                    local d = (Vector2.new(s.X, s.Y) - anchor).Magnitude
                    if d < best then best, name, pos = d, t.name, t.pos end
                end
            end
            if not name then
                best = math.huge
                for _, t in ipairs(others) do
                    local d = (t.pos - origin).Magnitude
                    if d < best then best, name, pos = d, t.name, t.pos end
                end
            end
        end
    end
    target_hold.at, target_hold.mode, target_hold.name, target_hold.pos = now, mode, name, pos
    return name, pos, mode
end

System.curve = {}
function System.curve.get_cframe()
    local Camera = Workspace.CurrentCamera
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local root_pos = root and root.Position or Camera.CFrame.Position
    local _, chosen_pos = choose_target(Camera)
    local target_pos = chosen_pos or (root_pos + Camera.CFrame.LookVector * 100)
    local Parry_Type = System.__config.__curve_names[System.__properties.__curve_mode]
    local cf
    if Parry_Type == "Camera" then cf = Camera.CFrame
    elseif Parry_Type == "Random" then
        local direction = (target_pos - root_pos).Unit
        local random_offset; local attempts = 0
        repeat
            random_offset = Vector3.new(math.random(-4000,4000), math.random(-4000,4000), math.random(-4000,4000))
            local curve_dir = (target_pos + random_offset - root_pos).Unit
            local dot = direction:Dot(curve_dir); attempts = attempts + 1
        until dot < 0.95 or attempts > 10
        cf = CFrame.new(root_pos, target_pos + random_offset)
    elseif Parry_Type == "Accelerated" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, 5, 0))
    elseif Parry_Type == "Backwards" then
        local direction = (root_pos - target_pos).Unit
        local backwards_pos = root_pos + direction * 10000 + Vector3.new(0, 1000, 0)
        cf = CFrame.new(Camera.CFrame.Position, backwards_pos)
    elseif Parry_Type == "Slow" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, -9e18, 0))
    elseif Parry_Type == "High" then cf = CFrame.new(root_pos, target_pos + Vector3.new(0, 9e18, 0))
    elseif Parry_Type == "Normal" then cf = CFrame.new(root_pos, root_pos + (root and root.CFrame.LookVector or Camera.CFrame.LookVector))
    elseif Parry_Type == "Speed" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.UpVector * 5)
    elseif Parry_Type == "Down" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.UpVector * -9e9)
    elseif Parry_Type == "Left" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position - Camera.CFrame.RightVector * 9e9)
    elseif Parry_Type == "Right" then cf = CFrame.new(Camera.CFrame.Position, Camera.CFrame.Position + Camera.CFrame.RightVector * 9e9)
    else cf = Camera.CFrame end
    return cf
end

-- Same curve for every parry fired in one frame (spam), so the per-player screen
-- projection in get_cframe runs once per frame, not once per parry.
local curve_cache = {at = -1, mode = nil, cf = nil}
function System.curve.get_cframe_fast()
    local now, mode = os.clock(), System.__properties.__curve_mode
    if now - curve_cache.at > PACKET_TTL or curve_cache.mode ~= mode then
        curve_cache.cf = System.curve.get_cframe()
        curve_cache.at, curve_cache.mode = now, mode
    end
    return curve_cache.cf
end

System.parry = {}
-- "Remote" fires the parry remote with the chosen curve -- no key press, so the
-- game's sender never runs for our parries. The remote is armed by a FAST
-- capture burst (prime_remote below) the first time a parry feature is on: the
-- hook is up only for the few frames it takes to grab one packet. "Keypress"
-- presses the block key (VirtualInputManager) every time, so it runs the game's
-- sender constantly and is the one mode BAC watches -- opt-in only.
function System.parry.execute()
    if System.__properties.__parries > 10000 or not LocalPlayer.Character then return end
    if not fireParryRemote(System.curve.get_cframe()) then prime_remote(); return end
    System.__properties.__parries = System.__properties.__parries + 1
    System.__properties.__total_parries = System.__properties.__total_parries + 1
    task.delay(0.5, function()
        if System.__properties.__parries > 0 then System.__properties.__parries = System.__properties.__parries - 1 end
    end)
end
function System.parry.keypress()
    if not LocalPlayer.Character then return end
    pressBlockKey()
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end
-- Light parry for spam: same remote and curve as execute, but reuses the frame's
-- curve/packet and leaves no cleanup thread behind (execute schedules a
-- task.delay per call, which piles up into thousands at spam rates).
function System.parry.fast()
    if not LocalPlayer.Character then return end
    if not fireParryRemote(System.curve.get_cframe_fast()) then prime_remote(); return end
    System.__properties.__total_parries = System.__properties.__total_parries + 1
end

-- Arm Remote mode: get the game's own parry sender with require(PRY) (the cached
-- module value -- no memory scan, no upvalue reads, no hook) and verify a clean
-- call thread can be built (arm_sender). Retries only until the PRY module has
-- loaded, which is normally already true by the time a feature is turned on.
local arming = false
prime_remote = function()
    if remoteReady() or arming or Sender.gave_up then return end
    -- Test switch: getgenv().BladeBallNoArm = true before loading never touches
    -- PRY at all (no require, no probe), so an idle run shows whether arming is
    -- what BAC reacts to.
    if genv.BladeBallNoArm then
        if not Sender.no_arm_logged then Sender.no_arm_logged = true; flight("NO-ARM TEST: PRY never touched") end
        Sender.info = "not armed (BladeBallNoArm test)"
        return
    end
    if getgenv().AutoParryMode == "Keypress" and getgenv().ManualSpamMode == "Keypress" then return end
    arming = true
    task.spawn(function()
        local tries = 0
        while not remoteReady() and not Library.Unloaded and tries < 40 do
            local ok, got = pcall(arm_sender)
            if ok and got then
                Notify("Blade Ball", "Remote armed: " .. tostring(Sender.info), 4)
                flight("ARMED: " .. tostring(Sender.info))
                break
            end
            -- a missing module is worth waiting for; anything else won't fix itself
            if Sender.info ~= "PRY module not loaded yet" then Sender.gave_up = true; break end
            tries = tries + 1
            task.wait(0.5)
        end
        if not remoteReady() then
            Notify("Blade Ball", "Remote not armed: " .. tostring(Sender.info), 8)
            flight("NOT ARMED: " .. tostring(Sender.info))
        end
        arming = false
    end)
end
function System.parry.execute_action() System.animation.play_grab_parry(); System.parry.execute() end
function System.parry.by_mode(mode)
    -- Remote is the default: only an explicit "Keypress" presses the block key.
    if mode == "Keypress" then System.parry.keypress() else System.parry.execute_action() end
end

-- ============================================================
-- DETECTION EVENTS
-- ============================================================
local function isLocal(player)
    return player == LocalPlayer or player == LocalPlayer.Name or (typeof(player) == 'Instance' and player.Name == LocalPlayer.Name)
end

pcall(function()
    Remotes.DeathBall.OnClientEvent:Connect(function(c, d) System.__properties.__deathslash_active = d or false end)
end)
pcall(function()
    Remotes.InfinityBall.OnClientEvent:Connect(function(a, b) System.__properties.__infinity_active = b or false end)
end)

local net
pcall(function() net = ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"].net end)
local function onNet(name, fn)
    pcall(function() net[name].OnClientEvent:Connect(fn) end)
end

onNet("RE/TimeHoleActivate", function(player)
    if isLocal(player) then System.__properties.__timehole_active = true end
end)
onNet("RE/TimeHoleDeactivate", function()
    System.__properties.__timehole_active = false
end)

local maxParryCount = 36; local parryDelay = 0.05
-- One loop at a time, driven locally so it works even if the server is slow to
-- echo SlashesOfFuryParry back. The old loop only started on Catch (which can
-- race ahead of Activate) and relied entirely on the server count, so it often
-- never ran or stopped early. This one starts on either event and keeps its own
-- count as a safety cap.
local slashesLoopRunning = false
local function runSlashesLoop()
    if slashesLoopRunning then return end
    if not System.__config.__detections.__slashesoffury then return end
    if not System.__properties.__slashesoffury_active then return end
    slashesLoopRunning = true
    task.spawn(function()
        local sent = 0
        while System.__properties.__slashesoffury_active
            and System.__config.__detections.__slashesoffury
            and sent < maxParryCount
            and System.__properties.__slashesoffury_count < maxParryCount
            and LocalPlayer.Character do
            ParryLog.source = "slashes of fury"; System.parry.execute(); ParryLog.source = nil
            if System.__properties.__play_animation then
                pcall(System.animation.play_grab_parry)
            end
            sent = sent + 1
            task.wait(parryDelay)
        end
        slashesLoopRunning = false
    end)
end
onNet("RE/SlashesOfFuryActivate", function(player)
    if isLocal(player) then
        System.__properties.__slashesoffury_active = true
        System.__properties.__slashesoffury_count = 0
        runSlashesLoop()
    end
end)
onNet("RE/SlashesOfFuryEnd", function()
    System.__properties.__slashesoffury_active = false
    System.__properties.__slashesoffury_count = 0
    slashesLoopRunning = false
end)
onNet("RE/SlashesOfFuryParry", function()
    System.__properties.__slashesoffury_count = System.__properties.__slashesoffury_count + 1
end)
onNet("RE/SlashesOfFuryCatch", function()
    runSlashesLoop()
end)

Runtime.ChildAdded:Connect(function(Object)
    if not System.__config.__detections.__phantom then return end
    if Object.Name ~= "maxTransmission" and Object.Name ~= "transmissionpart" then return end
    local Weld = Object:FindFirstChildWhichIsA("WeldConstraint")
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not Weld or not root or Weld.Part1 ~= root then return end
    local CurrentBall = System.ball.get(); Weld:Destroy()
    if not CurrentBall then return end
    local FocusConnection
    FocusConnection = RunService.RenderStepped:Connect(function()
        local Highlighted = CurrentBall:GetAttribute("highlighted")
        if Highlighted == true then
            Remotes.AbilityButtonPress:Fire()
            System.__properties.__parried = true
            task.delay(1, function() System.__properties.__parried = false end)
        elseif Highlighted == false then FocusConnection:Disconnect() end
    end)
    task.delay(3, function() if FocusConnection and FocusConnection.Connected then FocusConnection:Disconnect() end end)
end)

Remotes.ParrySuccess.OnClientEvent:Connect(function()
    if not LocalPlayer.Character or LocalPlayer.Character.Parent ~= Alive then return end
    if System.__properties.__grab_animation then System.__properties.__grab_animation:Stop() end
end)

-- ============================================================
-- TRIGGERBOT
-- ============================================================
System.triggerbot = {}

-- One parry per pass, the moment the ball targets you: re-armed only when the
-- ball goes to someone else and comes back. (It used to re-arm every 0.02s, so
-- it kept parrying for as long as the ball stayed on you.)
function System.triggerbot.trigger(ball)
    local state = System.ball_state and System.ball_state(ball)
    if not state or state.pass_parried then return end
    state.pass_parried = true
    System.__triggerbot.__parries = System.__triggerbot.__parries + 1
    ParryLog.source = "triggerbot"
    System.parry.execute()
    ParryLog.source = nil
    if System.__properties.__play_animation then System.animation.play_grab_parry() end
end

function System.triggerbot.loop()
    if not System.__triggerbot.__enabled then return end
    local root = getRoot()
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return end
    local balls = Workspace:FindFirstChild('Balls'); if not balls then return end
    for _, ball in ipairs(balls:GetChildren()) do
        if ball:GetAttribute('realBall') and ball:GetAttribute('target') == LocalPlayer.Name then
            System.triggerbot.trigger(ball)
        end
    end
end

function System.triggerbot.enable(enabled)
    System.__triggerbot.__enabled = enabled
    if enabled then
        if not System.__properties.__connections.__triggerbot then
            System.__properties.__connections.__triggerbot = RunService.PreSimulation:Connect(System.triggerbot.loop)
        end
    else
        if System.__properties.__connections.__triggerbot then
            System.__properties.__connections.__triggerbot:Disconnect()
            System.__properties.__connections.__triggerbot = nil
        end
        System.__triggerbot.__is_parrying = false
        System.__triggerbot.__parries = 0
    end
end

-- ============================================================
-- AUTO PARRY
-- ============================================================
System.autoparry = {}

-- How far away (studs) a ball moving at `speed` gets parried.
function System.parry_distance(speed)
    local props = System.__properties
    -- Capped so a lag spike can't blow the window up to the whole map.
    local ping_ms = math.min(pingMs(), 400)
    local ping_threshold = math.clamp(ping_ms / 100, 5, 17)
    -- Old code capped the speed term at 650, so past ~660 studs/s the window
    -- stopped growing and very fast balls were parried too late (or skipped).
    -- Growth now continues for any speed, just tapering off so it stays sane.
    local speed_diff = math.max(speed - 9.5, 0)
    local speed_divisor = (2.4 + speed_diff * 0.0016) * props.__divisor_multiplier
    local distance = ping_threshold + math.max(speed / speed_divisor, 9.5)
    if props.__ping_compensation then
        -- The parry reaches the server about half a round trip later, and the
        -- ball keeps closing in the meantime.
        distance = distance + speed * (ping_ms / 1000) * 0.5
        -- Never later than the parry can reach the server in time: the server
        -- sees the ball half a ping ahead and gets our parry half a ping late,
        -- so the ball has to be at least a full ping (plus a couple of frames)
        -- out when we fire, whatever the accuracy setting.
        local min_lead = speed * (ping_ms / 1000 + props.__frame_dt * 2)
        if distance < min_lead then distance = min_lead end
    end
    -- High-speed safety: a ball moving fast enough can jump the whole window in
    -- a single frame. Guarantee the window is at least a few frames of travel so
    -- the distance check catches it no matter the frame rate.
    local frame_travel = speed * math.clamp(props.__frame_dt * 3, 1/120, 0.12)
    if frame_travel > distance then distance = frame_travel end
    return distance + props.__extra_distance
end

-- Close range is where a reactive parry loses: the ball comes back from a
-- player next to you faster than a round trip, so by the time "ball is on me"
-- replicates it's already too late. The game's parry stays up for ~0.5s though,
-- so up close auto parry (a) parries the instant the ball retargets you instead
-- of waiting a frame, (b) retries a parry that didn't take after about one round
-- trip instead of a full second, and (c) pre-parries while the ball is on a
-- player standing right next to you, so the parry is already up when it returns.
local APCfg = {
    close_range = 20,       -- studs; instant retarget and pre-parry work inside this
    instant = true,         -- run the decision straight from the target change
    preparry = false,       -- opt-in: parry ahead when a player next to you is about to hit it back
    sim_dt = 1 / 120,       -- anti curve: step size when flying the ball forward
    hit_zone = 4,           -- studs: a ball whose line passes this close to us is coming at us
    hit_radius = 3,         -- studs: the ball has reached us
    parry_window = 0.45,    -- parry once the ball lands within this (+ ping); a bit under the real window
    parry_lasts = 0.5,      -- how long the game keeps a parry up
    landed_hold = 0.75,     -- max wait for the ball to leave us after a parry lands
}

-- One parry at a time, shared by every auto parry path (frame loop, instant
-- retarget, pre-parry, parry-back), mirroring the game's own client rule that
-- you can't parry while one is still up:
--   * nothing fires while our last parry is still up. In our own (client)
--     time that's the game's window plus a full ping: it starts half a ping
--     late on the server, and the server sees the ball half a ping ahead;
--     If the ball was due to land late in that window, we also hold until the
--     success has had time to come back from that landing;
--   * once it lands (ParrySuccess) we stay locked until the ball actually
--     leaves us. The success event usually arrives a moment before the
--     target flips, and that gap used to get a second parry;
--   * the ball leaving us frees the next parry at once.
local ParryCover = {at = 0, busy_until = 0, landed = false, landed_at = 0}
local function parry_up_for()
    return APCfg.parry_lasts + pingMs() / 1000 + 0.03
end
local function parry_busy()
    local now = tick()
    if ParryCover.at > 0 and now < ParryCover.busy_until then return true end
    return ParryCover.landed and now - ParryCover.landed_at < APCfg.landed_hold
end
-- eta: when the ball we're parrying is due to land (nil for a pre-parry).
local function mark_parry(eta)
    local now = tick()
    ParryCover.at, ParryCover.landed = now, false
    ParryCover.busy_until = now + math.max(parry_up_for(), (eta or 0) + pingMs() / 2000 + 0.05)
end
local function parry_landed()
    ParryCover.landed, ParryCover.landed_at = true, tick()
end
local function parry_released()
    ParryCover.at, ParryCover.landed = 0, false
end

-- ------------------------------------------------------------
-- Ball tracking (shared by auto parry and auto spam)
-- ------------------------------------------------------------
-- One record per ball. Its target listener is made once, keeps a short history
-- of who the ball went from/to (what clash detection reads), resets the parry
-- lockout, and hands a retarget onto us straight to auto parry.
local BALL_HISTORY = 16
local ball_state = setmetatable({}, {__mode = 'k'})
local pass_counter = 0
-- A pass starts when the ball comes onto us after being on someone else (or is
-- first seen on us); it ends when someone else gets it. Each gets an id so the
-- parry log can show which pass a parry was for.
local function open_pass(state)
    if state.pass_open then return end
    pass_counter = pass_counter + 1
    state.pass_id, state.pass_open = pass_counter, true
    -- A pre-parry fired while the ball was on its last holder was this pass's parry.
    if state.preparried then state.pass_parried = true end
    state.preparried = false
end
local function get_ball_state(ball)
    local state = ball_state[ball]
    if state then return state end
    state = {parried = false, at = 0, target = ball:GetAttribute('target'), swaps = {}}
    ball_state[ball] = state
    if state.target == LocalPlayer.Name then open_pass(state) end
    ball:GetAttributeChangedSignal('target'):Connect(function()
        local new = ball:GetAttribute('target')
        local swaps = state.swaps
        swaps[#swaps + 1] = {t = os.clock(), from = state.target, to = new}
        if #swaps > BALL_HISTORY then table.remove(swaps, 1) end
        -- The ball left us: our parry landed, so it's used up.
        if state.target == LocalPlayer.Name and new ~= LocalPlayer.Name then parry_released() end
        -- One parry per pass: the lock lifts only when someone else gets the
        -- ball, so the next time it's on us is a new pass. A blank target in
        -- between (me -> "" -> me) is the same pass, not a new one.
        if type(new) == 'string' and new ~= '' and new ~= LocalPlayer.Name then
            state.pass_parried, state.pass_open, state.preparried = false, false, false
        end
        -- A new pass at us: any "parry landed" hold left over is from the last
        -- pass. The success event often arrives after the ball already flipped to
        -- the other player, which left the hold set and blocked this pass's parry
        -- -- why instant retarget did nothing in fast exchanges.
        if new == LocalPlayer.Name and not state.pass_open then ParryCover.landed = false end
        if new == LocalPlayer.Name then open_pass(state) end
        state.target = new
        state.parried = false
        if new == LocalPlayer.Name then
            -- A fresh pass at us.
            state.reached_at = nil
            -- Randomized accuracy: one roll per ball coming at you. Re-rolling
            -- every frame meant the ball crossed whichever frame rolled lowest,
            -- so it always parried early instead of around your setting.
            if System.__properties.__random_accuracy then roll_accuracy() end
        end
        if new == LocalPlayer.Name and System.autoparry.on_retarget then
            System.autoparry.on_retarget(ball)
        end
        if new == LocalPlayer.Name and System.spam_on_retarget then
            System.spam_on_retarget()
        end
    end)
    return state
end
-- For code defined above this (triggerbot) that needs the same per-ball pass lock.
System.ball_state = get_ball_state

-- Match balls plus lobby training balls. Auto parry, auto spam and the parry
-- log all ask every frame, so the list is built once per frame and shared
-- (callers only read it).
local live_balls_cache = {at = -1, list = {}}
local function get_live_balls()
    local now = os.clock()
    if now - live_balls_cache.at < 1 / 240 then return live_balls_cache.list end
    local balls = System.ball.get_all()
    local training = Workspace:FindFirstChild("TrainingBalls")
    if training then
        for _, ball in ipairs(training:GetChildren()) do
            if ball:GetAttribute("realBall") then table.insert(balls, ball) end
        end
    end
    live_balls_cache.list, live_balls_cache.at = balls, now
    return balls
end

-- A player's root by character name, from Alive (round) or Dead (training).
local function character_root(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local char = Alive:FindFirstChild(name)
    if not char then
        local dead = Workspace:FindFirstChild('Dead')
        char = dead and dead:FindFirstChild(name)
    end
    return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
end

local ABILITY_PARRY = {"Raging Deflection", "Rapture", "Calming Deflection", "Aerodynamic Slash", "Fracture", "Death Slash"}
local ABILITY_PROTECT = {"Raging Deflection", "Rapture", "Calming Deflection"}

local function ability_ready()
    local ok, ready = pcall(function()
        return LocalPlayer.PlayerGui.Hotbar.Ability.UIGradient.Offset.Y == 0.5
    end)
    return ok and ready
end

local function has_ability(list)
    local abilities = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Abilities")
    if not abilities then return false end
    for _, name in ipairs(list) do
        local ability = abilities:FindFirstChild(name)
        if ability then
            local ok, enabled = pcall(function() return ability.Enabled end)
            if ok and enabled then return true end
        end
    end
    return false
end

-- Uses the equipped ability in place of a parry when the options allow it.
local function try_ability()
    local props = System.__properties
    if props.__auto_ability_enabled and ability_ready() and has_ability(ABILITY_PARRY) then
        Remotes.AbilityButtonPress:Fire()
        task.delay(2.432, function()
            local ds = Remotes:FindFirstChild("DeathSlashShootActivation")
            if ds then pcall(function() ds:FireServer(true) end) end
        end)
        return true
    end
    if props.__cooldown_protection and ability_ready() and has_ability(ABILITY_PROTECT) then
        Remotes.AbilityButtonPress:Fire()
        return true
    end
    return false
end

local function blocked_by_detection()
    local det, props = System.__config.__detections, System.__properties
    return (det.__infinity and props.__infinity_active)
        or (det.__deathslash and props.__deathslash_active)
        or (det.__timehole and props.__timehole_active)
        or (det.__slashesoffury and props.__slashesoffury_active)
end

local function autoparry_can_run()
    local props = System.__properties
    if not props.__autoparry_enabled or System.__triggerbot.__enabled then return nil end
    local root = getRoot()
    -- canParryNow: alive in the round (or training), not Stunned, no DoNotParry.
    -- Checking only the flags let it keep parrying after you'd been hit and died.
    if not root or root:FindFirstChild('SingularityCape') or not canParryNow() then return nil end
    return root
end

-- ------------------------------------------------------------
-- Parry decision
-- ------------------------------------------------------------
-- Reads the ball as it is right now, without guessing its future path (the
-- turn rate a path guess needs arrives in jumps over the network, so a guess
-- built on it parried early or held until too late):
--   * heading: where it's flying relative to us (1 = straight at us, 0 =
--     sideways, -1 = straight away), and how close its current line passes us;
--   * the accuracy window (parry_distance) for when to parry.
-- Inside the window it parries once the ball is really coming: its line runs
-- through us, or it's heading in at least as straight as the anti curve setting
-- asks. A ball being curved round (bait) is held until it turns in. Never while
-- it's flying away (curving back, or already past us), never once it has
-- already reached us, never a parry that would run out before it gets here.
local function ball_velocity(ball)
    local zoomies = ball:FindFirstChild('zoomies')
    return zoomies and zoomies.VectorVelocity or ball.AssemblyLinearVelocity
end

-- heading, miss (closest its straight line passes us), speed, distance, velocity
local function read_ball(ball, root)
    local velocity = ball_velocity(ball)
    local speed = velocity.Magnitude
    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    if speed < 1 or distance < 0.01 then return 0, math.huge, speed, distance, velocity end
    local heading = (velocity / speed):Dot(offset / distance)
    local miss = heading > 0 and distance * math.sqrt(math.max(0, 1 - heading * heading)) or math.huge
    return heading, miss, speed, distance, velocity
end

-- How fast the ball's flight direction is swinging round (radians/s), read over
-- ~50ms steps and smoothed. A ball homing on us turns at its homing rate; one
-- already flying straight at us reads ~0. Reset each pass.
local function turn_rate(state, velocity, now)
    local speed = velocity.Magnitude
    if speed < 1 then return 0 end
    local dir = velocity / speed
    local s = state.trn
    if not s or s.pass ~= state.pass_id then
        state.trn = {pass = state.pass_id, t = now, dir = dir, w = 0, n = 0}
        return 0
    end
    local dt = now - s.t
    if dt >= 0.05 then
        local w = math.acos(math.clamp(s.dir:Dot(dir), -1, 1)) / dt
        s.w = s.n == 0 and w or (s.w * 0.6 + w * 0.4)
        s.n = s.n + 1
        s.t, s.dir = now, dir
    end
    return s.w
end

-- Anti curve, by prediction instead of a threshold: fly the ball forward the way
-- it really moves -- its velocity swinging toward us at the rate it's been turning,
-- its speed rising at the rate it's been gaining -- and return the seconds until
-- its surface reaches us, or nil if it won't within `horizon`. Bait and wide
-- curves are then timed by where the ball will actually be, not guessed at.
local function predict_contact(ball_pos, velocity, target, gap, turn, accel, horizon)
    local speed = velocity.Magnitude
    if speed < 1 then return nil end
    local step = APCfg.sim_dt
    local pos, dir, t = ball_pos, velocity / speed, 0
    while t < horizon do
        local to = target - pos
        local dist = to.Magnitude
        if dist <= gap then return t end
        local want = to / dist
        local cos = math.clamp(dir:Dot(want), -1, 1)
        local angle = math.acos(cos)
        if angle > 1e-3 and turn > 0 then
            local swing = turn * step
            if swing >= angle then
                dir = want
            else
                local mixed = dir:Lerp(want, swing / angle)
                if mixed.Magnitude < 1e-3 then mixed = dir:Cross(Vector3.yAxis) end
                dir = mixed.Unit
            end
        end
        speed = speed + accel * step
        local move = speed * step
        -- Reaches the contact distance during this step: finish exactly.
        if dir:Dot(want) > 0 and move >= dist - gap then return t + (dist - gap) / speed end
        pos = pos + dir * move
        t = t + step
    end
    return nil
end

-- How far ahead of the ball's arrival (seconds, before ping) a parry may go out.
-- Arrival is now measured to contact (see time_to_contact), so this is the real
-- lead. Fast balls get the full window (parry_distance usually fires them later
-- anyway). Slow ones aim to land ~0.3s into the ~0.5s parry, leaving room on both
-- sides for a curve or a change of pace: 0.45s at 80+ studs/s down to 0.3s at 20.
local function lead_window(speed)
    local slow = math.clamp((80 - speed) / 60, 0, 1)
    return APCfg.parry_window - slow * 0.15
end

-- The ball hits you when its surface reaches you, not when its centre reaches
-- your root: that's its radius plus about half a body further out. On a fast ball
-- the difference is a few milliseconds; on a 15 studs/s ball it's ~0.25s, which
-- is why slow balls landed before the parry went up.
local function contact_gap(ball)
    local ok, size = pcall(function() return ball.Size end)
    if not ok or not size then return 3 end
    return math.max(size.X, size.Y, size.Z) * 0.5 + 1.5
end

-- How fast the ball is gaining speed on its way in (studs/s per second), read
-- over ~80ms steps so replication jitter doesn't swing it. Reset each pass.
local function speed_gain(state, speed, now)
    local s = state.spd
    if not s or s.pass ~= state.pass_id then
        state.spd = {pass = state.pass_id, t = now, v = speed, a = 0}
        return 0
    end
    local dt = now - s.t
    if dt >= 0.08 then
        s.a = s.a * 0.5 + ((speed - s.v) / dt) * 0.5
        s.t, s.v = now, speed
    end
    return math.clamp(s.a, 0, speed * 4)
end

-- Seconds until the ball's surface reaches us along `path`, starting at `speed`
-- and gaining `accel`.
local function time_to_contact(path, ball, speed, accel)
    local gap = math.max(path - contact_gap(ball), 0)
    if accel > 1 then
        return (math.sqrt(speed * speed + 2 * accel * gap) - speed) / accel
    end
    return gap / speed
end

-- When a ball on us makes contact, with anti curve built in: straight in if its
-- line already runs through us, otherwise flown forward along its real homing
-- curve. Returns eta (nil if it won't land within the parry window), the window,
-- and the reading it was based on.
local function ball_contact_eta(ball, root, state, now)
    local heading, miss, speed, distance, velocity = read_ball(ball, root)
    if speed < 1 then return nil, 0, speed, distance, heading end
    local accel = speed_gain(state, speed, now)
    local turn = turn_rate(state, velocity, now)
    local window = lead_window(speed) + math.min(pingMs(), 400) / 1000
    local eta
    if miss <= APCfg.hit_zone then
        eta = time_to_contact(distance, ball, speed, accel)
    else
        eta = predict_contact(ball.Position, velocity, root.Position, contact_gap(ball), turn, accel, window + 0.05)
    end
    return eta, window, speed, distance, heading, accel
end

-- Parry one ball if it's on us and really coming. Leaves the reason in
-- state.why for the Status tab.
local function try_parry_ball(ball, root, now, via)
    local props = System.__properties
    local state = get_ball_state(ball)
    if ball:GetAttribute('target') ~= LocalPlayer.Name then return false end
    local function hold(why) state.why = why; return false end

    -- One parry per pass: already parried this one, locked until the ball goes
    -- to someone else and comes back. Only spam and manual parry more.
    if state.pass_parried then return hold("parried this pass, waiting for next") end
    if props.__parried then return hold("phantom") end
    if parry_busy() then return hold("parry already up") end
    local tornado = Runtime:FindFirstChild('Tornado')
    if tornado and (now - props.__tornado_time) < (tornado:GetAttribute('TornadoTime') or 1) + 0.314159 then return hold("tornado") end
    if ball:FindFirstChild('ComboCounter') then return hold("combo") end
    if blocked_by_detection() then return hold("ability detected") end

    local eta, window, speed, distance, heading, accel = ball_contact_eta(ball, root, state, now)
    if speed < 1 then return hold("ball not moving") end
    local ping_s = math.min(pingMs(), 400) / 1000

    -- Instant retarget (inside close range, straight off the target change).
    -- The ball's velocity still points at its last holder at that moment, so
    -- heading can't be read yet; it parries if the ball is close enough to
    -- land within a parry's window. One parry per pass, so it can't double;
    -- further out it's left to the normal checks a frame later.
    if via == "instant retarget" then
        eta = time_to_contact(distance, ball, speed, accel)
        if eta > window then return hold("too far for instant") end
        state.parried, state.at = true, now
        state.pass_parried = true
        mark_parry(eta)
        ParryLog.source = via
        if try_ability() then log_send("ability") else System.parry.by_mode(getgenv().AutoParryMode) end
        ParryLog.source = nil
        state.why = "parried (instant)"
        return true
    end

    -- Already reached us this pass: it hit, or a parry is landing. Nothing left
    -- to parry; firing here was the "parried after getting hit".
    if distance <= APCfg.hit_radius then state.reached_at = now end
    if state.reached_at and now - state.reached_at < ping_s + 0.3 then return hold("already reached you") end

    -- Anti curve: eta comes from flying the ball forward along its real curve
    -- (ball_contact_eta). No eta means it won't land inside a parry from here --
    -- flying away, or still swinging round (bait) -- so hold until it will.
    if not eta then return hold(heading < 0 and "flying away" or "curving, waiting") end
    -- The accuracy window, on the distance it will really travel to reach us.
    if speed * eta + contact_gap(ball) > System.parry_distance(speed) then return hold("outside window") end
    -- A parry that would run out before the ball gets here is a wasted one.
    if eta > window then return hold("too early") end

    state.parried, state.at = true, now
    state.pass_parried = true
    mark_parry(eta)
    ParryLog.source = via or "auto parry"
    if try_ability() then log_send("ability") else System.parry.by_mode(getgenv().AutoParryMode) end
    ParryLog.source = nil
    state.why = "parried"
    return true
end

-- What the parry log records about the ball on us when a parry goes out.
ParryLog.describe = function()
    local root = getRoot()
    if not root then return {} end
    for _, ball in ipairs(get_live_balls()) do
        if ball:GetAttribute('target') == LocalPlayer.Name then
            local state = get_ball_state(ball)
            local heading, _, _, distance = read_ball(ball, root)
            return {pass = state.pass_id, dist = distance, heading = heading}
        end
    end
    return {}
end

-- Whether a return from a player `gap` studs away is too fast to react to: it
-- covers the gap in under a round trip (plus a couple of frames), so only a
-- parry that's already up can catch it. Slower returns, or ones they curve,
-- are left to the normal timing, which sees the real path; pre-parrying those
-- just runs out before the ball arrives and costs a second parry.
local function return_too_fast(gap, speed)
    local budget = pingMs() / 1000 + System.__properties.__frame_dt * 2 + 0.02
    -- Each hit speeds the ball up a little.
    return gap / math.max(speed * 1.1, 1) <= budget
end

local function preparry_now()
    -- Remote only: a block-key press puts the game's own ~1.3s parry cooldown on
    -- you, so pre-parrying by key would burn it right before the ball arrives.
    if getgenv().AutoParryMode == "Keypress" or not remoteReady() then return false end
    if parry_busy() then return false end
    mark_parry()
    ParryLog.source = "pre-parry"
    System.parry.by_mode(getgenv().AutoParryMode)
    ParryLog.source = nil
    return true
end

-- Ball is on a player standing next to us and about to reach them, and their
-- return would be too fast to react to: put our parry up first. Only when
-- they're about to hit it, and only when reacting can't work, so one return
-- gets one parry.
local function try_preparry(ball, root)
    if not APCfg.preparry then return false end
    local target = ball:GetAttribute('target')
    if not target or target == '' or target == LocalPlayer.Name then return false end
    local their_root = character_root(target)
    if not their_root or (their_root.Position - root.Position).Magnitude > APCfg.close_range then return false end
    if (ball.Position - root.Position).Magnitude > APCfg.close_range * 1.5 then return false end
    local zoomies = ball:FindFirstChild('zoomies')
    local speed = zoomies and zoomies.VectorVelocity.Magnitude or 0
    local their_eta = (ball.Position - their_root.Position).Magnitude / math.max(speed, 1)
    if their_eta > 0.12 + pingMs() / 1000 then return false end
    if not return_too_fast((their_root.Position - root.Position).Magnitude, speed) then return false end
    if blocked_by_detection() then return false end
    if not preparry_now() then return false end
    -- Counts as the parry for this ball's next pass at us, so the real pass
    -- doesn't get a second one on top.
    get_ball_state(ball).preparried = true
    return true
end

function System.autoparry.step()
    local props = System.__properties
    local root = autoparry_can_run()
    if not root then return end

    local now = tick()
    for _, ball in ipairs(get_live_balls()) do
        if ball:FindFirstChild('AeroDynamicSlashVFX') then
            ball.AeroDynamicSlashVFX:Destroy(); props.__tornado_time = now
        end
        if not try_parry_ball(ball, root, now) then
            try_preparry(ball, root)
        end
    end
end

-- Straight from the ball's target change, a frame before the loop would see it.
-- At that moment the ball's velocity still points at its old holder, so heading
-- can't be read; the "instant" branch parries on distance and speed alone. It's
-- used inside close range, and beyond it whenever the ball would still land inside
-- one parry window even if it had to travel twice the straight-line distance (so a
-- curve can't make it arrive after the parry runs out). Anything further gets the
-- normal heading-aware check right away, which holds until the ball turns in.
function System.autoparry.on_retarget(ball)
    if not APCfg.instant then return end
    local root = autoparry_can_run()
    if not root then return end
    local distance = (root.Position - ball.Position).Magnitude
    local speed = ball_velocity(ball).Magnitude
    local window = lead_window(speed) + math.min(pingMs(), 400) / 1000
    local instant = distance <= APCfg.close_range
        or (speed > 1 and 2 * distance / speed <= window)
    pcall(try_parry_ball, ball, root, tick(), instant and "instant retarget" or "retarget")
end

-- Our own parry landed: stay locked until the ball actually leaves us. Only while
-- a ball is still on us -- if it already flipped away there's nothing to hold for.
Remotes.ParrySuccess.OnClientEvent:Connect(function()
    for _, ball in ipairs(get_live_balls()) do
        if ball:GetAttribute('target') == LocalPlayer.Name then parry_landed(); return end
    end
end)

Remotes.ParrySuccessAll.OnClientEvent:Connect(function()
    if System.__properties.__grab_animation then pcall(function() System.__properties.__grab_animation:Stop() end) end
end)

function System.autoparry.start()
    if System.__properties.__connections.__autoparry then return end
    local last_error
    System.__properties.__connections.__autoparry = RunService.PreSimulation:Connect(function(dt)
        if dt then System.__properties.__frame_dt = dt end
        local ok, err = pcall(System.autoparry.step)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] auto parry: " .. tostring(err))
        end
    end)
end

function System.autoparry.stop()
    if System.__properties.__connections.__autoparry then
        System.__properties.__connections.__autoparry:Disconnect()
        System.__properties.__connections.__autoparry = nil
    end
end

-- ============================================================
-- SPAM ENGINE (MANUAL + AUTO)
-- ============================================================
-- One engine drives both. It ticks at three points of every frame
-- (PreSimulation, Heartbeat, PreRender) so parries are spread through the frame
-- instead of dumped at one point, starts a burst on the very first tick, and
-- uses System.parry.fast, which reuses the frame's curve/packet/token.
System.manual_spam = {}
System.auto_spam = {}
local macroAnimFix = false
local ManualSpam = {rate = 300}     -- parries per second
-- Auto spam fires only when one reactive parry can't keep up: a clash (the ball
-- going back and forth with one player faster than you could react) or a ball
-- landing on you faster than that. There are no range / hits / window settings
-- any more: each is worked out from the ball's speed, the gap between players
-- and your ping, so it adapts to slow and fast balls on its own.
local AutoSpam = {
    rate = 250,
    react_margin = 0.03,    -- seconds on top of ping (a couple of frames) a reactive parry needs
    active_until = 0,
    reason = nil,
}
-- One parry per send point (four per frame). Parries sent at the same instant
-- reach the server in the same frame and only the first counts; the rest just
-- fill your upload, and once it's full your character's movement queues behind
-- them -- the "I'm ahead of where I really am" desync.
local SPAM_MAX_PER_TICK = 1
local SpamNet = {
    idle_rate = 20,       -- parries/s while no ball is on or near you
    budget_kbps = 350,    -- keep upload under this (Roblox is comfortable to ~400)
    guard_at = -1,        -- upload guard: last check
    factor = 1,           -- upload guard: current rate multiplier
}

function System.manual_spam.start() System.__properties.__manual_spam_enabled = true end
function System.manual_spam.stop() System.__properties.__manual_spam_enabled = false end

local function spam_fire(manual)
    if getgenv().ManualSpamMode == "Keypress" then
        System.parry.keypress()
    else
        System.parry.fast()
        if getgenv().ManualSpamAnimationFix and macroAnimFix then
            -- Played the way the game plays a held block key: a block swing, then
            -- (once it lands) the game's success swing, then the next block. It
            -- no longer depends on auto parry's animation setting being on.
            System.animation.play_block()
        end
    end
end

-- The ball's recent owners, newest first: one entry per change of hands, with
-- blank targets dropped (the game can clear the target between owners) and
-- repeats collapsed. t is when that player got the ball.
local function ball_owners(state)
    local owners = {}
    for i = #state.swaps, 1, -1 do
        local s = state.swaps[i]
        if type(s.to) == 'string' and s.to ~= '' then
            local last = owners[#owners]
            if last and last.name == s.to then
                last.t = s.t
            else
                owners[#owners + 1] = {name = s.to, t = s.t}
            end
        end
    end
    return owners
end

-- A clash is the ball going back and forth between you and one player. Counts
-- the hand-offs between the two of you in one unbroken run; how close they must
-- be, how quick each hand-off and how many are needed all come from the ball's
-- speed and your ping (see detect_clash). Only real hand-offs count: one parry
-- is one hit, never two.
-- How fast a return has to be before one reactive parry can't keep up.
local function reaction_budget()
    return math.min(pingMs(), 400) / 1000 + AutoSpam.react_margin
end

local function detect_clash(ball, root, now)
    local owners = ball_owners(get_ball_state(ball))
    local newest, second = owners[1], owners[2]
    if not second then return nil end
    local me = LocalPlayer.Name
    local opponent
    if newest.name == me then opponent = second.name
    elseif second.name == me then opponent = newest.name
    else return nil end -- ball isn't with you or them right now

    local their_root = character_root(opponent)
    if not their_root then return nil end
    local gap = (their_root.Position - root.Position).Magnitude
    local speed = math.max(ball_velocity(ball).Magnitude, 1)
    local budget = reaction_budget()
    -- Clash range, worked out: close enough that the two of you are trading the
    -- ball, wider for faster balls (a 300+ studs/s exchange spans more ground).
    local range = math.clamp(18 + speed * 0.06, 18, 45)
    if gap > range then return nil end
    -- The ball has to be in the exchange, not flying in from someone else.
    if (ball.Position - root.Position).Magnitude > gap + 12 then return nil end
    -- Clash tempo, worked out: in a clash each hand-off comes about as fast as the
    -- ball can cross between you plus both reactions. A slow rally (long holds,
    -- curves) breaks the run and is left to auto parry.
    local cross = gap / speed
    local tempo = math.clamp(cross * 2 + budget * 2 + 0.15, 0.3, 0.75)
    if now - newest.t > tempo then return nil end

    local hits = 0
    for i = 1, #owners - 1 do
        local cur, prev = owners[i], owners[i + 1]
        local alternates = (cur.name == me and prev.name == opponent) or (cur.name == opponent and prev.name == me)
        if not alternates or cur.t - prev.t > tempo then break end
        hits = hits + 1
    end
    -- Clash hits, worked out: right up close one quick hand-off is enough;
    -- otherwise wait for the ball to come back once so a single pass with a
    -- nearby player doesn't start spam.
    local need = (gap <= 10 or cross <= budget) and 1 or 2
    if hits < need then return nil end
    return ("clash vs %s (%d hits)"):format(opponent, hits)
end

-- Ball on you, heading in, and landing faster than a reactive parry can answer,
-- with auto parry not having got a parry out for this pass: spam to save it.
-- Point-blank range is worked out from speed and ping, not set.
local function detect_point_blank(ball, root)
    if ball:GetAttribute('target') ~= LocalPlayer.Name then return nil end
    if get_ball_state(ball).pass_parried then return nil end
    local offset = root.Position - ball.Position
    local distance = offset.Magnitude
    local velocity = ball_velocity(ball)
    local speed = velocity.Magnitude
    if speed < 1 then return nil end
    if distance > 1 and velocity:Dot(offset / distance) <= speed * 0.5 then return nil end
    if distance / speed > reaction_budget() then return nil end
    return "point blank"
end

-- Lobby training or lobby parry: auto spam never runs there.
local function in_training()
    if LocalPlayer:GetAttribute("LobbyTraining") or LocalPlayer:GetAttribute("LobbyParry") then return true end
    local char, dead = LocalPlayer.Character, Workspace:FindFirstChild("Dead")
    return char ~= nil and dead ~= nil and char.Parent == dead
end

-- Once per frame: decide whether auto spam should be firing.
local function auto_spam_evaluate()
    if not System.__properties.__auto_spam_enabled then
        AutoSpam.active_until, AutoSpam.reason = 0, nil
        return
    end
    local now = os.clock()
    local root = getRoot()
    if root and not root:FindFirstChild('SingularityCape') and canParryNow() and not blocked_by_detection()
        and not in_training() then
        for _, ball in ipairs(get_live_balls()) do
            local reason = detect_clash(ball, root, now) or detect_point_blank(ball, root)
            if reason then
                -- Keep going a couple of reaction times past the last detection.
                AutoSpam.active_until = now + math.clamp(reaction_budget() * 2, 0.1, 0.35)
                AutoSpam.reason = reason
                return
            end
        end
    end
    if now >= AutoSpam.active_until then AutoSpam.reason = nil end
end

function System.auto_spam.status()
    if not System.__properties.__auto_spam_enabled then return "off" end
    if os.clock() < AutoSpam.active_until then return "SPAMMING (" .. tostring(AutoSpam.reason or "clash") .. ")" end
    return "watching for clashes"
end

-- Measures the parries spam really sent per second (shown next to the rate
-- slider), over a half-second window so it reads steadily.
local SpamMeter = {count = 0, since = os.clock(), rate = 0}
function System.spam_actual_rate() return SpamMeter.rate end

-- A ball on us, or close enough to reach us within about a reaction time (in a
-- clash that's the whole exchange). That's when every parry counts; the rest of
-- the time a low keep-alive rate is all spam needs, and the saved upload keeps
-- your movement in sync.
local function spam_focus()
    local root = getRoot()
    if not root then return false end
    local me = LocalPlayer.Name
    local horizon = reaction_budget() + 0.25
    for _, ball in ipairs(get_live_balls()) do
        get_ball_state(ball) -- makes sure its retarget listener exists (instant fire)
        if ball:GetAttribute('target') == me then return true end
        local speed = ball_velocity(ball).Magnitude
        if speed > 1 and (ball.Position - root.Position).Magnitude / speed <= horizon then return true end
    end
    return false
end

-- Upload guard: reads the client's real send rate and eases spam down while it's
-- over budget, back up once it's clear -- as fast as your connection allows
-- without flooding it.
local function bandwidth_factor(now)
    if now - SpamNet.guard_at < 0.25 then return SpamNet.factor end
    SpamNet.guard_at = now
    local ok, kbps = pcall(function() return Stats.DataSendKbps end)
    if ok and type(kbps) == 'number' and kbps > 0 then
        local step = math.clamp(SpamNet.budget_kbps / kbps, 0.6, 1.15)
        SpamNet.factor = math.clamp(SpamNet.factor * step, 0.25, 1)
    end
    return SpamNet.factor
end

local spam_acc, spam_last, spam_active = 0, os.clock(), false
local function spam_tick()
    local now = os.clock()
    local elapsed = math.min(now - spam_last, 0.1)
    spam_last = now
    local span = now - SpamMeter.since
    if span >= 0.5 then
        SpamMeter.rate = SpamMeter.count / span
        SpamMeter.count, SpamMeter.since = 0, now
    end
    local props = System.__properties
    local rate, source
    if props.__manual_spam_enabled then
        rate, source = ManualSpam.rate, "manual spam"
    elseif props.__auto_spam_enabled and now < AutoSpam.active_until then
        rate, source = AutoSpam.rate, "auto spam"
    end
    if not rate or not LocalPlayer.Character then
        spam_acc, spam_active = 0, false
        return
    end
    if not spam_focus() then rate = math.min(rate, SpamNet.idle_rate) end
    rate = rate * bandwidth_factor(now)
    local interval = 1 / math.max(rate, 1)
    if spam_active then
        spam_acc = spam_acc + elapsed
    else
        -- First tick of a burst fires right away instead of waiting an interval.
        spam_acc, spam_active = interval, true
    end
    local fires = math.min(math.floor(spam_acc / interval), SPAM_MAX_PER_TICK)
    if fires > 0 then
        spam_acc = spam_acc - fires * interval
        ParryLog.source = source
        local manual = source == "manual spam"
        for _ = 1, fires do spam_fire(manual) end
        ParryLog.source = nil
        SpamMeter.count = SpamMeter.count + fires
    end
    -- Don't try to make up a big backlog after a frame hitch; a burst of stale
    -- parries all at once does nothing useful.
    if spam_acc > interval * 4 then spam_acc = 0 end
end

-- The two moments a fresh parry matters most in a clash: our parry just landed
-- (the ball is on its way back), and the ball has just flipped back to us. Fire
-- one straight away from the event itself instead of waiting for the next tick --
-- faster where it counts, for a single packet.
local function spam_instant()
    local props = System.__properties
    local manual = props.__manual_spam_enabled
    if not (manual or (props.__auto_spam_enabled and os.clock() < AutoSpam.active_until)) then return end
    if not LocalPlayer.Character then return end
    ParryLog.source = manual and "manual spam" or "auto spam"
    spam_fire(manual)
    ParryLog.source = nil
    SpamMeter.count = SpamMeter.count + 1
end
Remotes.ParrySuccess.OnClientEvent:Connect(function() pcall(spam_instant) end)
System.spam_on_retarget = function() pcall(spam_instant) end

do
    local last_error
    local function run(fn)
        local ok, err = pcall(fn)
        if not ok and err ~= last_error then
            last_error = err
            warn("[Blade Ball] spam: " .. tostring(err))
        end
    end
    local conns = System.__properties.__connections
    conns.__spam_pre = RunService.PreSimulation:Connect(function()
        run(auto_spam_evaluate)
        run(spam_tick)
    end)
    conns.__spam_heartbeat = RunService.Heartbeat:Connect(function() run(spam_tick) end)
    -- Four points per frame (render, animation, simulation, heartbeat) so a
    -- frame's parries go out spread across it instead of in two or three clumps.
    pcall(function()
        conns.__spam_render = RunService.PreRender:Connect(function() run(spam_tick) end)
    end)
    pcall(function()
        conns.__spam_anim = RunService.PreAnimation:Connect(function() run(spam_tick) end)
    end)
end

-- ============================================================
-- HEADLESS & KORBLOX
-- ============================================================
local Byte_Library = {}
function Byte_Library.Korblox(char)
    if not char then return end
    local leg = char:FindFirstChild("Right Leg"); if not leg then return end
    if not leg:FindFirstChild("KorbloxMesh") then
        for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
        local m = Instance.new("SpecialMesh"); m.Name = "KorbloxMesh"
        m.MeshId = "rbxassetid://902942096"; m.TextureId = "rbxassetid://902843398"
        m.Offset = Vector3.new(0, 0.7, 0); m.Parent = leg
    end
end
function Byte_Library.Restore_Leg(char)
    if not char then return end
    local leg = char:FindFirstChild("Right Leg"); if not leg then return end
    for _, v in leg:GetChildren() do if v:IsA("SpecialMesh") then v:Destroy() end end
end
function Byte_Library.Headless(char)
    if not char then return end
    local head = char:FindFirstChild("Head"); if not head then return end
    head.Transparency = 1
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = 1
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            if not child:GetAttribute("OriginalScale") then
                child:SetAttribute("OriginalScale", child.Scale); child.Scale = Vector3.new(0, 0, 0)
            end
        end
    end
end
function Byte_Library.Restore_Head(char)
    if not char then return end
    local head = char:FindFirstChild("Head"); if not head then return end
    head.Transparency = 0
    for _, child in head:GetChildren() do
        if child:IsA("Decal") or child.Name == "face" then child.Transparency = 0
        elseif child:IsA("SpecialMesh") or child:IsA("DataModelMesh") then
            local orig = child:GetAttribute("OriginalScale")
            if orig then child.Scale = orig; child:SetAttribute("OriginalScale", nil) end
        end
    end
end
local function ApplyHeadlessKorblox()
    local char = LocalPlayer.Character; if not char then return end
    if System.__properties.__headless_enabled then Byte_Library.Headless(char) end
    if System.__properties.__korblox_enabled then Byte_Library.Korblox(char) end
end
LocalPlayer.CharacterAdded:Connect(function(char) task.wait(0.5); ApplyHeadlessKorblox() end)


-- ============================================================
-- MOBILE BUTTONS
-- ============================================================
local function create_mobile_button(name, position_y, color, x_pos)
    local gui = Instance.new('ScreenGui')
    gui.Name = 'BladeBall_' .. name .. '_Mobile'; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 9998; gui.Parent = HUI
    local button = Instance.new('TextButton')
    button.Size = UDim2.new(0, 130, 0, 55)
    button.Position = UDim2.new(x_pos or 0.15, 0, position_y, 0)
    button.BackgroundTransparency = 1; button.AnchorPoint = Vector2.new(0.5, 0)
    button.Draggable = true; button.AutoButtonColor = false; button.ZIndex = 2
    local bg = Instance.new('Frame'); bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(40, 40, 40); bg.Parent = button
    Instance.new('UICorner', bg).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new('UIStroke', bg); stroke.Color = color
    stroke.Thickness = 2; stroke.Transparency = 0.3
    local text = Instance.new('TextLabel')
    text.Size = UDim2.new(1, 0, 1, 0); text.BackgroundTransparency = 1; text.Text = name
    text.Font = Enum.Font.GothamBold; text.TextSize = 17
    text.TextColor3 = Color3.fromRGB(255, 255, 255); text.ZIndex = 3; text.Parent = button
    button.Parent = gui
    return {gui = gui, button = button, text = text, bg = bg}
end

local function destroy_mobile_gui(gui_data) if gui_data and gui_data.gui then gui_data.gui:Destroy() end end


-- ============================================================
-- SKIN CHANGER
-- ============================================================
local SKIN_SAVE_FILE = SAVE_FOLDER .. "/skin.json"

local function loadSkinSave()
    local data = {}
    pcall(function()
        if isfile and isfile(SKIN_SAVE_FILE) then
            local decoded = HttpService:JSONDecode(readfile(SKIN_SAVE_FILE))
            if type(decoded) == "table" then data = decoded end
        end
    end)
    return data
end

local function saveSkinData()
    ensureSaveFolder()
    pcall(function()
        if writefile then
            writefile(SKIN_SAVE_FILE, HttpService:JSONEncode({swordModel = getgenv().swordModel or ""}))
        end
    end)
end

getgenv().saveLastEquippedSword = saveSkinData
local savedSkin = loadSkinSave()
getgenv().skinChanger = false
getgenv().skinChangerEnabled = false
getgenv().swordModel = savedSkin.swordModel or ""
getgenv().swordAnimations = savedSkin.swordModel or ""
getgenv().swordFX = savedSkin.swordModel or ""
getgenv().slashName = "SlashEffect"

task.spawn(function()
    -- Wait until the user actually enables skin changer before doing any
    -- getconnections calls — those loops were causing kicks while standing still.
    while not getgenv().skinChangerEnabled do task.wait(1) end

    local rs = game:GetService("ReplicatedStorage")
    local swordInstancesInstance = rs:WaitForChild("Shared", 9e9):WaitForChild("ReplicatedInstances", 9e9):WaitForChild("Swords", 9e9)
    local swordInstances = require(swordInstancesInstance)
    local swordsController
    task.spawn(function()
        while task.wait(0.25) and not swordsController do
            local ok, conns = pcall(getconnections, rs.Remotes.FireSwordInfo.OnClientEvent)
            if ok and conns then
                for _, v in ipairs(conns) do
                    if v.Function and islclosure and islclosure(v.Function) then
                        local ok2, up = pcall(getupvalues, v.Function)
                        if ok2 and #up == 1 and type(up[1]) == "table" then swordsController = up[1]; break end
                    end
                end
            end
        end
    end)
    local function getSlashName(swordName)
        local ok, sln = pcall(function() return swordInstances:GetSword(swordName) end)
        return (ok and sln and sln.SlashName) or "SlashEffect"
    end
    local function refreshSlashName()
        local fxName = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
        if fxName ~= "" then getgenv().slashName = getSlashName(fxName)
        else getgenv().slashName = "SlashEffect" end
    end
    refreshSlashName()
    local function setSword()
        if not getgenv().skinChanger then return end
        if not LocalPlayer.Character then return end
        pcall(function()
            local f = rawget(swordInstances, "EquipSwordTo")
            if type(f) == "function" then
                local ups = getupvalues(f)
                for i = 1, #ups do if type(ups[i]) == "boolean" then setupvalue(f, i, false); break end end
            end
        end)
        pcall(function() swordInstances:EquipSwordTo(LocalPlayer.Character, getgenv().swordModel) end)
        task.spawn(function()
            local attempts = 0
            while not swordsController and attempts < 20 do task.wait(0.5); attempts = attempts + 1 end
            if not swordsController then return end
            pcall(function()
                if swordsController.SetSword then
                    swordsController:SetSword(getgenv().swordAnimations ~= "" and getgenv().swordAnimations or getgenv().swordModel)
                end
            end)
            pcall(function()
                local targetSword = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
                if rs.Remotes:FindFirstChild("FireSwordInfo") then rs.Remotes.FireSwordInfo:FireServer(targetSword) end
                if swordsController.currentSword ~= nil then pcall(function() swordsController.currentSword = targetSword end) end
                if swordsController.SwordFX ~= nil then pcall(function() swordsController.SwordFX = targetSword end) end
            end)
        end)
    end
    -- ========================================================================
    -- SKIN RENDERING -- resolver remap (completely different: no handler hooks)
    -- ========================================================================
    -- The old approach caught the game's five visual-effect handlers
    -- (ParrySuccessAll, ParryAttempt, ParrySuccess, PlaySound, PlayVisuals) with
    -- getconnections and replaced each one -- the loops that were causing kicks.
    -- This touches none of that. Every effect the game plays turns a sword *name*
    -- into its visual data through one shared resolver, Swords:GetSword (the same
    -- one this script already uses at load). We make that resolver hand back the
    -- chosen skin's data whenever it is asked for the sword we actually have
    -- equipped; the game's own, untouched effect code then renders the skin by
    -- itself. No getconnections on the effect remotes, nothing disabled, nothing
    -- added -- and it is a plain field write on a module table we legitimately
    -- require, not a closure hook, so there is no C/Lua-closure tell and nothing
    -- for a hook scan to find. The connection list stays a clean client's.

    -- The server fires our effects under the sword we really have equipped, so
    -- remap only that name; every other player's sword resolves untouched.
    local function isOurEquippedSword(name)
        if type(name) ~= "string" or name == "" then return false end
        return name == LocalPlayer:GetAttribute("CurrentlyEquippedSword")
            or name == getgenv().swordModel
    end

    -- Swap the resolver in place on the required module table. require() hands
    -- every script the same cached table, so the game's effect code reads this
    -- raw field too. We call the original for the real lookup -- and crucially
    -- recurse the real one under the SKIN'S name, so the returned data is a
    -- genuine game sword-data table (right SlashName / AnimationType / fields),
    -- never a hand-built one that would read as foreign.
    pcall(function()
        local realGetSword = swordInstances.GetSword
        if type(realGetSword) == "function" then
            rawset(swordInstances, "GetSword", function(self, name, ...)
                if getgenv().skinChanger then
                    local fx = getgenv().swordFX ~= "" and getgenv().swordFX or getgenv().swordModel
                    if fx ~= "" and fx ~= name and isOurEquippedSword(name) then
                        local ok, skinData = pcall(realGetSword, self, fx, ...)
                        if ok and type(skinData) == "table" then return skinData end
                    end
                end
                return realGetSword(self, name, ...)
            end)
        end
    end)
    getgenv().updateSword = function()
        refreshSlashName()
        if getgenv().skinChanger and getgenv().swordModel ~= "" then saveSkinData() end
        setSword()
    end
    task.spawn(function()
        while task.wait(1) do
            if getgenv().skinChanger and getgenv().swordModel ~= "" then
                local char = LocalPlayer.Character
                if char then
                    if LocalPlayer:GetAttribute("CurrentlyEquippedSword") ~= getgenv().swordModel then setSword() end
                    if not char:FindFirstChild(getgenv().swordModel) then setSword() end
                    for _, v in pairs(char:GetChildren()) do
                        if v:IsA("Model") and v.Name ~= getgenv().swordModel then v:Destroy() end
                        task.wait()
                    end
                end
            end
        end
    end)
    -- Re-equip the chosen sword after a respawn, once the game has given back the real one.
    LocalPlayer.CharacterAdded:Connect(function()
        if not getgenv().skinChanger then return end
        task.wait(2.5)
        if getgenv().skinChanger then pcall(function() getgenv().updateSword() end) end
    end)
end)

-- ============================================================
-- AVATAR CHANGER
-- ============================================================
local __players = cloneref(game:GetService('Players'))
local __localplayer = __players.LocalPlayer

local function saveOriginalAppearance()
    if _G.OriginalAppearance then return end
    local char = __localplayer.Character; if not char then return end
    _G.OriginalAppearance = {Face = nil, Shirt = nil, Pants = nil, BodyColors = nil, HeadMesh = nil, Accessories = {}, CharacterMeshes = {}}
    local head = char:FindFirstChild("Head")
    if head then
        local face = head:FindFirstChildOfClass("Decal"); if face then _G.OriginalAppearance.Face = face.Texture end
        local headMesh = head:FindFirstChildOfClass("SpecialMesh"); if headMesh then _G.OriginalAppearance.HeadMesh = headMesh:Clone() end
    end
    local shirt = char:FindFirstChildOfClass("Shirt"); if shirt then _G.OriginalAppearance.Shirt = shirt.ShirtTemplate end
    local pants = char:FindFirstChildOfClass("Pants"); if pants then _G.OriginalAppearance.Pants = pants.PantsTemplate end
    local bc = char:FindFirstChildOfClass("BodyColors")
    if bc then
        _G.OriginalAppearance.BodyColors = {HeadColor3 = bc.HeadColor3, LeftArmColor3 = bc.LeftArmColor3, RightArmColor3 = bc.RightArmColor3, LeftLegColor3 = bc.LeftLegColor3, RightLegColor3 = bc.RightLegColor3, TorsoColor3 = bc.TorsoColor3}
    end
    for _, obj in ipairs(char:GetChildren()) do
        if obj:IsA("Accessory") or obj:IsA("Accoutrement") then table.insert(_G.OriginalAppearance.Accessories, obj:Clone())
        elseif obj:IsA("CharacterMesh") then table.insert(_G.OriginalAppearance.CharacterMeshes, obj:Clone()) end
    end
end

local function restoreOriginalAppearance()
    local char = __localplayer.Character; if not char or not _G.OriginalAppearance then return end
    pcall(function()
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
        local head = char:FindFirstChild("Head")
        if head then
            local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
            if _G.OriginalAppearance.Face then
                local newFace = Instance.new("Decal"); newFace.Name = "face"; newFace.Texture = _G.OriginalAppearance.Face; newFace.Parent = head
            end
            local headMesh = head:FindFirstChildOfClass("SpecialMesh"); if headMesh then headMesh:Destroy() end
            if _G.OriginalAppearance.HeadMesh then _G.OriginalAppearance.HeadMesh:Clone().Parent = head end
        end
        if _G.OriginalAppearance.Shirt then
            local shirt = Instance.new("Shirt"); shirt.Name = "Shirt"; shirt.ShirtTemplate = _G.OriginalAppearance.Shirt; shirt.Parent = char
        end
        if _G.OriginalAppearance.Pants then
            local pants = Instance.new("Pants"); pants.Name = "Pants"; pants.PantsTemplate = _G.OriginalAppearance.Pants; pants.Parent = char
        end
        if _G.OriginalAppearance.BodyColors then
            local bc = Instance.new("BodyColors")
            for k, v in pairs(_G.OriginalAppearance.BodyColors) do bc[k] = v end
            bc.Parent = char
        end
        for _, mesh in ipairs(_G.OriginalAppearance.CharacterMeshes) do mesh:Clone().Parent = char end
        for _, acc in ipairs(_G.OriginalAppearance.Accessories) do acc:Clone().Parent = char end
    end)
end

local function attachAccessoryManually(char, acc)
    local handle = acc:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return end
    local accAttachment = handle:FindFirstChildOfClass("Attachment")
    local charAttachment
    if accAttachment then
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") then
                charAttachment = part:FindFirstChild(accAttachment.Name)
                if charAttachment then break end
            end
        end
    end
    if charAttachment then
        acc.Parent = char; handle.CanCollide = false; handle.Anchored = false
        local part = charAttachment.Parent
        if charAttachment:IsA("Attachment") and accAttachment then
            handle.CFrame = part.CFrame * charAttachment.CFrame * accAttachment.CFrame:Inverse()
        else handle.CFrame = part.CFrame * CFrame.new(0, 0, 0) end
        local weld = Instance.new("Weld"); weld.Name = "AccessoryWeld"; weld.Part0 = handle; weld.Part1 = part
        weld.C0 = accAttachment and accAttachment.CFrame or CFrame.new(0, 0.6, 0)
        weld.C1 = charAttachment:IsA("Attachment") and charAttachment.CFrame or CFrame.new()
        weld.Parent = handle
    else
        local part = char:FindFirstChild("Head")
        if part then
            acc.Parent = char; handle.CanCollide = false; handle.Anchored = false
            handle.CFrame = part.CFrame * CFrame.new(0, 0.6, 0)
            local weld = Instance.new("Weld"); weld.Name = "AccessoryWeld"; weld.Part0 = handle; weld.Part1 = part
            weld.C0 = CFrame.new(0, 0.6, 0); weld.C1 = CFrame.new(); weld.Parent = handle
        else acc.Parent = char end
    end
end

local function applyAvatarLocally(userId)
    local char = __localplayer.Character; if not char then return end
    local success, model = pcall(function() return __players:CreateHumanoidModelFromUserId(userId) end)
    if not success or not model then return end
    pcall(function()
        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") or obj:IsA("Accoutrement") or obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("CharacterMesh") or obj:IsA("ShirtGraphic") then obj:Destroy() end
        end
        local head = char:FindFirstChild("Head")
        local modelHead = model:FindFirstChild("Head")
        if head and modelHead then
            local face = head:FindFirstChildOfClass("Decal"); if face then face:Destroy() end
            local modelFace = modelHead:FindFirstChildOfClass("Decal"); if modelFace then modelFace:Clone().Parent = head end
            local headMesh = head:FindFirstChildOfClass("SpecialMesh")
            local modelMesh = modelHead:FindFirstChildOfClass("SpecialMesh")
            if modelMesh then if headMesh then headMesh:Destroy() end; modelMesh:Clone().Parent = head
            elseif headMesh then headMesh:Destroy() end
            head.Size = modelHead.Size; head.Color = modelHead.Color
        end
        for _, obj in ipairs(model:GetChildren()) do
            if obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("BodyColors") or obj:IsA("ShirtGraphic") or obj:IsA("CharacterMesh") then obj:Clone().Parent = char
            elseif obj:IsA("Accessory") or obj:IsA("Accoutrement") then pcall(function() attachAccessoryManually(char, obj:Clone()) end) end
        end
        model:Destroy()
    end)
end

local __avatar_changer_target = ""
local __avatar_changer_enabled = false

local function __resolveTargetId(value)
    if value == nil or value == "" then return nil end
    local id = tonumber(value); if id then return id end
    local ok, resolved = pcall(function() return __players:GetUserIdFromNameAsync(value) end)
    if ok and resolved then return resolved end
    return nil
end

-- ============================================================
-- ABILITY ESP
-- ============================================================
-- Live-editable Ability ESP settings, read by the update loop.
local AbilityESPConfig = {
    Color = Color3.fromRGB(255, 255, 255),
    TextSize = 14,
    Height = 3.5,          -- studs above the head
    ShowName = true,       -- show the player's display name
    ShowDistance = false,  -- append distance in studs
    OnlyWithAbility = false, -- only show players who have an ability equipped
    MaxDistance = 0,       -- 0 = unlimited; otherwise hide beyond this many studs
    ShowActive = true,     -- "ACTIVE 2.4s" while their ability is running
    ShowCooldown = true,   -- "CD 6.1s" / "READY"
}

-- Scoped so its helpers don't count against the main chunk's 200-local limit;
-- start_ability_esp / stop_ability_esp are globals used by the menu.
do
-- One shared loop (10x a second) updates every label, instead of a Heartbeat
-- connection per player, and only writes a label's text or style when it
-- actually changed.
local abilityEspEntries = {}       -- player -> {billboard, label, character, head, text, color, size, height}
local abilityEspCharConns = {}     -- player -> CharacterAdded connection
local abilityEspPlayerAddedConnection = nil
local abilityEspLoop = nil

local function esp_escape(s)
    return (tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

-- The ability line for one player, from what the game itself replicates:
--   name     player's EquippedAbility (or the character's Ability)
--   version  player.Upgrades.<ability> level: 1 -> "V1", 2 -> "V2" (0 = base)
--   active   player's AbilityDurationStart + AbilityDuration (server time), the
--            same pair the game's own ability duration bar reads; falls back to
--            the character's AbilityActive flag when there's no duration
--   cooldown the character's CooldownExpiration (server time)
local function esp_ability_info(player, character)
    local ability = player:GetAttribute('EquippedAbility') or (character and character:GetAttribute('Ability'))
    if not ability or ability == '' then return nil end
    local name = tostring(ability)
    local upgrades = player:FindFirstChild('Upgrades')
    local level_value = upgrades and upgrades:FindFirstChild(name)
    local level = level_value and level_value.Value
    if type(level) == 'number' and level > 0 then name = name .. ' V' .. level end

    local now = Workspace:GetServerTimeNow()
    local status
    if AbilityESPConfig.ShowActive then
        local start = player:GetAttribute('AbilityDurationStart') or 0
        local duration = player:GetAttribute('AbilityDuration') or 0
        local left = (start > 0 and duration > 0) and (start + duration - now) or 0
        if left > 0 then
            status = ('<font color="#5CFF7A">ACTIVE %.1fs</font>'):format(left)
        elseif character and character:GetAttribute('AbilityActive') then
            status = '<font color="#5CFF7A">ACTIVE</font>'
        end
    end
    if not status and AbilityESPConfig.ShowCooldown then
        local expires = (character and character:GetAttribute('CooldownExpiration')) or player:GetAttribute('CooldownExpiration')
        if type(expires) == 'number' then
            local left = expires - now
            if left > 0 and left < 600 then
                status = ('<font color="#FF6A6A">CD %.1fs</font>'):format(left)
            else
                status = '<font color="#B4B4B4">READY</font>'
            end
        end
    end
    return name, status
end

local function remove_ability_esp_entry(player)
    local e = abilityEspEntries[player]
    if e then pcall(function() e.billboard:Destroy() end) end
    abilityEspEntries[player] = nil
end

local function update_ability_esp()
    local myRoot = getRoot()
    local cfg = AbilityESPConfig
    for player, e in pairs(abilityEspEntries) do
        local character, head = e.character, e.head
        if not (character and character.Parent and head and head.Parent) then
            remove_ability_esp_entry(player)
        else
            local dist = myRoot and (myRoot.Position - head.Position).Magnitude
            local name, status = esp_ability_info(player, character)
            local visible = not (cfg.MaxDistance > 0 and dist and dist > cfg.MaxDistance)
                and not (cfg.OnlyWithAbility and not name)
            if e.label.Visible ~= visible then e.label.Visible = visible end
            if visible then
                if e.color ~= cfg.Color then e.color = cfg.Color; e.label.TextColor3 = cfg.Color end
                if e.size ~= cfg.TextSize then e.size = cfg.TextSize; e.label.TextSize = cfg.TextSize end
                if e.height ~= cfg.Height then e.height = cfg.Height; e.billboard.StudsOffset = Vector3.new(0, cfg.Height, 0) end
                local parts = {}
                if cfg.ShowName then parts[#parts + 1] = esp_escape(player.DisplayName) end
                if name then parts[#parts + 1] = '[' .. esp_escape(name) .. ']' end
                if cfg.ShowDistance and dist then parts[#parts + 1] = ('%.0fm'):format(dist) end
                if #parts == 0 then parts[1] = esp_escape(player.DisplayName) end
                local text = '<b>' .. table.concat(parts, ' ') .. '</b>'
                if status then text = text .. '\n' .. status end
                if text ~= e.text then e.text = text; e.label.Text = text end
            end
        end
    end
end

local function create_ability_esp_for_player(player)
    task.spawn(function()
        local character = player.Character
        while getgenv().AbilityESP and (not character or not character.Parent) do task.wait(0.5); character = player.Character end
        if not character then return end
        local head = character:WaitForChild('Head', 10)
        if not head or not getgenv().AbilityESP then return end
        remove_ability_esp_entry(player)
        -- The billboard lives in our hidden container and only points at the head
        -- (Adornee). Parenting it INTO the head put a foreign BillboardGui in
        -- another player's character in Workspace, where the game can see it.
        local billboard = Instance.new('BillboardGui')
        billboard.Name = 'AbilityESPGui'; billboard.Adornee = head
        billboard.Size = UDim2.new(0, 220, 0, 60)
        billboard.StudsOffset = Vector3.new(0, AbilityESPConfig.Height, 0); billboard.AlwaysOnTop = true
        billboard.Parent = HUI
        local label = Instance.new('TextLabel')
        label.Size = UDim2.new(1, 0, 1, 0); label.BackgroundTransparency = 1
        label.TextColor3 = AbilityESPConfig.Color; label.TextSize = AbilityESPConfig.TextSize
        label.TextStrokeTransparency = 0; label.Font = Enum.Font.Roboto
        label.RichText = true; label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center; label.Parent = billboard
        label.Visible = false
        abilityEspEntries[player] = {
            billboard = billboard, label = label, character = character, head = head,
            color = AbilityESPConfig.Color, size = AbilityESPConfig.TextSize, height = AbilityESPConfig.Height,
        }
    end)
end

local function add_ability_esp_player(player)
    if player == LocalPlayer then return end
    if abilityEspCharConns[player] then pcall(function() abilityEspCharConns[player]:Disconnect() end) end
    abilityEspCharConns[player] = player.CharacterAdded:Connect(function() create_ability_esp_for_player(player) end)
    if player.Character then create_ability_esp_for_player(player) end
end

function start_ability_esp()
    if abilityEspLoop then return end
    getgenv().AbilityESP = true
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then add_ability_esp_player(player) end
    end
    abilityEspPlayerAddedConnection = Players.PlayerAdded:Connect(function(player)
        if getgenv().AbilityESP then add_ability_esp_player(player) end
    end)
    local acc = 0
    abilityEspLoop = RunService.Heartbeat:Connect(function(dt)
        acc = acc + dt
        if acc < 0.1 then return end
        acc = 0
        pcall(update_ability_esp)
    end)
end

function stop_ability_esp()
    getgenv().AbilityESP = false
    if abilityEspLoop then pcall(function() abilityEspLoop:Disconnect() end); abilityEspLoop = nil end
    if abilityEspPlayerAddedConnection then
        pcall(function() abilityEspPlayerAddedConnection:Disconnect() end)
        abilityEspPlayerAddedConnection = nil
    end
    for _, connection in pairs(abilityEspCharConns) do pcall(function() connection:Disconnect() end) end
    abilityEspCharConns = {}
    for player in pairs(abilityEspEntries) do remove_ability_esp_entry(player) end
end
end -- ability ESP scope

-- ============================================================
-- BALL VELOCITY GUI
-- ============================================================
function System.create_ball_velocity_gui()
    if System.__properties.__ball_velocity_gui then System.__properties.__ball_velocity_gui.gui:Destroy() end
    local gui = Instance.new("ScreenGui"); gui.Name = "BallVelocityGUI"; gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    local frame = Instance.new("Frame"); frame.Size = UDim2.new(0, 200, 0, 75)
    frame.Position = UDim2.new(0, 10, 0.80, 0); frame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    frame.BackgroundTransparency = 0.4; frame.BorderSizePixel = 0; frame.Active = true; frame.Draggable = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame); stroke.Color = Color3.fromRGB(255,255,255); stroke.Thickness = 2
    local title = Instance.new("TextLabel", frame); title.Size = UDim2.new(1,0,0,18); title.Position = UDim2.new(0,0,0,5)
    title.BackgroundTransparency = 1; title.Text = "Ball Status"; title.TextColor3 = Color3.fromRGB(255,255,255)
    title.Font = Enum.Font.GothamBold; title.TextSize = 13
    local cl = Instance.new("TextLabel", frame); cl.Size = UDim2.new(1,-10,0,22); cl.Position = UDim2.new(0,5,0,24)
    cl.BackgroundTransparency = 1; cl.Text = "Current: 0"; cl.TextColor3 = Color3.fromRGB(255,255,255)
    cl.Font = Enum.Font.GothamBold; cl.TextSize = 15; cl.TextXAlignment = Enum.TextXAlignment.Left
    local pl = Instance.new("TextLabel", frame); pl.Size = UDim2.new(1,-10,0,22); pl.Position = UDim2.new(0,5,0,46)
    pl.BackgroundTransparency = 1; pl.Text = "Peak: 0"; pl.TextColor3 = Color3.fromRGB(255,255,255)
    pl.Font = Enum.Font.GothamBold; pl.TextSize = 15; pl.TextXAlignment = Enum.TextXAlignment.Left
    frame.Parent = gui; gui.Parent = HUI
    System.__properties.__ball_velocity_gui = {gui=gui, frame=frame, currentSpeedLabel=cl, peakSpeedLabel=pl}
end

function System.update_ball_velocity()
    if not System.__properties.__ball_velocity_enabled or not System.__properties.__ball_velocity_gui then return end
    local ball = System.ball.get()
    if not ball then System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = "Current: 0"; return end
    local ballId = ball:GetFullName()
    if ballId ~= System.__properties.__last_ball_id then System.__properties.__peak_velocity = 0; System.__properties.__last_ball_id = ballId end
    local zoomies = ball:FindFirstChild('zoomies')
    if not zoomies then System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = "Current: 0"; return end
    local speed = zoomies.VectorVelocity.Magnitude
    if speed > System.__properties.__peak_velocity then System.__properties.__peak_velocity = speed end
    local color = Color3.fromRGB(255, 255, 0)
    if speed > 2000 then color = Color3.fromRGB(255, 0, 0)
    elseif speed > 1500 then color = Color3.fromRGB(255, 165, 0)
    elseif speed > 1000 then color = Color3.fromRGB(255, 215, 0) end
    local peakColor = Color3.fromRGB(255, 255, 0)
    if System.__properties.__peak_velocity > 2000 then peakColor = Color3.fromRGB(255, 0, 0)
    elseif System.__properties.__peak_velocity > 1500 then peakColor = Color3.fromRGB(255, 165, 0)
    elseif System.__properties.__peak_velocity > 1000 then peakColor = Color3.fromRGB(255, 215, 0) end
    System.__properties.__ball_velocity_gui.currentSpeedLabel.RichText = true
    System.__properties.__ball_velocity_gui.currentSpeedLabel.Text = string.format("Current: <font color='#%02x%02x%02x'>%.1f</font>", math.floor(color.R*255), math.floor(color.G*255), math.floor(color.B*255), speed)
    System.__properties.__ball_velocity_gui.peakSpeedLabel.RichText = true
    System.__properties.__ball_velocity_gui.peakSpeedLabel.Text = string.format("Peak: <font color='#%02x%02x%02x'>%.1f</font>", math.floor(peakColor.R*255), math.floor(peakColor.G*255), math.floor(peakColor.B*255), System.__properties.__peak_velocity)
end


-- ============================================================
-- PING GUI
-- ============================================================
local PingGui = Instance.new("ScreenGui")
PingGui.Name = "BladeBallPing"; PingGui.ResetOnSpawn = false
PingGui.IgnoreGuiInset = true; PingGui.DisplayOrder = 999; PingGui.Enabled = false
local PingFrame = Instance.new("Frame", PingGui)
PingFrame.Size = UDim2.new(0, 110, 0, 35); PingFrame.Position = UDim2.new(0, 15, 0.88, 0)
PingFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 10); PingFrame.BackgroundTransparency = 0.3
PingFrame.BorderSizePixel = 0; PingFrame.Active = true; PingFrame.Draggable = true
Instance.new("UICorner", PingFrame).CornerRadius = UDim.new(0, 8)
Instance.new("UIStroke", PingFrame).Color = Color3.fromRGB(60, 60, 60)
local PingLabel = Instance.new("TextLabel", PingFrame)
PingLabel.Size = UDim2.new(1, 0, 1, 0); PingLabel.Text = "Ping: 0ms"
PingLabel.TextColor3 = Color3.fromRGB(255, 255, 255); PingLabel.BackgroundTransparency = 1
PingLabel.Font = Enum.Font.GothamBold; PingLabel.TextSize = 14; PingLabel.RichText = true
PingLabel.TextXAlignment = Enum.TextXAlignment.Center
PingGui.Parent = HUI

task.spawn(function()
    while task.wait(0.5) do
        if Library.Unloaded then break end
        if System.__properties.__show_ping then
            local ping = getPing()
            local color = Color3.fromRGB(0, 255, 0)
            if ping > 300 then color = Color3.fromRGB(255, 0, 0)
            elseif ping > 150 then color = Color3.fromRGB(255, 165, 0) end
            PingLabel.Text = string.format("Ping: <font color='#%s'>%dms</font>", color:ToHex(), ping)
        end
    end
end)

-- ============================================================
-- UI
-- ============================================================
local Tabs = {
    Status = Window:AddTab("Status", "gauge", "Live ball and parry info"),
    Parry = Window:AddTab("Auto Parry", "swords", "Auto parry, triggerbot and abilities"),
    Detection = Window:AddTab("Detection", "shield-alert", "Pause parrying during enemy abilities"),
    Spam = Window:AddTab("Spam", "zap", "Manual spam"),
    Player = Window:AddTab("Player", "user", "Avatar, cosmetics and movement"),
    Visuals = Window:AddTab("Visuals", "eye", "Overlays and ESP"),
    Misc = Window:AddTab("Misc", "wrench", "Skin changer and extras"),
}

-- STATUS TAB
local Overview = Tabs.Status:AddBigGroupbox({Name = "Overview", Description = "Updates while the menu is open", IconName = "gauge"})
local StatCards = Overview:AddStatCards("StatusCards", {
    Cards = {
        {Title = "Ball speed", Value = 0, Icon = "wind"},
        {Title = "Peak speed", Value = 0, Icon = "trending-up"},
        {Title = "Distance", Value = "-", Icon = "ruler"},
        {Title = "Parry range", Value = "-", Icon = "crosshair"},
        {Title = "Ping", Value = "0 ms", Icon = "wifi"},
        {Title = "Parries", Value = 0, Icon = "shield"},
    },
})
Overview:AddLabel("Version: " .. SCRIPT_VERSION, true)
local RemoteLabel = Overview:AddLabel("Remote: checking...", true)
local TargetLabel = Overview:AddLabel("Ball target: -", true)

local LogBox = Tabs.Status:AddLeftGroupbox("Parry log", "list")
LogBox:AddLabel("Every parry this copy sends: where it came from and which pass at you it was for. Two for the same pass are marked DOUBLE. Spam is only counted.", true)
local LogCounts = LogBox:AddLabel("Parries: 0  |  doubles: 0  |  spam: 0", true)
local LogLines = LogBox:AddLabel("(nothing yet)", true)
LogBox:AddButton({Text = "Clear log", Func = function()
    ParryLog.entries, ParryLog.total, ParryLog.doubles, ParryLog.spam = {}, 0, 0, 0
end})
local function parry_log_text()
    if #ParryLog.entries == 0 then return "(nothing yet)" end
    local now, lines = os.clock(), {}
    for i = #ParryLog.entries, 1, -1 do
        local e = ParryLog.entries[i]
        local where = e.pass and string.format("pass %d, %.0f studs, heading %.2f", e.pass, e.dist or 0, e.heading or 0)
            or "no ball on you"
        lines[#lines + 1] = string.format("%s%.1fs ago  %s (%s)  %s", e.double and "DOUBLE  " or "", now - e.t, e.src, e.how, where)
    end
    return table.concat(lines, "\n")
end
task.spawn(function()
    while task.wait(0.25) do
        if Library.Unloaded then break end
        if Library.Toggled then
            LogCounts:SetText(string.format("Parries: %d  |  doubles: %d  |  spam: %d", ParryLog.total, ParryLog.doubles, ParryLog.spam))
            LogLines:SetText(parry_log_text())
        end
    end
end)

local function remoteStatusText()
    if getgenv().AutoParryMode == "Keypress" then return "Mode: Keypress (presses the block key)" end
    local w = parry_window()
    local wtxt = w and ("%.3f"):format(w) or (Win.done and "fallback" or "reading stats...")
    if remoteReady() then
        return ("Remote: armed -- %s. window=%s, no memory reads, no hooks"):format(tostring(Sender.info), wtxt)
    end
    return "Remote: " .. tostring(Sender.info) .. " (window=" .. wtxt .. ")"
end

local status_peak, status_ball = 0, nil
task.spawn(function()
    while task.wait(0.1) do
        if Library.Unloaded then break end
        if Library.Toggled then
            local ball = System.ball.get()
            local root = getRoot()
            local speed = 0
            if ball ~= status_ball then status_ball = ball; status_peak = 0 end
            local zoomies = ball and ball:FindFirstChild('zoomies')
            if zoomies then speed = zoomies.VectorVelocity.Magnitude end
            if speed > status_peak then status_peak = speed end
            StatCards:SetValue("Ball speed", string.format("%.0f", speed))
            StatCards:SetValue("Peak speed", string.format("%.0f", status_peak))
            if ball and root then
                StatCards:SetValue("Distance", string.format("%.0f", (root.Position - ball.Position).Magnitude))
                StatCards:SetValue("Parry range", string.format("%.0f", System.parry_distance(speed)))
            else
                StatCards:SetValue("Distance", "-")
                StatCards:SetValue("Parry range", "-")
            end
            StatCards:SetValue("Ping", string.format("%d ms", getPing()))
            StatCards:SetValue("Parries", System.__properties.__total_parries)
            RemoteLabel:SetText(remoteStatusText())
            local target = ball and ball:GetAttribute('target')
            local text = "Ball target: " .. ((target == nil or target == "") and "-" or tostring(target))
            -- Live read of the ball: how straight it's heading at you (1 = dead
            -- on), how close its line passes you, and while it's on you what
            -- auto parry is doing with it and why.
            if ball and root and speed > 1 then
                local heading, miss = read_ball(ball, root)
                text = text .. string.format("  |  heading %.2f", heading)
                if miss < math.huge then text = text .. string.format("  |  line passes %.0f studs", miss) end
                local st = ball_state[ball]
                if target == LocalPlayer.Name and st and st.why then text = text .. "  |  auto parry: " .. st.why end
            end
            TargetLabel:SetText(text)
        end
    end
end)

-- AUTO PARRY TAB
local AP = Tabs.Parry:AddLeftGroupbox("Auto Parry", "swords")
AP:AddToggle("AutoParry", {Text = "Auto parry", Default = false, Callback = function(v)
    System.__properties.__autoparry_enabled = v
    System.__properties.__play_animation = v
    if v then System.autoparry.start(); prime_remote() else System.autoparry.stop() end
    NotifyToggle("Auto Parry", v)
end}):AddKeyPicker("AutoParryKey", {Default = "None", Mode = "Toggle", SyncToggleState = true, Text = "Auto parry"})
AP:AddDropdown("ParryMode", {Text = "Parry mode", Values = {"Remote", "Keypress"}, Default = "Remote",
    Tooltip = "Remote fires the parry remote with your curve (hookless, sends exactly what the game sends). Keypress presses the block key (F).",
    Callback = function(v) getgenv().AutoParryMode = v end})
AP:AddDropdown("CurveMode", {Text = "Curve mode", Values = System.__config.__curve_names, Default = "Camera",
    Callback = function(v)
        for i, n in ipairs(System.__config.__curve_names) do if n == v then System.__properties.__curve_mode = i; break end end
    end})
AP:AddDropdown("TargetMode", {Text = "Target mode", Values = System.__config.__target_names, Default = "Cursor",
    Tooltip = "Who the ball goes to (separate from curve). Cursor: player under your mouse. Camera: player nearest screen centre. Closest/Farthest: by distance to you. Random: a random player. Needs remote parry mode.",
    Callback = function(v)
        for i, n in ipairs(System.__config.__target_names) do if n == v then System.__properties.__target_mode = i; break end end
    end})
AP:AddSlider("Accuracy", {Text = "Accuracy", Default = 50, Min = 1, Max = 100, Rounding = 0,
    Tooltip = "Higher parries later (closer). Lower parries earlier (further away).",
    Callback = function(v) System.__properties.__accuracy_base = v; roll_accuracy() end})
AP:AddToggle("RandomAccuracy", {Text = "Randomize accuracy", Default = false,
    Tooltip = "Jitters accuracy around your current Accuracy setting each parry, to look less robotic.",
    Callback = function(v)
        System.__properties.__random_accuracy = v
        roll_accuracy() -- snaps back to the base value when turned off
        NotifyToggle("Randomize Accuracy", v)
    end})
AP:AddSlider("RandomAccuracyAmount", {Text = "Randomize amount", Default = 10, Min = 0, Max = 50, Rounding = 0, Suffix = " ±",
    Tooltip = "How far accuracy can swing above/below your setting, based on the current Accuracy value.",
    Callback = function(v) System.__properties.__random_accuracy_amount = v; roll_accuracy() end})
AP:AddToggle("PingCompensation", {Text = "Ping compensation", Default = true,
    Tooltip = "Parries earlier the higher your ping, by how far the ball moves in half a round trip.",
    Callback = function(v) System.__properties.__ping_compensation = v end})
AP:AddSlider("ExtraDistance", {Text = "Extra distance", Default = 0, Min = -10, Max = 30, Rounding = 0, Suffix = " studs",
    Callback = function(v) System.__properties.__extra_distance = v end})
AP:AddSlider("CloseRange", {Text = "Close range", Default = 20, Min = 8, Max = 45, Rounding = 0, Suffix = " studs",
    Tooltip = "Instant parry on retarget and pre-parry only work inside this distance.",
    Callback = function(v) APCfg.close_range = v end})
AP:AddToggle("InstantRetarget", {Text = "Instant parry on retarget", Default = true,
    Tooltip = "Inside close range, parries the moment the ball switches to you if it's close enough to land within a parry. Still one parry per pass.",
    Callback = function(v) APCfg.instant = v end})
AP:AddToggle("ClosePreParry", {Text = "Close-range pre-parry", Default = false,
    Tooltip = "Off by default. Parries ahead when a player next to you is about to hit the ball and a return would be too fast to react to. It's a guess: if they send it elsewhere or curve it, it was wasted. Auto spam is the better tool for clashes.",
    Callback = function(v) APCfg.preparry = v end})
AP:AddToggle("RandomCurve", {Text = "Random curve", Default = false, Callback = function(s)
    if s then
        if not System.__properties.__connections.__rc then
            System.__properties.__connections.__rc = RunService.PreSimulation:Connect(function()
                System.__properties.__curve_mode = math.random(1, #System.__config.__curve_names)
            end)
        end
    else
        if System.__properties.__connections.__rc then
            System.__properties.__connections.__rc:Disconnect()
            System.__properties.__connections.__rc = nil
        end
        -- Back to whatever the dropdown says.
        if Options.CurveMode then Options.CurveMode:SetValue(Options.CurveMode.Value) end
    end
end})
AP:AddToggle("CurveHotkeys", {Text = "Curve hotkeys (1-9)", Default = true,
    Tooltip = "Number keys 1-9 pick the curve mode.",
    Callback = function(v) System.__properties.__curve_hotkeys = v end})

local TB = Tabs.Parry:AddRightGroupbox("Triggerbot", "crosshair")
local function setTriggerbot(v)
    System.__properties.__triggerbot_enabled = v
    System.triggerbot.enable(v)
    if v then prime_remote() end
end
TB:AddToggle("Triggerbot", {Text = "Triggerbot", Default = false,
    Tooltip = "Parries the moment the ball targets you, at any distance. Overrides auto parry while on.",
    Callback = function(v)
        setTriggerbot(v)
        NotifyToggle("Triggerbot", v)
        if not isMobile then return end
        if v then
            if not System.__properties.__mobile_guis.triggerbot then
                local tb = create_mobile_button('Trigger', 0.20, Color3.fromRGB(255, 100, 0), 0.15)
                System.__properties.__mobile_guis.triggerbot = tb
                tb.button.MouseButton1Click:Connect(function()
                    setTriggerbot(not System.__properties.__triggerbot_enabled)
                    local on = System.__properties.__triggerbot_enabled
                    tb.text.Text = on and "ON" or "Trigger"
                    tb.text.TextColor3 = on and Color3.fromRGB(0, 255, 100) or Color3.fromRGB(255, 255, 255)
                    Notify("Triggerbot", on and "ON" or "OFF", 1.5)
                end)
            end
        else
            destroy_mobile_gui(System.__properties.__mobile_guis.triggerbot)
            System.__properties.__mobile_guis.triggerbot = nil
        end
    end}):AddKeyPicker("TriggerbotKey", {Default = "R", Mode = "Toggle", SyncToggleState = true, Text = "Triggerbot"})

local AB = Tabs.Parry:AddRightGroupbox("Abilities", "sparkles")
AB:AddToggle("AutoAbility", {Text = "Auto ability", Default = false,
    Tooltip = "Uses a ready deflect or slash ability instead of parrying.",
    Callback = function(v) System.__properties.__auto_ability_enabled = v end})
AB:AddToggle("CooldownProtection", {Text = "Cooldown protection", Default = false,
    Tooltip = "Uses a ready deflection ability (Raging, Rapture, Calming) instead of parrying.",
    Callback = function(v) System.__properties.__cooldown_protection = v end})

-- DETECTION TAB
local DL = Tabs.Detection:AddLeftGroupbox("Abilities", "shield-alert")
DL:AddToggle("DetInfinity", {Text = "Infinity detection", Default = false, Callback = function(v) System.__config.__detections.__infinity = v end})
DL:AddToggle("DetDeathSlash", {Text = "Death Slash detection", Default = false, Callback = function(v) System.__config.__detections.__deathslash = v end})
DL:AddToggle("DetTimeHole", {Text = "Time Hole detection", Default = false, Callback = function(v) System.__config.__detections.__timehole = v end})
DL:AddToggle("DetPhantom", {Text = "Anti-Phantom [BETA]", Default = false, Callback = function(v) System.__config.__detections.__phantom = v end})

local DR = Tabs.Detection:AddRightGroupbox("Slashes Of Fury", "swords")
DR:AddToggle("DetSlashes", {Text = "Slashes detection", Default = false, Callback = function(v) System.__config.__detections.__slashesoffury = v end})
DR:AddSlider("SlashesDelay", {Text = "Parry delay", Default = 0.05, Min = 0.05, Max = 0.25, Rounding = 2, Suffix = "s", Callback = function(v) parryDelay = v end})
DR:AddSlider("SlashesMax", {Text = "Max parry count", Default = 36, Min = 1, Max = 100, Rounding = 0, Callback = function(v) maxParryCount = v end})

-- SPAM TAB
local SP = Tabs.Spam:AddLeftGroupbox("Manual Spam", "zap")
SP:AddToggle("ManualSpam", {Text = "Manual spam", Default = false, Callback = function(v)
    if isMobile then
        -- On mobile the on-screen button is the real control. Arming the toggle
        -- only shows that button (OFF by default), so enabling the feature no
        -- longer starts spamming the moment you flip it — you tap the button to
        -- turn it on, and tap again to turn it off.
        if v then
            System.__properties.__manual_spam_enabled = false
            if not System.__properties.__mobile_guis.manual_spam then
                local sm = create_mobile_button('Spam', 0.35, Color3.fromRGB(255, 255, 255), 0.15)
                System.__properties.__mobile_guis.manual_spam = sm
                sm.button.MouseButton1Click:Connect(function()
                    System.__properties.__manual_spam_enabled = not System.__properties.__manual_spam_enabled
                    local on = System.__properties.__manual_spam_enabled
                    sm.text.Text = on and "ON" or "Spam"
                    sm.text.TextColor3 = on and Color3.fromRGB(0, 255, 100) or Color3.fromRGB(255, 255, 255)
                    Notify("Manual Spam", on and "ON" or "OFF", 1.5)
                end)
            end
        else
            System.__properties.__manual_spam_enabled = false
            destroy_mobile_gui(System.__properties.__mobile_guis.manual_spam)
            System.__properties.__mobile_guis.manual_spam = nil
        end
    else
        System.__properties.__manual_spam_enabled = v
        if v then prime_remote() end
    end
    NotifyToggle("Manual Spam", v)
end}):AddKeyPicker("ManualSpamKey", {Default = "E", Mode = "Hold", SyncToggleState = true, Text = "Manual spam"})
SP:AddDropdown("SpamMode", {Text = "Mode", Values = {"Remote", "Keypress"}, Default = "Remote", Callback = function(v) getgenv().ManualSpamMode = v end})
SP:AddSlider("SpamRate", {Text = "Spam rate", Default = 300, Min = 20, Max = 1000, Rounding = 0, Suffix = " /s",
    Tooltip = "Parries per second while a ball is on or near you (20/s otherwise). Tops out at one per send point (4 per frame) and eases off automatically if your upload gets too high.",
    Callback = function(v) ManualSpam.rate = v end})
local ManualSpamLabel = SP:AddLabel("Actual: 0/s", true)
SP:AddToggle("SpamAnimFix", {Text = "Animation fix", Default = false, Callback = function(v)
    getgenv().ManualSpamAnimationFix = v
    macroAnimFix = v
end})

local AS = Tabs.Spam:AddRightGroupbox("Auto Spam", "activity")
AS:AddToggle("AutoSpam", {Text = "Auto spam", Default = false,
    Tooltip = "Spams only when one parry can't keep up: a clash (the ball going back and forth with a player faster than you could react) or a ball landing on you too fast to react to. Range, hits and timing are worked out from ball speed and ping. Normal rallies are left to auto parry. Never runs in training.",
    Callback = function(v)
        System.__properties.__auto_spam_enabled = v
        if v then prime_remote() else AutoSpam.active_until, AutoSpam.reason = 0, nil end
        NotifyToggle("Auto Spam", v)
    end})
local AutoSpamLabel = AS:AddLabel("Status: off", true)
AS:AddSlider("AutoSpamRate", {Text = "Spam rate", Default = 250, Min = 20, Max = 1000, Rounding = 0, Suffix = " /s",
    Tooltip = "Parries per second while a clash is detected. Tops out at one per send point (4 per frame) and eases off automatically if your upload gets too high, so your movement stays in sync.",
    Callback = function(v) AutoSpam.rate = v end})

task.spawn(function()
    while task.wait(0.1) do
        if Library.Unloaded then break end
        if Library.Toggled then
            local actual = System.spam_actual_rate()
            local props = System.__properties
            local auto_text = "Status: " .. System.auto_spam.status()
            if not props.__manual_spam_enabled and actual >= 1 then
                auto_text = auto_text .. ("  |  %d/s"):format(math.floor(actual + 0.5))
            end
            AutoSpamLabel:SetText(auto_text)
            ManualSpamLabel:SetText(("Actual: %d/s"):format(props.__manual_spam_enabled and math.floor(actual + 0.5) or 0))
        end
    end
end)

-- PLAYER TAB
local AVC = Tabs.Player:AddLeftGroupbox("Avatar Changer", "user")
AVC:AddInput("AvatarTarget", {Text = "Target", Placeholder = "Username or user id", Default = "", Finished = true, Callback = function(t)
    __avatar_changer_target = t
end})
AVC:AddToggle("AvatarChanger", {Text = "Avatar changer", Default = false, Callback = function(v)
    __avatar_changer_enabled = v
    if v then
        task.spawn(function()
            local userId = __resolveTargetId(__avatar_changer_target)
            if userId then
                saveOriginalAppearance(); applyAvatarLocally(userId)
                Notify("Avatar Changer", "Appearance changed", 3)
            else Notify("Avatar Changer", "Invalid username or id", 3) end
        end)
    else
        restoreOriginalAppearance()
        if UIReady then Notify("Avatar Changer", "Appearance restored", 2) end
    end
end})

local HK = Tabs.Player:AddRightGroupbox("Cosmetics", "shirt")
HK:AddToggle("Headless", {Text = "Headless", Default = false, Callback = function(v)
    System.__properties.__headless_enabled = v
    local c = LocalPlayer.Character
    if c then if v then Byte_Library.Headless(c) else Byte_Library.Restore_Head(c) end end
end})
HK:AddToggle("Korblox", {Text = "Korblox", Default = false, Callback = function(v)
    System.__properties.__korblox_enabled = v
    local c = LocalPlayer.Character
    if c then if v then Byte_Library.Korblox(c) else Byte_Library.Restore_Leg(c) end end
end})

local AutoJump = false
local ajLastOnGround = false
local MV = Tabs.Player:AddRightGroupbox("Movement", "footprints")
MV:AddToggle("AutoJump", {Text = "Auto jump", Default = false, Callback = function(v)
    AutoJump = v
    if not v then ajLastOnGround = false end
    NotifyToggle("Auto Jump", v)
end}):AddKeyPicker("AutoJumpKey", {Default = "J", Mode = "Toggle", SyncToggleState = true, Text = "Auto jump"})

RunService.Heartbeat:Connect(function()
    if AutoJump then
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            local onGround = hum.FloorMaterial ~= Enum.Material.Air
            if onGround and not ajLastOnGround then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
            ajLastOnGround = onGround
        end
    else ajLastOnGround = false end
end)

-- VISUALS TAB
local VS = Tabs.Visuals:AddLeftGroupbox("Overlays", "monitor")
VS:AddToggle("BallVelocity", {Text = "Ball velocity overlay", Default = false, Callback = function(v)
    System.__properties.__ball_velocity_enabled = v
    if v then
        System.create_ball_velocity_gui()
        if not System.__properties.__connections.__ball_velocity then
            System.__properties.__connections.__ball_velocity = RunService.RenderStepped:Connect(function() System.update_ball_velocity() end)
        end
    else
        if System.__properties.__ball_velocity_gui then System.__properties.__ball_velocity_gui.gui:Destroy(); System.__properties.__ball_velocity_gui = nil end
        if System.__properties.__connections.__ball_velocity then System.__properties.__connections.__ball_velocity:Disconnect(); System.__properties.__connections.__ball_velocity = nil end
    end
end})
VS:AddToggle("ShowPing", {Text = "Ping overlay", Default = false, Callback = function(v)
    System.__properties.__show_ping = v
    PingGui.Enabled = v
end})

local AE = Tabs.Visuals:AddRightGroupbox("Ability ESP", "eye")
AE:AddToggle("AbilityESP", {Text = "Ability ESP", Default = false, Callback = function(s)
    if s then start_ability_esp() else stop_ability_esp() end
    NotifyToggle("Ability ESP", s)
end})
AE:AddToggle("AbilityESPName", {Text = "Show name", Default = true,
    Callback = function(v) AbilityESPConfig.ShowName = v end})
AE:AddToggle("AbilityESPDistance", {Text = "Show distance", Default = false,
    Callback = function(v) AbilityESPConfig.ShowDistance = v end})
AE:AddToggle("AbilityESPOnlyWith", {Text = "Only players with an ability", Default = false,
    Callback = function(v) AbilityESPConfig.OnlyWithAbility = v end})
AE:AddToggle("AbilityESPActive", {Text = "Show active time", Default = true,
    Tooltip = "Shows ACTIVE and the seconds left while their ability is running.",
    Callback = function(v) AbilityESPConfig.ShowActive = v end})
AE:AddToggle("AbilityESPCooldown", {Text = "Show cooldown", Default = true,
    Tooltip = "Shows the seconds left on their ability cooldown, or READY.",
    Callback = function(v) AbilityESPConfig.ShowCooldown = v end})
AE:AddSlider("AbilityESPTextSize", {Text = "Text size", Default = 14, Min = 8, Max = 30, Rounding = 0,
    Callback = function(v) AbilityESPConfig.TextSize = v end})
AE:AddSlider("AbilityESPHeight", {Text = "Height offset", Default = 3.5, Min = 0, Max = 15, Rounding = 1, Suffix = " studs",
    Tooltip = "How far above the head the label sits.",
    Callback = function(v) AbilityESPConfig.Height = v end})
AE:AddSlider("AbilityESPMaxDistance", {Text = "Max distance", Default = 0, Min = 0, Max = 2000, Rounding = 0, Suffix = " studs",
    Tooltip = "Hide labels beyond this distance. 0 = unlimited.",
    Callback = function(v) AbilityESPConfig.MaxDistance = v end})
AE:AddLabel("Text color"):AddColorPicker("AbilityESPColor", {
    Default = Color3.fromRGB(255, 255, 255), Title = "Ability ESP color",
    Callback = function(v) AbilityESPConfig.Color = v end})

-- MISC TAB
local SC = Tabs.Misc:AddLeftGroupbox("Skin Changer", "palette")
SC:AddInput("SkinName", {Text = "Sword name", Placeholder = "e.g. DualPrince", Default = getgenv().swordModel or "", Finished = true, Callback = function(t)
    getgenv().swordModel = t
    getgenv().swordAnimations = t
    getgenv().swordFX = t
    if getgenv().skinChangerEnabled and t ~= "" then
        if getgenv().updateSword then pcall(getgenv().updateSword) end
    end
    if getgenv().saveLastEquippedSword then pcall(getgenv().saveLastEquippedSword) end
end})
SC:AddToggle("SkinChanger", {Text = "Skin changer", Default = false, Callback = function(v)
    getgenv().skinChanger = v
    getgenv().skinChangerEnabled = v
    if v and getgenv().swordModel ~= "" then
        if getgenv().updateSword then pcall(getgenv().updateSword) end
    end
    NotifyToggle("Skin Changer", v)
end})

local NR = Tabs.Misc:AddRightGroupbox("Performance", "cpu")
local Connections_Manager = {}
NR:AddToggle("NoRender", {Text = "No render", Default = false,
    Tooltip = "Turns off ability and parry effects.",
    Callback = function(state)
        local effectScripts = LocalPlayer.PlayerScripts:FindFirstChild("EffectScripts")
        local clientFX = effectScripts and effectScripts:FindFirstChild("ClientFX")
        if clientFX then clientFX.Disabled = state end
        if state then
            if not Connections_Manager['No Render'] then
                Connections_Manager['No Render'] = Runtime.ChildAdded:Connect(function(Value) Debris:AddItem(Value, 0) end)
            end
        elseif Connections_Manager['No Render'] then
            Connections_Manager['No Render']:Disconnect()
            Connections_Manager['No Render'] = nil
        end
    end})

local UA = Tabs.Misc:AddRightGroupbox("Unlock All", "unlock")
UA:AddButton({Text = "Load unlock all", Risky = true, DoubleClick = true,
    Tooltip = "Runs a third-party script from flowauth.net. Its code is not part of this repo.",
    Func = function()
        Notify("Unlock All", "Loading script...", 3)
        local success, err = pcall(function()
            loadstring(game:HttpGet("https://flowauth.net/v1/loaders/5d423493a8f0aa8432cda8455a5f8906.lua"))()
        end)
        if success then Notify("Unlock All", "Script loaded", 3)
        else Notify("Unlock All", "Error: " .. tostring(err), 5) end
    end})
UA:AddButton({Text = "Remove unlock UI", Func = function()
    task.spawn(function()
        local destroyed_count = 0
        local keywords = {"unlock", "unlocksuite", "flowauth", "flow", "authui", "hubui", "keyui", "keysystem", "key", "loader"}
        local function shouldDestroy(gui)
            local name = tostring(gui.Name):lower()
            for _, kw in ipairs(keywords) do
                if name:find(kw, 1, true) then return true end
            end
            return false
        end
        local function sweep(parent)
            if not parent then return end
            for _, gui in ipairs(parent:GetChildren()) do
                if gui:IsA("ScreenGui") and shouldDestroy(gui) then
                    if pcall(function() gui:Destroy() end) then destroyed_count = destroyed_count + 1 end
                end
            end
        end
        sweep(LocalPlayer:FindFirstChildOfClass("PlayerGui"))
        pcall(sweep, CoreGui)
        pcall(function() if gethui then sweep(gethui()) end end)
        pcall(function()
            for _, key in ipairs({"UnlockGui", "UnlockSuiteGui", "_usStandaloneUnlockGui", "unlockGui", "flowAuthGui", "FlowAuthUI", "FlowAuthUI_Standalone", "UnlockAllUI"}) do
                local gui = getgenv()[key]
                if typeof(gui) == "Instance" then
                    pcall(function() gui:Destroy() end)
                    destroyed_count = destroyed_count + 1
                    getgenv()[key] = nil
                end
            end
        end)
        if destroyed_count > 0 then
            Notify("Unlock All", "Removed " .. destroyed_count .. " UI", 2)
        else
            Notify("Unlock All", "No UI found", 3)
        end
    end)
end})

-- ============================================================
-- HOTKEYS
-- ============================================================
-- Spam, triggerbot and auto jump keys are key pickers on their toggles, and
-- the menu key is in Ui3's settings. Only the curve number keys live here.
local curveKeys = {
    [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
    [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
    [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
}
Library:GiveSignal(UserInputService.InputBegan:Connect(function(inp, gp)
    if gp or not System.__properties.__curve_hotkeys then return end
    local index = curveKeys[inp.KeyCode]
    local name = index and System.__config.__curve_names[index]
    if name then
        Options.CurveMode:SetValue(name)
        Notify("Curve Mode", name, 1)
    end
end))

-- ============================================================
-- UNLOAD
-- ============================================================
Library:OnUnload(function()
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
    pcall(uninstallRemoteHooks)
    System.autoparry.stop()
    setTriggerbot(false)
    System.__properties.__autoparry_enabled = false
    System.__properties.__manual_spam_enabled = false
    System.__properties.__auto_spam_enabled = false
    System.__properties.__show_ping = false
    AutoJump = false
    for _, conn in pairs(System.__properties.__connections) do pcall(function() conn:Disconnect() end) end
    for _, conn in pairs(Connections_Manager) do pcall(function() conn:Disconnect() end) end
    for _, gui in pairs(System.__properties.__mobile_guis) do destroy_mobile_gui(gui) end
    if System.__properties.__ball_velocity_gui then pcall(function() System.__properties.__ball_velocity_gui.gui:Destroy() end) end
    pcall(function() PingGui:Destroy() end)
    pcall(stop_ability_esp)
    getgenv().skinChanger = false
    getgenv().skinChangerEnabled = false
end)

-- The next copy calls this before it starts.
genv.__BladeBallShutdown = function()
    pcall(function() Library:Unload() end)
    if genv.__BladeBallInstance == INSTANCE then genv.__BladeBallInstance = nil end
end

-- Flight recorder: kick message, a heartbeat, and every toggle change.
do
    local GuiService = cloneref(game:GetService('GuiService'))
    local exec = "?"
    pcall(function() exec = table.concat({identifyexecutor()}, " ") end)
    flight(("==== v%s loaded | executor %s | place %s | userId %s"):format(
        SCRIPT_VERSION, exec, tostring(game.PlaceId), tostring(LocalPlayer.UserId)))
    local conns = {}
    table.insert(conns, GuiService.ErrorMessageChanged:Connect(function(msg)
        local reason = tostring(msg):match("BAC%s+%w-X(%d%d)")
        flight("!!!! KICK / ERROR MESSAGE: " .. tostring(msg) .. (reason and (" [reason " .. reason .. "]") or ""))
    end))
    table.insert(conns, Remotes.ParrySuccess.OnClientEvent:Connect(function() flight("ParrySuccess received") end))
    local function where()
        local char = LocalPlayer.Character
        local alive = char and char.Parent == Alive
        local balls = Workspace:FindFirstChild('Balls')
        return ("%s, %d ball(s)"):format(alive and "in match" or "lobby/dead", balls and #balls:GetChildren() or 0)
    end
    task.spawn(function()
        local on, last_spam, beat = {}, 0, 0
        while is_live() and not Library.Unloaded do
            for name, t in pairs(Toggles) do
                local v = type(t) == 'table' and t.Value == true
                if v ~= (on[name] == true) then
                    on[name] = v
                    flight(("toggle %s = %s"):format(tostring(name), v and "ON" or "OFF"))
                end
            end
            beat = beat + 1
            if beat % 5 == 0 or ParryLog.spam ~= last_spam then
                flight(("beat: %s | heap %dKB | sends %d, spam sends %d | modes parry=%s spam=%s | remote %s"):format(
                    where(), math.floor(gcinfo()), ParryLog.total, ParryLog.spam, tostring(getgenv().AutoParryMode),
                    tostring(getgenv().ManualSpamMode), remoteReady() and "armed" or tostring(Sender.info)))
                last_spam = ParryLog.spam
            end
            task.wait(1)
        end
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        flight("==== unloaded")
    end)
end

UIReady = true
Notify("Blade Ball", "Loaded. " .. (isMobile and "Tap the menu button to open." or "LeftControl toggles the menu."), 5)

end)
