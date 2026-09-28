--// [TRAITS] Survive the Cold ---------------------------------------------------------
-- Built against a script dump of the live game (place 134750290201751, version 801).
--
-- What the game's own client scripts show:
--  * Every client system is a module that the game's ModuleLoader stores in
--    `shared` under its own name (shared.MovementManager, shared.Minigame, ...),
--    and the game calls their functions through that table. Swapping a function
--    on the table changes what the game itself runs, so the "hook" methods below
--    go through the game's own code paths, with the arguments it would use. Each
--    feature also has a method that needs no hook, and Auto picks the hook when
--    it went in and falls back otherwise.
--  * All networking is shared.NetworkingClient:RequestServer(name, ...). The
--    shared Networking modules also hold the server's checks: an item pickup must
--    be within 15 studs, and a gun shot must start within 20 studs of you, wait
--    out the gun's cooldown and spend real ammo.
--  * Stamina is only your character's Stamina attribute, drained and refilled by
--    MovementManager.UpdateStamina every frame, up to TraitsCalculator's
--    MaxStamina. Walk and run speed come from MovementManager.baseWalkSpeed /
--    baseRunSpeed (16 / 32).
--  * Two things about you are reported by your own client. Your cold zone
--    (Green, Yellow, Red): Zones sends RequestServer("ChangeZone", zone) when you
--    walk into one and the server stores it as your FreezeSpot; enemy AI set to
--    IgnoreGreenZones skips anyone whose FreezeSpot is Green. And whether you are
--    in the snowstorm: the server tells the client (SnowstormHandler.ReplicateIn /
--    ReplicateOut), the client sets its IsSnowstormActive attribute and sends it
--    back on SnowstormHandler.ReplicateSnowstorm, and the server stores that.
--  * Screen effects: TemperatureEffects (breath, shivering, frost mask, blur)
--    runs off Data.Temperature, Snowstorm swaps lighting presets and parents a
--    storm model, and Zones parents a Yellow/Red zone effect around you.
--  * Gathering: branches, bushes and trees are per-player spawns tagged
--    BranchInteraction / FiberInteraction / WoodCutInteraction. Each hit is
--    obj:TakeDamage(); the first opens the minigame on the server and the last
--    ends it. A click near one runs the game's swing handler (kick, scythe, axe),
--    which plays the animation and hits whatever is in front of you. Snow piles
--    and chests are MinigameSpawner spawns with a prompt: AttemptMinigame, then
--    the server starts Minigame.StartMinigame. Snow is a timing bar
--    (Minigame.WaitForClick waits for a tap, then the indicator is checked
--    against the green window drawn into the bar's UIGradient); a chest is
--    "click as fast as you can" on a UserInputService.InputBegan handler.
--  * Loot boxes are models tagged LootChest with a hold prompt. Your relic is
--    spawned on your client by Relic (shared.Relic.Collection[you]) with a
--    Collect prompt that sends RequestServer("Relic", "Collect").
--  * Fishing is a timing session (Client.UI.MinigameUI): a press only counts
--    with the marker on the catch target, and is PERFECT within 0.034 of its
--    centre. Space, the left mouse button or a tap in the world presses.
--  * Guns: shared.Firearm:Fire(tool, direction) sends CreateProjectile with the
--    muzzle position and a unit direction taken from CommonUtils.Mousecast, and
--    the server flies the bullet at the gun's ProjectileVelocity. Enemies live in
--    Workspace.Enemies with a Humanoid (raid mobs carry IsRaidMob). Melee is
--    server side: activating the tool is the whole attack.
--  * Chests take their loot table from Config.PointOfInterest by the part of
--    their ID before the underscore (AirDrop_..., Cave_...). Snowstorms follow the
--    "Main" world event schedule; raids announce themselves through
--    RaidController (OnRaidIncoming, OnRaidStarted, ...).
--
-- Everything here is LOCAL PLAYER ONLY.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer

-- A second run of the script retires the first one's loops.
local Genv = (typeof(getgenv) == "function" and getgenv()) or _G
Genv.__SurviveTheColdRun = (Genv.__SurviveTheColdRun or 0) + 1
local RUN = Genv.__SurviveTheColdRun
local function alive() return Genv.__SurviveTheColdRun == RUN end

local Settings = {
    -- survival
    InfStamina = false, StaminaMethod = "Auto",
    Speed = 1, SpeedMethod = "Auto",
    StayGreen = false, ZoneMethod = "Auto",
    Shelter = false, ShelterMethod = "Auto",
    NoColdFx = false, ColdFxMethod = "Auto",
    NoStormFx = false, StormFxMethod = "Auto",
    -- farming
    FarmBranch = false, FarmBush = false, FarmTree = false, GatherMethod = "Auto",
    Reach = 10, HitDelay = 0.6,
    AutoSnow = false, SnowMethod = "Auto",
    AutoChest = false, ChestMethod = "Auto",
    AutoPickup = false, PickupMethod = "Auto",
    AutoLoot = false, LootMethod = "Auto",
    AutoRelic = false, RelicMethod = "Auto",
    WalkTo = false, WalkMethod = "Walk", WalkRadius = 150,
    AutoFish = false, FishMethod = "Auto",
    AutoCast = false, CastMethod = "Auto",
    AntiAfk = false,
    -- combat
    GunAim = false, AimMethod = "Auto", AimFov = 35, AimRange = 350,
    AutoSwing = false, SwingMethod = "Auto", SwingReach = 9,
    -- esp
    EnemyEsp = false, RelicEsp = false, ChestEsp = false, DropEsp = false, LootEsp = false,
    EspStyle = "Label + outline", EspRange = 500,
    -- alerts
    AlertStorm = true, AlertRaid = true, AlertAirdrop = true, AlertRelic = true,
}

local notify = function() end

--// the game's modules --------------------------------------------------------------
local GameShared
do
    local ok, value = pcall(function()
        if typeof(getrenv) == "function" then return getrenv().shared end
    end)
    if ok and type(value) == "table" then GameShared = value end
    if not GameShared and type(shared) == "table" then GameShared = shared end
end

-- where each module lives, for executors that keep their own `shared`; require
-- is cached per module, so this still returns the table the game uses
local MODULE_PATHS = {
    NetworkingClient = "Client.Objects.NetworkingClient",
    MovementManager = "Client.Objects.MovementManager",
    TemperatureEffects = "Client.Objects.TemperatureEffects",
    Snowstorm = "Client.Objects.Snowstorm",
    Minigame = "Client.Objects.Minigame",
    Zones = "Client.Classes.Zones",
    MinigameSpawner = "Client.Classes.MinigameSpawner",
    BranchInteraction = "Client.Classes.BranchInteraction",
    FiberInteraction = "Client.Classes.FiberInteraction",
    WoodCutInteraction = "Client.Classes.WoodCutInteraction",
    ItemUI = "Client.Classes.ItemUI",
    Firearm = "Client.Classes.Firearm",
    RaidController = "Client.Classes.RaidController",
    LootChest = "Client.Classes.LootChest",
    Relic = "Client.Classes.Relic",
    MinigameUI = "Client.UI.MinigameUI",
    CommonUtils = "Shared.Utils.CommonUtils",
    TraitsCalculator = "Shared.Systems.Gameplay.Traits.TraitsCalculator",
}

local function findPath(path)
    local inst = ReplicatedStorage
    for part in string.gmatch(path or "", "[^%.]+") do
        inst = inst and inst:FindFirstChild(part)
    end
    return inst
end

local function requirePath(path)
    local inst = findPath(path)
    if inst and inst:IsA("ModuleScript") then
        local ok, value = pcall(require, inst)
        if ok then return value end
    end
    return nil
end

local Modules = {}
local function mod(name)
    local cached = Modules[name]
    if cached then return cached end
    if GameShared then
        local ok, value = pcall(function() return GameShared[name] end)
        if ok and type(value) == "table" then
            Modules[name] = value
            return value
        end
    end
    local value = requirePath(MODULE_PATHS[name])
    if type(value) == "table" then
        Modules[name] = value
        return value
    end
    return nil
end

local GameConfig
local function gameConfig()
    if GameConfig == nil then
        local value = requirePath("Shared.Data.Config")
        GameConfig = type(value) == "table" and value or false
    end
    return GameConfig or nil
end

-- wrap(module, key, make) puts make(original) in place of module[key]. The
-- original is kept in the executor's globals, so running the script again wraps
-- the game's function rather than the previous run's wrapper.
Genv.__SurviveTheColdOriginals = Genv.__SurviveTheColdOriginals or {}
local Originals = Genv.__SurviveTheColdOriginals
local Wrapped = {}

local function wrap(name, key, make)
    local id = name .. "." .. key
    if Wrapped[id] then return true end
    local m = mod(name)
    if not m then return false end
    local saved = Originals[id]
    local original = (saved and saved.module == m) and saved.fn or rawget(m, key)
    if type(original) ~= "function" then return false end
    if not pcall(rawset, m, key, make(original)) then return false end
    Originals[id] = { module = m, fn = original }
    Wrapped[id] = true
    return true
end

local HookState = { done = {}, count = 0 }
local function hooked(name) return HookState.done[name] == true end

-- the method a feature runs with: the one picked, or Auto's choice
local function methodOf(setting, auto)
    local picked = Settings[setting]
    if picked and picked ~= "Auto" then return picked end
    return auto()
end

-- the game's RequestServer yields for the server's answer
local function request(name, ...)
    local nc = mod("NetworkingClient")
    if not nc then return nil end
    local args = table.pack(...)
    local ok, result = pcall(function() return nc:RequestServer(name, table.unpack(args, 1, args.n)) end)
    return ok and result or nil
end

local function character()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if root and hum and hum.Health > 0 then return char, root, hum end
    return nil
end

local function byDistance(a, b) return a.dist < b.dist end

local function firstPart(model)
    if model:IsA("BasePart") then return model end
    return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

--// input ------------------------------------------------------------------------------
local Input = {}
local FAKE_CLICK = { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }
local TAP_SPOTS = { { 0.5, 0.55 }, { 0.3, 0.45 }, { 0.7, 0.45 }, { 0.5, 0.3 } }

function Input.vim()
    local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
    return ok and vim or nil
end

-- a point on screen with no game button over it, so the click reaches the world
function Input.spot()
    local size = Workspace.CurrentCamera.ViewportSize
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, spot in ipairs(TAP_SPOTS) do
        local x, y = size.X * spot[1], size.Y * spot[2]
        local clear = true
        local ok, objects = pcall(function() return gui:GetGuiObjectsAtPosition(x, y) end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if object.Active or object:IsA("GuiButton") then
                    clear = false
                    break
                end
            end
        end
        if clear then return x, y end
    end
    return size.X * 0.5, size.Y * 0.55
end

function Input.click()
    local vim = Input.vim()
    if not vim then return false end
    return pcall(function()
        local x, y = Input.spot()
        vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
        vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
end

function Input.key(keyCode)
    local vim = Input.vim()
    if not vim then return false end
    return pcall(function()
        vim:SendKeyEvent(true, keyCode, false, game)
        vim:SendKeyEvent(false, keyCode, false, game)
    end)
end

-- The game's own UserInputService.InputBegan handlers, found by strings only
-- they use. Cached for a second: minigame handlers come and go.
local Handlers = { cache = {}, at = {} }

function Handlers.find(key, markers)
    local now = os.clock()
    if Handlers.at[key] and now - Handlers.at[key] < 1 then return Handlers.cache[key] end
    local found = {}
    local getconsts = (type(debug) == "table" and debug.getconstants) or (typeof(getconstants) == "function" and getconstants) or nil
    if typeof(getconnections) == "function" and getconsts then
        local ok, connections = pcall(getconnections, UserInputService.InputBegan)
        if ok and type(connections) == "table" then
            for _, connection in ipairs(connections) do
                local fn = connection.Function
                if type(fn) == "function" then
                    local okc, constants = pcall(getconsts, fn)
                    if okc and type(constants) == "table" then
                        local have = {}
                        for _, c in pairs(constants) do have[c] = true end
                        local all = true
                        for _, marker in ipairs(markers) do
                            if not have[marker] then all = false end
                        end
                        if all then found[#found + 1] = fn end
                    end
                end
            end
        end
    end
    Handlers.cache[key], Handlers.at[key] = found, now
    return found
end

function Handlers.click(fns)
    for _, fn in ipairs(fns) do task.spawn(pcall, fn, FAKE_CLICK, false) end
end

local function firePrompt(prompt, method)
    if method ~= "Hold" and typeof(fireproximityprompt) == "function" then
        if pcall(fireproximityprompt, prompt) then return end
    end
    pcall(function()
        prompt:InputHoldBegin()
        task.wait((prompt.HoldDuration or 0) + 0.05)
        prompt:InputHoldEnd()
    end)
end

local function promptMethod(setting)
    return methodOf(setting, function()
        return typeof(fireproximityprompt) == "function" and "Prompt" or "Hold"
    end)
end

--// survival ---------------------------------------------------------------------------
local Survival = { reportedZone = nil, ourSend = false, nextResend = 0, maxAt = 0, max = 100 }

function Survival.staminaMethod()
    return methodOf("StaminaMethod", function() return hooked("stamina") and "Hook" or "Attribute" end)
end

-- Hook: every frame's update is run as a long rest, so the game refills the
-- attribute to your real maximum itself.
function Survival.hookStamina()
    return wrap("MovementManager", "UpdateStamina", function(original)
        return function(self, dt)
            if Settings.InfStamina and Survival.staminaMethod() == "Hook" then
                local running, stoppedAt = self.isRunning, self.lastRunStopTime
                self.isRunning = false
                self.lastRunStopTime = -math.huge
                local ok = pcall(original, self, 1000)
                self.isRunning, self.lastRunStopTime = running, stoppedAt
                if ok then return end
            end
            return original(self, dt)
        end
    end)
end

function Survival.maxStamina()
    if os.clock() - Survival.maxAt > 1 then
        Survival.maxAt = os.clock()
        local traits = mod("TraitsCalculator")
        local ok, value = pcall(function() return traits.Get(LocalPlayer, "MaxStamina") end)
        Survival.max = (ok and type(value) == "number" and value > 0) and value or 100
    end
    return Survival.max
end

-- Attribute: tops the attribute back up every frame
function Survival.staminaStep()
    if not Settings.InfStamina or Survival.staminaMethod() ~= "Attribute" then return end
    local char = LocalPlayer.Character
    if not char then return end
    local max = Survival.maxStamina()
    if (char:GetAttribute("Stamina") or max) < max then char:SetAttribute("Stamina", max) end
end

function Survival.speedMethod()
    return methodOf("SpeedMethod", function() return mod("MovementManager") and "Game speed" or "CFrame" end)
end

function Survival.applySpeed()
    local mm = mod("MovementManager")
    if not mm then return end
    local scale = Survival.speedMethod() == "Game speed" and Settings.Speed or 1
    mm.baseWalkSpeed = 16 * scale
    mm.baseRunSpeed = 32 * scale
    -- recomputes WalkSpeed (or the run tween) from the new bases, buffs included
    pcall(mm.HandleDrivingChange, mm)
end

-- CFrame: carries you the extra distance yourself, whatever WalkSpeed says
function Survival.speedStep(dt)
    if Settings.Speed <= 1 or Survival.speedMethod() ~= "CFrame" then return end
    local _, root, hum = character()
    if not root or hum.Sit then return end
    local direction = hum.MoveDirection
    if direction.Magnitude > 0 then
        root.CFrame = root.CFrame + direction * (hum.WalkSpeed * (Settings.Speed - 1) * dt)
    end
end

function Survival.zoneMethod()
    return methodOf("ZoneMethod", function() return hooked("zone") and "Rewrite" or "Resend" end)
end

function Survival.hookZone()
    return wrap("NetworkingClient", "RequestServer", function(original)
        return function(self, name, ...)
            if name == "ChangeZone" then
                local zone = ...
                -- remember only what the game itself reports
                if Survival.ourSend then
                    Survival.ourSend = false
                else
                    Survival.reportedZone = zone
                end
                if Settings.StayGreen and zone ~= "Green" and Survival.zoneMethod() == "Rewrite" then
                    return original(self, name, "Green")
                end
            end
            return original(self, name, ...)
        end
    end)
end

-- tell the server where we are now: Green while the toggle is on, the real zone
-- once it is off again
function Survival.sendZone()
    local zone = "Green"
    if not Settings.StayGreen then
        local zones = mod("Zones")
        zone = (zones and zones.CurrentZone and zones.CurrentZone[LocalPlayer]) or Survival.reportedZone or "Green"
    end
    task.spawn(function()
        Survival.ourSend = hooked("zone")
        request("ChangeZone", zone)
    end)
end

-- Resend: says Green again every couple of seconds, over the game's own reports
function Survival.zoneStep()
    if Settings.StayGreen and Survival.zoneMethod() == "Resend" and os.clock() >= Survival.nextResend then
        Survival.nextResend = os.clock() + 2
        Survival.sendZone()
    end
end

-- Snowstorm report. The real state is tracked from the server's own messages,
-- so switching this off hands the server the truth again.
local Shelter = { keys = {}, watching = false }

function Shelter.method()
    return methodOf("ShelterMethod", function() return "Attribute" end)
end

function Shelter.real() return next(Shelter.keys) ~= nil end

function Shelter.remote()
    local handler = findPath("Shared.Systems.Gameplay.World.SnowstormHandler")
    return handler and handler:FindFirstChild("ReplicateSnowstorm")
end

function Shelter.send(value)
    local remote = Shelter.remote()
    if remote then pcall(remote.FireServer, remote, value) end
end

function Shelter.apply()
    if not Settings.Shelter or not LocalPlayer:GetAttribute("IsSnowstormActive") then return end
    if Shelter.method() == "Attribute" then
        -- the game's own listener sends the change to the server
        task.defer(function()
            if Settings.Shelter then LocalPlayer:SetAttribute("IsSnowstormActive", false) end
        end)
    else
        Shelter.send(false)
    end
end

function Shelter.watch()
    if Shelter.watching then return true end
    local handler = findPath("Shared.Systems.Gameplay.World.SnowstormHandler")
    local into = handler and handler:FindFirstChild("ReplicateIn")
    local out = handler and handler:FindFirstChild("ReplicateOut")
    if not into or not out then return false end
    Shelter.watching = true
    into.OnClientEvent:Connect(function(key)
        Shelter.keys[key == nil and "_" or key] = true
        Shelter.apply()
    end)
    out.OnClientEvent:Connect(function(key)
        Shelter.keys[key == nil and "_" or key] = nil
    end)
    LocalPlayer:GetAttributeChangedSignal("IsSnowstormActive"):Connect(Shelter.apply)
    return true
end

function Shelter.toggled()
    if Settings.Shelter then
        Shelter.apply()
        if Shelter.method() == "Remote" and Shelter.real() then Shelter.send(false) end
        return
    end
    local real = Shelter.real()
    if Shelter.method() == "Attribute" then
        LocalPlayer:SetAttribute("IsSnowstormActive", real)
    else
        Shelter.send(real)
    end
end

-- Remote: keeps telling the server "not in the storm" while one is on you
function Shelter.step()
    if Settings.Shelter and Shelter.method() == "Remote" and (Shelter.real() or LocalPlayer:GetAttribute("IsSnowstormActive")) then
        Shelter.send(false)
    end
end

function Survival.coldMethod()
    return methodOf("ColdFxMethod", function() return hooked("cold effects") and "Hook" or "Clean up" end)
end

function Survival.hookColdEffects()
    local temperature = wrap("TemperatureEffects", "UpdateTemperatureEffects", function(original)
        return function(self, dt)
            if Settings.NoColdFx and Survival.coldMethod() == "Hook" then
                -- switch off whatever is showing with the game's own cleanup
                for char, effects in pairs(self.activeCharacters or {}) do
                    for effectName, st in pairs(effects) do
                        if type(st) == "table" and st.active then
                            st.active = false
                            local config = self.temperatureEffects and self.temperatureEffects[effectName]
                            if config and config.onDeactivate then pcall(config.onDeactivate, char, st) end
                        end
                    end
                end
                return
            end
            return original(self, dt)
        end
    end)
    local zones = wrap("Zones", "TryCreateVFX", function(original)
        return function(self, ...)
            if Settings.NoColdFx and Survival.coldMethod() == "Hook" then return end
            return original(self, ...)
        end
    end)
    return temperature and zones
end

-- Clean up: removes what the effects leave on screen, without touching the game
function Survival.coldCleanup()
    if not Settings.NoColdFx or Survival.coldMethod() ~= "Clean up" then return end
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local freezing = gui and gui:FindFirstChild("Freezing")
    local mask = freezing and freezing:FindFirstChild("FrostMask", true)
    if mask then mask.ImageTransparency = 1 end
    local blur = game:GetService("Lighting"):FindFirstChild("ArcticExtremeBlur")
    if blur then blur.Size = 0 end
    local char = LocalPlayer.Character
    local breath = char and char:FindFirstChild("BreathPart")
    if breath then breath:Destroy() end
    for _, name in ipairs({ "YellowZone", "RedZone" }) do
        local vfx = Workspace:FindFirstChild(name)
        if vfx then vfx:Destroy() end
    end
end

function Survival.refreshZoneEffect()
    local zones = mod("Zones")
    if not zones then return end
    local active = zones.ActiveVFX and zones.ActiveVFX[LocalPlayer]
    if Settings.NoColdFx then
        if active and active.vfx then pcall(function() active.vfx:Destroy() end) end
        return
    end
    local zone = zones.CurrentZone and zones.CurrentZone[LocalPlayer]
    if not active and (zone == "Yellow" or zone == "Red") then
        task.spawn(pcall, zones.TryCreateVFX, zones, zone, zones.CurrentZoneSize and zones.CurrentZoneSize[LocalPlayer])
    end
end

-- the game's own "Default" preset, used while the snowstorm is hidden
local CLEAR_SKY = {
    Brightness = 3,
    OutdoorAmbient = Color3.fromRGB(54, 107, 157),
    Atmosphere = { Density = 0.431, Haze = 0, Color = Color3.fromRGB(133, 151, 211), Decay = Color3.fromRGB(165, 170, 189) },
    ColorCorrection = { Brightness = 0, Contrast = 0.08, Saturation = 0.1, TintColor = Color3.fromRGB(255, 255, 255) },
}

function Survival.stormMethod()
    return methodOf("StormFxMethod", function() return hooked("snowstorm") and "Hook" or "Clean up" end)
end

function Survival.hookStorm()
    local vfx = wrap("Snowstorm", "StartSnowstormVFX", function(original)
        return function(self, ...)
            if Settings.NoStormFx and Survival.stormMethod() == "Hook" then return end
            return original(self, ...)
        end
    end)
    local lighting = wrap("Snowstorm", "tweenLighting", function(original)
        return function(self, preset, plain)
            if Settings.NoStormFx and Survival.stormMethod() == "Hook" then return original(self, CLEAR_SKY, false) end
            return original(self, preset, plain)
        end
    end)
    return vfx and lighting
end

function Survival.refreshStorm()
    local storm = mod("Snowstorm")
    if not storm then return end
    if Settings.NoStormFx then
        pcall(function() storm.vfxTrove:Clean() end)
        pcall(function() Workspace.GlobalWind = Vector3.new(0, 0, 0) end)
        if Survival.stormMethod() == "Hook" then pcall(storm.tweenLighting, storm, CLEAR_SKY) end
        return
    end
    storm.vfxActive = false
    task.spawn(function()
        pcall(storm.updateLighting, storm)
        pcall(storm.updateVFX, storm)
    end)
end

-- Clean up: takes the storm model and the thick air away as they appear
function Survival.stormCleanup()
    if not Settings.NoStormFx or Survival.stormMethod() ~= "Clean up" then return end
    local vfxFolder = Workspace:FindFirstChild("VFX")
    local storm = vfxFolder and vfxFolder:FindFirstChild("Snowstorm")
    if storm then storm:Destroy() end
    local atmosphere = game:GetService("Lighting"):FindFirstChildOfClass("Atmosphere")
    if atmosphere then
        atmosphere.Density = CLEAR_SKY.Atmosphere.Density
        atmosphere.Haze = CLEAR_SKY.Atmosphere.Haze
    end
    Workspace.GlobalWind = Vector3.new(0, 0, 0)
end

--// farming ----------------------------------------------------------------------------
local Farm = {
    nextHit = 0, tries = {}, cooldown = {}, avoid = {}, walking = nil, status = "idle",
    swingCheck = nil, swingBrokenUntil = 0, nextButton = 0, lootAt = {}, relicAt = 0, nextTeleport = 0,
    snowTapAt = 0,
}

local RESOURCE_KINDS = {
    { module = "BranchInteraction", setting = "FarmBranch", label = "branch", markers = { "Kick", "Animations" } },
    { module = "FiberInteraction", setting = "FarmBush", label = "bush", markers = { "Scythe", "WindTrail" } },
    { module = "WoodCutInteraction", setting = "FarmTree", label = "tree", markers = { "AxeAnim", "AxeAnim1" } },
}

function Farm.enabled()
    return Settings.FarmBranch or Settings.FarmBush or Settings.FarmTree or Settings.AutoSnow
        or Settings.AutoChest or Settings.AutoPickup or Settings.AutoLoot or Settings.AutoRelic
end

function Farm.minigameBusy()
    local minigame = mod("Minigame")
    return minigame ~= nil and minigame.ID ~= nil
end

-- the spawns the server gave this player; hits on anything else do nothing
function Farm.spawns()
    local spawner = mod("MinigameSpawner")
    return spawner and spawner.minigameSpawns or nil
end

function Farm.resources(root, radius, out)
    local spawns = Farm.spawns()
    if not spawns then return end
    for _, kind in ipairs(RESOURCE_KINDS) do
        local class = Settings[kind.setting] and mod(kind.module)
        local collection = class and class.Collection
        if collection then
            for _, obj in pairs(collection) do
                if type(obj) == "table" and not obj.destroyed and obj.object and obj.object.Parent
                    and obj.pos and (obj.health or 1) > 0 and spawns[obj.object:GetAttribute("ID")] then
                    local dist = (obj.pos.Position - root.Position).Magnitude
                    if dist <= radius then
                        out[#out + 1] = { kind = kind.label, markers = kind.markers, obj = obj, key = obj, dist = dist, pos = obj.pos.Position }
                    end
                end
            end
        end
    end
end

-- snow piles and chests: a prompt that is enabled means nobody is playing it
function Farm.minigames(root, radius, out)
    local spawns = Farm.spawns()
    if not spawns then return end
    for id, entry in pairs(spawns) do
        local spawn = type(entry) == "table" and entry.Object
        if type(spawn) == "table" and spawn.object and spawn.object.Parent and spawn.proximity and spawn.proximity.Enabled
            and ((spawn.Type == "Snow" and Settings.AutoSnow) or (spawn.Type == "Chest" and Settings.AutoChest))
            and (Farm.cooldown[id] or 0) <= os.clock() then
            local pos = spawn.object:GetPivot().Position
            local dist = (pos - root.Position).Magnitude
            if dist <= radius then
                out[#out + 1] = { kind = string.lower(spawn.Type), spawn = spawn, id = id, key = spawn, dist = dist, pos = pos }
            end
        end
    end
end

-- drops you can pick up; one the server keeps refusing is left alone for a minute
function Farm.drops(root, radius, out)
    local itemUI = mod("ItemUI")
    local collection = itemUI and itemUI.Collection
    if not collection then return end
    for item, entry in pairs(collection) do
        if type(entry) == "table" and entry.part and item.Parent then
            local tries = Farm.tries[item]
            if not tries or tries.n < 3 or os.clock() - tries.at > 60 then
                local dist = (entry.part.Position - root.Position).Magnitude
                if dist <= radius then
                    out[#out + 1] = { kind = "drop", item = item, key = item, dist = dist, pos = entry.part.Position }
                end
            end
        end
    end
end

function Farm.lootBoxes(root, radius, out)
    local class = mod("LootChest")
    local collection = class and class.Collection
    if not collection then return end
    for model in pairs(collection) do
        if typeof(model) == "Instance" and model.Parent and (Farm.lootAt[model] or 0) <= os.clock() then
            local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and prompt.Enabled then
                local pos = model:GetPivot().Position
                local dist = (pos - root.Position).Magnitude
                if dist <= radius then
                    out[#out + 1] = { kind = "loot box", model = model, prompt = prompt, key = model, dist = dist, pos = pos }
                end
            end
        end
    end
end

function Farm.relic()
    local class = mod("Relic")
    local obj = class and class.Collection and class.Collection[LocalPlayer]
    if type(obj) == "table" and obj.relicModel and obj.relicModel.Parent then return obj end
    return nil
end

function Farm.pickupMethod()
    return methodOf("PickupMethod", function() return "Request" end)
end

function Farm.pickup(root)
    if Farm.pickupMethod() == "Button" then
        -- the game's own collect button: the closest drop within its 8 studs
        local itemUI = mod("ItemUI")
        if itemUI and os.clock() >= Farm.nextButton then
            Farm.nextButton = os.clock() + 0.3
            task.spawn(pcall, itemUI.UIClicked, itemUI)
        end
        return
    end
    local list = {}
    Farm.drops(root, 14, list)
    for _, c in ipairs(list) do
        local tries = Farm.tries[c.item] or { n = 0, at = 0 }
        if os.clock() - tries.at >= 1.5 then
            if os.clock() - tries.at > 60 then tries.n = 0 end
            tries.n = tries.n + 1
            tries.at = os.clock()
            Farm.tries[c.item] = tries
            task.spawn(request, "Item", "Collect", c.item)
        end
    end
end

function Farm.loot(root)
    local list = {}
    Farm.lootBoxes(root, 40, list)
    table.sort(list, byDistance)
    local box = list[1]
    if box and box.dist <= (box.prompt.MaxActivationDistance or 10) - 0.5 then
        Farm.lootAt[box.model] = os.clock() + (box.prompt.HoldDuration or 0) + 5
        Farm.status = "looting a box"
        task.spawn(firePrompt, box.prompt, promptMethod("LootMethod"))
        return true
    end
    return false
end

function Farm.relicMethod()
    return methodOf("RelicMethod", function()
        local obj = Farm.relic()
        return (obj and obj.proximity) and "Prompt" or "Request"
    end)
end

function Farm.collectRelic(root)
    local obj = Farm.relic()
    if not obj or os.clock() < Farm.relicAt then return false end
    local prompt = obj.proximity
    local range = (prompt and prompt.MaxActivationDistance) or 10
    if (obj.relicModel:GetPivot().Position - root.Position).Magnitude > range - 0.5 then return false end
    Farm.relicAt = os.clock() + 3
    Farm.status = "collecting your relic"
    if Farm.relicMethod() == "Request" or not prompt then
        task.spawn(request, "Relic", "Collect")
    else
        task.spawn(firePrompt, prompt, typeof(fireproximityprompt) == "function" and "Prompt" or "Hold")
    end
    return true
end

-- Gathering. Swing runs the game's own swing handler with a click while you face
-- the target; a swing that takes nothing off within a second and a half makes
-- Auto use the game's hit directly for a while.
function Farm.gatherMethod(target)
    local picked = Settings.GatherMethod
    if picked ~= "Auto" then return picked end
    if os.clock() < Farm.swingBrokenUntil then return "Game hit" end
    return #Handlers.find(target.kind, target.markers) > 0 and "Swing" or "Game hit"
end

function Farm.swing(target, root)
    local fns = Handlers.find(target.kind, target.markers)
    if #fns == 0 then return false end
    local flat = Vector3.new(target.pos.X, root.Position.Y, target.pos.Z)
    if (flat - root.Position).Magnitude > 0.1 then root.CFrame = CFrame.lookAt(root.Position, flat) end
    Handlers.click(fns)
    return true
end

function Farm.verifySwing()
    local check = Farm.swingCheck
    if not check or os.clock() - check.at < 1.5 then return end
    Farm.swingCheck = nil
    if not check.obj.destroyed and (check.obj.health or 0) >= check.health then
        Farm.swingBrokenUntil = os.clock() + 30
    end
end

function Farm.stopWalk(hum, root)
    if Farm.walking then
        Farm.walking = nil
        if hum and root then pcall(hum.MoveTo, hum, root.Position) end
    end
end

function Farm.pathTo(hum, root, best)
    local w = Farm.walking
    if not w.points or w.goalKey ~= best.key or os.clock() - (w.pathAt or 0) > 4 then
        w.goalKey = best.key
        w.pathAt = os.clock()
        w.points = nil
        local ok, path = pcall(function()
            local p = game:GetService("PathfindingService"):CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
            p:ComputeAsync(root.Position, best.pos)
            return p
        end)
        if ok and path and path.Status == Enum.PathStatus.Success then
            w.points = path:GetWaypoints()
            w.index = 2
        end
    end
    local points = w.points
    if points then
        local point = points[w.index]
        while point do
            local gap = point.Position - root.Position
            if Vector3.new(gap.X, 0, gap.Z).Magnitude >= 3 then break end
            w.index = w.index + 1
            point = points[w.index]
        end
        if point then
            if point.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            hum:MoveTo(point.Position)
            return
        end
    end
    hum:MoveTo(best.pos)
end

function Farm.walk(root, hum)
    local list = {}
    Farm.resources(root, Settings.WalkRadius, list)
    Farm.minigames(root, Settings.WalkRadius, list)
    if Settings.AutoPickup then Farm.drops(root, Settings.WalkRadius, list) end
    if Settings.AutoLoot then Farm.lootBoxes(root, Settings.WalkRadius, list) end
    local relic = Settings.AutoRelic and Farm.relic()
    if relic then
        local pos = relic.relicModel:GetPivot().Position
        local dist = (pos - root.Position).Magnitude
        if dist <= Settings.WalkRadius then list[#list + 1] = { kind = "relic", key = relic, dist = dist, pos = pos } end
    end
    local best
    for _, c in ipairs(list) do
        if (Farm.avoid[c.key] or 0) <= os.clock() and (not best or c.dist < best.dist) then best = c end
    end
    if not best then
        Farm.status = "nothing in range"
        Farm.stopWalk(hum, root)
        return
    end
    local w = Farm.walking
    if not w or w.key ~= best.key then
        w = { key = best.key, closest = best.dist, progressAt = os.clock() }
        Farm.walking = w
    end
    if best.dist < w.closest - 0.5 then
        w.closest = best.dist
        w.progressAt = os.clock()
    end
    -- stuck: hop, then give up on that target for a while
    if os.clock() - w.progressAt > 4 then
        Farm.avoid[best.key] = os.clock() + 30
        Farm.walking = nil
        return
    end
    local method = Settings.WalkMethod
    if method == "Teleport" then
        Farm.status = "teleporting to " .. best.kind
        if os.clock() >= Farm.nextTeleport then
            Farm.nextTeleport = os.clock() + 1
            local away = root.Position - best.pos
            away = Vector3.new(away.X, 0, away.Z)
            local offset = away.Magnitude > 0.1 and away.Unit * 4 or Vector3.new(4, 0, 0)
            local char = LocalPlayer.Character
            pcall(char.PivotTo, char, CFrame.new(best.pos + offset + Vector3.new(0, 3, 0)))
        end
        return
    end
    if os.clock() - w.progressAt > 1.5 then hum.Jump = true end
    Farm.status = "walking to " .. best.kind
    if method == "Pathfind" then
        Farm.pathTo(hum, root, best)
    else
        hum:MoveTo(best.pos)
    end
end

function Farm.step()
    local _, root, hum = character()
    if not root then
        Farm.status = "no character"
        return
    end
    Farm.verifySwing()
    if Settings.AutoPickup then Farm.pickup(root) end
    if Farm.minigameBusy() then
        Farm.status = "playing minigame"
        Farm.stopWalk(hum, root)
        return
    end
    if Settings.AutoRelic and Farm.collectRelic(root) then return end
    if Settings.AutoLoot and Farm.loot(root) then
        Farm.stopWalk(hum, root)
        return
    end
    local near = {}
    Farm.resources(root, Settings.Reach, near)
    table.sort(near, byDistance)
    local target = near[1]
    if target then
        Farm.stopWalk(hum, root)
        if os.clock() >= Farm.nextHit then
            Farm.status = "hitting " .. target.kind
            Farm.nextHit = os.clock() + Settings.HitDelay
            if Farm.gatherMethod(target) == "Swing" and Farm.swing(target, root) then
                Farm.swingCheck = Farm.swingCheck or { obj = target.obj, health = target.obj.health, at = os.clock() }
            else
                -- the game's own hit: effects, drops and the server calls all included
                pcall(target.obj.TakeDamage, target.obj)
            end
            Farm.nextHit = os.clock() + Settings.HitDelay
        end
        return
    end
    local games = {}
    Farm.minigames(root, 9, games)
    table.sort(games, byDistance)
    if games[1] then
        Farm.stopWalk(hum, root)
        local g = games[1]
        Farm.cooldown[g.id] = os.clock() + 6
        Farm.status = "starting " .. g.kind
        pcall(g.spawn.AttemptMinigame, g.spawn)
        return
    end
    if Settings.WalkTo then
        Farm.walk(root, hum)
    else
        Farm.status = "waiting for something in reach"
    end
end

-- Snow. Hook: the tap the minigame waits for comes the moment the indicator is
-- inside the green window. Tap: a real click is sent at that moment instead.
local SNOW_GREEN = Color3.fromRGB(130, 255, 55)

local function isGreen(color)
    return math.abs(color.R - SNOW_GREEN.R) < 0.02 and math.abs(color.G - SNOW_GREEN.G) < 0.02
        and math.abs(color.B - SNOW_GREEN.B) < 0.02
end

function Farm.snowMethod()
    return methodOf("SnowMethod", function() return hooked("snow") and "Hook" or "Tap" end)
end

function Farm.snowBar(info)
    local items = Workspace:FindFirstChild("Items")
    local pile = info and items and items:FindFirstChild(info.ID)
    local bar = pile and pile:FindFirstChild("MinigameBar", true)
    local indicator = bar and bar:FindFirstChild("Indicator")
    local track = bar and bar:FindFirstChild("Bar")
    local gradient = track and track:FindFirstChildOfClass("UIGradient")
    if indicator and gradient then return indicator, gradient end
    return nil
end

-- true while the indicator sits well inside a freshly drawn green window
local function inSnowWindow(indicator, gradient)
    local points = gradient.Color.Keypoints
    local low, high = points[3], points[4]
    if not low or not high or not isGreen(low.Value) or high.Time <= low.Time then return false end
    local pad = math.min(0.03, (high.Time - low.Time) * 0.25)
    local x = indicator.Position.X.Scale
    return x >= low.Time + pad and x <= high.Time - pad
end

function Farm.hookSnow()
    return wrap("Minigame", "WaitForClick", function(original)
        return function(self, id)
            if not Settings.AutoSnow or Farm.snowMethod() ~= "Hook" or id ~= self.ID then return original(self, id) end
            local indicator, gradient = Farm.snowBar(self.lastInfo)
            if not indicator then return original(self, id) end
            local started = os.clock()
            while self.ID == id and Settings.AutoSnow and os.clock() - started < 20 do
                if inSnowWindow(indicator, gradient) then return true end
                RunService.RenderStepped:Wait()
            end
            if self.ID ~= id then return false end
            return original(self, id)
        end
    end)
end

function Farm.snowTapStep()
    if not Settings.AutoSnow or Farm.snowMethod() ~= "Tap" or os.clock() < Farm.snowTapAt then return end
    local minigame = mod("Minigame")
    local info = minigame and minigame.ID and minigame.lastInfo
    if not info or info.Type ~= "Snow" then return end
    local indicator, gradient = Farm.snowBar(info)
    if indicator and inSnowWindow(indicator, gradient) then
        Farm.snowTapAt = os.clock() + 0.35
        Input.click()
    end
end

-- Chest: Handler feeds clicks to the chest's own input handler (found by the
-- "Chest Try" sound it plays); Tap clicks the screen. Both about 14 a second.
local Clicker = { nextAt = 0 }

function Clicker.step()
    local minigame = Settings.AutoChest and mod("Minigame")
    local info = minigame and minigame.ID and minigame.lastInfo
    if not info or info.Type ~= "Chest" or os.clock() < Clicker.nextAt then return end
    Clicker.nextAt = os.clock() + 1 / 14
    local picked = Settings.ChestMethod
    local fns = picked ~= "Tap" and Handlers.find("chest", { "Chest Try" }) or {}
    if #fns > 0 then
        Handlers.click(fns)
    elseif picked ~= "Handler" then
        Input.click()
    end
end

--// fishing ----------------------------------------------------------------------------
-- Pressed only well inside the PERFECT radius (0.26 * 0.130 of the track).
local FISH_PERFECT = 0.026
local Fishing = { nextCast = 0, nextKey = 0 }

function Fishing.session()
    local ui = mod("MinigameUI")
    return ui, ui and rawget(ui, "session")
end

function Fishing.method()
    return methodOf("FishMethod", function() return mod("MinigameUI") and "Submit" or "Key" end)
end

function Fishing.step()
    if not Settings.AutoFish then return end
    local ui, session = Fishing.session()
    local active = session and session.active
    local current = session and session.currentUI
    if not active or not current or os.clock() < (active.nextSubmitTime or 0) then return end
    local ok, onTarget = pcall(function()
        if not current.screenGui.Enabled or not current.container.Visible then return false end
        local track = current.timingTrack
        local height = track.AbsoluteSize.Y
        if height <= 0 then return false end
        local top = track.AbsolutePosition.Y
        local marker = (current.timingMarker.AbsolutePosition.Y + current.timingMarker.AbsoluteSize.Y / 2 - top) / height
        local target = (current.catchTarget.AbsolutePosition.Y + current.catchTarget.AbsoluteSize.Y / 2 - top) / height
        return math.abs(marker - target) <= FISH_PERFECT
    end)
    if not ok or not onTarget then return end
    if Fishing.method() == "Key" then
        -- Space is one of the keys the game binds to its press
        if os.clock() >= Fishing.nextKey then
            Fishing.nextKey = os.clock() + 0.15
            Input.key(Enum.KeyCode.Space)
        end
    else
        pcall(ui.submit, ui)
    end
end

-- casts again at your own pond; the game only enables its prompt for the owner
function Fishing.cast()
    if not Settings.AutoCast or os.clock() < Fishing.nextCast then return end
    if LocalPlayer:GetAttribute("fishingUnlocked") ~= true then return end
    local _, session = Fishing.session()
    if session and session.active then return end
    local _, root = character()
    if not root then return end
    for _, spot in ipairs(CollectionService:GetTagged("fishingSpot")) do
        local prompt = spot:FindFirstChild("FishingPrompt")
        if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled and spot:IsA("BasePart")
            and (spot.Position - root.Position).Magnitude <= prompt.MaxActivationDistance then
            Fishing.nextCast = os.clock() + 3
            task.spawn(firePrompt, prompt, promptMethod("CastMethod"))
            return
        end
    end
end

--// combat -----------------------------------------------------------------------------
local Combat = { nextSwing = 0 }

function Combat.enemies()
    local folder = Workspace:FindFirstChild("Enemies")
    return folder and folder:GetChildren() or {}
end

-- a living enemy's humanoid, root and the part to aim at (its hitbox)
local function enemyParts(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return nil end
    local aim = model:FindFirstChild("ActualHB")
    if not aim or not aim:IsA("BasePart") then aim = root end
    return hum, root, aim
end

function Combat.gunData(tool)
    local config = gameConfig()
    return config and config.GunData and config.GunData[tool:GetAttribute("RealName")] or nil
end

function Combat.heldGun()
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if tool and Combat.gunData(tool) then return tool end
    return nil
end

-- The enemy nearest your aim inside the FOV cone, as the point to shoot at: led
-- for its velocity and for the bullet's drop (ProjectileWeight times gravity).
function Combat.aimPoint(tool, look)
    local muzzle = tool:FindFirstChild("MuzzleAtt", true)
    if not muzzle then return nil end
    local origin = muzzle.WorldCFrame.Position
    look = (look or muzzle.WorldCFrame.LookVector).Unit
    local gun = Combat.gunData(tool) or {}
    local speed = gun.ProjectileVelocity or 250
    local gravity = Workspace.Gravity * (gun.ProjectileWeight or 0)
    local minDot = math.cos(math.rad(math.min(Settings.AimFov, 180)))
    local best, bestDot
    for _, model in ipairs(Combat.enemies()) do
        local _, root, part = enemyParts(model)
        if part then
            local offset = part.Position - origin
            local dist = offset.Magnitude
            if dist > 1 and dist <= Settings.AimRange then
                local dot = offset.Unit:Dot(look)
                if (Settings.AimFov >= 180 or dot >= minDot) and (not best or dot > bestDot) then
                    best, bestDot = { root = root, part = part }, dot
                end
            end
        end
    end
    if not best then return nil end
    local velocity = best.root.AssemblyLinearVelocity
    local point = best.part.Position
    local t = (point - origin).Magnitude / speed
    for _ = 1, 3 do
        point = best.part.Position + velocity * t
        t = (point - origin).Magnitude / speed
    end
    return point + Vector3.new(0, 0.5 * gravity * t * t, 0), origin
end

function Combat.aimMethod()
    return methodOf("AimMethod", function()
        if hooked("guns") then return "Fire hook" end
        return "Mouse hook"
    end)
end

-- Fire hook: the direction the game hands to its fire function
function Combat.hookGun()
    return wrap("Firearm", "Fire", function(original)
        return function(self, tool, direction, ...)
            if Settings.GunAim and tool and Combat.aimMethod() == "Fire hook" then
                local ok, point, origin = pcall(Combat.aimPoint, tool, direction)
                if ok and point and (point - origin).Magnitude > 0.001 then direction = (point - origin).Unit end
            end
            return original(self, tool, direction, ...)
        end
    end)
end

-- Mouse hook: where the game thinks your mouse is pointing while you hold a gun
function Combat.hookMouse()
    return wrap("CommonUtils", "Mousecast", function(original)
        return function(params, distance, ...)
            local tool = Settings.GunAim and Combat.aimMethod() == "Mouse hook" and Combat.heldGun()
            if not tool then return original(params, distance, ...) end
            local hit, position = original(params, distance, ...)
            local muzzle = tool:FindFirstChild("MuzzleAtt", true)
            if muzzle and position then
                local ok, point = pcall(Combat.aimPoint, tool, position - muzzle.WorldCFrame.Position)
                if ok and point then return nil, point end
            end
            return hit, position
        end
    end)
end

-- melee is decided by the server when the tool activates, at the weapon's own
-- cooldown
function Combat.swing()
    if not Settings.AutoSwing or os.clock() < Combat.nextSwing then return end
    local char, root = character()
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return end
    local config = gameConfig()
    local weapon = config and config.Weapons and config.Weapons[tool:GetAttribute("RealName") or tool.Name]
    if not weapon or weapon.ItemType ~= "Melee" then return end
    for _, model in ipairs(Combat.enemies()) do
        local _, enemyRoot = enemyParts(model)
        if enemyRoot and (enemyRoot.Position - root.Position).Magnitude <= Settings.SwingReach then
            Combat.nextSwing = os.clock() + (weapon.Cooldown or 1) + 0.05
            if methodOf("SwingMethod", function() return "Activate" end) == "Tap" then
                Input.click()
            else
                pcall(tool.Activate, tool)
            end
            return
        end
    end
end

--// esp --------------------------------------------------------------------------------
local function guiRoot()
    if typeof(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

-- Highlights are capped (the engine draws about 31 at once), so past that
-- things get a label only.
local Esp = { objects = {}, root = nil, outlines = 0 }
local MAX_OUTLINES = 24
local COLORS = {
    Wolf = Color3.fromRGB(255, 160, 160),
    AlphaWolf = Color3.fromRGB(255, 70, 70),
    Yeti = Color3.fromRGB(170, 220, 255),
    Bigfoot = Color3.fromRGB(215, 160, 95),
    enemy = Color3.fromRGB(255, 200, 90),
    relic = Color3.fromRGB(255, 215, 0),
    chest = Color3.fromRGB(120, 230, 140),
    drop = Color3.fromRGB(240, 240, 240),
    loot = Color3.fromRGB(255, 240, 110),
}

function Esp.drop(key)
    local obj = Esp.objects[key]
    if not obj then return end
    Esp.objects[key] = nil
    if obj.gui then pcall(function() obj.gui:Destroy() end) end
    if obj.highlight then
        pcall(function() obj.highlight:Destroy() end)
        Esp.outlines = Esp.outlines - 1
    end
end

function Esp.show(seen, key, adornee, outline, text, color)
    seen[key] = true
    Esp.root = Esp.root or guiRoot()
    local obj = Esp.objects[key]
    if not obj then
        obj = {}
        Esp.objects[key] = obj
    end
    local style = Settings.EspStyle
    local wantLabel = style ~= "Outline"
    local wantOutline = style ~= "Label"
    if wantLabel and not obj.gui then
        local gui = Instance.new("BillboardGui")
        gui.Name = "stc_esp"
        gui.AlwaysOnTop = true
        gui.LightInfluence = 0
        gui.ResetOnSpawn = false
        gui.Size = UDim2.fromOffset(200, 30)
        gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
        gui.Adornee = adornee
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextSize = 12
        label.TextStrokeTransparency = 0.35
        label.Parent = gui
        gui.Parent = Esp.root
        obj.gui, obj.label = gui, label
    elseif not wantLabel and obj.gui then
        pcall(function() obj.gui:Destroy() end)
        obj.gui, obj.label = nil, nil
    end
    if wantOutline and not obj.highlight and Esp.outlines < MAX_OUTLINES then
        local highlight = Instance.new("Highlight")
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillTransparency = 0.8
        highlight.OutlineTransparency = 0.1
        highlight.Adornee = outline
        highlight.Parent = Esp.root
        obj.highlight = highlight
        Esp.outlines = Esp.outlines + 1
    elseif not wantOutline and obj.highlight then
        pcall(function() obj.highlight:Destroy() end)
        obj.highlight = nil
        Esp.outlines = Esp.outlines - 1
    end
    if obj.label then
        obj.label.Text = text
        obj.label.TextColor3 = color
    end
    if obj.highlight then
        obj.highlight.OutlineColor = color
        obj.highlight.FillColor = color
    end
end

-- "AirDrop chest  Medikit 10%": where a chest is from and its rarest loot
function Esp.chestText(id)
    local place = tostring(id):match("^([^_]+)_") or "Chest"
    local config = gameConfig()
    local poi = config and config.PointOfInterest and config.PointOfInterest[place]
    local rarest
    for _, chance in ipairs(poi and poi.Chances or {}) do
        if not rarest or chance.prob < rarest.prob then rarest = chance end
    end
    if rarest then return ("%s chest  %s %d%%"):format(place, rarest.name, math.floor(rarest.prob * 100 + 0.5)) end
    return place .. " chest"
end

local function meters(dist) return ("  %dm"):format(math.floor(dist + 0.5)) end

function Esp.step()
    local seen = {}
    local _, root = character()
    if root then
        local range = Settings.EspRange
        if Settings.EnemyEsp then
            for _, model in ipairs(Combat.enemies()) do
                local hum, enemyRoot = enemyParts(model)
                local dist = enemyRoot and (enemyRoot.Position - root.Position).Magnitude
                if dist and dist <= range then
                    local kind = model:GetAttribute("EnemyType") or model.Name
                    local text = ("%s%s  %d/%d"):format(kind, model:GetAttribute("IsRaidMob") and " (raid)" or "",
                        math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5)) .. meters(dist)
                    Esp.show(seen, model, enemyRoot, model, text, COLORS[kind] or COLORS.enemy)
                end
            end
        end
        local relic = Settings.RelicEsp and Farm.relic()
        local relicPart = relic and firstPart(relic.relicModel)
        if relicPart then
            local dist = (relicPart.Position - root.Position).Magnitude
            Esp.show(seen, relic.relicModel, relicPart, relic.relicModel, "your relic" .. meters(dist), COLORS.relic)
        end
        if Settings.ChestEsp then
            for id, entry in pairs(Farm.spawns() or {}) do
                local spawn = type(entry) == "table" and entry.Object
                local part = type(spawn) == "table" and spawn.Type == "Chest" and spawn.object and spawn.object.Parent and firstPart(spawn.object)
                local dist = part and (part.Position - root.Position).Magnitude
                if dist and dist <= range then
                    Esp.show(seen, spawn.object, part, spawn.object, Esp.chestText(id) .. meters(dist), COLORS.chest)
                end
            end
        end
        if Settings.DropEsp then
            local itemUI = mod("ItemUI")
            for item, entry in pairs(itemUI and itemUI.Collection or {}) do
                local dist = type(entry) == "table" and entry.part and item.Parent and (entry.part.Position - root.Position).Magnitude
                if dist and dist <= range then
                    Esp.show(seen, item, entry.part, item, item.Name .. meters(dist), COLORS.drop)
                end
            end
        end
        if Settings.LootEsp then
            local class = mod("LootChest")
            for model in pairs(class and class.Collection or {}) do
                local part = typeof(model) == "Instance" and model.Parent and firstPart(model)
                local dist = part and (part.Position - root.Position).Magnitude
                if dist and dist <= range then
                    local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
                    local text = (prompt and not prompt.Enabled) and "loot box (looted)" or "loot box"
                    Esp.show(seen, model, part, model, text .. meters(dist), COLORS.loot)
                end
            end
        end
    end
    for key in pairs(Esp.objects) do
        if not seen[key] then Esp.drop(key) end
    end
end

--// alerts ------------------------------------------------------------------------------
local Alerts = { warned = {}, lastStorm = nil, relicSeen = false, findNext = nil, watchingItems = false, itemsSince = 0 }

function Alerts.nextStorm()
    if Alerts.findNext == nil then
        local fn = requirePath("Shared.Utils.Gameplay.WorldEvents.FindTimePeriodForNextWorldEvent")
        Alerts.findNext = type(fn) == "function" and fn or false
    end
    if not Alerts.findNext then return nil end
    local ok, period = pcall(Alerts.findNext, "Main", "Snowstorm")
    return ok and type(period) == "table" and period.StartTimeStamp and period or nil
end

-- the game warns at two minutes and one; these come closer in
function Alerts.stormStep()
    if not Settings.AlertStorm then return end
    local period = Alerts.nextStorm()
    if period then
        local left = period.StartTimeStamp - Workspace:GetServerTimeNow()
        for _, mark in ipairs({ 30, 10 }) do
            local id = tostring(period.StartTimeStamp) .. ":" .. mark
            if left <= mark and left > mark - 5 and not Alerts.warned[id] then
                Alerts.warned[id] = true
                notify(("Snowstorm in %d seconds - get inside or next to a fire."):format(mark), true)
            end
        end
    end
    local active = Workspace:GetAttribute("IsSnowstormActive") == true
    if Alerts.lastStorm ~= nil and active ~= Alerts.lastStorm then
        if active then
            local kind = LocalPlayer:GetAttribute("ActiveStormType")
            notify("Snowstorm started" .. (kind and (" (" .. tostring(kind) .. ")") or "") .. ".", true)
        else
            notify("The snowstorm is over.")
        end
    end
    Alerts.lastStorm = active
end

function Alerts.relicStep()
    local obj = Farm.relic()
    if obj and not Alerts.relicSeen then
        Alerts.relicSeen = true
        local _, root = character()
        if Settings.AlertRelic and root then
            notify(("Your relic is out, %dm away."):format(math.floor((obj.relicModel:GetPivot().Position - root.Position).Magnitude + 0.5)))
        end
    elseif not obj then
        Alerts.relicSeen = false
    end
end

function Alerts.watchItems()
    if Alerts.watchingItems then return end
    local items = Workspace:FindFirstChild("Items")
    if not items then return end
    Alerts.watchingItems = true
    Alerts.itemsSince = os.clock()
    items.ChildAdded:Connect(function(child)
        if not alive() or not Settings.AlertAirdrop or not tostring(child.Name):match("^AirDrop") then return end
        -- the spawns the game lays out when it loads are not news
        if os.clock() - Alerts.itemsSince < 15 then return end
        task.wait(0.5)
        local _, root = character()
        local ok, pos = pcall(function() return child:GetPivot().Position end)
        if root and ok then
            notify(("An airdrop landed %dm away."):format(math.floor((pos - root.Position).Magnitude + 0.5)))
        else
            notify("An airdrop landed.")
        end
    end)
end

local RAID_MESSAGES = {
    OnRaidIncoming = "A raid is coming - get ready.",
    OnRaidStarted = "Raid started.",
    OnRaidCompleted = "Raid beaten.",
    OnRaidFailed = "Raid failed.",
}

function Alerts.hookRaids()
    local all = true
    for fnName, message in pairs(RAID_MESSAGES) do
        local ok = wrap("RaidController", fnName, function(original)
            return function(self, ...)
                if Settings.AlertRaid and alive() then
                    local text = message
                    if fnName == "OnRaidStarted" then
                        local level, _, _, waves = ...
                        text = ("Raid started: level %s, %s waves."):format(tostring(level), tostring(waves))
                    end
                    pcall(notify, text, fnName ~= "OnRaidCompleted")
                end
                return original(self, ...)
            end
        end)
        all = all and ok
    end
    return all
end

--// hooks and loops ----------------------------------------------------------------------
local HOOKS = {
    { name = "stamina", install = Survival.hookStamina },
    { name = "zone", install = Survival.hookZone },
    { name = "cold effects", install = Survival.hookColdEffects },
    { name = "snowstorm", install = Survival.hookStorm },
    { name = "snow", install = Farm.hookSnow },
    { name = "guns", install = Combat.hookGun },
    { name = "mouse", install = Combat.hookMouse },
    { name = "raids", install = Alerts.hookRaids },
}

local function installHooks()
    for _, hook in ipairs(HOOKS) do
        if not HookState.done[hook.name] then
            local ok, result = pcall(hook.install)
            if ok and result then
                HookState.done[hook.name] = true
                HookState.count = HookState.count + 1
            end
        end
    end
    pcall(Shelter.watch)
    pcall(Alerts.watchItems)
    return HookState.count == #HOOKS and Shelter.watching and Alerts.watchingItems
end

-- the game may still be loading its modules
task.spawn(function()
    for _ = 1, 90 do
        if not alive() or installHooks() then break end
        task.wait(1)
    end
    if alive() and HookState.count < #HOOKS then
        local missing = {}
        for _, hook in ipairs(HOOKS) do
            if not HookState.done[hook.name] then missing[#missing + 1] = hook.name end
        end
        notify("Could not hook " .. table.concat(missing, ", ") .. " - Auto uses the other methods for those.", true)
    end
end)

local renderConnection, heartbeatConnection
renderConnection = RunService.RenderStepped:Connect(function()
    if not alive() then
        renderConnection:Disconnect()
        return
    end
    pcall(Fishing.step)
    pcall(Clicker.step)
    pcall(Farm.snowTapStep)
end)
heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
    if not alive() then
        heartbeatConnection:Disconnect()
        return
    end
    pcall(Survival.staminaStep)
    pcall(Survival.speedStep, dt)
end)

task.spawn(function()
    while alive() do
        if Farm.enabled() or Settings.WalkTo then
            local ok = pcall(Farm.step)
            if not ok then Farm.status = "error, retrying" end
        else
            Farm.status = "idle"
            if Farm.walking then
                local _, root, hum = character()
                Farm.stopWalk(hum, root)
            end
        end
        pcall(Combat.swing)
        task.wait(0.1)
    end
end)

task.spawn(function()
    local ticks = 0
    while alive() do
        pcall(Esp.step)
        pcall(Fishing.cast)
        pcall(Survival.coldCleanup)
        pcall(Survival.stormCleanup)
        -- the movement module may load after the slider was set
        local mm = Settings.Speed ~= 1 and Survival.speedMethod() == "Game speed" and mod("MovementManager")
        if mm and mm.baseWalkSpeed ~= 16 * Settings.Speed then pcall(Survival.applySpeed) end
        ticks = ticks + 1
        if ticks % 4 == 0 then
            pcall(Survival.zoneStep)
            pcall(Shelter.step)
            pcall(Alerts.stormStep)
            pcall(Alerts.relicStep)
        end
        if ticks % 40 == 0 then
            -- forget drops and targets that are gone
            for item in pairs(Farm.tries) do
                if not item.Parent then Farm.tries[item] = nil end
            end
            for key, untilAt in pairs(Farm.avoid) do
                if untilAt <= os.clock() then Farm.avoid[key] = nil end
            end
        end
        task.wait(0.25)
    end
    for key in pairs(Esp.objects) do Esp.drop(key) end
end)

LocalPlayer.Idled:Connect(function()
    if Settings.AntiAfk and alive() then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    if alive() and Settings.Speed ~= 1 then Survival.applySpeed() end
end)

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
    Title = 'Survive the Cold',
    SubTitle = 'traits',
    Keybind = Enum.KeyCode.RightShift,
    Scope = 'game',
    Status = 'ready',
    StartOpen = true,
    Opener = 'Topbar',
})

pcall(function() Void:SetAccent(Color3.fromRGB(150, 210, 255)) end)

notify = function(content, warn)
    Void:Notify({ Title = 'Survive the Cold', Content = content, Duration = 5, Warn = warn == true })
end

-- A toggle and its method side by side. `changed` runs only when the value
-- really changes, so the call a UI may make at load with the default does nothing.
local function toggle(section, title, flag, setting, changed)
    section:Toggle({
        Title = title,
        Flag = flag,
        Default = Settings[setting],
        Half = true,
        Callback = function(v)
            if Settings[setting] == v then return end
            Settings[setting] = v
            if changed then changed(v) end
        end,
    })
end

local function method(section, flag, setting, values, changed)
    section:Dropdown({
        Title = 'method',
        Values = values,
        Default = Settings[setting],
        Flag = flag,
        Half = true,
        Callback = function(v)
            if type(v) ~= "string" or Settings[setting] == v then return end
            Settings[setting] = v
            if changed then changed(v) end
        end,
    })
end

local function slider(section, title, flag, setting, low, high, step, suffix, changed)
    section:Slider({
        Title = title,
        Flag = flag,
        Min = low,
        Max = high,
        Increment = step,
        Rounding = step < 1 and 2 or 0,
        Default = Settings[setting],
        Suffix = suffix,
        Callback = function(v)
            if Settings[setting] == v then return end
            Settings[setting] = v
            if changed then changed(v) end
        end,
    })
end

local function plainToggle(section, title, flag, setting)
    section:Toggle({
        Title = title,
        Flag = flag,
        Default = Settings[setting],
        Callback = function(v) Settings[setting] = v end,
    })
end

--// survival tab
local SurvivalTab = Window:CreateTab('survival')

local BodySection = SurvivalTab:CreateSection('you')
toggle(BodySection, 'infinite stamina', 'stc_stamina', 'InfStamina')
method(BodySection, 'stc_stamina_method', 'StaminaMethod', { 'Auto', 'Hook', 'Attribute' })
slider(BodySection, 'speed multiplier', 'stc_speed', 'Speed', 1, 3, 0.05, 'x', function() Survival.applySpeed() end)
method(BodySection, 'stc_speed_method', 'SpeedMethod', { 'Auto', 'Game speed', 'CFrame' }, function() Survival.applySpeed() end)

local ColdSection = SurvivalTab:CreateSection('cold')
toggle(ColdSection, 'report the green zone', 'stc_green', 'StayGreen', function() Survival.sendZone() end)
method(ColdSection, 'stc_green_method', 'ZoneMethod', { 'Auto', 'Rewrite', 'Resend' })
toggle(ColdSection, 'report no snowstorm', 'stc_shelter', 'Shelter', function() Shelter.toggled() end)
method(ColdSection, 'stc_shelter_method', 'ShelterMethod', { 'Auto', 'Attribute', 'Remote' })
ColdSection:Paragraph({
    Title = 'what those do',
    Content = 'Your client tells the server which cold zone you are in and whether the snowstorm is on you. These say green and no storm, so the cold should hit you like the safe zone even in a storm, and enemies that ignore the green zone ignore you. Storms may stop counting as survived while it is on.',
})
toggle(ColdSection, 'hide cold screen effects', 'stc_no_cold_fx', 'NoColdFx', function() Survival.refreshZoneEffect() end)
method(ColdSection, 'stc_cold_fx_method', 'ColdFxMethod', { 'Auto', 'Hook', 'Clean up' })
toggle(ColdSection, 'hide the snowstorm', 'stc_no_storm_fx', 'NoStormFx', function() Survival.refreshStorm() end)
method(ColdSection, 'stc_storm_fx_method', 'StormFxMethod', { 'Auto', 'Hook', 'Clean up' })

local StatusSection = SurvivalTab:CreateSection('status')
StatusSection:Paragraph({
    Title = 'methods',
    Content = 'Auto uses the game hook when it went in and the other method when it did not. Pick one yourself if Auto is not working for you.',
})
local HookLabel = StatusSection:Label('hooks: waiting for the game')

--// farming tab
local FarmTab = Window:CreateTab('farming')

local GatherSection = FarmTab:CreateSection('gathering')
toggle(GatherSection, 'branches', 'stc_branch', 'FarmBranch')
toggle(GatherSection, 'bushes', 'stc_bush', 'FarmBush')
toggle(GatherSection, 'trees', 'stc_tree', 'FarmTree')
method(GatherSection, 'stc_gather_method', 'GatherMethod', { 'Auto', 'Game hit', 'Swing' })
slider(GatherSection, 'reach', 'stc_reach', 'Reach', 6, 12, 0.5, ' studs')
slider(GatherSection, 'time between hits', 'stc_hit_delay', 'HitDelay', 0.3, 1.5, 0.05, 's')

local MinigameSection = FarmTab:CreateSection('minigames and loot')
toggle(MinigameSection, 'auto snow', 'stc_snow', 'AutoSnow')
method(MinigameSection, 'stc_snow_method', 'SnowMethod', { 'Auto', 'Hook', 'Tap' })
toggle(MinigameSection, 'auto chests', 'stc_chest', 'AutoChest')
method(MinigameSection, 'stc_chest_method', 'ChestMethod', { 'Auto', 'Handler', 'Tap' })
toggle(MinigameSection, 'auto pick up drops', 'stc_pickup', 'AutoPickup')
method(MinigameSection, 'stc_pickup_method', 'PickupMethod', { 'Auto', 'Request', 'Button' })
toggle(MinigameSection, 'auto loot boxes', 'stc_loot', 'AutoLoot')
method(MinigameSection, 'stc_loot_method', 'LootMethod', { 'Auto', 'Prompt', 'Hold' })
toggle(MinigameSection, 'auto collect your relic', 'stc_relic', 'AutoRelic')
method(MinigameSection, 'stc_relic_method', 'RelicMethod', { 'Auto', 'Prompt', 'Request' })

local FishSection = FarmTab:CreateSection('fishing')
toggle(FishSection, 'auto fish (perfect hits)', 'stc_fish', 'AutoFish')
method(FishSection, 'stc_fish_method', 'FishMethod', { 'Auto', 'Submit', 'Key' })
toggle(FishSection, 'cast again at your pond', 'stc_cast', 'AutoCast')
method(FishSection, 'stc_cast_method', 'CastMethod', { 'Auto', 'Prompt', 'Hold' })

local MoveSection = FarmTab:CreateSection('movement')
toggle(MoveSection, 'go to the next target', 'stc_walk', 'WalkTo')
method(MoveSection, 'stc_walk_method', 'WalkMethod', { 'Walk', 'Pathfind', 'Teleport' })
slider(MoveSection, 'search radius', 'stc_walk_radius', 'WalkRadius', 30, 400, 10, ' studs')
plainToggle(MoveSection, 'anti afk', 'stc_afk', 'AntiAfk')
local FarmLabel = MoveSection:Label('farm: idle')

--// combat tab
local CombatTab = Window:CreateTab('combat')

local GunSection = CombatTab:CreateSection('guns')
toggle(GunSection, 'aim assist on enemies', 'stc_gun_aim', 'GunAim')
method(GunSection, 'stc_aim_method', 'AimMethod', { 'Auto', 'Fire hook', 'Mouse hook' })
slider(GunSection, 'aim cone', 'stc_aim_fov', 'AimFov', 5, 180, 5, ' deg')
slider(GunSection, 'aim range', 'stc_aim_range', 'AimRange', 50, 800, 25, ' studs')

local MeleeSection = CombatTab:CreateSection('melee')
toggle(MeleeSection, 'auto swing at enemies', 'stc_swing', 'AutoSwing')
method(MeleeSection, 'stc_swing_method', 'SwingMethod', { 'Auto', 'Activate', 'Tap' })
slider(MeleeSection, 'swing reach', 'stc_swing_reach', 'SwingReach', 5, 14, 0.5, ' studs')

--// esp and alerts tab
local EspTab = Window:CreateTab('esp & alerts')

local EspSection = EspTab:CreateSection('esp')
toggle(EspSection, 'enemies', 'stc_esp', 'EnemyEsp')
toggle(EspSection, 'your relic', 'stc_esp_relic', 'RelicEsp')
toggle(EspSection, 'chests', 'stc_esp_chest', 'ChestEsp')
toggle(EspSection, 'dropped items', 'stc_esp_drop', 'DropEsp')
toggle(EspSection, 'loot boxes', 'stc_esp_loot', 'LootEsp')
EspSection:Dropdown({
    Title = 'style',
    Values = { 'Label + outline', 'Label', 'Outline' },
    Default = Settings.EspStyle,
    Flag = 'stc_esp_style',
    Half = true,
    Callback = function(v) if type(v) == "string" then Settings.EspStyle = v end end,
})
slider(EspSection, 'esp range', 'stc_esp_range', 'EspRange', 100, 1500, 50, ' studs')

local AlertSection = EspTab:CreateSection('alerts')
toggle(AlertSection, 'snowstorms', 'stc_alert_storm', 'AlertStorm')
toggle(AlertSection, 'raids', 'stc_alert_raid', 'AlertRaid')
toggle(AlertSection, 'airdrops', 'stc_alert_airdrop', 'AlertAirdrop')
toggle(AlertSection, 'your relic', 'stc_alert_relic', 'AlertRelic')

task.spawn(function()
    while alive() and task.wait(1) do
        pcall(function()
            HookLabel:SetText(('hooks: %d/%d ready'):format(HookState.count, #HOOKS))
            FarmLabel:SetText('farm: ' .. Farm.status)
        end)
    end
end)
