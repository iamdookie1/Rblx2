-- Blade Ball Lite: auto parry and nothing else.
-- No UI library, no ESP, no spam, no file writes, no getgc, no upvalue reads,
-- and the game's own code is never called to parry.
--
-- How it parries (lite-2), the way first-parry auto parries do it:
--   1. YOU block once. The instant you touch the screen or press a key, a hook
--      goes on the remote's FireServer. The game's own parry packet passes
--      through it; the hook copies the remote, the BAC hash and your id, works
--      out the token key from the packet and the server time, and takes itself
--      off in that same call. If no parry comes within 0.4s it comes off anyway.
--      Nothing stays hooked, and debug.info is never touched.
--   2. From then on every parry is just that remote, fired with a fresh token,
--      the real window for your account, the game's press gate, and the game's
--      parry swing. Never the decoy remotes.
-- If the server stops accepting our parries, it forgets the capture and asks
-- for one more block. Re-executing stops the previous copy.

task.spawn(function()

local VERSION = "lite-2"
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
-- One-shot capture of a real parry packet
-- ------------------------------------------------------------
local Cap -- {remote, hash, uid, key = {bytes}, len, ball2}
local hookfunction_, restore_ = hookfunction, restorefunction
local newcclosure_ = newcclosure or function(f) return f end
local select_, type_, typeof_, tostring_, floor_, byte_, bxor_, pcall_ = select, type, typeof, tostring, math.floor, string.byte, bit32.bxor, pcall
local JOB_ID = game.JobId
local FIRE_FN
pcall(function() FIRE_FN = Instance.new("RemoteEvent").FireServer end)
local hook = {fn = nil, old = nil, until_t = 0}

local function unhook()
    local fn, old = hook.fn, hook.old
    if not fn then return end
    hook.fn, hook.old = nil, nil
    if not (restore_ and pcall_(restore_, fn)) then pcall_(hookfunction_, fn, old) end
end

-- token[i] = bxor((time_text[i] + i) % 256, key[i]), time_text = floor(server time * 100),
-- so key[i] = bxor(token[i], (time_text[i] + i) % 256).
local function learn(remote, hash, uid, token, a4)
    local text = tostring_(floor_(Workspace:GetServerTimeNow() * 100))
    if #token ~= #text then return end
    local key = {}
    for i = 1, #text do key[i] = bxor_(byte_(token, i), (byte_(text, i) + i) % 256) end
    Cap = {remote = remote, hash = hash, uid = uid, key = key, len = #text, ball2 = typeof_(a4) == "CFrame"}
end

-- Real parry: (hash, id, token, window, cameraCF, points, aim, flag) or on UseBall2
-- servers (hash, id, token, cameraCF, mouseCF, flag). The decoys send the
-- JobId first; they pass straight through.
local function hooked(self, ...)
    local old = hook.old
    if not Cap and select_('#', ...) >= 6 then
        pcall_(function(a1, a2, a3, a4, a5)
            if type_(a1) == 'string' and #a1 == 36 and a1 ~= JOB_ID and type_(a2) == 'string' and type_(a3) == 'string'
                and ((type_(a4) == 'number' and typeof_(a5) == 'CFrame') or (typeof_(a4) == 'CFrame' and typeof_(a5) == 'CFrame')) then
                learn(self, a1, a2, a3, a4)
            end
        end, ...)
    end
    if Cap then unhook() end
    return old(self, ...)
end

local function arm_hook()
    if Cap or not hookfunction_ or not FIRE_FN then return end
    hook.until_t = os.clock() + 0.4
    if hook.fn then return end
    local ok, old = pcall(hookfunction_, FIRE_FN, newcclosure_(hooked))
    if not ok or type(old) ~= 'function' then return end
    hook.fn, hook.old = FIRE_FN, old
    task.spawn(function()
        while hook.fn and os.clock() < hook.until_t do task.wait(0.05) end
        unhook()
    end)
end

local function make_token()
    local text = tostring(math.floor(Workspace:GetServerTimeNow() * 100))
    if #text ~= Cap.len then return nil end
    local out = table.create(#text)
    for i = 1, #text do out[i] = string.char(bit32.bxor((string.byte(text, i) + i) % 256, Cap.key[i])) end
    return table.concat(out)
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
-- Did the server take our parries? A sent parry with no ParrySuccess within
-- 0.6s is a miss; four in a row means the capture is stale.
local Check = {pending = nil, misses = 0}
local can_parry_ref
local conns = {}
local function on(sig, fn) local ok, c = pcall(function() return sig:Connect(fn) end); if ok then table.insert(conns, c) end end
pcall(function()
    on(Remotes.ParrySuccess.OnClientEvent, function()
        local char = LocalPlayer.Character
        if not (char and char:IsDescendantOf(Workspace)) then return end
        G.active, G.cool = false, false
        Check.pending, Check.misses = nil, 0
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

-- Your own press arms the one-shot hook: input reaches us before the game sends.
on(UserInputService.InputBegan, function(input)
    if Cap or not alive then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.Touch or t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.MouseButton1
        or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.Gamepad1 then
        -- only while a ball is in play, so random taps elsewhere never hook
        local live = false
        for _, name in ipairs({"Balls", "TrainingBalls"}) do
            local f = Workspace:FindFirstChild(name)
            if f and #f:GetChildren() > 0 then live = true end
        end
        if live and can_parry_ref and can_parry_ref(LocalPlayer.Character) then arm_hook() end
    end
end)

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
can_parry_ref = can_parry

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
    if not Cap then return false end
    if not Cap.remote.Parent then Cap = nil; return false end
    local tok = make_token()
    if not tok then Cap = nil; return false end
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
    local mouse = UserInputService:GetMouseLocation()
    local r, args = Cap.remote, nil
    if Cap.ball2 then
        local ray = cam:ScreenPointToRay(mouse.X, mouse.Y, 0)
        args = {Cap.hash, Cap.uid, tok, cam.CFrame, CFrame.lookAt(ray.Origin, ray.Origin + ray.Direction), false}
    else
        args = {Cap.hash, Cap.uid, tok, n6, cam.CFrame, screen_points(cam, char), {mouse.X, mouse.Y}, false}
    end
    -- both call shapes the game's sender uses, 50/50
    if math.random(1, 2) == 1 then
        r:FireServer(table.unpack(args))
    else
        local f = r.FireServer
        f(r, table.unpack(args))
    end
    Check.pending = os.clock()
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

local told_armed = false
local hb = RunService.Heartbeat:Connect(function()
    if not alive then return end
    if Cap and not told_armed then told_armed = true; notify("Armed from your block. Auto parry is live.") end
    if Check.pending and os.clock() - Check.pending > 0.6 then
        Check.pending, Check.misses = nil, Check.misses + 1
        if Check.misses >= 4 then
            Cap, told_armed, Check.misses = nil, false, 0
            notify("Parries stopped landing. Block once more to re-arm.")
        end
    end
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
    unhook()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
end

if not hookfunction_ then
    notify("This executor has no hookfunction, so lite-2 can't arm.")
else
    notify("Loaded (" .. VERSION .. "). Block once yourself to arm auto parry.")
end

end)
