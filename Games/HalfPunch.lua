--// HALF PUNCH ---------------------------------------------------------------------------------
-- place 73547227876007 (game 10773149360), built against version 205. Built on Ui3.
-- What the game's client shows:
--   Fighters   every ragdoll (players and the Workspace.HalfPunchNPCs dummies) is a
--              Model tagged HP_Fighter with HP_Ready. Attributes: Consciousness,
--              ConsciousnessCap, HP_BruiseCount, Broken_LeftArm / RightArm / LeftLeg /
--              RightLeg / Upper, HP_God, HP_ArmLength, HP_StandHeight.
--   Physics    the client simulates the ragdoll (Controller module) and reports what
--              happened: Hit(myPart, theirPart, relativeVelocity) when a swing lands
--              (the client itself only sends hits between MinHitSpeed 5 and MaxHitSpeed 90,
--              one per HitCooldown 0.25 s per part), Grab(side, hand, part, point, id) /
--              Grab(side, nil) to let go, BodyHit(part, impulse, point, ...) for hitting
--              the world, SlamHit(theirPart, impulse, point) when someone you hold is
--              thrown into the world.
--   Read live  the Controller reads these off your character every frame:
--              HP_SpeedMult, HP_UpgradeSpeed, HP_UpgradeJump, HP_UpgradeEnergy,
--              HP_InfiniteStamina, HP_GrabStrength, HP_UpgradeGrabCooldown, Broken_*.
--              Everything else comes from the Config module (reach, stamina costs, wall
--              jump, fall angle...), which is read live too.
--   Keys       left / right mouse = punch, Q / E = grab, F = kick, Space = jump,
--              Shift = sprint, V = lock grab.
--   Upgrades   Remotes.Upgrade:InvokeServer(name, false) pays with KOCoins / KillCoins
--              (Config.upgradeCost); the free levels are Config.Upgrades[name].freeMax.
--   Modes      Remotes.GameMode:FireServer("SelectMode", "FFA" / "1v1" / "2v2"),
--              "Confirm", "Cancel", "Leave". Remotes.GiveUp gives up a match.
-- The server may check some of these (velocity, distance, god mode...), so the risky
-- ones are marked "test" in the menu and can be switched off independently.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__HalfPunchUnload then
    pcall(Genv.__HalfPunchUnload)
end
Genv.__HalfPunchRun = (Genv.__HalfPunchRun or 0) + 1
local RUN = Genv.__HalfPunchRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__HalfPunchRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
if not alive() then
    return
end

local Settings = {
    -- hit aura
    HitAura = false, HitRange = 10, HitDelay = 0.25, HitSpeed = 60, HitExtreme = false, HitExtremeSpeed = 5000,
    HitJitter = false, HitSpoof = false, SpoofFrames = 3, HitBurst = 1, HitPart = "Closest", HitAllParts = false,
    SlamAura = false, SlamImpulse = 5000, SlamRange = 14,
    -- grab
    AutoGrab = false, GrabAura = false, GrabRange = 7, ForceGrabUnlock = false, GrabStrengthOn = false, GrabStrength = 5,
    NoGrabCooldown = false,
    -- attack
    AutoPunch = false, AutoKick = false, PunchRange = 7, ReachOn = false, ReachMult = 1.6,
    AimLock = false, AimRange = 60, AimSmooth = 0.25, FaceTarget = false,
    -- targets
    IgnoreTeam = true, SkipKnockedOut = true, TargetNPCs = true, TargetPlayers = true,
    -- movement
    SpeedOn = false, SpeedMult = 2, JumpOn = false, JumpPower = 1.6, InfStamina = false,
    InfWallJump = false, AirSpinOn = false, AirSpin = 3, Fly = false, FlySpeed = 60, Noclip = false,
    -- defense
    AntiRagdoll = false, AntiKnockback = false, AntiBones = false, AntiGrab = false, God = false,
    -- esp
    Esp = false, EspNPCs = true, EspInfo = true, EspDistance = 500, ReachVisual = false,
    -- upgrades / modes
    AutoUpgrade = false, Mode = "FFA", AutoQueue = false, AutoConfirm = true, AutoGiveUp = false,
    -- utility
    AntiAfk = true, Fullbright = false, NoFog = false, NoBlood = false, NoFlash = false,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function loop(every, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[HALF PUNCH] " .. tostring(err))
            end
            task.wait(every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "HALF PUNCH", Description = text, Time = seconds or 3 })
end
local function myChar()
    return LocalPlayer.Character
end
local function myRoot()
    local c = myChar()
    return c and (c:FindFirstChild("UpperTorso") or c:FindFirstChild("HumanoidRootPart"))
end
local function myHum()
    local c = myChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function part(model, name)
    local p = model and model:FindFirstChild(name)
    return p and p:IsA("BasePart") and p or nil
end

local Remotes = ReplicatedStorage:WaitForChild("HalfPunch", 10) and ReplicatedStorage.HalfPunch:WaitForChild("Remotes", 10)
local function remote(name)
    return Remotes and Remotes:FindFirstChild(name)
end
local R = {
    Hit = remote("Hit"), Grab = remote("Grab"), SlamHit = remote("SlamHit"), Upgrade = remote("Upgrade"),
    GameMode = remote("GameMode"), GiveUp = remote("GiveUp"), Pref = remote("Pref"),
}
local Cfg, Ctrl
pcall(function()
    Cfg = require(ReplicatedStorage.HalfPunch:WaitForChild("Config", 5))
end)
pcall(function()
    Ctrl = require(ReplicatedStorage.HalfPunch:WaitForChild("Controller", 5))
end)

-- Attributes and Config values we change are put back when a feature is switched
-- off (or the script unloads), so nothing is left behind.
local Held = setmetatable({}, { __mode = "k" }) -- instance -> { attr = original }
local function attr(inst, name, enabled, value)
    if not inst then
        return
    end
    local h = Held[inst]
    if enabled then
        if not h then
            h = {}
            Held[inst] = h
        end
        if h[name] == nil then
            h[name] = { inst:GetAttribute(name) }
        end
        if inst:GetAttribute(name) ~= value then
            inst:SetAttribute(name, value)
        end
    elseif h and h[name] then
        inst:SetAttribute(name, h[name][1])
        h[name] = nil
    end
end
local CfgHeld = {}
local function cfg(key, enabled, value)
    if not Cfg then
        return
    end
    if enabled then
        if CfgHeld[key] == nil then
            CfgHeld[key] = { Cfg[key] }
        end
        Cfg[key] = value
    elseif CfgHeld[key] then
        Cfg[key] = CfgHeld[key][1]
        CfgHeld[key] = nil
    end
end
table.insert(Cleanups, function()
    for inst, h in Held do
        for name, orig in h do
            pcall(inst.SetAttribute, inst, name, orig[1])
        end
    end
    for key, orig in CfgHeld do
        if Cfg then
            Cfg[key] = orig[1]
        end
    end
end)

--// Fighters \\--
local BODY = {
    "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftHand", "RightHand", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot",
}
local ATTACK = { "RightHand", "LeftHand", "RightFoot", "LeftFoot", "RightLowerArm", "LeftLowerArm", "RightLowerLeg", "LeftLowerLeg" }
local Fighters = { list = {} }
do
    local function owner(model)
        return Players:GetPlayerFromCharacter(model)
    end
    function Fighters.knockedOut(model)
        local c = tonumber(model:GetAttribute("Consciousness"))
        local threshold = Cfg and tonumber(Cfg.KOThreshold) or 5
        return c ~= nil and c <= threshold
    end
    function Fighters.valid(model)
        if model == myChar() or not model.Parent then
            return false
        end
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then
            return false
        end
        local plr = owner(model)
        if plr then
            if not Settings.TargetPlayers then
                return false
            end
            if Settings.IgnoreTeam then
                local mine, theirs = LocalPlayer:GetAttribute("HP_Team"), plr:GetAttribute("HP_Team")
                if mine and mine ~= "" and mine == theirs then
                    return false
                end
            end
        elseif not Settings.TargetNPCs then
            return false
        end
        if Settings.SkipKnockedOut and Fighters.knockedOut(model) then
            return false
        end
        return true
    end
    -- All fighters, refreshed a few times a second.
    loop(0.2, function()
        local list, seen = {}, {}
        local function add(m)
            if m:IsA("Model") and not seen[m] and m:GetAttribute("HP_Ready") ~= nil and m:FindFirstChild("UpperTorso") then
                seen[m] = true
                table.insert(list, m)
            end
        end
        for _, m in CollectionService:GetTagged("HP_Fighter") do
            add(m)
        end
        local npcs = Workspace:FindFirstChild("HalfPunchNPCs")
        if npcs then
            for _, m in npcs:GetChildren() do
                add(m)
            end
        end
        Fighters.list = list
    end)
    function Fighters.targets()
        local out = {}
        for _, m in Fighters.list do
            if Fighters.valid(m) then
                table.insert(out, m)
            end
        end
        return out
    end
    function Fighters.nearest(maxDist)
        local root = myRoot()
        if not root then
            return nil
        end
        local best, bestD = nil, maxDist or math.huge
        for _, m in Fighters.targets() do
            local t = part(m, "UpperTorso")
            if t then
                local d = (t.Position - root.Position).Magnitude
                if d < bestD then
                    best, bestD = m, d
                end
            end
        end
        return best, bestD
    end
    function Fighters.closestPair(model, from)
        -- my attacking part and their part that are closest to each other
        local char = myChar()
        if not char then
            return nil
        end
        local theirs
        if Settings.HitPart == "Head" then
            theirs = { part(model, "Head") }
        elseif Settings.HitPart == "Torso" then
            theirs = { part(model, "UpperTorso") }
        elseif Settings.HitPart == "Random" then
            theirs = { part(model, BODY[math.random(#BODY)]) }
        else
            theirs = {}
            for _, n in BODY do
                local p = part(model, n)
                if p then
                    table.insert(theirs, p)
                end
            end
        end
        local best, bm, bt = math.huge, nil, nil
        for _, n in ATTACK do
            local mp = part(char, n)
            if mp then
                for _, tp in theirs do
                    local d = (mp.Position - tp.Position).Magnitude
                    if d < best then
                        best, bm, bt = d, mp, tp
                    end
                end
            end
        end
        return bm, bt, best
    end
end

--// Combat \\--
local Combat = { hits = 0, slams = 0, grabs = 0, info = "off" }
do
    local lastHit = {} -- model -> time
    local function velocity(from, to)
        local dir = to - from
        dir = dir.Magnitude > 0.01 and dir.Unit or Vector3.new(0, 0, -1)
        local speed = Settings.HitExtreme and Settings.HitExtremeSpeed or Settings.HitSpeed
        if Settings.HitJitter then
            speed *= 1 + (math.random() - 0.5) * 0.3
        end
        return dir * speed
    end
    -- Real velocity: the server can see how fast your hand is really moving (your
    -- parts replicate to it), so a hit that only claims a high velocity may be
    -- treated as an ordinary punch. Here the rest of your body is anchored (so you
    -- don't go anywhere), the hitting part is driven at the target at the chosen
    -- speed for a few frames, the hit is sent while it's moving, then everything is
    -- released and the part's velocity zeroed.
    local anchoredNow = {}
    function Combat.release()
        for p, was in anchoredNow do
            if p.Parent then
                p.Anchored = was
            end
        end
        table.clear(anchoredNow)
    end
    table.insert(Cleanups, Combat.release)
    function Combat.spoof(mp, targets)
        local char = myChar()
        if not (char and mp.Parent) then
            return
        end
        for _, n in BODY do
            local p = part(char, n)
            if p and p ~= mp and not p.Anchored then
                anchoredNow[p] = false
                p.Anchored = true
            end
        end
        local frames = math.max(1, math.floor(Settings.SpoofFrames))
        local fireAt = math.min(2, frames)
        for i = 1, frames do
            if not (alive() and mp.Parent) then
                break
            end
            local main = targets[1]
            local v = velocity(mp.Position, main.Position)
            mp.AssemblyLinearVelocity = v
            if i == fireAt then
                for _, t in targets do
                    for _ = 1, math.max(1, Settings.HitBurst) do
                        pcall(R.Hit.FireServer, R.Hit, mp, t, velocity(mp.Position, t.Position))
                        Combat.hits += 1
                    end
                end
            end
            RunService.Heartbeat:Wait()
        end
        if mp.Parent then
            mp.AssemblyLinearVelocity = Vector3.zero
        end
        Combat.release()
    end

    -- Hit aura: sends the same Hit(myPart, theirPart, relativeVelocity) a real swing
    -- sends, for every fighter in range. The velocity is what the game's damage is
    -- worked out from, so the high-velocity test just raises it past the 90 the
    -- real client caps at.
    loop(0.03, function()
        if not Settings.HitAura or not R.Hit then
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        local fired = 0
        for _, m in Fighters.targets() do
            local now = os.clock()
            if now - (lastHit[m] or 0) >= Settings.HitDelay then
                local mp, tp, d = Fighters.closestPair(m)
                if mp and tp and d <= Settings.HitRange then
                    lastHit[m] = now
                    local targets = { tp }
                    if Settings.HitAllParts then
                        targets = {}
                        for _, n in BODY do
                            local p = part(m, n)
                            if p then
                                table.insert(targets, p)
                            end
                        end
                    end
                    if Settings.HitSpoof then
                        -- the hit is sent while your hand really is moving that fast
                        if not Combat.spoofing then
                            Combat.spoofing = true
                            task.spawn(function()
                                pcall(Combat.spoof, mp, targets)
                                Combat.spoofing = false
                            end)
                            fired += #targets
                        end
                    else
                        for _, t in targets do
                            for _ = 1, math.max(1, Settings.HitBurst) do
                                pcall(R.Hit.FireServer, R.Hit, mp, t, velocity(mp.Position, t.Position))
                                Combat.hits += 1
                                fired += 1
                            end
                        end
                    end
                end
            end
        end
        Combat.info = fired > 0 and ("sent %d hits"):format(fired) or "nobody in range"
    end)

    -- Slam aura: what the game sends when someone you hold is thrown into a wall.
    loop(0.3, function()
        if not Settings.SlamAura or not R.SlamHit then
            return
        end
        local root = myRoot()
        if not root then
            return
        end
        for _, m in Fighters.targets() do
            local tp = part(m, BODY[math.random(#BODY)])
            if tp and (tp.Position - root.Position).Magnitude <= Settings.SlamRange then
                pcall(R.SlamHit.FireServer, R.SlamHit, tp, Settings.SlamImpulse, tp.Position)
                Combat.slams += 1
            end
        end
    end)

    -- Grab aura: Grab(side, myHand, theirPart, point, id) like the game's own grab.
    local serial = 100000
    local grabbed = {} -- side -> time
    loop(0.4, function()
        if not Settings.GrabAura or not R.Grab then
            return
        end
        local char = myChar()
        local target = Fighters.nearest(Settings.GrabRange)
        if not (char and target) then
            return
        end
        for _, side in { "Left", "Right" } do
            local hand = part(char, side .. "Hand")
            local tp = part(target, "UpperTorso")
            if hand and tp and os.clock() - (grabbed[side] or 0) > 2.5 then
                grabbed[side] = os.clock()
                serial += 1
                pcall(R.Grab.FireServer, R.Grab, side, hand, tp, tp.Position, serial)
                Combat.grabs += 1
                task.delay(1.5, function()
                    if alive() then
                        pcall(R.Grab.FireServer, R.Grab, side, nil)
                    end
                end)
            end
        end
    end)

    -- Auto punch / kick / grab: the game's own inputs, pressed for you.
    local function tap(key)
        if typeof(keypress) == "function" and typeof(keyrelease) == "function" then
            pcall(keypress, key)
            task.wait(0.05)
            pcall(keyrelease, key)
        end
    end
    local lastGrabKey = 0
    loop(0.12, function()
        if not (Settings.AutoPunch or Settings.AutoKick or Settings.AutoGrab) then
            return
        end
        local target, d = Fighters.nearest(math.max(Settings.PunchRange, Settings.GrabRange))
        if not target then
            return
        end
        if Settings.AutoPunch and d <= Settings.PunchRange and typeof(mouse1click) == "function" then
            pcall(mouse1click)
        end
        if Settings.AutoKick and d <= Settings.PunchRange then
            tap(0x46) -- F
        end
        if Settings.AutoGrab and d <= Settings.GrabRange and os.clock() - lastGrabKey > 3 then
            lastGrabKey = os.clock()
            tap(0x51) -- Q
            tap(0x45) -- E
        end
    end)

    -- Aim: the camera follows the nearest fighter, which is where the arms aim.
    bind(RunService.RenderStepped, function()
        if not alive() or not (Settings.AimLock or Settings.FaceTarget) then
            return
        end
        local cam = Workspace.CurrentCamera
        local root = myRoot()
        local target = cam and root and Fighters.nearest(Settings.AimRange)
        local tp = target and part(target, "UpperTorso")
        if not tp then
            return
        end
        if Settings.AimLock then
            cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, tp.Position), math.clamp(Settings.AimSmooth, 0.02, 1))
        end
    end)

    -- Reach: the Config's reach values scaled up (they are in cm, read live).
    local REACH = { "ArmMinReachCm", "ArmHorizontalReachCm", "ArmMaxReachCm", "ThrustReachCm", "ArmRestReachCm" }
    loop(0.25, function()
        for _, k in REACH do
            if Cfg and Cfg[k] then
                local base = CfgHeld[k] and CfgHeld[k][1] or Cfg[k]
                cfg(k, Settings.ReachOn, base * Settings.ReachMult)
            end
        end
    end)

    -- No grab cooldown / grab strength / unlocking the grab button.
    loop(0.2, function()
        local char = myChar()
        attr(char, "HP_UpgradeGrabCooldown", Settings.NoGrabCooldown, 0)
        attr(char, "HP_GrabStrength", Settings.GrabStrengthOn, Settings.GrabStrength)
        attr(LocalPlayer, "HP_GrabUnlocked", Settings.ForceGrabUnlock, true)
    end)
end

--// Movement and defense \\--
local Body = { info = "" }
do
    -- Everything the Controller reads off your character every frame.
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local char = myChar()
        if not char then
            return
        end
        attr(char, "HP_InfiniteStamina", Settings.InfStamina, true)
        attr(char, "HP_SpeedMult", Settings.SpeedOn, Settings.SpeedMult)
        attr(char, "HP_UpgradeJump", Settings.JumpOn, Settings.JumpPower)
        attr(char, "HP_God", Settings.God, true)
        attr(LocalPlayer, "Pref_AirSpin", Settings.AirSpinOn, Settings.AirSpin)
        if Settings.AntiBones then
            for _, limb in { "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Upper" } do
                if char:GetAttribute("Broken_" .. limb) then
                    char:SetAttribute("Broken_" .. limb, false)
                end
            end
        end
    end)

    -- Config tweaks: wall jump, ragdoll, stamina costs.
    local wallParts
    loop(0.25, function()
        if not Cfg then
            return
        end
        cfg("WallJumpCooldown", Settings.InfWallJump, 0)
        cfg("WallJumpWindow", Settings.InfWallJump, 2)
        cfg("WallJumpMaxNormalY", Settings.InfWallJump, 1)
        cfg("JumpCost", Settings.InfWallJump, 0)
        if type(Cfg.WallJumpParts) == "table" then
            if Settings.InfWallJump then
                wallParts = wallParts or {}
                for _, n in BODY do
                    if Cfg.WallJumpParts[n] == nil then
                        Cfg.WallJumpParts[n] = true
                        wallParts[n] = true
                    end
                end
            elseif wallParts then
                for n in wallParts do
                    Cfg.WallJumpParts[n] = nil
                end
                wallParts = nil
            end
        end
        cfg("FallAngle", Settings.AntiRagdoll, 179)
        cfg("FallAngleDown", Settings.AntiRagdoll, 179)
        cfg("KnockdownPush", Settings.AntiRagdoll, 0)
        cfg("BalanceFromRaw", Settings.AntiRagdoll, 1e9)
        cfg("BalanceToRaw", Settings.AntiRagdoll, 2e9)
        cfg("GetUpGain", Settings.AntiRagdoll, 30)
        cfg("CollapseMuscle", Settings.AntiRagdoll, 1)
    end)
    table.insert(Cleanups, function()
        if Cfg and wallParts and type(Cfg.WallJumpParts) == "table" then
            for n in wallParts do
                Cfg.WallJumpParts[n] = nil
            end
        end
    end)

    -- Anti knockback: the Controller's own "something hit me" handler is skipped.
    if Ctrl and type(Ctrl.receiveHit) == "function" then
        local original = Ctrl.receiveHit
        Ctrl.receiveHit = function(self, ...)
            if Settings.AntiKnockback and alive() then
                return
            end
            return original(self, ...)
        end
        table.insert(Cleanups, function()
            Ctrl.receiveHit = original
        end)
    end

    -- Anti grab: the grips other fighters hold you with are switched off on your side.
    loop(0.15, function()
        if not Settings.AntiGrab then
            return
        end
        local char = myChar()
        if not char then
            return
        end
        for _, m in Fighters.list do
            if m ~= char then
                for _, hand in { "LeftHand", "RightHand" } do
                    local h = part(m, hand)
                    if h then
                        for _, grip in h:GetChildren() do
                            if grip.Name:sub(1, 8) == "HP_Grip_" then
                                for _, c in grip:GetDescendants() do
                                    if c:IsA("Constraint") and c.Enabled then
                                        local a0, a1 = c.Attachment0, c.Attachment1
                                        if (a0 and a0:IsDescendantOf(char)) or (a1 and a1:IsDescendantOf(char)) then
                                            c.Enabled = false
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    -- Fly (WASD, Space up, Shift down) and noclip.
    bind(RunService.Heartbeat, function()
        if not alive() or not Settings.Fly then
            return
        end
        local char, cam = myChar(), Workspace.CurrentCamera
        if not (char and cam) then
            return
        end
        local move = Vector3.zero
        local function down(k)
            return UserInputService:IsKeyDown(k)
        end
        if down(Enum.KeyCode.W) then move += cam.CFrame.LookVector end
        if down(Enum.KeyCode.S) then move -= cam.CFrame.LookVector end
        if down(Enum.KeyCode.D) then move += cam.CFrame.RightVector end
        if down(Enum.KeyCode.A) then move -= cam.CFrame.RightVector end
        if down(Enum.KeyCode.Space) then move += Vector3.yAxis end
        if down(Enum.KeyCode.LeftShift) then move -= Vector3.yAxis end
        local v = move.Magnitude > 0 and move.Unit * Settings.FlySpeed or Vector3.zero
        for _, n in BODY do
            local p = part(char, n)
            if p then
                p.AssemblyLinearVelocity = v
            end
        end
    end)
    local noclipped = setmetatable({}, { __mode = "k" })
    bind(RunService.Stepped, function()
        if not alive() then
            return
        end
        local char = myChar()
        if not char then
            return
        end
        for _, d in char:GetDescendants() do
            if d:IsA("BasePart") then
                if Settings.Noclip then
                    if d.CanCollide then
                        noclipped[d] = true
                        d.CanCollide = false
                    end
                elseif noclipped[d] then
                    d.CanCollide = true
                    noclipped[d] = nil
                end
            end
        end
    end)
    table.insert(Cleanups, function()
        for p in noclipped do
            if p.Parent then
                p.CanCollide = true
            end
        end
    end)

    function Body.status()
        local char = myChar()
        if not char then
            return "No character"
        end
        local c, cap = tonumber(char:GetAttribute("Consciousness")), tonumber(char:GetAttribute("ConsciousnessCap"))
        local broken = {}
        for _, limb in { "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Upper" } do
            if char:GetAttribute("Broken_" .. limb) then
                table.insert(broken, limb)
            end
        end
        return ("Consciousness: %s / %s\nBruises: %s\nBroken: %s"):format(c and ("%.1f"):format(c) or "?", cap and ("%.1f"):format(cap) or "?",
            tostring(char:GetAttribute("HP_BruiseCount") or 0), #broken > 0 and table.concat(broken, ", ") or "none")
    end
end

--// ESP \\--
do
    local folder = Instance.new("Folder")
    folder.Name = "\0"
    folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    table.insert(Cleanups, function()
        folder:Destroy()
    end)
    local marks = {}
    local function drop(m)
        m.bb:Destroy()
        m.hl:Destroy()
    end
    local ring
    loop(0.2, function()
        for _, m in marks do
            m.seen = false
        end
        local root = myRoot()
        if Settings.Esp and root then
            for _, model in Fighters.list do
                local tp = part(model, "UpperTorso")
                local plr = Players:GetPlayerFromCharacter(model)
                local isMe = model == myChar()
                if tp and not isMe and (plr or Settings.EspNPCs) then
                    local d = (tp.Position - root.Position).Magnitude
                    if d <= Settings.EspDistance then
                        local ko = Fighters.knockedOut(model)
                        local mine, theirs = LocalPlayer:GetAttribute("HP_Team"), plr and plr:GetAttribute("HP_Team")
                        local color = ko and Color3.fromRGB(150, 150, 150)
                            or (plr and mine and mine ~= "" and mine == theirs) and Color3.fromRGB(90, 200, 255)
                            or plr and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(255, 170, 60)
                        local lines = { ("%s [%dm]"):format(plr and plr.DisplayName or model.Name, d) }
                        if Settings.EspInfo then
                            local c, cap = tonumber(model:GetAttribute("Consciousness")), tonumber(model:GetAttribute("ConsciousnessCap"))
                            if c then
                                table.insert(lines, ("%d / %d%s"):format(c, cap or 100, ko and " KO" or ""))
                            end
                            local broken = {}
                            for _, limb in { "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Upper" } do
                                if model:GetAttribute("Broken_" .. limb) then
                                    table.insert(broken, limb)
                                end
                            end
                            if #broken > 0 then
                                table.insert(lines, "broken: " .. table.concat(broken, ", "))
                            end
                            local bruises = tonumber(model:GetAttribute("HP_BruiseCount"))
                            if bruises and bruises > 0 then
                                table.insert(lines, bruises .. " bruises")
                            end
                        end
                        local m = marks[model]
                        if not m then
                            local bb = Instance.new("BillboardGui")
                            bb.AlwaysOnTop = true
                            bb.Size = UDim2.fromOffset(200, 60)
                            bb.StudsOffset = Vector3.new(0, 3.5, 0)
                            bb.MaxDistance = math.huge
                            bb.Adornee = tp
                            bb.Parent = folder
                            local label = Instance.new("TextLabel")
                            label.BackgroundTransparency = 1
                            label.Size = UDim2.fromScale(1, 1)
                            label.Font = Enum.Font.GothamBold
                            label.TextSize = 12
                            label.TextStrokeTransparency = 0.35
                            label.Parent = bb
                            local hl = Instance.new("Highlight")
                            hl.Adornee = model
                            hl.FillTransparency = 0.75
                            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                            hl.Parent = folder
                            m = { bb = bb, hl = hl, label = label, tp = tp }
                            marks[model] = m
                        end
                        m.seen = true
                        m.label.Text = table.concat(lines, "\n")
                        m.label.TextColor3 = color
                        m.hl.FillColor, m.hl.OutlineColor = color, color
                    end
                end
            end
        end
        for k, m in marks do
            if not m.seen or not k.Parent then
                drop(m)
                marks[k] = nil
            end
        end
        -- the reach visual: a ball as big as the hit aura's range
        if Settings.ReachVisual and root then
            if not ring then
                ring = Instance.new("Part")
                ring.Shape = Enum.PartType.Ball
                ring.Anchored = true
                ring.CanCollide, ring.CanQuery, ring.CanTouch = false, false, false
                ring.Material = Enum.Material.ForceField
                ring.Color = Color3.fromRGB(255, 80, 80)
                ring.Transparency = 0.6
                ring.Parent = folder
            end
            ring.Size = Vector3.one * Settings.HitRange * 2
            ring.CFrame = CFrame.new(root.Position)
        elseif ring then
            ring:Destroy()
            ring = nil
        end
    end)
end

--// Upgrades and modes \\--
local Meta = { bought = 0, info = "" }
do
    -- Free upgrade levels, bought with the coins you earn (KOCoins / KillCoins).
    loop(1.5, function()
        if not (Settings.AutoUpgrade and R.Upgrade and Cfg and type(Cfg.Upgrades) == "table") then
            return
        end
        for _, name in Cfg.UpgradeOrder or {} do
            local up = Cfg.Upgrades[name]
            local level = tonumber(LocalPlayer:GetAttribute("Upgrade_" .. name)) or 0
            local free = up and tonumber(up.freeMax) or 0
            if level < free and type(Cfg.upgradeCost) == "function" then
                local cost, coin = Cfg.upgradeCost(level + 1)
                if (tonumber(LocalPlayer:GetAttribute(coin)) or 0) >= cost then
                    local ok, done, why = pcall(R.Upgrade.InvokeServer, R.Upgrade, name, false)
                    if ok and done then
                        Meta.bought += 1
                        Meta.info = ("bought %s %d"):format(name, level + 1)
                    else
                        Meta.info = ("%s: %s"):format(name, tostring(why))
                    end
                    task.wait(0.4)
                end
            end
        end
    end)

    local function inMatch()
        return (tonumber(LocalPlayer:GetAttribute("HP_MatchId")) or 0) ~= 0
    end
    function Meta.queue()
        if R.GameMode then
            R.GameMode:FireServer("SelectMode", Settings.Mode)
            if Settings.AutoConfirm then
                task.wait(0.4)
                R.GameMode:FireServer("Confirm")
            end
        end
    end
    loop(6, function()
        if Settings.AutoQueue and not inMatch() then
            Meta.queue()
            Meta.info = "queued " .. Settings.Mode
        end
    end)
    loop(1, function()
        if Settings.AutoGiveUp and inMatch() and R.GiveUp then
            local c = tonumber(LocalPlayer.Character and LocalPlayer.Character:GetAttribute("Consciousness")) or 100
            if c <= 10 then
                R.GiveUp:FireServer()
            end
        end
    end)
end

--// Utilities \\--
do
    local saved, fog
    bind(RunService.RenderStepped, function()
        if not alive() then
            return
        end
        if Settings.Fullbright or Settings.NoFog then
            if not saved then
                saved = {
                    Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
                    GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
                }
                fog = {}
            end
            if Settings.Fullbright then
                Lighting.Brightness = 2
                Lighting.ClockTime = 14
                Lighting.GlobalShadows = false
                Lighting.Ambient = Color3.fromRGB(180, 180, 180)
                Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
            end
            Lighting.FogEnd = 1e6
            for _, e in Lighting:GetChildren() do
                if e:IsA("Atmosphere") and e.Density > 0 then
                    fog[e] = fog[e] or e.Density
                    e.Density = 0
                end
            end
        elseif saved then
            for k, v in saved do
                pcall(function()
                    Lighting[k] = v
                end)
            end
            for e, d in fog do
                if e.Parent then
                    e.Density = d
                end
            end
            saved, fog = nil, nil
        end
    end)
    table.insert(Cleanups, function()
        if saved then
            for k, v in saved do
                pcall(function()
                    Lighting[k] = v
                end)
            end
            for e, d in fog do
                if e.Parent then
                    e.Density = d
                end
            end
        end
    end)

    -- The game's own settings, sent the way its settings menu sends them.
    loop(1, function()
        if R.Pref then
            if Settings.NoBlood and LocalPlayer:GetAttribute("Pref_Blood") ~= false then
                R.Pref:FireServer("Blood", false)
            end
            if Settings.NoFlash and LocalPlayer:GetAttribute("Pref_Flash") ~= false then
                R.Pref:FireServer("Flash", false)
            end
        end
    end)

    local idled = {}
    loop(2, function()
        if typeof(getconnections) ~= "function" then
            return
        end
        if Settings.AntiAfk then
            for _, c in getconnections(LocalPlayer.Idled) do
                if not idled[c] and pcall(c.Disable, c) then
                    idled[c] = true
                end
            end
        elseif next(idled) then
            for c in idled do
                pcall(c.Enable, c)
            end
            table.clear(idled)
        end
    end)
    table.insert(Cleanups, function()
        for c in idled do
            pcall(c.Enable, c)
        end
    end)
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "HALF PUNCH",
    Footer = "dookie hub · Ui3",
    Icon = "gem",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/HalfPunch",
})
local function toggle(box, key, text, tip, after)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
            if after then
                after(v)
            end
        end,
    })
end
local function slider(box, key, text, min, max, rounding, suffix, tip)
    return box:AddSlider(key, {
        Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function dropdown(box, key, text, values, tip)
    return box:AddDropdown(key, {
        Text = text, Values = values, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
        end,
    })
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.4)
        end
    end)
end

do
    local Tab = Window:AddTab("Combat", "hammer", "Hit aura, slam, grab, aim")
    local H = Tab:AddLeftGroupbox("Hit aura", "zap")
    toggle(H, "HitAura", "Hit aura", "Sends the game's own Hit for every fighter in range, no swing needed")
    slider(H, "HitRange", "Range", 2, 80, 0, " studs", "How close you must be (a real swing is ~3). The server may check this")
    slider(H, "HitDelay", "Delay per target", 0.02, 1, 2, " s", "The game's own is 0.25")
    dropdown(H, "HitPart", "Hit", { "Closest", "Head", "Torso", "Random" })
    toggle(H, "HitAllParts", "Hit every part at once", "One hit per body part per round")
    slider(H, "HitBurst", "Hits per round", 1, 20, 0, "", "Test: repeats the same hit")
    slider(H, "HitSpeed", "Velocity", 5, 90, 0, "", "Normal swings are 5 to 90")
    toggle(H, "HitExtreme", "Very high velocity (test)", "Uses the slider below instead, far past what a real swing reaches")
    slider(H, "HitExtremeSpeed", "High velocity", 100, 1000000, 0, "", "Damage and knockback are worked out from this. The server may clamp or reject it")
    toggle(H, "HitSpoof", "Real velocity (test)", "Anchors the rest of you and really drives the hitting hand at the target at the velocity above while the hit is sent. Use this if high velocities only act like a normal punch")
    slider(H, "SpoofFrames", "Real velocity frames", 1, 10, 0, "", "How many frames the hand is driven. More frames is more likely to be seen by the server but moves the arm more")
    toggle(H, "HitJitter", "Randomise velocity", "+/- 15% so hits aren't identical")
    status(H, function()
        return ("Hits sent: %d\n%s"):format(Combat.hits, Combat.info)
    end)
    local S = Tab:AddRightGroupbox("Slam and grab", "hand")
    toggle(S, "SlamAura", "Slam aura (test)", "Sends the hit the game sends when you throw someone into a wall")
    slider(S, "SlamImpulse", "Slam impulse", 700, 1000000, 0, "", "The game ignores anything under 666")
    slider(S, "SlamRange", "Slam range", 3, 80, 0, " studs")
    toggle(S, "GrabAura", "Grab aura (test)", "Sends Grab for the nearest fighter, lets go after 1.5 s")
    toggle(S, "AutoGrab", "Auto grab keys", "Presses Q and E when someone is close")
    slider(S, "GrabRange", "Grab range", 3, 40, 0, " studs")
    toggle(S, "NoGrabCooldown", "No grab cooldown", "The 30 s fighter-grab cooldown is set to 0 on your side")
    toggle(S, "GrabStrengthOn", "Grab strength")
    slider(S, "GrabStrength", "Strength", 0.6, 100, 1, "x", "The game's top is 100")
    toggle(S, "ForceGrabUnlock", "Unlock grab button", "Skips the 'join the group' lock (the server may still say no)")
    status(S, function()
        return ("Slams: %d · grabs: %d"):format(Combat.slams, Combat.grabs)
    end)
    local A = Tab:AddRightGroupbox("Auto attack", "hammer")
    toggle(A, "AutoPunch", "Auto punch", "Clicks while someone is in range")
    toggle(A, "AutoKick", "Auto kick", "Presses F while someone is in range")
    slider(A, "PunchRange", "Range", 3, 30, 0, " studs")
    toggle(A, "ReachOn", "Longer reach", "Arm and thrust reach are scaled up")
    slider(A, "ReachMult", "Reach", 1, 6, 1, "x")
    toggle(A, "AimLock", "Camera lock", "Your arms aim where the camera does")
    slider(A, "AimRange", "Lock range", 10, 300, 0, " studs")
    slider(A, "AimSmooth", "Lock smoothing", 0.02, 1, 2, "", "Lower is smoother")
    local T = Tab:AddLeftGroupbox("Targets", "eye")
    toggle(T, "TargetPlayers", "Players")
    toggle(T, "TargetNPCs", "Dummies and NPC fighters")
    toggle(T, "IgnoreTeam", "Skip my team")
    toggle(T, "SkipKnockedOut", "Skip knocked out fighters")
end

do
    local Tab = Window:AddTab("Movement", "footprints", "Speed, jump, fly, defense")
    local M = Tab:AddLeftGroupbox("Movement", "footprints")
    toggle(M, "SpeedOn", "Speed")
    slider(M, "SpeedMult", "Speed", 1, 10, 1, "x")
    toggle(M, "JumpOn", "Jump power")
    slider(M, "JumpPower", "Jump", 0.85, 6, 2, "x", "The game starts at 0.85")
    toggle(M, "InfStamina", "Infinite stamina")
    toggle(M, "InfWallJump", "Infinite wall jump", "Any body part, no cooldown, no cost")
    toggle(M, "AirSpinOn", "Air spin")
    slider(M, "AirSpin", "Spin", 1, 10, 1, "x")
    toggle(M, "Fly", "Fly", "WASD, Space up, Shift down")
    slider(M, "FlySpeed", "Fly speed", 10, 200, 0, "")
    toggle(M, "Noclip", "Noclip")
    local D = Tab:AddRightGroupbox("Defense", "shield")
    toggle(D, "AntiRagdoll", "Anti ragdoll / quick get up", "You stay on your feet and get up fast")
    toggle(D, "AntiKnockback", "Anti knockback", "The game's own 'I got hit' response is skipped")
    toggle(D, "AntiBones", "Anti bone break", "Broken limbs are mended every frame")
    toggle(D, "AntiGrab", "Anti grab (test)", "Switches off the grips holding you")
    toggle(D, "God", "God mode (test)", "Sets the game's own HP_God flag on you; the server probably owns it")
    status(D, Body.status)
end

do
    local Tab = Window:AddTab("ESP", "eye", "Fighters")
    local E = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(E, "Esp", "Fighters", "Players red, teammates blue, dummies orange, knocked out grey")
    toggle(E, "EspNPCs", "Include dummies")
    toggle(E, "EspInfo", "Consciousness, broken limbs and bruises")
    toggle(E, "ReachVisual", "Hit range ball", "A ball as big as the hit aura's range")
    slider(E, "EspDistance", "Max distance", 50, 2000, 0, " studs")
end

do
    local Tab = Window:AddTab("Progress", "truck", "Upgrades and modes")
    local U = Tab:AddLeftGroupbox("Upgrades", "zap")
    toggle(U, "AutoUpgrade", "Auto buy free upgrades", "Buys every free level you can pay for with KO and kill coins; never the Robux ones")
    status(U, function()
        return ("Bought: %d\n%s\nKO coins: %s · kill coins: %s"):format(Meta.bought, Meta.info ~= "" and Meta.info or "-",
            tostring(LocalPlayer:GetAttribute("KOCoins") or 0), tostring(LocalPlayer:GetAttribute("KillCoins") or 0))
    end)
    local G = Tab:AddRightGroupbox("Game modes", "map")
    dropdown(G, "Mode", "Mode", { "FFA", "1v1", "2v2" })
    toggle(G, "AutoQueue", "Auto queue", "Selects the mode and confirms every few seconds while you're not in a match")
    toggle(G, "AutoConfirm", "Confirm after selecting")
    toggle(G, "AutoGiveUp", "Give up when nearly out", "Leaves a match when your consciousness drops to 10")
    G:AddButton({ Text = "Queue now", Func = function()
        task.spawn(Meta.queue)
    end })
    G:AddButton({ Text = "Leave queue", Func = function()
        if R.GameMode then
            R.GameMode:FireServer("Leave")
        end
    end })
    G:AddButton({ Text = "Give up match", Func = function()
        if R.GiveUp then
            R.GiveUp:FireServer()
        end
    end })
end

do
    local Tab = Window:AddTab("Misc", "settings", "Utilities")
    local M = Tab:AddLeftGroupbox("Utilities", "settings")
    toggle(M, "AntiAfk", "Anti-AFK")
    toggle(M, "Fullbright", "Fullbright")
    toggle(M, "NoFog", "No fog or rain haze")
    toggle(M, "NoBlood", "No blood", "Uses the game's own blood setting")
    toggle(M, "NoFlash", "No flash", "Uses the game's own flash setting")
    M:AddButton({ Text = "Reset character", Func = function()
        local hum = myHum()
        if hum then
            hum.Health = 0
        end
    end })
    M:AddButton({ Text = "Unload", Func = function()
        if Genv.__HalfPunchUnload then
            Genv.__HalfPunchUnload()
        end
    end })
end

--// Unload \\--
local function cleanup()
    if Unloaded then
        return
    end
    Unloaded = true
    for _, c in Connections do
        pcall(c.Disconnect, c)
    end
    for i = #Cleanups, 1, -1 do
        pcall(Cleanups[i])
    end
end
Library:OnUnload(cleanup)
Genv.__HalfPunchUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(Cfg and "Loaded" or "Loaded (game config not found: some options are off)", 4)
