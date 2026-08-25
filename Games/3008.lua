--// 3008 -------------------------------------------------------------------------
-- Built against a script dump of the live game.
--
-- Nearly everything the client asks the server to do goes through two remotes
-- that live on your own character:
--
--   Character.System.Action : RemoteFunction : InvokeServer("Name", {table})
--   Character.System.Event  : RemoteEvent    : FireServer("Name", {table})
--
-- Verified signatures used below:
--   Action:InvokeServer("Pickup",            {Model = model})
--   Action:InvokeServer("Drop",              {EndCFrame = cf, Throw = bool,
--                                             CameraCFrame = v3, ThrowPower = n})
--   Action:InvokeServer("Store",             {Model = model})
--   Action:InvokeServer("Interact",          {Model = model})
--   Action:InvokeServer("Inventory_Consume", {Tool = toolName})
--   Action:InvokeServer("ShoveEmployee",     {Humanoid = humanoid})
--   Action:InvokeServer("Whistle")
--   Event :FireServer  ("FallDamage",        data)
--   Event :FireServer  ("DecreaseStat",      {Stats = {Energy = n}})
--
-- Three shared sources decide what this script believes about the world, and
-- reading them beats any table we could hardcode:
--
--   ReplicatedStorage.Modules.Item      : get(name) -> item definition, so
--                                         food, healing and harmful items are
--                                         the game's own classification
--   ReplicatedStorage.Remotes.Communication
--                                       : OnClientEvent("ShowWhistle",
--                                         {Player, Position}) - every whistle
--                                         in the server, with its exact spot
--   CollectionService tags              : "Item" makes a model grabbable,
--                                         "Storable" and "Interactable" decide
--                                         which action E runs on it
--
-- The client's own PickupSystem lives at
--   Players.LocalPlayer.PlayerScripts.source.client.Building (ModuleScript)
-- and require is cached per instance, so requiring it returns the same table
-- the game is using. That is where the LIVE carry distance lives.
--
-- Player attributes:
--   LocalPlayer:GetAttribute("ScrollDistance")   - CEILING for carry distance,
--                                                  not the distance itself
--   LocalPlayer:GetAttribute("IsHolding")        - server owned, the honest
--                                                  answer to "am I holding
--                                                  something right now"
--   LocalPlayer:GetAttribute("MaxInventorySpace")- server owned, read for the
--                                                  "n/m items" text
--   Humanoid   :GetAttribute("Hunger")           - read only, server owned
--
-- The moderator panel's one lever, aimed at ourselves in the server tab:
--   Remotes.Vip:FireServer("UpdatePlayerProperties",
--       {Properties = {...}, ToPlayer = player})
--
-- Where the server is authoritative, the UI says so instead of shipping a
-- toggle that only lies to your own HUD.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local Workspace = workspace

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function resolveEvent(modernName, legacyName)
    local ok, event = pcall(function() return RunService[modernName] end)
    if ok and event then return event end
    return RunService[legacyName]
end

local PreRender = resolveEvent("PreRender", "RenderStepped")
local PreSimulation = resolveEvent("PreSimulation", "Stepped")
local PostSimulation = resolveEvent("PostSimulation", "Heartbeat")

--// Lifecycle -------------------------------------------------------------------
local Connections = {}
local Unloading = false

-- Declared up here because the systems below want to talk long before the UI
-- that owns the notifier is built.
local notify

local function track(connection)
    Connections[#Connections + 1] = connection
    return connection
end

local function spawnLoop(fn)
    return task.spawn(fn)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then Camera = Workspace.CurrentCamera end
end)

--// Config ----------------------------------------------------------------------
local Main = {
    AutoCollect = false,
    CollectRadius = 60,
    CollectFood = true,
    CollectAll = false,
    CollectDelay = 0.35,

    AutoEat = false,
    HungerThreshold = 40,
    AutoHeal = false,
    HealthThreshold = 50,

    RemoteShove = false,
    ShoveRadius = 40,
    ShoveDelay = 1.2,

    AutoWhistle = false,
    WhistleInterval = 16,

    AutoUnstick = false,
    UnstickAfter = 3,
}

-- Another player's whistle is broadcast to every client as
-- Remotes.Communication:FireClient("ShowWhistle", { Player = plr, Position = v3 })
-- so the exact spot they whistled from arrives here for free - no guessing,
-- no config, and it works even while they are streamed out.
local Whistle = {
    Follow = false,
    Target = 'anyone',
    WaitSeconds = 60,
    ExpiresAt = 0,
    Offset = 6,
    Last = nil,
}

local Player = {
    InfiniteEnergy = false,
    NoFallDamage = false,

    SpeedEnabled = false,
    WalkSpeed = 16,
    JumpEnabled = false,
    JumpPower = 50,
    InfiniteJump = false,
    Noclip = false,
    Fly = false,
    FlySpeed = 70,
    ReachEnabled = false,
    Reach = 30,
    AntiAFK = true,

    MobileFly = true,
    GrabKey = Enum.KeyCode.V,
}

local Visual = {
    Employees = false,
    Items = false,
    PlayersEsp = false,
    Method = "Highlight",
    Transparency = 0.5,
    ShowNames = true,
    ShowDistance = true,
    ItemFilter = "Food",
    MaxEspDistance = 1500,
    -- 0 means no cap at all. The old build had no visible count limit but the
    -- Highlight method silently hit the engine's ~31-instance ceiling, which
    -- is what made item ESP look broken in a shop full of pizza.
    MaxEspCount = 150,

    Fullbright = false,
    NoFog = false,
    StripCeiling = false,
}

--// Paths -----------------------------------------------------------------------
local GameObjects = Workspace:WaitForChild("GameObjects", 20)
local Physical = GameObjects and GameObjects:WaitForChild("Physical", 20)
local EmployeesFolder = Physical and Physical:WaitForChild("Employees", 20)
local ItemsFolder = Physical and Physical:WaitForChild("Items", 20)
local MapFolder = Physical and Physical:WaitForChild("Map", 20)

-- Named specials worth a distinct colour - a BEAR 5 should not look like a
-- shelf stocker on your screen.
local SpecialEmployees = {
    ["BEAR 5"] = true, ["BEAR 5 PRIME"] = true, ["Jim Scary"] = true,
    ["King"] = true, ["Harold"] = true, ["Hubert"] = true, ["Dave"] = true,
    ["Ben"] = true, ["MrEgg"] = true, ["ChickenNugget"] = true,
    ["Snowball"] = true, ["Abomination Employee"] = true, ["EnergyOrb"] = true,
}

-- Only used if ReplicatedStorage.Modules.Item cannot be reached. The real
-- classification comes from the game's own item definitions below, which is
-- why this list no longer decides anything on its own.
local FallbackFood = {
    Pizza = true, Burger = true, Cookie = true, Hotdog = true, Chips = true,
    Lemon = true, ["Lemon Slice"] = true, Banana = true, Water = true,
    ["Ice Cream"] = true, ["Bloxy Soda"] = true, Medkit = true,
}

--// Item definitions --------------------------------------------------------------
-- ReplicatedStorage.Modules.Item is the game's own item registry:
--
--   Item.get(nameOrInstance) -> { Name, PickupTime, Properties = {
--       Inventory, Consumable, Restocks, RegenStats = { Health, Energy, Hunger },
--       ValuedStat } }
--
-- Reading it instead of hardcoding names means the filters below track the game
-- exactly - including the fact that a Glass Shard lives in _EDIBLE and carries a
-- NEGATIVE Health regen, so "food" that would hurt you is something we can
-- actually recognise rather than eat by accident.
local ItemModule
do
    local ok, module = pcall(function()
        local modules = ReplicatedStorage:WaitForChild("Modules", 15)
        return modules and modules:WaitForChild("Item", 15)
    end)
    if ok and module then
        local loaded, api = pcall(require, module)
        if loaded and typeof(api) == "table" and typeof(api.get) == "function" then
            ItemModule = api
        end
    end
end

local defCache = {}

local function itemProps(name)
    if not ItemModule then return nil end
    local cached = defCache[name]
    if cached == nil then
        local ok, def = pcall(ItemModule.get, name)
        cached = (ok and typeof(def) == "table" and def.Properties) or false
        defCache[name] = cached
    end
    return cached or nil
end

local function regenOf(name, stat)
    local props = itemProps(name)
    local stats = props and props.RegenStats
    if not stats then return 0 end
    return tonumber(stats[stat]) or 0
end

-- Consumable in the game's sense: something the client will let you eat/drink.
local function isConsumable(name)
    local props = itemProps(name)
    if props then return props.Consumable == true end
    return FallbackFood[name] == true
end

-- Anything whose Health regen is negative. The game itself special-cases this
-- with a confirmation prompt before you eat it.
local function isHarmful(name)
    return regenOf(name, "Health") < 0
end

local function isHealing(name)
    return regenOf(name, "Health") > 0
end

--// Tags --------------------------------------------------------------------------
-- The client decides what E does purely from these tags: "Interactable" runs
-- Interact, "Storable" runs Store, and "Item" is what makes a model grabbable
-- at all. Matching them beats any name list we could keep up to date.
local function hasTag(instance, tag)
    local ok, tagged = pcall(function() return CollectionService:HasTag(instance, tag) end)
    return ok and tagged == true
end

--// Character helpers ------------------------------------------------------------
local function getCharacter() return LocalPlayer.Character end

local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isAlive()
    local hum = getHumanoid()
    return hum ~= nil and hum.Health > 0
end

-- The System remotes are parented to the character, so they are replaced on
-- every respawn and must be re-fetched rather than cached at load.
local function getSystem()
    local char = getCharacter()
    local system = char and char:FindFirstChild("System")
    if not system then return nil, nil end
    return system:FindFirstChild("Action"), system:FindFirstChild("Event")
end

local function invokeAction(name, payload)
    local action = select(1, getSystem())
    if not action then return false, "no System.Action" end
    local ok, a, b = pcall(function() return action:InvokeServer(name, payload) end)
    if not ok then return false, tostring(a) end
    return a, b
end

--// Namecall hook: energy + fall damage -------------------------------------------
-- Both of these are the client volunteering something to the server. Dropping
-- the call is the whole exploit - there is nothing to spoof, just something
-- not to say.
local HAS_NAMECALL = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

if HAS_NAMECALL then
    local originalNamecall
    originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if not Unloading and typeof(self) == "Instance" and getnamecallmethod() == "FireServer" then
            local okName = pcall(function() return self.Name end)
            if okName and self.Name == "Event" then
                local parent = self.Parent
                if parent and parent.Name == "System" then
                    local action = ...
                    if action == "FallDamage" and Player.NoFallDamage then
                        return
                    end
                    if action == "DecreaseStat" and Player.InfiniteEnergy then
                        return
                    end
                end
            end
        end
        return originalNamecall(self, ...)
    end)
end

-- The other half of infinite energy. Server-side drain still replicates down
-- and overwrites the attribute, but every gate that stops you sprinting or
-- sliding (StartRun / StartSlide) reads this value on the client, so keeping
-- it topped up keeps those gates open regardless of what the server thinks.
track(PostSimulation:Connect(function()
    if Unloading or not Player.InfiniteEnergy then return end
    local hum = getHumanoid()
    if not hum then return end
    local maxEnergy = hum:GetAttribute("MaxEnergy")
    if maxEnergy and (hum:GetAttribute("Energy") or 0) < maxEnergy then
        pcall(function() hum:SetAttribute("Energy", maxEnergy) end)
    end
end))

--// Reach --------------------------------------------------------------------------
-- Two separate numbers control carry distance, and only fixing one of them is
-- why this kept looking broken.
--
--   1. Building (the client's own PickupSystem module) keeps the LIVE carry
--      distance in a module upvalue that starts at 8. PickupRenderLoop reads it
--      every frame to decide where the held item floats:
--        raycast(cursorRay.Origin, cursorRay.Direction * GetScrollDistance())
--
--   2. LocalPlayer:GetAttribute("ScrollDistance") is only a CEILING. It is read
--      by AdjustDistance (mouse wheel) and the gamepad bumpers:
--        SetScrollDistance(math.clamp(current + delta, 2.1, attribute))
--
-- So raising the attribute alone changes nothing until you physically scroll -
-- and on a phone there is no scroll wheel at all, so it could never take
-- effect. The module is a plain ModuleScript under PlayerScripts, and require
-- is cached per instance, so requiring it here hands back the exact same table
-- the game is using. Setting the live value directly is the actual fix; the
-- attribute still gets raised so scrolling cannot clamp it back down.
local PickupSystem
pcall(function()
    local scripts = LocalPlayer:WaitForChild("PlayerScripts", 20)
    local source = scripts and scripts:WaitForChild("source", 20)
    local client = source and source:WaitForChild("client", 20)
    local module = client and client:WaitForChild("Building", 20)
    if module then
        local ok, api = pcall(require, module)
        if ok and typeof(api) == "table" and api.SetScrollDistance then PickupSystem = api end
    end
end)

local DEFAULT_SCROLL_DISTANCE = 8
local baseScrollDistance = nil

local function liveScrollDistance()
    if not PickupSystem then return nil end
    local ok, value = pcall(function() return PickupSystem:GetScrollDistance() end)
    if ok then return value end
    return nil
end

local function applyReach()
    if baseScrollDistance == nil then
        baseScrollDistance = LocalPlayer:GetAttribute("ScrollDistance") or 15
    end
    -- Raise the ceiling first, or the next scroll tick clamps us straight back.
    if LocalPlayer:GetAttribute("ScrollDistance") ~= Player.Reach then
        pcall(function() LocalPlayer:SetAttribute("ScrollDistance", Player.Reach) end)
    end
    if PickupSystem and liveScrollDistance() ~= Player.Reach then
        pcall(function() PickupSystem:SetScrollDistance(Player.Reach) end)
    end
end

local function restoreReach()
    if baseScrollDistance ~= nil then
        pcall(function() LocalPlayer:SetAttribute("ScrollDistance", baseScrollDistance) end)
    end
    if PickupSystem then
        pcall(function() PickupSystem:SetScrollDistance(DEFAULT_SCROLL_DISTANCE) end)
    end
end

--// Holding ------------------------------------------------------------------------
-- IsHolding is a server-set Player attribute. It is the honest answer to
-- "does the server think I have something in my hands right now", which is
-- exactly what a desynced hold needs.
local function isHolding()
    return LocalPlayer:GetAttribute("IsHolding") == true
end

--// Player properties (Remotes.Vip) ------------------------------------------------
-- The in-game moderator panel changes another player's stats by firing one
-- remote:
--
--   Remotes.Vip:FireServer("UpdatePlayerProperties", {
--       Properties = { Health = n, MaxHealth = n, MaxInventorySpace = n, ... },
--       ToPlayer   = player,
--   })
--
-- Its God button is literally SetStat(stat, 1/0), which writes infinity into
-- both the stat and its Max - that is why god mode makes the health bar render
-- strangely, the bar is drawing a fraction with an infinite denominator.
--
-- Whether the server checks your rank before applying this is its business,
-- not something the client can see. So rather than promise anything, every
-- write below is followed by a read of the attribute it was supposed to
-- change, and the UI reports what actually happened.
local VipRemote
pcall(function()
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
    VipRemote = remotes and remotes:WaitForChild("Vip", 15)
end)

local Admin = {
    LastResult = 'not tried',
    LastAt = 0,
}

local function setProperties(properties, toPlayer)
    if not VipRemote then return false end
    local target = toPlayer or LocalPlayer
    local ok = pcall(function()
        VipRemote:FireServer("UpdatePlayerProperties", {
            Properties = properties,
            ToPlayer = target,
        })
    end)
    return ok
end

-- Fires the write, then waits for the value it was meant to produce to show up.
-- A remote the server ignores is silent, so the only honest test is whether the
-- thing changed.
local function setPropertiesAndVerify(properties, check, label)
    if not VipRemote then
        Admin.LastResult = 'Remotes.Vip not found'
        Admin.LastAt = os.clock()
        return false, Admin.LastResult
    end

    setProperties(properties)

    local deadline = os.clock() + 1.5
    while os.clock() < deadline do
        if check() then
            Admin.LastResult = label .. ': applied'
            Admin.LastAt = os.clock()
            return true, Admin.LastResult
        end
        task.wait(0.1)
    end

    Admin.LastResult = label .. ': server refused'
    Admin.LastAt = os.clock()
    return false, Admin.LastResult
end

--// Teleporting -------------------------------------------------------------------
-- Whatever moves you, land stopped. Carrying velocity into a teleport is what
-- flings you back out of where you just arrived.
local function teleportTo(cframe)
    local root = getRoot()
    if not root or not cframe then return false end
    root.CFrame = cframe
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.new()
        root.AssemblyAngularVelocity = Vector3.new()
    end)
    return true
end

local function requestStreamAround(position)
    pcall(function()
        LocalPlayer:RequestStreamAroundAsync(position)
    end)
end

--// Whistle ---------------------------------------------------------------------------
-- Your own whistle is a plain Action call. The client wraps it in a 15 second
-- cooldown held in a local upvalue, so calling the remote directly is not gated
-- by it - the server still is, hence the interval defaulting to 16.
local function sendWhistle()
    return invokeAction("Whistle")
end

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        if Main.AutoWhistle and isAlive() then
            sendWhistle()
            local waited = 0
            local interval = math.max(1, Main.WhistleInterval)
            while waited < interval and not Unloading and Main.AutoWhistle do
                task.wait(0.5)
                waited = waited + 0.5
            end
        end
    end
end)

-- Everyone else's whistle arrives on Remotes.Communication as
-- ("ShowWhistle", { Player = plr, Position = Vector3 }). The game only uses it
-- to draw a marker; the position in it is the exact spot they whistled from,
-- which is all a teleport needs. It fires even while they are streamed out, so
-- this reaches people the sweep would have to hunt for.
local CommunicationRemote
pcall(function()
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
    CommunicationRemote = remotes and remotes:WaitForChild("Communication", 15)
end)

local function onWhistleHeard(who, position)
    local name = (typeof(who) == "Instance" and who:IsA("Player")) and who.Name or "someone"
    local root = getRoot()
    local distance = root and (position - root.Position).Magnitude or nil
    Whistle.Last = {
        Name = name,
        Position = position,
        At = os.clock(),
        Distance = distance,
    }

    if not Whistle.Follow then return end
    if Whistle.Target ~= 'anyone' and name ~= Whistle.Target then return end
    if Whistle.WaitSeconds > 0 and os.clock() > Whistle.ExpiresAt then
        Whistle.Follow = false
        notify('Whistle listen window expired.', 'warning')
        return
    end

    -- Land slightly above the whistle point rather than inside whatever they
    -- were standing on when it went off.
    local landed = teleportTo(CFrame.new(position + Vector3.new(0, Whistle.Offset, 0)))
    if landed then
        requestStreamAround(position)
        notify(('Teleported to %s\'s whistle (%d studs away).'):format(name, math.floor(distance or 0)))
    else
        notify('Heard a whistle but there was no character to move.', 'error')
    end
end

if CommunicationRemote then
    track(CommunicationRemote.OnClientEvent:Connect(function(name, payload)
        if Unloading then return end
        if name ~= "ShowWhistle" or typeof(payload) ~= "table" then return end
        local position = payload.Position
        if typeof(position) ~= "Vector3" then return end
        onWhistleHeard(payload.Player, position)
    end))
end

--// Items ---------------------------------------------------------------------------
local ItemFilters = { 'All', 'Food', 'Healing', 'Storable', 'Interactable', 'Non-food' }

local function itemMatchesFilter(model, filter)
    filter = filter or Visual.ItemFilter
    if filter == "All" then return true end
    if filter == "Food" then return isConsumable(model.Name) and not isHarmful(model.Name) end
    if filter == "Healing" then return isHealing(model.Name) end
    if filter == "Storable" then return hasTag(model, "Storable") end
    if filter == "Interactable" then return hasTag(model, "Interactable") end
    if filter == "Non-food" then return not isConsumable(model.Name) end
    return true
end

-- Streamed-out item models still exist as instances, they just carry no
-- BaseParts. GetPivot still reports where the model is, so distance work stays
-- valid for items you cannot see yet.
local function modelPosition(model)
    local part = model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
        or model:FindFirstChildWhichIsA("BasePart", true)
    if part then return part.Position end
    local ok, pivot = pcall(function() return model:GetPivot().Position end)
    if ok and typeof(pivot) == "Vector3" and pivot.Magnitude > 0.01 then return pivot end
    return nil
end

-- Storable is the tag SecondInteract checks before it fires Store, and it
-- lines up with Properties.Inventory in the item registry - so an item with no
-- tags replicated yet is still recognised by its definition.
local function isStorable(model)
    if hasTag(model, "Storable") then return true end
    local props = itemProps(model.Name)
    return props ~= nil and props.Inventory == true
end

local function isInteractable(model)
    return hasTag(model, "Interactable")
end

-- Mirrors PickupSystem.ReturnModel: the client will only offer a model that is
-- tagged Item, has a PrimaryPart and is not already Busy in someone else's
-- hands. Asking for anything else is a guaranteed refusal.
local function canPickup(model)
    if not model.Parent then return false end
    if not model.PrimaryPart then return false end
    if model:GetAttribute("Busy") == true then return false end
    return true
end

local function collectibleItems(radius, filter)
    local root = getRoot()
    local list = {}
    if not root or not ItemsFolder then return list end
    for _, model in ipairs(ItemsFolder:GetChildren()) do
        if model:IsA("Model") and canPickup(model) and itemMatchesFilter(model, filter) then
            local position = modelPosition(model)
            if position and (position - root.Position).Magnitude <= radius then
                list[#list + 1] = { Model = model, Distance = (position - root.Position).Magnitude }
            end
        end
    end
    table.sort(list, function(a, b) return a.Distance < b.Distance end)
    return list
end

-- Store and Pickup are two different things and confusing them is what got a
-- medkit welded to somebody.
--
-- Store is what E does on a Storable item: SecondInteract calls
-- Action:InvokeServer("Store", {Model = model}) on whatever is under the
-- crosshair, with no pickup involved at all. It goes straight into the bag.
--
-- Pickup puts the item in your HANDS. The server attaches the real model to
-- you, and the client's own Pickup() then sets up everything that makes that
-- state survivable: SetHoldingModel, a ghost clone under the camera, the
-- Heartbeat render loop that positions it, and the raycast filter that stops
-- you shooting rays at your own item. Calling the remote directly does the
-- first half and none of the second, so the server thinks you are holding
-- something the client has never heard of: the real parts ride along colliding
-- with you, and the game's Drop reads GetHoldingModel(), finds nil, and
-- refuses. That is a stuck item you cannot walk away from or put down.
--
-- So: automation uses Store and never Pickup.
local function storeModel(model)
    return invokeAction("Store", { Model = model })
end

local function interactModel(model)
    return invokeAction("Interact", { Model = model })
end

local function pickupModel(model)
    return invokeAction("Pickup", { Model = model })
end

-- Drop carries a client-supplied EndCFrame: the client decides where the held
-- item lands. That is what lets items be moved without moving yourself.
local function dropAt(cframe, throwPower)
    return invokeAction("Drop", {
        EndCFrame = cframe,
        Throw = false,
        CameraCFrame = Camera.CFrame.LookVector,
        ThrowPower = throwPower or 0,
    })
end

-- Puts whatever we are holding down in front of us. This is also the way out
-- of a hold the client never set up, because the server only needs the remote
-- call - it does not care that our client has no ghost model to tidy away.
local function dropHeld()
    local root = getRoot()
    if not root then return false end
    -- Slightly ahead and below eye level, so it lands on the floor rather than
    -- inside your own collision box, which is what makes Drop refuse.
    local target = root.CFrame * CFrame.new(0, -1.5, -5)
    return dropAt(target) == true
end

spawnLoop(function()
    while not Unloading do
        task.wait(Main.CollectDelay)
        if Main.AutoCollect and isAlive() then
            local filter = 'All'
            if not Main.CollectAll and Main.CollectFood then filter = 'Food' end
            local items = collectibleItems(Main.CollectRadius, filter)
            for _, entry in ipairs(items) do
                if Unloading or not Main.AutoCollect then break end
                local model = entry.Model
                -- Glass Shard is registered as edible and takes health off you.
                -- Never sweep it up unless you asked for literally everything.
                local safe = Main.CollectAll or not isHarmful(model.Name)
                if canPickup(model) and safe and isStorable(model) then
                    storeModel(model)
                    task.wait(0.15)
                end
            end
        end
    end
end)

-- A hold the client does not know about can only have come from a remote call,
-- so this watches for exactly that and puts the item down before it can pin
-- you in place. Off by default, because holding things on purpose is normal.
spawnLoop(function()
    local heldSince = nil
    while not Unloading do
        task.wait(0.5)
        if isHolding() then
            heldSince = heldSince or os.clock()
            local desynced = PickupSystem == nil or PickupSystem:GetHoldingModel() == nil
            if Main.AutoUnstick and desynced and (os.clock() - heldSince) >= Main.UnstickAfter then
                if dropHeld() then
                    notify('Dropped an item the client was not tracking.', 'warning')
                end
                heldSince = nil
            end
        else
            heldSince = nil
        end
    end
end)

--// Consumables ----------------------------------------------------------------------
local function inventoryToolNames()
    local names = {}
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then names[#names + 1] = tool.Name end
        end
    end
    local char = getCharacter()
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") then names[#names + 1] = tool.Name end
        end
    end
    return names
end

local function consume(toolName)
    return invokeAction("Inventory_Consume", { Tool = toolName })
end

-- Hunger and Health are server-authoritative in this game, so there is no
-- attribute to pin. Eating is the only real route, which makes automating it
-- the actual feature rather than a workaround.
spawnLoop(function()
    while not Unloading do
        task.wait(1.5)
        local hum = getHumanoid()
        if hum and isAlive() then
            if Main.AutoEat then
                local hunger = hum:GetAttribute("Hunger")
                if hunger and hunger <= Main.HungerThreshold then
                    -- Pick the biggest hunger restore we are carrying rather
                    -- than the first thing in the bag, and never something the
                    -- game registers as edible but health-negative.
                    local best, bestValue = nil, 0
                    for _, name in ipairs(inventoryToolNames()) do
                        if isConsumable(name) and not isHarmful(name) then
                            local value = regenOf(name, "Hunger")
                            if value > bestValue then best, bestValue = name, value end
                        end
                    end
                    if best then consume(best) end
                end
            end
            if Main.AutoHeal and hum.Health <= (hum.MaxHealth * (Main.HealthThreshold / 100)) then
                local best, bestValue = nil, 0
                for _, name in ipairs(inventoryToolNames()) do
                    local value = regenOf(name, "Health")
                    if value > bestValue then best, bestValue = name, value end
                end
                if best then consume(best) end
            end
        end
    end
end)

--// Employees -------------------------------------------------------------------------
local function nearbyEmployees(radius)
    local root = getRoot()
    local list = {}
    if not root or not EmployeesFolder then return list end
    for _, model in ipairs(EmployeesFolder:GetChildren()) do
        local hum = model:FindFirstChildOfClass("Humanoid")
        local hrp = model:FindFirstChild("HumanoidRootPart")
        if hum and hrp and hum.Health > 0 then
            if (hrp.Position - root.Position).Magnitude <= radius then
                list[#list + 1] = { Model = model, Humanoid = hum }
            end
        end
    end
    return list
end

-- ShoveEmployee takes a Humanoid reference with no position in the payload,
-- same shape as Pickup, so range enforcement is the server's choice alone.
spawnLoop(function()
    while not Unloading do
        task.wait(Main.ShoveDelay)
        if Main.RemoteShove and isAlive() then
            for _, entry in ipairs(nearbyEmployees(Main.ShoveRadius)) do
                if Unloading or not Main.RemoteShove then break end
                invokeAction("ShoveEmployee", { Humanoid = entry.Humanoid })
                task.wait(0.1)
            end
        end
    end
end)

--// Movement ---------------------------------------------------------------------------
local noclipConnection
local flyVelocity, flyGyro
local flyDirection = Vector3.new()

local function setNoclip(state)
    if noclipConnection then
        noclipConnection:Disconnect()
        noclipConnection = nil
    end
    if not state then
        local char = getCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and not part.CanCollide then
                    part.CanCollide = true
                end
            end
        end
        return
    end
    -- PreSimulation: collisions have to be cleared before the physics step
    -- resolves them, not after it has already pushed you out of the shelf.
    noclipConnection = PreSimulation:Connect(function()
        if not Player.Noclip or Unloading then return end
        local char = getCharacter()
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end)
end

-- Range grab. The game's own reach for this is a 10 stud raycast baked into
-- GetModelAtCrosshair, so this casts the same ray at whatever distance you set
-- and acts on what it hits.
--
-- It calls Store, not Pickup. Store drops the item into your bag with no hold
-- state involved, which is the same thing E does on a Storable item and cannot
-- leave anything attached to you. Pickup would put it in your hands without the
-- client-side setup that makes a hold work - see the note above storeModel.
local grabParams = RaycastParams.new()
grabParams.FilterType = Enum.RaycastFilterType.Exclude

local function modelAtCrosshair()
    local char = getCharacter()
    if not char then return nil, "no character" end
    grabParams.FilterDescendantsInstances = { char, Camera }

    local viewport = Camera.ViewportSize
    local ray = Camera:ScreenPointToRay(viewport.X / 2, viewport.Y / 2)
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * Player.Reach, grabParams)
    if not hit then return nil, "nothing in the way" end

    local model = hit.Instance:FindFirstAncestorOfClass("Model")
    while model and not hasTag(model, "Item") do
        model = model:FindFirstAncestorOfClass("Model")
    end
    if not model then return nil, "that is not an item" end
    return model
end

local function grabAtCrosshair()
    local model, why = modelAtCrosshair()
    if not model then return false, why end
    if not canPickup(model) then return false, model.Name .. " is busy or not loaded" end

    if isStorable(model) then
        local ok = storeModel(model)
        return ok == true, ok and ("stored " .. model.Name) or "server refused, bag may be full"
    end

    if isInteractable(model) then
        local ok = interactModel(model)
        return ok == true, ok and ("used " .. model.Name) or "server refused"
    end

    -- Not storable and not interactable means the only way to move it is to
    -- hold it, and a remote-only hold is the thing that gets people stuck. Say
    -- so instead of doing it quietly.
    return false, model.Name .. " can only be carried by hand - use the game's own grab"
end

--// Fly ----------------------------------------------------------------------------
local function stopFly()
    if flyVelocity then flyVelocity:Destroy() flyVelocity = nil end
    if flyGyro then flyGyro:Destroy() flyGyro = nil end
    local hum = getHumanoid()
    if hum then pcall(function() hum.PlatformStand = false end) end
end

local function startFly()
    local root = getRoot()
    if not root then return end
    stopFly()
    flyVelocity = Instance.new("BodyVelocity")
    flyVelocity.MaxForce = Vector3.new(1, 1, 1) * 9e9
    flyVelocity.Velocity = Vector3.new()
    flyVelocity.Parent = root
    flyGyro = Instance.new("BodyGyro")
    flyGyro.MaxTorque = Vector3.new(1, 1, 1) * 9e9
    flyGyro.P = 9e4
    flyGyro.CFrame = Camera.CFrame
    flyGyro.Parent = root
end

-- Touch with no keyboard means the default joystick is the only steering the
-- player has, so fly reads it instead of demanding WASD that does not exist.
local function touchOnly()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local mobileRiseUntil = 0

-- On mobile the joystick gives a flat world direction and the camera gives
-- pitch. Splitting the stick into forward/right amounts and replaying them
-- along the camera's real LookVector means aiming the camera up and pushing
-- forward climbs - vertical control with no extra buttons drawn on screen.
local function mobileFlyDirection(camCF)
    local hum = getHumanoid()
    local move = hum and hum.MoveDirection or Vector3.new()
    local direction = Vector3.new()

    if move.Magnitude > 0.05 then
        local flatForward = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
        flatForward = flatForward.Magnitude > 0.001 and flatForward.Unit or camCF.LookVector
        local flatRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
        flatRight = flatRight.Magnitude > 0.001 and flatRight.Unit or camCF.RightVector

        direction = camCF.LookVector * move:Dot(flatForward) + camCF.RightVector * move:Dot(flatRight)
    end

    if os.clock() < mobileRiseUntil then
        direction = direction + Vector3.new(0, 1, 0)
    end

    return direction
end

track(PostSimulation:Connect(function()
    if Unloading or not Player.Fly then return end
    if not flyVelocity or not flyGyro then return end
    local direction = Vector3.new()
    local camCF = Camera.CFrame

    -- W maps to +Z here, so this must NOT be negated: with the minus in place
    -- W flew you backwards and S flew you forwards.
    if flyDirection.Z ~= 0 then direction = direction + camCF.LookVector * flyDirection.Z end
    if flyDirection.X ~= 0 then direction = direction + camCF.RightVector * flyDirection.X end
    if flyDirection.Y ~= 0 then direction = direction + Vector3.new(0, flyDirection.Y, 0) end

    if Player.MobileFly and touchOnly() then
        direction = direction + mobileFlyDirection(camCF)
    end

    if direction.Magnitude > 0 then
        flyVelocity.Velocity = direction.Unit * Player.FlySpeed
    else
        flyVelocity.Velocity = Vector3.new()
    end
    flyGyro.CFrame = camCF
end))

local flyKeys = {
    [Enum.KeyCode.W] = Vector3.new(0, 0, 1),
    [Enum.KeyCode.S] = Vector3.new(0, 0, -1),
    [Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
    [Enum.KeyCode.D] = Vector3.new(1, 0, 0),
    [Enum.KeyCode.Space] = Vector3.new(0, 1, 0),
    [Enum.KeyCode.LeftShift] = Vector3.new(0, -1, 0),
}

track(UserInputService.InputBegan:Connect(function(input, processed)
    if Unloading or processed then return end
    local delta = flyKeys[input.KeyCode]
    if delta then flyDirection = flyDirection + delta end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if Unloading then return end
    local delta = flyKeys[input.KeyCode]
    if delta then flyDirection = flyDirection - delta end
end))

track(UserInputService.JumpRequest:Connect(function()
    if Unloading then return end
    -- While flying the jump button is a straight climb, not a jump.
    if Player.Fly and Player.MobileFly and touchOnly() then
        mobileRiseUntil = os.clock() + 0.3
        return
    end
    if not Player.InfiniteJump then return end
    local hum = getHumanoid()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end) end
end))

track(PostSimulation:Connect(function()
    if Unloading then return end
    local hum = getHumanoid()
    if not hum then return end
    if Player.SpeedEnabled then hum.WalkSpeed = Player.WalkSpeed end
    if Player.JumpEnabled then hum.JumpPower = Player.JumpPower end
    if Player.ReachEnabled then applyReach() end
end))

track(LocalPlayer.Idled:Connect(function()
    if Unloading or not Player.AntiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

track(LocalPlayer.CharacterAdded:Connect(function(char)
    char:WaitForChild("Humanoid", 10)
    if Player.Noclip then setNoclip(true) end
    if Player.Fly then task.wait(0.5) startFly() end
end))

--// ESP ---------------------------------------------------------------------------------
-- Everything lives in a folder under the Camera rather than inside the models
-- themselves. Item models stream in and out constantly, and anything parented
-- to one dies with it - so adornees point at the model while the instances
-- themselves stay put.
local espObjects = {}
local EspHolder = Instance.new("Folder")
EspHolder.Name = "Esp3008"
EspHolder.Parent = Camera

-- Roblox stops rendering Highlights past roughly 31 live instances and gives
-- no error when it does. That ceiling is the real reason item ESP looked dead
-- in a shop holding a hundred pizzas, so it is enforced here on purpose and
-- everything past it falls back to a marker, which has no such limit.
local HIGHLIGHT_BUDGET = 30

local function espColor(kind, name)
    if kind == "Employee" then
        if SpecialEmployees[name] then return Color3.fromRGB(255, 70, 70) end
        return Color3.fromRGB(255, 150, 60)
    elseif kind == "Item" then
        return Color3.fromRGB(255, 220, 70)
    end
    return Color3.fromRGB(80, 180, 255)
end

local function espPart(model)
    return model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Head")
        or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function destroyEsp(key)
    local objs = espObjects[key]
    if not objs then return end
    if objs.Highlight then objs.Highlight:Destroy() end
    if objs.Billboard then objs.Billboard:Destroy() end
    if objs.Proxy then objs.Proxy:Destroy() end
    if objs.Box then pcall(function() objs.Box:Remove() end) end
    espObjects[key] = nil
end

-- A streamed-out model has no part to adorn to, but GetPivot still knows where
-- it is. A tiny invisible anchor driven from the pivot gives the billboard
-- something to hang on so distant items still draw.
local function ensureProxy(objs)
    if objs.Proxy and objs.Proxy.Parent then return objs.Proxy end
    local part = Instance.new("Part")
    part.Name = "anchor"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.Parent = EspHolder
    objs.Proxy = part
    return part
end

local function buildEsp(model, label, kind, method)
    destroyEsp(model)
    local color = espColor(kind, model.Name)
    local objs = { Kind = kind, Method = method, ShowNames = Visual.ShowNames }
    espObjects[model] = objs

    if method == "Highlight" then
        local hl = Instance.new("Highlight")
        hl.FillColor = color
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = model
        hl.Parent = EspHolder
        objs.Highlight = hl
    elseif method == "Box" then
        pcall(function()
            local box = Drawing.new("Square")
            box.Thickness = 1.5
            box.Filled = false
            box.Color = color
            box.Visible = false
            objs.Box = box
        end)
    end

    -- The marker method is the dot itself, so it needs the billboard whether or
    -- not names are on. Highlight and Box only need one for the label.
    if method == "Marker" or Visual.ShowNames then
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "tag"
        billboard.Size = UDim2.fromOffset(200, 40)
        billboard.StudsOffset = Vector3.new(0, 2, 0)
        billboard.AlwaysOnTop = true
        billboard.LightInfluence = 0
        billboard.Parent = EspHolder

        if method == "Marker" then
            local dot = Instance.new("Frame")
            dot.Name = "dot"
            dot.AnchorPoint = Vector2.new(0.5, 0.5)
            dot.Position = UDim2.fromScale(0.5, 0.78)
            dot.Size = UDim2.fromOffset(7, 7)
            dot.BackgroundColor3 = color
            dot.BorderSizePixel = 0
            dot.Parent = billboard
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(1, 0)
            corner.Parent = dot
            objs.Dot = dot
        end

        local text = Instance.new("TextLabel")
        text.Name = "name"
        text.BackgroundTransparency = 1
        text.Size = UDim2.new(1, 0, 0, 24)
        text.Font = Enum.Font.GothamBold
        text.TextSize = 13
        text.TextColor3 = color
        text.TextStrokeTransparency = 0.4
        text.Text = label
        text.Visible = Visual.ShowNames
        text.Parent = billboard

        objs.Billboard = billboard
        objs.NameLabel = text
    end

    return objs
end

local espShown, espTotal = 0, 0

spawnLoop(function()
    while not Unloading do
        task.wait(0.4)
        local root = getRoot()
        local seen = {}
        local candidates = {}

        if root then
            local origin = root.Position

            local function offer(model, kind, label)
                local position = modelPosition(model)
                if not position then return end
                local distance = (position - origin).Magnitude
                if distance > Visual.MaxEspDistance then return end
                candidates[#candidates + 1] = {
                    Model = model,
                    Kind = kind,
                    Label = label,
                    Distance = distance,
                    Position = position,
                }
            end

            if Visual.Employees and EmployeesFolder then
                for _, model in ipairs(EmployeesFolder:GetChildren()) do
                    local hum = model:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        offer(model, "Employee", model.Name)
                    end
                end
            end

            if Visual.Items and ItemsFolder then
                for _, model in ipairs(ItemsFolder:GetChildren()) do
                    if model:IsA("Model") and itemMatchesFilter(model) then
                        offer(model, "Item", model.Name)
                    end
                end
            end

            if Visual.PlayersEsp then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= LocalPlayer and plr.Character then
                        offer(plr.Character, "Player", plr.Name)
                    end
                end
            end

            -- Nearest first, so whatever the count limit cuts off is always the
            -- stuff furthest away rather than whatever happened to be enumerated
            -- last.
            table.sort(candidates, function(a, b) return a.Distance < b.Distance end)

            espTotal = #candidates
            local limit = Visual.MaxEspCount
            if limit > 0 and #candidates > limit then
                for index = #candidates, limit + 1, -1 do
                    candidates[index] = nil
                end
            end
            espShown = #candidates

            local highlightsUsed = 0

            for _, entry in ipairs(candidates) do
                local model = entry.Model
                seen[model] = true

                local method = Visual.Method
                if method == "Highlight" then
                    if highlightsUsed < HIGHLIGHT_BUDGET then
                        highlightsUsed = highlightsUsed + 1
                    else
                        method = "Marker"
                    end
                elseif method == "Box" and typeof(Drawing) ~= "table" then
                    method = "Marker"
                end

                local objs = espObjects[model]
                if not objs or objs.Method ~= method or objs.ShowNames ~= Visual.ShowNames then
                    objs = buildEsp(model, entry.Label, entry.Kind, method)
                end

                if objs then
                    objs.Position = entry.Position
                    local part = espPart(model)

                    if objs.Highlight then
                        objs.Highlight.FillTransparency = Visual.Transparency
                    end

                    if objs.Billboard then
                        local adornee = part
                        if not adornee then
                            local proxy = ensureProxy(objs)
                            proxy.CFrame = CFrame.new(entry.Position)
                            adornee = proxy
                        elseif objs.Proxy then
                            objs.Proxy:Destroy()
                            objs.Proxy = nil
                        end
                        objs.Billboard.Adornee = adornee
                        objs.Billboard.MaxDistance = Visual.MaxEspDistance
                    end

                    if objs.Dot then
                        objs.Dot.BackgroundTransparency = Visual.Transparency * 0.6
                    end

                    if objs.NameLabel then
                        objs.NameLabel.Visible = Visual.ShowNames
                        if Visual.ShowDistance then
                            objs.NameLabel.Text = ("%s [%d]"):format(entry.Label, math.floor(entry.Distance))
                        else
                            objs.NameLabel.Text = entry.Label
                        end
                    end
                end
            end
        else
            espShown, espTotal = 0, 0
        end

        for key in pairs(espObjects) do
            if not seen[key] then destroyEsp(key) end
        end
    end
end)

track(PreRender:Connect(function()
    if Unloading then return end
    for model, objs in pairs(espObjects) do
        if objs.Box then
            if not model.Parent then
                destroyEsp(model)
            else
                local anchor = objs.Position or (espPart(model) and espPart(model).Position)
                if anchor then
                    local top, onScreen = Camera:WorldToViewportPoint(anchor + Vector3.new(0, 3, 0))
                    local bottom = Camera:WorldToViewportPoint(anchor - Vector3.new(0, 3, 0))
                    if onScreen then
                        local height = bottom.Y - top.Y
                        local width = height * 0.6
                        objs.Box.Visible = true
                        objs.Box.Transparency = 1 - Visual.Transparency
                        objs.Box.Position = Vector2.new(top.X - width / 2, top.Y)
                        objs.Box.Size = Vector2.new(width, height)
                    else
                        objs.Box.Visible = false
                    end
                end
            end
        end
    end
end))

--// World visuals ---------------------------------------------------------------------
local savedLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
}

local function applyFullbright(state)
    if state then
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
    else
        Lighting.Brightness = savedLighting.Brightness
        Lighting.ClockTime = savedLighting.ClockTime
        Lighting.GlobalShadows = savedLighting.GlobalShadows
        Lighting.Ambient = savedLighting.Ambient
    end
end

local function applyNoFog(state)
    Lighting.FogEnd = state and 1e6 or savedLighting.FogEnd
end

-- Purely local: hiding the ceiling only changes your own view, nobody else
-- sees through anything, and it comes back when the chunk re-streams.
local strippedParts = setmetatable({}, { __mode = "k" })

local function setCeilingHidden(state)
    if not MapFolder then return end
    for _, name in ipairs({ "Ceiling", "CeilingDecor" }) do
        local folder = MapFolder:FindFirstChild(name)
        if folder then
            for _, descendant in ipairs(folder:GetDescendants()) do
                if descendant:IsA("BasePart") then
                    if state then
                        if strippedParts[descendant] == nil then
                            strippedParts[descendant] = descendant.LocalTransparencyModifier
                        end
                        descendant.LocalTransparencyModifier = 1
                    elseif strippedParts[descendant] ~= nil then
                        descendant.LocalTransparencyModifier = strippedParts[descendant]
                        strippedParts[descendant] = nil
                    end
                end
            end
        end
    end
end

--// UI ---------------------------------------------------------------------------------
local Centrl = loadstring(game:HttpGet('https://raw.githubusercontent.com/iamdookie1/Rblx2/main/UI/Lib2.lua'))()

local Window = Centrl:Window({
    Title = '3008',
    SubTitle = 'assist',
    Folder = '3008Assist',
    ToggleKey = Enum.KeyCode.RightShift,
    Accent = Color3.fromRGB(255, 190, 60),
})

function notify(content, kind, duration)
    Centrl:Notify({
        Title = '3008',
        Content = content,
        Type = kind or 'success',
        Duration = duration or 5,
    })
end

if not Physical then
    notify('Workspace.GameObjects.Physical not found - the game may have changed.', 'error', 8)
end

--// Main tab
local MainTab = Window:Tab({ Title = 'main', Icon = 'crosshair' })

local LootSection = MainTab:Section({ Title = 'looting', Side = 'left' })

LootSection:Toggle({
    Title = 'auto collect',
    Flag = 'tv_auto_collect',
    Default = false,
    Callback = function(v) Main.AutoCollect = v end,
})

LootSection:Toggle({
    Title = 'collect everything (not just food)',
    Flag = 'tv_collect_all',
    Default = false,
    Callback = function(v) Main.CollectAll = v end,
})

LootSection:Slider({
    Title = 'collect radius',
    Flag = 'tv_collect_radius',
    Min = 10,
    Max = 500,
    Increment = 10,
    Default = 60,
    Suffix = ' studs',
    Callback = function(v) Main.CollectRadius = v end,
})

LootSection:Button({
    Title = 'collect nearest item now',
    Callback = function()
        local filter = Main.CollectAll and 'All' or 'Food'
        local items = collectibleItems(Main.CollectRadius, filter)
        for _, entry in ipairs(items) do
            if isStorable(entry.Model) then
                local ok = storeModel(entry.Model)
                notify(ok and ('Stored ' .. entry.Model.Name) or 'Server refused - bag may be full.', ok and 'success' or 'warning')
                return
            end
        end
        notify('Nothing storable matching in range.', 'warning')
    end,
})

LootSection:Paragraph({
    Title = 'store, not pickup',
    Text = 'Collecting fires Store, which is what E does on a Storable item and puts it straight in the bag. It never fires Pickup, which puts the item in your hands - a hold created by a remote alone leaves the client with no idea it happened, and that is what welded a medkit to somebody. There is a force drop button on the player tab if anything ever does get stuck.',
})

LootSection:Paragraph({
    Title = 'what counts as food',
    Text = 'Read straight out of ReplicatedStorage.Modules.Item rather than a name list, so it follows the game exactly. That includes knowing Glass Shard is filed as edible with a negative health regen - auto collect skips it unless you asked for everything, and auto eat will never touch it.',
})

LootSection:Paragraph({
    Title = 'range is the experiment',
    Text = 'Store takes a model reference and the range check is client side, so this asks for items you are not looking at. If the server checks distance it simply refuses - raise the radius until it starts failing and you have found the real limit.',
})

local ActionSection = MainTab:Section({ Title = 'actions', Side = 'right' })

ActionSection:Toggle({
    Title = 'auto eat when hungry',
    Flag = 'tv_auto_eat',
    Default = false,
    Callback = function(v) Main.AutoEat = v end,
})

ActionSection:Slider({
    Title = 'eat below hunger',
    Flag = 'tv_hunger_threshold',
    Min = 5,
    Max = 90,
    Increment = 5,
    Default = 40,
    Callback = function(v) Main.HungerThreshold = v end,
})

ActionSection:Toggle({
    Title = 'auto heal when hurt',
    Flag = 'tv_auto_heal',
    Default = false,
    Callback = function(v) Main.AutoHeal = v end,
})

ActionSection:Slider({
    Title = 'heal below health %',
    Flag = 'tv_health_threshold',
    Min = 10,
    Max = 90,
    Increment = 5,
    Default = 50,
    Callback = function(v) Main.HealthThreshold = v end,
})

ActionSection:Toggle({
    Title = 'auto shove employees',
    Flag = 'tv_remote_shove',
    Default = false,
    Callback = function(v) Main.RemoteShove = v end,
})

ActionSection:Slider({
    Title = 'shove radius',
    Flag = 'tv_shove_radius',
    Min = 5,
    Max = 300,
    Increment = 5,
    Default = 40,
    Suffix = ' studs',
    Callback = function(v) Main.ShoveRadius = v end,
})

ActionSection:Button({
    Title = 'drop held item here',
    Callback = function()
        local root = getRoot()
        if not root then return end
        local ok = dropAt(root.CFrame * CFrame.new(0, 0, -4))
        notify(ok and 'Dropped.' or 'Nothing held, or server refused.', ok and 'success' or 'warning')
    end,
})

ActionSection:Paragraph({
    Title = 'why health and hunger have no toggle',
    Text = 'Both are server-owned in this game: the client only ever reads them to draw the bars. Pinning them would make your HUD lie while you still starve, so eating and medkits are automated instead. Energy is different - the client decides whether you can sprint, which is why infinite energy is real.',
})

--// Whistle section
local WhistleSection = MainTab:Section({ Title = 'whistle', Side = 'right' })

WhistleSection:Button({
    Title = 'whistle now',
    Callback = function()
        local ok = sendWhistle()
        notify(ok and 'Whistled.' or 'Whistle refused (server cooldown).', ok and 'success' or 'warning')
    end,
})

WhistleSection:Toggle({
    Title = 'auto whistle',
    Flag = 'tv_auto_whistle',
    Default = false,
    Callback = function(v) Main.AutoWhistle = v end,
})

WhistleSection:Slider({
    Title = 'whistle every',
    Flag = 'tv_whistle_interval',
    Min = 5,
    Max = 120,
    Increment = 1,
    Default = 16,
    Suffix = 's',
    Callback = function(v) Main.WhistleInterval = v end,
})

local whistleHeard = WhistleSection:Stat({ Title = 'last whistle', Value = 'none yet' })

local whistleDropdown = WhistleSection:Dropdown({
    Title = 'teleport when this player whistles',
    Flag = 'tv_whistle_target',
    Options = { 'anyone' },
    Default = 'anyone',
    Callback = function(v) Whistle.Target = v end,
})

WhistleSection:Button({
    Title = 'refresh whistle list',
    Callback = function()
        local names = { 'anyone' }
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then names[#names + 1] = plr.Name end
        end
        pcall(function() whistleDropdown:SetOptions(names) end)
    end,
})

WhistleSection:Input({
    Title = 'listen for (seconds, 0 = forever)',
    Flag = 'tv_whistle_wait',
    Default = '60',
    Placeholder = '60',
    Callback = function(text)
        local seconds = tonumber(text)
        if not seconds or seconds < 0 then
            notify('Listen time needs to be a number of seconds.', 'warning')
            return
        end
        Whistle.WaitSeconds = seconds
        if Whistle.Follow then
            Whistle.ExpiresAt = seconds > 0 and (os.clock() + seconds) or math.huge
        end
    end,
})

local whistleToggle = WhistleSection:Toggle({
    Title = 'teleport to whistle',
    Flag = 'tv_whistle_follow',
    Default = false,
    Callback = function(v)
        Whistle.Follow = v
        if v then
            Whistle.ExpiresAt = Whistle.WaitSeconds > 0 and (os.clock() + Whistle.WaitSeconds) or math.huge
            if not CommunicationRemote then
                notify('Remotes.Communication was not found - whistles cannot be heard.', 'error', 8)
            end
        end
    end,
})

local whistleWindow = WhistleSection:Stat({ Title = 'listening', Value = 'off' })

-- Expiry has to be watched here rather than only at whistle time, so the
-- toggle actually turns itself off when nobody whistles at all.
spawnLoop(function()
    while not Unloading do
        task.wait(0.5)

        if Whistle.Follow and Whistle.WaitSeconds > 0 and os.clock() > Whistle.ExpiresAt then
            Whistle.Follow = false
            pcall(function() whistleToggle:Set(false) end)
            notify('Stopped listening for whistles - nothing heard in time.', 'warning')
        end

        local windowText = 'off'
        if Whistle.Follow then
            if Whistle.WaitSeconds > 0 then
                windowText = ('%ds left'):format(math.max(0, math.floor(Whistle.ExpiresAt - os.clock())))
            else
                windowText = 'no time limit'
            end
        end
        pcall(function() whistleWindow:Set(windowText) end)

        local heardText = 'none yet'
        if Whistle.Last then
            local ago = os.clock() - Whistle.Last.At
            if Whistle.Last.Distance then
                heardText = ('%s, %ds ago, %d studs'):format(Whistle.Last.Name, math.floor(ago), math.floor(Whistle.Last.Distance))
            else
                heardText = ('%s, %ds ago'):format(Whistle.Last.Name, math.floor(ago))
            end
        end
        pcall(function() whistleHeard:Set(heardText) end)
    end
end)

WhistleSection:Button({
    Title = 'go to last whistle',
    Callback = function()
        if not Whistle.Last then
            notify('No whistle heard yet.', 'warning')
            return
        end
        local ok = teleportTo(CFrame.new(Whistle.Last.Position + Vector3.new(0, Whistle.Offset, 0)))
        notify(ok and ('Moved to ' .. Whistle.Last.Name .. "'s whistle.") or 'No character to move.', ok and 'success' or 'error')
    end,
})

WhistleSection:Paragraph({
    Title = 'how this hears them',
    Text = 'Every whistle is broadcast to all clients on Remotes.Communication as ShowWhistle with the whistler and the exact world position it came from - the game only uses it to draw the marker on your screen. Reading that same event means no guessing and no configuration, and it reaches people who are streamed out, which is exactly who the sweep struggles with.',
})

--// Player tab
local PlayerTab = Window:Tab({ Title = 'player', Icon = 'user' })
local StatsSection = PlayerTab:Section({ Title = 'stats', Side = 'left' })

StatsSection:Toggle({
    Title = 'infinite energy',
    Flag = 'tv_inf_energy',
    Default = false,
    Callback = function(v)
        Player.InfiniteEnergy = v
        if v and not HAS_NAMECALL then
            notify('No namecall hooking on this executor - energy is pinned locally but slide drain still reaches the server.', 'warning', 6)
        end
    end,
})

StatsSection:Toggle({
    Title = 'no fall damage',
    Flag = 'tv_no_fall',
    Default = false,
    Callback = function(v)
        Player.NoFallDamage = v
        if v and not HAS_NAMECALL then
            notify('No namecall hooking on this executor - fall damage cannot be blocked.', 'error', 6)
        end
    end,
})

StatsSection:Paragraph({
    Title = 'how these work',
    Text = 'Your client volunteers both of these. It calculates its own fall damage and asks the server to apply it, and it spends its own energy when sliding. Blocking those two calls is the entire trick - nothing is being faked.',
})

local MoveSection = PlayerTab:Section({ Title = 'movement', Side = 'right' })

MoveSection:Toggle({
    Title = 'walkspeed',
    Flag = 'tv_speed_enabled',
    Default = false,
    Callback = function(v)
        Player.SpeedEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.WalkSpeed = 16 end
        end
    end,
})

MoveSection:Slider({
    Title = 'walkspeed value',
    Flag = 'tv_walkspeed',
    Min = 16,
    Max = 250,
    Increment = 2,
    Default = 16,
    Callback = function(v) Player.WalkSpeed = v end,
})

MoveSection:Toggle({
    Title = 'jump power',
    Flag = 'tv_jump_enabled',
    Default = false,
    Callback = function(v)
        Player.JumpEnabled = v
        if not v then
            local hum = getHumanoid()
            if hum then hum.JumpPower = 50 end
        end
    end,
})

MoveSection:Slider({
    Title = 'jump power value',
    Flag = 'tv_jumppower',
    Min = 50,
    Max = 400,
    Increment = 10,
    Default = 50,
    Callback = function(v) Player.JumpPower = v end,
})

MoveSection:Toggle({
    Title = 'infinite jump',
    Flag = 'tv_inf_jump',
    Default = false,
    Callback = function(v) Player.InfiniteJump = v end,
})

MoveSection:Toggle({
    Title = 'noclip',
    Flag = 'tv_noclip',
    Default = false,
    Callback = function(v)
        Player.Noclip = v
        setNoclip(v)
    end,
})

MoveSection:Toggle({
    Title = 'fly',
    Flag = 'tv_fly',
    Default = false,
    Callback = function(v)
        Player.Fly = v
        if v then startFly() else stopFly() end
    end,
})

MoveSection:Slider({
    Title = 'fly speed',
    Flag = 'tv_fly_speed',
    Min = 10,
    Max = 400,
    Increment = 10,
    Default = 70,
    Callback = function(v) Player.FlySpeed = v end,
})

MoveSection:Toggle({
    Title = 'mobile fly uses the joystick',
    Flag = 'tv_mobile_fly',
    Default = true,
    Callback = function(v) Player.MobileFly = v end,
})

MoveSection:Paragraph({
    Title = 'flying on a phone',
    Text = 'No extra buttons get drawn - the normal joystick steers and the camera decides height. Push forward with the camera tilted up and you climb, tilt down and you dive, exactly like walking does. The jump button becomes a straight climb while fly is on. Keyboards are untouched: WASD, space and shift work as they always did.',
})

local ReachSection = PlayerTab:Section({ Title = 'reach', Side = 'left' })

ReachSection:Toggle({
    Title = 'extended item reach',
    Flag = 'tv_reach_enabled',
    Default = false,
    Callback = function(v)
        Player.ReachEnabled = v
        if v then applyReach() else restoreReach() end
    end,
})

ReachSection:Slider({
    Title = 'reach distance',
    Flag = 'tv_reach',
    Min = 5,
    Max = 200,
    Increment = 5,
    Default = 30,
    Suffix = ' studs',
    Callback = function(v)
        Player.Reach = v
        if Player.ReachEnabled then applyReach() end
    end,
})

local reachLive = ReachSection:Stat({ Title = 'carry distance now', Value = '-' })
local reachCeiling = ReachSection:Stat({ Title = 'ceiling (attribute)', Value = '-' })
local reachModule = ReachSection:Stat({
    Title = 'PickupSystem',
    Value = PickupSystem and 'hooked' or 'not found',
})

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        local live = liveScrollDistance()
        local ceiling = LocalPlayer:GetAttribute("ScrollDistance")
        pcall(function()
            reachLive:Set(live and ('%.1f studs'):format(live) or 'module not hooked')
        end)
        pcall(function()
            reachCeiling:Set(ceiling and tostring(ceiling) or 'unset')
        end)
    end
end)

ReachSection:Button({
    Title = 'take item at crosshair',
    Callback = function()
        local ok, detail = grabAtCrosshair()
        notify(ok and tostring(detail) or ('No take: ' .. tostring(detail)), ok and 'success' or 'warning')
    end,
})

ReachSection:Keybind({
    Title = 'take key',
    Flag = 'tv_grab_key',
    Default = Enum.KeyCode.V,
    Callback = function()
        local ok, detail = grabAtCrosshair()
        if not ok then notify('No take: ' .. tostring(detail), 'warning', 3) end
    end,
})

ReachSection:Toggle({
    Title = 'anti afk',
    Flag = 'tv_anti_afk',
    Default = true,
    Callback = function(v) Player.AntiAFK = v end,
})

ReachSection:Paragraph({
    Title = 'why the attribute alone did nothing',
    Text = 'There are two numbers. The live carry distance is a module upvalue inside the client\'s Building module that starts at 8, and the render loop reads it every frame to place the held item. The ScrollDistance attribute is only the CEILING that the mouse wheel clamps against. Raising the ceiling changes nothing until you physically scroll - and on a phone there is no wheel, so it could never take effect. Building is a plain ModuleScript and require is cached per instance, so this now sets the live value on the same table the game is using. The carry distance stat above is read straight back out of it.',
})

ReachSection:Paragraph({
    Title = 'taking things at range',
    Text = 'Carry range and take range are different numbers. Taking is a fixed 10 stud raycast baked into GetModelAtCrosshair, so this casts the same ray at your reach distance and fires Store or Interact on what it hits - the same calls E makes. It deliberately never fires Pickup: a hold set up by a remote alone is the thing that welds an item to you.',
})

local HoldSection = PlayerTab:Section({ Title = 'holding', Side = 'right' })

local holdStat = HoldSection:Stat({ Title = 'server says holding', Value = 'no' })
local holdSync = HoldSection:Stat({ Title = 'client tracking it', Value = '-' })

spawnLoop(function()
    while not Unloading do
        task.wait(0.4)
        local held = isHolding()
        pcall(function() holdStat:Set(held and 'yes' or 'no') end)

        local text
        if not PickupSystem then
            text = 'module not hooked'
        elseif not held then
            text = '-'
        else
            local ok, model = pcall(function() return PickupSystem:GetHoldingModel() end)
            if ok and model then
                text = 'yes (' .. tostring(model.Name) .. ')'
            else
                text = 'NO - stuck'
            end
        end
        pcall(function() holdSync:Set(text) end)
    end
end)

HoldSection:Button({
    Title = 'force drop held item',
    Callback = function()
        if not isHolding() then
            notify('The server does not think you are holding anything.', 'warning')
            return
        end
        local ok = dropHeld()
        notify(ok and 'Dropped it.' or 'Server refused - try moving somewhere clearer first.', ok and 'success' or 'error')
    end,
})

HoldSection:Toggle({
    Title = 'auto drop untracked holds',
    Flag = 'tv_auto_unstick',
    Default = false,
    Callback = function(v) Main.AutoUnstick = v end,
})

HoldSection:Slider({
    Title = 'drop after',
    Flag = 'tv_unstick_after',
    Min = 1,
    Max = 15,
    Increment = 1,
    Default = 3,
    Suffix = 's',
    Callback = function(v) Main.UnstickAfter = v end,
})

HoldSection:Paragraph({
    Title = 'what got the medkit stuck',
    Text = 'Auto collect used to fire Pickup and then Store. Pickup puts the item in your hands, and the game\'s own Pickup function is what makes that survivable - it records the held model, spawns the ghost you actually see, starts the render loop and fixes the raycast filter. Firing the remote alone did none of that, so the server had you holding something the client had never heard of: the real parts rode along colliding with you, and Drop refused because it looks up a held model that was never set. Auto collect now fires Store only, which is what E does and involves no hold at all. The button above is the way out if anything else leaves you stuck.',
})

--// Visual tab
local VisualTab = Window:Tab({ Title = 'visual', Icon = 'eye' })
local EspSection = VisualTab:Section({ Title = 'esp', Side = 'left' })

EspSection:Toggle({
    Title = 'employee esp',
    Flag = 'tv_esp_employees',
    Default = false,
    Callback = function(v) Visual.Employees = v end,
})

EspSection:Toggle({
    Title = 'item esp',
    Flag = 'tv_esp_items',
    Default = false,
    Callback = function(v) Visual.Items = v end,
})

EspSection:Toggle({
    Title = 'player esp',
    Flag = 'tv_esp_players',
    Default = false,
    Callback = function(v) Visual.PlayersEsp = v end,
})

EspSection:Dropdown({
    Title = 'item filter',
    Flag = 'tv_item_filter',
    Options = ItemFilters,
    Default = 'Food',
    Callback = function(v) Visual.ItemFilter = v end,
})

EspSection:Dropdown({
    Title = 'method',
    Flag = 'tv_esp_method',
    Options = { 'Marker', 'Highlight', 'Box' },
    Default = 'Marker',
    Callback = function(v) Visual.Method = v end,
})

local espCountStat = EspSection:Stat({ Title = 'drawn', Value = '0' })

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        local text
        if espTotal > espShown then
            text = ('%d of %d in range'):format(espShown, espTotal)
        else
            text = ('%d'):format(espShown)
        end
        pcall(function() espCountStat:Set(text) end)
    end
end)

local EspConfigSection = VisualTab:Section({ Title = 'esp config', Side = 'right' })

EspConfigSection:Toggle({
    Title = 'names',
    Flag = 'tv_esp_names',
    Default = true,
    Callback = function(v) Visual.ShowNames = v end,
})

EspConfigSection:Toggle({
    Title = 'distance',
    Flag = 'tv_esp_distance',
    Default = true,
    Callback = function(v) Visual.ShowDistance = v end,
})

EspConfigSection:Slider({
    Title = 'transparency',
    Flag = 'tv_esp_transparency',
    Min = 0,
    Max = 1,
    Increment = 0.05,
    Default = 0.5,
    Callback = function(v) Visual.Transparency = v end,
})

EspConfigSection:Slider({
    Title = 'max esp distance',
    Flag = 'tv_esp_max_dist',
    Min = 100,
    Max = 5000,
    Increment = 100,
    Default = 1500,
    Suffix = ' studs',
    Callback = function(v) Visual.MaxEspDistance = v end,
})

EspConfigSection:Input({
    Title = 'max esp count (0 = no limit)',
    Flag = 'tv_esp_max_count',
    Default = '150',
    Placeholder = '150',
    Callback = function(text)
        local count = tonumber(text)
        if not count or count < 0 then
            notify('ESP count needs to be a whole number, or 0 for no limit.', 'warning')
            return
        end
        Visual.MaxEspCount = math.floor(count)
        if Visual.MaxEspCount == 0 then
            notify('ESP count limit removed. Marker draws thousands fine; Highlight still caps at 30 by engine.', 'warning', 7)
        end
    end,
})

EspConfigSection:Paragraph({
    Title = 'why item esp was empty',
    Text = 'Highlight is the default in most hubs and Roblox quietly stops rendering past about 31 live Highlight instances - in a shop holding a hundred pizzas the item highlights simply never drew. Marker is the new default: a dot and a label per entry with no engine ceiling. Highlight still works and is capped at the nearest 30 on purpose; anything past that falls back to a marker instead of vanishing.',
})

EspConfigSection:Paragraph({
    Title = 'streamed out items',
    Text = 'A distant item model still exists but carries no parts at all, so there is nothing to adorn to. Those entries get an invisible anchor driven from the model pivot, which is why items now show up well before you can see them. Adornees point at the model while the instances themselves live under the camera, so nothing dies when a chunk streams out.',
})

EspConfigSection:Paragraph({
    Title = 'colours',
    Text = 'Named specials (BEAR 5, BEAR 5 PRIME, Jim Scary, King, Harold, Hubert, Dave, Ben, MrEgg, ChickenNugget, Snowball, Abomination) draw red so they never get mistaken for an ordinary employee, which draws orange. Items are yellow, players blue.',
})

local WorldSection = VisualTab:Section({ Title = 'world', Side = 'left' })

WorldSection:Toggle({
    Title = 'fullbright',
    Flag = 'tv_fullbright',
    Default = false,
    Callback = function(v)
        Visual.Fullbright = v
        applyFullbright(v)
    end,
})

WorldSection:Toggle({
    Title = 'no fog',
    Flag = 'tv_no_fog',
    Default = false,
    Callback = function(v)
        Visual.NoFog = v
        applyNoFog(v)
    end,
})

WorldSection:Toggle({
    Title = 'hide ceiling',
    Flag = 'tv_strip_ceiling',
    Default = false,
    Callback = function(v)
        Visual.StripCeiling = v
        setCeilingHidden(v)
    end,
})

WorldSection:Paragraph({
    Title = 'hide ceiling',
    Text = 'Local only - it changes your view and nothing else, nobody else sees through anything. Newly streamed chunks come back solid, so toggle it again after moving a long way.',
})

--// Settings tab
local SettingsTab = Window:Tab({ Title = 'settings', Icon = 'settings' })
local DiagSection = SettingsTab:Section({ Title = 'diagnostics', Side = 'left' })

local systemLabel = DiagSection:Label({ Title = 'System remotes: checking' })

spawnLoop(function()
    while not Unloading do
        task.wait(1)
        local action, event = getSystem()
        local systemText
        if action and event then
            systemText = 'System remotes: found (Action + Event)'
        elseif action or event then
            systemText = 'System remotes: partial'
        else
            systemText = 'System remotes: missing'
        end
        pcall(function() systemLabel:Set(systemText) end)
    end
end)

local invStat = DiagSection:Stat({ Title = 'inventory', Value = '-' })
local itemModuleStat = DiagSection:Stat({ Title = 'item definitions', Value = ItemModule and 'loaded' or 'unavailable' })
local whistleRemoteStat = DiagSection:Stat({ Title = 'whistle broadcast', Value = CommunicationRemote and 'connected' or 'not found' })

spawnLoop(function()
    while not Unloading do
        task.wait(1)
        local max = LocalPlayer:GetAttribute("MaxInventorySpace")
        local used = 0
        for _, name in ipairs(inventoryToolNames()) do
            if name then used = used + 1 end
        end
        pcall(function() invStat:Set(('%d / %s'):format(used, max and tostring(max) or '?')) end)
    end
end)

--// Server properties tab
local AdminTab = Window:Tab({ Title = 'server', Icon = 'shield' })
local PropSection = AdminTab:Section({ Title = 'player properties', Side = 'left' })

local adminStat = PropSection:Stat({
    Title = 'Remotes.Vip',
    Value = VipRemote and 'found' or 'not found',
})
local adminResult = PropSection:Stat({ Title = 'last write', Value = 'not tried' })

spawnLoop(function()
    while not Unloading do
        task.wait(0.5)
        pcall(function() adminResult:Set(Admin.LastResult) end)
    end
end)

local function humanoidMaxHealth()
    local hum = getHumanoid()
    return hum and hum.MaxHealth or 0
end

PropSection:Button({
    Title = 'god mode (infinite health)',
    Callback = function()
        spawnLoop(function()
            local ok, detail = setPropertiesAndVerify(
                { Health = math.huge, MaxHealth = math.huge },
                function() return humanoidMaxHealth() == math.huge end,
                'god'
            )
            notify(detail, ok and 'success' or 'error', 7)
            if ok then
                notify('Health bar will render oddly - it is drawing a fraction over infinity.', 'warning', 7)
            end
        end)
    end,
})

PropSection:Button({
    Title = 'restore health to 100',
    Callback = function()
        spawnLoop(function()
            local ok, detail = setPropertiesAndVerify(
                { Health = 100, MaxHealth = 100 },
                function() return humanoidMaxHealth() == 100 end,
                'health reset'
            )
            notify(detail, ok and 'success' or 'error', 6)
        end)
    end,
})

PropSection:Button({
    Title = 'infinite hunger + energy',
    Callback = function()
        spawnLoop(function()
            local ok, detail = setPropertiesAndVerify(
                {
                    Hunger = math.huge, MaxHunger = math.huge,
                    Energy = math.huge, MaxEnergy = math.huge,
                },
                function()
                    local hum = getHumanoid()
                    return hum ~= nil and hum:GetAttribute("MaxHunger") == math.huge
                end,
                'hunger + energy'
            )
            notify(detail, ok and 'success' or 'error', 6)
        end)
    end,
})

PropSection:Input({
    Title = 'max inventory space',
    Flag = 'tv_inv_space',
    Default = '100',
    Placeholder = '100',
    Callback = function(text)
        local wanted = tonumber(text)
        if not wanted or wanted < 1 then
            notify('Inventory space needs to be a number of slots.', 'warning')
            return
        end
        wanted = math.floor(wanted)
        spawnLoop(function()
            local ok, detail = setPropertiesAndVerify(
                { MaxInventorySpace = wanted },
                function() return LocalPlayer:GetAttribute("MaxInventorySpace") == wanted end,
                'inventory space'
            )
            notify(detail, ok and 'success' or 'error', 6)
        end)
    end,
})

PropSection:Input({
    Title = 'carry distance (server side)',
    Flag = 'tv_server_scroll',
    Default = '100',
    Placeholder = '100',
    Callback = function(text)
        local wanted = tonumber(text)
        if not wanted or wanted < 2 then
            notify('Carry distance needs to be a number of studs.', 'warning')
            return
        end
        spawnLoop(function()
            local ok, detail = setPropertiesAndVerify(
                { ScrollDistance = wanted },
                function() return LocalPlayer:GetAttribute("ScrollDistance") == wanted end,
                'carry distance'
            )
            notify(detail, ok and 'success' or 'error', 6)
        end)
    end,
})

local TogglesSection = AdminTab:Section({ Title = 'flags', Side = 'right' })

local function propertyToggle(title, flag, attribute)
    TogglesSection:Button({
        Title = title,
        Callback = function()
            spawnLoop(function()
                local wanted = not (LocalPlayer:GetAttribute(attribute) == true)
                local ok, detail = setPropertiesAndVerify(
                    { [attribute] = wanted },
                    function() return LocalPlayer:GetAttribute(attribute) == wanted end,
                    attribute
                )
                notify(detail .. (ok and (' -> ' .. tostring(wanted)) or ''), ok and 'success' or 'error', 6)
            end)
        end,
    })
end

propertyToggle('toggle CanPickUp', 'tv_can_pickup', 'CanPickUp')
propertyToggle('toggle CanInteract', 'tv_can_interact', 'CanInteract')
propertyToggle('toggle AlwaysAnchor', 'tv_always_anchor', 'AlwaysAnchor')

TogglesSection:Paragraph({
    Title = 'how this works',
    Text = 'The in-game moderator panel changes a player by firing one remote: Remotes.Vip UpdatePlayerProperties with a Properties table and a ToPlayer. Its God button is literally SetStat(stat, 1/0), writing infinity into the stat and its Max, which is exactly why god mode makes the health bar draw strangely. These buttons send the same payload aimed at you.',
})

TogglesSection:Paragraph({
    Title = 'whether it lands is the server\'s call',
    Text = 'Nothing here can promise a result. If the server checks your rank first, the remote is simply ignored and you get no error - so every button reads back the attribute it was supposed to change and the last write line above says applied or server refused. That is the real answer, not a toggle flipping green.',
})

local ControlSection = SettingsTab:Section({ Title = 'control', Side = 'right' })

ControlSection:Button({
    Title = 'unload',
    Callback = function()
        Unloading = true

        for _, connection in ipairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end

        for key in pairs(espObjects) do destroyEsp(key) end
        if EspHolder then EspHolder:Destroy() end
        setNoclip(false)
        stopFly()
        restoreReach()
        Whistle.Follow = false
        Main.AutoWhistle = false
        applyFullbright(false)
        applyNoFog(false)
        setCeilingHidden(false)

        local hum = getHumanoid()
        if hum then
            hum.WalkSpeed = 16
            hum.JumpPower = 50
        end

        Centrl:Unload()
    end,
})

ControlSection:Paragraph({
    Title = 'unload',
    Text = 'Disconnects every loop and hook, clears ESP, restores lighting, collisions and your walkspeed. The namecall hook itself cannot be removed without rejoining, but it goes inert once unloaded.',
})

Window:Load()

notify('Loaded. RightShift toggles the menu.', 'success', 5)
