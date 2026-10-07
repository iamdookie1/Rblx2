-- Blade Ball Lite: auto parry and nothing else.
-- No UI library, no ESP, no spam, no file writes, no hooks, no getgc.
-- A baseline: if this stays clean where the full script gets kicked, the kick
-- comes from something the full script adds, not from how it parries.
--
-- Parries through the game's own sender (require of SwordsController's PRY,
-- the cached module value), called the way the game calls it:
--   * on its own thread, at identity 2, with clean thread globals
--   * the game's press gate (window / lockout / landed-parry reset)
--   * the game's parry swing played right after each send
--   * the real per-account parry window
-- Re-executing stops the previous copy.

task.spawn(function()

local VERSION = "lite-1"
local genv = (getgenv and getgenv()) or _G
if type(genv.__BBLiteStop) == 'function' then pcall(genv.__BBLiteStop) end
local alive = true
genv.__BBLiteStop = function() alive = false end

repeat task.wait(0.5) until game:IsLoaded()

local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService('Players'))
local ReplicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local RunService = cloneref(game:GetService('RunService'))
local UserInputService = cloneref(game:GetService('UserInputService'))
local CollectionService = cloneref(game:GetService('CollectionService'))
local Stats = cloneref(game:GetService('Stats'))
local StarterGui = cloneref(game:GetService('StarterGui'))
local Workspace = cloneref(game:GetService('Workspace'))

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Alive = Workspace:WaitForChild("Alive")

local function notify(text)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", {Title = "Blade Ball Lite", Text = text, Duration = 5})
end

-- ------------------------------------------------------------
-- The game's own sender and a clean thread to call it on
-- ------------------------------------------------------------
local Sender
local CLEAN_ENV
do
    local ok, renv = pcall(function() return getrenv and getrenv() end)
    CLEAN_ENV = (ok and type(renv) == 'table' and renv.writefile == nil) and setmetatable({}, {__index = renv}) or {}
end
local setfenv_, pcall_, spawn_, unpack_ = setfenv, pcall, task.spawn, table.unpack
local setident_ = setthreadidentity or setidentity or set_thread_identity

-- The sender becomes the base frame of a fresh thread with clean globals and
-- identity 2: nothing of ours is anywhere on its stack.
local function call_clean(fn, ...)
    local n, args = select('#', ...), {...}
    spawn_(function()
        if not pcall_(setfenv_, 0, CLEAN_ENV) then return end
        if setident_ then pcall_(setident_, 2) end
        spawn_(fn, unpack_(args, 1, n))
    end)
end

local function get_sender()
    if Sender then return Sender end
    local ctrls = ReplicatedStorage:FindFirstChild("Controllers")
    if not ctrls then return nil end
    for _, c in ipairs(ctrls:GetChildren()) do
        if c.Name:match("^SwordsController") then
            local mod = c:FindFirstChild("PRY")
            if mod and mod:IsA("ModuleScript") then
                local ok, fn = pcall(require, mod)
                if ok and type(fn) == 'function' then
                    CLEAN_ENV.script = c
                    Sender = fn
                end
            end
        end
    end
    return Sender
end

-- ------------------------------------------------------------
-- The real parry window and lockout for this account
-- ------------------------------------------------------------
local Data, NoobBoost
task.spawn(function()
    pcall(function()
        local info = require(ReplicatedStorage:WaitForChild("ServerInfo", 10))
        local utils = require(ReplicatedStorage:WaitForChild("Common", 10):WaitForChild("Utils", 10))
        local function srv(name) local ok, r = pcall(function() return info[name]() end); return ok and r == true end
        NoobBoost = utils.FFlag.GetInstantFFlag("NoobParryEnabled", true) and not srv("isDungeonsMatchServer")
            and not srv("isRankedMatchServer") and not srv("isMedalServer") and not srv("isClanWarServer")
            and not srv("isTournamentMatchServer") and true or false
    end)
    pcall(function()
        local Replion = require(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Replion", 10))
        Data = Replion.Client:WaitReplion("Data")
    end)
end)

local function window()
    local tp = 5
    if Data then
        local ok, v = pcall(Data.Get, Data, "timesParried")
        if ok and type(v) == 'number' then tp = v end
    end
    local n6, n2, fresh = 0.5, 1.3, false
    if tp == 0 then n6, n2, fresh = 1.5, 1.5, true
    elseif tp == 1 then n6, n2, fresh = 1.25, 1.3, true
    elseif tp == 2 then n6, n2, fresh = 1, 1.3, true
    elseif tp == 3 then n6, fresh = 0.75, true
    elseif tp == 4 then n6, fresh = 0.625, true end
    if NoobBoost and Data then
        local ok, kills = pcall(Data.Get, Data, "TotalStats.Kills")
        kills = (ok and type(kills) == 'number') and kills or 0
        if kills >= 20 then NoobBoost = false else n2, n6 = kills / 20 * n2, kills / 20 * n6 end
    end
    return n6, n2, fresh, tp
end

-- ------------------------------------------------------------
-- The game's press gate (u40 window, u38 lockout, u39 after a landed parry)
-- ------------------------------------------------------------
local G = {active = false, cool = false, recent = false, m1 = false, n1 = 1.3}
local conns = {}
local function on(sig, fn) local ok, c = pcall(function() return sig:Connect(fn) end); if ok then table.insert(conns, c) end end
pcall(function()
    on(Remotes.ParrySuccess.OnClientEvent, function()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.active, G.cool = false, false
        task.spawn(function() G.recent = true; task.wait(G.n1); G.recent = false end)
    end)
end)
pcall(function()
    on(Remotes.NoobParryHappened.OnClientEvent, function()
        task.wait(0.11)
        G.cool, G.recent, G.active = false, false, false
    end)
end)
pcall(function() on(Remotes.M1Stop.Event, function(v) G.m1 = v end) end)

-- The game's own parry conditions (SwordsController).
local function can_parry(char)
    if not char or char:GetAttribute("Stunned") or char:GetAttribute("DoNotParry") then return false end
    local training = LocalPlayer:GetAttribute("LobbyTraining") and char.Parent == Workspace:FindFirstChild("Dead")
    if not (char.Parent == Alive or LocalPlayer:GetAttribute("LobbyParry") or training) then return false end
    if char:GetAttribute("ChargingAdrenaline") then
        local ok, qi = pcall(function() return LocalPlayer.Upgrades["Qi-Charge"].Value end)
        if ok and qi < 2 then return false end
    end
    if LocalPlayer:GetAttribute("LobbyParry") and LocalPlayer:GetAttribute("InLobbyParryCooldown") then return false end
    return true
end

-- ------------------------------------------------------------
-- The parry swing, as the game plays it around each send
-- ------------------------------------------------------------
local SwordAPI, AnimCtrl
pcall(function() SwordAPI = require(ReplicatedStorage.Shared.SwordAPI) end)
pcall(function() AnimCtrl = require(ReplicatedStorage.Controllers.AnimationController) end)
local sword_cache = {}
local function sword_info(name)
    name = name or ""
    if sword_cache[name] then return sword_cache[name] end
    local info = {collection = "Default", sword_type = "Single"}
    if name ~= "" then
        local ok, d = pcall(function() return ReplicatedStorage.Shared.ReplicatedInstances.Swords.GetSword:Invoke(name) end)
        if ok and type(d) == 'table' then
            info.collection = d.AnimationType or info.collection
            info.sword_type = d.SwordType or info.sword_type
        end
    end
    sword_cache[name] = info
    return info
end

local function swing_stop(animator)
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track:GetAttribute("SuccessParry") or track:GetAttribute("Parry") then
            track:Stop(track:GetAttribute("StopFadeTime"))
        end
    end
end

local function swing_play(char, animator, fresh, tp)
    if char:GetAttribute("InOverdriveMech") or not (SwordAPI and AnimCtrl) then return end
    local info = sword_info(char:GetAttribute("CurrentlyEquippedSword"))
    local ok, list = pcall(SwordAPI.GetAnimations, SwordAPI, char, {"Parry", "GrabParry"}, info.collection, info.sword_type)
    if not ok or type(list) ~= 'table' then return end
    for _, anim in ipairs(list) do
        local ok2, track = pcall(AnimCtrl.LoadAnimation, AnimCtrl, animator, anim, true)
        if ok2 and track then
            local speed = (fresh and tp / 5 + 1) or track:GetAttribute("PlaySpeed") or 1
            track:Play(fresh and 0.05 or track:GetAttribute("PlayFadeTime"), fresh and 1 or track:GetAttribute("PlayWeight"), speed)
            local left = track.Length == 0 and 1 or (track.Length - track.TimePosition) * speed
            pcall(char.SetAttribute, char, "ParryTime", math.max(char:GetAttribute("ParryTime") or 0, left))
        end
    end
end

-- ------------------------------------------------------------
-- One parry, exactly the game's press: gate, stop swings, send, swing
-- ------------------------------------------------------------
local function screen_points(cam, char)
    local t = {}
    local dead = Workspace:FindFirstChild("Dead")
    if dead and char.Parent == dead and LocalPlayer:GetAttribute("LobbyTraining") then
        for _, other in ipairs(dead:GetChildren()) do
            local plr = Players:GetPlayerFromCharacter(other)
            local hrp = other:FindFirstChild("HumanoidRootPart")
            if plr and hrp and plr:GetAttribute("LobbyTraining") then t[other.Name] = cam:WorldToScreenPoint(hrp.Position) end
        end
        for _, dummy in ipairs(CollectionService:GetTagged("LobbyTrainingTarget")) do
            t[dummy.Name] = cam:WorldToScreenPoint(dummy.Position)
        end
    else
        for _, e in ipairs(Alive:GetChildren()) do
            local hrp = e:FindFirstChild("HumanoidRootPart")
            if hrp then t[e.Name] = cam:WorldToScreenPoint(hrp.Position) end
        end
    end
    return t
end

local function parry()
    local char = LocalPlayer.Character
    if not can_parry(char) or G.m1 or G.active or G.cool then return false end
    local fn = get_sender()
    if not fn then return false end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return false end
    local n6, n2, fresh, tp = window()
    G.active, G.cool, G.n1 = true, true, n2
    task.delay(n6, function()
        G.active = false
        task.wait(math.max(0.1, n2 - n6))
        if not G.recent then G.cool = false end
    end)
    swing_stop(animator)
    local cam = Workspace.CurrentCamera
    local use_ball2 = false
    pcall(function() use_ball2 = require(ReplicatedStorage.Shared.UseBall2)() == true end)
    local mouse = UserInputService:GetMouseLocation()
    if use_ball2 then
        local ray = cam:ScreenPointToRay(mouse.X, mouse.Y, 0)
        call_clean(fn, cam.CFrame, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false)
    else
        call_clean(fn, n6, cam.CFrame, screen_points(cam, char), {mouse.X, mouse.Y}, false)
    end
    swing_play(char, animator, fresh, tp)
    return true
end

-- ------------------------------------------------------------
-- Auto parry: once per pass, when the ball is about to reach you
-- ------------------------------------------------------------
local function ping_s()
    local ok, p = pcall(function() return Stats.Network.ServerStatsItem['Data Ping']:GetValue() end)
    return (ok and p or 50) / 1000
end

local parried_pass = setmetatable({}, {__mode = 'k'}) -- ball -> true once parried this pass
local function balls()
    local list = {}
    for _, name in ipairs({"Balls", "TrainingBalls"}) do
        local folder = Workspace:FindFirstChild(name)
        if folder then
            for _, b in ipairs(folder:GetChildren()) do
                if b:GetAttribute("realBall") then list[#list + 1] = b end
            end
        end
    end
    return list
end

local hb = RunService.Heartbeat:Connect(function()
    if not alive then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    for _, ball in ipairs(balls()) do
        if ball:GetAttribute("target") == LocalPlayer.Name then
            if not parried_pass[ball] then
                local zoomies = ball:FindFirstChild("zoomies")
                local speed = zoomies and zoomies.VectorVelocity.Magnitude or ball.AssemblyLinearVelocity.Magnitude
                local dist = (ball.Position - root.Position).Magnitude
                -- reach time vs ping plus a small reaction margin
                if speed > 1 and dist / speed <= ping_s() + 0.15 + (speed > 150 and 0.05 or 0) then
                    if parry() then parried_pass[ball] = true end
                elseif dist < 12 then
                    if parry() then parried_pass[ball] = true end
                end
            end
        else
            parried_pass[ball] = nil -- the ball went to someone else: next pass at us is fresh
        end
    end
end)
table.insert(conns, hb)

genv.__BBLiteStop = function()
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
end

notify("Loaded (" .. VERSION .. "). Auto parry is on; re-execute to restart.")

end)
