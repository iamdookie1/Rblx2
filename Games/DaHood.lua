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
    -- hitbox
    Hitbox = false, HitboxSize = 8, HitboxTransparency = 75, HitboxSkipCrew = true, HitboxSkipKnocked = true,
    -- macro
    CustomMacro = false, MacroButton = true, MacroHold = false, MacroTurn = 100, MacroOnlyMoving = true, MacroOnlyAir = false,
    QuickMacro = false, QuickEmote = nil, QuickEmoteWait = 0.15, QuickNudge = 0.3, QuickLockpick = true,
    -- world
    AtmEsp = false, VaultEsp = false, ItemEsp = false, WorldShowBroken = false, WorldEspMax = 1500,
    AtmColor = Color3.fromRGB(90, 255, 120), VaultColor = Color3.fromRGB(255, 215, 70), ItemColor = Color3.fromRGB(150, 200, 255),
    AutoPunchAtm = false, AtmFarm = false, AtmFarmRange = 400, AtmPunchDelay = 0.35,
    -- shop / supplies
    BuyPick = "Closest", BuyCount = 1, BuyPauseNear = 0,
    AutoEat = false, EatHP = 70,
    AutoFood = false, FoodItem = "[Hamburger]", FoodBuyHP = 75, FoodBuyCount = 3,
    AutoArmor = false, ArmorItem = "[High-Medium Armor]", ArmorMin = 40,
    AutoAmmo = false, AmmoMin = 30,
    -- anti kill
    AntiKill = false, AntiKillHP = 35, AntiKillMethod = "Sky", SkyHeight = 1500, AntiKillReturn = true, ReturnHP = 85,
    AntiKillEat = true, AntiKillKnocked = false,
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
-- Shop items are models in workspace.Ignored.Shop named "[Item] - $price"
-- (ammo: "12 [Revolver Ammo] - $56"), each with a ClickDetector (click range 9).
-- The server checks your distance to it, so a far item means a short hop there.
local Shop = { busy = false, info = "idle", bought = 0 }
do
    local cache, cacheAt = {}, -10
    function Shop.items(fresh)
        if not fresh and os.clock() - cacheAt < 2 then
            return cache
        end
        local out = {}
        local ign = Workspace:FindFirstChild("Ignored")
        local folder = ign and ign:FindFirstChild("Shop")
        if folder then
            for _, m in folder:GetChildren() do
                local cd = m:FindFirstChildWhichIsA("ClickDetector", true)
                if cd then
                    local label, price = m.Name:match("^(.-)%s*%-%s*%$(%d+)")
                    local p
                    local okP, cf = pcall(m.GetPivot, m)
                    if okP and cf then
                        p = cf.Position
                    elseif cd.Parent and cd.Parent:IsA("BasePart") then
                        p = cd.Parent.Position
                    end
                    if p then
                        table.insert(out, { model = m, cd = cd, label = label or m.Name, price = tonumber(price) or 0, pos = p })
                    end
                end
            end
        end
        cache, cacheAt = out, os.clock()
        return out
    end
    function Shop.names()
        local seen, list = {}, {}
        for _, it in Shop.items(true) do
            if not seen[it.label] then
                seen[it.label] = true
                table.insert(list, it.label)
            end
        end
        table.sort(list)
        return list
    end
    function Shop.find(label)
        local root = myRoot()
        local best, bestScore
        for _, it in Shop.items() do
            if it.label == label and it.model.Parent then
                local d = root and (it.pos - root.Position).Magnitude or 0
                local score = Settings.BuyPick == "Cheapest" and (it.price * 100000 + d) or d
                if not bestScore or score < bestScore then
                    best, bestScore = it, score
                end
            end
        end
        return best
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

    -- What a purchase changes: cash, items, armor, ammo.
    local function snapshot()
        local s = { cash = Game.cash() or 0, tools = 0, armor = 0, fire = 0, ammo = 0 }
        local c = myChar()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        for _, holder in { bp, c } do
            if holder then
                for _, t in holder:GetChildren() do
                    if t:IsA("Tool") then
                        s.tools += 1
                    end
                end
            end
        end
        local be = Game.effects(c)
        s.armor = tonumber(Game.val(be, "Armor")) or 0
        s.fire = tonumber(Game.val(be, "FireArmor")) or 0
        local ok, inv = pcall(function()
            return LocalPlayer.DataFolder.Inventory
        end)
        if ok and inv then
            for _, v in inv:GetChildren() do
                s.ammo += tonumber(v.Value) or 0
            end
        end
        return s
    end
    local function changed(a, b)
        return b.cash < a.cash or b.tools > a.tools or b.armor > a.armor or b.fire > a.fire or b.ammo > a.ammo
    end

    local function doBuy(label, count, quiet)
        if typeof(fireclickdetector) ~= "function" then
            notify("Your executor has no fireclickdetector")
            return 0
        end
        local c = myChar()
        local root = myRoot()
        if not root or Game.knocked(c) or Game.dead(c) or Game.grabbed(c) then
            Shop.info = "can't buy right now (knocked / grabbed)"
            return 0
        end
        local it = Shop.find(label)
        if not it then
            if not quiet then
                notify("Couldn't find " .. tostring(label) .. " in the shop")
            end
            Shop.info = "not found: " .. tostring(label)
            return 0
        end
        local cash = Game.cash()
        if cash and cash < it.price then
            if not quiet then
                notify(("Not enough cash for %s ($%d)"):format(label, it.price))
            end
            Shop.info = "not enough cash"
            return 0
        end
        Shop.info = ("buying %s ($%d)"):format(label, it.price)
        local back = root.CFrame
        local reach = it.cd.MaxActivationDistance
        local moved = (it.pos - root.Position).Magnitude > reach - 1.5
        local stand = CFrame.new(it.pos + Vector3.new(0, 2.5, 0)) * (back - back.Position)
        local function hold()
            if moved and root.Parent then
                root.CFrame = stand
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end
        if moved then
            hold()
            -- Let the server see you there before the click arrives.
            RunService.Heartbeat:Wait()
            hold()
            RunService.Heartbeat:Wait()
        end
        local got = 0
        for _ = 1, count do
            local before = snapshot()
            if before.cash < it.price then
                break
            end
            local done = false
            for _ = 1, 3 do
                pcall(fireclickdetector, it.cd)
                local t0 = os.clock()
                while os.clock() - t0 < 0.4 do
                    hold()
                    RunService.Heartbeat:Wait()
                    if changed(before, snapshot()) then
                        done = true
                        break
                    end
                end
                if done then
                    break
                end
            end
            if not done then
                break
            end
            got += 1
            Shop.bought += 1
        end
        if moved and root.Parent then
            root.CFrame = back
            root.AssemblyLinearVelocity = Vector3.zero
        end
        Shop.info = got > 0 and ("bought %s x%d"):format(label, got) or ("%s didn't go through"):format(label)
        if not quiet then
            notify(Shop.info, 2)
        end
        return got
    end
    -- One purchase at a time; a second request waits its turn.
    function Shop.buy(label, count, quiet)
        local waited = os.clock()
        while Shop.busy and os.clock() - waited < 5 do
            task.wait(0.05)
        end
        if Shop.busy then
            return 0
        end
        Shop.busy = true
        local ok, got = pcall(doBuy, label, math.max(1, count or 1), quiet)
        Shop.busy = false
        return ok and got or 0
    end
end

--// Supplies: auto eat, auto food / armor / ammo \\--
local Supplies = { info = "off", ate = 0 }
local Safe = { active = false, info = "off", spot = nil }
do
    local function isFood(t)
        return t:IsA("Tool") and (t:FindFirstChild("Eat") or t:FindFirstChild("Drink") or t.Name == "[Lettuce]") ~= nil
    end
    function Supplies.foods()
        local out = {}
        local c = myChar()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        for _, holder in { c, bp } do
            if holder then
                for _, t in holder:GetChildren() do
                    if isFood(t) then
                        table.insert(out, t)
                    end
                end
            end
        end
        return out
    end
    local function hpPct()
        local c = myChar()
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum or hum.MaxHealth <= 0 then
            return 100, hum
        end
        return hum.Health / hum.MaxHealth * 100, hum
    end
    Supplies.hpPct = hpPct
    local function blocked()
        local c = myChar()
        return not c or Game.knocked(c) or Game.dead(c) or Game.grabbed(c)
    end
    local function enemyNear(range)
        if range <= 0 then
            return false
        end
        local root = myRoot()
        if not root then
            return false
        end
        for _, t in Targets.list() do
            if not Game.sameCrew(t.player) and (t.root.Position - root.Position).Magnitude <= range then
                return true
            end
        end
        return false
    end

    -- Eat: hold the food out and use it (the same as tapping with it out).
    local eating = false
    function Supplies.eat()
        if eating or blocked() then
            return false
        end
        local food = Supplies.foods()[1]
        if not food then
            return false
        end
        eating = true
        local c = myChar()
        local hum = c:FindFirstChildOfClass("Humanoid")
        local held = c:FindFirstChildOfClass("Tool")
        if held == food then
            held = nil
        end
        if food.Parent ~= c then
            hum:EquipTool(food)
            task.wait(0.1)
        end
        for _ = 1, 16 do
            if food.Parent ~= c or hpPct() >= 99.5 or blocked() then
                break
            end
            pcall(food.Activate, food)
            task.wait(0.25)
        end
        Supplies.ate += 1
        if held and held.Parent == LocalPlayer:FindFirstChild("Backpack") and not blocked() then
            hum:EquipTool(held)
        end
        eating = false
        return true
    end

    local lastFood, lastArmor, lastAmmo = 0, 0, {}
    loop(0.25, function()
        local any = Settings.AutoEat or Settings.AutoFood or Settings.AutoArmor or Settings.AutoAmmo
        if not any then
            Supplies.info = "off"
            return
        end
        if blocked() then
            Supplies.info = "waiting (knocked / grabbed / dead)"
            return
        end
        local hp = hpPct()
        if Settings.AutoEat and hp < Settings.EatHP and #Supplies.foods() > 0 then
            Supplies.info = ("eating (%d%% hp)"):format(hp)
            Supplies.eat()
            return
        end
        if Safe.active then
            Supplies.info = "anti kill is holding you safe"
            return
        end
        if Shop.busy or enemyNear(Settings.BuyPauseNear) then
            Supplies.info = Shop.busy and "buying..." or "paused (enemy close)"
            return
        end
        local now = os.clock()
        if Settings.AutoFood and hp < Settings.FoodBuyHP and #Supplies.foods() == 0 and now - lastFood > 3 then
            lastFood = now
            Supplies.info = "buying food"
            Shop.buy(Settings.FoodItem, Settings.FoodBuyCount, true)
            return
        end
        if Settings.AutoArmor and now - lastArmor > 3 then
            local be = Game.effects(myChar())
            local kind = Settings.ArmorItem == "[Fire Armor]" and "FireArmor" or "Armor"
            local armor = tonumber(Game.val(be, kind)) or 0
            if armor < Settings.ArmorMin then
                lastArmor = now
                Supplies.info = ("buying armor (%d)"):format(armor)
                Shop.buy(Settings.ArmorItem, 1, true)
                return
            end
        end
        if Settings.AutoAmmo then
            local ok, inv = pcall(function()
                return LocalPlayer.DataFolder.Inventory
            end)
            if ok and inv then
                local c = myChar()
                local bp = LocalPlayer:FindFirstChild("Backpack")
                for _, holder in { c, bp } do
                    for _, t in holder and holder:GetChildren() or {} do
                        if t:IsA("Tool") and t:FindFirstChild("Ammo") then
                            local slot = inv:FindFirstChild(t.Name)
                            local left = slot and tonumber(slot.Value)
                            if left and left < Settings.AmmoMin and now - (lastAmmo[t.Name] or 0) > 4 then
                                local label = Shop.ammoFor(t)
                                if label then
                                    lastAmmo[t.Name] = now
                                    Supplies.info = "buying " .. label
                                    Shop.buy(label, 1, true)
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end
        Supplies.info = "watching"
    end)
end

--// Anti kill: get out of the fight at low health \\--
-- Moves you away (CFrame only: no anchoring, which the game kicks for, and
-- no body movers, which it reports) and holds you there until you've healed.
do
    local back, hold
    local function release(toBack)
        local root = myRoot()
        if toBack and back and root then
            root.CFrame = back
            root.AssemblyLinearVelocity = Vector3.zero
        end
        Safe.active, back, hold = false, nil, nil
    end
    table.insert(Cleanups, function()
        if Safe.active then
            release(true)
        end
    end)
    local function target(root)
        local m = Settings.AntiKillMethod
        if m == "Hidden spot" and Safe.spot then
            return Safe.spot
        elseif m == "Far away" then
            local a = math.random() * 2 * math.pi
            local d = math.random(2500, 4000)
            return CFrame.new(root.Position + Vector3.new(math.cos(a) * d, Settings.SkyHeight * 0.3, math.sin(a) * d))
        end
        return CFrame.new(root.Position + Vector3.new(0, Settings.SkyHeight, 0))
    end
    function Safe.setSpot()
        local root = myRoot()
        if root then
            Safe.spot = root.CFrame
            notify("Hidden spot saved here", 2)
        end
    end
    bind(RunService.Heartbeat, function()
        if not alive() then
            return
        end
        local c = myChar()
        local root = c and c:FindFirstChild("HumanoidRootPart")
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not Settings.AntiKill then
            if Safe.active then
                release(Settings.AntiKillReturn)
            end
            Safe.info = "off"
            return
        end
        if not (root and hum) or hum.Health <= 0 or Game.dead(c) then
            if Safe.active then
                release(false)
            end
            Safe.info = "waiting"
            return
        end
        local hp = hum.Health / math.max(1, hum.MaxHealth) * 100
        local knocked = Game.knocked(c)
        if not Safe.active then
            if hp <= Settings.AntiKillHP or (Settings.AntiKillKnocked and knocked) then
                back = root.CFrame
                hold = target(root)
                Safe.active = true
                notify(("Anti kill: %d%% hp, moved to safety"):format(hp), 2)
            else
                Safe.info = ("ready (%d%% hp)"):format(hp)
                return
            end
        end
        root.CFrame = hold
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        Safe.info = ("safe (%d%% hp)"):format(hp)
        if Settings.AntiKillEat and not knocked and hp < 99 and #Supplies.foods() > 0 then
            task.spawn(Supplies.eat)
        end
        if Settings.AntiKillReturn and not knocked and hp >= Settings.ReturnHP then
            release(true)
            notify("Anti kill: healed, back in", 2)
        end
    end)
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

--// Hitbox expander \\--
-- Guns raycast on your side and send the part they hit, so other players'
-- HumanoidRootParts made bigger on your screen get hit from further off.
-- Only you see the change (other players' parts don't replicate from you).
local Hitbox = { count = 0 }
do
    local original = {}
    local function restore(part)
        local o = original[part]
        if o then
            pcall(function()
                part.Size = o.Size
                part.Transparency = o.Transparency
                part.CanCollide = o.CanCollide
                part.Massless = o.Massless
            end)
            original[part] = nil
        end
    end
    local function restoreAll()
        for part in original do
            restore(part)
        end
    end
    table.insert(Cleanups, restoreAll)
    loop(0.1, function()
        if not Settings.Hitbox then
            if next(original) then
                restoreAll()
            end
            Hitbox.count = 0
            return
        end
        local n = 0
        local want = {}
        for _, t in Targets.list() do
            local skip = (Settings.HitboxSkipCrew and Game.sameCrew(t.player))
                or (Settings.HitboxSkipKnocked and (Game.knocked(t.char) or Game.dead(t.char)))
            if not skip then
                local part = t.root
                want[part] = true
                if not original[part] then
                    original[part] = { Size = part.Size, Transparency = part.Transparency, CanCollide = part.CanCollide, Massless = part.Massless }
                end
                local s = Settings.HitboxSize
                part.Size = Vector3.new(s, s, s)
                part.Transparency = Settings.HitboxTransparency / 100
                part.CanCollide = false
                part.Massless = true
                n += 1
            end
        end
        for part in original do
            if not want[part] or not part.Parent then
                restore(part)
            end
        end
        Hitbox.count = n
    end)
end

--// Macro \\--
-- Da Hood has its own macro (the speed glitch): while it's on, your root turns
-- to face where the camera looks every frame (MobileMacroButton, RenderStep
-- "MobileMacro"). It's only offered when Lighting.MacroAllow is on, nobody
-- voted it off, and you're skinny (MuscleInformation <= -7500).
local Macro = { custom = false, info = "" }
do
    local UGS = UserSettings():GetService("UserGameSettings")
    function Macro.allowed()
        local l = game:GetService("Lighting")
        return l:GetAttribute("MacroAllow") == true and not l:GetAttribute("PlayersWantMacroToBeDisabled")
    end
    function Macro.skinny()
        local ok, v = pcall(function()
            return LocalPlayer.DataFolder.Information.MuscleInformation.Value
        end)
        return ok and tonumber(v) ~= nil and tonumber(v) <= -7500
    end
    local function gameButton()
        local gui = LocalPlayer:FindFirstChild("PlayerGui")
        local main = gui and gui:FindFirstChild("MainScreenGui")
        local layout = main and main:FindFirstChild("MobileLayout")
        return layout and layout:FindFirstChild("Macro")
    end
    -- The game's own macro, on / off.
    function Macro.gameOn()
        local b = gameButton()
        local stroke = b and b:FindFirstChildOfClass("UIStroke")
        return stroke ~= nil and stroke.Enabled == true
    end
    -- Toggles the game's own macro through its own button handler.
    function Macro.toggleGame()
        local b = gameButton()
        if not b then
            notify("The game's macro button isn't loaded")
            return
        end
        if not Macro.allowed() then
            notify("Macro is turned off on this server")
            return
        end
        if not Macro.skinny() and not Macro.gameOn() then
            notify("The game only lets skinny characters macro. Use the custom macro instead")
            return
        end
        if typeof(getconnections) ~= "function" then
            notify("Your executor has no getconnections")
            return
        end
        local fired = false
        for _, c in getconnections(b.Activated) do
            if c.Function then
                task.spawn(c.Function)
                fired = true
            end
        end
        if not fired then
            notify("Couldn't reach the game's macro button")
        end
    end

    -- Custom macro: the same steering the game does, on any build, with its
    -- own on-screen button for phones.
    local steering = false
    local rotationBefore = nil
    local function stop()
        if steering then
            steering = false
            if rotationBefore then
                pcall(function()
                    UGS.RotationType = rotationBefore
                end)
                rotationBefore = nil
            end
        end
    end
    table.insert(Cleanups, stop)
    function Macro.active()
        return alive() and Settings.CustomMacro and Macro.custom
    end
    local function yaw(v)
        return math.atan2(-v.X, -v.Z)
    end
    RunService:BindToRenderStep("DaHoodMacro", 41, function(dt)
        if not Macro.active() then
            stop()
            Macro.info = Settings.CustomMacro and "ready (tap the MACRO button)" or "off"
            return
        end
        local c = myChar()
        local root = c and c:FindFirstChild("HumanoidRootPart")
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not (root and hum) or hum.Sit or hum.PlatformStand or hum.Health <= 0 or Game.knocked(c) or Game.grabbed(c) then
            stop()
            Macro.info = "paused"
            return
        end
        if Settings.MacroOnlyMoving and hum.MoveDirection.Magnitude < 0.1 then
            stop()
            Macro.info = "waiting (not moving)"
            return
        end
        if Settings.MacroOnlyAir and hum.FloorMaterial ~= Enum.Material.Air then
            stop()
            Macro.info = "waiting (on the ground)"
            return
        end
        if not steering then
            steering = true
            rotationBefore = UGS.RotationType
        end
        pcall(function()
            UGS.RotationType = Enum.RotationType.MovementRelative
        end)
        local look = root.CFrame.LookVector
        local cam = camera().CFrame.LookVector
        local now = yaw(look)
        local diff = ((yaw(cam) - now + math.pi) % (2 * math.pi)) - math.pi
        local a = 1 - 0.64 ^ (dt * 240 * Settings.MacroTurn / 100)
        root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, now + diff * a, 0)
        Macro.info = "macroing"
    end)
    table.insert(Cleanups, function()
        pcall(RunService.UnbindFromRenderStep, RunService, "DaHoodMacro")
    end)

    -- On-screen MACRO button (drag it anywhere). Tap = toggle, or hold.
    local gui
    do
        local ok, parent = pcall(function()
            return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
        end)
        gui = Instance.new("ScreenGui")
        gui.Name = "DHMacro"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 50
        if not (ok and pcall(function()
            gui.Parent = parent
        end)) then
            gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(72, 72)
        b.Position = UDim2.new(1, -170, 0.5, -36)
        b.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 14
        b.Text = "MACRO"
        b.AutoButtonColor = false
        b.Parent = gui
        Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
        local stroke = Instance.new("UIStroke", b)
        stroke.Thickness = 2
        stroke.Color = Color3.fromRGB(70, 70, 78)
        local function paint()
            b.BackgroundColor3 = Macro.custom and Color3.fromRGB(40, 120, 55) or Color3.fromRGB(35, 35, 40)
            stroke.Color = Macro.custom and Color3.fromRGB(90, 210, 120) or Color3.fromRGB(70, 70, 78)
        end
        Macro.paint = paint
        local downAt, startPos, dragging, inputObj = nil, nil, false, nil
        bind(b.InputBegan, function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
                downAt, startPos, dragging, inputObj = i.Position, b.Position, false, i
                if Settings.MacroHold then
                    Macro.custom = true
                    paint()
                end
            end
        end)
        bind(UserInputService.InputChanged, function(i)
            if downAt and (i == inputObj or i.UserInputType == Enum.UserInputType.MouseMovement) then
                local d = i.Position - downAt
                if d.Magnitude > 12 then
                    dragging = true
                end
                if dragging then
                    b.Position = startPos + UDim2.fromOffset(d.X, d.Y)
                end
            end
        end)
        bind(UserInputService.InputEnded, function(i)
            if downAt and (i == inputObj or i.UserInputType == Enum.UserInputType.MouseButton1) then
                if Settings.MacroHold then
                    Macro.custom = false
                elseif not dragging then
                    Macro.custom = not Macro.custom
                end
                downAt = nil
                paint()
            end
        end)
        table.insert(Cleanups, function()
            gui:Destroy()
        end)
        loop(0.25, function()
            gui.Enabled = Settings.CustomMacro and Settings.MacroButton
            if not Settings.CustomMacro and Macro.custom then
                Macro.custom = false
                paint()
            end
        end)
    end
end

--// Quick macro: emote -> wait -> lockpick -> nudge \\--
-- One tap while a macro is on: plays an emote from your equipped emote wheel
-- (Humanoid:PlayEmote, the same thing the wheel does), waits, pulls out a
-- lockpick if you have one, and steps a tiny bit forward to cancel the emote.
local Quick = { info = "", runs = 0 }
do
    function Quick.emotes()
        local list = {}
        local c = myChar()
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local desc = hum and hum:FindFirstChildOfClass("HumanoidDescription")
        if not desc then
            return list
        end
        local ok, eq = pcall(desc.GetEquippedEmotes, desc)
        if ok and type(eq) == "table" then
            table.sort(eq, function(a, b)
                return (a.Slot or 0) < (b.Slot or 0)
            end)
            for _, e in eq do
                if e.Name and not table.find(list, e.Name) then
                    table.insert(list, e.Name)
                end
            end
        end
        return list
    end
    local function lockpick()
        local c = myChar()
        if c and c:FindFirstChild("[LockPicker]") then
            return c["[LockPicker]"]
        end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        return bp and bp:FindFirstChild("[LockPicker]")
    end
    local busy = false
    function Quick.run()
        if busy then
            return
        end
        if not (Macro.gameOn() or Macro.active()) then
            Quick.info = "turn a macro on first"
            notify("Quick macro needs the game's macro or the custom macro on", 2)
            return
        end
        local c = myChar()
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local root = c and c:FindFirstChild("HumanoidRootPart")
        if not (hum and root) or hum.Health <= 0 or Game.knocked(c) then
            return
        end
        local emote = Settings.QuickEmote
        if not emote or emote == "" then
            emote = Quick.emotes()[1]
        end
        if not emote then
            Quick.info = "no emotes equipped"
            notify("Equip an emote in your emote wheel first", 2)
            return
        end
        busy = true
        task.spawn(function()
            -- PlayEmote only works standing: drop the held tool first.
            if c:FindFirstChildOfClass("Tool") then
                hum:UnequipTools()
                RunService.Heartbeat:Wait()
            end
            -- Remember which animation tracks the emote starts, so they can be
            -- stopped directly (a small step alone doesn't end an emote).
            local animator = hum:FindFirstChildOfClass("Animator")
            local before = {}
            if animator then
                for _, tr in animator:GetPlayingAnimationTracks() do
                    before[tr] = true
                end
            end
            local ok, played = pcall(hum.PlayEmote, hum, emote)
            if not (ok and played) then
                Quick.info = "emote didn't play (jumping / falling?)"
                busy = false
                return
            end
            local started = os.clock()
            RunService.Heartbeat:Wait()
            local emoteTracks = {}
            if animator then
                for _, tr in animator:GetPlayingAnimationTracks() do
                    if not before[tr] then
                        table.insert(emoteTracks, tr)
                    end
                end
            end
            local left = Settings.QuickEmoteWait - (os.clock() - started)
            if left > 0 then
                task.wait(left)
            end
            if Settings.QuickLockpick then
                local lp = lockpick()
                if lp and lp.Parent ~= c then
                    hum:EquipTool(lp)
                end
            end
            -- Cancel the emote: stop its tracks, then a tiny real step forward
            -- (with walking speed, so the game's Animate script sees you move).
            for _, tr in emoteTracks do
                pcall(tr.Stop, tr, 0.05)
            end
            local look = root.CFrame.LookVector
            local flat = Vector3.new(look.X, 0, look.Z)
            flat = flat.Magnitude > 0 and flat.Unit or Vector3.new(0, 0, -1)
            root.CFrame += flat * Settings.QuickNudge
            local t = os.clock()
            while os.clock() - t < 0.08 do
                local v = root.AssemblyLinearVelocity
                root.AssemblyLinearVelocity = Vector3.new(flat.X * hum.WalkSpeed, v.Y, flat.Z * hum.WalkSpeed)
                hum:Move(flat, false)
                RunService.Heartbeat:Wait()
            end
            hum:Move(Vector3.zero, false)
            for _, tr in emoteTracks do
                if tr.IsPlaying then
                    pcall(tr.Stop, tr, 0)
                end
            end
            Quick.runs += 1
            Quick.info = ("did %s"):format(emote)
            busy = false
        end)
    end

    -- On-screen QUICK button (drag it anywhere, tap to run).
    local gui = Instance.new("ScreenGui")
    gui.Name = "DHQuickMacro"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 50
    local ok, parent = pcall(function()
        return (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
    end)
    if not (ok and pcall(function()
        gui.Parent = parent
    end)) then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(72, 72)
    b.Position = UDim2.new(1, -170, 0.5, 46)
    b.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.Text = "QUICK"
    b.AutoButtonColor = false
    b.Parent = gui
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", b)
    stroke.Thickness = 2
    stroke.Color = Color3.fromRGB(70, 70, 78)
    local downAt, startPos, dragging, inputObj = nil, nil, false, nil
    bind(b.InputBegan, function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            downAt, startPos, dragging, inputObj = i.Position, b.Position, false, i
        end
    end)
    bind(UserInputService.InputChanged, function(i)
        if downAt and (i == inputObj or i.UserInputType == Enum.UserInputType.MouseMovement) then
            local d = i.Position - downAt
            if d.Magnitude > 12 then
                dragging = true
            end
            if dragging then
                b.Position = startPos + UDim2.fromOffset(d.X, d.Y)
            end
        end
    end)
    bind(UserInputService.InputEnded, function(i)
        if downAt and (i == inputObj or i.UserInputType == Enum.UserInputType.MouseButton1) then
            if not dragging then
                Quick.run()
            end
            downAt = nil
        end
    end)
    table.insert(Cleanups, function()
        gui:Destroy()
    end)
    loop(0.2, function()
        gui.Enabled = Settings.QuickMacro
        local ready = Macro.gameOn() or Macro.active()
        stroke.Color = ready and Color3.fromRGB(90, 210, 120) or Color3.fromRGB(70, 70, 78)
        b.BackgroundColor3 = busy and Color3.fromRGB(40, 120, 55) or Color3.fromRGB(35, 35, 40)
    end)
end

--// World: ATMs, vaults, dropped items \\--
local World = { atms = 0, vaults = 0 }
do
    -- workspace.Cashiers holds the ATMs ("CA$HIER") and vaults ("VAULT"), each a
    -- model with a Humanoid: broken open = health 0.
    function World.breakables()
        local out = {}
        local folder = Workspace:FindFirstChild("Cashiers")
        if not folder then
            return out
        end
        for _, m in folder:GetChildren() do
            local hum = m:FindFirstChildOfClass("Humanoid")
            local head = m:FindFirstChild("Head") or m:FindFirstChild("Open") or m:FindFirstChildWhichIsA("BasePart")
            if hum and head then
                local kind = m.Name:find("VAULT") and "Vault" or "ATM"
                table.insert(out, { model = m, hum = hum, head = head, kind = kind, broken = hum.Health <= 0 })
            end
        end
        return out
    end
    function World.items()
        local out = {}
        local ign = Workspace:FindFirstChild("Ignored")
        local folder = ign and ign:FindFirstChild("ItemsDrop")
        if not folder then
            return out
        end
        for _, cd in folder:GetDescendants() do
            if cd:IsA("ClickDetector") then
                local holder = cd.Parent
                local part = holder:IsA("BasePart") and holder or holder:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    table.insert(out, { name = holder.Name, part = part, cd = cd })
                end
            end
        end
        return out
    end

    local cache, items = {}, {}
    loop(0.5, function()
        cache = World.breakables()
        items = World.items()
        local a, v = 0, 0
        for _, b in cache do
            if not b.broken then
                if b.kind == "ATM" then
                    a += 1
                else
                    v += 1
                end
            end
        end
        World.atms, World.vaults = a, v
    end)

    local labels = {}
    bind(RunService.RenderStepped, function()
        local cam = camera()
        local root = myRoot()
        local used = 0
        local function put(pos, text, col)
            local sp, vis = cam:WorldToViewportPoint(pos)
            if not vis then
                return
            end
            used += 1
            local l = labels[used]
            if not l then
                l = Draw.new("Text", { Size = 13, Center = true, Outline = true })
                labels[used] = l
            end
            if l then
                l.Visible = true
                l.Text = text
                l.Position = Vector2.new(sp.X, sp.Y)
                l.Color = col
            end
        end
        if alive() and Draw.ok and cam then
            for _, b in cache do
                local want = (b.kind == "ATM" and Settings.AtmEsp) or (b.kind == "Vault" and Settings.VaultEsp)
                if want and b.head.Parent and (Settings.WorldShowBroken or b.hum.Health > 0) then
                    local dist = root and (b.head.Position - root.Position).Magnitude or 0
                    if dist <= Settings.WorldEspMax then
                        local hp = math.floor(b.hum.Health / math.max(1, b.hum.MaxHealth) * 100 + 0.5)
                        local col = b.hum.Health <= 0 and Color3.fromRGB(130, 130, 130)
                            or (b.kind == "Vault" and Settings.VaultColor or Settings.AtmColor)
                        put(b.head.Position + Vector3.new(0, 2, 0),
                            ("%s %s · %dm"):format(b.kind, b.hum.Health <= 0 and "(open)" or (hp .. "%"), dist), col)
                    end
                end
            end
            if Settings.ItemEsp then
                for _, it in items do
                    if it.part.Parent then
                        local dist = root and (it.part.Position - root.Position).Magnitude or 0
                        if dist <= Settings.WorldEspMax then
                            put(it.part.Position + Vector3.new(0, 1.5, 0), ("%s · %dm"):format(it.name, dist), Settings.ItemColor)
                        end
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

    -- Punches ATMs with Combat (Tool:Activate, the same as tapping). Farm mode
    -- also walks you (teleports) from one unbroken ATM to the next and picks
    -- up the cash they drop.
    World.info, World.broken = "off", 0
    local function nearestAtm(maxDist)
        local root = myRoot()
        if not root then
            return nil
        end
        local best, bestD
        for _, b in World.breakables() do
            if b.kind == "ATM" and b.hum.Health > 0 then
                local d = (b.head.Position - root.Position).Magnitude
                if d <= maxDist and (not bestD or d < bestD) then
                    best, bestD = b, d
                end
            end
        end
        return best, bestD
    end
    local function combat()
        local c = myChar()
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if not hum then
            return nil
        end
        local held = c:FindFirstChild("Combat")
        if held then
            return held
        end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local tool = bp and bp:FindFirstChild("Combat")
        if tool then
            hum:EquipTool(tool)
            task.wait(0.1)
            return c:FindFirstChild("Combat")
        end
        return nil
    end
    local function collect(around)
        if typeof(fireclickdetector) ~= "function" then
            return
        end
        local root = myRoot()
        for _, d in Money.drops() do
            if root and (d.part.Position - around).Magnitude <= 18 then
                root.CFrame = CFrame.new(d.part.Position + Vector3.new(0, 2.5, 0))
                root.AssemblyLinearVelocity = Vector3.zero
                task.wait(0.12)
                pcall(fireclickdetector, d.cd)
                Money.picked += 1
                task.wait(0.08)
            end
        end
    end
    loop(0.05, function()
        if not (Settings.AtmFarm or Settings.AutoPunchAtm) then
            World.info = "off"
            return
        end
        local me = myChar()
        local root = myRoot()
        if not root or Game.knocked(me) or Game.dead(me) then
            World.info = "waiting (knocked / dead)"
            return
        end
        local atm, d = nearestAtm(Settings.AtmFarm and Settings.AtmFarmRange or 7)
        if not atm then
            World.info = Settings.AtmFarm and "no unbroken ATM in range" or "no ATM in reach"
            return
        end
        local head = atm.head
        if d > 5 then
            if not Settings.AtmFarm then
                return
            end
            local flat = Vector3.new(root.Position.X - head.Position.X, 0, root.Position.Z - head.Position.Z)
            local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
            local stand = head.Position + dir * 3
            root.CFrame = CFrame.lookAt(stand, Vector3.new(head.Position.X, stand.Y, head.Position.Z))
            root.AssemblyLinearVelocity = Vector3.zero
            task.wait(0.2)
        end
        local tool = combat()
        if not tool then
            World.info = "no Combat tool"
            return
        end
        local flatLook = Vector3.new(head.Position.X, root.Position.Y, head.Position.Z)
        if (flatLook - root.Position).Magnitude > 0.5 then
            root.CFrame = CFrame.lookAt(root.Position, flatLook)
        end
        World.info = ("punching ATM (%d%%)"):format(math.floor(atm.hum.Health / math.max(1, atm.hum.MaxHealth) * 100))
        pcall(tool.Activate, tool)
        task.wait(Settings.AtmPunchDelay)
        if atm.hum.Health <= 0 then
            World.broken += 1
            if Settings.AtmFarm then
                task.wait(0.4)
                collect(head.Position)
            end
        end
    end)
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
    local Hb = Tab:AddLeftGroupbox("Hitbox expander", "maximize")
    toggle(Hb, "Hitbox", "Hitbox expander",
        "Makes other players' root part bigger on your screen, so your gun's own raycast hits them from further off. Silent aim is usually cleaner")
    slider(Hb, "HitboxSize", "Size", 2, 30, 0, " studs")
    slider(Hb, "HitboxTransparency", "See-through", 0, 100, 0, "%", "100 is invisible")
    toggle(Hb, "HitboxSkipCrew", "Not your crew")
    toggle(Hb, "HitboxSkipKnocked", "Not knocked players")
    status(Hb, function()
        return ("Expanded: %d"):format(Hitbox.count)
    end)
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

    local Mac = Tab:AddRightGroupbox("Macro", "zap")
    Mac:AddButton({ Text = "Toggle the game's own macro", Func = Macro.toggleGame })
    Mac:AddLabel("The game's own macro: needs the server to allow it and a skinny character.", true)
    toggle(Mac, "CustomMacro", "Custom macro",
        "The same steering the game's macro does (your body turns to face the camera every frame), on any build, with its own button")
    toggle(Mac, "MacroButton", "Show MACRO button", "A round button on screen you can drag anywhere. Tap to turn the macro on / off")
    toggle(Mac, "MacroHold", "Hold the button instead", "Macro only while your finger is on the button")
    slider(Mac, "MacroTurn", "Turn speed", 10, 300, 0, "%", "100 is exactly the game's own macro")
    toggle(Mac, "MacroOnlyMoving", "Only while moving")
    toggle(Mac, "MacroOnlyAir", "Only in the air")
    local Qm = Tab:AddRightGroupbox("Quick macro", "sparkles")
    toggle(Qm, "QuickMacro", "Quick macro button",
        "A QUICK button on screen: with a macro on, one tap plays your emote, waits, pulls out a lockpick and steps forward to cancel the emote")
    local emoteDD = Qm:AddDropdown("QuickEmote", {
        Text = "Emote", Values = Quick.emotes(), Default = nil,
        Tooltip = "From your equipped emote wheel. Empty = the first one",
        Callback = function(v)
            Settings.QuickEmote = v
        end,
    })
    Qm:AddButton({
        Text = "Refresh emotes",
        Func = function()
            pcall(function()
                emoteDD:SetValues(Quick.emotes())
            end)
        end,
    })
    slider(Qm, "QuickEmoteWait", "Wait before lockpick", 0, 1.5, 2, " s")
    toggle(Qm, "QuickLockpick", "Pull out lockpick", "Only if you have a [LockPicker]")
    slider(Qm, "QuickNudge", "Forward step", 0.05, 2, 2, " studs", "How far the cancel step moves you")
    Qm:AddButton({ Text = "Run once", Func = function() Quick.run() end })
    status(Qm, function()
        return ("Quick: %s\nRuns: %d"):format(Quick.info ~= "" and Quick.info or "ready", Quick.runs)
    end)
    task.defer(function()
        -- Fill the emote list once your character has loaded.
        for _ = 1, 20 do
            local list = Quick.emotes()
            if #list > 0 then
                pcall(function()
                    emoteDD:SetValues(list)
                end)
                break
            end
            task.wait(1)
        end
    end)

    status(Mac, function()
        return ("Server allows macro: %s\nSkinny: %s\nGame macro: %s\nCustom: %s"):format(
            Macro.allowed() and "yes" or "no", Macro.skinny() and "yes" or "no", Macro.gameOn() and "on" or "off", Macro.info)
    end)
end

do
    local Tab = Window:AddTab("World", "landmark", "ATMs, vaults, items")
    local Box = Tab:AddLeftGroupbox("World ESP", "eye")
    color(toggle(Box, "AtmEsp", "ATM ESP", "Every ATM that can still be broken open, with its health"), "AtmColor", "ATM colour")
    color(toggle(Box, "VaultEsp", "Vault ESP", "Bank vaults that can still be broken open"), "VaultColor", "Vault colour")
    color(toggle(Box, "ItemEsp", "Dropped item ESP", "Lockpicks and other items lying around"), "ItemColor", "Item colour")
    toggle(Box, "WorldShowBroken", "Also show opened ones", "Greyed out")
    slider(Box, "WorldEspMax", "Max distance", 50, 5000, 0, " studs")
    status(Box, function()
        return ("Unbroken ATMs: %d\nUnbroken vaults: %d"):format(World.atms, World.vaults)
    end)

    local Farm = Tab:AddRightGroupbox("ATMs", "dollar-sign")
    toggle(Farm, "AutoPunchAtm", "Auto punch ATM", "Punches an unbroken ATM in reach with Combat (the game's own punch)")
    toggle(Farm, "AtmFarm", "ATM farm",
        "Goes from one unbroken ATM to the next, breaks it and picks up the cash. Teleports: risky, use an alt")
    slider(Farm, "AtmFarmRange", "Farm range", 20, 3000, 0, " studs")
    slider(Farm, "AtmPunchDelay", "Punch delay", 0.15, 1, 2, " s")
    status(Farm, function()
        return ("ATM: %s\nBroken: %d\nCash picked: %d"):format(World.info, World.broken, Money.picked)
    end)
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
    dropdown(Buy, "BuyPick", "Which shop", { "Closest", "Cheapest" }, "Prices differ between shops. Cheapest can mean a longer hop")
    slider(Buy, "BuyCount", "Amount", 1, 20, 0, "", "Buys this many in one trip")
    Buy:AddButton({
        Text = "Buy",
        Func = function()
            if not selected then
                notify("Pick an item first")
                return
            end
            task.spawn(Shop.buy, selected, Settings.BuyCount)
        end,
    })
    status(Buy, function()
        return ("Shop: %s\nBought this session: %d"):format(Shop.info, Shop.bought)
    end)
    Buy:AddLabel("Far items: hops there, clicks the moment the server sees you, comes back as soon as the buy goes through.", true)

    local Auto = Tab:AddLeftGroupbox("Auto buy", "repeat")
    local foodList = { "[Hamburger]", "[Chicken]", "[Pizza]", "[Taco]", "[HotDog]", "[Donut]", "[Meat]", "[Popcorn]",
        "[Popsicle]", "[IceCream]", "[Lettuce]", "[Cranberry]", "[Lemonade]", "[Da Milk]", "[Starblox Latte]" }
    toggle(Auto, "AutoFood", "Auto buy food", "When your health is low and you have no food left")
    dropdown(Auto, "FoodItem", "Food", foodList)
    slider(Auto, "FoodBuyHP", "Buy food below", 10, 100, 0, "% hp")
    slider(Auto, "FoodBuyCount", "How many", 1, 10, 0, "")
    toggle(Auto, "AutoArmor", "Auto buy armor", "When your armor drops below the amount")
    dropdown(Auto, "ArmorItem", "Armor", { "[Medium Armor]", "[High-Medium Armor]", "[Fire Armor]" })
    slider(Auto, "ArmorMin", "Buy armor below", 1, 200, 0, "", "Armor goes up to 200")
    toggle(Auto, "AutoAmmo", "Auto buy ammo", "For every gun you own, when its spare ammo runs low")
    slider(Auto, "AmmoMin", "Buy ammo below", 1, 300, 0, " spare")
    slider(Auto, "BuyPauseNear", "Pause if enemy within", 0, 100, 0, " studs", "0 = never pause. Stops auto buy hopping away mid-fight")
    status(Auto, function()
        return "Auto: " .. Supplies.info
    end)
end

do
    local Tab = Window:AddTab("Survive", "heart", "Anti kill, auto heal")
    local Box = Tab:AddLeftGroupbox("Anti kill", "shield")
    toggle(Box, "AntiKill", "Anti kill", "At low health, moves you somewhere safe and holds you there until you've healed")
    slider(Box, "AntiKillHP", "Trigger at", 5, 90, 0, "% hp")
    dropdown(Box, "AntiKillMethod", "Where to", { "Sky", "Hidden spot", "Far away" },
        "Sky: straight up. Hidden spot: the spot you save below. Far away: thousands of studs off, up high")
    slider(Box, "SkyHeight", "Sky height", 200, 5000, 0, " studs")
    Box:AddButton({ Text = "Save hidden spot here", Func = Safe.setSpot })
    toggle(Box, "AntiKillEat", "Eat while safe", "Uses your food while you wait")
    toggle(Box, "AntiKillReturn", "Come back when healed", "Off: stays there until you turn anti kill off")
    slider(Box, "ReturnHP", "Come back at", 20, 100, 0, "% hp")
    toggle(Box, "AntiKillKnocked", "Also when knocked", "Takes you away when you're knocked so nobody can stomp you. Riskier")
    status(Box, function()
        return ("Anti kill: %s\nHidden spot: %s"):format(Safe.info, Safe.spot and "saved" or "not saved")
    end)

    local Heal = Tab:AddRightGroupbox("Auto heal", "heart")
    toggle(Heal, "AutoEat", "Auto eat", "Eats your food when your health is low, then puts your item back")
    slider(Heal, "EatHP", "Eat below", 10, 100, 0, "% hp")
    Heal:AddButton({
        Text = "Eat now",
        Func = function()
            task.spawn(function()
                if not Supplies.eat() then
                    notify("No food to eat", 2)
                end
            end)
        end,
    })
    status(Heal, function()
        return ("Health: %d%%\nFood: %d\nAte: %d"):format(Supplies.hpPct(), #Supplies.foods(), Supplies.ate)
    end)
    Heal:AddLabel("God mode isn't possible: health is only changed by the server. This tab is the closest thing.", true)
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
