--// PARKOUR Legacy -----------------------------------------------------------------
-- Built against a script dump of the live game (place 445664957).
--
-- All movement runs in one LocalScript, StarterPack.Main (re-created with every
-- character). It keeps its state in a few plain tables, found here with getgc:
--
--   stats  : maximum_walk_speed, walk_speed_multiplier, Respawning, ...
--   gear   : glide_stamina, LongfallBoot, AdrenalineBelt, ...
--   moves  : WallClimb {power, climbs_left}, LongJump {Useable},
--            Landing {FallDamageOverride}, ...
--
-- Rather than writing those values every frame and racing the game, a single key
-- is "pinned": it is moved behind a metatable, so the game's own reads get our
-- value while a feature is on. The game's writes are still kept, so switching
-- a feature off hands back exactly what the game would have had.
--
-- Fall damage is applied by the client itself: after landing, Main calls
-- humanoid:TakeDamage(n). Blocking that call (from game code, on your own
-- humanoid) is the whole of "no fall damage". Without hookmetamethod, pinning
-- Landing.FallDamageOverride makes Main reset the fall height every frame,
-- which covers everything short of a very fast fall.
--
-- Main also has a speed check. If WalkSpeed stays more than 50 above
-- maximum_walk_speed * walk_speed_multiplier for 250 frames, it kills you and
-- reports "walk" on FireToDieOverly. The speed boost here scales
-- walk_speed_multiplier, the same value the server sets through
-- SetWalkspeedMultiplier, so the game's limit rises with it and the check
-- never fires. For the same reason WalkSpeed and JumpPower are never written
-- directly.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Settings = {
    NoFall = false,
    Speed = 1,
    WallClimb = 12,
    InfWallClimbs = false,
    InfGlide = false,
    LongJumpAnytime = false,
}

local notify = function() end

--// Pins ----------------------------------------------------------------------------
-- pin(tbl, key, override): while override(real) returns non-nil, reads of
-- tbl[key] get that; otherwise they get the last value the game wrote.
local function pin(tbl, key, override)
    local mt = getmetatable(tbl)
    if mt == nil then
        local real, over = {}, {}
        mt = {
            real = real,
            over = over,
            __index = function(_, k)
                local f = over[k]
                if f then
                    local v = f(real[k])
                    if v ~= nil then return v end
                end
                return real[k]
            end,
            __newindex = function(t, k, v)
                if over[k] then real[k] = v else rawset(t, k, v) end
            end,
        }
        setmetatable(tbl, mt)
    elseif not mt.over then
        return false
    end
    if not mt.over[key] then
        mt.real[key] = rawget(tbl, key)
        rawset(tbl, key, nil)
    end
    mt.over[key] = override
    return true
end

--// Finding Main's tables -----------------------------------------------------------
local State = { stats = nil, gear = nil, moves = nil, attached = false, token = 0 }

-- Tables a previous character's Main left behind were pinned when found, so
-- they no longer match: pinned keys are gone from rawget, and the WallClimb
-- table has a metatable.
local function findTables()
    local stats, gear, moves
    for _, t in ipairs(getgc(true)) do
        if type(t) == "table" then
            if rawget(t, "walk_speed_multiplier") ~= nil and rawget(t, "maximum_walk_speed") ~= nil then
                stats = t
            elseif rawget(t, "glide_stamina") ~= nil and type(rawget(t, "LongfallBoot")) == "table" then
                gear = t
            else
                local wc, landing = rawget(t, "WallClimb"), rawget(t, "Landing")
                if type(wc) == "table" and type(landing) == "table" and rawget(wc, "climbs_left") ~= nil
                    and getmetatable(wc) == nil then
                    moves = t
                end
            end
        end
    end
    return stats, gear, moves
end

local function attach(stats, gear, moves)
    pin(stats, "walk_speed_multiplier", function(real)
        if Settings.Speed ~= 1 then return (real or 1) * Settings.Speed end
    end)
    pin(gear, "glide_stamina", function()
        if Settings.InfGlide then return 1 end
    end)
    pin(moves.WallClimb, "power", function(real)
        if Settings.WallClimb > 12 then return math.max(real or 12, Settings.WallClimb) end
    end)
    pin(moves.WallClimb, "climbs_left", function(real)
        if Settings.InfWallClimbs then return math.max(real or 0, 2) end
    end)
    if type(moves.LongJump) == "table" then
        pin(moves.LongJump, "Useable", function()
            if Settings.LongJumpAnytime then return true end
        end)
    end
    pin(moves.Landing, "FallDamageOverride", function()
        if Settings.NoFall then return true end
    end)
    State.stats, State.gear, State.moves = stats, gear, moves
    State.attached = true
end

local function hookCharacter()
    State.token = State.token + 1
    local token = State.token
    State.attached = false
    if not getgc then return end
    task.spawn(function()
        for _ = 1, 40 do
            task.wait(0.5)
            if token ~= State.token then return end
            local ok, stats, gear, moves = pcall(findTables)
            if ok and stats and gear and moves then
                attach(stats, gear, moves)
                return
            end
        end
        notify("Could not find the movement script's state - the game may have changed.", true)
    end)
end

--// No fall damage ------------------------------------------------------------------
local Hooked = false
if hookmetamethod and getnamecallmethod and checkcaller then
    local ok = pcall(function()
        local old
        local handler = function(self, ...)
            if Settings.NoFall and not checkcaller() and getnamecallmethod() == "TakeDamage" then
                local char = LocalPlayer.Character
                if char and typeof(self) == "Instance" and self.Parent == char then return end
            end
            return old(self, ...)
        end
        old = hookmetamethod(game, "__namecall", newcclosure and newcclosure(handler) or handler)
    end)
    Hooked = ok
end

LocalPlayer.CharacterAdded:Connect(hookCharacter)
if LocalPlayer.Character then hookCharacter() end

--// UI ---------------------------------------------------------------------------------
-- Void (VoidUI), loaded straight from the library repo. Resolving the latest
-- commit first means a fresh copy every load instead of the up-to-5-minute raw
-- cache; if the API call is blocked it falls back to the main branch.
local Void
do
    local ref = 'main'
    local resolved, shaOrError = pcall(function()
        local commit = game:GetService("HttpService"):JSONDecode(game:HttpGet('https://api.github.com/repos/iamdookie1/Ui2/commits/main'))
        return commit.sha
    end)
    if resolved and shaOrError then
        ref = shaOrError
    else
        warn('[Void] could not resolve the latest commit, falling back to main (raw.githubusercontent.com caches that for up to 5 minutes): ' .. tostring(shaOrError))
    end

    local url = ('https://raw.githubusercontent.com/iamdookie1/Ui2/%s/VoidUI.lua'):format(ref)
    Void = loadstring(game:HttpGet(url))()
end

local Window = Void:CreateWindow({
    Title = 'PARKOUR',
    SubTitle = 'legacy',
    Keybind = Enum.KeyCode.RightShift,
    Scope = 'game',
    Status = 'ready',
    StartOpen = true,
    Opener = 'Topbar',
})

notify = function(content, warn)
    Void:Notify({ Title = 'PARKOUR', Content = content, Duration = 5, Warn = warn == true })
end

if not getgc then
    notify('Your executor has no getgc - only no fall damage and respawn will work.', true)
end

local MoveTab = Window:CreateTab('movement')

local SafetySection = MoveTab:CreateSection('safety')
SafetySection:Toggle({
    Title = 'no fall damage',
    Flag = 'pk_no_fall',
    Default = false,
    Callback = function(v) Settings.NoFall = v end,
})

local MoveSection = MoveTab:CreateSection('movement')
MoveSection:Slider({
    Title = 'speed multiplier',
    Flag = 'pk_speed',
    Min = 1,
    Max = 3,
    Increment = 0.1,
    Default = 1,
    Suffix = 'x',
    Callback = function(v) Settings.Speed = v end,
})
MoveSection:Slider({
    Title = 'wall climb power',
    Flag = 'pk_wallclimb',
    Min = 12,
    Max = 40,
    Increment = 1,
    Default = 12,
    Callback = function(v) Settings.WallClimb = v end,
})
MoveSection:Toggle({
    Title = 'infinite wall climbs',
    Flag = 'pk_inf_climbs',
    Default = false,
    Callback = function(v) Settings.InfWallClimbs = v end,
})
MoveSection:Toggle({
    Title = 'infinite glide stamina',
    Flag = 'pk_inf_glide',
    Default = false,
    Callback = function(v) Settings.InfGlide = v end,
})
MoveSection:Toggle({
    Title = 'long jump without landing',
    Flag = 'pk_longjump',
    Default = false,
    Callback = function(v) Settings.LongJumpAnytime = v end,
})

local MiscSection = MoveTab:CreateSection('misc')
MiscSection:Button({
    Title = 'respawn',
    Callback = function()
        -- the game's own respawn keybind does exactly this
        if State.stats then State.stats.Respawning = true end
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 end
        task.spawn(function()
            task.wait()
            local remote = ReplicatedStorage:FindFirstChild("Respawn")
            if remote then remote:FireServer() end
        end)
    end,
})

local StatusLabel = MiscSection:Label('status: waiting for character')
task.spawn(function()
    while task.wait(1) do
        local parts = {}
        parts[#parts + 1] = State.attached and 'movement: hooked' or 'movement: searching'
        parts[#parts + 1] = Hooked and 'fall damage: blocked' or 'fall damage: height reset only'
        pcall(function() StatusLabel:SetText(table.concat(parts, '  |  ')) end)
    end
end)
