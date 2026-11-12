--// Runaways ------------------------------------------------------------------------
-- supercat games. Match places: normal 117311404196294, express 99088826116845,
-- hard 129415455370018. Built on Ui3.
--
-- How the game works (as the client sees it):
--   Flow      every module in ReplicatedStorage.FlowClient is merged into one
--             table (require(FlowClient)); server calls go through
--             FlowClient.ClientRunner.Event:FireServer(module, method, ...).
--             The game's own scripts call into that shared table at call time,
--             so wrapping a function there changes what the game does.
--   Guns      Guns.fire -> BulletsClient.shootProjectile({ from, direction,
--             config }) -> raycast; NPC hits report NPCs.Damage(humanoid, dmg),
--             lootables DamageToOpen.Damage(model, dmg, "bullet"). Recoil is
--             Camera.Recoil / Viewmodel.Recoil.
--   Melee     DamageToOpen.Damage(model, destructibleDamage * strength,
--             "melee"), NPCs.Damage(humanoid, damage * strength).
--   Crime     NPCs.Threaten(npc) when you aim at people, UnlawfulFiring.Shot(pos)
--             when you fire. ReplicatedStorage.GameState: Heat, Stars, Bounty.
--   Loot      tag "Cash" / "Credz" under a part with a TouchSensor ->
--             Cash.Collect / Credz.Collect. Breakables carry tag DamageToOpen.
--   Cars      Packages.Vehicle.GetSpec(model) returns Data.CarData.Cars[id].spec,
--             read by the driving code every frame (topSpeedMPH, acceleration,
--             torque, brakingPower, turningAngle). Fuel: model.gasLevel.
--   Fuel      GasPump.Pour(refuelSystem, on) / FuelContainer.Pour(can, on),
--             with the gas gun or can being dragged (LocalStates draggedObject).
--   Falls     FallDamage asks ModifiersClient.Get("fallDamage") before it
--             reports PlayerDamage.TakeDamage.
--   Watch     AntiYeetClient snaps you back if you move over 300 studs/s
--             outside a seat. Nothing here moves you, and car tuning stays a
--             multiplier on the car's own numbers.
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer

local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
if Genv.__RunawaysUnload then
    pcall(Genv.__RunawaysUnload)
end
Genv.__RunawaysRun = (Genv.__RunawaysRun or 0) + 1
local RUN = Genv.__RunawaysRun
local Unloaded = false
local function alive()
    return not Unloaded and Genv.__RunawaysRun == RUN
end

--// Ui3 \\--
local Library
do
    local ref = "main"
    local ok, sha = pcall(function()
        return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://api.github.com/repos/iamdookie1/Ui3/commits/main")).sha
    end)
    if ok and sha then
        ref = sha
    end
    Library = loadstring(game:HttpGet(("https://raw.githubusercontent.com/iamdookie1/Ui3/%s/Ui.lua"):format(ref)))()
end
local Options = Library.Options
if not alive() then
    return
end

local Settings = {
    -- combat
    SilentAim = false, AimNPC = true, AimPolice = true, AimPlayers = false, AimPart = "Head",
    FOV = 180, ShowFOV = true, VisibleCheck = true, HitChance = 100,
    NoRecoil = false, NoSpread = false,
    MeleeAura = false, MeleeRange = 10, MeleeEvery = 0.45, MeleeWeaponSpeed = true, MeleeCivilians = true,
    MeleePolice = true, MeleeTargets = 3, MeleeBreak = false,
    GunMods = false, RpmMult = 1.5, ForceAuto = true, InfAmmo = false, DamageMult = 1, ExtraPellets = 0,
    Wallbang = false, GunAura = false, GunAuraRange = 120, GunAuraPolice = true, GunAuraCivilians = false,
    Fly = false, FlySpeed = 80,
    EspNPC = false, EspPlayers = false, EspHealth = true,
    -- police
    PoliceEsp = true, PoliceAlert = true, AlertRange = 150, Quiet = false,
    -- driving
    Tune = false, SpeedMult = 1.3, AccelMult = 1.3, TorqueMult = 1.2, BrakeMult = 1.3, TurnMult = 1.1,
    AutoPour = false, LowFuelAlert = true, LowFuelAt = 20, AutoFlip = false,
    CarFly = false, CarFlySpeed = 220, CarFlyTurn = 2.2, CarFlyResponse = 5,
    BoostGrip = 0.3, BoostTurn = 1.5, BoostDownforce = 80,
    AutoSell = false, SellAt = 0, SellRange = 500, SellSpeed = 200, CheckpointSpeed = 700, CheckpointHeight = 12, CarBoost = false, BoostSpeed = 300, BoostAccel = 120,
    AntiDrift = false, Grip = 0.35, DriftFrom = 30, SteerAssist = false, SteerPower = 1.6, Stabilize = false,
    BrakeAssist = false, BrakePower = 150,
    AutoShoot = false, ShootCops = false, CopShootRange = 250, StealAtOnce = 6, CarFlyHeading = false,
    -- loot
    AutoCash = false, CashRange = 30, AutoBreak = false, BreakRange = 12, BreakEvery = 0.5,
    AutoSteal = false, StealMin = 100, StealRange = 10, BringMin = 0, BringRange = 300, BringCount = 10,
    BringOnly = false, BringNames = {}, TakeUnlisted = true,
    DragNoclip = false, DragPower = 50, DragForce = 1, DragDistance = 1,
    LootEsp = false, CashEsp = false,
    -- survival
    NoFall = false, AutoEat = false, EatAt = 40, AutoRevive = false, LowHpAlert = true, AntiAfk = false,
    -- world
    Fullbright = false, NoFog = false, NoWeather = false, FpsBoost = false,
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
                warn("[Runaways] " .. tostring(err))
            end
            task.wait(type(every) == "function" and every() or every)
        end
    end)
end
local function notify(text, seconds)
    pcall(Library.Notify, Library, { Title = "Runaways", Description = text, Time = seconds or 3 })
end
local function character()
    return LocalPlayer.Character
end
local function rootPart()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function inWorld(inst)
    return inst and inst:IsDescendantOf(Workspace)
end
local function pivotOf(inst)
    local ok, pos = pcall(function()
        if inst:IsA("Model") then
            return inst:GetPivot().Position
        end
        return inst.Position
    end)
    return ok and typeof(pos) == "Vector3" and pos or nil
end

--// The game's modules \\--
local Data = select(2, pcall(require, ReplicatedStorage:WaitForChild("Data")))
if type(Data) ~= "table" then
    Data = {}
end
local Packages = select(2, pcall(require, ReplicatedStorage:WaitForChild("Packages")))
if type(Packages) ~= "table" then
    Packages = {}
end
local FlowFolder = ReplicatedStorage:WaitForChild("FlowClient")
local Runner = FlowFolder:WaitForChild("ClientRunner")
local RunnerEvent = Runner:WaitForChild("Event")
local RunnerFunction = Runner:WaitForChild("Function")

-- The game's merged Flow table. require() normally hands back the same table
-- the game uses; if this executor gives a fresh one, the table is found in
-- memory by a few of its module names.
local Flow
do
    local function looksRight(t)
        return type(t) == "table" and type(rawget(t, "BulletsClient")) == "table" and type(rawget(t, "NPCs")) == "table"
    end
    local ok, t = pcall(require, FlowFolder)
    if ok and looksRight(t) then
        Flow = t
    elseif typeof(getgc) == "function" then
        pcall(function()
            for _, v in getgc(true) do
                if looksRight(v) then
                    Flow = v
                    break
                end
            end
        end)
    end
end

local Game = {}
do
    function Game.module(name)
        if not Flow then
            return nil
        end
        local ok, m = pcall(function()
            return Flow[name]
        end)
        return ok and type(m) == "table" and m or nil
    end
    -- Server call: through the game's own function when there is one (it
    -- knows whether it's an event or an invoke), else the shared event.
    function Game.call(module, method, ...)
        local m = Game.module(module)
        local fn = m and m[method]
        if type(fn) == "function" then
            return pcall(fn, ...)
        end
        return pcall(RunnerEvent.FireServer, RunnerEvent, module, method, ...)
    end
    -- A server call that answers (an invoke). Without the shared table it
    -- goes straight to the runner's RemoteFunction; sending one of these
    -- through the event, as before, got no answer and did nothing.
    function Game.invoke(module, method, ...)
        local m = Game.module(module)
        local fn = m and m[method]
        if type(fn) == "function" then
            return pcall(fn, ...)
        end
        return pcall(RunnerFunction.InvokeServer, RunnerFunction, module, method, ...)
    end
    -- Wraps one of the game's functions; undone on unload.
    function Game.wrap(module, method, make)
        local m = Game.module(module)
        local old = m and m[method]
        if type(old) ~= "function" then
            return false
        end
        m[method] = make(old)
        table.insert(Cleanups, function()
            m[method] = old
        end)
        return true
    end
    function Game.state(name)
        local gs = ReplicatedStorage:FindFirstChild("GameState")
        local v = gs and gs:FindFirstChild(name)
        return v and v.Value or 0
    end
    function Game.balance(name)
        local b = type(Data.Balance) == "table" and Data.Balance or {}
        return b[name]
    end
    function Game.toolConfig(tool)
        local tools = Data.Tools
        if not (tools and tools.GetToolConfig) then
            return nil
        end
        local ok, cfg = pcall(tools.GetToolConfig, tool.Name)
        if ok and cfg then
            return cfg
        end
        local base = tool:GetAttribute("BaseTool")
        if base then
            ok, cfg = pcall(tools.GetToolConfig, base)
            return ok and cfg or nil
        end
        return nil
    end
    function Game.isMelee(tool)
        local tools = Data.Tools
        local ok, r = pcall(function()
            return tools.IsMelee(tool)
        end)
        return ok and r == true
    end
    function Game.strength()
        local m = Game.module("PlayerLoadoutClient")
        local ok, r = pcall(function()
            return m.GetStrengthMult(LocalPlayer)
        end)
        return ok and type(r) == "number" and r or 1
    end
    function Game.localData(key)
        local m = Game.module("LocalData")
        local ok, r = pcall(function()
            return m.Get(key)
        end)
        return ok and r or nil
    end
    function Game.dragged()
        local m = Game.module("LocalStates")
        local ok, r = pcall(function()
            return m.GetValue("draggedObject"):get()
        end)
        return ok and r or nil
    end
end

--// Who is who \\--
local POLICE_WORDS = { "police", "sheriff", "swet", "swat", "officer", "military", "trooper", "cop" }
local People = {}
do
    function People.isPolice(model)
        local name = model.Name:lower()
        for _, w in POLICE_WORDS do
            if name:find(w, 1, true) then
                return true
            end
        end
        for _, attr in { "Police", "IsPolice", "Faction", "Team", "Role" } do
            local v = model:GetAttribute(attr)
            if v == true or (type(v) == "string" and v:lower():find("police")) then
                return true
            end
        end
        return false
    end
    -- Living NPCs in the world.
    -- Rebuilt at most 4 times a second: aim, ESP and the auras all ask.
    local npcCache, npcAt = {}, -1
    function People.npcs()
        if os.clock() - npcAt < 0.25 then
            return npcCache
        end
        npcAt = os.clock()
        local out = {}
        npcCache = out
        for _, m in CollectionService:GetTagged("NPC") do
            if m:IsA("Model") and inWorld(m) then
                local h = m:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then
                    table.insert(out, m)
                end
            end
        end
        return out
    end
    function People.others()
        local out = {}
        for _, p in Players:GetPlayers() do
            if p ~= LocalPlayer and p.Character then
                local h = p.Character:FindFirstChildOfClass("Humanoid")
                if h and h.Health > 0 then
                    table.insert(out, p.Character)
                end
            end
        end
        return out
    end
    function People.policeVehicles()
        local out = {}
        local folder = Workspace:FindFirstChild("Vehicles")
        for _, v in folder and folder:GetChildren() or {} do
            if v.Name:lower():find("police") or v:FindFirstChild("PoliceLights", true) then
                table.insert(out, v)
            end
        end
        for _, h in CollectionService:GetTagged("PoliceHeli") do
            if inWorld(h) then
                table.insert(out, h)
            end
        end
        return out
    end
end

--// Silent aim, recoil, spread \\--
local Aim = { target = nil, part = nil }
do
    local camera = Workspace.CurrentCamera
    local function screenPoint()
        if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
            local v = camera.ViewportSize
            return Vector2.new(v.X / 2, v.Y / 2)
        end
        return UserInputService:GetMouseLocation()
    end
    -- Would a bullet from here reach this model? The same ray the game's
    -- bullets use: they pass through Effects, you, your car and anything
    -- tagged NPCCollider, MetalFence or NoBulletImpact. Those invisible NPC
    -- colliders are what made the old check call nearly everyone hidden.
    local PASS_THROUGH = { "NPCCollider", "MetalFence", "NoBulletImpact" }
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.RespectCanCollide = false
    local ignoreAt, ignoreList = -1, {}
    local function reaches(from, part, model)
        if os.clock() - ignoreAt < 2 then
            local hit = Workspace:Raycast(from, part.Position - from, params)
            return hit == nil or hit.Instance:IsDescendantOf(model)
        end
        ignoreAt = os.clock()
        local ignore = {}
        ignoreList = ignore
        local c = character()
        if c then
            table.insert(ignore, c)
            local h = c:FindFirstChildOfClass("Humanoid")
            local p = h and h.SeatPart
            while p and p ~= Workspace do
                if p:IsA("Model") and p:HasTag("Vehicle") then
                    table.insert(ignore, p)
                    break
                end
                p = p.Parent
            end
        end
        local effects = Workspace:FindFirstChild("Effects")
        if effects then
            table.insert(ignore, effects)
        end
        for _, tag in PASS_THROUGH do
            for _, inst in CollectionService:GetTagged(tag) do
                table.insert(ignore, inst)
            end
        end
        params.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(from, part.Position - from, params)
        return hit == nil or hit.Instance:IsDescendantOf(model)
    end
    -- The part you asked for first, then the rest of the body.
    local function partsOf(model)
        local order = Settings.AimPart == "Head"
            and { "Head", "UpperTorso", "Torso", "HumanoidRootPart" }
            or { "UpperTorso", "Torso", "HumanoidRootPart", "Head" }
        local out = {}
        for _, name in order do
            local p = model:FindFirstChild(name)
            if p and p:IsA("BasePart") then
                table.insert(out, p)
            end
        end
        return out
    end
    Aim.status = "off"
    local cacheAt, cachePart = -1, nil
    function Aim.find(from)
        -- full-auto and shotguns ask many times a frame: one answer per frame
        if os.clock() - cacheAt < 0.03 then
            return cachePart
        end
        cacheAt = os.clock()
        cachePart = Aim.findNow(from)
        return cachePart
    end
    function Aim.findNow(from)
        camera = Workspace.CurrentCamera
        from = from or camera.CFrame.Position
        local pool = {}
        for _, m in People.npcs() do
            local police = People.isPolice(m)
            if (police and Settings.AimPolice) or (not police and Settings.AimNPC) then
                table.insert(pool, m)
            end
        end
        if Settings.AimPlayers then
            for _, m in People.others() do
                table.insert(pool, m)
            end
        end
        local center = screenPoint()
        local candidates = {}
        for _, m in pool do
            local parts = partsOf(m)
            local first = parts[1]
            if first then
                local pos, onScreen = camera:WorldToViewportPoint(first.Position)
                if onScreen and pos.Z > 0 then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= Settings.FOV then
                        table.insert(candidates, { m = m, parts = parts, d = d })
                    end
                end
            end
        end
        table.sort(candidates, function(a, b)
            return a.d < b.d
        end)
        local blocked = 0
        for _, c in candidates do
            for _, part in c.parts do
                if not Settings.VisibleCheck or reaches(from, part, c.m) then
                    Aim.target, Aim.part = c.m, part
                    Aim.status = ("aiming at %s (%s)"):format(c.m.Name, part.Name)
                    return part
                end
            end
            blocked += 1
        end
        Aim.target, Aim.part = nil, nil
        Aim.status = #candidates == 0 and "nobody inside the circle"
            or ("%d in the circle, all behind walls"):format(blocked)
        return nil
    end

    -- What a shot does: point it at the target (or straight, for no spread).
    local function steer(args)
        if not (alive() and type(args) == "table" and typeof(args.from) == "Vector3") or args.__aimed then
            return
        end
        local part = Settings.SilentAim and Aim.find(args.from) or nil
        if part and math.random(1, 100) <= Settings.HitChance then
            args.direction = (part.Position - args.from).Unit * 1000
            Aim.shots = (Aim.shots or 0) + 1
        elseif Settings.NoSpread then
            local cf = Workspace.CurrentCamera.CFrame
            args.from = cf.Position
            args.direction = cf.LookVector * 1000
        end
    end
    -- Through the shared table the guns call into; if that can't be reached,
    -- by hooking the game's own shootProjectile function itself.
    Aim.hook = "none"
    if Game.wrap("BulletsClient", "shootProjectile", function(old)
        return function(args, who, ...)
            steer(args)
            return old(args, who, ...)
        end
    end) then
        Aim.hook = "game table"
    elseif typeof(hookfunction) == "function" and typeof(getgc) == "function" then
        pcall(function()
            local target
            for _, fn in getgc() do
                if type(fn) == "function" and typeof(debug.info) == "function" then
                    local okN, name = pcall(debug.info, fn, "n")
                    local okS, src = pcall(debug.info, fn, "s")
                    if okN and name == "shootProjectile" and okS and tostring(src):find("BulletsClient", 1, true) then
                        target = fn
                        break
                    end
                end
            end
            if target then
                local old
                local wrapper = function(args, who, ...)
                    steer(args)
                    return old(args, who, ...)
                end
                old = hookfunction(target, typeof(newcclosure) == "function" and newcclosure(wrapper) or wrapper)
                Aim.hook = "hooked the function"
                table.insert(Cleanups, function()
                    pcall(hookfunction, target, old)
                end)
            end
        end)
    end
    for _, mod in { "Camera", "Viewmodel" } do
        Game.wrap(mod, "Recoil", function(old)
            return function(...)
                if alive() and Settings.NoRecoil then
                    return
                end
                return old(...)
            end
        end)
    end

    -- FOV circle
    local circle
    if typeof(Drawing) == "table" and typeof(Drawing.new) == "function" then
        pcall(function()
            circle = Drawing.new("Circle")
            circle.Thickness, circle.NumSides, circle.Filled = 1.5, 48, false
            circle.Color = Color3.fromRGB(255, 220, 90)
            circle.Transparency = 0.8
        end)
    end
    if circle then
        table.insert(Cleanups, function()
            pcall(function()
                circle:Remove()
            end)
        end)
        bind(RunService.RenderStepped, function()
            local show = Settings.SilentAim and Settings.ShowFOV
            circle.Visible = show
            if show then
                circle.Radius = Settings.FOV
                circle.Position = screenPoint()
            end
        end)
    end
end

--// Melee aura and loot breaking (with the weapon you hold) \\--
local Hit = { lastMelee = 0, lastBreak = 0 }
do
    function Hit.held()
        local c = character()
        return c and c:FindFirstChildOfClass("Tool")
    end
    function Hit.breakables(range)
        local root = rootPart()
        local out = {}
        if not root then
            return out
        end
        for _, m in CollectionService:GetTagged("DamageToOpen") do
            if inWorld(m) then
                local pos = pivotOf(m)
                if pos and (pos - root.Position).Magnitude <= range then
                    table.insert(out, m)
                end
            end
        end
        return out
    end
    -- Who the melee aura and gun aura go for, nearest first.
    function Hit.targets(range, civilians, police, limit)
        local root = rootPart()
        local out = {}
        if not root then
            return out
        end
        for _, m in People.npcs() do
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - root.Position).Magnitude
                local isCop = People.isPolice(m)
                if d <= range and ((isCop and police) or (not isCop and civilians)) then
                    table.insert(out, { m = m, d = d })
                end
            end
        end
        table.sort(out, function(a, b)
            return a.d < b.d
        end)
        local models = {}
        for i = 1, math.min(#out, limit or #out) do
            models[i] = out[i].m
        end
        return models
    end
    function Hit.meleePass()
        if not Settings.MeleeAura then
            return
        end
        local tool, root = Hit.held(), rootPart()
        if not (tool and root and Game.isMelee(tool)) then
            return
        end
        local cfg = Game.toolConfig(tool)
        if not (cfg and type(cfg.damage) == "number") then
            return
        end
        -- the weapon's own swing rate, or the slider
        local every = Settings.MeleeEvery
        if Settings.MeleeWeaponSpeed and type(cfg.hitsPerSecond) == "number" and cfg.hitsPerSecond > 0 then
            every = 1 / cfg.hitsPerSecond
        end
        if os.clock() - Hit.lastMelee < every then
            return
        end
        Hit.lastMelee = os.clock()
        local strength = Game.strength()
        for _, m in Hit.targets(Settings.MeleeRange, Settings.MeleeCivilians, Settings.MeleePolice, Settings.MeleeTargets) do
            Game.call("NPCs", "Damage", m:FindFirstChildOfClass("Humanoid"), cfg.damage * strength)
        end
        if Settings.MeleeBreak and type(cfg.destructibleDamage) == "number" then
            for _, m in Hit.breakables(Settings.MeleeRange) do
                Game.call("DamageToOpen", "Damage", m, cfg.destructibleDamage * strength, "melee")
            end
        end
    end
    function Hit.breakPass()
        if not Settings.AutoBreak or os.clock() - Hit.lastBreak < Settings.BreakEvery then
            return
        end
        local tool = Hit.held()
        if not tool then
            return
        end
        local cfg = Game.toolConfig(tool)
        if not cfg then
            return
        end
        local melee = Game.isMelee(tool)
        local dmg = melee and cfg.destructibleDamage or cfg.damage
        if type(dmg) ~= "number" then
            return
        end
        Hit.lastBreak = os.clock()
        dmg *= melee and Game.strength() or 1
        for _, m in Hit.breakables(Settings.BreakRange) do
            Game.call("DamageToOpen", "Damage", m, dmg, melee and "melee" or "bullet")
        end
    end
end
loop(0.05, function()
    Hit.meleePass()
    Hit.breakPass()
end)

--// Gun mods \\--
-- A gun reads its config (Data.Tools.Guns) when you equip it, and the damage
-- on every shot, so these change the shared config and re-equip your gun.
local Guns = { base = {}, lastShot = 0 }
do
    local FIELDS = { "maxRpm", "mode", "infiniteAmmo", "damage", "pellets", "collateral", "inaccuracy" }
    local function gunConfigs()
        local out = {}
        local tools = Data.Tools
        local list = {}
        for _, where in { LocalPlayer:FindFirstChildOfClass("Backpack"), character() } do
            for _, t in where and where:GetChildren() or {} do
                if t:IsA("Tool") then
                    table.insert(list, t)
                end
            end
        end
        for _, t in list do
            local cfg = Game.toolConfig(t)
            if cfg and cfg.category == "Guns" then
                out[cfg] = true
            end
        end
        return out
    end
    function Guns.restore()
        for cfg, base in Guns.base do
            for _, f in FIELDS do
                cfg[f] = base[f]
            end
        end
        table.clear(Guns.base)
    end
    table.insert(Cleanups, Guns.restore)
    function Guns.apply()
        if not Settings.GunMods then
            Guns.restore()
            return
        end
        for cfg in gunConfigs() do
            local base = Guns.base[cfg]
            if not base then
                base = {}
                for _, f in FIELDS do
                    base[f] = cfg[f]
                end
                Guns.base[cfg] = base
            end
            if type(base.maxRpm) == "number" then
                cfg.maxRpm = base.maxRpm * Settings.RpmMult
            end
            cfg.mode = Settings.ForceAuto and "auto" or base.mode
            cfg.infiniteAmmo = Settings.InfAmmo or base.infiniteAmmo
            if type(base.damage) == "number" then
                cfg.damage = base.damage * Settings.DamageMult
            end
            cfg.pellets = (base.pellets or 1) + Settings.ExtraPellets
            if Settings.Wallbang then
                cfg.collateral = true
            else
                cfg.collateral = base.collateral
            end
            if Settings.NoSpread then
                cfg.inaccuracy = 0
            else
                cfg.inaccuracy = base.inaccuracy
            end
        end
    end
    -- Picks the new numbers up straight away.
    function Guns.reequip()
        local h, tool = humanoid(), Hit.held()
        if h and tool and Game.toolConfig(tool) and Game.toolConfig(tool).category == "Guns" then
            task.spawn(function()
                pcall(h.UnequipTools, h)
                task.wait(0.15)
                pcall(h.EquipTool, h, tool)
            end)
        end
    end
    -- Gun aura: shoots the nearest NPCs in range with the gun you hold, at
    -- its own fire rate, through the game's own bullet code.
    -- One shot of the gun you hold at a part, the way the gun fires: its
    -- live config (so fire rate, pellets, damage and infinite ammo from the
    -- gun mods all count), its ammo, its sound and tracer.
    function Guns.shootAt(tool, cfg, part)
        local bullets = Game.module("BulletsClient")
        if not (bullets and part) then
            return false
        end
        if not cfg.infiniteAmmo then
            local ammo = tool:GetAttribute("Ammo")
            if type(ammo) == "number" then
                if ammo <= 0 then
                    return false
                end
                Game.call("Ammo", "setAmmo", tool, ammo - 1)
            end
        end
        Guns.lastShot = os.clock()
        local from = Workspace.CurrentCamera.CFrame.Position
        local guns = Game.module("Guns")
        for _ = 1, math.max(1, cfg.pellets or 1) do
            local ok, result = pcall(bullets.shootProjectile, {
                from = from, direction = (part.Position - from).Unit * 1000, config = cfg, __aimed = true,
            })
            if guns and guns.Traceshot and ok and type(result) == "table" then
                pcall(guns.Traceshot, tool, result.intersectionPoint or part.Position)
            end
        end
        if guns and guns.Gunshot then
            pcall(guns.Gunshot, tool)
        end
        return true
    end
    -- The nearest police car or helicopter in range: a point in the middle
    -- of it, which the bullet's own ray then hits whatever it meets first.
    function Guns.copVehicle()
        local root = rootPart()
        if not root then
            return nil
        end
        local best, bestD
        for _, v in People.policeVehicles() do
            local ok, cf = pcall(function()
                return (v:GetBoundingBox())
            end)
            local pos = ok and cf and cf.Position or pivotOf(v)
            if pos then
                local d = (pos - root.Position).Magnitude
                if d <= Settings.CopShootRange and (not bestD or d < bestD) then
                    best, bestD = pos, d
                end
            end
        end
        return best and { Position = best } or nil
    end
    function Guns.held()
        local tool = Hit.held()
        local cfg = tool and Game.toolConfig(tool)
        if cfg and cfg.category == "Guns" and type(cfg.maxRpm) == "number" and cfg.maxRpm > 0 then
            return tool, cfg
        end
        return nil
    end
    -- Gun aura: the nearest NPC in range. Auto shoot: whoever silent aim has
    -- in the circle. Both at the gun's own (modded) fire rate.
    function Guns.auraPass()
        if not (Settings.GunAura or Settings.AutoShoot or Settings.ShootCops) then
            return
        end
        local tool, cfg = Guns.held()
        if not tool or os.clock() - Guns.lastShot < 60 / cfg.maxRpm then
            return
        end
        local part
        if Settings.AutoShoot then
            part = Aim.find()
        end
        if not part and Settings.GunAura then
            local target = Hit.targets(Settings.GunAuraRange, Settings.GunAuraCivilians, Settings.GunAuraPolice, 1)[1]
            part = target and (target:FindFirstChild("Head") or target:FindFirstChild("HumanoidRootPart"))
        end
        if not part and Settings.ShootCops then
            part = Guns.copVehicle()
        end
        if part then
            Guns.shootAt(tool, cfg, part)
        end
    end
end
loop(1, Guns.apply)
bind(RunService.Heartbeat, function()
    if alive() then
        pcall(Guns.auraPass)
    end
end)

--// Loot: steal into your backpack, bring things to you \\--
local Steal = { skip = {}, names = {} }
do
    -- The game's own value for an item, or nil when it doesn't list one
    -- (the tutorial's watch, tiara and trophy, for one).
    function Steal.value(model)
        local loot = Data.Loot
        local name = model.Name:gsub("%[%d+%]$", "")
        for _, fn in { loot and loot.GetItemValue, loot and loot.GetItemPrice } do
            if fn then
                local ok, v = pcall(fn, name)
                if ok and type(v) == "number" then
                    return v
                end
            end
        end
        local v = model:GetAttribute("Value") or model:GetAttribute("Price")
        return type(v) == "number" and v or nil
    end
    function Steal.worth(model, min)
        local v = Steal.value(model)
        if v == nil then
            return Settings.TakeUnlisted
        end
        return v >= min
    end
    -- The part you'd point at to take it: its Handle.
    local function partOf(model)
        local h = model:FindFirstChild("Handle")
        if h and h:IsA("BasePart") then
            return h
        end
        return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
    end
    Steal.partOf = partOf
    -- Things put on a pawn counter (its Volume box) are being sold: hands off.
    function Steal.onCounter(model)
        local part = partOf(model)
        if not part then
            return false
        end
        for _, counter in CollectionService:GetTagged("PawnCounter") do
            local vol = counter:FindFirstChild("Volume")
            if vol and vol:IsA("BasePart") then
                local rel = vol.CFrame:PointToObjectSpace(part.Position)
                local half = vol.Size / 2 + Vector3.new(2, 3, 2)
                if math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z then
                    return true
                end
            end
        end
        return false
    end
    -- Not what you're holding or dragging, not inside a character or a car,
    -- not stuck onto a car.
    local function eligible(model)
        if not (model:IsA("Model") and inWorld(model)) then
            return false
        end
        if model:HasTag("BuyableLoot") or model:HasTag("Vehicle") or model:HasTag("GasGun") or model:HasTag("Turret") then
            return false
        end
        if model == Game.dragged() then
            return false
        end
        local c = character()
        if c and model:IsDescendantOf(c) then
            return false
        end
        local p = model.Parent
        while p and p ~= Workspace do
            if p:IsA("Model") and (p:HasTag("Vehicle") or Players:GetPlayerFromCharacter(p)) then
                return false
            end
            p = p.Parent
        end
        if model:FindFirstChild("AttachableWeld", true) then
            return false
        end
        if Steal.onCounter(model) then
            return false
        end
        return true
    end
    Steal.eligible = eligible
    Steal.status = "idle"
    -- Small things go straight into the backpack, the way pressing equip does.
    function Steal.pass()
        if not Settings.AutoSteal then
            return
        end
        local root = rootPart()
        if not root then
            return
        end
        local near = 0
        for _, model in CollectionService:GetTagged("Equippable") do
            if (Steal.inFlight or 0) >= Settings.StealAtOnce then
                break
            end
            if (Steal.skip[model] or 0) < os.clock() and eligible(model) then
                local part = partOf(model)
                if part and (part.Position - root.Position).Magnitude <= Settings.StealRange then
                    near += 1
                    if Steal.worth(model, Settings.StealMin) then
                        -- each request waits on the server's answer, so several
                        -- go at once instead of one after another
                        Steal.skip[model] = os.clock() + 0.6
                        Steal.inFlight = (Steal.inFlight or 0) + 1
                        task.spawn(function()
                            local ok, result = Game.invoke("Loot", "LootEquip", part)
                            Steal.inFlight -= 1
                            Steal.status = ("%s: %s"):format(model.Name, ok and tostring(result) or ("error " .. tostring(result)))
                            if not (ok and result == "Success") then
                                Steal.skip[model] = os.clock() + 4
                            end
                        end)
                    end
                end
            end
        end
        if near == 0 then
            Steal.status = "nothing to take within range"
        end
    end
    -- Everything draggable around, for the bring list.
    function Steal.draggables()
        local out = {}
        for _, model in CollectionService:GetTagged("Draggable") do
            if eligible(model) then
                table.insert(out, model)
            end
        end
        return out
    end
    function Steal.refreshNames()
        local seen = {}
        for _, m in Steal.draggables() do
            seen[m.Name] = true
        end
        local names = {}
        for n in seen do
            table.insert(names, n)
        end
        table.sort(names)
        Steal.names = names
    end
    -- Bring: the game hands you ownership of an item the same way it does
    -- when you grab it, then it's moved next to you and let go.
    function Steal.bring()
        local root = rootPart()
        if not root then
            return 0
        end
        local list = {}
        for _, m in Steal.draggables() do
            local part = partOf(m)
            if part then
                local d = (part.Position - root.Position).Magnitude
                local picked = not Settings.BringOnly or Settings.BringNames[m.Name]
                if d > 6 and d <= Settings.BringRange and picked and Steal.worth(m, Settings.BringMin) then
                    table.insert(list, { m = m, part = part, d = d })
                end
            end
        end
        table.sort(list, function(a, b)
            return a.d < b.d
        end)
        local brought, pending = 0, 0
        for i, e in list do
            if i > Settings.BringCount or not alive() then
                break
            end
            pending += 1
            task.spawn(function()
            local ok, granted = Game.invoke("Loot", "OwnNetworkRequestAsync", e.part, true)
            Steal.status = ("bring %s: %s"):format(e.m.Name, ok and tostring(granted) or ("error " .. tostring(granted)))
            if ok and granted then
                local row, col = (i - 1) // 4, (i - 1) % 4
                local at = root.CFrame * CFrame.new((col - 1.5) * 3, 1, -5 - row * 3)
                pcall(function()
                    e.m:PivotTo(CFrame.new(at.Position))
                    for _, bp in e.m:GetDescendants() do
                        if bp:IsA("BasePart") then
                            bp.AssemblyLinearVelocity = Vector3.zero
                        end
                    end
                end)
                brought += 1
                task.delay(1.5, function()
                    Game.call("Loot", "OwnNetworkRequest", e.part, nil)
                end)
            end
            pending -= 1
            end)
            task.wait(0.02)
        end
        local t0 = os.clock()
        while pending > 0 and os.clock() - t0 < 5 do
            task.wait(0.05)
        end
        return brought
    end
end
loop(0.05, Steal.pass)
loop(3, Steal.refreshNames)

--// Drag settings \\--
-- While you drag something: how hard and how far it's held, and through walls
-- but never through the floor.
local Drag = { item = nil, parts = {}, holds = {} }
do
    local function cameraPart()
        local m = Game.module("CameraPart")
        local ok, part = pcall(function()
            return m.GetCameraPart()
        end)
        return ok and part or nil
    end
    function Drag.release()
        for part, was in Drag.parts do
            pcall(function()
                part.CanCollide = was
            end)
        end
        table.clear(Drag.parts)
        table.clear(Drag.holds)
        Drag.item = nil
    end
    table.insert(Cleanups, Drag.release)
    function Drag.step()
        local item = Game.dragged()
        if typeof(item) ~= "Instance" or not item.Parent then
            if Drag.item then
                Drag.release()
            end
            return
        end
        if item ~= Drag.item then
            Drag.release()
            Drag.item = item
        end
        local cam = cameraPart()
        if not cam then
            return
        end
        -- the game aims the gas gun, jerrycans and turrets itself every frame
        local aimed = item:HasTag("GasGun") or item:HasTag("FuelContainer") or item:HasTag("Turret")
        for _, att in cam:GetChildren() do
            if att:IsA("Attachment") then
                Drag.holds[att] = Drag.holds[att] or att.CFrame
                local base = Drag.holds[att]
                if not aimed and (Settings.DragDistance ~= 1 or Settings.DragNoclip) then
                    att.CFrame = base + base.Position * (Settings.DragDistance - 1)
                end
                for _, c in att:GetChildren() do
                    if c:IsA("AlignPosition") then
                        c.Responsiveness, c.MaxForce = Settings.DragPower, 10000 * Settings.DragForce
                    elseif c:IsA("AlignOrientation") then
                        c.Responsiveness, c.MaxTorque = Settings.DragPower, 10000 * Settings.DragForce
                    end
                end
                if Settings.DragNoclip and not aimed then
                    -- keep the hold point above the ground under it
                    local params = RaycastParams.new()
                    params.FilterType = Enum.RaycastFilterType.Exclude
                    params.FilterDescendantsInstances = { item, character() }
                    local p = att.WorldPosition
                    local hit = Workspace:Raycast(p + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), params)
                    local ok, size = pcall(function()
                        return item:GetExtentsSize()
                    end)
                    local half = ok and size and size.Y / 2 or 1
                    if hit and p.Y < hit.Position.Y + half then
                        att.WorldPosition = Vector3.new(p.X, hit.Position.Y + half, p.Z)
                    end
                end
            end
        end
        for _, bp in item:GetDescendants() do
            if bp:IsA("BasePart") then
                if Settings.DragNoclip then
                    if Drag.parts[bp] == nil then
                        Drag.parts[bp] = bp.CanCollide
                    end
                    bp.CanCollide = false
                elseif Drag.parts[bp] ~= nil then
                    bp.CanCollide = Drag.parts[bp]
                    Drag.parts[bp] = nil
                end
            end
        end
    end
    bind(RunService.Heartbeat, function()
        if alive() then
            pcall(Drag.step)
        end
    end)
end

--// Fly \\--
-- Stays under the game's 300 studs/s limit.
local Fly = {}
do
    local controls
    pcall(function()
        controls = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")):GetControls()
    end)
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        dt = type(dt) == "number" and dt or 1 / 60
        local root, h = rootPart(), humanoid()
        if not (Settings.Fly and root and h) or h.SeatPart then
            if Fly.on and h then
                h.PlatformStand = false
            end
            Fly.on = false
            return
        end
        Fly.on = true
        h.PlatformStand = true
        local cam = Workspace.CurrentCamera.CFrame
        local move = Vector3.zero
        if controls then
            local ok, v = pcall(controls.GetMoveVector, controls)
            if ok and typeof(v) == "Vector3" then
                move = v
            end
        end
        local dir = cam.RightVector * move.X + cam.LookVector * -move.Z
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            dir += Vector3.new(0, 1, 0)
        elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
            dir -= Vector3.new(0, 1, 0)
        end
        -- moved by exactly speed x time each frame, held still otherwise, so
        -- the slider is the real speed
        local speed = math.min(Settings.FlySpeed, 250)
        root.AssemblyLinearVelocity = Vector3.zero
        if dir.Magnitude > 0 then
            root.CFrame = root.CFrame + dir.Unit * speed * dt
        end
    end)
    table.insert(Cleanups, function()
        local h = humanoid()
        if h then
            h.PlatformStand = false
        end
    end)
end

--// Cash and Credz \\--
local Collect = {}
do
    function Collect.pass()
        if not Settings.AutoCash then
            return
        end
        local root = rootPart()
        if not root then
            return
        end
        for _, kind in { "Cash", "Credz" } do
            for _, tag in CollectionService:GetTagged(kind) do
                local holder = tag.Parent
                if holder and inWorld(holder) then
                    local pos = pivotOf(holder)
                    if pos and (pos - root.Position).Magnitude <= Settings.CashRange then
                        local sensor = holder:FindFirstChild("TouchSensor")
                        if sensor and typeof(firetouchinterest) == "function" then
                            -- the way the game itself picks it up
                            pcall(firetouchinterest, root, sensor, 0)
                            pcall(firetouchinterest, root, sensor, 1)
                        else
                            Game.call(kind, "Collect", tag)
                        end
                    end
                end
            end
        end
    end
end
loop(0.25, Collect.pass)

--// Crime reports \\--
-- Quiet: the reports your own client makes (aiming at people, firing) aren't
-- sent. What the server works out by itself still counts.
Game.wrap("NPCs", "Threaten", function(old)
    return function(...)
        if alive() and Settings.Quiet then
            return
        end
        return old(...)
    end
end)
Game.wrap("UnlawfulFiring", "Shot", function(old)
    return function(...)
        if alive() and Settings.Quiet then
            return
        end
        return old(...)
    end
end)

--// Fall damage \\--
Game.wrap("ModifiersClient", "Get", function(old)
    return function(name, ...)
        if alive() and Settings.NoFall and name == "fallDamage" then
            return false
        end
        return old(name, ...)
    end
end)

--// Your car \\--
local Car = { base = {}, flippedSince = nil, lowWarned = false }
do
    local VehiclePkg = type(Packages.Vehicle) == "table" and Packages.Vehicle or nil
    function Car.current()
        local h = humanoid()
        local p = h and h.SeatPart
        while p and p ~= Workspace do
            if p:IsA("Model") and p:HasTag("Vehicle") then
                return p
            end
            p = p.Parent
        end
        for _, v in CollectionService:GetTagged("MainVehicle") do
            if inWorld(v) then
                return v
            end
        end
        return nil
    end
    function Car.spec(model)
        if not (VehiclePkg and model) then
            return nil
        end
        local ok, spec = pcall(VehiclePkg.GetSpec, model)
        return ok and type(spec) == "table" and spec or nil
    end
    local FIELDS = { topSpeedMPH = "SpeedMult", acceleration = "AccelMult", torque = "TorqueMult",
        brakingPower = "BrakeMult", turningAngle = "TurnMult" }
    function Car.tune()
        local spec = Car.spec(Car.current())
        if spec and Settings.Tune then
            local base = Car.base[spec]
            if not base then
                base = {}
                for f in FIELDS do
                    base[f] = spec[f]
                end
                Car.base[spec] = base
            end
            for f, key in FIELDS do
                if type(base[f]) == "number" then
                    spec[f] = base[f] * Settings[key]
                end
            end
        end
        if not Settings.Tune then
            Car.restore()
        end
    end
    function Car.restore()
        for spec, base in Car.base do
            for f, v in base do
                spec[f] = v
            end
        end
        table.clear(Car.base)
    end
    table.insert(Cleanups, Car.restore)
    function Car.fuel(model)
        model = model or Car.current()
        local gas = model and model:FindFirstChild("gasLevel")
        local spec = Car.spec(model)
        if not gas then
            return nil
        end
        local cap = spec and spec.gasCapacity or 100
        return gas.Value, cap
    end
    function Car.speed(model)
        local system = model and model:FindFirstChild("system")
        local chassis = system and system:FindFirstChild("chassis")
        local part = chassis or (model and model.PrimaryPart)
        return part and part.AssemblyLinearVelocity.Magnitude * 0.6263 or 0
    end
    -- Back on its wheels after a couple of seconds upside down and still.
    function Car.flipPass()
        local model = Car.current()
        if not (Settings.AutoFlip and model) then
            Car.flippedSince = nil
            return
        end
        local cf = model:GetPivot()
        if cf.UpVector.Y < 0.3 and Car.speed(model) < 5 then
            Car.flippedSince = Car.flippedSince or os.clock()
            if os.clock() - Car.flippedSince > 2 then
                Car.flippedSince = nil
                local look = cf.LookVector * Vector3.new(1, 0, 1)
                if look.Magnitude < 0.1 then
                    look = Vector3.new(0, 0, -1)
                end
                pcall(function()
                    model:PivotTo(CFrame.lookAt(cf.Position + Vector3.new(0, 4, 0), cf.Position + Vector3.new(0, 4, 0) + look.Unit))
                end)
            end
        else
            Car.flippedSince = nil
        end
    end
    -- Keeps pouring while you hold the gas gun or a jerrycan, until full.
    local pouring = nil
    function Car.pourPass()
        local obj = Settings.AutoPour and Game.dragged() or nil
        local level, cap = Car.fuel()
        local full = level and cap and level >= cap - 0.5
        local target, module
        if obj and typeof(obj) == "Instance" then
            if obj:HasTag("GasGun") then
                target, module = obj.Parent, "GasPump"
            elseif obj:HasTag("FuelContainer") or obj.Name:lower():find("jerry") then
                target, module = obj, "FuelContainer"
            end
        end
        if pouring and (pouring[1] ~= target or full) then
            Game.call(pouring[2], "Pour", pouring[1], false)
            pouring = nil
        end
        if target and not full and not pouring then
            Game.call(module, "Pour", target, true)
            pouring = { target, module }
        end
    end
    function Car.lowFuelPass()
        local level, cap = Car.fuel()
        if not (Settings.LowFuelAlert and level and cap and cap > 0) then
            return
        end
        local pct = level / cap * 100
        if pct <= Settings.LowFuelAt and not Car.lowWarned then
            Car.lowWarned = true
            notify(("Low fuel: %d%%"):format(math.floor(pct)), 5)
        elseif pct > Settings.LowFuelAt + 5 then
            Car.lowWarned = false
        end
    end
end
loop(0.5, function()
    Car.tune()
    Car.lowFuelPass()
end)
loop(0.25, function()
    Car.flipPass()
    Car.pourPass()
end)

--// Car fly, boost and handling \\--
-- You drive your own car's physics, so its velocity can be set directly.
-- Input comes from the keys, the driver's seat and the movement stick, so it
-- works the same on PC and phone. Forward is the way the driver's seat faces.
local CarMove = { flying = false }
do
    local controls
    pcall(function()
        controls = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")):GetControls()
    end)
    local function key(...)
        for _, k in { ... } do
            if UserInputService:IsKeyDown(k) then
                return true
            end
        end
        return false
    end
    -- throttle: +1 forward, -1 back; steer: +1 right
    function CarMove.input(seat)
        local K = Enum.KeyCode
        local throttle = (key(K.W, K.Up) and 1 or 0) - (key(K.S, K.Down) and 1 or 0)
        local steer = (key(K.D, K.Right) and 1 or 0) - (key(K.A, K.Left) and 1 or 0)
        local function take(t, st)
            if math.abs(t) > math.abs(throttle) then
                throttle = t
            end
            if math.abs(st) > math.abs(steer) then
                steer = st
            end
        end
        take(seat.ThrottleFloat or 0, seat.SteerFloat or 0)
        if controls then
            local ok, v = pcall(controls.GetMoveVector, controls)
            if ok and typeof(v) == "Vector3" then
                -- the game doubles the stick, so half a push is full throttle
                take(math.clamp(-v.Z * 2, -1, 1), math.clamp(v.X * 2, -1, 1))
            end
        end
        return math.clamp(throttle, -1, 1), math.clamp(steer, -1, 1)
    end
    local function driving()
        local h = humanoid()
        local seat = h and h.SeatPart
        if not (seat and seat:IsA("VehicleSeat")) then
            return nil
        end
        local model = Car.current()
        local system = model and model:FindFirstChild("system")
        local chassis = system and system:FindFirstChild("chassis")
        if not (chassis and chassis:IsA("BasePart")) then
            return nil
        end
        return model, chassis, seat
    end
    CarMove.driving = driving
    local function flat(v)
        local f = Vector3.new(v.X, 0, v.Z)
        return f.Magnitude > 1e-3 and f.Unit or nil
    end
    bind(RunService.Heartbeat, function(dt)
        if not alive() then
            return
        end
        dt = type(dt) == "number" and dt or 1 / 60
        local model, chassis, seat = driving()
        if not model then
            CarMove.flying = false
            return
        end
        local throttle, steer = CarMove.input(seat)
        local fwd = flat(seat.CFrame.LookVector) or Vector3.new(0, 0, -1)
        local right = flat(seat.CFrame.RightVector) or Vector3.new(1, 0, 0)
        if Settings.CarFly then
            CarMove.flying = true
            local cam = Workspace.CurrentCamera.CFrame
            local pivot = model:GetPivot()
            -- how the driver's seat sits in the car, so "forward" is the
            -- way you face when the car is turned
            local seatRel = pivot:ToObjectSpace(seat.CFrame).Rotation
            local face, side
            if Settings.CarFlyHeading then
                -- the car's own heading; steering turns it
                local yawed = CFrame.lookAt(Vector3.zero, fwd) * CFrame.Angles(0, -steer * Settings.CarFlyTurn * dt, 0)
                face = yawed.LookVector + Vector3.new(0, cam.LookVector.Y, 0)
                side = Vector3.zero
            else
                -- where the camera looks. A/D do nothing here: the camera is
                -- the steering, and sliding sideways read as moving on its own.
                face = cam.LookVector
                side = Vector3.zero
            end
            face = face.Magnitude > 1e-3 and face.Unit or fwd
            -- never straight up or down (the car would flip over the top)
            if math.abs(face.Y) > 0.9 then
                local f = flat(face) or fwd
                face = (f * 0.436 + Vector3.new(0, face.Y > 0 and 0.9 or -0.9, 0)).Unit
            end
            -- speeds up and slows down smoothly toward the target speed
            local want = face * throttle + side
            if want.Magnitude > 1 then
                want = want.Unit
            end
            want *= Settings.CarFlySpeed
            -- stopping is quicker than speeding up, so letting go stops it
            local blend = 1 - math.exp(-Settings.CarFlyResponse * (want.Magnitude == 0 and 2.5 or 1) * dt)
            CarMove.vel = (CarMove.vel or Vector3.zero):Lerp(want, blend)
            if CarMove.vel.Magnitude < 0.05 and want.Magnitude == 0 then
                CarMove.vel = Vector3.zero
            end
            -- the car turns to face the same way, quickly but not in a snap
            -- turns only while you're flying somewhere, so a camera that
            -- drifts on its own (phones) can't turn a parked car
            local rot = pivot.Rotation
            if math.abs(throttle) > 0.05 or Settings.CarFlyHeading then
                local target = CFrame.lookAt(Vector3.zero, face) * seatRel:Inverse()
                rot = rot:Lerp(target, 1 - math.exp(-10 * dt))
            end
            -- moved by velocity x time and held still in between, so the
            -- speed is exact and the car's own engine can't add to it
            for _, part in model:GetDescendants() do
                if part:IsA("BasePart") and part.AssemblyRootPart == part then
                    part.AssemblyLinearVelocity = Vector3.zero
                    part.AssemblyAngularVelocity = Vector3.zero
                end
            end
            pcall(function()
                model:PivotTo(CFrame.new(pivot.Position + CarMove.vel * dt) * rot)
            end)
            return
        end
        CarMove.vel = nil
        CarMove.flying = false
        if not (Settings.CarBoost or Settings.BrakeAssist or Settings.AntiDrift or Settings.SteerAssist or Settings.Stabilize) then
            return
        end
        local v = chassis.AssemblyLinearVelocity
        local flatV = Vector3.new(v.X, 0, v.Z)
        local speed = flatV.Magnitude
        local along = flatV:Dot(fwd)
        local boosting = false
        -- Boost: on the throttle, speeds up past the car's own top speed
        -- along the way the car faces (not the way it's sliding), and keeps
        -- it drivable: the slide is taken out, steering turns at a steady
        -- rate, tipping is damped and it's pressed onto the road.
        if Settings.CarBoost and throttle > 0.1 and along > 5 then
            boosting = true
            local newAlong = along
            if along < Settings.BoostSpeed then
                newAlong = math.min(along + Settings.BoostAccel * dt * throttle, Settings.BoostSpeed)
            end
            local slide = flatV:Dot(right)
            flatV = fwd * newAlong + right * slide * (1 - Settings.BoostGrip)
            v = Vector3.new(v.X, math.min(v.Y, 15) - Settings.BoostDownforce * dt, v.Z)
        end
        -- Brake assist: braking (throttle back while rolling forward) bites harder.
        if Settings.BrakeAssist and throttle < -0.1 and along > 5 then
            local new = math.max(speed - Settings.BrakePower * dt * -throttle, 0)
            flatV = speed > 0 and flatV.Unit * new or flatV
        end
        -- Anti drift: the sideways slide is taken out, so the car goes where
        -- it points instead of sliding off at speed.
        if Settings.AntiDrift and speed > Settings.DriftFrom then
            local side = flatV:Dot(right)
            flatV -= right * side * Settings.Grip
        end
        chassis.AssemblyLinearVelocity = Vector3.new(flatV.X, v.Y, flatV.Z)
        local av = chassis.AssemblyAngularVelocity
        if boosting then
            av = Vector3.new(av.X * 0.5, -steer * Settings.BoostTurn, av.Z * 0.5)
        end
        -- Steering assist: at speed, the car turns at a steady rate.
        if Settings.SteerAssist and speed > Settings.DriftFrom and math.abs(steer) > 0.05 then
            local dirSign = along >= 0 and 1 or -1
            av = Vector3.new(av.X, -steer * Settings.SteerPower * dirSign, av.Z)
        end
        -- Stabilize: damps the rolling and pitching that flips cars at speed.
        if Settings.Stabilize then
            av = Vector3.new(av.X * 0.6, av.Y, av.Z * 0.6)
        end
        chassis.AssemblyAngularVelocity = av
    end)
end

--// Travel: flying to places (auto sell, checkpoints) \\--
local Travel = { busy = false, status = "idle" }
do
    local function groundBelow(pos, ignore)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignore
        local hit = Workspace:Raycast(pos + Vector3.new(0, 300, 0), Vector3.new(0, -800, 0), params)
        return hit and hit.Position or nil
    end
    Travel.groundBelow = groundBelow
    -- On foot to a point at a set speed (kept under the game's 300 limit),
    -- moved by position each frame so walls don't stop it.
    function Travel.footTo(target, speed)
        local root, h = rootPart(), humanoid()
        if not (root and h) then
            return false
        end
        speed = math.min(speed, 250)
        h.PlatformStand = true
        local t0 = os.clock()
        while alive() and root.Parent and os.clock() - t0 < 30 do
            local dt = RunService.Heartbeat:Wait()
            local diff = target - root.Position
            if diff.Magnitude < 1.5 then
                break
            end
            local step = math.min(diff.Magnitude, speed * dt)
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.new(root.Position + diff.Unit * step) * root.CFrame.Rotation
        end
        root.AssemblyLinearVelocity = Vector3.zero
        h.PlatformStand = false
        return (target - root.Position).Magnitude < 3
    end

    -- The road, from the game's own road tracker: its path points (or a
    -- straight road along Z) and where the borders (checkpoints) are.
    function Travel.road()
        local rp = Game.module("RoadProgressClient")
        if not (rp and rp.Along and typeof(debug) == "table" and debug.getupvalues) then
            return nil
        end
        local ok, ups = pcall(debug.getupvalues, rp.Along)
        if not ok or type(ups) ~= "table" then
            return nil
        end
        local road = { straight = false, points = {}, offset = 0 }
        for _, up in ups do
            if type(up) == "boolean" then
                road.straight = up
            elseif type(up) == "number" then
                road.offset = up
            elseif type(up) == "table" and type(up[1]) == "table" and up[1].along then
                road.points = up
            end
        end
        local okB, borders = pcall(rp.Borders)
        road.borders = {}
        for _, b in okB and type(borders) == "table" and borders or {} do
            local a = type(b) == "number" and b or (type(b) == "table" and (b.along or b.Along or b.distance or b[1])) or nil
            if type(a) == "number" then
                table.insert(road.borders, a)
            end
        end
        table.sort(road.borders)
        road.along = function(pos)
            local okA, a = pcall(rp.Along, pos)
            return okA and a or nil
        end
        return road
    end
    -- A world point (x, z) at a distance along the road.
    function Travel.pointAt(road, along, nearX)
        local pts = road.points
        if road.straight or #pts < 2 then
            return Vector3.new(nearX or 0, 0, along + road.offset)
        end
        if along <= pts[1].along then
            return Vector3.new(pts[1].x, 0, pts[1].z)
        end
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            if along <= b.along then
                local t = (along - a.along) / math.max(b.along - a.along, 1e-6)
                return Vector3.new(a.x + (b.x - a.x) * t, 0, a.z + (b.z - a.z) * t)
            end
        end
        local last = pts[#pts]
        return Vector3.new(last.x, 0, last.z)
    end
    function Travel.nextCheckpoint()
        local road = Travel.road()
        local root = rootPart()
        if not (road and root) then
            return nil, "couldn't read the road"
        end
        local here = road.along(root.Position)
        if not here then
            return nil, "couldn't place you on the road"
        end
        for _, b in road.borders do
            if b > here + 10 then
                return road, here, b
            end
        end
        return nil, "no checkpoint ahead"
    end
    -- Flies the car along the road to just past the next checkpoint, a
    -- little above it, then sets it down on the road.
    function Travel.toCheckpoint()
        if Travel.busy then
            return
        end
        local model, chassis = CarMove.driving()
        if not model then
            notify("Get in the driver's seat first", 3)
            return
        end
        local road, here, goal = Travel.nextCheckpoint()
        if not road then
            notify("Checkpoint: " .. tostring(here), 4)
            return
        end
        Travel.busy = true
        local target = goal + 25
        local along = here
        local root = rootPart()
        local x0 = root and root.Position.X or 0
        local ignore = { model, character() }
        Travel.status = ("flying %d studs to the checkpoint"):format(math.floor(target - here))
        while alive() and along < target do
            local dt = RunService.Heartbeat:Wait()
            if not CarMove.driving() then
                break
            end
            along = math.min(along + Settings.CheckpointSpeed * dt, target)
            local p = Travel.pointAt(road, along, x0)
            local ahead = Travel.pointAt(road, along + 10, x0)
            local ground = groundBelow(p, ignore)
            local y = (ground and ground.Y or model:GetPivot().Position.Y) + Settings.CheckpointHeight
            local pos = Vector3.new(p.X, y, p.Z)
            local look = Vector3.new(ahead.X - p.X, 0, ahead.Z - p.Z)
            for _, part in model:GetDescendants() do
                if part:IsA("BasePart") and part.AssemblyRootPart == part then
                    part.AssemblyLinearVelocity = Vector3.zero
                    part.AssemblyAngularVelocity = Vector3.zero
                end
            end
            pcall(function()
                local seat = humanoid().SeatPart
                local seatRel = model:GetPivot():ToObjectSpace(seat.CFrame).Rotation
                model:PivotTo(CFrame.lookAt(pos, pos + (look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1))) * seatRel:Inverse())
            end)
        end
        -- down onto the road
        local pivot = model:GetPivot()
        local ground = groundBelow(pivot.Position, ignore)
        if ground then
            pcall(function()
                model:PivotTo(CFrame.new(Vector3.new(pivot.Position.X, ground.Y + 4, pivot.Position.Z)) * pivot.Rotation)
            end)
        end
        Travel.status = along >= target and "at the checkpoint" or "stopped"
        Travel.busy = false
    end
end

--// Auto sell \\--
-- When your backpack is full: on foot to the nearest pawn counter within
-- range, each piece of loot put up through the counter's own "Add item to
-- sell" prompt, wait until the cash actually comes in, then back.
local Sell = { busy = false, status = "idle", lastTry = -math.huge }
do
    local function cash()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        for _, v in ls and ls:GetChildren() or {} do
            if v.Name:sub(1, 4) == "Cash" and v:IsA("ValueBase") then
                return v.Value
            end
        end
        return 0
    end
    Sell.cash = cash
    local function isLoot(tool)
        if not tool:IsA("Tool") or tool:HasTag("Undroppable") then
            return false
        end
        if Game.toolConfig(tool) then
            return false -- weapons and tools aren't sold here
        end
        local loot = Data.Loot
        local ok, data = pcall(function()
            return loot.GetItemData(tool.Name)
        end)
        return (ok and data ~= nil) or tool:HasTag("Equippable")
    end
    function Sell.items()
        local out = {}
        for _, where in { LocalPlayer:FindFirstChildOfClass("Backpack"), character() } do
            for _, t in where and where:GetChildren() or {} do
                if isLoot(t) then
                    table.insert(out, t)
                end
            end
        end
        return out
    end
    function Sell.limit()
        local m = Game.module("BackpackCapacity")
        local ok, n = pcall(function()
            return m.GetSlotLimit()
        end)
        return ok and type(n) == "number" and n or (Game.balance("MaxTools") or 10)
    end
    function Sell.full()
        local count = 0
        for _, where in { LocalPlayer:FindFirstChildOfClass("Backpack"), character() } do
            for _, t in where and where:GetChildren() or {} do
                if t:IsA("Tool") then
                    count += 1
                end
            end
        end
        local at = Settings.SellAt > 0 and Settings.SellAt or Sell.limit()
        return #Sell.items() > 0 and count >= at
    end
    function Sell.counter()
        local root = rootPart()
        if not root then
            return nil
        end
        local best, bestD
        for _, counter in CollectionService:GetTagged("PawnCounter") do
            local bell = counter:FindFirstChild("CallBell")
            local prompt = bell and bell:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and inWorld(counter) then
                local d = (bell.Position - root.Position).Magnitude
                if d <= Settings.SellRange and (not bestD or d < bestD) then
                    best, bestD = { bell = bell, prompt = prompt, counter = counter }, d
                end
            end
        end
        return best, bestD
    end
    local function press(prompt)
        local hold = prompt.HoldDuration
        prompt.HoldDuration = 0
        if typeof(fireproximityprompt) == "function" then
            pcall(fireproximityprompt, prompt)
        else
            pcall(function()
                prompt:InputHoldBegin()
                task.wait()
                prompt:InputHoldEnd()
            end)
        end
        prompt.HoldDuration = hold
    end
    function Sell.run()
        if Sell.busy or Travel.busy then
            return
        end
        local h, root = humanoid(), rootPart()
        if not (h and root) or h.SeatPart then
            Sell.status = "get out of the car to sell"
            return
        end
        local spot, dist = Sell.counter()
        if not spot then
            Sell.status = ("no pawn counter within %d studs"):format(Settings.SellRange)
            return
        end
        Sell.busy = true
        local home = root.CFrame
        local startCash = cash()
        -- stand by the bell, on the side you came from
        local away = Vector3.new(root.Position.X - spot.bell.Position.X, 0, root.Position.Z - spot.bell.Position.Z)
        away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
        local stand = spot.bell.Position + away * 3.5 + Vector3.new(0, 1.5, 0)
        Sell.status = ("flying %d studs to the pawn counter"):format(math.floor(dist))
        if Travel.footTo(stand, Settings.SellSpeed) then
            local items = Sell.items()
            Sell.status = ("selling %d items"):format(#items)
            for _, tool in items do
                if not alive() then
                    break
                end
                pcall(h.EquipTool, h, tool)
                task.wait(0.25)
                press(spot.prompt)
                task.wait(0.35)
            end
            pcall(h.UnequipTools, h)
            task.wait(0.2)
            press(spot.prompt) -- with nothing in hand: in case the bell is what sells
            -- only go back once the money has actually come in
            local t0 = os.clock()
            while alive() and cash() <= startCash and os.clock() - t0 < 8 do
                task.wait(0.2)
            end
            local gained = cash() - startCash
            Sell.status = gained > 0 and ("sold for $%d"):format(gained) or "no cash came in (the counter may need you to do something)"
            Travel.footTo(home.Position, Settings.SellSpeed)
            pcall(function()
                root.CFrame = home
            end)
        else
            Sell.status = "couldn't reach the pawn counter"
        end
        Sell.lastTry = os.clock()
        Sell.busy = false
    end
end
loop(1, function()
    if Settings.AutoSell and not Sell.busy and os.clock() - Sell.lastTry > 10 and Sell.full() then
        Sell.run()
    end
end)

--// Survival \\--
local Survive = { lastEat = 0, revivedFor = nil, lowWarned = false }
do
    function Survive.consumable()
        for _, where in { LocalPlayer:FindFirstChildOfClass("Backpack"), character() } do
            for _, t in where and where:GetChildren() or {} do
                if t:IsA("Tool") and t:HasTag("Consumable") then
                    return t
                end
            end
        end
        return nil
    end
    function Survive.pass()
        local c, h = character(), humanoid()
        if not (c and h and h.MaxHealth > 0) then
            return
        end
        local pct = h.Health / h.MaxHealth * 100
        local downed = c:GetAttribute("Downed") == true
        -- eat when hurt, through the item's own use so its animation plays
        if Settings.AutoEat and not downed and h.Health > 0 and pct <= Settings.EatAt and os.clock() - Survive.lastEat > 6 then
            local tool = Survive.consumable()
            if tool then
                Survive.lastEat = os.clock()
                pcall(function()
                    if tool.Parent ~= c then
                        h:EquipTool(tool)
                    end
                    task.wait(0.25)
                    tool:Activate()
                end)
            end
        end
        -- free revives only, never a purchase
        if Settings.AutoRevive and downed and Survive.revivedFor ~= c then
            local free = Game.localData("freeRevives")
            if type(free) == "number" and free > 0 then
                Survive.revivedFor = c
                Game.call("Revive", "TryRevive")
                notify("Used a free revive", 4)
            end
        end
        if not downed then
            Survive.revivedFor = nil
        end
        if Settings.LowHpAlert then
            if pct <= 25 and h.Health > 0 and not Survive.lowWarned then
                Survive.lowWarned = true
                notify(("Low health: %d%%"):format(math.floor(pct)), 4)
            elseif pct > 35 then
                Survive.lowWarned = false
            end
        end
    end
    bind(LocalPlayer.Idled, function()
        if Settings.AntiAfk then
            pcall(function()
                local vu = game:GetService("VirtualUser")
                vu:CaptureController()
                vu:ClickButton2(Vector2.new())
            end)
        end
    end)
end
loop(0.5, Survive.pass)

--// Police alerts \\--
local Police = { lastAlert = 0 }
function Police.nearest()
    local root = rootPart()
    if not root then
        return nil
    end
    local best, bestD
    local function consider(model)
        local pos = pivotOf(model)
        if pos then
            local d = (pos - root.Position).Magnitude
            if not bestD or d < bestD then
                best, bestD = model, d
            end
        end
    end
    for _, m in People.npcs() do
        if People.isPolice(m) then
            consider(m)
        end
    end
    for _, v in People.policeVehicles() do
        consider(v)
    end
    return best, bestD
end
loop(1, function()
    if not Settings.PoliceAlert then
        return
    end
    local who, d = Police.nearest()
    if who and d <= Settings.AlertRange and os.clock() - Police.lastAlert > 12 then
        Police.lastAlert = os.clock()
        notify(("Police %d studs away (%s)"):format(math.floor(d), who.Name), 4)
    end
end)

--// ESP \\--
local Esp = { tags = {}, folder = Instance.new("Folder") }
Esp.folder.Name = "RunawaysEsp"
Esp.folder.Parent = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
table.insert(Cleanups, function()
    Esp.folder:Destroy()
end)
do
    local function tag(key, adornee, color)
        local t = Esp.tags[key]
        if not t or not t.gui.Parent then
            local gui = Instance.new("BillboardGui")
            gui.AlwaysOnTop, gui.Size, gui.StudsOffset = true, UDim2.fromOffset(160, 34), Vector3.new(0, 3, 0)
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency, label.Size = 1, UDim2.fromScale(1, 1)
            label.Font, label.TextSize, label.TextStrokeTransparency = Enum.Font.GothamBold, 13, 0.3
            label.Parent = gui
            gui.Parent = Esp.folder
            t = { gui = gui, label = label }
            Esp.tags[key] = t
        end
        t.gui.Adornee = adornee
        t.label.TextColor3 = color
        t.seen = true
        return t.label
    end
    local RED, ORANGE, WHITE, GREEN, PINK, YELLOW =
        Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 160, 40), Color3.fromRGB(235, 235, 235),
        Color3.fromRGB(80, 230, 110), Color3.fromRGB(255, 105, 200), Color3.fromRGB(255, 225, 90)
    local function hp(model)
        local h = model:FindFirstChildOfClass("Humanoid")
        return (Settings.EspHealth and h) and ("  %d hp"):format(math.floor(h.Health)) or ""
    end
    local function value(name)
        local loot = Data.Loot
        if not (loot and loot.GetItemValue) then
            return nil
        end
        local ok, v = pcall(loot.GetItemValue, name)
        return ok and type(v) == "number" and v or nil
    end
    function Esp.pass()
        for _, t in Esp.tags do
            t.seen = false
        end
        local root = rootPart()
        local here = root and root.Position or Vector3.zero
        local function dist(pos)
            return math.floor((pos - here).Magnitude)
        end
        for _, m in People.npcs() do
            local police = People.isPolice(m)
            local head = m:FindFirstChild("Head") or m:FindFirstChild("HumanoidRootPart")
            if head and ((police and Settings.PoliceEsp) or (not police and Settings.EspNPC)) then
                tag(m, head, police and RED or WHITE).Text = ("%s%s  %dm"):format(police and "POLICE " or m.Name, hp(m), dist(head.Position))
            end
        end
        if Settings.EspPlayers then
            for _, m in People.others() do
                local head = m:FindFirstChild("Head")
                if head then
                    tag(m, head, YELLOW).Text = ("%s%s  %dm"):format(m.Name, hp(m), dist(head.Position))
                end
            end
        end
        if Settings.PoliceEsp then
            for _, v in People.policeVehicles() do
                local pos = pivotOf(v)
                local part = v.PrimaryPart or v:FindFirstChildWhichIsA("BasePart", true)
                if pos and part then
                    tag(v, part, ORANGE).Text = ("%s  %dm"):format(v:HasTag("PoliceHeli") and "POLICE HELI" or "POLICE CAR", dist(pos))
                end
            end
        end
        if Settings.LootEsp then
            for _, m in CollectionService:GetTagged("DamageToOpen") do
                local part = inWorld(m) and (m:IsA("BasePart") and m or m:FindFirstChildWhichIsA("BasePart", true))
                if part then
                    tag(m, part, GREEN).Text = ("%s  %dm"):format(m.Name, dist(part.Position))
                end
            end
            local loot = Workspace:FindFirstChild("Loot")
            for _, item in loot and loot:GetChildren() or {} do
                local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    local v = value(item.Name)
                    tag(item, part, GREEN).Text = ("%s%s  %dm"):format(item.Name, v and (" $" .. v) or "", dist(part.Position))
                end
            end
        end
        if Settings.CashEsp then
            for _, kind in { "Cash", "Credz" } do
                for _, t in CollectionService:GetTagged(kind) do
                    local holder = t.Parent
                    if holder and holder:IsA("BasePart") and inWorld(holder) then
                        tag(t, holder, kind == "Cash" and GREEN or PINK).Text = ("%s  %dm"):format(kind, dist(holder.Position))
                    end
                end
            end
        end
        for key, t in Esp.tags do
            if not t.seen then
                t.gui:Destroy()
                Esp.tags[key] = nil
            end
        end
    end
end
loop(0.4, Esp.pass)

--// World \\--
local World = { saved = nil }
do
    local KEYS = { "Brightness", "ClockTime", "FogEnd", "FogStart", "GlobalShadows", "Ambient", "OutdoorAmbient" }
    function World.save()
        if World.saved then
            return
        end
        World.saved = {}
        for _, k in KEYS do
            World.saved[k] = Lighting[k]
        end
    end
    function World.restore()
        if not World.saved then
            return
        end
        for k, v in World.saved do
            pcall(function()
                Lighting[k] = v
            end)
        end
        World.saved = nil
    end
    table.insert(Cleanups, World.restore)
    function World.pass()
        if Settings.Fullbright or Settings.NoFog then
            World.save()
        end
        if Settings.Fullbright then
            Lighting.Brightness, Lighting.ClockTime, Lighting.GlobalShadows = 2, 14, false
            Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180), Color3.fromRGB(180, 180, 180)
        end
        if Settings.NoFog then
            Lighting.FogEnd, Lighting.FogStart = 1e6, 1e6
            for _, a in Lighting:GetChildren() do
                if a:IsA("Atmosphere") then
                    a.Density, a.Haze = 0, 0
                end
            end
        end
        if not Settings.Fullbright and not Settings.NoFog then
            World.restore()
        end
    end
    -- the weather is set on your side, so it can be kept clear
    Game.wrap("LightingClient", "SetWeather", function(old)
        return function(name, ...)
            if alive() and Settings.NoWeather then
                return old("Clear", ...)
            end
            return old(name, ...)
        end
    end)
    local boosted = {}
    function World.boostPass()
        if Settings.FpsBoost then
            for _, d in Workspace:GetDescendants() do
                if (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke") or d:IsA("Fire")) and d.Enabled and not boosted[d] then
                    boosted[d] = true
                    d.Enabled = false
                end
            end
        else
            for d in boosted do
                pcall(function()
                    d.Enabled = true
                end)
            end
            table.clear(boosted)
        end
    end
    table.insert(Cleanups, function()
        Settings.FpsBoost = false
        World.boostPass()
    end)
end
loop(1, World.pass)
loop(5, World.boostPass)

--// UI \\--
local Window = Library:CreateWindow({
    Title = "Runaways",
    Footer = "dookie hub · Ui3",
    Icon = "car",
    Size = UDim2.fromOffset(680, 540),
    ConfigFolder = "Ui3/Runaways",
})
local UI = {}
do
    function UI.toggle(box, key, text, tip, after)
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
    function UI.slider(box, key, text, min, max, rounding, suffix, tip)
        return box:AddSlider(key, {
            Text = text, Default = Settings[key], Min = min, Max = max, Rounding = rounding, Suffix = suffix, Tooltip = tip,
            Callback = function(v)
                Settings[key] = v
            end,
        })
    end
    function UI.choice(box, key, text, values, tip)
        return box:AddDropdown(key, {
            Text = text, Values = values, Default = Settings[key], Tooltip = tip,
            Callback = function(v)
                Settings[key] = v or values[1]
            end,
        })
    end
end

-- Combat
do
    local Tab = Window:AddTab("Combat", "crosshair", "Guns, melee, ESP")
    local AimBox = Tab:AddLeftGroupbox("Silent aim", "crosshair")
    UI.toggle(AimBox, "SilentAim", "Silent aim", "Your shots go to the nearest target inside the circle")
    UI.toggle(AimBox, "AimNPC", "Civilians")
    UI.toggle(AimBox, "AimPolice", "Police")
    UI.toggle(AimBox, "AimPlayers", "Players")
    UI.choice(AimBox, "AimPart", "Aim at", { "Head", "Torso" }, "Heads take 1.5x damage in this game")
    UI.slider(AimBox, "FOV", "Circle size", 30, 600, 0, " px")
    UI.toggle(AimBox, "ShowFOV", "Show circle")
    UI.toggle(AimBox, "VisibleCheck", "Only visible targets")
    UI.slider(AimBox, "HitChance", "Hit chance", 1, 100, 0, "%")
    local AimLabel = AimBox:AddLabel("...", true)
    loop(0.3, function()
        if Settings.SilentAim then
            Aim.find()
        end
        AimLabel:SetText(("%s · shots steered %d\nHooked: %s"):format(Settings.SilentAim and Aim.status or "off",
            Aim.shots or 0, Aim.hook))
    end)

    local GunBox = Tab:AddRightGroupbox("Guns", "zap")
    UI.toggle(GunBox, "NoRecoil", "No recoil")
    UI.toggle(GunBox, "NoSpread", "No spread", "Every shot goes exactly where you aim")
    if not Flow then
        GunBox:AddLabel("Couldn't reach the game's Flow table, so silent aim, recoil and spread can't work in this executor", true)
    end

    local MeleeBox = Tab:AddRightGroupbox("Melee aura", "swords")
    UI.toggle(MeleeBox, "MeleeAura", "Melee aura", "While you hold a melee weapon, hits NPCs around you with that weapon's damage")
    UI.slider(MeleeBox, "MeleeRange", "Range", 1, 30, 0, " studs")
    UI.toggle(MeleeBox, "MeleeWeaponSpeed", "Weapon's own speed", "Swings at the weapon's own hits per second. Off: the slider below")
    UI.slider(MeleeBox, "MeleeEvery", "Every", 0.05, 2, 2, " s")
    UI.slider(MeleeBox, "MeleeTargets", "Targets per swing", 1, 20, 0)
    UI.toggle(MeleeBox, "MeleeCivilians", "Hit civilians")
    UI.toggle(MeleeBox, "MeleePolice", "Hit police")
    UI.toggle(MeleeBox, "MeleeBreak", "Also break things", "Each swing also hits breakables in range")

    local ModBox = Tab:AddLeftGroupbox("Gun mods", "settings")
    local function mods()
        Guns.apply()
        Guns.reequip()
    end
    UI.toggle(ModBox, "GunMods", "Gun mods", "Changes your guns' own numbers. Your gun is re-equipped so it takes effect", mods)
    UI.slider(ModBox, "RpmMult", "Fire rate", 0.5, 20, 2, "x")
    UI.toggle(ModBox, "ForceAuto", "Full auto", "Hold to fire with every gun", mods)
    UI.toggle(ModBox, "InfAmmo", "Infinite ammo", "Your gun stops counting rounds. The server may still check", mods)
    UI.slider(ModBox, "DamageMult", "Damage", 1, 5, 2, "x")
    UI.slider(ModBox, "ExtraPellets", "Extra bullets per shot", 0, 10, 0)
    UI.toggle(ModBox, "Wallbang", "Shoot through people", "Bullets carry on through NPCs into the ones behind", mods)
    ModBox:AddButton({ Text = "Apply to my gun now", Func = mods })

    local AuraBox = Tab:AddRightGroupbox("Gun aura", "target")
    UI.toggle(AuraBox, "GunAura", "Gun aura", "While you hold a gun, it shoots the nearest NPC in range at the gun's own fire rate")
    UI.slider(AuraBox, "GunAuraRange", "Range", 10, 400, 0, " studs")
    UI.toggle(AuraBox, "GunAuraPolice", "Police")
    UI.toggle(AuraBox, "GunAuraCivilians", "Civilians")
    UI.toggle(AuraBox, "ShootCops", "Shoot police cars and helicopters", "While you hold a gun, shoots the nearest police car or helicopter in range")
    UI.slider(AuraBox, "CopShootRange", "Police vehicle range", 20, 600, 0, " studs")
    UI.toggle(AuraBox, "AutoShoot", "Auto shoot",
        "Shoots whoever silent aim has in the circle, at your gun's fire rate with your gun mods. Uses the silent aim settings for who to aim at")

    local MoveBox = Tab:AddRightGroupbox("Movement", "wind")
    UI.toggle(MoveBox, "Fly", "Fly", "Move with your normal controls, Space up, Ctrl down. Off while seated")
    UI.slider(MoveBox, "FlySpeed", "Speed", 2, 250, 0, " studs/s", "The real speed. Capped under the game's 300 studs/s limit")

    local EspBox = Tab:AddLeftGroupbox("ESP", "eye")
    UI.toggle(EspBox, "EspNPC", "Civilians")
    UI.toggle(EspBox, "EspPlayers", "Players")
    UI.toggle(EspBox, "EspHealth", "Show health")
end

-- Police and heat
do
    local Tab = Window:AddTab("Police", "siren", "Heat, stars, police")
    local HeatBox = Tab:AddLeftGroupbox("Heat", "flame")
    local HeatLabel = HeatBox:AddLabel("...", true)
    UI.toggle(HeatBox, "Quiet", "Quiet", "Your client doesn't report you aiming at people or firing. What the server sees by itself still counts")

    local CopBox = Tab:AddRightGroupbox("Police", "shield")
    UI.toggle(CopBox, "PoliceEsp", "Police ESP", "Officers, police cars and the helicopter")
    UI.toggle(CopBox, "PoliceAlert", "Alert when close")
    UI.slider(CopBox, "AlertRange", "Alert range", 30, 500, 0, " studs")
    local NearLabel = CopBox:AddLabel("...", true)

    loop(0.5, function()
        local cool = Game.balance("CooloffDelay")
        HeatLabel:SetText(("Heat %s · stars %s · bounty $%s%s"):format(
            tostring(math.floor(Game.state("Heat") * 10) / 10), tostring(Game.state("Stars")), tostring(math.floor(Game.state("Bounty"))),
            cool and ("\nHeat starts cooling %ds after your last crime"):format(cool) or ""))
        local who, d = Police.nearest()
        NearLabel:SetText(who and ("Nearest: %s, %d studs"):format(who.Name, math.floor(d)) or "No police around")
    end)
end

-- Driving
do
    local Tab = Window:AddTab("Driving", "car", "Your car and fuel")
    local TuneBox = Tab:AddLeftGroupbox("Tuning", "gauge")
    UI.toggle(TuneBox, "Tune", "Tune my car", "Multiplies your car's own top speed, acceleration and so on. Off puts them back")
    UI.slider(TuneBox, "SpeedMult", "Top speed", 0.5, 10, 2, "x")
    UI.slider(TuneBox, "AccelMult", "Acceleration", 0.5, 12, 2, "x")
    UI.slider(TuneBox, "TorqueMult", "Torque", 0.5, 10, 2, "x")
    UI.slider(TuneBox, "BrakeMult", "Brakes", 0.5, 25, 2, "x")
    UI.slider(TuneBox, "TurnMult", "Steering", 0.5, 3, 2, "x")
    UI.toggle(TuneBox, "AutoFlip", "Auto flip", "Puts the car back on its wheels after 2 s upside down")

    local FastBox = Tab:AddLeftGroupbox("Go fast", "rocket")
    UI.toggle(FastBox, "CarBoost", "Speed boost", "Hold the throttle and the car keeps speeding up past its own top speed, up to the speed below")
    UI.slider(FastBox, "BoostSpeed", "Boost up to", 50, 1000, 0, " studs/s")
    UI.slider(FastBox, "BoostAccel", "Boost pick-up", 20, 600, 0, " studs/s²")
    UI.slider(FastBox, "BoostGrip", "Boost grip", 0, 1, 2, nil, "How much sliding it takes out while boosting")
    UI.slider(FastBox, "BoostTurn", "Boost turning", 0.3, 4, 1, nil, "How fast you turn while boosting")
    UI.slider(FastBox, "BoostDownforce", "Boost downforce", 0, 300, 0, nil, "Keeps the car on the road over bumps at speed")
    UI.toggle(FastBox, "CarFly", "Car fly", "While you drive: gas flies where the camera looks, steering slides sideways. Let go to hover")
    UI.slider(FastBox, "CarFlySpeed", "Fly speed", 5, 1000, 0, " studs/s", "The real speed")
    UI.slider(FastBox, "CarFlyResponse", "Fly response", 1, 15, 1, nil, "How quickly it gets up to speed and stops. Higher is snappier")
    UI.slider(FastBox, "CarFlyTurn", "Steering turn rate", 0.5, 6, 1, nil, "Only for \"Steer instead of camera\"")
    UI.toggle(FastBox, "CarFlyHeading", "Steer instead of camera", "The car keeps its heading and steering turns it. Try this if the camera fights the car on phone")

    local CheckBox = Tab:AddLeftGroupbox("Checkpoints", "flag")
    UI.slider(CheckBox, "CheckpointSpeed", "Speed", 100, 3000, 0, " studs/s")
    UI.slider(CheckBox, "CheckpointHeight", "Height above the road", 4, 60, 0, " studs")
    CheckBox:AddButton({
        Text = "Fly to the next checkpoint",
        Func = function()
            task.spawn(Travel.toCheckpoint)
        end,
    })
    local CheckLabel = CheckBox:AddLabel("...", true)
    loop(1, function()
        local road, here, goal = Travel.nextCheckpoint()
        CheckLabel:SetText(road and ("Next checkpoint in %d studs · %s"):format(math.floor(goal - here), Travel.status)
            or ("Checkpoint: %s"):format(tostring(here)))
    end)

    local HandleBox = Tab:AddRightGroupbox("Handling", "steering-wheel")
    UI.toggle(HandleBox, "AntiDrift", "No drifting", "Takes out the sideways slide, so the car goes where it points at speed")
    UI.slider(HandleBox, "Grip", "Grip", 0.05, 1, 2, nil, "How much of the slide is taken out each frame")
    UI.slider(HandleBox, "DriftFrom", "From speed", 0, 200, 0, " studs/s", "Handling help only starts above this speed")
    UI.toggle(HandleBox, "SteerAssist", "Steering assist", "Turns at a steady rate at speed, even when the tyres would slip")
    UI.slider(HandleBox, "SteerPower", "Turn rate", 0.3, 5, 1)
    UI.toggle(HandleBox, "Stabilize", "Stabilize", "Damps the rolling and tipping that flips cars at speed")
    UI.toggle(HandleBox, "BrakeAssist", "Brake assist", "Braking takes off speed this fast, on top of the car's own brakes")
    UI.slider(HandleBox, "BrakePower", "Brake power", 20, 800, 0, " studs/s²")

    local FuelBox = Tab:AddRightGroupbox("Fuel", "fuel")
    local FuelLabel = FuelBox:AddLabel("...", true)
    UI.toggle(FuelBox, "AutoPour", "Keep pouring", "While you hold the pump's gas gun or a jerrycan, it pours by itself until the tank is full")
    UI.toggle(FuelBox, "LowFuelAlert", "Low fuel alert")
    UI.slider(FuelBox, "LowFuelAt", "Alert at", 5, 50, 0, "%")

    loop(0.25, function()
        local model = Car.current()
        local level, cap = Car.fuel(model)
        FuelLabel:SetText(model and ("%s · %d mph\nFuel %s"):format(model.Name, math.floor(Car.speed(model)),
            level and ("%.1f / %d (%d%%)"):format(level, cap, math.floor(level / cap * 100)) or "?") or "Not in a car")
    end)
end

-- Money and loot
do
    local Tab = Window:AddTab("Loot", "dollar-sign", "Cash and breakables")
    local CashBox = Tab:AddLeftGroupbox("Cash", "banknote")
    UI.toggle(CashBox, "AutoCash", "Pick up cash and Credz", "Everything dropped within range, the same way walking over it does")
    UI.slider(CashBox, "CashRange", "Range", 5, 60, 0, " studs")
    UI.toggle(CashBox, "CashEsp", "Cash ESP")

    local BreakBox = Tab:AddRightGroupbox("Breakables", "hammer")
    UI.toggle(BreakBox, "AutoBreak", "Break things around you",
        "ATMs, registers, dumpsters, bins, nightstands... with the weapon you hold, at its damage")
    UI.slider(BreakBox, "BreakRange", "Range", 4, 40, 0, " studs")
    UI.slider(BreakBox, "BreakEvery", "Every", 0.2, 2, 2, " s")
    UI.toggle(BreakBox, "LootEsp", "Loot ESP", "Breakables and loose loot, with values where the game lists them")

    local StealBox = Tab:AddLeftGroupbox("Auto steal", "shopping-bag")
    UI.toggle(StealBox, "AutoSteal", "Auto steal", "Puts small items worth at least the amount below into your backpack, the way pressing equip does")
    UI.slider(StealBox, "StealMin", "Worth at least", 0, 5000, 0, " $")
    UI.slider(StealBox, "StealRange", "Range", 4, 20, 0, " studs")
    UI.slider(StealBox, "StealAtOnce", "At once", 1, 15, 0, nil, "How many items it asks for at the same time")
    UI.toggle(StealBox, "TakeUnlisted", "Take unlisted items", "Items the game gives no value (like the tutorial's watch and trophy) count as worth enough, for stealing and bringing")
    local StealLabel = StealBox:AddLabel("...", true)
    loop(0.5, function()
        StealLabel:SetText(("Last: %s%s"):format(Steal.status, Flow and "" or "\n(game table not found: using the remotes directly)"))
    end)

    local BringBox = Tab:AddRightGroupbox("Bring", "magnet")
    UI.slider(BringBox, "BringMin", "Worth at least", 0, 5000, 0, " $")
    UI.slider(BringBox, "BringRange", "From up to", 20, 1000, 0, " studs")
    UI.slider(BringBox, "BringCount", "How many", 1, 40, 0)
    local NameDrop = BringBox:AddDropdown("BringPick", {
        Text = "Only these", Values = {}, Multi = true, Searchable = true,
        Callback = function(v)
            Settings.BringNames = type(v) == "table" and v or {}
        end,
    })
    UI.toggle(BringBox, "BringOnly", "Only the ones picked above")
    BringBox:AddButton({
        Text = "Bring",
        Func = function()
            task.spawn(function()
                notify(("Brought %d"):format(Steal.bring()), 3)
            end)
        end,
    })
    loop(3, function()
        pcall(NameDrop.SetValues, NameDrop, Steal.names)
    end)

    local SellBox = Tab:AddRightGroupbox("Auto sell", "store")
    UI.toggle(SellBox, "AutoSell", "Auto sell when full", "When your backpack is full, flies you to the nearest pawn counter, sells your loot, waits for the money, and flies you back. On foot only")
    UI.slider(SellBox, "SellAt", "Sell at", 0, 30, 0, " items", "0 = when the backpack is full")
    UI.slider(SellBox, "SellRange", "Counter within", 50, 500, 0, " studs")
    UI.slider(SellBox, "SellSpeed", "Flight speed", 20, 250, 0, " studs/s")
    SellBox:AddButton({
        Text = "Sell now",
        Func = function()
            task.spawn(Sell.run)
        end,
    })
    local SellLabel = SellBox:AddLabel("...", true)
    loop(0.5, function()
        SellLabel:SetText(("Auto sell: %s · cash $%s"):format(Sell.status, tostring(Sell.cash())))
    end)

    local DragBox = Tab:AddLeftGroupbox("Dragging", "hand")
    UI.toggle(DragBox, "DragNoclip", "Through walls", "What you drag passes through walls and things, but never sinks into the floor")
    UI.slider(DragBox, "DragPower", "Snappiness", 5, 200, 0, nil, "How quickly it follows you (the game uses 50)")
    UI.slider(DragBox, "DragForce", "Strength", 0.2, 10, 2, "x", "How heavy a thing you can swing around")
    UI.slider(DragBox, "DragDistance", "Hold distance", 0.5, 2, 2, "x", "The game lets go of anything more than 20 studs from you")
end

-- Survival
do
    local Tab = Window:AddTab("Survival", "heart", "Health and revives")
    local Box = Tab:AddLeftGroupbox("Health", "heart-pulse")
    UI.toggle(Box, "NoFall", "No fall damage")
    UI.toggle(Box, "AutoEat", "Auto eat", "Uses a consumable from your backpack when you're hurt")
    UI.slider(Box, "EatAt", "Eat below", 10, 90, 0, "%")
    UI.toggle(Box, "LowHpAlert", "Low health alert")
    local Box2 = Tab:AddRightGroupbox("Other", "life-buoy")
    UI.toggle(Box2, "AutoRevive", "Use free revives", "When you go down and have a free revive. It never buys one")
    UI.toggle(Box2, "AntiAfk", "Anti AFK")
end

-- World
do
    local Tab = Window:AddTab("World", "sun", "Lighting and performance")
    local Box = Tab:AddLeftGroupbox("World", "sun")
    UI.toggle(Box, "Fullbright", "Fullbright")
    UI.toggle(Box, "NoFog", "No fog")
    UI.toggle(Box, "NoWeather", "Clear weather", "Keeps the weather clear on your screen")
    UI.toggle(Box, "FpsBoost", "FPS boost", "Turns off particles, trails, smoke and fire")
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
Genv.__RunawaysUnload = function()
    cleanup()
    pcall(Library.Unload, Library)
end

notify(Flow and "Loaded" or "Loaded (the game's Flow table wasn't found: combat changes are off)", 4)
