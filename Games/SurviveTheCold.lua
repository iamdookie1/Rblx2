--// [TRAITS] Survive the Cold ---------------------------------------------------------
-- Built against a script dump of the live game (place 134750290201751, version 801).
--
-- What the game's own client scripts show:
--  * Every client system is a module that the game's ModuleLoader stores in
--    `shared` under its own name (shared.MovementManager, shared.Minigame, ...),
--    and the game calls their functions through that table. Swapping a function
--    on the table changes what the game itself runs, so everything below goes
--    through the game's own code paths, with the arguments it would use.
--  * All networking is shared.NetworkingClient:RequestServer(name, ...). The
--    shared Networking modules also hold the server's checks: an item pickup must
--    be within 15 studs, and a gun shot must start within 20 studs of you, wait
--    out the gun's cooldown and spend real ammo.
--  * Stamina is only your character's Stamina attribute, drained and refilled by
--    MovementManager.UpdateStamina every frame. Walk and run speed come from
--    MovementManager.baseWalkSpeed / baseRunSpeed (16 / 32).
--  * Your cold zone (Green, Yellow, Red) is reported by the client: Zones sends
--    RequestServer("ChangeZone", zone) when you walk into one, and the server
--    stores it as your FreezeSpot. Enemy AI set to IgnoreGreenZones skips anyone
--    whose FreezeSpot is Green.
--  * Screen effects: TemperatureEffects (breath, shivering, frost mask, blur)
--    runs off Data.Temperature, Snowstorm swaps lighting presets and parents a
--    storm model, and Zones parents a Yellow/Red zone effect around you.
--  * Gathering: branches, bushes and trees are per-player spawns tagged
--    BranchInteraction / FiberInteraction / WoodCutInteraction. Each hit is
--    obj:TakeDamage(); the first opens the minigame on the server and the last
--    ends it. Snow piles and chests are MinigameSpawner spawns with a prompt:
--    AttemptMinigame, then the server starts Minigame.StartMinigame. Snow is a
--    timing bar (Minigame.WaitForClick waits for a tap, then the indicator is
--    checked against the green window drawn into the bar's UIGradient); a chest
--    is "click as fast as you can" on a UserInputService.InputBegan handler.
--  * Fishing is a timing session (Client.UI.MinigameUI): a press only counts
--    with the marker on the catch target, and is PERFECT within 0.034 of its
--    centre.
--  * Guns: shared.Firearm:Fire(tool, direction) sends CreateProjectile with the
--    muzzle position and a unit direction, and the server flies the bullet at
--    the gun's ProjectileVelocity. Enemies live in Workspace.Enemies with a
--    Humanoid. Melee is server side: activating the tool is the whole attack.
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
    InfStamina = false,
    Speed = 1,
    StayGreen = false,
    NoColdFx = false,
    NoStormFx = false,
    -- farming
    FarmBranch = false,
    FarmBush = false,
    FarmTree = false,
    AutoSnow = false,
    AutoChest = false,
    AutoPickup = false,
    WalkTo = false,
    Reach = 10,
    HitDelay = 0.6,
    WalkRadius = 150,
    AutoFish = false,
    AutoCast = false,
    AntiAfk = false,
    -- combat
    GunAim = false,
    AimFov = 35,
    AimRange = 350,
    AutoSwing = false,
    SwingReach = 9,
    EnemyEsp = false,
    EspRange = 500,
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
    MinigameUI = "Client.UI.MinigameUI",
}

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
    local inst = ReplicatedStorage
    for part in string.gmatch(MODULE_PATHS[name] or "", "[^%.]+") do
        inst = inst and inst:FindFirstChild(part)
    end
    if inst and inst:IsA("ModuleScript") then
        local ok, value = pcall(require, inst)
        if ok and type(value) == "table" then
            Modules[name] = value
            return value
        end
    end
    return nil
end

local GameConfig
local function gameConfig()
    if GameConfig == nil then
        local ok, value = pcall(function() return require(ReplicatedStorage.Shared.Data.Config) end)
        GameConfig = (ok and type(value) == "table") and value or false
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

--// survival ---------------------------------------------------------------------------
local Survival = { reportedZone = nil, ourSend = false }

-- With infinite stamina on, every frame's update is run as a long rest, so the
-- game refills the attribute to your real maximum itself.
function Survival.hookStamina()
    return wrap("MovementManager", "UpdateStamina", function(original)
        return function(self, dt)
            if Settings.InfStamina then
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

function Survival.applySpeed()
    local mm = mod("MovementManager")
    if not mm then return end
    mm.baseWalkSpeed = 16 * Settings.Speed
    mm.baseRunSpeed = 32 * Settings.Speed
    -- recomputes WalkSpeed (or the run tween) from the new bases, buffs included
    pcall(mm.HandleDrivingChange, mm)
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
                if Settings.StayGreen and zone ~= "Green" then
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
        Survival.ourSend = true
        request("ChangeZone", zone)
    end)
end

function Survival.hookColdEffects()
    local temperature = wrap("TemperatureEffects", "UpdateTemperatureEffects", function(original)
        return function(self, dt)
            if Settings.NoColdFx then
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
            if Settings.NoColdFx then return end
            return original(self, ...)
        end
    end)
    return temperature and zones
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

function Survival.hookStorm()
    local vfx = wrap("Snowstorm", "StartSnowstormVFX", function(original)
        return function(self, ...)
            if Settings.NoStormFx then return end
            return original(self, ...)
        end
    end)
    local lighting = wrap("Snowstorm", "tweenLighting", function(original)
        return function(self, preset, plain)
            if Settings.NoStormFx then return original(self, CLEAR_SKY, false) end
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
        pcall(storm.tweenLighting, storm, CLEAR_SKY)
        return
    end
    storm.vfxActive = false
    task.spawn(function()
        pcall(storm.updateLighting, storm)
        pcall(storm.updateVFX, storm)
    end)
end

--// farming ----------------------------------------------------------------------------
local Farm = { nextHit = 0, tries = {}, cooldown = {}, avoid = {}, walking = nil, status = "idle" }

local RESOURCE_KINDS = {
    { module = "BranchInteraction", setting = "FarmBranch", label = "branch" },
    { module = "FiberInteraction", setting = "FarmBush", label = "bush" },
    { module = "WoodCutInteraction", setting = "FarmTree", label = "tree" },
}

function Farm.enabled()
    return Settings.FarmBranch or Settings.FarmBush or Settings.FarmTree or Settings.AutoSnow
        or Settings.AutoChest or Settings.AutoPickup
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
                        out[#out + 1] = { kind = kind.label, obj = obj, key = obj, dist = dist, pos = obj.pos.Position }
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

function Farm.pickup(root)
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

function Farm.stopWalk(hum, root)
    if Farm.walking then
        Farm.walking = nil
        if hum and root then pcall(hum.MoveTo, hum, root.Position) end
    end
end

function Farm.walk(root, hum)
    local list = {}
    Farm.resources(root, Settings.WalkRadius, list)
    Farm.minigames(root, Settings.WalkRadius, list)
    if Settings.AutoPickup then Farm.drops(root, Settings.WalkRadius, list) end
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
    if os.clock() - w.progressAt > 1.5 then hum.Jump = true end
    Farm.status = "walking to " .. best.kind
    hum:MoveTo(best.pos)
end

function Farm.step()
    local _, root, hum = character()
    if not root then
        Farm.status = "no character"
        return
    end
    if Settings.AutoPickup then Farm.pickup(root) end
    if Farm.minigameBusy() then
        Farm.status = "playing minigame"
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
            -- the game's own hit: effects, drops and the server calls all included
            pcall(target.obj.TakeDamage, target.obj)
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

-- Snow: while auto snow is on, the tap the minigame waits for comes the moment
-- the indicator is inside the green window of the bar.
local SNOW_GREEN = Color3.fromRGB(130, 255, 55)

local function isGreen(color)
    return math.abs(color.R - SNOW_GREEN.R) < 0.02 and math.abs(color.G - SNOW_GREEN.G) < 0.02
        and math.abs(color.B - SNOW_GREEN.B) < 0.02
end

function Farm.hookSnow()
    return wrap("Minigame", "WaitForClick", function(original)
        return function(self, id)
            if not Settings.AutoSnow or id ~= self.ID then return original(self, id) end
            local info = self.lastInfo
            local items = Workspace:FindFirstChild("Items")
            local pile = info and items and items:FindFirstChild(info.ID)
            local bar = pile and pile:FindFirstChild("MinigameBar", true)
            local indicator = bar and bar:FindFirstChild("Indicator")
            local track = bar and bar:FindFirstChild("Bar")
            local gradient = track and track:FindFirstChildOfClass("UIGradient")
            if not indicator or not gradient then return original(self, id) end
            local started = os.clock()
            while self.ID == id and Settings.AutoSnow and os.clock() - started < 20 do
                local points = gradient.Color.Keypoints
                local low, high = points[3], points[4]
                if low and high and isGreen(low.Value) and high.Time > low.Time then
                    local pad = math.min(0.03, (high.Time - low.Time) * 0.25)
                    local x = indicator.Position.X.Scale
                    if x >= low.Time + pad and x <= high.Time - pad then return true end
                end
                RunService.RenderStepped:Wait()
            end
            if self.ID ~= id then return false end
            return original(self, id)
        end
    end)
end

-- Chest: the minigame counts clicks on its own InputBegan handler, found by the
-- "Chest Try" sound it plays, and fed a left click as fast as a quick player.
local Clicker = { handlers = nil, scannedFor = nil, nextAt = 0 }
local FAKE_CLICK = { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }

function Clicker.scan()
    local found = {}
    local getconsts = (type(debug) == "table" and debug.getconstants) or (typeof(getconstants) == "function" and getconstants) or nil
    if typeof(getconnections) ~= "function" or not getconsts then return found end
    local ok, connections = pcall(getconnections, UserInputService.InputBegan)
    if not ok or type(connections) ~= "table" then return found end
    for _, connection in ipairs(connections) do
        local fn = connection.Function
        if type(fn) == "function" then
            local okc, constants = pcall(getconsts, fn)
            if okc and type(constants) == "table" then
                for _, c in pairs(constants) do
                    if c == "Chest Try" then
                        found[#found + 1] = fn
                        break
                    end
                end
            end
        end
    end
    return found
end

function Clicker.virtualClick()
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local size = Workspace.CurrentCamera.ViewportSize
        vim:SendMouseButtonEvent(size.X * 0.5, size.Y * 0.4, 0, true, game, 0)
        vim:SendMouseButtonEvent(size.X * 0.5, size.Y * 0.4, 0, false, game, 0)
    end)
end

function Clicker.step()
    local minigame = Settings.AutoChest and mod("Minigame")
    local info = minigame and minigame.ID and minigame.lastInfo
    if not info or info.Type ~= "Chest" then
        Clicker.handlers, Clicker.scannedFor = nil, nil
        return
    end
    if os.clock() < Clicker.nextAt then return end
    Clicker.nextAt = os.clock() + 1 / 14
    if Clicker.scannedFor ~= minigame.ID then
        Clicker.handlers = Clicker.scan()
        if #Clicker.handlers > 0 then Clicker.scannedFor = minigame.ID end
    end
    if Clicker.handlers and #Clicker.handlers > 0 then
        for _, fn in ipairs(Clicker.handlers) do task.spawn(pcall, fn, FAKE_CLICK, false) end
    else
        Clicker.virtualClick()
    end
end

--// fishing ----------------------------------------------------------------------------
-- Pressed only well inside the PERFECT radius (0.26 * 0.130 of the track).
local FISH_PERFECT = 0.026
local Fishing = { nextCast = 0 }

function Fishing.session()
    local ui = mod("MinigameUI")
    return ui, ui and rawget(ui, "session")
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
    if ok and onTarget then pcall(ui.submit, ui) end
end

local function firePrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
        return
    end
    pcall(function()
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.05)
        prompt:InputHoldEnd()
    end)
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
            task.spawn(firePrompt, prompt)
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

-- The enemy nearest your aim inside the FOV cone, led for its velocity and for
-- the bullet's drop (the gun's ProjectileWeight times gravity).
function Combat.aim(tool, direction)
    local muzzle = tool:FindFirstChild("MuzzleAtt", true)
    if not muzzle then return nil end
    local origin = muzzle.WorldCFrame.Position
    local look = (direction or muzzle.WorldCFrame.LookVector).Unit
    local config = gameConfig()
    local gun = (config and config.GunData and config.GunData[tool:GetAttribute("RealName")]) or {}
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
    point = point + Vector3.new(0, 0.5 * gravity * t * t, 0)
    local aim = point - origin
    if aim.Magnitude < 0.001 then return nil end
    return aim.Unit
end

function Combat.hookGun()
    return wrap("Firearm", "Fire", function(original)
        return function(self, tool, direction, ...)
            if Settings.GunAim and tool then
                local ok, aimed = pcall(Combat.aim, tool, direction)
                if ok and aimed then direction = aimed end
            end
            return original(self, tool, direction, ...)
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
            pcall(tool.Activate, tool)
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

local Esp = { objects = {}, root = nil }
local ENEMY_COLORS = {
    Wolf = Color3.fromRGB(255, 160, 160),
    AlphaWolf = Color3.fromRGB(255, 70, 70),
    Yeti = Color3.fromRGB(170, 220, 255),
    Bigfoot = Color3.fromRGB(215, 160, 95),
}

function Esp.make(model, adornee)
    Esp.root = Esp.root or guiRoot()
    local gui = Instance.new("BillboardGui")
    gui.Name = "stc_esp"
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.ResetOnSpawn = false
    gui.Size = UDim2.fromOffset(180, 30)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
    gui.Adornee = adornee
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 12
    label.TextStrokeTransparency = 0.35
    label.Text = ""
    label.Parent = gui
    gui.Parent = Esp.root
    local highlight = Instance.new("Highlight")
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillTransparency = 0.8
    highlight.OutlineTransparency = 0.1
    highlight.Adornee = model
    highlight.Parent = Esp.root
    local obj = { gui = gui, label = label, highlight = highlight }
    Esp.objects[model] = obj
    return obj
end

function Esp.drop(model)
    local obj = Esp.objects[model]
    if not obj then return end
    Esp.objects[model] = nil
    pcall(function() obj.gui:Destroy() end)
    pcall(function() obj.highlight:Destroy() end)
end

function Esp.step()
    local seen = {}
    local _, root = character()
    if Settings.EnemyEsp and root then
        for _, model in ipairs(Combat.enemies()) do
            local hum, enemyRoot = enemyParts(model)
            local dist = enemyRoot and (enemyRoot.Position - root.Position).Magnitude
            if dist and dist <= Settings.EspRange then
                seen[model] = true
                local obj = Esp.objects[model] or Esp.make(model, enemyRoot)
                local kind = model:GetAttribute("EnemyType") or model.Name
                local color = ENEMY_COLORS[kind] or Color3.fromRGB(255, 200, 90)
                obj.label.Text = ("%s  %d/%d  %dm"):format(kind, math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5), math.floor(dist + 0.5))
                obj.label.TextColor3 = color
                obj.highlight.OutlineColor = color
                obj.highlight.FillColor = color
            end
        end
    end
    for model in pairs(Esp.objects) do
        if not seen[model] then Esp.drop(model) end
    end
end

--// hooks and loops ----------------------------------------------------------------------
local HOOKS = {
    { name = "stamina", install = Survival.hookStamina },
    { name = "zone", install = Survival.hookZone },
    { name = "cold effects", install = Survival.hookColdEffects },
    { name = "snowstorm", install = Survival.hookStorm },
    { name = "snow", install = Farm.hookSnow },
    { name = "guns", install = Combat.hookGun },
}
local HookState = { done = {}, count = 0 }

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
    return HookState.count == #HOOKS
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
        notify("Could not hook: " .. table.concat(missing, ", ") .. " - the game may have changed.", true)
    end
end)

local frameConnection
frameConnection = RunService.RenderStepped:Connect(function()
    if not alive() then
        frameConnection:Disconnect()
        return
    end
    pcall(Fishing.step)
    pcall(Clicker.step)
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
        -- the movement module may load after the slider was set
        local mm = Settings.Speed ~= 1 and mod("MovementManager")
        if mm and mm.baseWalkSpeed ~= 16 * Settings.Speed then pcall(Survival.applySpeed) end
        ticks = ticks + 1
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
    for model in pairs(Esp.objects) do Esp.drop(model) end
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

--// survival tab
local SurvivalTab = Window:CreateTab('survival')

local BodySection = SurvivalTab:CreateSection('you')
BodySection:Toggle({
    Title = 'infinite stamina',
    Flag = 'stc_stamina',
    Default = false,
    Callback = function(v) Settings.InfStamina = v end,
})
BodySection:Slider({
    Title = 'speed multiplier',
    Flag = 'stc_speed',
    Min = 1,
    Max = 3,
    Increment = 0.05,
    Rounding = 2,
    Default = 1,
    Suffix = 'x',
    Callback = function(v)
        if Settings.Speed == v then return end
        Settings.Speed = v
        Survival.applySpeed()
    end,
})

local ColdSection = SurvivalTab:CreateSection('cold')
ColdSection:Toggle({
    Title = 'always report the green zone',
    Flag = 'stc_green',
    Default = false,
    Callback = function(v)
        if Settings.StayGreen == v then return end
        Settings.StayGreen = v
        Survival.sendZone()
    end,
})
ColdSection:Paragraph({
    Title = 'what that does',
    Content = 'Your client tells the server which cold zone you are in. This always says green, so yellow and red areas should chill you like the safe zone, and enemies that ignore the green zone ignore you.',
})
ColdSection:Toggle({
    Title = 'hide cold screen effects',
    Flag = 'stc_no_cold_fx',
    Default = false,
    Callback = function(v)
        if Settings.NoColdFx == v then return end
        Settings.NoColdFx = v
        Survival.refreshZoneEffect()
    end,
})
ColdSection:Toggle({
    Title = 'hide the snowstorm',
    Flag = 'stc_no_storm_fx',
    Default = false,
    Callback = function(v)
        if Settings.NoStormFx == v then return end
        Settings.NoStormFx = v
        Survival.refreshStorm()
    end,
})

local HookSection = SurvivalTab:CreateSection('status')
local HookLabel = HookSection:Label('hooks: waiting for the game')

--// farming tab
local FarmTab = Window:CreateTab('farming')

local GatherSection = FarmTab:CreateSection('gathering')
GatherSection:Toggle({
    Title = 'branches',
    Flag = 'stc_branch',
    Default = false,
    Half = true,
    Callback = function(v) Settings.FarmBranch = v end,
})
GatherSection:Toggle({
    Title = 'bushes',
    Flag = 'stc_bush',
    Default = false,
    Half = true,
    Callback = function(v) Settings.FarmBush = v end,
})
GatherSection:Toggle({
    Title = 'trees',
    Flag = 'stc_tree',
    Default = false,
    Callback = function(v) Settings.FarmTree = v end,
})
GatherSection:Slider({
    Title = 'reach',
    Flag = 'stc_reach',
    Min = 6,
    Max = 12,
    Increment = 0.5,
    Default = 10,
    Suffix = ' studs',
    Callback = function(v) Settings.Reach = v end,
})
GatherSection:Slider({
    Title = 'time between hits',
    Flag = 'stc_hit_delay',
    Min = 0.3,
    Max = 1.5,
    Increment = 0.05,
    Rounding = 2,
    Default = 0.6,
    Suffix = 's',
    Callback = function(v) Settings.HitDelay = v end,
})

local MinigameSection = FarmTab:CreateSection('minigames')
MinigameSection:Toggle({
    Title = 'auto snow',
    Flag = 'stc_snow',
    Default = false,
    Half = true,
    Callback = function(v) Settings.AutoSnow = v end,
})
MinigameSection:Toggle({
    Title = 'auto chests',
    Flag = 'stc_chest',
    Default = false,
    Half = true,
    Callback = function(v) Settings.AutoChest = v end,
})
MinigameSection:Toggle({
    Title = 'auto pick up drops',
    Flag = 'stc_pickup',
    Default = false,
    Callback = function(v) Settings.AutoPickup = v end,
})

local FishSection = FarmTab:CreateSection('fishing')
FishSection:Toggle({
    Title = 'auto fish (perfect hits)',
    Flag = 'stc_fish',
    Default = false,
    Callback = function(v) Settings.AutoFish = v end,
})
FishSection:Toggle({
    Title = 'cast again at your pond',
    Flag = 'stc_cast',
    Default = false,
    Callback = function(v) Settings.AutoCast = v end,
})

local MoveSection = FarmTab:CreateSection('movement')
MoveSection:Toggle({
    Title = 'walk to the next target',
    Flag = 'stc_walk',
    Default = false,
    Callback = function(v) Settings.WalkTo = v end,
})
MoveSection:Slider({
    Title = 'search radius',
    Flag = 'stc_walk_radius',
    Min = 30,
    Max = 400,
    Increment = 10,
    Default = 150,
    Suffix = ' studs',
    Callback = function(v) Settings.WalkRadius = v end,
})
MoveSection:Toggle({
    Title = 'anti afk',
    Flag = 'stc_afk',
    Default = false,
    Callback = function(v) Settings.AntiAfk = v end,
})
local FarmLabel = MoveSection:Label('farm: idle')

--// combat tab
local CombatTab = Window:CreateTab('combat')

local GunSection = CombatTab:CreateSection('guns')
GunSection:Toggle({
    Title = 'aim assist on enemies',
    Flag = 'stc_gun_aim',
    Default = false,
    Callback = function(v) Settings.GunAim = v end,
})
GunSection:Slider({
    Title = 'aim cone',
    Flag = 'stc_aim_fov',
    Min = 5,
    Max = 180,
    Increment = 5,
    Default = 35,
    Suffix = ' deg',
    Callback = function(v) Settings.AimFov = v end,
})
GunSection:Slider({
    Title = 'aim range',
    Flag = 'stc_aim_range',
    Min = 50,
    Max = 800,
    Increment = 25,
    Default = 350,
    Suffix = ' studs',
    Callback = function(v) Settings.AimRange = v end,
})

local MeleeSection = CombatTab:CreateSection('melee')
MeleeSection:Toggle({
    Title = 'auto swing at enemies in reach',
    Flag = 'stc_swing',
    Default = false,
    Callback = function(v) Settings.AutoSwing = v end,
})
MeleeSection:Slider({
    Title = 'swing reach',
    Flag = 'stc_swing_reach',
    Min = 5,
    Max = 14,
    Increment = 0.5,
    Default = 9,
    Suffix = ' studs',
    Callback = function(v) Settings.SwingReach = v end,
})

local EspSection = CombatTab:CreateSection('esp')
EspSection:Toggle({
    Title = 'enemy esp',
    Flag = 'stc_esp',
    Default = false,
    Callback = function(v) Settings.EnemyEsp = v end,
})
EspSection:Slider({
    Title = 'esp range',
    Flag = 'stc_esp_range',
    Min = 100,
    Max = 1500,
    Increment = 50,
    Default = 500,
    Suffix = ' studs',
    Callback = function(v) Settings.EspRange = v end,
})

task.spawn(function()
    while alive() and task.wait(1) do
        pcall(function()
            HookLabel:SetText(('hooks: %d/%d ready'):format(HookState.count, #HOOKS))
            FarmLabel:SetText('farm: ' .. Farm.status)
        end)
    end
end)
