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
    MeleeAura = false, MeleeRange = 10, MeleeEvery = 0.45,
    EspNPC = false, EspPlayers = false, EspHealth = true,
    -- police
    PoliceEsp = true, PoliceAlert = true, AlertRange = 150, Quiet = false,
    -- driving
    Tune = false, SpeedMult = 1.3, AccelMult = 1.3, TorqueMult = 1.2, BrakeMult = 1.3, TurnMult = 1.1,
    AutoPour = false, LowFuelAlert = true, LowFuelAt = 20, AutoFlip = false,
    -- loot
    AutoCash = false, CashRange = 30, AutoBreak = false, BreakRange = 12, BreakEvery = 0.5,
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
    function People.npcs()
        local out = {}
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
    local function visible(part, model)
        if not Settings.VisibleCheck then
            return true
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = { model }
        if character() then
            table.insert(ignore, character())
        end
        local effects = Workspace:FindFirstChild("Effects")
        if effects then
            table.insert(ignore, effects)
        end
        params.FilterDescendantsInstances = ignore
        local from = camera.CFrame.Position
        return Workspace:Raycast(from, part.Position - from, params) == nil
    end
    local function partOf(model)
        if Settings.AimPart == "Head" then
            return model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
        end
        return model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
    end
    function Aim.find()
        camera = Workspace.CurrentCamera
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
        local best, bestPart, bestD
        for _, m in pool do
            local part = partOf(m)
            if part then
                local pos, onScreen = camera:WorldToViewportPoint(part.Position)
                if onScreen and pos.Z > 0 then
                    local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
                    if d <= Settings.FOV and (not bestD or d < bestD) and visible(part, m) then
                        best, bestPart, bestD = m, part, d
                    end
                end
            end
        end
        Aim.target, Aim.part = best, bestPart
        return bestPart
    end

    Game.wrap("BulletsClient", "shootProjectile", function(old)
        return function(args, who, ...)
            if alive() and type(args) == "table" and typeof(args.from) == "Vector3" then
                local part = Settings.SilentAim and Aim.find() or nil
                if part and math.random(1, 100) <= Settings.HitChance then
                    args.direction = (part.Position - args.from).Unit * 1000
                elseif Settings.NoSpread then
                    local cf = Workspace.CurrentCamera.CFrame
                    args.from = cf.Position
                    args.direction = cf.LookVector * 1000
                end
            end
            return old(args, who, ...)
        end
    end)
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
    function Hit.meleePass()
        if not Settings.MeleeAura or os.clock() - Hit.lastMelee < Settings.MeleeEvery then
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
        Hit.lastMelee = os.clock()
        local dmg = cfg.damage * Game.strength()
        for _, m in People.npcs() do
            local r = m:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - root.Position).Magnitude <= Settings.MeleeRange then
                Game.call("NPCs", "Damage", m:FindFirstChildOfClass("Humanoid"), dmg)
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
loop(0.1, function()
    Hit.meleePass()
    Hit.breakPass()
end)

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

    local GunBox = Tab:AddRightGroupbox("Guns", "zap")
    UI.toggle(GunBox, "NoRecoil", "No recoil")
    UI.toggle(GunBox, "NoSpread", "No spread", "Every shot goes exactly where you aim")
    if not Flow then
        GunBox:AddLabel("Couldn't reach the game's Flow table, so silent aim, recoil and spread can't work in this executor", true)
    end

    local MeleeBox = Tab:AddRightGroupbox("Melee aura", "swords")
    UI.toggle(MeleeBox, "MeleeAura", "Melee aura", "While you hold a melee weapon, hits NPCs around you with that weapon's damage")
    UI.slider(MeleeBox, "MeleeRange", "Range", 4, 20, 0, " studs")
    UI.slider(MeleeBox, "MeleeEvery", "Every", 0.2, 2, 2, " s")

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
    UI.slider(TuneBox, "SpeedMult", "Top speed", 1, 2, 2, "x")
    UI.slider(TuneBox, "AccelMult", "Acceleration", 1, 2.5, 2, "x")
    UI.slider(TuneBox, "TorqueMult", "Torque", 1, 2, 2, "x")
    UI.slider(TuneBox, "BrakeMult", "Brakes", 1, 2.5, 2, "x")
    UI.slider(TuneBox, "TurnMult", "Steering", 1, 1.6, 2, "x")
    UI.toggle(TuneBox, "AutoFlip", "Auto flip", "Puts the car back on its wheels after 2 s upside down")

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
