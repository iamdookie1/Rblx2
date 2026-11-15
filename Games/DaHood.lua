--// Da Hood --------------------------------------------------------------------------------------
-- place 2788229376 (game 1008451066). Built on Ui3.
--
-- How the game works (as the client sees it):
--   Guns     every gun's LocalScript (GunClient / GunClientShotgun /
--            GunClientAutomatic) runs on Tool.Activated, asks
--            Modules.GunHandler.getAim(muzzle) for the direction, raycasts it
--            itself in GunHandler.shoot() and sends the result with
--            MainEvent:FireServer("ShootGun", handle, origin, hitPos, hitPart,
--            normal, ...). The direction is looked up on the module table
--            every shot, so changing getAim changes where every gun shoots.
--   Aim      Framework also streams your mouse point to the server
--            ("UpdateMousePosI2", up to 20x a second) and, when the server
--            runs SERVER_AIM mode, the server shoots at that point instead.
--   Stomp    MainEvent "Stomp" stomps whoever is knocked under you.
--   Block    MainEvent "Block", true/false.  Reload: MainEvent "Reload", tool.
--   States   character.BodyEffects: K.O, Dead, Grabbed, Reload, Attacking,
--            Cuff, MousePos (where that player is aiming), Armor.
--   Crews    player.DataFolder.Information.Crew.Value.
--
-- Anti-cheat this script stays clear of:
--   * KeyRelay: when the server turns "Logging" on, every key you press is
--     reported. Nothing here presses keys; it calls the game's own code.
--   * CHECKER_1 / CHECKER_2: any BodyVelocity / BodyGyro / BodyPosition /
--     BodyMover / LinearVelocity put in your character is reported. Fly and
--     speed here only set velocity / CFrame.
--   * CHECKER_3: an anchored Head kicks you. Nothing here anchors anything.
--   * CHECKER_4: a gun's Grip changing is reported. Nothing here touches Grip.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__DaHoodUnload then
    pcall(Genv.__DaHoodUnload)
end
Genv.__DaHoodRun = (Genv.__DaHoodRun or 0) + 1
local RUN = Genv.__DaHoodRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__DaHoodRun == RUN
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

local IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local Settings = {
    -- silent aim / camlock
    SilentAim = false, SpoofServerAim = true, HitChance = 100,
    CamLock = false, CamSmooth = 5, AimWhen = "Always",
    AimPart = "Head", AimFOV = 150, ShowFOV = true, FOVColor = Color3.fromRGB(255, 255, 255),
    AimMaxDistance = 300, VisibleOnly = true, SkipKnocked = true, SkipCrew = true, SkipForceField = true,
    StickyTarget = true, ShowTarget = true,
    -- prediction
    Prediction = true, PredictionMs = 110, LeadPing = true, PredictY = false,
    -- triggerbot
    Triggerbot = false, TriggerDelayMin = 40, TriggerDelayMax = 90, TriggerOnSilentTarget = false,
    -- guns
    AutoReload = true,
    -- melee
    AutoStomp = false, StompTeleport = false, StompRange = 12, StompCrew = false,
    AutoBlock = false, BlockRange = 14, BlockGunAim = true, BlockMelee = true, BlockOnlyNoGun = true,
    AntiStomp = false,
    -- movement
    Speed = false, SpeedAmount = 12, Fly = false, FlySpeed = 50, Noclip = false, InfJump = false,
    -- esp
    Esp = false, EspBox = true, EspName = true, EspHealth = true, EspDistance = true, EspTool = true,
    EspTracer = false, EspAimLines = false, EspMax = 700, EspCrew = true, EspArmor = true,
    EnemyColor = Color3.fromRGB(255, 70, 70), CrewColor = Color3.fromRGB(90, 170, 255),
    KnockedColor = Color3.fromRGB(255, 200, 60), AimLineColor = Color3.fromRGB(255, 120, 255),
    -- money
    AutoPickup = false, PickupRange = 12, PickupTeleport = false, PickupTeleportRange = 60, CashEsp = false,
    CashColor = Color3.fromRGB(90, 255, 120),
    -- misc
    AntiAfk = true,
}

--// Plumbing \\--
local Connections, Cleanups = {}, {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Da Hood", Description = text, Time = seconds or 3 })
end
local function loop(rate, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then
                warn("[Da Hood] " .. tostring(err))
            end
            task.wait(rate)
        end
    end)
end
local function myChar()
    return LocalPlayer.Character
end
local function myRoot()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function camera()
    return Workspace.CurrentCamera
end

--// Drawing helpers \\--
local Draw = {}
do
    Draw.ok = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
    local all = {}
    function Draw.new(kind, props)
        if not Draw.ok then
            return nil
        end
        local ok, d = pcall(Drawing.new, kind)
        if not ok then
            return nil
        end
        for k, v in props or {} do
            pcall(function()
                d[k] = v
            end)
        end
        table.insert(all, d)
        return d
    end
    function Draw.remove(d)
        if d then
            pcall(d.Remove, d)
            local i = table.find(all, d)
            if i then
                table.remove(all, i)
            end
        end
    end
    table.insert(Cleanups, function()
        for _, d in all do
            pcall(d.Remove, d)
        end
        table.clear(all)
    end)
end

--// The game \\--
local Game = {}
do
    Game.MainEvent = ReplicatedStorage:WaitForChild("MainEvent", 10)

    local function findGunHandler()
        local mod = ReplicatedStorage:FindFirstChild("Modules") and ReplicatedStorage.Modules:FindFirstChild("GunHandler")
        if mod then
            local ok, t = pcall(require, mod)
            if ok and type(t) == "table" and type(rawget(t, "getAim")) == "function" then
                return t
            end
        end
        if typeof(getgc) == "function" then
            for _, v in getgc(true) do
                if type(v) == "table" and type(rawget(v, "getAim")) == "function" and type(rawget(v, "shoot")) == "function"
                    and type(rawget(v, "shotgunSpread")) == "function" then
                    return v
                end
            end
        end
        return nil
    end
    Game.Gun = findGunHandler()

    function Game.fire(...)
        if Game.MainEvent then
            Game.MainEvent:FireServer(...)
        end
    end
    function Game.effects(char)
        return char and char:FindFirstChild("BodyEffects")
    end
    local function val(be, name)
        local v = be and be:FindFirstChild(name)
        if v then
            return v.Value
        end
        return nil
    end
    Game.val = val
    function Game.knocked(char)
        return val(Game.effects(char), "K.O") == true
    end
    function Game.dead(char)
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        return val(Game.effects(char), "Dead") == true or not hum or hum.Health <= 0
    end
    function Game.grabbed(char)
        return char and char:FindFirstChild("GRABBING_CONSTRAINT") ~= nil
    end
    function Game.crew(player)
        local ok, v = pcall(function()
            return player.DataFolder.Information.Crew.Value
        end)
        if ok and v and v ~= "" then
            return tostring(v)
        end
        return nil
    end
    function Game.sameCrew(player)
        local a, b = Game.crew(LocalPlayer), Game.crew(player)
        return a ~= nil and a == b
    end
    -- The gun you're holding (a Tool with Ammo), or nil.
    function Game.gun()
        local c = myChar()
        local tool = c and c:FindFirstChildOfClass("Tool")
        if tool and tool:FindFirstChild("Ammo") and tool:FindFirstChild("Handle") then
            return tool
        end
        return nil
    end
    function Game.cash()
        local ok, v = pcall(function()
            return LocalPlayer.DataFolder.Currency.Value
        end)
        return ok and tonumber(v) or nil
    end
end

--// Targets \\--
local Targets = {}
do
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true

    local PARTS = {
        Head = { "Head" },
        Torso = { "UpperTorso", "Torso", "HumanoidRootPart" },
        Root = { "HumanoidRootPart" },
    }
    function Targets.part(char, which)
        if which == "Closest to aim" then
            local cam = camera()
            if not cam then
                return char:FindFirstChild("Head")
            end
            local centre = Targets.aimCentre()
            local best, bestD
            for _, n in { "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "LeftUpperArm", "RightUpperArm" } do
                local p = char:FindFirstChild(n)
                if p then
                    local sp, on = cam:WorldToViewportPoint(p.Position)
                    if on then
                        local d = (Vector2.new(sp.X, sp.Y) - centre).Magnitude
                        if not bestD or d < bestD then
                            best, bestD = p, d
                        end
                    end
                end
            end
            return best or char:FindFirstChild("Head")
        end
        for _, n in PARTS[which] or PARTS.Head do
            local p = char:FindFirstChild(n)
            if p then
                return p
            end
        end
        return nil
    end
    -- Where the game aims from on screen: the mouse on PC, the middle of the
    -- screen on mobile (the game aims from the camera there) and in shift lock.
    function Targets.aimCentre()
        local cam = camera()
        if IsTouch or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
            return cam.ViewportSize / 2
        end
        return UserInputService:GetMouseLocation()
    end
    function Targets.visible(part, char)
        local cam = camera()
        local me = myChar()
        local ignore = { char, cam }
        if me then
            table.insert(ignore, me)
        end
        local ign = Workspace:FindFirstChild("Ignored")
        if ign then
            table.insert(ignore, ign)
        end
        params.FilterDescendantsInstances = ignore
        local from = cam.CFrame.Position
        return Workspace:Raycast(from, part.Position - from, params) == nil
    end
    function Targets.list()
        local out = {}
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer then
                local c = p.Character
                local root = c and c:FindFirstChild("HumanoidRootPart")
                local hum = c and c:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    table.insert(out, { player = p, char = c, root = root, hum = hum })
                end
            end
        end
        return out
    end
    function Targets.valid(t)
        if Game.dead(t.char) then
            return false
        end
        if Settings.SkipKnocked and Game.knocked(t.char) then
            return false
        end
        if Settings.SkipCrew and Game.sameCrew(t.player) then
            return false
        end
        if Settings.SkipForceField and (t.char:FindFirstChildOfClass("ForceField") or t.char:FindFirstChild("FORCEFIELD")) then
            return false
        end
        return true
    end
end

--// Prediction \\--
local Lead = {}
function Lead.point(part, root)
    if not part then
        return nil
    end
    local pos = part.Position
    if not Settings.Prediction then
        return pos
    end
    local vel = root and root.AssemblyLinearVelocity or part.AssemblyLinearVelocity
    if not Settings.PredictY then
        vel = Vector3.new(vel.X, math.clamp(vel.Y, -10, 10) * 0.5, vel.Z)
    end
    local t = Settings.PredictionMs / 1000
    if Settings.LeadPing then
        local ok, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
        if ok and ping then
            t += ping
        end
    end
    return pos + vel * t
end

--// Aim (target picking, silent aim, camlock) \\--
local Aim = { target = nil, point = nil, info = "off" }
do
    local fov = Draw.new("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Transparency = 0.8, Visible = false })
    local mark = Draw.new("Circle", { Thickness = 2, NumSides = 16, Radius = 5, Filled = false, Visible = false })

    local function active()
        if Settings.AimWhen == "Always" then
            return true
        end
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end
    local function score(t, centre, cam, root)
        if not Targets.valid(t) then
            return nil
        end
        if root and (t.root.Position - root.Position).Magnitude > Settings.AimMaxDistance then
            return nil
        end
        local part = Targets.part(t.char, Settings.AimPart)
        if not part then
            return nil
        end
        local sp, on = cam:WorldToViewportPoint(part.Position)
        if not on then
            return nil
        end
        local d = (Vector2.new(sp.X, sp.Y) - centre).Magnitude
        if d > Settings.AimFOV then
            return nil
        end
        if Settings.VisibleOnly and not Targets.visible(part, t.char) then
            return nil
        end
        return d, part
    end
    function Aim.pick()
        local cam = camera()
        if not cam then
            return nil
        end
        local centre = Targets.aimCentre()
        local root = myRoot()
        local list = Targets.list()
        if Settings.StickyTarget and Aim.target then
            for _, t in list do
                if t.player == Aim.target.player then
                    local d, part = score(t, centre, cam, root)
                    if d then
                        t.part = part
                        return t
                    end
                end
            end
        end
        local best, bestD
        for _, t in list do
            local d, part = score(t, centre, cam, root)
            if d and (not bestD or d < bestD) then
                t.part = part
                best, bestD = t, d
            end
        end
        return best
    end

    bind(RunService.RenderStepped, function()
        local cam = camera()
        local using = alive() and (Settings.SilentAim or Settings.CamLock or Settings.Triggerbot)
        if fov then
            fov.Visible = using and Settings.ShowFOV and cam ~= nil
            if fov.Visible then
                fov.Radius = Settings.AimFOV
                fov.Position = Targets.aimCentre()
                fov.Color = Aim.target and Settings.EnemyColor or Settings.FOVColor
            end
        end
        if not (using and cam and active()) then
            Aim.target, Aim.point = nil, nil
            Aim.info = using and "waiting (hold right click)" or "off"
            if mark then
                mark.Visible = false
            end
            return
        end
        local t = Aim.pick()
        Aim.target = t
        Aim.point = t and Lead.point(t.part, t.root) or nil
        Aim.info = t and ("on %s"):format(t.player.DisplayName) or "no target in the circle"
        if mark then
            local show = Settings.ShowTarget and Aim.point ~= nil
            if show then
                local sp, on = cam:WorldToViewportPoint(Aim.point)
                mark.Visible = on
                mark.Position = Vector2.new(sp.X, sp.Y)
                mark.Color = Settings.EnemyColor
            else
                mark.Visible = false
            end
        end
        -- Camlock: turns your real camera (works on mobile too).
        if Settings.CamLock and Aim.point then
            local cf = cam.CFrame
            local goal = CFrame.lookAt(cf.Position, Aim.point)
            local a = 1 / math.max(1, Settings.CamSmooth)
            cam.CFrame = cf:Lerp(goal, a)
        end
    end)

    -- Hit chance: rolled at most every 0.15s so all pellets of one shotgun
    -- blast agree.
    local rollAt, rollOk = 0, true
    function Aim.rolled()
        if Settings.HitChance >= 100 then
            return true
        end
        local now = os.clock()
        if now - rollAt > 0.15 then
            rollAt = now
            rollOk = math.random(1, 100) <= Settings.HitChance
        end
        return rollOk
    end
    function Aim.silentPoint()
        if alive() and Settings.SilentAim and Aim.point and Aim.rolled() then
            return Aim.point
        end
        return nil
    end
end

--// Silent aim: the game's own GunHandler.getAim \\--
local Silent = { status = "not installed", shots = 0 }
do
    local Gun = Game.Gun
    if Gun then
        Genv.__DaHoodOrigGetAim = Genv.__DaHoodOrigGetAim or rawget(Gun, "getAim")
        local original = Genv.__DaHoodOrigGetAim
        Gun.getAim = function(origin, range, ...)
            local point = Aim.silentPoint()
            if point and typeof(origin) == "Vector3" then
                local d = point - origin
                if d.Magnitude > 0.01 then
                    Silent.shots += 1
                    return d.Unit, d.Magnitude
                end
            end
            return original(origin, range, ...)
        end
        table.insert(Cleanups, function()
            Gun.getAim = original
        end)
        Silent.status = "hooked GunHandler.getAim"
    else
        Silent.status = "GunHandler not found"
    end

    -- The mouse point the game streams to the server (UpdateMousePosI2), used
    -- by SERVER_AIM servers and to line up your aim with your shots.
    Genv.__DaHoodHook = Genv.__DaHoodHook or {}
    local H = Genv.__DaHoodHook
    H.point = function()
        if Settings.SpoofServerAim then
            return Aim.silentPoint()
        end
        return nil
    end
    H.run = RUN
    table.insert(Cleanups, function()
        H.point = nil
    end)
    if not H.installed and typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
        local ok = pcall(function()
            local old
            old = hookmetamethod(game, "__namecall", function(self, ...)
                local fn = H.point
                if fn and getnamecallmethod() == "FireServer" then
                    local a1 = ...
                    if a1 == "UpdateMousePosI2" and not (typeof(checkcaller) == "function" and checkcaller()) then
                        local ok2, p = pcall(fn)
                        if ok2 and typeof(p) == "Vector3" then
                            local args = table.pack(...)
                            args[2] = p
                            return old(self, table.unpack(args, 1, args.n))
                        end
                    end
                end
                return old(self, ...)
            end)
        end)
        H.installed = ok
    end
    Silent.serverAim = H.installed and "hooked" or "not available (no hookmetamethod)"
end

--// Triggerbot \\--
local Trigger = { shots = 0, info = "off" }
do
    local onSince, delay = nil, 0
    local lastShot = 0
    local function onEnemy()
        local hit = Mouse.Target
        if IsTouch or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
            local cam = camera()
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            local ign = { myChar(), Workspace:FindFirstChild("Ignored") }
            params.FilterDescendantsInstances = ign
            local r = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 500, params)
            hit = r and r.Instance
        end
        local node = hit
        while node and node ~= Workspace do
            local p = Players:GetPlayerFromCharacter(node)
            if p then
                if p ~= LocalPlayer then
                    return Targets.valid({ player = p, char = node })
                end
                break
            end
            node = node.Parent
        end
        if Settings.TriggerOnSilentTarget and Settings.SilentAim and Aim.point then
            return true
        end
        return false
    end
    bind(RunService.Heartbeat, function()
        if not (alive() and Settings.Triggerbot) then
            Trigger.info = "off"
            onSince = nil
            return
        end
        local tool = Game.gun()
        if not tool then
            Trigger.info = "no gun out"
            onSince = nil
            return
        end
        if tool.Ammo.Value <= 0 then
            Trigger.info = "empty"
            return
        end
        if not onEnemy() then
            Trigger.info = "waiting"
            onSince = nil
            return
        end
        local now = os.clock()
        if not onSince then
            onSince = now
            delay = math.random(Settings.TriggerDelayMin, math.max(Settings.TriggerDelayMin, Settings.TriggerDelayMax)) / 1000
        end
        if now - onSince < delay then
            Trigger.info = "reacting"
            return
        end
        local cd = tool:FindFirstChild("ShootingCooldown")
        cd = cd and cd.Value or 0.1
        if now - lastShot < cd + 0.02 then
            return
        end
        lastShot = now
        Trigger.shots += 1
        Trigger.info = "shooting"
        pcall(tool.Activate, tool)
    end)
end

--// Guns: auto reload \\--
local Reload = { count = 0 }
loop(0.25, function()
    if not Settings.AutoReload then
        return
    end
    local tool = Game.gun()
    if not tool or tool.Ammo.Value > 0 then
        return
    end
    local be = Game.effects(myChar())
    if Game.val(be, "Reload") == true then
        return
    end
    Game.fire("Reload", tool)
    Reload.count += 1
    task.wait(1)
end)

--// Stomp / block / anti-stomp \\--
local Melee = { stomps = 0, info = "off" }
do
    local function nearestKnocked(range)
        local root = myRoot()
        if not root then
            return nil
        end
        local best, bestD
        for _, t in Targets.list() do
            if Game.knocked(t.char) and not Game.dead(t.char) and not Game.grabbed(t.char)
                and (Settings.StompCrew or not Game.sameCrew(t.player)) then
                local d = (t.root.Position - root.Position).Magnitude
                if d <= range and (not bestD or d < bestD) then
                    best, bestD = t, d
                end
            end
        end
        return best, bestD
    end
    loop(0.2, function()
        if not Settings.AutoStomp then
            Melee.info = "off"
            return
        end
        local me = myChar()
        local root = myRoot()
        if not root or Game.knocked(me) or Game.dead(me) then
            return
        end
        local t, d = nearestKnocked(Settings.StompTeleport and Settings.StompRange or 4.5)
        if not t then
            Melee.info = "nobody knocked nearby"
            return
        end
        local torso = t.char:FindFirstChild("UpperTorso") or t.root
        local back
        if Settings.StompTeleport and d > 2.5 then
            back = root.CFrame
            root.CFrame = CFrame.new(torso.Position + Vector3.new(0, 3, 0)) * (root.CFrame - root.CFrame.Position)
            root.AssemblyLinearVelocity = Vector3.zero
            task.wait(0.08)
        end
        Melee.info = "stomping " .. t.player.DisplayName
        Game.fire("Stomp")
        Melee.stomps += 1
        task.wait(0.45)
        if back and root.Parent then
            root.CFrame = back
        end
        task.wait(0.6)
    end)

    -- Auto block: someone close is aiming a gun at you, or swinging at you.
    local blocking = false
    local function setBlock(on)
        if on ~= blocking then
            blocking = on
            Game.fire("Block", on)
        end
    end
    table.insert(Cleanups, function()
        if blocking then
            pcall(setBlock, false)
        end
    end)
    loop(0.05, function()
        if not Settings.AutoBlock then
            setBlock(false)
            return
        end
        local me = myChar()
        local root = myRoot()
        if not root or Game.knocked(me) or Game.dead(me) or (Settings.BlockOnlyNoGun and Game.gun()) then
            setBlock(false)
            return
        end
        local threat = false
        for _, t in Targets.list() do
            if not Game.knocked(t.char) and not Game.sameCrew(t.player) then
                local d = (t.root.Position - root.Position).Magnitude
                if d <= Settings.BlockRange then
                    local be = Game.effects(t.char)
                    local tool = t.char:FindFirstChildOfClass("Tool")
                    if Settings.BlockGunAim and tool and tool:FindFirstChild("Ammo") then
                        local mp = Game.val(be, "MousePos")
                        if typeof(mp) == "Vector3" and (mp - root.Position).Magnitude < 6 then
                            threat = true
                        end
                    end
                    if Settings.BlockMelee and Game.val(be, "Attacking") == true and d <= 9 then
                        threat = true
                    end
                end
            end
            if threat then
                break
            end
        end
        setBlock(threat)
    end)

    -- Anti stomp: once you're knocked, die straight away so nobody gets the stomp.
    loop(0.1, function()
        if not Settings.AntiStomp then
            return
        end
        local me = myChar()
        if me and Game.knocked(me) and not Game.dead(me) then
            local hum = me:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function()
                    hum.Health = 0
                end)
                pcall(hum.ChangeState, hum, Enum.HumanoidStateType.Dead)
            end
            task.wait(1)
        end
    end)
end

--// Movement \\--
do
    local flyUp = 0
    bind(UserInputService.InputBegan, function(i, gpe)
        if gpe then
            return
        end
        if i.KeyCode == Enum.KeyCode.Space then
            flyUp = 1
        elseif i.KeyCode == Enum.KeyCode.LeftControl then
            flyUp = -1
        end
    end)
    bind(UserInputService.InputEnded, function(i)
        if i.KeyCode == Enum.KeyCode.Space or i.KeyCode == Enum.KeyCode.LeftControl then
            flyUp = 0
        end
    end)
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        local c = myChar()
        local root = c and c:FindFirstChild("HumanoidRootPart")
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not (root and hum) or hum.Health <= 0 then
            return
        end
        local move = hum.MoveDirection
        if Settings.Fly then
            local cam = camera()
            local dir = Vector3.zero
            if move.Magnitude > 0 then
                -- Follow the camera's pitch so looking up flies up (mobile friendly).
                local look = cam.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                local along = flat.Magnitude > 0 and move:Dot(flat.Unit) or 0
                dir = move + Vector3.new(0, look.Y * along, 0)
            end
            dir += Vector3.new(0, flyUp, 0)
            if hum.Jump then
                dir += Vector3.new(0, 1, 0)
            end
            root.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * Settings.FlySpeed or Vector3.zero
            return
        end
        if Settings.Speed and move.Magnitude > 0 then
            root.CFrame += move * Settings.SpeedAmount * dt
        end
    end)
    local noclipped = {}
    bind(RunService.Stepped, function()
        if not (alive() and Settings.Noclip) then
            if next(noclipped) then
                for p in noclipped do
                    if p.Parent then
                        p.CanCollide = true
                    end
                end
                table.clear(noclipped)
            end
            return
        end
        local c = myChar()
        if not c then
            return
        end
        for _, p in c:GetDescendants() do
            if p:IsA("BasePart") and p.CanCollide then
                p.CanCollide = false
                noclipped[p] = true
            end
        end
    end)
    bind(UserInputService.JumpRequest, function()
        if alive() and Settings.InfJump then
            local c = myChar()
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end)
end

--// ESP \\--
do
    local pool = {}
    local function make()
        return {
            box = Draw.new("Square", { Thickness = 1.5, Filled = false, Visible = false }),
            name = Draw.new("Text", { Size = 14, Center = true, Outline = true, Visible = false }),
            info = Draw.new("Text", { Size = 13, Center = true, Outline = true, Visible = false }),
            hpBack = Draw.new("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
            hp = Draw.new("Line", { Thickness = 2, Visible = false }),
            tracer = Draw.new("Line", { Thickness = 1, Visible = false }),
            aim = Draw.new("Line", { Thickness = 1.5, Visible = false }),
        }
    end
    local function hide(e)
        for _, d in e do
            if d then
                d.Visible = false
            end
        end
    end
    local function free(e)
        for _, d in e do
            Draw.remove(d)
        end
    end
    bind(Players.PlayerRemoving, function(p)
        if pool[p] then
            free(pool[p])
            pool[p] = nil
        end
    end)
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local root = myRoot()
        local on = alive() and Settings.Esp and Draw.ok and cam
        local seen = {}
        if on then
            for _, t in Targets.list() do
                local p = t.player
                seen[p] = true
                local e = pool[p]
                if not e then
                    e = make()
                    pool[p] = e
                end
                local crew = Game.sameCrew(p)
                local dist = root and (t.root.Position - root.Position).Magnitude or 0
                if dist > Settings.EspMax or (crew and not Settings.EspCrew) then
                    hide(e)
                    continue
                end
                local cf = t.root.CFrame
                local top, onTop = cam:WorldToViewportPoint((cf * CFrame.new(0, 3, 0)).Position)
                local bot, onBot = cam:WorldToViewportPoint((cf * CFrame.new(0, -3.5, 0)).Position)
                if not (onTop or onBot) or top.Z < 0 then
                    hide(e)
                    continue
                end
                local knocked = Game.knocked(t.char)
                local colour = knocked and Settings.KnockedColor or crew and Settings.CrewColor or Settings.EnemyColor
                local h = math.abs(bot.Y - top.Y)
                local w = h * 0.55
                local x, y = top.X - w / 2, top.Y
                if e.box then
                    e.box.Visible = Settings.EspBox
                    e.box.Position = Vector2.new(x, y)
                    e.box.Size = Vector2.new(w, h)
                    e.box.Color = colour
                end
                if e.name then
                    e.name.Visible = Settings.EspName
                    e.name.Text = p.DisplayName .. (knocked and " [KO]" or Game.grabbed(t.char) and " [GRABBED]" or "")
                    e.name.Position = Vector2.new(top.X, y - 16)
                    e.name.Color = colour
                end
                if e.info then
                    local bits = {}
                    if Settings.EspDistance then
                        table.insert(bits, ("%dm"):format(dist))
                    end
                    if Settings.EspTool then
                        local tool = t.char:FindFirstChildOfClass("Tool")
                        if tool then
                            table.insert(bits, tool.Name)
                        end
                    end
                    if Settings.EspArmor then
                        local armor = Game.val(Game.effects(t.char), "Armor")
                        if tonumber(armor) and armor > 0 then
                            table.insert(bits, ("armor %d"):format(armor))
                        end
                    end
                    e.info.Visible = #bits > 0
                    e.info.Text = table.concat(bits, " · ")
                    e.info.Position = Vector2.new(top.X, y + h + 2)
                    e.info.Color = Color3.new(1, 1, 1)
                end
                if e.hp and e.hpBack then
                    local frac = math.clamp(t.hum.Health / math.max(1, t.hum.MaxHealth), 0, 1)
                    e.hpBack.Visible = Settings.EspHealth
                    e.hp.Visible = Settings.EspHealth
                    e.hpBack.From = Vector2.new(x - 5, y + h)
                    e.hpBack.To = Vector2.new(x - 5, y)
                    e.hp.From = Vector2.new(x - 5, y + h)
                    e.hp.To = Vector2.new(x - 5, y + h - h * frac)
                    e.hp.Color = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 255, 90), frac)
                end
                if e.tracer then
                    e.tracer.Visible = Settings.EspTracer
                    e.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                    e.tracer.To = Vector2.new(bot.X, bot.Y)
                    e.tracer.Color = colour
                end
                if e.aim then
                    local mp = Game.val(Game.effects(t.char), "MousePos")
                    local head = t.char:FindFirstChild("Head")
                    local show = Settings.EspAimLines and head and typeof(mp) == "Vector3" and mp.Magnitude > 1
                        and t.char:FindFirstChildOfClass("Tool") ~= nil
                    if show then
                        local a, onA = cam:WorldToViewportPoint(head.Position)
                        local b, onB = cam:WorldToViewportPoint(mp)
                        show = (onA or onB) and a.Z > 0 and b.Z > 0
                        e.aim.From = Vector2.new(a.X, a.Y)
                        e.aim.To = Vector2.new(b.X, b.Y)
                        e.aim.Color = Settings.AimLineColor
                    end
                    e.aim.Visible = show and true or false
                end
            end
        end
        for p, e in pool do
            if not seen[p] then
                hide(e)
            end
        end
    end)
end

--// Money: cash drops \\--
local Money = { picked = 0 }
do
    local function drops()
        local out = {}
        local ign = Workspace:FindFirstChild("Ignored")
        local folder = ign and ign:FindFirstChild("Drop")
        if not folder then
            return out
        end
        for _, d in folder:GetChildren() do
            if d.Name == "MoneyDrop" and d:IsA("BasePart") then
                local cd = d:FindFirstChildOfClass("ClickDetector")
                if cd then
                    table.insert(out, { part = d, cd = cd })
                end
            end
        end
        return out
    end
    Money.drops = drops
    local canClick = typeof(fireclickdetector) == "function"
    loop(0.15, function()
        if not (Settings.AutoPickup and canClick) then
            return
        end
        local root = myRoot()
        local me = myChar()
        if not root or Game.knocked(me) or Game.dead(me) then
            return
        end
        for _, d in drops() do
            local dist = (d.part.Position - root.Position).Magnitude
            if dist <= math.min(Settings.PickupRange, d.cd.MaxActivationDistance) then
                pcall(fireclickdetector, d.cd)
                Money.picked += 1
                task.wait(0.05)
            elseif Settings.PickupTeleport and dist <= Settings.PickupTeleportRange then
                local back = root.CFrame
                root.CFrame = CFrame.new(d.part.Position + Vector3.new(0, 2.5, 0))
                root.AssemblyLinearVelocity = Vector3.zero
                task.wait(0.15)
                pcall(fireclickdetector, d.cd)
                Money.picked += 1
                task.wait(0.15)
                if root.Parent then
                    root.CFrame = back
                end
                task.wait(0.3)
                return
            end
        end
    end)

    local labels = {}
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local on = alive() and Settings.CashEsp and Draw.ok and cam
        local used = 0
        if on then
            local root = myRoot()
            for _, d in drops() do
                local sp, vis = cam:WorldToViewportPoint(d.part.Position)
                if vis then
                    used += 1
                    local l = labels[used]
                    if not l then
                        l = Draw.new("Text", { Size = 13, Center = true, Outline = true })
                        labels[used] = l
                    end
                    if l then
                        local dist = root and (d.part.Position - root.Position).Magnitude or 0
                        l.Visible = true
                        l.Text = ("$ %dm"):format(dist)
                        l.Position = Vector2.new(sp.X, sp.Y)
                        l.Color = Settings.CashColor
                    end
                end
            end
        end
        for i = used + 1, #labels do
            if labels[i] then
                labels[i].Visible = false
            end
        end
    end)
end

--// Shop \\--
local Shop = {}
do
    -- Shop items are models named "[Item] - $price" (ammo: "12 [Revolver Ammo] - $56").
    function Shop.items()
        local out = {}
        local ign = Workspace:FindFirstChild("Ignored")
        local folder = ign and ign:FindFirstChild("Shop")
        if not folder then
            return out
        end
        for _, m in folder:GetChildren() do
            local cd = m:FindFirstChildWhichIsA("ClickDetector", true)
            if cd then
                local label, price = m.Name:match("^(.-)%s*%-%s*%$(%d+)")
                table.insert(out, { model = m, cd = cd, label = label or m.Name, price = tonumber(price) or 0 })
            end
        end
        return out
    end
    function Shop.names()
        local seen, list = {}, {}
        for _, it in Shop.items() do
            if not seen[it.label] then
                seen[it.label] = true
                table.insert(list, it.label)
            end
        end
        table.sort(list)
        return list
    end
    local function pos(it)
        local ok, cf = pcall(it.model.GetPivot, it.model)
        if ok and cf then
            return cf.Position
        end
        local p = it.cd.Parent
        return p and p:IsA("BasePart") and p.Position or nil
    end
    -- Goes to the closest one with that name, clicks it, comes back.
    function Shop.buy(label)
        if typeof(fireclickdetector) ~= "function" then
            notify("Your executor has no fireclickdetector")
            return false
        end
        local root = myRoot()
        if not root then
            return false
        end
        local best, bestD, bestPos
        for _, it in Shop.items() do
            if it.label == label then
                local p = pos(it)
                if p then
                    local d = (p - root.Position).Magnitude
                    if not bestD or d < bestD then
                        best, bestD, bestPos = it, d, p
                    end
                end
            end
        end
        if not best then
            notify("Couldn't find " .. tostring(label) .. " in the shop")
            return false
        end
        local cash = Game.cash()
        if cash and cash < best.price then
            notify(("Not enough cash for %s ($%d)"):format(label, best.price))
            return false
        end
        local back = root.CFrame
        local far = bestD > best.cd.MaxActivationDistance - 1
        if far then
            root.CFrame = CFrame.new(bestPos + Vector3.new(0, 3, 0))
            root.AssemblyLinearVelocity = Vector3.zero
            task.wait(0.25)
        end
        pcall(fireclickdetector, best.cd)
        task.wait(0.3)
        if far and root.Parent then
            root.CFrame = back
        end
        notify(("Bought %s ($%d)"):format(label, best.price), 2)
        return true
    end
    function Shop.ammoFor(tool)
        local base = tool and tool.Name:match("^%[(.-)%]$")
        if not base then
            return nil
        end
        for _, it in Shop.items() do
            if it.label:find("[" .. base .. " Ammo]", 1, true) then
                return it.label
            end
        end
        return nil
    end
end

--// Misc \\--
do
    local ok, vu = pcall(game.GetService, game, "VirtualUser")
    bind(LocalPlayer.Idled, function()
        if Settings.AntiAfk and ok and vu then
            pcall(function()
                vu:CaptureController()
                vu:ClickButton2(Vector2.new())
            end)
        end
    end)
end
local function rejoin()
    if #Players:GetPlayers() <= 1 then
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end
end
local function serverHop()
    local ok, data = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"):format(game.PlaceId)))
    end)
    if ok and data and data.data then
        local list = {}
        for _, s in data.data do
            if s.id ~= game.JobId and s.playing and s.maxPlayers and s.playing < s.maxPlayers - 1 then
                table.insert(list, s.id)
            end
        end
        if #list > 0 then
            TeleportService:TeleportToPlaceInstance(game.PlaceId, list[math.random(#list)], LocalPlayer)
            return
        end
    end
    notify("No other server found, rejoining instead")
    rejoin()
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Da Hood",
    Footer = "dookie hub · Ui3",
    Icon = "crosshair",
    Size = UDim2.fromOffset(640, 520),
    ConfigFolder = "Ui3/DaHood",
})
local function toggle(box, key, text, tip)
    return box:AddToggle(key, {
        Text = text, Default = Settings[key], Tooltip = tip,
        Callback = function(v)
            Settings[key] = v
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
local function color(t, key, title)
    if t and t.AddColorPicker then
        pcall(function()
            t:AddColorPicker(key .. "Pick", {
                Default = Settings[key], Title = title,
                Callback = function(c)
                    Settings[key] = c
                end,
            })
        end)
    end
end
local function status(box, fn)
    local label = box:AddLabel("...", true)
    task.spawn(function()
        while alive() do
            pcall(function()
                label:SetText(fn())
            end)
            task.wait(0.3)
        end
    end)
end

do
    local Tab = Window:AddTab("Combat", "crosshair", "Silent aim, camlock, triggerbot")
    local Box = Tab:AddLeftGroupbox("Aim", "crosshair")
    toggle(Box, "SilentAim", "Silent aim",
        "Every gun shoots at the target in the circle, through the game's own GunHandler.getAim. Your camera doesn't move. Works with the mobile Fire button")
    toggle(Box, "SpoofServerAim", "Also send the target as your aim",
        "Replaces the aim point the game streams to the server (UpdateMousePosI2) while silent aim has a target, so your shots and your aim agree (and SERVER_AIM servers shoot there)")
    slider(Box, "HitChance", "Hit chance", 1, 100, 0, "%", "Below 100 some shots go where you really aim")
    toggle(Box, "CamLock", "Camlock", "Turns your real camera onto the target (works on mobile)")
    slider(Box, "CamSmooth", "Camlock smoothness", 1, 30, 0, "", "1 snaps instantly")
    dropdown(Box, "AimWhen", "Active", { "Always", "While holding right click" })
    dropdown(Box, "AimPart", "Aim at", { "Head", "Torso", "Root", "Closest to aim" })
    slider(Box, "AimFOV", "Circle size", 20, 800, 0, " px", "Centred on your mouse on PC, the middle of the screen on mobile / shift lock")
    color(toggle(Box, "ShowFOV", "Show circle"), "FOVColor", "Circle colour")
    toggle(Box, "ShowTarget", "Mark the aim point")
    slider(Box, "AimMaxDistance", "Max distance", 20, 1000, 0, " studs", "Guns have about 200 studs of range")
    status(Box, function()
        return ("Target: %s\nGetAim: %s\nServer aim: %s\nSilent shots: %d"):format(Aim.info, Silent.status, Silent.serverAim, Silent.shots)
    end)

    local Filt = Tab:AddLeftGroupbox("Who to aim at", "users")
    toggle(Filt, "VisibleOnly", "Only visible", "Skips anyone behind a wall")
    toggle(Filt, "SkipKnocked", "Skip knocked")
    toggle(Filt, "SkipCrew", "Skip your crew")
    toggle(Filt, "SkipForceField", "Skip spawn protected")
    toggle(Filt, "StickyTarget", "Stick to target")

    local Pred = Tab:AddRightGroupbox("Prediction", "move-right")
    toggle(Pred, "Prediction", "Prediction", "Aims where the target will be, by their velocity")
    slider(Pred, "PredictionMs", "Lead", 0, 300, 0, " ms", "How far ahead. Raise it if you hit behind moving targets")
    toggle(Pred, "LeadPing", "Add your ping")
    toggle(Pred, "PredictY", "Predict jumps / falls", "Off: vertical movement is mostly ignored, which is steadier against jump spam")

    local Trig = Tab:AddRightGroupbox("Triggerbot", "zap")
    toggle(Trig, "Triggerbot", "Triggerbot",
        "Shoots (Tool:Activate, no fake clicks) when your aim is on an enemy, waiting for the gun's own cooldown")
    slider(Trig, "TriggerDelayMin", "Reaction min", 0, 400, 0, " ms")
    slider(Trig, "TriggerDelayMax", "Reaction max", 0, 600, 0, " ms")
    toggle(Trig, "TriggerOnSilentTarget", "Fire whenever silent aim has a target", "With silent aim on, shoots as soon as someone's in the circle")
    status(Trig, function()
        return ("Triggerbot: %s\nShots: %d"):format(Trigger.info, Trigger.shots)
    end)

    local Guns = Tab:AddRightGroupbox("Guns", "target")
    toggle(Guns, "AutoReload", "Auto reload", "Reloads the moment the mag is empty, through the game's own Reload")
    Guns:AddButton({
        Text = "Buy ammo for held gun",
        Func = function()
            local tool = Game.gun()
            local label = tool and Shop.ammoFor(tool)
            if not label then
                notify(tool and ("No ammo in the shop for " .. tool.Name) or "Hold a gun first")
                return
            end
            task.spawn(Shop.buy, label)
        end,
    })
end

do
    local Tab = Window:AddTab("Melee", "swords", "Stomp, block")
    local Box = Tab:AddLeftGroupbox("Stomp", "footprints")
    toggle(Box, "AutoStomp", "Auto stomp", "Stomps knocked players standing right under / next to you")
    toggle(Box, "StompTeleport", "Go to them", "Teleports on top of knocked players within range, stomps, comes back. Teleports are risky")
    slider(Box, "StompRange", "Range", 5, 60, 0, " studs")
    toggle(Box, "StompCrew", "Stomp your crew too")
    status(Box, function()
        return ("Stomp: %s\nStomps: %d"):format(Melee.info, Melee.stomps)
    end)
    local Def = Tab:AddRightGroupbox("Defence", "shield")
    toggle(Def, "AutoBlock", "Auto block", "Blocks when someone close aims a gun at you or swings at you")
    slider(Def, "BlockRange", "Range", 5, 40, 0, " studs")
    toggle(Def, "BlockGunAim", "Block guns aimed at you")
    toggle(Def, "BlockMelee", "Block melee swings")
    toggle(Def, "BlockOnlyNoGun", "Not while holding a gun", "You can't shoot while blocking")
    toggle(Def, "AntiStomp", "Anti stomp", "Resets you the moment you're knocked, so nobody gets the stomp (you still die)")
end

do
    local Tab = Window:AddTab("Movement", "move", "Speed, fly, noclip")
    local Box = Tab:AddLeftGroupbox("Movement", "move")
    toggle(Box, "Speed", "CFrame speed", "Moves you a bit further each frame. No body movers (the game reports those)")
    slider(Box, "SpeedAmount", "Extra speed", 1, 80, 0, " studs/s")
    toggle(Box, "Fly", "Fly", "Velocity fly: move to go where the camera looks, Space / Ctrl or jump button for up / down")
    slider(Box, "FlySpeed", "Fly speed", 10, 200, 0, " studs/s")
    toggle(Box, "Noclip", "Noclip")
    toggle(Box, "InfJump", "Infinite jump")
    Box:AddLabel("Da Hood checks movement on the server. Keep speed low and fly short.", true)
end

do
    local Tab = Window:AddTab("ESP", "eye", "See everyone")
    local Box = Tab:AddLeftGroupbox("ESP", "eye")
    toggle(Box, "Esp", "ESP", "Drawn on your screen only")
    toggle(Box, "EspBox", "Box")
    toggle(Box, "EspName", "Name (and KO / grabbed)")
    toggle(Box, "EspHealth", "Health bar")
    toggle(Box, "EspDistance", "Distance")
    toggle(Box, "EspTool", "Held item")
    toggle(Box, "EspArmor", "Armor")
    toggle(Box, "EspTracer", "Tracers")
    color(toggle(Box, "EspAimLines", "Aim lines", "Where everyone holding a gun is aiming (their streamed mouse point)"), "AimLineColor", "Aim line colour")
    slider(Box, "EspMax", "Max distance", 50, 3000, 0, " studs")
    local Col = Tab:AddRightGroupbox("Colours", "palette")
    color(toggle(Col, "EspCrew", "Show your crew"), "CrewColor", "Crew colour")
    Col:AddLabel("Enemy colour", false)
    color(Col, "EnemyColor", "Enemy colour")
    Col:AddLabel("Knocked colour", false)
    color(Col, "KnockedColor", "Knocked colour")
end

do
    local Tab = Window:AddTab("Money", "dollar-sign", "Cash and shop")
    local Box = Tab:AddLeftGroupbox("Cash drops", "dollar-sign")
    toggle(Box, "AutoPickup", "Auto pick up cash", "Clicks dropped cash in reach (fireclickdetector)")
    slider(Box, "PickupRange", "Reach", 4, 12, 0, " studs", "The game's own click range is 12")
    toggle(Box, "PickupTeleport", "Go to cash", "Teleports to cash within range, grabs it, comes back. Teleports are risky")
    slider(Box, "PickupTeleportRange", "Go to range", 15, 300, 0, " studs")
    color(toggle(Box, "CashEsp", "Cash ESP"), "CashColor", "Cash colour")
    status(Box, function()
        return ("Cash: %s\nDrops around: %d\nPicked up: %d"):format(tostring(Game.cash() or "?"), #Money.drops(), Money.picked)
    end)

    local Buy = Tab:AddRightGroupbox("Shop", "shopping-cart")
    local selected = nil
    local dd = Buy:AddDropdown("ShopItem", {
        Text = "Item", Values = Shop.names(), Default = nil, Searchable = true,
        Callback = function(v)
            selected = v
        end,
    })
    Buy:AddButton({
        Text = "Refresh list",
        Func = function()
            pcall(function()
                dd:SetValues(Shop.names())
            end)
        end,
    })
    Buy:AddButton({
        Text = "Buy",
        Func = function()
            if not selected then
                notify("Pick an item first")
                return
            end
            task.spawn(Shop.buy, selected)
        end,
    })
    Buy:AddLabel("Buying goes to the item, clicks it and comes back.", true)
end

do
    local Tab = Window:AddTab("Misc", "settings", "Server")
    local Box = Tab:AddLeftGroupbox("Server", "server")
    toggle(Box, "AntiAfk", "Anti AFK")
    Box:AddButton({ Text = "Rejoin", Func = rejoin })
    Box:AddButton({ Text = "Server hop", Func = serverHop })
    Box:AddButton({
        Text = "Unload",
        Func = function()
            if Genv.__DaHoodUnload then
                Genv.__DaHoodUnload()
            end
        end,
    })
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
Genv.__DaHoodUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(("Loaded%s%s"):format(Game.Gun and "" or " (GunHandler not found: silent aim off)", Draw.ok and "" or " (no Drawing API: ESP off)"), 4)
